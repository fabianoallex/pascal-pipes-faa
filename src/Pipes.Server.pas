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
  Pipes.Compression,
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
    // Contadores de Pipes.Server.ConnectionStats (Pipes.Types.TPipeConnStats).
    // Sempre ativos (sem opt-in): custam um PipeAtomicAdd64 por frame, no
    // MESMO ponto que ja atualiza FLastReadTick/FLastWriteTick.
    FBytesSent: UInt64;
    FBytesReceived: UInt64;
    // Bytes de fato no fio (pos-compressao) — ver Pipes.Types.TPipeConnStats.
    FBytesSentWire: UInt64;
    FBytesReceivedWire: UInt64;
    FMessagesSent: UInt64;
    FMessagesReceived: UInt64;
    FConnectedSinceTick: UInt64;
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
    /// Mesma coisa que SendFrame, para N frames num unico Write (ver
    /// PipeWriteFrames) — um lock, uma syscall, para toda a lista. Lista
    /// vazia e' no-op.
    procedure SendFrames(const AFrames: TArray<TPipeFrame>);
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
    // Endereco IP:porta do par, mesmo ciclo de vida/rationale de FIdentities
    // acima (sobrevive a saida do cliente, mesmo teto PIPES_RECENT_IDENTITIES)
    // — so que aqui False e' o normal em ptLocal, nao uma excecao rara.
    FAddresses: TDictionary<TPipeConnectionId, string>;
    FAddressOrder: TList<TPipeConnectionId>;
    FConnLock: TCriticalSection;
    FNextConnId: TPipeConnectionId; // sob FConnLock
    FActive: Boolean;
    FStopping: Integer; // atomico
    FMaxClients: Integer;
    FOnClientConnected: TPipeConnectionEvent;
    FOnClientDisconnected: TPipeConnectionEvent;
    FOnRequest: TPipeRequestEvent;
    // Agregado de Stats (Pipes.Types.TPipeServerStats): cumulativo desde o
    // Listen, sobrevive a conexoes que ja cairam. Bumped nos MESMOS pontos que
    // os contadores por conexao (SendFrame, reader loop, PublishEstablished).
    FTotalConnectionsAccepted: UInt64;
    FTotalBytesSent: UInt64;
    FTotalBytesReceived: UInt64;
    FTotalBytesSentWire: UInt64;
    FTotalBytesReceivedWire: UInt64;
    FTotalMessagesSent: UInt64;
    FTotalMessagesReceived: UInt64;
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
    FOnDelivered: TPipeTopicEvent;
    FOnDeliveryFailed: TPipeDeliveryFailedEvent;
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
    /// AGroupKey opcional: mensagens da MESMA chave, mandadas por QUALQUER
    /// lado (cliente ou servidor), sao entregues ao OnMessage do RECEPTOR em
    /// ordem entre si mesmo em pdmPool (o padrao) — sem isso, pdmPool nao
    /// garante ordem de entrega entre mensagens distintas (so' a ordem no
    /// fio, que ja' e' sempre preservada). Chaves diferentes continuam
    /// paralelas. Vazio (padrao) e' o comportamento de sempre, sem custo. So'
    /// afeta o DispatchMode do lado que RECEBE (ver Pipes.Threading.
    /// TPipeKeyedDispatcher); em pdmSerialized/pdmMainThread a' ordem ja' e'
    /// total e a chave e' ignorada.
    procedure SendBytes(AConnId: TPipeConnectionId; const AData: TBytes;
      const AGroupKey: string = '');
    procedure SendText(AConnId: TPipeConnectionId; const AText: string;
      const AGroupKey: string = '');
    /// Mesma coisa que SendBytes, para N mensagens num unico Write no stream
    /// da conexao — pensado para rajadas (um app que tem varias mensagens
    /// prontas de uma vez) em vez de N locks/syscalls separados. Ordem
    /// preservada; lista vazia e' no-op. Mesmos erros de SendBytes. Sem
    /// AGroupKey (cada item sai como mensagem comum, sem chave).
    procedure SendBytesBatch(AConnId: TPipeConnectionId; const AItems: TArray<TBytes>);
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
    /// Endereco 'ip:porta' do cliente (ptTcp/ptTls). False em ptLocal (Named
    /// Pipe/UDS nao tem endereco de rede) — mesmo criterio Try* de
    /// TryClientIdentity, inclusive sobrevivendo a saida do cliente para
    /// responder "de onde veio quem saiu?" dentro de OnClientDisconnected.
    function TryClientAddress(AConnId: TPipeConnectionId;
      out AAddress: string): Boolean;
    /// Snapshot agregado (cumulativo desde o Listen; sobrevive a conexoes que
    /// ja cairam). Ver a ressalva de TPipeServerStats.PoolQueueDepth sobre o
    /// pool GLOBAL em pdmPool.
    function Stats: TPipeServerStats;
    /// Contadores da conexao AConnId (Pipes.Types.TPipeConnStats). False se
    /// nao existe ou nao esta ESTABELECIDA (mesmo criterio de ClientCount) —
    /// morrem com a conexao, ao contrario de TryClientIdentity.
    function ConnectionStats(AConnId: TPipeConnectionId;
      out AStats: TPipeConnStats): Boolean;
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
    /// Mesma coisa que Publish, para N itens (cada um com seu topico/corpo/
    /// retain) em vez de uma chamada por item. Cada conexao recebe, num unico
    /// Write, so' os itens do lote cujo topico algum filtro dela alcanca —
    /// itens sem nenhum assinante nao geram Write nenhum para essa conexao.
    /// EPipeError se ALGUM topico for invalido (nenhum item e' publicado).
    procedure PublishBatch(const AItems: TArray<TPipePublishItem>);
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
    /// Um destinatario recebeu uma publicacao FEITA POR ESTE SERVIDOR (Publish/
    /// PublishBatch) — ao vivo (ARetained = False) ou replay de valor retido na
    /// hora da assinatura (ARetained = True). Dispara uma vez por conexao que
    /// casou o filtro, DEPOIS do Write ter retornado sem excecao: confirma que
    /// o payload passou ao SO, nao que o app do cliente processou (o protocolo
    /// nunca teve ACK de aplicacao — mesmo corte de Stats/BytesSentWire).
    /// Diferente de OnPublish, que e' sobre um CLIENTE publicando; este e o
    /// irmao OnDeliveryFailed cobrem o servidor sendo o publicador.
    property OnDelivered: TPipeTopicEvent read FOnDelivered write FOnDelivered;
    /// Mesmo evento que OnDelivered, do lado da falha: o Write para aquela
    /// conexao levantou excecao (conexao caindo bem no meio do fanout/replay).
    /// AError traz a mensagem da excecao. A conexao em si nao e' derrubada
    /// daqui — o reader dela ja vai notificar a queda por OnClientDisconnected,
    /// sem ligacao com qual publicacao especifica falhou; este evento existe
    /// para quem precisa dessa correlacao (log/observabilidade de entrega).
    property OnDeliveryFailed: TPipeDeliveryFailedEvent
      read FOnDeliveryFailed write FOnDeliveryFailed;
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

  { Subconjunto de um PublishBatch destinado a UMA conexao (so' os itens cujo
    topico algum filtro dela alcanca) — ver TPipeServer.PublishBatch. }
  TPipeConnFrameBatch = record
    Conn: TPipeServerConnection;
    Frames: TArray<TPipeFrame>;
    // Paralelo a Frames: topico/payload de origem de cada frame, so' para
    // disparar OnDelivered/OnDeliveryFailed por item apos o SendFrames (ver
    // TPipeServer.PublishBatch). Nao existiria se o metodo nao precisasse
    // correlacionar a entrega com CADA publicacao do lote.
    Topics: TArray<string>;
    Payloads: TArray<TBytes>;
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
  LWireBytes: UInt64;
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
      // Tamanho NO FIO, antes de desfazer o envelope — pfkCompressed inclui
      // o overhead do proprio envelope (2 bytes), entao isto e' o que de fato
      // trafegou, nao uma estimativa.
      LWireBytes := PIPE_FRAME_HEADER_SIZE + UInt64(Length(LFrame.Payload));
      if LFrame.Kind = pfkCompressed then
        // Transparente daqui pra baixo: Stats (a parte LOGICA) e HandleFrame
        // veem o frame como se nunca tivesse sido comprimido no fio.
        LFrame := PipeUndoCompress(LFrame, FConn.FServer.MaxMessageSize);
      PipeAtomicWrite64(FConn.FLastReadTick, PipeTickMs);
      PipeAtomicAdd64(FConn.FBytesReceived,
        PIPE_FRAME_HEADER_SIZE + UInt64(Length(LFrame.Payload)));
      PipeAtomicAdd64(FConn.FBytesReceivedWire, LWireBytes);
      PipeAtomicAdd64(FConn.FMessagesReceived, 1);
      PipeAtomicAdd64(FConn.FServer.FTotalBytesReceived,
        PIPE_FRAME_HEADER_SIZE + UInt64(Length(LFrame.Payload)));
      PipeAtomicAdd64(FConn.FServer.FTotalBytesReceivedWire, LWireBytes);
      PipeAtomicAdd64(FConn.FServer.FTotalMessagesReceived, 1);
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
var
  LBytes, LWireBytes: UInt64;
  LWire: TPipeFrame;
