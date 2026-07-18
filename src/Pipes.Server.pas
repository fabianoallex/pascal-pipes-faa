unit Pipes.Server;

{$I pipes.inc}

{ TPipeServer: servidor de Named Pipes multi-cliente.

  Threads:
    1 acceptor (TPipeAcceptorThread) + 1 reader por conexao
    (TPipeServerReaderThread) + pool de despacho (Pipes.Base).

  Invariantes de lock e posse (violar = deadlock/use-after-free):
  - FConnLock protege FConnections e FNextConnId. Ordem "de fora pra dentro":
    FConnLock -> write lock da conexao; nunca o inverso. Nenhum callback de
    usuario roda sob FConnLock.
  - Cada conexao tem refcount (FRefs): 1 do registro (FConnections) + 1
    transitorio por SendBytes em andamento. O objeto e' liberado quando zera.
  - REMOVER do dicionario e' o ato de POSSE do teardown: morte natural
    (reader), DisconnectClient e Stop disputam pela remocao sob FConnLock;
    so quem removeu faz CloseAbort/join/Release — nunca ha dois teardowns
    da mesma conexao.
  - Morte natural: o reader nao pode dar join em si mesmo, entao remove a
    conexao, despacha OnClientDisconnected e enfileira a limpeza (join do
    reader + Release) no pool GLOBAL, contada em FInFlight — Stop/Destroy
    esperam por ela no DrainInFlight.
  - Stop e' sincrono: fecha listener -> join do acceptor -> CloseAbort de
    todas as conexoes -> join dos readers -> DrainInFlight -> libera.
    NAO chame Stop/Destroy de dentro de um callback do proprio servidor.
  - DisconnectClient e' ASSINCRONO (CloseAbort + limpeza no pool): pode ser
    chamado ate de dentro de um callback da propria conexao.
  - Broadcast tira um snapshot das conexoes sob FConnLock (com AddRef) e
    envia FORA do lock: um cliente lento nao trava a lista nem os demais.
  - OnRequest roda SEMPRE no pool (global ou serializado), nunca na main
    thread mesmo em pdmMainThread: o reply e' enviado pelo proprio worker ao
    fim do handler e nao pode ficar atras do loop de mensagens. Excecao no
    handler (ou handler ausente) vira reply de erro (PIPE_FLAG_ERROR) — o
    Request do cliente levanta EPipeError com a mensagem. }

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
  TPipeServer = class;

  { Conexao aceita (interna; a API publica enxerga so o TPipeConnectionId). }
  TPipeServerConnection = class
  private
    FServer: TPipeServer;
    FId: TPipeConnectionId;
    FEndpoint: TPipeEndpoint;
    FStream: TPipeEndpointStream;
    FReader: TThread;
    FWriteLock: TCriticalSection;
    FRefs: Integer;
    procedure AddRef;
    procedure Release; // libera o objeto quando zera
    procedure StartReader;
    procedure SendFrame(const AFrame: TPipeFrame);
  public
    constructor Create(AServer: TPipeServer; AId: TPipeConnectionId;
      AEndpoint: TPipeEndpoint);
    destructor Destroy; override;
    property Id: TPipeConnectionId read FId;
  end;

  TPipeServer = class(TPipeBase)
  private
    FListener: TPipeListener;
    FAcceptor: TThread;
    FConnections: TDictionary<TPipeConnectionId, TPipeServerConnection>;
    FConnLock: TCriticalSection;
    FNextConnId: TPipeConnectionId; // sob FConnLock
    FActive: Boolean;
    FStopping: Integer; // atomico
    FMaxClients: Integer;
    FOnClientConnected: TPipeConnectionEvent;
    FOnClientDisconnected: TPipeConnectionEvent;
    FOnRequest: TPipeRequestEvent;
    // Chamados pelas threads/works internos (mesma unit):
    procedure HandleAccepted(AEndpoint: TPipeEndpoint);
    procedure AcceptorFinished(const AError: string);
    procedure ReaderFinished(AConn: TPipeServerConnection; const AError: string);
    procedure HandleFrame(AConn: TPipeServerConnection; const AFrame: TPipeFrame);
    /// Remove a conexao do dicionario (ato de posse). False se outro teardown
    /// (Stop/DisconnectClient/morte natural) chegou antes.
    function TakeConnection(AConn: TPipeServerConnection): Boolean;
    procedure QueueCleanup(AConn: TPipeServerConnection);
    procedure RunCleanup(AConn: TPipeServerConnection); // roda no pool global
    procedure DispatchRequest(AConn: TPipeServerConnection; ACorrId: UInt64;
      const AData: TBytes);
    procedure ExecuteRequest(AConn: TPipeServerConnection; ACorrId: UInt64;
      const AData: TBytes; ACallback: TPipeRequestEvent); // roda no pool
  protected
    function GetActive: Boolean; override;
  public
    constructor Create(const AAddress: string);
    destructor Destroy; override;
    /// Nao-blocante: cria o listener e sobe a acceptor thread.
    procedure Listen;
    /// Sincrono e idempotente: para tudo e espera callbacks em voo.
    procedure Stop;
    procedure SendBytes(AConnId: TPipeConnectionId; const AData: TBytes);
    procedure SendText(AConnId: TPipeConnectionId; const AText: string);
    /// Envia a todos os clientes conectados. Falha de envio a UM cliente e'
    /// ignorada (a desconexao dele sera notificada pelo proprio reader).
    procedure Broadcast(const AData: TBytes);
    procedure BroadcastText(const AText: string);
    /// Assincrono e idempotente: aborta a conexao; a limpeza roda no pool.
    procedure DisconnectClient(AConnId: TPipeConnectionId);
    function ClientCount: Integer;
    function ClientIds: TArray<TPipeConnectionId>;
    property MaxClients: Integer read FMaxClients write FMaxClients; // 0 = sem teto
    property OnClientConnected: TPipeConnectionEvent
      read FOnClientConnected write FOnClientConnected;
    property OnClientDisconnected: TPipeConnectionEvent
      read FOnClientDisconnected write FOnClientDisconnected;
    /// Request-reply: o retorno em AReply vira o frame de resposta (mesmo
    /// corrId), enviado pelo worker ao fim do handler. Roda sempre no pool.
    property OnRequest: TPipeRequestEvent read FOnRequest write FOnRequest;
  end;

  /// Alias de compatibilidade (ver TNamedPipeBase em Pipes.Base).
  TNamedPipeServer = TPipeServer;

