unit Pipes.Client;

{$I pipes.inc}

{ TPipeClient: cliente de Named Pipes (uma conexao).

  Threads: 1 reader (TPipeClientReaderThread) + pool de despacho (Pipes.Base)
  + 1 thread efemera de reconexao (TPipeReconnectThread, FreeOnTerminate),
  quando AutoReconnect esta ligado.

  Invariantes:
  - FWriteLock serializa as escritas E protege FStream/FEndpoint contra o
    free/troca (Disconnect e reconexao so mexem nos objetos sob o lock).
  - Disconnect e' sincrono e idempotente: encerra a reconexao em curso ->
    CloseAbort -> join do reader -> OnDisconnected -> DrainInFlight ->
    libera. NAO chamar de dentro de um callback do proprio cliente.
  - OnDisconnected dispara UMA vez por sessao (CAS em FDisconnectNotified);
    cada reconexao bem-sucedida dispara OnConnected de novo.
  - Request (sincrono) usa o padrao RPC do pascal-amqp-faa: slot com TEvent
    por corrId (FRpcSlots sob FRpcLock); a thread de leitura resolve o slot
    SOB FRpcLock (sem codigo de usuario) e o chamador, ao acordar, REMOVE o
    slot antes de le-lo — depois da remocao o reader nao o encontra mais.
    Queda da conexao falha os slots pendentes (EPipeClosed no chamador);
    reply de erro do servidor (PIPE_FLAG_ERROR) vira EPipeError.
  - Reconexao: o reader que morre dispara a thread de reconexao (CAS em
    FReconnecting garante uma so); cada tentativa e' um PipeConnect com
    timeout = ReconnectDelayMs. Disconnect/Connect/Destroy esperam a
    reconexao em curso terminar (spin em FReconnecting). }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Transport,
  Pipes.Base;

type
  TPipeClient = class(TPipeBase)
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
    // --- request-reply ---
    FRpcLock: TCriticalSection;
    FRpcSlots: TDictionary<UInt64, TObject>; // corrId -> TPipeRpcSlot
    FCorrSeq: Integer;                       // atomico
    // --- reconexao ---
    FAutoReconnect: Boolean;
    FReconnectDelayMs: Cardinal;
    FMaxReconnectAttempts: Integer; // 0 = infinitas
    FReconnecting: Integer;         // atomico: 1 com thread de reconexao viva
    // Chamados pelas threads internas (mesma unit):
    procedure ReaderFinished(const AError: string);
    procedure HandleFrame(const AFrame: TPipeFrame);
    procedure NotifyDisconnectedOnce;
    procedure ResolveRpc(const AFrame: TPipeFrame);
    procedure FailPendingRpc;
    function TryReopenSession: Boolean; // roda na thread de reconexao
    procedure WaitReconnectDone;
  protected
    function GetActive: Boolean; override;
  public
    constructor Create(const AAddress: string);
    destructor Destroy; override;
    /// Conecta (re-tentando ate ATimeoutMs; EPipeTimeout no prazo). Se havia
    /// uma sessao anterior (viva ou morta), e' encerrada antes.
    procedure Connect(ATimeoutMs: Cardinal = 5000);
    /// Sincrono e idempotente.
    procedure Disconnect;
    procedure SendBytes(const AData: TBytes);
    procedure SendText(const AText: string);
    /// Request-reply sincrono: bloqueia o CHAMADOR (nunca a thread de
    /// leitura) ate o reply, EPipeTimeout no prazo, EPipeError se o servidor
    /// respondeu com erro (excecao no OnRequest ou handler ausente),
    /// EPipeClosed se a conexao caiu no meio.
    function Request(const AData: TBytes; ATimeoutMs: Cardinal = 30000): TBytes;
    function RequestText(const AText: string; ATimeoutMs: Cardinal = 30000): string;
    property Connected: Boolean read GetActive;
    property AutoReconnect: Boolean read FAutoReconnect write FAutoReconnect;
    property ReconnectDelayMs: Cardinal read FReconnectDelayMs write FReconnectDelayMs;
    property MaxReconnectAttempts: Integer
      read FMaxReconnectAttempts write FMaxReconnectAttempts;
    property OnConnected: TPipeConnectionEvent
      read FOnConnected write FOnConnected;
    property OnDisconnected: TPipeConnectionEvent
      read FOnDisconnected write FOnDisconnected;
  end;

  /// Alias de compatibilidade (ver TNamedPipeBase em Pipes.Base).
  TNamedPipeClient = TPipeClient;