begin
  // Validacao (do payload ORIGINAL) e compressao sao CPU pura, feitas FORA
  // do write lock: um payload grande comprimindo nao trava outros escritores
  // desta conexao. LBytes (logico) usa AFrame; LWireBytes usa LWire — a
  // diferenca entre os dois E' a economia da compressao.
  PipeValidateMaxPayload(Length(AFrame.Payload), FServer.MaxMessageSize);
  LWire := PipeMaybeCompress(AFrame, FServer.CompressionMinSize);
  FWriteLock.Enter;
  try
    PipeWriteFrame(FStream, LWire, FServer.MaxMessageSize);
    PipeAtomicWrite64(FLastWriteTick, PipeTickMs); // so' em caso de sucesso
    LBytes := PIPE_FRAME_HEADER_SIZE + UInt64(Length(AFrame.Payload));
    LWireBytes := PIPE_FRAME_HEADER_SIZE + UInt64(Length(LWire.Payload));
    PipeAtomicAdd64(FBytesSent, LBytes);
    PipeAtomicAdd64(FBytesSentWire, LWireBytes);
    PipeAtomicAdd64(FMessagesSent, 1);
    PipeAtomicAdd64(FServer.FTotalBytesSent, LBytes);
    PipeAtomicAdd64(FServer.FTotalBytesSentWire, LWireBytes);
    PipeAtomicAdd64(FServer.FTotalMessagesSent, 1);
  finally
    FWriteLock.Leave;
  end;
