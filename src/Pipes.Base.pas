unit Pipes.Base;

{$I pipes.inc}

{ Base comum de TPipeServer/TPipeClient: configuracao (Address,
  DispatchMode, MaxMessageSize), eventos comuns (OnMessage/OnError) e o motor
  de despacho de callbacks do usuario.

  Invariantes de despacho:
  - Threads de leitura/accept NUNCA executam codigo do usuario: todo evento
    vira um TPipeWorkItem enfileirado no pool — o global (pdmPool) ou um pool
    privado de 1 worker (pdmSerialized: ordem FIFO global garantida).
  - O handler e' capturado em campo do work item NO DESPACHO (leitura de
    method pointer nao e' atomica; capturar evita ler um ponteiro rasgado se
    o usuario trocar o evento com o componente ativo).
  - FInFlight conta work items despachados e ainda nao concluidos;
    DrainInFlight espera zerar antes de liberar recursos que os callbacks
    referenciam (padrao DrainInFlight do pascal-amqp-faa).
  - NAO chame Stop/Disconnect/Destroy de DENTRO de um callback do proprio
    componente: o drain esperaria o proprio callback (auto-espera).
  - pdmMainThread: eventos vao para a main thread via TThread.Queue (LCL/VCL
    os drenam no loop de mensagens; apps console precisam de CheckSynchronize).
    Esses eventos NAO entram em FInFlight — drena-los a partir da main thread
    seria auto-espera; em vez disso cada evento carrega um objeto-guarda
    (TPipeGuard) refcounted que o destructor invalida: um evento que dispare
    depois do Free do componente vira no-op, nunca use-after-free. Entre Stop
    e Destroy a guarda segue valida (eventos pendentes ainda disparam). }

interface

uses
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Threading;

type
  { Guarda refcounted dos eventos pdmMainThread: o componente e' o dono e a
    invalida no Destroy; cada evento enfileirado segura uma referencia e so
    invoca o callback se a guarda ainda for valida. }
  TPipeGuard = class
  private
    FRefs: Integer;
    FValid: Integer;
  public
    constructor Create; // refs=1 (dono), valida
    function IsValid: Boolean;
    procedure Invalidate;
    procedure AddRef;
    procedure Release; // libera o objeto quando zera
  end;

  TPipeBase = class
  private
    FAddress: string;
    FDispatchMode: TPipeDispatchMode;
    FMaxMessageSize: Cardinal;
    FOnMessage: TPipeMessageEvent;
    FOnError: TPipeErrorEvent;
    FDispatchPool: TPipeThreadPool; // pool privado (pdmSerialized); nil = global
    FInFlight: Integer;             // work items despachados em execucao (atomico)
    FGuard: TPipeGuard;             // guarda dos eventos pdmMainThread
    procedure SetAddress(const AValue: string);
    procedure SetDispatchMode(AValue: TPipeDispatchMode);
    procedure SetMaxMessageSize(AValue: Cardinal);
  protected
    function GetActive: Boolean; virtual; abstract;
    /// Propriedades de configuracao so mudam com o componente inativo.
    procedure EnsureInactive(const AWhat: string);
    /// Pool onde os eventos do usuario executam.
    function EventPool: TPipeThreadPool;
    /// Chamar na ativacao (Listen/Connect): valida o modo de despacho e cria
    /// o pool privado se pdmSerialized.
    procedure SetupDispatch;
    /// Chamar na desativacao, DEPOIS de DrainInFlight.
    procedure TeardownDispatch;
    /// Espera todos os callbacks despachados terminarem.
    procedure DrainInFlight;
    procedure IncInFlight;
    procedure DecInFlight;
    // Despacho (chamado pelas threads internas). Cada Dispatch* incrementa
    // FInFlight se ha handler; o work item decrementa no finally do Execute.
    procedure DispatchMessage(AConnId: TPipeConnectionId; const AData: TBytes);
    procedure DispatchConnEvent(AEvent: TPipeConnectionEvent;
      AConnId: TPipeConnectionId);
    procedure DispatchError(AConnId: TPipeConnectionId; const AMsg: string);
  public
    constructor Create(const AAddress: string);
    destructor Destroy; override;
    /// Endereco do ponto de comunicacao. Para o transporte local e' o nome do
    /// pipe ('MeuPipe') ou um caminho nativo ('\\.\pipe\X', '/tmp/x.sock').
    property Address: string read FAddress write SetAddress;
    /// Compatibilidade com a API anterior a generalizacao do transporte.
    /// Mesmo campo de Address; sera marcada deprecated apos a migracao de
    /// samples e testes.
    property PipeName: string read FAddress write SetAddress;
    property Active: Boolean read GetActive;
    property DispatchMode: TPipeDispatchMode read FDispatchMode write SetDispatchMode;
    property MaxMessageSize: Cardinal read FMaxMessageSize write SetMaxMessageSize;
    property OnMessage: TPipeMessageEvent read FOnMessage write FOnMessage;
    property OnError: TPipeErrorEvent read FOnError write FOnError;
  end;

  /// Alias de compatibilidade: o nome antigo amarrava a API ao Named Pipe do
  /// Windows, que passa a ser apenas um dos transportes.
  TNamedPipeBase = TPipeBase;