implementation

type
  { Slot de um Request pendente. Posse: o CHAMADOR cria, registra, remove e
    libera; o reader so preenche/sinaliza enquanto o slot esta no dicionario
    (sempre sob FRpcLock). }
  TPipeRpcSlot = class
  public
    Event: TEvent; // manual-reset
    Data: TBytes;
    Ok: Boolean;
    IsError: Boolean;  // reply com PIPE_FLAG_ERROR
    ErrorMsg: string;
    Closed: Boolean;   // conexao caiu antes do reply
    constructor Create;
    destructor Destroy; override;
  end;

  TPipeClientReaderThread = class(TThread)
  private
    FClient: TPipeClient;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TPipeClient);
  end;

  { Thread efemera de reconexao (padrao TAMQPReconnectThread). }
  TPipeReconnectThread = class(TThread)
  private
    FClient: TPipeClient;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TPipeClient);
  end;

{ TPipeRpcSlot }

constructor TPipeRpcSlot.Create;
begin
  inherited Create;
  Event := TEvent.Create(nil, True, False, '');
end;

destructor TPipeRpcSlot.Destroy;
begin
  Event.Free;
  inherited;
end;

{ TPipeClientReaderThread }

constructor TPipeClientReaderThread.Create(AClient: TPipeClient);
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

{ TPipeReconnectThread }

constructor TPipeReconnectThread.Create(AClient: TPipeClient);
begin
  FClient := AClient;
  FreeOnTerminate := True; // se auto-libera; quem sincroniza e' FReconnecting
  inherited Create(False);
end;

procedure TPipeReconnectThread.Execute;
var
  LAttempts: Integer;
begin
  LAttempts := 0;
  while PipeAtomicGet(FClient.FDeliberate) = 0 do
  begin
    if FClient.TryReopenSession then
    begin
      // TryReopenSession zera FReconnecting DEPOIS de a sessao estar completa
      // (reader criado). Se a sessao nova ja caiu neste intervalo, o CAS
      // retoma o loop — sem ele a queda instantanea perderia a reconexao.
      if (PipeAtomicGet(FClient.FDeliberate) = 0) and
         (not FClient.FConnected) and
         (PipeAtomicCompareExchange(FClient.FReconnecting, 1, 0) = 0) then
        Continue;
      Exit;
    end;
    Inc(LAttempts);
    if (FClient.FMaxReconnectAttempts > 0) and
       (LAttempts >= FClient.FMaxReconnectAttempts) then
    begin
      FClient.DispatchError(0, 'reconexao esgotada apos ' +
        IntToStr(LAttempts) + ' tentativas');
      Break;
    end;
  end;
  PipeAtomicSet(FClient.FReconnecting, 0); // desistiu (deliberado ou esgotado)
end;

{ TPipeClient }

constructor TPipeClient.Create(const AAddress: string);
begin
  inherited Create(AAddress);
  FWriteLock := TCriticalSection.Create;
  FRpcLock := TCriticalSection.Create;
  FRpcSlots := TDictionary<UInt64, TObject>.Create;
  FReconnectDelayMs := 2000;
end;

destructor TPipeClient.Destroy;
begin
  try
    Disconnect; // idempotente
  except
  end;
  FRpcSlots.Free; // vazio: cada Request remove e libera o proprio slot
  FRpcLock.Free;
  FWriteLock.Free;
  inherited;
end;

function TPipeClient.GetActive: Boolean;
begin
  Result := FConnected;
end;