end;

procedure TPipeServerConnection.SendFrames(const AFrames: TArray<TPipeFrame>);
var
  LBytes, LWireBytes: UInt64;
  LWireFrames: TArray<TPipeFrame>;
  I: Integer;
begin
  if Length(AFrames) = 0 then
    Exit;
  SetLength(LWireFrames, Length(AFrames));
  for I := 0 to High(AFrames) do
  begin
    PipeValidateMaxPayload(Length(AFrames[I].Payload), FServer.MaxMessageSize);
    LWireFrames[I] := PipeMaybeCompress(AFrames[I], FServer.CompressionMinSize);
  end;
  FWriteLock.Enter;
  try
    PipeWriteFrames(FStream, LWireFrames, FServer.MaxMessageSize);
    PipeAtomicWrite64(FLastWriteTick, PipeTickMs); // so' em caso de sucesso
    LBytes := 0;
    LWireBytes := 0;
    for I := 0 to High(AFrames) do
    begin
      Inc(LBytes, PIPE_FRAME_HEADER_SIZE + UInt64(Length(AFrames[I].Payload)));
      Inc(LWireBytes, PIPE_FRAME_HEADER_SIZE + UInt64(Length(LWireFrames[I].Payload)));
    end;
    PipeAtomicAdd64(FBytesSent, LBytes);
    PipeAtomicAdd64(FBytesSentWire, LWireBytes);
    PipeAtomicAdd64(FMessagesSent, UInt64(Length(AFrames)));
    PipeAtomicAdd64(FServer.FTotalBytesSent, LBytes);
    PipeAtomicAdd64(FServer.FTotalBytesSentWire, LWireBytes);
    PipeAtomicAdd64(FServer.FTotalMessagesSent, UInt64(Length(AFrames)));
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
  FAddresses := TDictionary<TPipeConnectionId, string>.Create;
  FAddressOrder := TList<TPipeConnectionId>.Create;
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
  FAddresses.Free;
  FAddressOrder.Free;
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
      DispatchMessage(AConn.FId, AFrame.Payload, AFrame.CorrId);
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
    pfkCompressed:
      ; // inalcancavel: o reader ja desfez o envelope antes de chamar HandleFrame
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
  LFrames: TArray<TPipeFrame>;
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
  if Length(LTopics) = 0 then
    Exit;
  SetLength(LFrames, Length(LTopics));
  for I := 0 to High(LTopics) do
    // PIPE_FLAG_RETAIN ligado: valor guardado, nao acontecimento de agora.
    // Chega ao app como ARetained = True em OnTopicMessage, e e' o UNICO
    // caminho que liga esse bit (ver FanOut).
    LFrames[I] := PipePublishFrame(LTopics[I], LDatas[I], True);
  try
    // Um Write so' para todo o replay (SendFrames): alem de mais barato numa
    // reconexao com muitos retidos, tambem ficou atomico — antes, um cliente
    // caindo no meio do loop recebia so' um PREFIXO dos retidos (o Break so'
    // parava o loop, sem avisar ninguem); agora ou chega o replay inteiro ou
    // nao chega nenhum, e a excecao cai no except abaixo do mesmo jeito.
    AConn.SendFrames(LFrames);
    // Um SendFrames so', mas cada topico retido e' uma entrega logicamente
    // distinta pra quem loga observabilidade: um OnDelivered por topico
    // (todos com sucesso, ja que chegou ate aqui sem excecao).
    for I := 0 to High(LTopics) do
      DispatchTopicEvent(FOnDelivered, AConn.FId, LTopics[I], LDatas[I], True);
  except
    on E: Exception do
      // conexao caindo: o reader dela notifica a queda; aqui e' so' a
      // correlacao de quais topicos retidos nao chegaram.
      for I := 0 to High(LTopics) do
        DispatchDeliveryFailedEvent(FOnDeliveryFailed, AConn.FId, LTopics[I],
          LDatas[I], True, E.Message);
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
        DispatchTopicEvent(FOnDelivered, LConn.FId, ATopic, AData, False);
      except
        on E: Exception do
        begin
          // conexao caindo: o reader dela notificara a queda; o fanout segue.
          // OnDeliveryFailed e' so' a correlacao com ESTA publicacao especifica.
          DispatchDeliveryFailedEvent(FOnDeliveryFailed, LConn.FId, ATopic,
            AData, False, E.Message);
        end;
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

