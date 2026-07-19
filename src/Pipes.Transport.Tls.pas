unit Pipes.Transport.Tls;

{$I pipes.inc}

{ Transporte TLS (ptTls): TCP com a sessao cifrada por cima.

  Esta unit e' o ponto NEUTRO — nao implementa TLS. Ela escolhe o backend e faz
  a adaptacao de contratos:

    backend TLS                  quem implementa
    Windows .................... Pipes.Transport.Schannel (SSPI nativo; nao
                                 depende de DLL externa — decisivo em parque de
                                 maquinas antigo, onde distribuir e atualizar
                                 OpenSSL e' problema operacional)
    POSIX (e Windows opt-in) ... Pipes.Transport.OpenSSL (libssl/libcrypto
                                 carregadas dinamicamente)

  A adaptacao existe porque os dois lados falam linguas diferentes:

    TPipeEndpoint  --TPipeEndpointStream-->  TStream  --backend TLS-->  TStream
                                                                          |
    TPipeTlsEndpoint <--------------------------------------------------- +

  Ou seja: o endpoint TCP vira TStream, o backend cifra sobre esse TStream, e
  TPipeTlsEndpoint traz o resultado de volta ao contrato TPipeEndpoint que o
  resto da lib conhece. O framing NPF1 nao sabe que ha TLS embaixo.

  Invariantes (alem do contrato de Pipes.Transport):
  - POSSE: o stream do backend e' dono do TStream de baixo (libera os dois no
    Free), mas NAO do TPipeEndpoint TCP — esse e' liberado aqui. Ordem no
    destructor: primeiro o stream TLS (que tenta o close_notify), depois o
    endpoint.
  - ABORT: CloseAbort delega ao endpoint TCP. Uma leitura presa no backend TLS
    esta, na pratica, presa no Read do endpoint de baixo; abortar aquele faz o
    EPipeClosed subir pela pilha de decifragem. Nao ha estado a desarmar no
    proprio TLS.
  - O contrato de Read difere do TStream: aqui Read NUNCA devolve 0 — fim de
    conexao e' EPipeClosed. A conversao e' feita neste adaptador.

  Onde cada lado negocia:
  - CLIENTE: no construtor, na thread de quem chamou Connect. Quem espera e'
    quem pediu, entao bloquear ali nao afeta mais ninguem.
  - SERVIDOR: NAO no accept. O listener devolve o endpoint ainda nao
    negociado e quem chama Handshake e' a reader thread da conexao. Feito no
    accept, um unico cliente travado no meio do handshake impediria o servidor
    de aceitar todos os outros.

  Estado: servidor implementado so no Windows (Schannel). No POSIX o lado
  servidor do OpenSSL ainda falta, e TlsPipeCreateListener recusa. }

interface

uses
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Transport
  // Os streams de servidor sao CAMPOS da classe, entao a unit do backend
  // precisa estar visivel ja na interface.
  {$IFDEF PIPES_OPENSSL}
  , Pipes.Transport.OpenSSL
  {$ENDIF}
  {$IFDEF PIPES_SCHANNEL}
  , Pipes.Transport.Schannel
  {$ENDIF};

type
  { Embrulha um TPipeEndpoint ja conectado numa sessao TLS. Assume a posse do
    endpoint de baixo. }
  TPipeTlsEndpoint = class(TPipeEndpoint)
  private
    FInner: TPipeEndpoint;   // endpoint TCP; propriedade desta classe
    FTls: TStream;           // stream do backend; dono do TPipeEndpointStream
    // <> nil enquanto ha negociacao de servidor pendente. So um dos dois
    // existe por build: o backend e' escolhido em tempo de compilacao.
    {$IFDEF PIPES_OPENSSL}
    FServerSsl: TPipeOpenSslServerStream;
    {$ENDIF}
    {$IFDEF PIPES_SCHANNEL}
    FServerTls: TPipeSchannelServerStream;
    {$ENDIF}
  public
    /// ATargetName e' o nome usado para SNI e para validar o certificado
    /// (tipicamente o host de Address). AVerifyPeer=False desliga a validacao
    /// da cadeia — util so em laboratorio, nunca em producao.
    constructor Create(AInner: TPipeEndpoint; const ATargetName: string;
      AVerifyPeer: Boolean);
    /// Lado SERVIDOR: embrulha o endpoint aceito sem negociar nada ainda. A
    /// negociacao acontece em Handshake, chamado pela reader thread — no
    /// accept, um cliente lento prenderia o servidor inteiro (ver T1).
    ///
    /// As credenciais chegam ja resolvidas pelo listener e diferem por
    /// backend: no Schannel um PCCERT_CONTEXT (ACertContext); no OpenSSL os
    /// caminhos do certificado e da chave PEM.
    constructor CreateServer(AInner: TPipeEndpoint; ACertContext: Pointer;
      const ACertFile, AKeyFile: string);
    destructor Destroy; override;
    procedure Handshake; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
  end;

  { Listener que embrulha o listener TCP: cada conexao aceita volta como
    TPipeTlsEndpoint AINDA NAO negociado. As credenciais sao resolvidas UMA vez
    aqui e compartilhadas por todas as conexoes. }
  TPipeTlsListener = class(TPipeListener)
  private
    FInner: TPipeListener;
    FCertContext: Pointer;  // Schannel: PCCERT_CONTEXT (desta classe)
    FCertFile: string;      // OpenSSL: caminhos PEM
    FKeyFile: string;
  public
    constructor Create(AInner: TPipeListener; ACertContext: Pointer;
      const ACertFile, AKeyFile: string);
    destructor Destroy; override;
    function Accept: TPipeEndpoint; override;
    procedure Close; override;
  end;

