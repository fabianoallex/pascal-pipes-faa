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

  TPipeMessageEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const AData: TBytes) of object;
  /// Request-reply no servidor: o retorno em AReply vira o frame de resposta
  /// (enviado pelo proprio worker ao fim do handler, com o mesmo corrId).
  TPipeRequestEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId;
    const ARequest: TBytes; out AReply: TBytes) of object;
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