procedure TPipeServer.PublishBatch(const AItems: TArray<TPipePublishItem>);
var
  I, J, LMatchCount: Integer;
  LFrames: TArray<TPipeFrame>;
  LMatched: TArray<TPipeFrame>;
  LMatchedTopics: TArray<string>;
  LMatchedPayloads: TArray<TBytes>;
  LConn: TPipeServerConnection;
  LBatches: TArray<TPipeConnFrameBatch>;
begin
  if Length(AItems) = 0 then
    Exit;
  for I := 0 to High(AItems) do
    if not PipeIsValidTopic(AItems[I].Topic) then
      raise EPipeError.CreateFmt('topico invalido para publicacao: %s', [AItems[I].Topic]);
  SetLength(LFrames, Length(AItems));
  for I := 0 to High(AItems) do
  begin
    if AItems[I].Retain then
      StoreRetained(AItems[I].Topic, AItems[I].Payload);
    // Sai SEMPRE com PIPE_FLAG_RETAIN desligado, mesmo quando o item pediu para
    // reter: mesma regra de FanOut (ver o cabecalho de FanOut acima) — o bit no
    // fio responde "isto e' historico?" para quem recebe AO VIVO, e essa entrega
    // e' sempre ao vivo. So' SendRetained liga o bit, no replay da assinatura.
    LFrames[I] := PipePublishFrame(AItems[I].Topic, AItems[I].Payload, False);
  end;
  // Mesma mecanica de FanOut: o casamento roda SOB FConnLock (e' onde a lista
  // de filtros de cada conexao pode ser lida com seguranca — ver o cabecalho
  // da unit), e o subconjunto por conexao ja sai pronto do lock; o envio (IO)
  // acontece fora dele, um SendFrames por conexao em vez de um Write por item.
  SetLength(LBatches, 0);
  FConnLock.Enter;
  try
    for LConn in FConnections.Values do
    begin
      if not LConn.FEstablished then
        Continue;
      SetLength(LMatched, Length(LFrames));
      SetLength(LMatchedTopics, Length(LFrames));
      SetLength(LMatchedPayloads, Length(LFrames));
      LMatchCount := 0;
      for J := 0 to High(LFrames) do
        if LConn.MatchesTopic(AItems[J].Topic) then
        begin
          LMatched[LMatchCount] := LFrames[J];
          LMatchedTopics[LMatchCount] := AItems[J].Topic;
          LMatchedPayloads[LMatchCount] := AItems[J].Payload;
          Inc(LMatchCount);
        end;
      if LMatchCount = 0 then
        Continue; // ninguem casou: nao gera Write nenhum para esta conexao
      SetLength(LMatched, LMatchCount);
      SetLength(LMatchedTopics, LMatchCount);
      SetLength(LMatchedPayloads, LMatchCount);
      LConn.AddRef;
      SetLength(LBatches, Length(LBatches) + 1);
      LBatches[High(LBatches)].Conn := LConn;
      LBatches[High(LBatches)].Frames := LMatched;
      LBatches[High(LBatches)].Topics := LMatchedTopics;
      LBatches[High(LBatches)].Payloads := LMatchedPayloads;
    end;
  finally
    FConnLock.Leave;
  end;
  for I := 0 to High(LBatches) do
    try
      try
        LBatches[I].Conn.SendFrames(LBatches[I].Frames);
        // Um SendFrames so' para o lote inteiro da conexao, mas cada item e'
        // uma publicacao distinta pra quem loga observabilidade (ver FanOut/
        // SendRetained) — sempre ARetained = False aqui: e' entrega AO VIVO,
        // mesmo que o item tenha pedido para reter (isso e' sobre o valor
        // GUARDADO, nao sobre esta entrega ser catch-up).
        for J := 0 to High(LBatches[I].Topics) do
          DispatchTopicEvent(FOnDelivered, LBatches[I].Conn.FId,
            LBatches[I].Topics[J], LBatches[I].Payloads[J], False);
      except
        on E: Exception do
          // conexao caindo: o reader dela notificara a queda; o lote segue
          // para as demais. Aqui e' so' a correlacao de quais itens do lote
          // nao chegaram a ESTA conexao.
          for J := 0 to High(LBatches[I].Topics) do
            DispatchDeliveryFailedEvent(FOnDeliveryFailed, LBatches[I].Conn.FId,
              LBatches[I].Topics[J], LBatches[I].Payloads[J], False, E.Message);
      end;
    finally
      LBatches[I].Conn.Release;
    end;
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
  const AData: TBytes; const AGroupKey: string);
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
    LConn.SendFrame(TPipeFrame.Msg(AData, PipeGroupKeyHash(AGroupKey)));
  finally
    LConn.Release;
  end;