/// Conecta via TCP e faz o handshake TLS como CLIENTE.
function TlsPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal; AVerifyPeer: Boolean): TPipeEndpoint;

/// ACertFile e' um PFX com a chave privada do servidor. O handshake de cada
/// conexao roda depois, na reader thread dela (ver TPipeEndpoint.Handshake).
/// AKeyFile so e' usado pelo backend OpenSSL (PEM separado); no Schannel a
/// chave vem dentro do PFX e ACertPassword e' a senha dele.
function TlsPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal;
  const ACertFile, ACertPassword, AKeyFile: string): TPipeListener;

implementation

uses
  Pipes.Transport.Tcp;

{ TPipeTlsEndpoint }

constructor TPipeTlsEndpoint.Create(AInner: TPipeEndpoint;
  const ATargetName: string; AVerifyPeer: Boolean);
var
  LRaw: TPipeEndpointStream;
begin
  inherited Create;
  FInner := AInner; // posse assumida JA: se o handshake abaixo levantar, o
                    // destructor desta classe e' chamado e libera AInner — o
                    // chamador nao deve liberar nada depois de chamar Create.
  // TPipeEndpointStream nao e' dono do endpoint; o backend TLS passa a ser
  // dono DELE (nao do endpoint).
  //
  // Sem 'try/except LRaw.Free' aqui de proposito: o backend assume a posse de
  // LRaw na primeira linha do construtor dele, entao se o handshake falhar o
  // destructor DELE ja libera LRaw. Liberar aqui tambem seria double-free —
  // e' o que o cabecalho de Pipes.Transport.Schannel avisa, e o que uma versao
  // anterior deste adaptador fazia (EAccessViolation ao rejeitar certificado
  // invalido, justamente o caminho de erro que precisa funcionar).
  {$IFDEF PIPES_OPENSSL}
  LRaw := TPipeEndpointStream.Create(AInner);
  FTls := TPipeOpenSslStream.Create(LRaw, ATargetName, AVerifyPeer);
  {$ENDIF}
  {$IFDEF PIPES_SCHANNEL}
  LRaw := TPipeEndpointStream.Create(AInner);
  FTls := TPipeSchannelStream.Create(LRaw, ATargetName, AVerifyPeer);
  {$ENDIF}
  {$IFNDEF PIPES_TLS}
  raise EPipeTls.Create('build sem backend TLS: compile com PIPES_OPENSSL');
  {$ENDIF}
end;

constructor TPipeTlsEndpoint.CreateServer(AInner: TPipeEndpoint;
  ACertContext: Pointer; const ACertFile, AKeyFile: string);
var
  LRaw: TPipeEndpointStream;
begin
  inherited Create;
  FInner := AInner; // posse assumida ja (mesma regra do construtor cliente)
  LRaw := TPipeEndpointStream.Create(AInner);
  {$IFDEF PIPES_OPENSSL}
  FServerSsl := TPipeOpenSslServerStream.Create(LRaw, ACertFile, AKeyFile);
  FTls := FServerSsl;
  {$ENDIF}
  {$IFDEF PIPES_SCHANNEL}
  FServerTls := TPipeSchannelServerStream.Create(LRaw, ACertContext);
  FTls := FServerTls;
  {$ENDIF}
  {$IFNDEF PIPES_TLS}
  LRaw.Free;
  raise EPipeTls.Create('build sem backend TLS: compile com PIPES_OPENSSL');
  {$ENDIF}
end;

procedure TPipeTlsEndpoint.Handshake;
begin
  // So o lado servidor tem negociacao pendente; no cliente ela ja aconteceu
  // no construtor, na thread de quem chamou Connect.
  {$IFDEF PIPES_OPENSSL}
  if Assigned(FServerSsl) then
    FServerSsl.Negotiate;
  {$ENDIF}
  {$IFDEF PIPES_SCHANNEL}
  if Assigned(FServerTls) then
    FServerTls.Negotiate;
  {$ENDIF}
