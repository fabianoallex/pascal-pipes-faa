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
    Request do cliente levanta EPipeError com a mensagem.

  Pub/sub (topicos) — regra de ouro: TODA decisao de roteamento e' codigo
  PURO e roda na thread de leitura; os callbacks do usuario sao apenas
  NOTIFICACOES, despachadas ao pool depois de a decisao estar tomada.
  - Por que: se o relay de uma publicacao dependesse do retorno de um handler,
    ele teria de esperar o pool, e em pdmPool duas publicacoes do MESMO cliente
    poderiam ser retransmitidas fora de ordem — o transporte e' ordenado e a
    aplicacao tem o direito de contar com isso. Por isso RelayClientPublish e'
    um Boolean lido na hora, e nao um veto em OnPublish; quem quer decidir
    caso a caso deixa o relay desligado e chama Publish de dentro do handler,
    assumindo a ordem que escolher (FIFO garantida em pdmSerialized).
  - Mesma razao para OnSubscribe/OnUnsubscribe serem notificacoes: aplicar a
    assinatura no pool deixaria um Unsubscribe passar na frente do Subscribe
    que ele cancela. Quem quer negar uma assinatura chama DisconnectClient no
    OnSubscribe — o cliente que pede topico alheio nao merece meia-medida.
  - A lista de filtros vive na CONEXAO e e' protegida pelo FConnLock, nao por
    um lock proprio: assim o fanout tira o snapshot dos destinatarios no mesmo
    passo em que ja percorre FConnections (como Broadcast), sem inventar um
    terceiro nivel na ordem de locks. O casamento de topico e' CPU pura, sem
    IO e sem alocacao por segmento (ver Pipes.Topics).
  - Corolario: a assinatura morre com a conexao, no destructor dela. Nao ha
    registro global de onde desinscrever no teardown — e' o que impede a
    classe de vazamento silencioso que uma tabela topico->conexoes teria.
  - Frames de controle (subscribe/unsubscribe) e publicacoes chegadas do
    cliente sao tratados NA reader thread, o que inclui escrever de volta
    (recusa, ou valores retidos na hora da assinatura). Uma escrita presa ali
    atrasa a leitura daquela conexao e de nenhuma outra — mesma exposicao de
    qualquer envio servidor->cliente.

  Heartbeat de aplicacao (ptTcp/ptTls; ver Pipes.Base.HeartbeatIntervalMs):
  - Simetrico e sem correlacao — qualquer frame recebido (pfkPing incluso)
    reseta FLastReadTick; nao ha pfkPong nem estado de "ping em aberto".
  - TPipeHeartbeatThread (Pipes.Threading) roda por conexao, iniciada pela
    propria reader thread apos OnClientConnected. Detectar conexao morta
    (sem leitura ha' 2x o intervalo) chama FEndpoint.CloseAbort — o MESMO
    mecanismo thread-safe/idempotente que qualquer erro de protocolo ja usa
    (ver Pipes.Transport) — e deixa a reader thread cair e seguir o teardown
    normal. Nenhuma interrupcao nova foi inventada para isto.
  - StopHeartbeat roda nos MESMOS pontos que ja fazem o join de FReader
    (Stop e RunCleanup), nunca dentro do proprio HeartbeatTick — por isso
    Destroy nunca encontra a thread viva. }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Topics,
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
    // Heartbeat de aplicacao (ptTcp/ptTls; ver Pipes.Base.HeartbeatIntervalMs).
    // FHeartbeatThread/FHbStopEvent so existem entre StartHeartbeat e
    // StopHeartbeat (nil quando desligado ou antes de a conexao ser
    // estabelecida); StopHeartbeat e' chamada nos MESMOS pontos que ja fazem
    // o join de FReader (Stop e RunCleanup), entao Destroy nunca a encontra
    // viva.
    FLastReadTick: UInt64;
    FLastWriteTick: UInt64;
    FHeartbeatThread: TThread;
    FHbStopEvent: TEvent;
    // Conexao ESTABELECIDA: handshake concluido, prestes a disparar
    // OnClientConnected. Antes disso ela existe (ocupa vaga de MaxClients) mas
    // nao aparece em ClientIds/ClientCount — sob mTLS, uma conexao ainda
    // negociando pode nunca se autenticar, e contar como "cliente" um par que
    // sera' recusado e' o que fazia o painel piscar clientes fantasmas.
    // Escrito sob FConnLock pela reader thread; lido sob FConnLock.
    FEstablished: Boolean;
    // Filtros de topico assinados por este cliente. Criada sempre (custa um
    // objeto vazio por conexao) e SEMPRE acessada sob o FConnLock do servidor —
    // ver o cabecalho da unit. Morre no destructor junto com a conexao.
    FSubs: TList<string>;
    procedure AddRef;
    procedure Release; // libera o objeto quando zera
    procedure StartReader;
    procedure SendFrame(const AFrame: TPipeFrame);
    /// True se algum filtro assinado alcanca ATopic. Sob FConnLock.
    function MatchesTopic(const ATopic: string): Boolean;
    /// Chamada pela reader thread apos OnClientConnected. No-op se
    /// HeartbeatIntervalMs = 0 ou o transporte nao for ptTcp/ptTls.
    procedure StartHeartbeat;
    /// Chamada nos mesmos pontos que ja fazem o join de FReader. Idempotente
    /// (no-op se a heartbeat nunca foi iniciada).
    procedure StopHeartbeat;
    /// Callback do TPipeHeartbeatThread: manda Ping se ocioso na escrita,
    /// CloseAbort se sem NENHUM frame recebido ha' mais de 2x o intervalo.
    procedure HeartbeatTick;
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
    // Identidades dos clientes autenticados. SEPARADO de FConnections de
    // proposito: a conexao sai do registro ANTES de OnClientDisconnected
    // disparar (a remocao e' o ato de posse do teardown), entao um handler que
    // perguntasse "quem saiu?" nao teria resposta se a identidade morresse
    // junto com a conexao.
    //
    // Nao da' para liberar a entrada na limpeza da conexao: o evento e a
    // limpeza vao para filas diferentes (pool de eventos x pool global) e, em
    // pdmPool ou pdmMainThread, nao ha ordem garantida entre os dois — a
    // identidade poderia sumir antes do handler rodar. Por isso a entrada
    // sobrevive, e o que limita a memoria e' o teto abaixo.
    FIdentities: TDictionary<TPipeConnectionId, TPipePeerIdentity>;
    FIdentityOrder: TList<TPipeConnectionId>; // ordem de chegada, p/ despejo
    FConnLock: TCriticalSection;
    FNextConnId: TPipeConnectionId; // sob FConnLock
    FActive: Boolean;
    FStopping: Integer; // atomico
    FMaxClients: Integer;
    FOnClientConnected: TPipeConnectionEvent;
    FOnClientDisconnected: TPipeConnectionEvent;
    FOnRequest: TPipeRequestEvent;
    // --- pub/sub ---
    FRelayClientPublish: Boolean;
    FMaxSubscriptionsPerClient: Integer;
    FMaxRetained: Integer;
    // Ultimo valor publicado com PIPE_FLAG_RETAIN por topico, entregue a quem
    // assinar depois. Sob FConnLock (mesmo lock das assinaturas: a entrega dos
    // retidos e a inclusao do filtro acontecem no mesmo passo).
    FRetained: TDictionary<string, TBytes>;
    FRetainedOrder: TList<string>; // ordem de chegada, p/ despejo do mais antigo
    FOnPublish: TPipeTopicEvent;
    FOnSubscribe: TPipeSubscriptionEvent;
    FOnUnsubscribe: TPipeSubscriptionEvent;
    // Chamados pelas threads/works internos (mesma unit):
    procedure HandleAccepted(AEndpoint: TPipeEndpoint);
    /// Marca a conexao como estabelecida e captura a identidade do par, se
    /// houver. Chamada pela reader thread apos o Handshake, ANTES de
    /// OnClientConnected.
    procedure PublishEstablished(AConn: TPipeServerConnection);
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
    // --- pub/sub: tudo abaixo roda na READER thread da conexao ---
    procedure HandleSubscribe(AConn: TPipeServerConnection;
      const AFrame: TPipeFrame);
    procedure HandleUnsubscribe(AConn: TPipeServerConnection;
      const AFrame: TPipeFrame);
    procedure HandleClientPublish(AConn: TPipeServerConnection;
      const AFrame: TPipeFrame);
    /// Recusa um frame de controle: avisa o cliente (reply de erro com corrId 0,
    /// que o TPipeClient transforma em OnError) e o servidor (OnError local).
    /// Nao derruba a conexao: filtro invalido e' erro de uso, nao de protocolo.
    procedure RejectControl(AConn: TPipeServerConnection; const AReason: string);
    /// Entrega a AConn os valores retidos que casam com AFilter (snapshot sob
    /// FConnLock, envio fora dele).
    procedure SendRetained(AConn: TPipeServerConnection; const AFilter: string);
    procedure StoreRetained(const ATopic: string; const AData: TBytes);
    /// Envia a publicacao a todas as conexoes estabelecidas com filtro que
    /// casa. Mesma mecanica de Broadcast (snapshot sob lock, envio fora).
    ///
    /// Sai SEMPRE com PIPE_FLAG_RETAIN desligado, mesmo quando o publicador
    /// pediu para reter: no fio, esse bit responde "isto e' historico?" a quem
    /// recebe, e uma publicacao ao vivo nunca e' historico. Quem o liga e'
    /// SendRetained, o unico caminho que entrega valor guardado.
    procedure FanOut(const ATopic: string; const AData: TBytes);
  protected
    function GetActive: Boolean; override;
  public
    constructor Create(const AAddress: string;
      ATransport: TPipeTransport = ptLocal);
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
    /// Quantos clientes ESTABELECIDOS — aqueles para os quais
    /// OnClientConnected ja disparou e OnClientDisconnected ainda nao. Conexoes
    /// aceitas mas ainda negociando TLS nao entram: sob mTLS elas podem nunca
    /// se autenticar.
    ///
    /// Difere de MaxClients de proposito: aquele e' um limite de RECURSO e
    /// conta tambem as conexoes em negociacao, senao um par que nunca conclui
    /// o handshake nao ocuparia vaga nenhuma.
    function ClientCount: Integer;
    /// Ids dos clientes estabelecidos (mesmo criterio de ClientCount).
    function ClientIds: TArray<TPipeConnectionId>;
    /// Quem e' o cliente, segundo o certificado validado no handshake mTLS.
    /// False quando nao ha identidade verificada — sem TLS, ou com TLS sem
    /// mTLS. False NUNCA significa "ainda nao chegou": nao ha o que esperar.
    ///
    /// Continua respondendo DEPOIS de o cliente sair, entao um handler de
    /// OnClientDisconnected pode perguntar "quem saiu?". A identidade das
    /// ultimas PIPES_RECENT_IDENTITIES conexoes autenticadas fica retida; alem
    /// disso a mais antiga e' descartada.
    ///
    /// E' Try* e nao levanta como SendBytes porque o uso tipico e' varrer
    /// ClientIds e consultar cada um; entre as duas chamadas uma conexao pode
    /// cair, e uma excecao ali obrigaria try/except dentro do laco.
    function TryClientIdentity(AConnId: TPipeConnectionId;
      out AIdentity: TPipePeerIdentity): Boolean;
    // --- pub/sub ---------------------------------------------------------
    /// Publica em ATopic: entrega a TODOS os clientes cujo filtro assinado
    /// alcanca o topico, e a mais ninguem. Nome literal e hierarquico
    /// ('caixa.3.status'), sem curinga — quem usa curinga e' quem assina.
    /// EPipeError se o nome for invalido (ver PipeIsValidTopic).
    ///
    /// Sem assinante, a mensagem simplesmente nao vai a ninguem: nao ha fila,
    /// nao ha erro, nao ha o que reter — a menos que ARetain diga o contrario.
    ///
    /// ARetain guarda esta mensagem como ULTIMO VALOR do topico, entregue na
    /// hora a quem assinar dali em diante. Serve ao caso "o cliente que acabou
    /// de conectar precisa do estado atual" (versao da tabela de precos, ultimo
    /// status conhecido) sem que ele tenha de pedir. Corpo VAZIO com ARetain
    /// apaga o valor retido. Nao e' fila nem persistencia: e' um valor por
    /// topico, na memoria do processo, com teto em MaxRetained.
    procedure Publish(const ATopic: string; const AData: TBytes;
      ARetain: Boolean = False);
    procedure PublishText(const ATopic, AText: string;
      ARetain: Boolean = False);
    /// Quantos clientes estabelecidos receberiam uma publicacao em ATopic.
    function SubscriberCount(const ATopic: string): Integer;
    /// Filtros que o cliente assinou (vazio se ele saiu ou nunca assinou).
    function ClientSubscriptions(AConnId: TPipeConnectionId): TArray<string>;
    /// Descarta todos os valores retidos. Eles NAO morrem no Stop — o mesmo
    /// objeto servidor que sobe de novo continua servindo o que retinha, o que
    /// e' o desejavel num Stop/Listen de reconfiguracao e indesejavel se o
    /// estado tiver ficado obsoleto; ai e' aqui que se limpa.
    procedure ClearRetained;
    /// Retransmite automaticamente o que um CLIENTE publica para os demais
    /// assinantes (incluindo o proprio publicador, se ele assinar o topico —
    /// mesma semantica de um chat em que todos veem a sala inteira).
    ///
    /// False por padrao, e nao e' cosmetico: ligado, qualquer cliente injeta
    /// mensagem em qualquer topico dos outros. Desligado, a publicacao do
    /// cliente chega ao servidor como OnPublish e ele decide o que fazer —
    /// inclusive chamar Publish, que e' o mesmo desenho de servidor
    /// autoritativo que os samples de jogo usam.
    property RelayClientPublish: Boolean
      read FRelayClientPublish write FRelayClientPublish;
    /// Teto de filtros por cliente (default PIPES_DEFAULT_MAX_SUBSCRIPTIONS;
    /// 0 = sem teto). Assinatura acima do teto e' recusada: o cliente recebe
    /// OnError e o servidor tambem, e a conexao continua de pe.
    property MaxSubscriptionsPerClient: Integer
      read FMaxSubscriptionsPerClient write FMaxSubscriptionsPerClient;
    /// Teto de topicos com valor retido (default PIPES_DEFAULT_MAX_RETAINED;
    /// 0 = sem teto). No estouro, o topico retido mais antigo e' descartado.
    property MaxRetained: Integer read FMaxRetained write FMaxRetained;
    /// Um cliente publicou. NOTIFICACAO: quando RelayClientPublish esta ligado,
    /// o fanout ja aconteceu antes deste evento ser enfileirado — nao ha como
    /// vetar daqui (o porque esta no cabecalho da unit). O ARetained do handler
    /// e' o PEDIDO de retencao do cliente, nao "veio do cache" (ver
    /// TPipeTopicEvent em Pipes.Types).
    property OnPublish: TPipeTopicEvent read FOnPublish write FOnPublish;
    /// Um cliente assinou/cancelou um filtro, DEPOIS de aplicado. Para negar
    /// uma assinatura, chame DisconnectClient aqui.
    property OnSubscribe: TPipeSubscriptionEvent
      read FOnSubscribe write FOnSubscribe;
    property OnUnsubscribe: TPipeSubscriptionEvent
      read FOnUnsubscribe write FOnUnsubscribe;
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
    // Negociacao (TLS do lado servidor) AQUI, nao no Accept: presa nesta
    // thread, ela afeta so esta conexao. Um par que trave no meio nao impede
    // o servidor de aceitar os outros.
    FConn.FEndpoint.Handshake;
    // So depois de negociar o cliente conta como conectado — com mTLS e' o
    // ponto em que ele esta autenticado. Handshake que falha nunca dispara
    // OnClientConnected: cai direto no except como qualquer outra queda.
    //
    // A ordem aqui e' contratual: publicar ANTES do evento, para que um
    // handler de OnClientConnected que consulte ClientIds/TryClientIdentity ja
    // enxergue a propria conexao que acabou de ser anunciada.
    FConn.FServer.PublishEstablished(FConn);
    FConn.FServer.DispatchConnEvent(FConn.FServer.FOnClientConnected, FConn.Id);
    FConn.StartHeartbeat;
    while True do
    begin
      LFrame := PipeReadFrame(FConn.FStream, FConn.FServer.MaxMessageSize);
      PipeAtomicWrite64(FConn.FLastReadTick, PipeTickMs);
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
  FSubs := TList<string>.Create;
  FRefs := 1; // referencia do registro (FConnections)