end;

procedure TPipeServer.SendText(AConnId: TPipeConnectionId;
  const AText: string; const AGroupKey: string);
begin
  SendBytes(AConnId, PipeUtf8Encode(AText), AGroupKey);
end;

procedure TPipeServer.SendBytesBatch(AConnId: TPipeConnectionId;
  const AItems: TArray<TBytes>);
var
  LConn: TPipeServerConnection;
  LFrames: TArray<TPipeFrame>;
  I: Integer;
begin
  if Length(AItems) = 0 then
    Exit;
  FConnLock.Enter;
  try
    // Mesma regra de SendBytes (ver o comentario la').
    if FConnections.TryGetValue(AConnId, LConn) and LConn.FEstablished then
      LConn.AddRef
    else
      LConn := nil;
  finally
    FConnLock.Leave;
  end;
  if LConn = nil then
    raise EPipeError.Create('cliente ' + IntToStr(Int64(AConnId)) +
      ' nao esta conectado');
  try
    SetLength(LFrames, Length(AItems));
    for I := 0 to High(AItems) do
      LFrames[I] := TPipeFrame.Msg(AItems[I]);
    LConn.SendFrames(LFrames);
  finally
    LConn.Release;
  end;
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
  LAddress: string;
  LHasIdentity, LHasAddress: Boolean;