procedure TPipeClient.WaitReconnectDone;
begin
  // FDeliberate ja esta em 1: a thread de reconexao desiste no proximo passo
  // (pior caso: espera um PipeConnect de ate ReconnectDelayMs terminar).
  while PipeAtomicGet(FReconnecting) <> 0 do
    Sleep(5);
end;

procedure TPipeClient.Connect(ATimeoutMs: Cardinal);
begin
  Disconnect; // encerra/limpa sessao anterior (viva ou morta); idempotente
  SetupDispatch;
  try
    FEndpoint := PipeConnect(Address, ATimeoutMs);
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

procedure TPipeClient.Disconnect;
var
  LHadSession: Boolean;
begin
  PipeAtomicSet(FDeliberate, 1);
  WaitReconnectDone; // depois disto, so esta thread mexe na sessao
  LHadSession := Assigned(FEndpoint);
  FConnected := False;
  if LHadSession then
    FEndpoint.CloseAbort; // desbloqueia o reader (e escritas em andamento)
  if Assigned(FReader) then
  begin
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  FailPendingRpc; // acorda Requests pendentes com EPipeClosed
  if LHadSession then
    NotifyDisconnectedOnce;
  DrainInFlight;
  TeardownDispatch;
  // Sob o write lock: um SendBytes/Request concorrente ou termina antes ou
  // ja ve FConnected=False; nunca escreve num stream liberado.
  FWriteLock.Enter;
  try
    FreeAndNil(FStream);
    FreeAndNil(FEndpoint);
  finally
    FWriteLock.Leave;
  end;
end;

function TPipeClient.TryReopenSession: Boolean;
var
  LEndpoint: TPipeEndpoint;
begin
  Result := False;
  if PipeAtomicGet(FDeliberate) <> 0 then
    Exit;
  // Limpa a sessao morta (o reader que disparou a reconexao ja esta saindo).
  if Assigned(FReader) then
  begin
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  FWriteLock.Enter;
  try
    FreeAndNil(FStream);
    FreeAndNil(FEndpoint);
  finally
    FWriteLock.Leave;
  end;
  try
    // O proprio PipeConnect re-tenta ate ReconnectDelayMs: e' o espacamento
    // entre tentativas (nao ha Sleep adicional).
    LEndpoint := PipeConnect(Address, FReconnectDelayMs);
  except
    on EPipeError do
      Exit; // inclui EPipeTimeout: proxima tentativa (ou desiste no teto)
  end;
  if PipeAtomicGet(FDeliberate) <> 0 then
  begin
    LEndpoint.CloseAbort;
    LEndpoint.Free;
    Exit;
  end;
  FWriteLock.Enter;
  try
    FEndpoint := LEndpoint;
    FStream := TPipeEndpointStream.Create(LEndpoint);
  finally
    FWriteLock.Leave;
  end;
  PipeAtomicSet(FDisconnectNotified, 0);
  FConnected := True;
  FReader := TPipeClientReaderThread.Create(Self);
  DispatchConnEvent(FOnConnected, 0);
  // So DEPOIS de a sessao estar completa (FReader atribuido): e' este flag
  // que libera o WaitReconnectDone do Disconnect — zera-lo antes deixaria o
  // Disconnect correr em paralelo com a montagem da sessao.
  PipeAtomicSet(FReconnecting, 0);
  Result := True;
end;

procedure TPipeClient.NotifyDisconnectedOnce;
begin
  if PipeAtomicCompareExchange(FDisconnectNotified, 1, 0) = 0 then
    DispatchConnEvent(FOnDisconnected, 0);
end;

procedure TPipeClient.ReaderFinished(const AError: string);
begin
  FConnected := False;
  FailPendingRpc; // Requests pendentes acordam com EPipeClosed
  if PipeAtomicGet(FDeliberate) <> 0 then
    Exit; // Disconnect deliberado: quem notifica e' o proprio Disconnect
  if AError <> '' then
    DispatchError(0, AError);
  NotifyDisconnectedOnce;
  if FAutoReconnect and
     (PipeAtomicCompareExchange(FReconnecting, 1, 0) = 0) then
    TPipeReconnectThread.Create(Self);