implementation

type
  TPipeAcceptorThread = class(TThread)
  private
    FServer: TPipeServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TPipeServer);
  end;

  TPipeServerReaderThread = class(TThread)
  private
    FConn: TPipeServerConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(AConn: TPipeServerConnection);
  end;

  { Limpeza pos-morte de uma conexao cujo teardown pertence a um work item
    (morte natural/DisconnectClient): join do reader + Release do registro. }
  TPipeConnCleanupWork = class(TPipeWorkItem)
  private
    FServer: TPipeServer;
    FConn: TPipeServerConnection;
  public
    constructor Create(AServer: TPipeServer; AConn: TPipeServerConnection);
    procedure Execute; override;
  end;

  { Um request em execucao: handler + envio do reply, no pool. }
  TPipeRequestWork = class(TPipeWorkItem)
  private
    FServer: TPipeServer;
    FConn: TPipeServerConnection; // AddRef feito no despacho
    FCorrId: UInt64;
    FData: TBytes;
    FCallback: TPipeRequestEvent; // capturado no despacho (pode ser nil)
  public
    constructor Create(AServer: TPipeServer; AConn: TPipeServerConnection;
      ACorrId: UInt64; const AData: TBytes; ACallback: TPipeRequestEvent);
    procedure Execute; override;
  end;

{ TPipeAcceptorThread }

constructor TPipeAcceptorThread.Create(AServer: TPipeServer);
begin
  FServer := AServer;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPipeAcceptorThread.Execute;
var
  LEndpoint: TPipeEndpoint;
begin
  try
    while True do
    begin
      LEndpoint := FServer.FListener.Accept;
      if LEndpoint = nil then
        Break; // listener fechado (Stop)
      FServer.HandleAccepted(LEndpoint);
    end;
    FServer.AcceptorFinished('');
  except
    on E: Exception do
      FServer.AcceptorFinished(E.Message);
  end;
end;

{ TPipeServerReaderThread }

constructor TPipeServerReaderThread.Create(AConn: TPipeServerConnection);
begin
  FConn := AConn;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPipeServerReaderThread.Execute;
