unit Pipes.Types;

{$I pipes.inc}

{ Tipos publicos compartilhados da biblioteca: identificador de conexao,
  assinaturas de eventos (sempre 'procedure of object' - compat FPC),
  excecoes e o modo de despacho dos callbacks de usuario.

  A API publica trafega TBytes; texto e' convertido internamente como UTF-8
  (ver PipeUtf8Encode/PipeUtf8Decode em Pipes.Framing). }

interface

uses
  SysUtils,
  PascalCommon.Transport;

type
  /// Identifica uma conexao no servidor (sequencial atomico; 0 = invalido).
  /// No cliente ha uma unica conexao e o id e' apenas informativo.
  TPipeConnectionId = UInt64;

  { Onde os eventos do usuario executam:
    - pdmPool: o PcPool da pascal-common-faa (padrao; paralelismo entre
      conexoes, sem garantia de ordem global). E' um pool do PROCESSO, nao
      do pipes: outras libs *-faa que o usam (amqp, redis) disputam os
      mesmos workers.
    - pdmSerialized: pool dedicado de 1 worker (ordem FIFO global garantida).
    - pdmMainThread: TThread.Queue para a main thread (apps VCL/LCL consomem
      eventos sem Synchronize manual; nao usar em apps console sem loop de
      mensagens, pois os eventos nunca seriam drenados). }
  TPipeDispatchMode = (pdmPool, pdmSerialized, pdmMainThread);

  { Qual transporte carrega os frames. Nomeado por ALCANCE, nao por mecanismo:
    - ptLocal: o melhor IPC local do SO (padrao). Named Pipe no Windows, Unix
      Domain Socket no POSIX — por isso 'ptNamedPipe' seria um nome errado
      metade das vezes. Address e' o nome do pipe ('MeuPipe') ou um caminho
      nativo ('\\.\pipe\X', '/tmp/x.sock').
    - ptTcp: socket TCP, identico nas duas plataformas. Address e' 'host:porta'
      ('0.0.0.0:5000', '127.0.0.1:5000', '[::1]:5000').
    Diferente de ptLocal, ptTcp NAO herda controle de acesso do SO: o listener
    fica exposto a rede e a autenticacao e' responsabilidade da aplicacao.
    - ptTls: o mesmo socket TCP, com TLS por cima. Address tem o formato de
      ptTcp; as credenciais vem de TlsOptions. E' a resposta ao paragrafo
      acima: cifra o trafego e, com CaFile no servidor (mTLS), autentica o
      cliente por certificado. Todo build tem TLS desde a 0.4.0 (ver pipes.inc). }
  TPipeTransport = (ptLocal, ptTcp, ptTls);

  { Credenciais e politica de validacao do ptTls: desde a 0.4.0 e' o
    TPcTlsOptions da pascal-common-faa (PascalCommon.Transport), que nasceu
    deste record. O mesmo record serve aos dois lados:

                  SERVIDOR                        CLIENTE
    CertFile      certificado do servidor         certificado do cliente (mTLS;
                  (obrigatorio)                   vazio = nao apresenta nenhum)
    CertPassword  senha do PFX (so SChannel)      idem
    KeyFile       chave PEM (so OpenSSL)          idem
    CaFile        CA que assina os certificados   CA que valida o servidor no
                  de CLIENTE. Preenchido, LIGA    lugar do trust store do
                  mTLS: quem nao apresentar       sistema (nos DOIS backends
                  certificado valido e' recusado  desde a 0.4.0; antes o
                                                  SChannel ignorava o campo)
    SkipServer... ignorado                        NAO valida a cadeia do servidor
    Verification
    HandshakeTimeoutMs  0 = PIPE_TLS_HANDSHAKE_TIMEOUT_DEFAULT; desligar exige
                  PIPE_TLS_HANDSHAKE_NO_TIMEOUT
    Backend       tbDefault, tbSChannel ou tbOpenSsl (escolha em RUNTIME; ver
                  abaixo)

    Record zerado = comportamento seguro (valida o servidor, prazo padrao no
    handshake), por isso os campos de desligar sao os negativos.

    Backend: tbDefault e' SChannel no Windows e OpenSSL no resto; compilar com
    PIPES_OPENSSL so' troca esse padrao para tbOpenSsl (no Windows os dois
    backends estao sempre compilados, e o OpenSSL so' e' carregado no primeiro
    uso). tbSChannel fora do Windows levanta EPipeTls.

    Formatos: o SChannel le um PFX (certificado + chave num arquivo), o OpenSSL
    um par de PEM -- dai CertFile/KeyFile em vez de um campo so. CaFile e' PEM
    nos dois. }
  TPipeTlsOptions = TPcTlsOptions;
  TPipeTlsBackend = TPcTlsBackend;

  { Quem e' o par do outro lado, segundo o certificado que ele apresentou e que
    JA FOI VALIDADO contra a CA configurada (TPcPeerIdentity da
    pascal-common-faa desde a 0.4.0: CommonName e Subject).

    So existe sob mTLS (CaFile preenchido no servidor). Sem mTLS o cliente nao
    apresenta certificado nenhum e nao ha identidade — nem uma vazia "provisoria":
    TPipeServer.TryClientIdentity devolve False, e isso significa "esta conexao
    nao tem identidade verificada", nunca "espere mais um pouco".

    E' confiavel porque a cadeia foi conferida ANTES: um certificado com
    CommonName forjado nao chega aqui, e' recusado no handshake. Por isso e'
    seguro usar CommonName para identificar (mostrar, logar, rotear) — o que
    NAO se deve fazer e' o contrario: derivar autorizacao de um nome quando a
    cadeia nao foi validada. }
  TPipePeerIdentity = TPcPeerIdentity;

  { Contadores de uma conexao ESTABELECIDA do servidor (ver
    TPipeServer.ConnectionStats). Morrem com a conexao, como TPipePeerIdentity
    NAO faz — quem precisa do numero depois da queda usa TPipeServerStats
    (agregado, sobrevive as conexoes). Sempre ativos, sem opt-in: o custo por
    frame e' um incremento atomico, o mesmo que FInFlight ja paga. }
  TPipeConnStats = record
    BytesSent: UInt64;
    BytesReceived: UInt64;
    MessagesSent: UInt64;
    MessagesReceived: UInt64;
    /// Bytes de fato escritos/lidos NO FIO (pos-compressao quando o frame foi
    /// comprimido; igual a BytesSent/BytesReceived quando nao — ver
    /// Pipes.Compression). BytesSent - BytesSentWire e' quanto a compressao
    /// economizou nesta conexao; sempre <= BytesSent/BytesReceived.
    BytesSentWire: UInt64;
    BytesReceivedWire: UInt64;
    /// PcTickMs no instante em que OnClientConnected disparou.
    ConnectedSinceTick: UInt64;
  end;

  { Agregado do servidor (ver TPipeServer.Stats): cumulativo desde o Listen,
    sobrevive a conexoes que ja cairam — e' o numero para um health-check ou
    painel de operacao, nao para depurar UMA conexao (isso e' ConnectionStats). }
  TPipeServerStats = record
    /// Igual a TPipeServer.ClientCount; incluido aqui para nao exigir uma
    /// segunda chamada de quem so' quer um snapshot completo.
    ClientCount: Integer;
    /// So conta conexoes ESTABELECIDAS (mesmo criterio de ClientCount/
    /// ClientIds) — uma conexao recusada no meio do handshake mTLS nao infla
    /// este numero.
    TotalConnectionsAccepted: UInt64;
    TotalBytesSent: UInt64;
    TotalBytesReceived: UInt64;
    /// Bytes de fato escritos/lidos NO FIO — ver TPipeConnStats.BytesSentWire.
    TotalBytesSentWire: UInt64;
    TotalBytesReceivedWire: UInt64;
    TotalMessagesSent: UInt64;
    TotalMessagesReceived: UInt64;
    /// Itens aguardando um worker no pool de despacho (EventPool). Em
    /// pdmPool (padrao) esse pool e' o PcPool da pascal-common-faa, GLOBAL
    /// do MESMO PROCESSO: compartilhado por todo TPipeServer/TPipeClient e
    /// tambem pelas outras libs *-faa que o usam (amqp, redis) — este numero
    /// e' o backlog de todo mundo, nao so deste servidor nem so do pipes. So
    /// e' exclusivo deste servidor em pdmSerialized (pool privado de 1 worker).
    PoolQueueDepth: Integer;
  end;

  { Contadores do cliente (ver TPipeClient.Stats): da SESSAO atual, como
    FLastReadTick/FLastWriteTick do heartbeat — zeram a cada Connect/
    reconexao. Sem contador cumulativo entre sessoes de proposito: o cliente
    e' uma unica conexao de cada vez, e "quantos bytes desde sempre" teria
    pouco uso pratico que ReconnectAttempts (o motivo de a sessao ter trocado)
    ja nao cubra melhor. }
  TPipeClientStats = record
    BytesSent: UInt64;
    BytesReceived: UInt64;
    /// Bytes de fato escritos/lidos NO FIO — ver TPipeConnStats.BytesSentWire.
    BytesSentWire: UInt64;
    BytesReceivedWire: UInt64;
    MessagesSent: UInt64;
    MessagesReceived: UInt64;
    /// = FReconnectAttempts: tentativas desde a ultima sessao DURAVEL (o
    /// mesmo criterio de MaxReconnectAttempts), nao desde sempre.
    ReconnectAttempts: Integer;
    /// Requests em voo (Request/RequestText de qualquer thread) aguardando
    /// reply ou timeout.
    PendingRequests: Integer;
    /// Media/maximo de latencia de Request bem-sucedido (exclui timeout e
    /// reply de erro) desde a sessao atual. 0 se nenhum Request completou.
    AvgRequestLatencyMs: Cardinal;
    MaxRequestLatencyMs: Cardinal;
  end;

  TPipeMessageEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const AData: TBytes) of object;
  /// Request-reply no servidor: o retorno em AReply vira o frame de resposta
  /// (enviado pelo proprio worker ao fim do handler, com o mesmo corrId).
  TPipeRequestEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const ARequest: TBytes; out AReply: TBytes) of object;
  { Mensagem dirigida a um TOPICO (pub/sub). Serve aos dois lados, com
    leituras diferentes de AConnId e de ARetained:
    - TPipeClient.OnTopicMessage: chegou uma publicacao que casa com um filtro
      assinado; AConnId e' 0 (o cliente tem uma conexao so'). ARetained = True
      significa "isto NAO e' um acontecimento de agora": e' o valor que o
      servidor tinha guardado do topico, entregue porque a assinatura acabou de
      ser feita. Uma publicacao ao vivo chega SEMPRE com False, mesmo que o
      publicador tenha pedido para reter — quem recebe quer saber se a mensagem
      e' noticia ou historico, e nao o que o remetente pediu ao servidor.
    - TPipeServer.OnPublish: o cliente AConnId publicou; e' notificacao, o
      fanout para os assinantes ja aconteceu (ou nao, conforme
      RelayClientPublish) antes deste evento ser enfileirado. Aqui ARetained
      tem o outro sentido, o unico possivel deste lado: o cliente PEDIU para
      reter (pedido que so' e' atendido se RelayClientPublish estiver ligado).

    E' um evento SEPARADO de OnMessage de proposito: quem usa os dois nao deve
    receber o envelope cru sem saber o topico. }
  TPipeTopicEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const ATopic: string; const AData: TBytes;
    ARetained: Boolean) of object;
  { TPipeServer.OnDelivered/OnDeliveryFailed: um destinatario especifico de UMA
    publicacao do proprio servidor (Publish/PublishBatch, ao vivo ou replay de
    retido na assinatura — ARetained distingue os dois, mesmo sentido de
    TPipeTopicEvent do lado cliente). NAO e' confirmacao de aplicacao: "entregue"
    aqui significa que o Write para aquela conexao retornou sem excecao (o
    payload passou para o buffer do SO/pipe), o mesmo corte que Stats/
    BytesSentWire ja fazem — o protocolo nunca teve ACK de app. OnPublish e'
    outra coisa (cliente publicando); estes dois cobrem o publicador ser o
    proprio servidor, que OnPublish nao alcanca. AError so' vem preenchido em
    OnDeliveryFailed. }
  TPipeDeliveryFailedEvent = procedure(Sender: TObject;
    AConnId: TPipeConnectionId; const ATopic: string; const AData: TBytes;
    ARetained: Boolean; const AError: string) of object;
  /// Assinatura/cancelamento de um cliente no servidor (notificacao, depois de
  /// aplicada). Ver TPipeServer.OnSubscribe.
  TPipeSubscriptionEvent = procedure(Sender: TObject;
    AConnId: TPipeConnectionId; const AFilter: string) of object;
  TPipeConnectionEvent = procedure(Sender: TObject;
    AConnId: TPipeConnectionId) of object;
  TPipeErrorEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const AError: string) of object;
  { TPipeClient.OnConnectAttemptFailed: UMA tentativa de abrir a sessao
    fracassou — tanto de ConnectAsync (primeira conexao) quanto da reconexao
    automatica, que para diagnostico sao o mesmo fenomeno. Puramente
    DIAGNOSTICO: nao ha nada a decidir aqui, a proxima tentativa ja esta a
    caminho (ou o teto de MaxReconnectAttempts sera alcancado, e ai vem o
    OnError de esgotamento). Sem handler atribuido nao custa nada.

    Nao ha AConnId de proposito: nao existe conexao — e' justamente disso que
    o evento fala.

    AAddress e' o endereco que ACABOU de falhar, passado por valor em vez de
    lido de ActiveAddress: com FailoverAddresses, o indice ja avancou quando
    este evento sai, entao a property responderia pelo PROXIMO endereco. Num
    log forense isso trocaria o culpado sem ninguem perceber.

    AAttempt e' o mesmo contador que MaxReconnectAttempts limita: conta desde
    a ultima sessao DURAVEL, nao desde sempre (ver TPipeClient). Comeca em 1.

    Frequencia: uma tentativa contra servidor ausente consome
    ReconnectDelayMs inteiro, entao o evento sai a cada ~ReconnectDelayMs
    enquanto durar a queda. A lib nao decima nem agrega — quem loga decide a
    politica, e AAttempt e' o que permite dizer "3 tentativas desde o ultimo
    registro" sem guardar estado proprio. }
  TPipeAttemptFailedEvent = procedure(Sender: TObject; const AAddress: string;
    AAttempt: Integer; const AError: string) of object;

  /// Erro generico da biblioteca (base das demais).
  EPipeError = class(Exception);
  /// Pipe/conexao encerrada (EOF do outro lado, handle/fd fechado).
  EPipeClosed = class(EPipeError);
  /// Connect/Request estourou o prazo.
  EPipeTimeout = class(EPipeError);
  /// Violacao do wire format: magic invalido, kind desconhecido ou payload
  /// acima do maximo configurado.
  EPipeProtocol = class(EPipeError);
  /// Falha de TLS: handshake, validacao de certificado, ou biblioteca TLS
  /// ausente/incompativel (comum aos backends Schannel e OpenSSL).
  EPipeTls = class(EPipeError);

const
  /// Os valores de TPipeTlsBackend, re-exportados para quem so' usa Pipes.*
  /// (um alias de tipo nao traz os nomes do enum junto).
  tbDefault = PascalCommon.Transport.tbDefault;
  tbSChannel = PascalCommon.Transport.tbSChannel;
  tbOpenSsl = PascalCommon.Transport.tbOpenSsl;

  PIPE_INVALID_CONNECTION = TPipeConnectionId(0);
  /// Teto padrao de payload por mensagem (protecao contra frame corrompido
  /// ou malicioso); ajustavel por instancia via MaxMessageSize.
  PIPES_DEFAULT_MAX_MESSAGE_SIZE = 16 * 1024 * 1024;
  /// Quantas identidades de clientes o servidor mantem consultaveis depois de
  /// a conexao ter saido (ver TPipeServer.TryClientIdentity). Existe porque a
  /// identidade precisa sobreviver ao OnClientDisconnected, e a limpeza da
  /// conexao nao tem ordem garantida em relacao a esse evento. 256 cobre com
  /// folga qualquer handler que consulte na hora, e custa poucos KB.
  PIPES_RECENT_IDENTITIES = 256;
  /// Ociosidade (segundos) antes do primeiro probe de keepalive em ptTcp.
  /// 20s e' deliberadamente curto: o alvo sao conexoes sobre VPN/NAT, cujo
  /// timeout de ociosidade costuma ficar entre 30s e poucos minutos — o probe
  /// precisa acontecer ANTES disso para manter o mapeamento vivo. Ignorado por
  /// ptLocal. Ajustavel por instancia via KeepAliveSeconds (0 = desligado).
  PIPES_DEFAULT_KEEPALIVE_SECONDS = 20;
  /// Intervalo entre probes e quantos probes sem resposta derrubam a conexao.
  /// Com os padroes: par morto detectado em ~20 + 3*5 = 35s.
  PIPES_KEEPALIVE_INTERVAL_SECONDS = 5;
  PIPES_KEEPALIVE_PROBE_COUNT = 3;
  /// Teto de filtros de assinatura por cliente (TPipeServer.
  /// MaxSubscriptionsPerClient; 0 = sem teto). Existe porque a lista de
  /// assinaturas e' memoria do SERVIDOR ditada pelo CLIENTE: sem teto, um par
  /// hostil assina um milhao de filtros e o custo do fanout vai com ele.
  /// 64 e' folgado para o uso real (um punhado de filtros por processo).
  PIPES_DEFAULT_MAX_SUBSCRIPTIONS = 64;
  /// Quantos topicos o servidor mantem com valor retido (o ultimo publicado com
  /// PIPE_FLAG_RETAIN, entregue a quem assinar depois). Alem disso, o topico
  /// retido mais antigo e' descartado — e' cache de ultimo valor, nao fila:
  /// quem precisa de mensagem que sobrevive ao processo esta na lib errada.
  PIPES_DEFAULT_MAX_RETAINED = 256;
  /// Prazo padrao do handshake TLS (TPipeTlsOptions.HandshakeTimeoutMs = 0).
  /// 15s cobre com folga um handshake sobre VPN ruim — o alvo nao e' a rede
  /// lenta, e' o par que nunca fala.
  PIPE_TLS_HANDSHAKE_TIMEOUT_DEFAULT = PC_TLS_HANDSHAKE_TIMEOUT_DEFAULT;
  /// Desliga o prazo do handshake. Valor explicito de proposito: quem remove
  /// essa protecao devia estar dizendo isso em voz alta, nao deixando um campo
  /// em zero.
  PIPE_TLS_HANDSHAKE_NO_TIMEOUT = PC_TLS_HANDSHAKE_NO_TIMEOUT;

/// Descreve o backend TLS efetivamente em uso (biblioteca, versao e de onde foi
/// carregada), para log e diagnostico — a mensagem de "handshake falhou" sozinha
/// raramente diz se o problema e' a DLL errada. Vazio ate o primeiro uso de TLS.
function PipeTlsBackendInfo: string;
/// Chamada por Pipes.Transport.Tls depois de cada connect/listen TLS. Nao e'
/// para uso da aplicacao.
procedure PipeSetTlsBackendDetail(const ADetail: string);

implementation

var
  // Escrita uma unica vez, sob o lock de carga do backend TLS; leitura e'
  // diagnostico. Nao ha corrida real, mas tambem nao ha garantia forte aqui.
  GTlsBackendDetail: string = '';

function PipeTlsBackendInfo: string;
begin
  Result := GTlsBackendDetail;
end;

procedure PipeSetTlsBackendDetail(const ADetail: string);
begin
  GTlsBackendDetail := ADetail;
end;

end.
