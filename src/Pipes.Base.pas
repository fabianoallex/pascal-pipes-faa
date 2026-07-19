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
  TPipeBase = class;

  { Credenciais e politica de validacao do ptTls, como propriedades editaveis
    uma a uma (Srv.TlsOptions.CertFile := ...). Envolve o record
    TPipeTlsOptions, que continua sendo o que trafega para a camada de
    transporte, via AsOptions.

    Existe como classe em vez de campo publico por causa de EnsureInactive: o
    transporte le estas opcoes UMA vez, no Listen/Connect. Um campo solto
    aceitaria calado um CertFile trocado com o servidor no ar — a configuracao
    pareceria aplicada sem nunca ter efeito. }
  TPipeTlsConfig = class
  private
    FOwner: TPipeBase;
    FOptions: TPipeTlsOptions;
    procedure SetCertFile(const AValue: string);
    procedure SetCertPassword(const AValue: string);
    procedure SetKeyFile(const AValue: string);
    procedure SetCaFile(const AValue: string);
    procedure SetSkipServerVerification(AValue: Boolean);
    procedure SetHandshakeTimeoutMs(AValue: Cardinal);
  public
    constructor Create(AOwner: TPipeBase);
    /// Snapshot para a camada de transporte.
    function AsOptions: TPipeTlsOptions;
    /// Servidor: certificado a apresentar (PFX no Schannel, PEM no OpenSSL);
    /// obrigatorio. Cliente: certificado a apresentar em mTLS (vazio = nenhum).
    property CertFile: string read FOptions.CertFile write SetCertFile;
    /// Senha do PFX (so Schannel).
    property CertPassword: string
      read FOptions.CertPassword write SetCertPassword;
    /// Chave privada em PEM (so OpenSSL; no Schannel a chave vem no PFX).
    property KeyFile: string read FOptions.KeyFile write SetKeyFile;
    /// Servidor: CA que assina os certificados de CLIENTE. Preenchido, LIGA
    /// mTLS — quem nao apresentar certificado dela e' recusado.
    /// Cliente: CA que valida o servidor (vazio = trust store do sistema).
    property CaFile: string read FOptions.CaFile write SetCaFile;
    /// Cliente: desliga a validacao da cadeia do servidor (default False =
    /// valida). Ligar so' em laboratorio — sem validacao a sessao e' MITM-avel.
    property SkipServerVerification: Boolean
      read FOptions.SkipServerVerification write SetSkipServerVerification;
    /// Prazo do handshake; 0 = PIPE_TLS_HANDSHAKE_TIMEOUT_DEFAULT.
    property HandshakeTimeoutMs: Cardinal
      read FOptions.HandshakeTimeoutMs write SetHandshakeTimeoutMs;
  end;

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
    FTransport: TPipeTransport;
    FKeepAliveSeconds: Cardinal;
    FDispatchMode: TPipeDispatchMode;
    FMaxMessageSize: Cardinal;
    FOnMessage: TPipeMessageEvent;
    FOnError: TPipeErrorEvent;
    FDispatchPool: TPipeThreadPool; // pool privado (pdmSerialized); nil = global
    FInFlight: Integer;             // work items despachados em execucao (atomico)
    FGuard: TPipeGuard;             // guarda dos eventos pdmMainThread
    FTlsConfig: TPipeTlsConfig;     // sempre existe; so' consultado em ptTls
    procedure SetAddress(const AValue: string);
    procedure SetTransport(AValue: TPipeTransport);
    procedure SetKeepAliveSeconds(AValue: Cardinal);
    procedure SetDispatchMode(AValue: TPipeDispatchMode);
    procedure SetMaxMessageSize(AValue: Cardinal);
  protected
    function GetActive: Boolean; virtual; abstract;
    /// Propriedades de configuracao so mudam com o componente inativo.
    /// TPipeTlsConfig tambem chama, para guardar as proprias mudancas (mesma
    /// unit: protected e' acessivel entre classes daqui).
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
    constructor Create(const AAddress: string;
      ATransport: TPipeTransport = ptLocal);
    destructor Destroy; override;
    /// Endereco do ponto de comunicacao. Para ptLocal e' o nome do pipe
    /// ('MeuPipe') ou um caminho nativo ('\\.\pipe\X', '/tmp/x.sock'); para
    /// ptTcp e' 'host:porta'.
    property Address: string read FAddress write SetAddress;
    /// Transporte que carrega os frames (ptLocal por padrao).
    property Transport: TPipeTransport read FTransport write SetTransport;
    /// Credenciais e politica de validacao usadas quando Transport = ptTls;
    /// ignoradas nos outros transportes. Lidas UMA vez, no Listen/Connect.
    property TlsOptions: TPipeTlsConfig read FTlsConfig;
    /// Segundos de ociosidade antes do primeiro probe de keepalive TCP;
    /// 0 desliga. So tem efeito em ptTcp (ptLocal ignora: a morte do processo
    /// par sempre fecha o pipe/socket local).
    ///
    /// Serve a DOIS propositos, e o segundo costuma ser o mais importante:
    /// detectar conexao morta em silencio, e manter vivo o mapeamento de
    /// NAT/VPN de uma conexao ociosa — por isso o valor precisa ser MENOR que
    /// o timeout de ociosidade do tunel, nao maior.
    property KeepAliveSeconds: Cardinal
      read FKeepAliveSeconds write SetKeepAliveSeconds;
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