end;

destructor TPipeServerConnection.Destroy;
begin
  // FReader e FHeartbeatThread ja foram joinados e liberados por quem possuiu
  // o teardown (StopHeartbeat roda nos mesmos pontos que o join de FReader).
  FStream.Free;
  FEndpoint.Free;
  FWriteLock.Free;
  // As assinaturas somem com a conexao, e por isso nao ha nada a desinscrever
  // em nenhum registro global — nao existe registro global.
  FSubs.Free;
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
    PipeAtomicWrite64(FLastWriteTick, PipeTickMs); // so' em caso de sucesso
  finally
    FWriteLock.Leave;
  end;
end;

procedure TPipeServerConnection.StartHeartbeat;
begin
  if (FServer.HeartbeatIntervalMs = 0) or
     not (FServer.Transport in [ptTcp, ptTls]) then
    Exit;
  PipeAtomicWrite64(FLastReadTick, PipeTickMs);
  PipeAtomicWrite64(FLastWriteTick, PipeTickMs);
  FHbStopEvent := TEvent.Create(nil, True, False, ''); // manual-reset
  FHeartbeatThread := TPipeHeartbeatThread.Create(FServer.HeartbeatIntervalMs,
    FHbStopEvent, HeartbeatTick);
end;

procedure TPipeServerConnection.StopHeartbeat;
begin
  if not Assigned(FHeartbeatThread) then
    Exit;
  FHeartbeatThread.Terminate;
  FHbStopEvent.SetEvent;
  FHeartbeatThread.WaitFor;
  FreeAndNil(FHeartbeatThread);
  FreeAndNil(FHbStopEvent);
