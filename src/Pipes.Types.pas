unit Pipes.Types;

{$I pipes.inc}

{ Tipos publicos compartilhados da biblioteca: identificador de conexao,
  assinaturas de eventos (sempre 'procedure of object' - compat FPC),
  excecoes e o modo de despacho dos callbacks de usuario.

  A API publica trafega TBytes; texto e' convertido internamente como UTF-8
  (ver PipeUtf8Encode/PipeUtf8Decode em Pipes.Framing). }

interface

uses
  SysUtils;

type
  /// Identifica uma conexao no servidor (sequencial atomico; 0 = invalido).
  /// No cliente ha uma unica conexao e o id e' apenas informativo.
  TPipeConnectionId = UInt64;

  { Onde os eventos do usuario executam:
    - pdmPool: pool de threads compartilhado (padrao; paralelismo entre
      conexoes, sem garantia de ordem global).
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
      cliente por certificado. Exige build com backend TLS (ver pipes.inc). }
  TPipeTransport = (ptLocal, ptTcp, ptTls);

  { Credenciais e politica de validacao do ptTls. O mesmo record serve aos dois
    lados; o que muda e' a leitura de cada campo:

                  SERVIDOR                        CLIENTE
    CertFile      certificado do servidor         certificado do cliente (mTLS;
                  (obrigatorio)                   vazio = nao apresenta nenhum)
    CertPassword  senha do PFX (so Schannel)      idem
    KeyFile       chave PEM (so OpenSSL)          idem
    CaFile        CA que assina os certificados   CA que valida o servidor
                  de CLIENTE. Preenchido, LIGA    (vazio = usa o trust store
                  mTLS: quem nao apresentar       do sistema; so' OpenSSL, ver
                  certificado valido e' recusado  abaixo)
    SkipServer... (implicito por CaFile)          NAO valida a cadeia do servidor
    Verification

    O campo de validacao do servidor e' NEGATIVO de proposito: um record zerado
    por FillChar valida o servidor (o comportamento seguro), e desligar exige
    dizer SkipServerVerification := True em voz alta. So faz sentido em
    laboratorio — sem isso, o cliente cifra o trafego mas nao sabe com quem
    fala, e a sessao e' MITM-avel.

    Sobre formatos: o Schannel le um PFX unico (certificado + chave), enquanto o
    OpenSSL le PEM separados — dai CertFile/KeyFile em vez de um campo so. }
  TPipeTlsOptions = record
    CertFile: string;
    CertPassword: string;
    KeyFile: string;
    CaFile: string;
    /// Cliente: desliga a validacao da cadeia do servidor (default False =
    /// valida). Negativo para que o zero seja o seguro. Ignorado no servidor.
    SkipServerVerification: Boolean;
    /// Prazo do handshake TLS. 0 = PIPE_TLS_HANDSHAKE_TIMEOUT_DEFAULT, para que
    /// um record zerado por FillChar caia no comportamento seguro; desligar
    /// exige o valor explicito PIPE_TLS_HANDSHAKE_NO_TIMEOUT.
    ///
    /// Sem prazo, quem abre o TCP e nunca manda o ClientHello prende a reader
    /// thread daquela conexao para sempre — algumas dezenas de conexoes
    /// meia-abertas esgotam o servidor sem enviar um byte util.
    HandshakeTimeoutMs: Cardinal;
  end;

  { Quem e' o par do outro lado, segundo o certificado que ele apresentou e que
    JA FOI VALIDADO contra a CA configurada.

    So existe sob mTLS (CaFile preenchido no servidor). Sem mTLS o cliente nao
    apresenta certificado nenhum e nao ha identidade — nem uma vazia "provisoria":
    TPipeServer.TryClientIdentity devolve False, e isso significa "esta conexao
    nao tem identidade verificada", nunca "espere mais um pouco".

    E' confiavel porque a cadeia foi conferida ANTES: um certificado com
    CommonName forjado nao chega aqui, e' recusado no handshake. Por isso e'
    seguro usar CommonName para identificar (mostrar, logar, rotear) — o que
    NAO se deve fazer e' o contrario: derivar autorizacao de um nome quando a
    cadeia nao foi validada. }
  TPipePeerIdentity = record
    /// CN do subject — 'pdv-loja-001'. E' o que se mostra na tela.
    CommonName: string;
    /// Subject completo (DN), para log e auditoria.
    Subject: string;
  end;

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
    /// PipeTickMs no instante em que OnClientConnected disparou.
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
    TotalMessagesSent: UInt64;
    TotalMessagesReceived: UInt64;
    /// Itens aguardando um worker no pool de despacho (EventPool). Em
    /// pdmPool (padrao) esse pool e' GLOBAL, compartilhado por todo
    /// TPipeServer/TPipeClient do MESMO PROCESSO — este numero e' o backlog
    /// de todo mundo, nao so deste servidor. So e' exclusivo deste servidor em
    /// pdmSerialized (pool privado de 1 worker).
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
  /// Assinatura/cancelamento de um cliente no servidor (notificacao, depois de
  /// aplicada). Ver TPipeServer.OnSubscribe.
  TPipeSubscriptionEvent = procedure(Sender: TObject;
    AConnId: TPipeConnectionId; const AFilter: string) of object;
  TPipeConnectionEvent = procedure(Sender: TObject;
    AConnId: TPipeConnectionId) of object;
  TPipeErrorEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const AError: string) of object;

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
  PIPE_TLS_HANDSHAKE_TIMEOUT_DEFAULT = 15000;
  /// Desliga o prazo do handshake. Valor explicito de proposito: quem remove
  /// essa protecao devia estar dizendo isso em voz alta, nao deixando um campo
  /// em zero.
  PIPE_TLS_HANDSHAKE_NO_TIMEOUT = Cardinal($FFFFFFFF);

/// Descreve o backend TLS efetivamente em uso (biblioteca, versao e de onde foi
/// carregada), para log e diagnostico — a mensagem de "handshake falhou" sozinha
/// raramente diz se o problema e' a DLL errada. Vazio ate o primeiro uso de TLS.
function PipeTlsBackendInfo: string;
/// Chamada pelos backends TLS ao carregar. Nao e' para uso da aplicacao.
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