var
  LFrame: TPipeFrame;
begin
  try
    while True do
    begin
      LFrame := PipeReadFrame(FConn.FStream, FConn.FServer.MaxMessageSize);
      FConn.FServer.HandleFrame(FConn, LFrame);
    end;
  except
    on EPipeClosed do
      FConn.FServer.ReaderFinished(FConn, ''); // desconexao (normal)
    on E: Exception do
      FConn.FServer.ReaderFinished(FConn, E.Message); // erro de protocolo etc.
  end;
end;

{ TPipeConnCleanupWork }

constructor TPipeConnCleanupWork.Create(AServer: TPipeServer;
  AConn: TPipeServerConnection);
begin
  inherited Create;
  FServer := AServer;
  FConn := AConn;
end;

procedure TPipeConnCleanupWork.Execute;
begin
  FServer.RunCleanup(FConn);
end;

{ TPipeRequestWork }

constructor TPipeRequestWork.Create(AServer: TPipeServer;
  AConn: TPipeServerConnection; ACorrId: UInt64; const AData: TBytes;
  ACallback: TPipeRequestEvent);
begin
  inherited Create;
  FServer := AServer;
  FConn := AConn;
  FCorrId := ACorrId;
  FData := AData;
  FCallback := ACallback;
end;

procedure TPipeRequestWork.Execute;
begin
  FServer.ExecuteRequest(FConn, FCorrId, FData, FCallback);
end;

{ TPipeServerConnection }

constructor TPipeServerConnection.Create(AServer: TPipeServer;
  AId: TPipeConnectionId; AEndpoint: TPipeEndpoint);
begin
  inherited Create;
  FServer := AServer;
  FId := AId;
  FEndpoint := AEndpoint;
  FStream := TPipeEndpointStream.Create(AEndpoint);
  FWriteLock := TCriticalSection.Create;
  FRefs := 1; // referencia do registro (FConnections)
end;

destructor TPipeServerConnection.Destroy;
begin
  // FReader ja foi joinado e liberado por quem possuiu o teardown.
  FStream.Free;
  FEndpoint.Free;
  FWriteLock.Free;
  inherited;
end;

procedure TPipeServerConnection.AddRef;
begin
  PipeAtomicInc(FRefs);
end;

procedure TPipeServerConnection.Release;
begin
  if PipeAtomicDec(FRefs) = 0 then
    Free;
end;

procedure TPipeServerConnection.StartReader;
begin
  FReader := TPipeServerReaderThread.Create(Self);
end;

procedure TPipeServerConnection.SendFrame(const AFrame: TPipeFrame);
begin
  FWriteLock.Enter;
  try
    PipeWriteFrame(FStream, AFrame, FServer.MaxMessageSize);
  finally
    FWriteLock.Leave;
  end;
end;

{ TPipeServer }

constructor TPipeServer.Create(const AAddress: string);
begin
  inherited Create(AAddress);
  FConnections := TDictionary<TPipeConnectionId, TPipeServerConnection>.Create;
  FConnLock := TCriticalSection.Create;
end;

destructor TPipeServer.Destroy;
begin
  try
    Stop; // idempotente
  except
  end;
  FConnections.Free;
  FConnLock.Free;
  inherited;
end;

function TPipeServer.GetActive: Boolean;
begin
  Result := FActive;
end;

procedure TPipeServer.Listen;
begin
  if FActive then
    raise EPipeError.Create('servidor ja esta ativo');
  SetupDispatch;
  try
    FListener := PipeCreateListener(Address);
  except
    TeardownDispatch;
    raise;
  end;
  PipeAtomicSet(FStopping, 0);
  FActive := True;
  FAcceptor := TPipeAcceptorThread.Create(Self);
end;

procedure TPipeServer.Stop;
var
  LConns: TArray<TPipeServerConnection>;
  LConn: TPipeServerConnection;
