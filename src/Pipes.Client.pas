unit Pipes.Client;

{$I pipes.inc}

{ TNamedPipeClient: cliente de Named Pipes (uma conexao).

  Threads: 1 reader (TPipeClientReaderThread) + pool de despacho (Pipes.Base).

  Invariantes:
  - FWriteLock serializa as escritas E protege FStream/FEndpoint contra o
    free do Disconnect (SendBytes escreve sob o lock; Disconnect so libera
    os objetos sob o mesmo lock, depois do join do reader).
  - Disconnect e' sincrono e idempotente: CloseAbort -> join do reader ->
    OnDisconnected -> DrainInFlight -> libera. NAO chamar de dentro de um
    callback do proprio cliente (auto-espera no drain).
  - OnDisconnected dispara UMA vez por sessao (CAS em FDisconnectNotified),
    tanto na queda natural (reader ve EPipeClosed) quanto no Disconnect
    deliberado.
  - Connect apos queda: limpa a sessao morta (join/free) e abre outra.
  - AutoReconnect chega no milestone M6. }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Transport,
  Pipes.Base;

type
  TNamedPipeClient = class(TNamedPipeBase)
  private
    FEndpoint: TPipeEndpoint;
    FStream: TPipeEndpointStream;
    FReader: TThread;
    FWriteLock: TCriticalSection;
    FConnected: Boolean;
    FDeliberate: Integer;         // atomico: 1 durante Disconnect deliberado
    FDisconnectNotified: Integer; // atomico: OnDisconnected ja disparado
    FOnConnected: TPipeConnectionEvent;
    FOnDisconnected: TPipeConnectionEvent;
    // Chamados pelo reader (mesma unit):
    procedure ReaderFinished(const AError: string);
    procedure HandleFrame(const AFrame: TPipeFrame);
    procedure NotifyDisconnectedOnce;
  protected
    function GetActive: Boolean; override;
  public
    constructor Create(const APipeName: string);
    destructor Destroy; override;
    /// Conecta (re-tentando ate ATimeoutMs; EPipeTimeout no prazo). Se havia
    /// uma sessao anterior (viva ou morta), e' encerrada antes.
    procedure Connect(ATimeoutMs: Cardinal = 5000);
    /// Sincrono e idempotente.
    procedure Disconnect;
    procedure SendBytes(const AData: TBytes);
    procedure SendText(const AText: string);
    property Connected: Boolean read GetActive;
    property OnConnected: TPipeConnectionEvent
      read FOnConnected write FOnConnected;
    property OnDisconnected: TPipeConnectionEvent
      read FOnDisconnected write FOnDisconnected;
  end;

implementation

type
  TPipeClientReaderThread = class(TThread)
  private
    FClient: TNamedPipeClient;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TNamedPipeClient);
  end;

{ TPipeClientReaderThread }

constructor TPipeClientReaderThread.Create(AClient: TNamedPipeClient);
begin
  FClient := AClient;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPipeClientReaderThread.Execute;
var
  LFrame: TPipeFrame;
begin
  try
    while True do
    begin
      LFrame := PipeReadFrame(FClient.FStream, FClient.MaxMessageSize);
      FClient.HandleFrame(LFrame);
    end;
  except
    on EPipeClosed do
      FClient.ReaderFinished(''); // servidor encerrou ou Disconnect local
    on E: Exception do
      FClient.ReaderFinished(E.Message);
  end;
end;

{ TNamedPipeClient }

constructor TNamedPipeClient.Create(const APipeName: string);
begin
  inherited Create(APipeName);
  FWriteLock := TCriticalSection.Create;
end;

destructor TNamedPipeClient.Destroy;
begin
  try
    Disconnect; // idempotente
  except
  end;
  FWriteLock.Free;
  inherited;
end;

function TNamedPipeClient.GetActive: Boolean;
begin
  Result := FConnected;
end;

procedure TNamedPipeClient.Connect(ATimeoutMs: Cardinal);
begin
  Disconnect; // encerra/limpa sessao anterior (viva ou morta); idempotente
  SetupDispatch;
  try
    FEndpoint := PipeConnect(PipeName, ATimeoutMs);
  except
    TeardownDispatch;
    raise;
  end;
  FStream := TPipeEndpointStream.Create(FEndpoint);
  PipeAtomicSet(FDeliberate, 0);
  PipeAtomicSet(FDisconnectNotified, 0);
  FConnected := True;
  FReader := TPipeClientReaderThread.Create(Self);
  DispatchConnEvent(FOnConnected, 0);
end;

procedure TNamedPipeClient.Disconnect;
var
  LHadSession: Boolean;
begin
  LHadSession := Assigned(FEndpoint);
  PipeAtomicSet(FDeliberate, 1);
  FConnected := False;
  if LHadSession then
    FEndpoint.CloseAbort; // desbloqueia o reader (e escritas em andamento)
  if Assigned(FReader) then
  begin
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  if LHadSession then
    NotifyDisconnectedOnce;
  DrainInFlight;
  TeardownDispatch;
  // Sob o write lock: um SendBytes concorrente ou termina antes ou ja ve
  // FConnected=False; nunca escreve num stream liberado.
  FWriteLock.Enter;
  try
    FreeAndNil(FStream);
    FreeAndNil(FEndpoint);
  finally
    FWriteLock.Leave;
  end;
end;

procedure TNamedPipeClient.NotifyDisconnectedOnce;
begin
  if PipeAtomicCompareExchange(FDisconnectNotified, 1, 0) = 0 then
    DispatchConnEvent(FOnDisconnected, 0);
end;

procedure TNamedPipeClient.ReaderFinished(const AError: string);
begin
  FConnected := False;
  if PipeAtomicGet(FDeliberate) <> 0 then
    Exit; // Disconnect deliberado: quem notifica e' o proprio Disconnect
  if AError <> '' then
    DispatchError(0, AError);
  NotifyDisconnectedOnce;
end;

procedure TNamedPipeClient.HandleFrame(const AFrame: TPipeFrame);
begin
  case AFrame.Kind of
    pfkMessage:
      DispatchMessage(0, AFrame.Payload);
    pfkPing:
      ; // reservado
    pfkRequest, pfkReply:
      ; // request-reply chega no milestone M6
  end;
end;

procedure TNamedPipeClient.SendBytes(const AData: TBytes);
begin
  FWriteLock.Enter;
  try
    if (not FConnected) or (FStream = nil) then
      raise EPipeClosed.Create('cliente nao esta conectado');
    PipeWriteFrame(FStream, TPipeFrame.Msg(AData), MaxMessageSize);
  finally
    FWriteLock.Leave;
  end;
end;

procedure TNamedPipeClient.SendText(const AText: string);
begin
  SendBytes(PipeUtf8Encode(AText));
end;

end.