end;

procedure TPipeClient.HandleFrame(const AFrame: TPipeFrame);
begin
  case AFrame.Kind of
    pfkMessage:
      DispatchMessage(0, AFrame.Payload);
    pfkReply:
      ResolveRpc(AFrame); // sob FRpcLock, sem codigo de usuario: pode rodar aqui
    pfkPing, pfkRequest:
      ; // ping: reservado; request: servidor -> cliente fora da v1
  end;
end;

procedure TPipeClient.ResolveRpc(const AFrame: TPipeFrame);
var
  LObj: TObject;
  LSlot: TPipeRpcSlot;
begin
  FRpcLock.Enter;
  try
    if not FRpcSlots.TryGetValue(AFrame.CorrId, LObj) then
      Exit; // reply tardio de um Request que ja desistiu (timeout): descarta
    LSlot := TPipeRpcSlot(LObj);
    if AFrame.IsError then
    begin
      LSlot.IsError := True;
      LSlot.ErrorMsg := AFrame.PayloadAsText;
    end
    else
    begin
      LSlot.Data := AFrame.Payload;
      LSlot.Ok := True;
    end;
    LSlot.Event.SetEvent;
  finally
    FRpcLock.Leave;
  end;
end;

procedure TPipeClient.FailPendingRpc;
var
  LObj: TObject;
begin
  FRpcLock.Enter;
  try
    for LObj in FRpcSlots.Values do
    begin
      TPipeRpcSlot(LObj).Closed := True;
      TPipeRpcSlot(LObj).Event.SetEvent;
    end;
  finally
    FRpcLock.Leave;
  end;
end;

function TPipeClient.Request(const AData: TBytes;
  ATimeoutMs: Cardinal): TBytes;
var
  LCorrId: UInt64;
  LSlot: TPipeRpcSlot;
begin
  LCorrId := UInt64(Cardinal(PipeAtomicInc(FCorrSeq)));
  LSlot := TPipeRpcSlot.Create;
  try
    FRpcLock.Enter;
    try
      FRpcSlots.Add(LCorrId, LSlot);
    finally
      FRpcLock.Leave;
    end;
    try
      FWriteLock.Enter;
      try
        if (not FConnected) or (FStream = nil) then
          raise EPipeClosed.Create('cliente nao esta conectado');
        PipeWriteFrame(FStream, TPipeFrame.Request(LCorrId, AData), MaxMessageSize);
      finally
        FWriteLock.Leave;
      end;
    except
      FRpcLock.Enter;
      try
        FRpcSlots.Remove(LCorrId);
      finally
        FRpcLock.Leave;
      end;
      raise;
    end;
    LSlot.Event.WaitFor(ATimeoutMs);
    // Remove ANTES de ler: depois disto o reader nao encontra mais o slot.
    FRpcLock.Enter;
    try
      FRpcSlots.Remove(LCorrId);
    finally
      FRpcLock.Leave;
    end;
    if LSlot.IsError then
      raise EPipeError.Create('servidor respondeu erro: ' + LSlot.ErrorMsg);
    if LSlot.Ok then
      Exit(LSlot.Data); // inclui reply que chegou entre o timeout e a remocao
    if LSlot.Closed then
      raise EPipeClosed.Create('conexao encerrada durante o request');
    raise EPipeTimeout.CreateFmt('request sem resposta em %u ms', [ATimeoutMs]);
  finally
    LSlot.Free;
  end;
end;

function TPipeClient.RequestText(const AText: string;
  ATimeoutMs: Cardinal): string;
begin
  Result := PipeUtf8Decode(Request(PipeUtf8Encode(AText), ATimeoutMs));
end;

procedure TPipeClient.SendBytes(const AData: TBytes);
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

procedure TPipeClient.SendText(const AText: string);
begin
  SendBytes(PipeUtf8Encode(AText));
end;

end.