end;

procedure TPipeServerConnection.HeartbeatTick;
var
  LNow: UInt64;
begin
  LNow := PipeTickMs;
  // Nenhum frame recebido (Ping incluso) ha' mais de 2x o intervalo: trata
  // como morta. CloseAbort e' thread-safe/idempotente (Pipes.Transport) e
  // desbloqueia a propria reader thread, que segue o teardown normal.
  if (LNow - PipeAtomicRead64(FLastReadTick)) >
     (2 * UInt64(FServer.HeartbeatIntervalMs)) then
  begin
    FEndpoint.CloseAbort;
    Exit;
  end;
  // Ocioso na escrita ha' >= metade do intervalo: manda um Ping para o peer
  // resetar o relogio de leitura dele.
  if (LNow - PipeAtomicRead64(FLastWriteTick)) >=
     (UInt64(FServer.HeartbeatIntervalMs) div 2) then
    try
      SendFrame(TPipeFrame.Ping);
    except
      // Falha de envio aqui e' sintoma, nao causa: o proprio erro ja
      // desbloqueia (ou vai desbloquear) a reader thread pelo caminho normal.
    end;
end;

function TPipeServerConnection.MatchesTopic(const ATopic: string): Boolean;
var
  I: Integer;
begin
  // Sob FConnLock. Sai no primeiro filtro que casa: a conexao recebe UMA copia
  // da mensagem mesmo que dois filtros dela alcancem o topico.
  Result := False;
  for I := 0 to FSubs.Count - 1 do
    if PipeTopicMatches(FSubs[I], ATopic) then
      Exit(True);