begin
  if not FActive then
    Exit;
  PipeAtomicSet(FStopping, 1);

  // 1) para de aceitar: fecha o listener e espera o acceptor.
  FListener.Close;
  FAcceptor.WaitFor;
  FreeAndNil(FAcceptor);
  FreeAndNil(FListener);

  // 2) toma posse de todas as conexoes restantes.
  FConnLock.Enter;
  try
    LConns := FConnections.Values.ToArray;
    FConnections.Clear;
  finally
    FConnLock.Leave;
  end;

  // 3) aborta todas (desbloqueia os readers) e so entao faz os joins:
  //    o abort em lote evita esperar cada leitura serialmente.
  for LConn in LConns do
    LConn.FEndpoint.CloseAbort;
  for LConn in LConns do
  begin
    LConn.FReader.WaitFor;
    FreeAndNil(LConn.FReader);
    DispatchConnEvent(FOnClientDisconnected, LConn.FId);
    LConn.Release; // referencia do registro
  end;

  // 4) espera callbacks em voo (inclui limpezas de mortes naturais anteriores).
  DrainInFlight;
  TeardownDispatch;
  FActive := False;
end;

procedure TPipeServer.HandleAccepted(AEndpoint: TPipeEndpoint);
var
  LConn: TPipeServerConnection;
  LId: TPipeConnectionId;
begin
  if PipeAtomicGet(FStopping) <> 0 then
  begin
    AEndpoint.CloseAbort;
    AEndpoint.Free;
    Exit;
  end;
  LConn := nil;
  LId := 0;
  FConnLock.Enter;
  try
    if (FMaxClients <= 0) or (FConnections.Count < FMaxClients) then
    begin
      Inc(FNextConnId);
      LId := FNextConnId;
      LConn := TPipeServerConnection.Create(Self, LId, AEndpoint);
      FConnections.Add(LId, LConn);
    end;
  finally
    FConnLock.Leave;
  end;
  if LConn = nil then
  begin
    AEndpoint.CloseAbort;
    AEndpoint.Free;
    DispatchError(0, 'conexao recusada: MaxClients atingido');
    Exit;
  end;
  // Conectado antes do reader partir: no pdmSerialized, OnClientConnected
  // fica garantidamente ANTES do primeiro OnMessage desta conexao.
  DispatchConnEvent(FOnClientConnected, LId);
  LConn.StartReader;
end;

procedure TPipeServer.AcceptorFinished(const AError: string);
begin
  // Acceptor caiu com o servidor ativo (ex.: CreateNamedPipe falhou): o
  // servidor para de aceitar novos clientes, mas os conectados seguem; o
  // usuario decide (Stop/Listen de novo) a partir do OnError.
  if (AError <> '') and (PipeAtomicGet(FStopping) = 0) then
    DispatchError(0, 'acceptor encerrado: ' + AError);
end;

procedure TPipeServer.ReaderFinished(AConn: TPipeServerConnection;
  const AError: string);
begin
  if not TakeConnection(AConn) then
    Exit; // Stop/DisconnectClient ja possuem este teardown
  if AError <> '' then
    DispatchError(AConn.FId, AError);
  AConn.FEndpoint.CloseAbort; // erro de protocolo: transporte pode estar vivo
  DispatchConnEvent(FOnClientDisconnected, AConn.FId);
  QueueCleanup(AConn); // join deste proprio reader: precisa de outra thread
end;

procedure TPipeServer.HandleFrame(AConn: TPipeServerConnection;
  const AFrame: TPipeFrame);
begin
  case AFrame.Kind of
    pfkMessage:
      DispatchMessage(AConn.FId, AFrame.Payload);
    pfkRequest:
      DispatchRequest(AConn, AFrame.CorrId, AFrame.Payload);
    pfkPing, pfkReply:
      ; // ping: reservado; reply: servidor nao faz requests na v1
  end;
end;

procedure TPipeServer.DispatchRequest(AConn: TPipeServerConnection;
  ACorrId: UInt64; const AData: TBytes);
begin
  // Mesmo sem handler o work roda (para responder com erro ao cliente).
  AConn.AddRef; // o work escreve o reply nesta conexao
  IncInFlight;
  EventPool.Queue(TPipeRequestWork.Create(Self, AConn, ACorrId, AData, FOnRequest));
end;

procedure TPipeServer.ExecuteRequest(AConn: TPipeServerConnection;
  ACorrId: UInt64; const AData: TBytes; ACallback: TPipeRequestEvent);
var
  LReply: TBytes;
  LErr: string;