implementation

type
  TPipeQueuedKind = (qeMessage, qeConn, qeError);

  { Evento enfileirado na MAIN THREAD (pdmMainThread) via TThread.Queue.
    Nao conta em FInFlight (drain a partir da main thread = auto-espera);
    a seguranca vem da guarda. Libera a si mesmo apos rodar. }
  TPipeQueuedEvent = class
  private
    FGuard: TPipeGuard; // referencia propria (AddRef no create, Release no Run)
    FOwner: TPipeBase;
    FKind: TPipeQueuedKind;
    FMsgCb: TPipeMessageEvent;
    FConnCb: TPipeConnectionEvent;
    FErrCb: TPipeErrorEvent;
    FConnId: TPipeConnectionId;
    FData: TBytes;
    FMsg: string;
  public
    constructor Create(AOwner: TPipeBase; AKind: TPipeQueuedKind;
      AConnId: TPipeConnectionId);
    procedure Run; // executa na main thread (CheckSynchronize/loop LCL-VCL)
  end;

  { Work items dos eventos: dados capturados em campos (sem closures), dec de
    FInFlight no finally — mesmo contrato do TAMQPDeliveryWork. }
  TPipeMessageWork = class(TPipeWorkItem)
  private
    FOwner: TPipeBase;
    FCallback: TPipeMessageEvent;
    FConnId: TPipeConnectionId;
    FData: TBytes;
  public
    constructor Create(AOwner: TPipeBase; ACallback: TPipeMessageEvent;
      AConnId: TPipeConnectionId; const AData: TBytes);
    procedure Execute; override;
  end;

  TPipeConnEventWork = class(TPipeWorkItem)
  private
    FOwner: TPipeBase;
    FCallback: TPipeConnectionEvent;
    FConnId: TPipeConnectionId;
  public
    constructor Create(AOwner: TPipeBase; ACallback: TPipeConnectionEvent;
      AConnId: TPipeConnectionId);
    procedure Execute; override;
  end;

  TPipeErrorWork = class(TPipeWorkItem)
  private
    FOwner: TPipeBase;
    FCallback: TPipeErrorEvent;
    FConnId: TPipeConnectionId;
    FMsg: string;
  public
    constructor Create(AOwner: TPipeBase; ACallback: TPipeErrorEvent;
      AConnId: TPipeConnectionId; const AMsg: string);
    procedure Execute; override;
  end;

{ TPipeGuard }

constructor TPipeGuard.Create;
begin
  inherited Create;
  FRefs := 1;  // referencia do dono (o componente)
  FValid := 1;
end;

function TPipeGuard.IsValid: Boolean;
begin
  Result := PipeAtomicGet(FValid) = 1;
end;

procedure TPipeGuard.Invalidate;
begin
  PipeAtomicSet(FValid, 0);
end;

procedure TPipeGuard.AddRef;
begin
  PipeAtomicInc(FRefs);
end;

procedure TPipeGuard.Release;
begin
  if PipeAtomicDec(FRefs) = 0 then
    Free;
end;

{ TPipeQueuedEvent }

constructor TPipeQueuedEvent.Create(AOwner: TPipeBase;
  AKind: TPipeQueuedKind; AConnId: TPipeConnectionId);
begin
  inherited Create;
  FOwner := AOwner;
  FKind := AKind;
  FConnId := AConnId;
  FGuard := AOwner.FGuard;
  FGuard.AddRef;
end;

procedure TPipeQueuedEvent.Run;
begin
  try
    if FGuard.IsValid then
      try
        case FKind of
          qeMessage: FMsgCb(FOwner, FConnId, FData);
          qeConn:    FConnCb(FOwner, FConnId);
          qeError:   FErrCb(FOwner, FConnId, FMsg);
        end;
      except
        // mesmo contrato do pool: excecao de callback nao derruba o chamador
        // (aqui seria o CheckSynchronize/loop de mensagens da main thread)
      end;
  finally
    FGuard.Release;
    Free;
  end;
end;

{ TPipeMessageWork }

constructor TPipeMessageWork.Create(AOwner: TPipeBase;
  ACallback: TPipeMessageEvent; AConnId: TPipeConnectionId; const AData: TBytes);
begin
  inherited Create;
  FOwner := AOwner;
  FCallback := ACallback;
  FConnId := AConnId;
  FData := AData;
end;

procedure TPipeMessageWork.Execute;
begin
  try
    FCallback(FOwner, FConnId, FData);
  finally
    FOwner.DecInFlight;
  end;
end;

{ TPipeConnEventWork }

constructor TPipeConnEventWork.Create(AOwner: TPipeBase;
  ACallback: TPipeConnectionEvent; AConnId: TPipeConnectionId);
begin
  inherited Create;
  FOwner := AOwner;
  FCallback := ACallback;
  FConnId := AConnId;
end;

procedure TPipeConnEventWork.Execute;
begin
  try
    FCallback(FOwner, FConnId);
  finally
    FOwner.DecInFlight;
  end;