end;

destructor TPipeTlsEndpoint.Destroy;
begin
  // O stream TLS tenta o close_notify no proprio destructor (best-effort, ja
  // protegido la) e libera o TPipeEndpointStream. O endpoint TCP e' nosso.
  FTls.Free;
  FInner.Free;
  inherited;
end;

procedure TPipeTlsEndpoint.CloseAbort;
begin
  // Toda espera do backend TLS termina num Read/Write do endpoint de baixo:
  // abortar la desbloqueia a pilha inteira. Idempotente porque o do TCP e'.
  if Assigned(FInner) then
    FInner.CloseAbort;
end;

function TPipeTlsEndpoint.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := FTls.Read(ABuffer, ACount);
  // TStream sinaliza fim com 0; o contrato de TPipeEndpoint e' excecao.
  if Result <= 0 then
    raise EPipeClosed.Create('conexao TLS encerrada pelo par');
end;

procedure TPipeTlsEndpoint.WriteExactly(const ABuffer; ACount: Integer);
begin
  // Os backends escrevem tudo ou levantam; o laco e' rede de seguranca para
  // uma eventual escrita parcial.
  if FTls.Write(ABuffer, ACount) <> ACount then
    raise EPipeClosed.Create('escrita TLS incompleta');
end;

{ --- fabricas --- }

function TlsPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal; AVerifyPeer: Boolean): TPipeEndpoint;
var
  LTcp: TPipeEndpoint;
  LHost: string;
  LPort: Word;
begin
  // O host de Address e' o nome esperado no certificado (SNI + validacao).
  PipeParseHostPort(AAddress, LHost, LPort);
  LTcp := TcpPipeConnect(AAddress, ATimeoutMs, AKeepAliveSeconds);
  // Idem: TPipeTlsEndpoint.Create assume a posse de LTcp imediatamente, e o
  // destructor dele o libera se o handshake falhar. Nao ha nada a liberar aqui.
  Result := TPipeTlsEndpoint.Create(LTcp, LHost, AVerifyPeer);
end;

{ TPipeTlsListener }

constructor TPipeTlsListener.Create(AInner: TPipeListener;
  ACertContext: Pointer; const ACertFile, AKeyFile: string);
begin
  inherited Create;
  FInner := AInner;
  FCertContext := ACertContext;
  FCertFile := ACertFile;
  FKeyFile := AKeyFile;
end;

destructor TPipeTlsListener.Destroy;
begin
  FInner.Free;
  {$IFDEF PIPES_SCHANNEL}
  PipeSchannelFreeCert(FCertContext); // aceita nil
  {$ENDIF}
  inherited;
end;

function TPipeTlsListener.Accept: TPipeEndpoint;
var
  LTcp: TPipeEndpoint;
begin
  LTcp := FInner.Accept;
  if LTcp = nil then
    Exit(nil); // listener fechado
  // Sem handshake aqui de proposito: esta chamada roda na thread de accept.
  Result := TPipeTlsEndpoint.CreateServer(LTcp, FCertContext, FCertFile,
    FKeyFile);
end;

procedure TPipeTlsListener.Close;
begin
  FInner.Close;
end;

function TlsPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal;
  const ACertFile, ACertPassword, AKeyFile: string): TPipeListener;
var
  LTcp: TPipeListener;
  LCert: Pointer;
begin
  LCert := nil;
  {$IFDEF PIPES_OPENSSL}
  // OpenSSL le os arquivos PEM na hora da negociacao; nada a resolver aqui
  // alem de validar que foram informados.
  if (ACertFile = '') or (AKeyFile = '') then
    raise EPipeTls.Create('servidor TLS exige certificado e chave PEM');
  {$ENDIF}
  {$IFDEF PIPES_SCHANNEL}
  // Schannel resolve o PFX UMA vez: erro de senha/arquivo aparece agora, no
  // Listen, e nao so quando o primeiro cliente conectar.
  LCert := PipeSchannelLoadPfx(ACertFile, ACertPassword);
  {$ENDIF}
  {$IFNDEF PIPES_TLS}
  raise EPipeTls.Create('build sem backend TLS: compile com PIPES_OPENSSL');
  {$ENDIF}
  try
    LTcp := TcpPipeCreateListener(AAddress, AKeepAliveSeconds);
  except
    {$IFDEF PIPES_SCHANNEL}
    PipeSchannelFreeCert(LCert); // o listener nao chegou a assumir a posse
    {$ENDIF}
    raise;
  end;
  Result := TPipeTlsListener.Create(LTcp, LCert, ACertFile, AKeyFile);
end;

end.
