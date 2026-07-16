unit Pipes.Base;

{$I pipes.inc}

{ Base comum de TNamedPipeServer/TNamedPipeClient: configuracao (PipeName,
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
  - pdmMainThread chega no milestone M6 (SetupDispatch rejeita por ora). }

interface

uses
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Threading;

type
  TNamedPipeBase = class
  private
    FPipeName: string;
    FDispatchMode: TPipeDispatchMode;
    FMaxMessageSize: Cardinal;
    FOnMessage: TPipeMessageEvent;
    FOnError: TPipeErrorEvent;
    FDispatchPool: TPipeThreadPool; // pool privado (pdmSerialized); nil = global
    FInFlight: Integer;             // work items despachados em execucao (atomico)
    procedure SetPipeName(const AValue: string);
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
    constructor Create(const APipeName: string);
    destructor Destroy; override;
    property PipeName: string read FPipeName write SetPipeName;
    property Active: Boolean read GetActive;
    property DispatchMode: TPipeDispatchMode read FDispatchMode write SetDispatchMode;
    property MaxMessageSize: Cardinal read FMaxMessageSize write SetMaxMessageSize;
    property OnMessage: TPipeMessageEvent read FOnMessage write FOnMessage;
    property OnError: TPipeErrorEvent read FOnError write FOnError;
  end;

implementation

type
  { Work items dos eventos: dados capturados em campos (sem closures), dec de
    FInFlight no finally — mesmo contrato do TAMQPDeliveryWork. }
  TPipeMessageWork = class(TPipeWorkItem)
  private
    FOwner: TNamedPipeBase;
    FCallback: TPipeMessageEvent;
    FConnId: TPipeConnectionId;
    FData: TBytes;
  public
    constructor Create(AOwner: TNamedPipeBase; ACallback: TPipeMessageEvent;
      AConnId: TPipeConnectionId; const AData: TBytes);
    procedure Execute; override;
  end;

  TPipeConnEventWork = class(TPipeWorkItem)
  private
    FOwner: TNamedPipeBase;
    FCallback: TPipeConnectionEvent;
    FConnId: TPipeConnectionId;
  public
    constructor Create(AOwner: TNamedPipeBase; ACallback: TPipeConnectionEvent;
      AConnId: TPipeConnectionId);
    procedure Execute; override;
  end;

  TPipeErrorWork = class(TPipeWorkItem)
  private
    FOwner: TNamedPipeBase;
    FCallback: TPipeErrorEvent;
    FConnId: TPipeConnectionId;
    FMsg: string;
  public
    constructor Create(AOwner: TNamedPipeBase; ACallback: TPipeErrorEvent;
      AConnId: TPipeConnectionId; const AMsg: string);
    procedure Execute; override;
  end;

{ TPipeMessageWork }

constructor TPipeMessageWork.Create(AOwner: TNamedPipeBase;
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

constructor TPipeConnEventWork.Create(AOwner: TNamedPipeBase;
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

constructor TPipeErrorWork.Create(AOwner: TNamedPipeBase;
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

{ TNamedPipeBase }

constructor TNamedPipeBase.Create(const APipeName: string);
begin
  inherited Create;
  FPipeName := APipeName; // direto no campo: GetActive e' abstrato aqui
  FDispatchMode := pdmPool;
  FMaxMessageSize := PIPES_DEFAULT_MAX_MESSAGE_SIZE;
end;

destructor TNamedPipeBase.Destroy;
begin
  TeardownDispatch; // rede de seguranca (os descendentes ja pararam tudo)
  inherited;
end;

procedure TNamedPipeBase.EnsureInactive(const AWhat: string);
begin
  if GetActive then
    raise EPipeError.CreateFmt('%s nao pode mudar com o componente ativo', [AWhat]);
end;

procedure TNamedPipeBase.SetPipeName(const AValue: string);
begin
  EnsureInactive('PipeName');
  FPipeName := AValue;
end;

procedure TNamedPipeBase.SetDispatchMode(AValue: TPipeDispatchMode);
begin
  EnsureInactive('DispatchMode');
  FDispatchMode := AValue;
end;

procedure TNamedPipeBase.SetMaxMessageSize(AValue: Cardinal);
begin
  EnsureInactive('MaxMessageSize');
  if AValue = 0 then
    raise EPipeError.Create('MaxMessageSize deve ser maior que zero');
  FMaxMessageSize := AValue;
end;

function TNamedPipeBase.EventPool: TPipeThreadPool;
begin
  if Assigned(FDispatchPool) then
    Result := FDispatchPool
  else
    Result := PipePool;
end;

procedure TNamedPipeBase.SetupDispatch;
begin
  if FDispatchMode = pdmMainThread then
    raise EPipeError.Create('pdmMainThread sera suportado no milestone M6');
  if FDispatchMode = pdmSerialized then
    FDispatchPool := TPipeThreadPool.Create(1); // 1 worker: ordem FIFO global
end;

procedure TNamedPipeBase.TeardownDispatch;
begin
  FreeAndNil(FDispatchPool); // drena a propria fila no Destroy
end;

procedure TNamedPipeBase.DrainInFlight;
begin
  while PipeAtomicGet(FInFlight) > 0 do
    Sleep(10);
end;

procedure TNamedPipeBase.IncInFlight;
begin
  PipeAtomicInc(FInFlight);
end;

procedure TNamedPipeBase.DecInFlight;
begin
  PipeAtomicDec(FInFlight);
end;

procedure TNamedPipeBase.DispatchMessage(AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LCallback: TPipeMessageEvent;
begin
  LCallback := FOnMessage;
  if not Assigned(LCallback) then
    Exit;
  IncInFlight;
  EventPool.Queue(TPipeMessageWork.Create(Self, LCallback, AConnId, AData));
end;

procedure TNamedPipeBase.DispatchConnEvent(AEvent: TPipeConnectionEvent;
  AConnId: TPipeConnectionId);
begin
  if not Assigned(AEvent) then
    Exit;
  IncInFlight;
  EventPool.Queue(TPipeConnEventWork.Create(Self, AEvent, AConnId));
end;

procedure TNamedPipeBase.DispatchError(AConnId: TPipeConnectionId;
  const AMsg: string);
var
  LCallback: TPipeErrorEvent;
begin
  LCallback := FOnError;
  if not Assigned(LCallback) then
    Exit;
  IncInFlight;
  EventPool.Queue(TPipeErrorWork.Create(Self, LCallback, AConnId, AMsg));
end;

end.