begin
  try
    LReply := nil;
    LErr := '';
    if Assigned(ACallback) then
      try
        ACallback(Self, AConn.FId, AData, LReply);
      except
        on E: Exception do
          LErr := E.Message; // excecao do handler vira reply de erro
      end
    else
      LErr := 'servidor sem handler OnRequest';
    try
      if LErr <> '' then
        AConn.SendFrame(TPipeFrame.ErrorReply(ACorrId, LErr))
      else
        AConn.SendFrame(TPipeFrame.Reply(ACorrId, LReply));
    except
      // conexao caiu antes do reply: o cliente ja vai receber EPipeClosed
    end;
  finally
    AConn.Release;
    DecInFlight;
  end;
end;

function TPipeServer.TakeConnection(AConn: TPipeServerConnection): Boolean;
var
  LCur: TPipeServerConnection;
begin
  FConnLock.Enter;
  try
    Result := FConnections.TryGetValue(AConn.FId, LCur) and (LCur = AConn);
    if Result then
      FConnections.Remove(AConn.FId);
  finally
    FConnLock.Leave;
  end;
end;

procedure TPipeServer.QueueCleanup(AConn: TPipeServerConnection);
begin
  // Sempre no pool GLOBAL: nao pode entrar atras de callbacks do usuario no
  // pool serializado. Contada em FInFlight para o Stop/Destroy esperarem.
  IncInFlight;
  PipePool.Queue(TPipeConnCleanupWork.Create(Self, AConn));
end;

procedure TPipeServer.RunCleanup(AConn: TPipeServerConnection);
begin
  try
    if Assigned(AConn.FReader) then
    begin
      AConn.FReader.WaitFor;
      FreeAndNil(AConn.FReader);
    end;
    AConn.Release; // referencia do registro
  finally
    DecInFlight;
  end;
end;

procedure TPipeServer.SendBytes(AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LConn: TPipeServerConnection;
begin
  FConnLock.Enter;
  try
    if FConnections.TryGetValue(AConnId, LConn) then
      LConn.AddRef // segura o objeto durante a escrita (fora do lock)
    else
      LConn := nil;
  finally
    FConnLock.Leave;
  end;
  if LConn = nil then
    raise EPipeError.Create('cliente ' + IntToStr(Int64(AConnId)) +
      ' nao esta conectado');
  try
    LConn.SendFrame(TPipeFrame.Msg(AData));
  finally
    LConn.Release;
  end;
end;

procedure TPipeServer.SendText(AConnId: TPipeConnectionId;
  const AText: string);
begin
  SendBytes(AConnId, PipeUtf8Encode(AText));
end;

procedure TPipeServer.Broadcast(const AData: TBytes);
var
  LConns: TArray<TPipeServerConnection>;
  LConn: TPipeServerConnection;
begin
  // Snapshot com AddRef sob o lock; envio fora dele (cliente lento nao trava
  // a lista) sob o write lock individual de cada conexao.
  FConnLock.Enter;
  try
    LConns := FConnections.Values.ToArray;
    for LConn in LConns do
      LConn.AddRef;
  finally
    FConnLock.Leave;
  end;
  for LConn in LConns do
  begin
    try
      try
        LConn.SendFrame(TPipeFrame.Msg(AData));
      except
        // conexao caindo: o reader dela notificara; o broadcast segue
      end;
    finally
      LConn.Release;
    end;
  end;
end;

procedure TPipeServer.BroadcastText(const AText: string);
begin
  Broadcast(PipeUtf8Encode(AText));
end;

procedure TPipeServer.DisconnectClient(AConnId: TPipeConnectionId);
var
  LConn: TPipeServerConnection;
begin
  FConnLock.Enter;
  try
    if not FConnections.TryGetValue(AConnId, LConn) then
      Exit; // ja desconectado: idempotente
    FConnections.Remove(AConnId); // posse do teardown
  finally
    FConnLock.Leave;
  end;
  LConn.FEndpoint.CloseAbort; // o reader vai cair com EPipeClosed
  DispatchConnEvent(FOnClientDisconnected, AConnId);
  QueueCleanup(LConn);
end;

function TPipeServer.ClientCount: Integer;
begin
  FConnLock.Enter;
  try
    Result := FConnections.Count;
  finally
    FConnLock.Leave;
  end;
end;

function TPipeServer.ClientIds: TArray<TPipeConnectionId>;
begin
  FConnLock.Enter;
  try
    Result := FConnections.Keys.ToArray;
  finally
    FConnLock.Leave;
  end;
end;

end.