end;

{ TPipeServer }

constructor TPipeServer.Create(const AAddress: string;
  ATransport: TPipeTransport);
begin
  inherited Create(AAddress, ATransport);
  FConnections := TDictionary<TPipeConnectionId, TPipeServerConnection>.Create;
  FIdentities := TDictionary<TPipeConnectionId, TPipePeerIdentity>.Create;
  FIdentityOrder := TList<TPipeConnectionId>.Create;
  FRetained := TDictionary<string, TBytes>.Create;
  FRetainedOrder := TList<string>.Create;
  FConnLock := TCriticalSection.Create;
  FMaxSubscriptionsPerClient := PIPES_DEFAULT_MAX_SUBSCRIPTIONS;
  FMaxRetained := PIPES_DEFAULT_MAX_RETAINED;
end;

destructor TPipeServer.Destroy;
begin
  try
    Stop; // idempotente
  except
  end;
  FConnections.Free;
  FIdentities.Free;
  FIdentityOrder.Free;
  FRetained.Free;
  FRetainedOrder.Free;
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
    // TlsOptions so' e' consultado em ptTls; nos demais a sobrecarga delega
    // para a forma sem opcoes. Erro de certificado/senha aparece AQUI, no
    // Listen, e nao quando o primeiro cliente conectar.
    FListener := PipeCreateListener(Address, Transport, KeepAliveSeconds,
      TlsOptions.AsOptions);
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
    LConn.StopHeartbeat;
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
  // OnClientConnected NAO e' despachado aqui: quem faz isso e' a reader thread,
  // depois do Handshake do endpoint (ver TPipeServerReaderThread.Execute). A
  // ordem "OnClientConnected antes do primeiro OnMessage desta conexao" segue
  // garantida no pdmSerialized, porque quem enfileira os dois e' a MESMA
  // thread, nesta ordem.
  //
  // Tudo o que roda aqui e' na thread de ACCEPT e precisa continuar rapido e
  // sem IO: e' o que impede um cliente lento de barrar os demais.
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
    // Pub/sub tratado AQUI, na reader thread: e' decisao de roteamento, nao
    // codigo de usuario (ver o cabecalho da unit).
    pfkSubscribe:
      HandleSubscribe(AConn, AFrame);
    pfkUnsubscribe:
      HandleUnsubscribe(AConn, AFrame);
    pfkPublish:
      HandleClientPublish(AConn, AFrame);
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