begin
  // A consulta ao endpoint fica FORA do FConnLock: ela nao faz IO (identidade
  // e endereco ja foram extraidos durante o handshake/accept e so' estao
  // guardados), mas segurar o lock das conexoes enquanto se chama codigo do
  // transporte inverteria a ordem "lista de conexoes -> transporte" que o
  // resto da unit respeita.
  LHasIdentity := AConn.FEndpoint.TryPeerIdentity(LIdentity);
  LHasAddress := AConn.FEndpoint.TryPeerAddress(LAddress);
  FConnLock.Enter;
  try
    if LHasIdentity then
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
    if LHasAddress then
    begin
      FAddresses.AddOrSetValue(AConn.Id, LAddress);
      FAddressOrder.Add(AConn.Id);
      while FAddressOrder.Count > PIPES_RECENT_IDENTITIES do
      begin
        FAddresses.Remove(FAddressOrder[0]);
        FAddressOrder.Delete(0);
      end;
    end;
    AConn.FEstablished := True;
  finally
    FConnLock.Leave;
  end;
  AConn.FConnectedSinceTick := PipeTickMs;
  PipeAtomicAdd64(FTotalConnectionsAccepted, 1);
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

function TPipeServer.TryClientAddress(AConnId: TPipeConnectionId;
  out AAddress: string): Boolean;
begin
  AAddress := '';
  FConnLock.Enter;
  try
    // Mesmo criterio de TryClientIdentity: nao exige conexao viva.
    Result := FAddresses.TryGetValue(AConnId, AAddress);
  finally
    FConnLock.Leave;
  end;
end;

function TPipeServer.Stats: TPipeServerStats;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ClientCount := ClientCount;
  Result.TotalConnectionsAccepted := PipeAtomicRead64(FTotalConnectionsAccepted);
  Result.TotalBytesSent := PipeAtomicRead64(FTotalBytesSent);
  Result.TotalBytesReceived := PipeAtomicRead64(FTotalBytesReceived);
  Result.TotalBytesSentWire := PipeAtomicRead64(FTotalBytesSentWire);
  Result.TotalBytesReceivedWire := PipeAtomicRead64(FTotalBytesReceivedWire);
  Result.TotalMessagesSent := PipeAtomicRead64(FTotalMessagesSent);
  Result.TotalMessagesReceived := PipeAtomicRead64(FTotalMessagesReceived);
  Result.PoolQueueDepth := EventPool.QueueDepth;
end;

function TPipeServer.ConnectionStats(AConnId: TPipeConnectionId;
  out AStats: TPipeConnStats): Boolean;
var
  LConn: TPipeServerConnection;
begin
  FillChar(AStats, SizeOf(AStats), 0);
  FConnLock.Enter;
  try
    // Mesma regra de SendBytes: FEstablished na condicao, AddRef segura o
    // objeto para ler os contadores FORA do lock sem risco de use-after-free
    // se a conexao cair entre o TryGetValue e a leitura.
    if FConnections.TryGetValue(AConnId, LConn) and LConn.FEstablished then
      LConn.AddRef
    else
      LConn := nil;
  finally
    FConnLock.Leave;
  end;
  Result := LConn <> nil;
  if not Result then
    Exit;
  try
    AStats.BytesSent := PipeAtomicRead64(LConn.FBytesSent);
    AStats.BytesReceived := PipeAtomicRead64(LConn.FBytesReceived);
    AStats.BytesSentWire := PipeAtomicRead64(LConn.FBytesSentWire);
    AStats.BytesReceivedWire := PipeAtomicRead64(LConn.FBytesReceivedWire);
    AStats.MessagesSent := PipeAtomicRead64(LConn.FMessagesSent);
    AStats.MessagesReceived := PipeAtomicRead64(LConn.FMessagesReceived);
    AStats.ConnectedSinceTick := LConn.FConnectedSinceTick;
  finally
    LConn.Release;
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