end;

{ TPipeErrorWork }

constructor TPipeErrorWork.Create(AOwner: TPipeBase;
  ACallback: TPipeErrorEvent; AConnId: TPipeConnectionId; const AMsg: string);
begin
  inherited Create;
  FOwner := AOwner;
  FCallback := ACallback;
  FConnId := AConnId;
  FMsg := AMsg;
end;

procedure TPipeErrorWork.Execute;
begin
  try
    FCallback(FOwner, FConnId, FMsg);
  finally
    FOwner.DecInFlight;
  end;
end;

{ TPipeBase }

constructor TPipeBase.Create(const AAddress: string);
begin
  inherited Create;
  FAddress := AAddress; // direto no campo: GetActive e' abstrato aqui
  FDispatchMode := pdmPool;
  FMaxMessageSize := PIPES_DEFAULT_MAX_MESSAGE_SIZE;
  FGuard := TPipeGuard.Create;
end;

destructor TPipeBase.Destroy;
begin
  TeardownDispatch; // rede de seguranca (os descendentes ja pararam tudo)
  // Eventos pdmMainThread ainda na fila da main thread viram no-op.
  FGuard.Invalidate;
  FGuard.Release;
  inherited;
end;

procedure TPipeBase.EnsureInactive(const AWhat: string);
begin
  if GetActive then
    raise EPipeError.CreateFmt('%s nao pode mudar com o componente ativo', [AWhat]);
end;

procedure TPipeBase.SetAddress(const AValue: string);
begin
  EnsureInactive('Address');
  FAddress := AValue;
end;

procedure TPipeBase.SetDispatchMode(AValue: TPipeDispatchMode);
begin
  EnsureInactive('DispatchMode');
  FDispatchMode := AValue;
end;

procedure TPipeBase.SetMaxMessageSize(AValue: Cardinal);
begin
  EnsureInactive('MaxMessageSize');
  if AValue = 0 then
    raise EPipeError.Create('MaxMessageSize deve ser maior que zero');
  FMaxMessageSize := AValue;
end;

function TPipeBase.EventPool: TPipeThreadPool;
begin
  if Assigned(FDispatchPool) then
    Result := FDispatchPool
  else
    Result := PipePool;
end;

procedure TPipeBase.SetupDispatch;
begin
  if FDispatchMode = pdmSerialized then
    FDispatchPool := TPipeThreadPool.Create(1); // 1 worker: ordem FIFO global
end;

procedure TPipeBase.TeardownDispatch;
begin
  FreeAndNil(FDispatchPool); // drena a propria fila no Destroy
end;

procedure TPipeBase.DrainInFlight;
begin
  while PipeAtomicGet(FInFlight) > 0 do
    Sleep(10);
end;

procedure TPipeBase.IncInFlight;
begin
  PipeAtomicInc(FInFlight);
end;

procedure TPipeBase.DecInFlight;
begin
  PipeAtomicDec(FInFlight);
end;

procedure TPipeBase.DispatchMessage(AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LCallback: TPipeMessageEvent;
  LQueued: TPipeQueuedEvent;
begin
  LCallback := FOnMessage;
  if not Assigned(LCallback) then
    Exit;
  if FDispatchMode = pdmMainThread then
  begin
    LQueued := TPipeQueuedEvent.Create(Self, qeMessage, AConnId);
    LQueued.FMsgCb := LCallback;
    LQueued.FData := AData;
    TThread.Queue(nil, LQueued.Run);
    Exit;
  end;
  IncInFlight;
  EventPool.Queue(TPipeMessageWork.Create(Self, LCallback, AConnId, AData));
end;

procedure TPipeBase.DispatchConnEvent(AEvent: TPipeConnectionEvent;
  AConnId: TPipeConnectionId);
var
  LQueued: TPipeQueuedEvent;
begin
  if not Assigned(AEvent) then
    Exit;
  if FDispatchMode = pdmMainThread then
  begin
    LQueued := TPipeQueuedEvent.Create(Self, qeConn, AConnId);
    LQueued.FConnCb := AEvent;
    TThread.Queue(nil, LQueued.Run);
    Exit;
  end;
  IncInFlight;
  EventPool.Queue(TPipeConnEventWork.Create(Self, AEvent, AConnId));
end;

procedure TPipeBase.DispatchError(AConnId: TPipeConnectionId;
  const AMsg: string);
var
  LCallback: TPipeErrorEvent;
  LQueued: TPipeQueuedEvent;
begin
  LCallback := FOnError;
  if not Assigned(LCallback) then
    Exit;
  if FDispatchMode = pdmMainThread then
  begin
    LQueued := TPipeQueuedEvent.Create(Self, qeError, AConnId);
    LQueued.FErrCb := LCallback;
    LQueued.FMsg := AMsg;
    TThread.Queue(nil, LQueued.Run);
    Exit;
  end;
  IncInFlight;
  EventPool.Queue(TPipeErrorWork.Create(Self, LCallback, AConnId, AMsg));
end;

end.