{ --- pub/sub -------------------------------------------------------------- }

{ Busca explicita, em vez de TList<string>.IndexOf: o comparador default de
  string nao tem a mesma sensibilidade a caixa nos dois compiladores, e topico e'
  comparado byte a byte (ver Pipes.Topics). Com o IndexOf, 'Caixa.#' e 'caixa.#'
  poderiam ser o mesmo filtro num compilador e dois no outro. }
function IndexOfFilter(AList: TList<string>; const AFilter: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to AList.Count - 1 do
    if AList[I] = AFilter then
      Exit(I);
end;

procedure TPipeServer.RejectControl(AConn: TPipeServerConnection;
  const AReason: string);
begin
  // corrId 0 num reply de erro e' o canal de recusa assincrona: nenhum Request
  // usa esse corrId (a sequencia do cliente comeca em 1), e o TPipeClient o
  // traduz em OnError. Sem isso, uma assinatura recusada seria silencio puro no
  // cliente — ele ficaria esperando mensagens que nunca viriam, sem saber por
  // que, que e' o pior desfecho possivel para quem esta depurando.
  try
    AConn.SendFrame(TPipeFrame.ErrorReply(0, AReason));
  except
    // conexao caindo: o reader dela ja vai notificar
  end;
  DispatchError(AConn.FId, AReason);
end;

procedure TPipeServer.HandleSubscribe(AConn: TPipeServerConnection;
  const AFrame: TPipeFrame);
var
  LFilter: string;
  LBody: TBytes;
  LAdded: Boolean;
  LFull: Boolean;
begin
  PipeDecodeTopicPayload(AFrame.Payload, LFilter, LBody);
  if not PipeIsValidTopicFilter(LFilter) then
  begin
    RejectControl(AConn, 'filtro de assinatura invalido: ' + LFilter);
    Exit;
  end;
  LAdded := False;
  LFull := False;
  FConnLock.Enter;
  try
    if IndexOfFilter(AConn.FSubs, LFilter) >= 0 then
      LAdded := False // ja assinado: idempotente, e nao reenvia os retidos
    else if (FMaxSubscriptionsPerClient > 0) and
            (AConn.FSubs.Count >= FMaxSubscriptionsPerClient) then
      LFull := True
    else
    begin
      AConn.FSubs.Add(LFilter);
      LAdded := True;
    end;
  finally
    FConnLock.Leave;
  end;
  if LFull then
  begin
    RejectControl(AConn, Format('teto de %d assinaturas por cliente atingido',
      [FMaxSubscriptionsPerClient]));
    Exit;
  end;
  if not LAdded then
    Exit;
  // Os retidos vao DEPOIS de o filtro estar registrado: se fosse antes, uma
  // publicacao no intervalo nao alcancaria esta conexao e o valor entregue
  // seria o antigo, sem nada depois para corrigi-lo. Na ordem atual o risco se
  // inverte e e' benigno — a publicacao concorrente pode chegar ANTES do
  // retido, ou seja, o cliente ve o valor novo e depois um valor velho no mesmo
  // topico. Quem publica estado com retain deve tratar a ultima mensagem de um
  // topico como a verdade, e nao acumular.
  SendRetained(AConn, LFilter);
  DispatchSubscriptionEvent(FOnSubscribe, AConn.FId, LFilter);
end;

procedure TPipeServer.HandleUnsubscribe(AConn: TPipeServerConnection;
  const AFrame: TPipeFrame);
var
  LFilter: string;
  LBody: TBytes;
  LIdx: Integer;
begin
  PipeDecodeTopicPayload(AFrame.Payload, LFilter, LBody);
  FConnLock.Enter;
  try
    LIdx := IndexOfFilter(AConn.FSubs, LFilter);
    if LIdx >= 0 then
      AConn.FSubs.Delete(LIdx);
  finally
    FConnLock.Leave;
  end;
  // Cancelar o que nao estava assinado e' no-op silencioso: o cliente pode
  // estar limpando estado que o servidor perdeu numa reconexao.
  if LIdx >= 0 then
    DispatchSubscriptionEvent(FOnUnsubscribe, AConn.FId, LFilter);
end;

procedure TPipeServer.HandleClientPublish(AConn: TPipeServerConnection;
  const AFrame: TPipeFrame);
var
  LTopic: string;
  LBody: TBytes;
begin
  PipeDecodeTopicPayload(AFrame.Payload, LTopic, LBody);
  if not PipeIsValidTopic(LTopic) then
  begin
    RejectControl(AConn, 'topico de publicacao invalido: ' + LTopic);
    Exit;
  end;
  // Reter e' efeito de escrita no servidor: so' acontece se o relay estiver
  // ligado. Com o relay desligado o servidor nao aceita nada que o cliente
  // publique — nem para os outros, nem para o cache de retidos; ele apenas
  // avisa a aplicacao em OnPublish, que decide (e pode chamar Publish).
  if FRelayClientPublish then
  begin
    if AFrame.IsRetain then
      StoreRetained(LTopic, LBody);
    FanOut(LTopic, LBody);
  end;
  // ARetained aqui e' o PEDIDO do cliente (ver TPipeTopicEvent), nao "veio do
  // cache": deste lado a mensagem acabou de chegar do fio, por definicao.
  DispatchTopicEvent(FOnPublish, AConn.FId, LTopic, LBody, AFrame.IsRetain);
end;

procedure TPipeServer.StoreRetained(const ATopic: string; const AData: TBytes);
var
  LIdx: Integer;
begin
  FConnLock.Enter;
  try
    if Length(AData) = 0 then
    begin
      // Corpo vazio com retain apaga: e' o unico jeito de dizer "esse topico
      // nao tem mais valor corrente" sem inventar um kind de frame para isso.
      if FRetained.ContainsKey(ATopic) then
      begin
        FRetained.Remove(ATopic);
        LIdx := FRetainedOrder.IndexOf(ATopic);
        if LIdx >= 0 then
          FRetainedOrder.Delete(LIdx);
      end;
      Exit;
    end;
    if not FRetained.ContainsKey(ATopic) then
      FRetainedOrder.Add(ATopic); // republicar nao muda o lugar na fila
    FRetained.AddOrSetValue(ATopic, AData);
    while (FMaxRetained > 0) and (FRetainedOrder.Count > FMaxRetained) do
    begin
      FRetained.Remove(FRetainedOrder[0]);
      FRetainedOrder.Delete(0);
    end;
  finally
    FConnLock.Leave;
  end;
end;

procedure TPipeServer.SendRetained(AConn: TPipeServerConnection;
  const AFilter: string);
var
  LTopics: TArray<string>;
  LDatas: TArray<TBytes>;
  LTopic: string;
  LData: TBytes;
  LCount, I: Integer;
begin
  SetLength(LTopics, 0);
  SetLength(LDatas, 0);
  FConnLock.Enter;
  try
    if FRetained.Count = 0 then
      Exit;
    SetLength(LTopics, FRetainedOrder.Count); // teto; encolhe no fim
    SetLength(LDatas, FRetainedOrder.Count);
    LCount := 0;
    // Percorre pela ordem de chegada, e nao pelo dicionario: o cliente recebe
    // os retidos na ordem em que foram publicados.
    for I := 0 to FRetainedOrder.Count - 1 do
    begin
      LTopic := FRetainedOrder[I];
      if PipeTopicMatches(AFilter, LTopic) and
         FRetained.TryGetValue(LTopic, LData) then
      begin
        LTopics[LCount] := LTopic;
        LDatas[LCount] := LData;
        Inc(LCount);
      end;
    end;
    SetLength(LTopics, LCount);
    SetLength(LDatas, LCount);
  finally
    FConnLock.Leave;
  end;
  for I := 0 to High(LTopics) do
    try
      // PIPE_FLAG_RETAIN ligado: valor guardado, nao acontecimento de agora.
      // Chega ao app como ARetained = True em OnTopicMessage, e e' o UNICO
      // caminho que liga esse bit (ver FanOut).
      AConn.SendFrame(PipePublishFrame(LTopics[I], LDatas[I], True));
    except
      Break; // conexao caindo: o reader dela notifica
    end;
end;

procedure TPipeServer.FanOut(const ATopic: string; const AData: TBytes);
var
  LConns: TArray<TPipeServerConnection>;
  LConn: TPipeServerConnection;
  LFrame: TPipeFrame;
begin
  // Mesma mecanica de Broadcast: snapshot com AddRef sob o lock, envio fora
  // dele. Aqui o snapshot ja vem FILTRADO — o casamento roda sob o lock porque
  // e' onde a lista de filtros de cada conexao pode ser lida com seguranca, e
  // porque e' CPU pura, sem IO e sem alocar (ver Pipes.Topics).
  SetLength(LConns, 0);
  FConnLock.Enter;
  try
    for LConn in FConnections.Values do
      if LConn.FEstablished and LConn.MatchesTopic(ATopic) then
      begin
        LConn.AddRef;
        SetLength(LConns, Length(LConns) + 1);
        LConns[High(LConns)] := LConn;
      end;
  finally
    FConnLock.Leave;
  end;
  if Length(LConns) = 0 then
    Exit;
  LFrame := PipePublishFrame(ATopic, AData, False); // encodado uma vez
  for LConn in LConns do
  begin
    try
      try
        LConn.SendFrame(LFrame);
      except
        // conexao caindo: o reader dela notificara; o fanout segue
      end;
    finally
      LConn.Release;
    end;
  end;
end;

procedure TPipeServer.Publish(const ATopic: string; const AData: TBytes;
  ARetain: Boolean);
begin
  // Levanta em vez de recusar em silencio: aqui quem erra o nome e' a
  // aplicacao, no proprio processo, e a pilha do erro aponta para a linha
  // errada. (Do lado do cliente o mesmo nome invalido vira OnError: la e' um
  // par remoto, e derrubar o servidor por causa dele nao seria correto.)
  if not PipeIsValidTopic(ATopic) then
    raise EPipeError.CreateFmt('topico invalido para publicacao: %s', [ATopic]);
  if ARetain then
    StoreRetained(ATopic, AData);
  FanOut(ATopic, AData);
end;

procedure TPipeServer.PublishText(const ATopic, AText: string;
  ARetain: Boolean);
begin
  Publish(ATopic, PipeUtf8Encode(AText), ARetain);
end;

function TPipeServer.SubscriberCount(const ATopic: string): Integer;
var
  LConn: TPipeServerConnection;
begin
  Result := 0;
  FConnLock.Enter;
  try
    for LConn in FConnections.Values do
      if LConn.FEstablished and LConn.MatchesTopic(ATopic) then
        Inc(Result);
  finally
    FConnLock.Leave;
  end;
end;

function TPipeServer.ClientSubscriptions(
  AConnId: TPipeConnectionId): TArray<string>;
var
  LConn: TPipeServerConnection;
  I: Integer;
begin
  Result := nil; // silencia o aviso do FPC sobre Result gerenciado nao iniciado
  FConnLock.Enter;
  try
    if not FConnections.TryGetValue(AConnId, LConn) then
      Exit;
    SetLength(Result, LConn.FSubs.Count);
    for I := 0 to LConn.FSubs.Count - 1 do
      Result[I] := LConn.FSubs[I];
  finally
    FConnLock.Leave;
  end;
end;

procedure TPipeServer.ClearRetained;
begin
  FConnLock.Enter;
  try
    FRetained.Clear;
    FRetainedOrder.Clear;
  finally
    FConnLock.Leave;
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
    AConn.StopHeartbeat;
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
    // FEstablished na condicao: um id so' vira publico em OnClientConnected,
    // que roda depois do handshake, entao na pratica ninguem tem como pedir
    // envio para uma conexao em negociacao. A checagem fecha o caso de um id
    // adivinhado ou guardado — e mantem a mesma regra de Broadcast.
    if FConnections.TryGetValue(AConnId, LConn) and LConn.FEstablished then
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
  //
  // So conexoes ESTABELECIDAS entram. Nao e' cosmetico: sob mTLS uma conexao
  // ainda em handshake e' um par que NAO se autenticou, e mandar payload de
  // aplicacao para ele seria vazar dado para quem talvez seja recusado a
  // seguir. (Mesmo sem mTLS o envio estaria errado: a sessao TLS ainda nao
  // existe, entao nao ha por onde cifrar.)
  SetLength(LConns, 0);
  FConnLock.Enter;
  try
    for LConn in FConnections.Values do
      if LConn.FEstablished then
      begin
        LConn.AddRef;
        SetLength(LConns, Length(LConns) + 1);
        LConns[High(LConns)] := LConn;
      end;
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

procedure TPipeServer.PublishEstablished(AConn: TPipeServerConnection);
var
  LIdentity: TPipePeerIdentity;
  LHas: Boolean;
begin
  // A consulta ao endpoint fica FORA do FConnLock: ela nao faz IO (a
  // identidade ja foi extraida durante o handshake e so' esta guardada), mas
  // segurar o lock das conexoes enquanto se chama codigo do transporte
  // inverteria a ordem "lista de conexoes -> transporte" que o resto da unit
  // respeita.
  LHas := AConn.FEndpoint.TryPeerIdentity(LIdentity);
  FConnLock.Enter;
  try
    if LHas then
    begin
      FIdentities.AddOrSetValue(AConn.Id, LIdentity);
      FIdentityOrder.Add(AConn.Id);
      // Despejo pelo mais antigo. Os ids sao monotonicos, entao a ordem de
      // chegada e' a propria ordem da lista.
      while FIdentityOrder.Count > PIPES_RECENT_IDENTITIES do
      begin
        FIdentities.Remove(FIdentityOrder[0]);
        FIdentityOrder.Delete(0);
      end;
    end;
    AConn.FEstablished := True;
  finally
    FConnLock.Leave;
  end;
end;

function TPipeServer.ClientCount: Integer;
var
  LConn: TPipeServerConnection;
begin
  Result := 0;
  FConnLock.Enter;
  try
    for LConn in FConnections.Values do
      if LConn.FEstablished then
        Inc(Result);
  finally
    FConnLock.Leave;
  end;
end;

function TPipeServer.TryClientIdentity(AConnId: TPipeConnectionId;
  out AIdentity: TPipePeerIdentity): Boolean;
var
  LConn: TPipeServerConnection;
begin
  Result := False;
  Finalize(AIdentity);
  FillChar(AIdentity, SizeOf(AIdentity), 0);
  FConnLock.Enter;
  try
    // Nao exige conexao viva: a identidade sobrevive a saida do cliente, que
    // e' justamente o que permite responder "quem saiu?" dentro do
    // OnClientDisconnected.
    Result := FIdentities.TryGetValue(AConnId, AIdentity);
  finally
    FConnLock.Leave;
  end;
end;

function TPipeServer.ClientIds: TArray<TPipeConnectionId>;
var
  LConn: TPipeServerConnection;
  LCount: Integer;
begin
  Result := nil; // cala o warning 5093 do FPC (Result gerenciado sem init)
  FConnLock.Enter;
  try
    SetLength(Result, FConnections.Count); // teto; encolhe no fim
    LCount := 0;
    for LConn in FConnections.Values do
      if LConn.FEstablished then
      begin
        Result[LCount] := LConn.Id;
        Inc(LCount);
      end;
    SetLength(Result, LCount);
  finally
    FConnLock.Leave;
  end;
end;

end.