{ TPipeTlsConfig }

constructor TPipeTlsConfig.Create(AOwner: TPipeBase);
begin
  inherited Create;
  FOwner := AOwner;
  // FOptions zerado: HandshakeTimeoutMs = 0 significa o prazo padrao, nao
  // "sem prazo" (ver PIPE_TLS_HANDSHAKE_TIMEOUT_DEFAULT).
end;

function TPipeTlsConfig.AsOptions: TPipeTlsOptions;
begin
  Result := FOptions;
end;

procedure TPipeTlsConfig.SetCertFile(const AValue: string);
begin
  FOwner.EnsureInactive('TlsOptions.CertFile');
  FOptions.CertFile := AValue;
end;

procedure TPipeTlsConfig.SetCertPassword(const AValue: string);
begin
  FOwner.EnsureInactive('TlsOptions.CertPassword');
  FOptions.CertPassword := AValue;
end;

procedure TPipeTlsConfig.SetKeyFile(const AValue: string);
begin
  FOwner.EnsureInactive('TlsOptions.KeyFile');
  FOptions.KeyFile := AValue;
end;

procedure TPipeTlsConfig.SetCaFile(const AValue: string);
begin
  FOwner.EnsureInactive('TlsOptions.CaFile');
  FOptions.CaFile := AValue;
end;

procedure TPipeTlsConfig.SetSkipServerVerification(AValue: Boolean);
begin
  FOwner.EnsureInactive('TlsOptions.SkipServerVerification');
  FOptions.SkipServerVerification := AValue;
end;

procedure TPipeTlsConfig.SetHandshakeTimeoutMs(AValue: Cardinal);
begin
  FOwner.EnsureInactive('TlsOptions.HandshakeTimeoutMs');
  FOptions.HandshakeTimeoutMs := AValue;
end;

{ TPipeBase }

constructor TPipeBase.Create(const AAddress: string;
  ATransport: TPipeTransport);
begin
  inherited Create;
  FAddress := AAddress; // direto no campo: GetActive e' abstrato aqui
  FTransport := ATransport;
  FKeepAliveSeconds := PIPES_DEFAULT_KEEPALIVE_SECONDS;
  FDispatchMode := pdmPool;
  FMaxMessageSize := PIPES_DEFAULT_MAX_MESSAGE_SIZE;
  FGuard := TPipeGuard.Create;
  FTlsConfig := TPipeTlsConfig.Create(Self);
end;

destructor TPipeBase.Destroy;
begin
  TeardownDispatch; // rede de seguranca (os descendentes ja pararam tudo)
  // Eventos pdmMainThread ainda na fila da main thread viram no-op.
  FGuard.Invalidate;
  FGuard.Release;
  FTlsConfig.Free;
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

procedure TPipeBase.SetTransport(AValue: TPipeTransport);
begin
  EnsureInactive('Transport');
  FTransport := AValue;
end;

procedure TPipeBase.SetKeepAliveSeconds(AValue: Cardinal);
begin
  EnsureInactive('KeepAliveSeconds');
  FKeepAliveSeconds := AValue;
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
