unit Pipes.Transport.OpenSSL;

{$I pipes.inc}

{ Backend TLS do ptTls via OpenSSL (libssl/libcrypto), multiplataforma.

  Compilado apenas sob a diretiva PIPES_OPENSSL (opt-in, definida pelo projeto
  consumidor — nunca automática): diferente do SChannel, que é garantido existir
  no Windows, o OpenSSL depende de libssl/libcrypto presentes na máquina. Sem a
  diretiva esta unit compila vazia e nada muda no build. Com ela, o OpenSSL é
  usado em QUALQUER plataforma (inclusive Windows, no lugar do SChannel).

  Mesma receita de Pipes.Transport.Tls (SChannel): bindings próprios contra a
  API pública (nada de código de terceiros — só as assinaturas da ABI), uma
  única unit compartilhada pelos dois compiladores. As bibliotecas são
  carregadas DINAMICAMENTE (dlopen/LoadLibrary) na primeira conexão TLS, com
  uma lista de sonames por versão (3.x preferida, 1.1.1 aceita): o binário não
  ganha dependência de link e, se a lib não estiver instalada, o erro só
  acontece — com mensagem clara — na primeira conexão ptTls. Os bindings se
  limitam a símbolos com a MESMA assinatura em 1.1.1 e 3.x.

  TPipeOpenSslStream é um TStream que envolve o stream de bytes crus (o
  TPipeSocketStream sobre o socket) e cifra/decifra por cima — mesmo contrato
  do TPipeSchannelStream, entao o transporte so troca a classe no branch de
  compilação. O engine SSL trabalha sobre um PAR DE BIOs DE MEMÓRIA (nunca
  sobre o fd do socket), por dois motivos que são invariantes da lib:

  - Os bytes crus continuam passando por FUnderlying.Read/Write: fechar o
    socket (reconexão/heartbeat) desbloqueia a thread de leitura exatamente
    como no caminho plain, em qualquer SO.
  - O objeto SSL do OpenSSL NÃO aceita SSL_read/SSL_write concorrentes — e na
    lib a thread de leitura lê enquanto outras threads escrevem (serializadas
    por FWriteLock, mas concorrentes com a leitura). Com BIOs de memória as
    chamadas SSL_* nunca bloqueiam (o bloqueio fica no FUnderlying.Read/Write,
    FORA do lock), então um TCriticalSection interno (FLock) protege o objeto
    SSL sem NUNCA ser segurado durante I/O de socket: o ciphertext produzido é
    drenado do BIO sob FLock e enviado depois de soltá-lo (ordem no fio
    garantida por FSendLock), e a leitura segue fluindo mesmo com um envio
    bloqueado em backpressure.

  Contrato de threading (igual ao contrato de Pipes.Transport): UM leitor
  (a thread de leitura) e escritores já serializados entre si; Read nunca é
  chamado concorrente com outro Read.

  Escopo: os dois lados. Cliente valida o servidor pela cadeia (trust store do
  sistema via SSL_CTX_set_default_verify_paths, ou a CA de CaFile) mais o
  hostname (SSL_set1_host); servidor valida o cliente sob mTLS
  (SSL_VERIFY_PEER + FAIL_IF_NO_PEER_CERT) e expõe a identidade dele
  (SSL_get1_peer_certificate — ver a nota de compatibilidade 1.1/3.x adiante).
  Há ainda o modo inseguro opt-in por SkipServerVerification (laboratório).

  Endereço por IP funciona: SSL_set1_host aceita '127.0.0.1' e o certificado de
  teste, que traz IP:127.0.0.1 no SAN, valida — medido, não presumido. (Uma
  versão anterior deste cabeçalho dizia que IP-SAN estava fora de escopo; era
  descrição do estado inicial da unit, não do comportamento atual.) }

interface

{$IFDEF PIPES_OPENSSL}

uses
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types; // EPipeTls

type
  { Stream TLS cliente sobre OpenSSL. Faz o handshake no construtor (síncrono,
    sobre o stream cru), depois cifra/decifra em Read/Write. É dono do stream
    de baixo (Free libera os dois). }
  TPipeOpenSslStream = class(TStream)
  private
    FUnderlying: TStream; // bytes crus (socket); TPipeOpenSslStream é dono
    // Protege o objeto SSL (leitor x escritores). NUNCA segurado durante I/O
    // de socket: quem drena o FBioOut envia fora dele (ver DrainBioOut).
    FLock: TCriticalSection;
    // Ordena o envio do ciphertext drenado: registros TLS fora de ordem no
    // fio derrubam a conexão (MAC/sequência). Adquirir SEMPRE antes de FLock.
    FSendLock: TCriticalSection;
    FCtx: Pointer;    // SSL_CTX*
    FSsl: Pointer;    // SSL* (dono dos dois BIOs após SSL_set_bio)
    FBioIn: Pointer;  // BIO de memória: ciphertext rede -> SSL
    FBioOut: Pointer; // BIO de memória: ciphertext SSL -> rede
    // AnsiString nos dois compiladores: a API OpenSSL recebe char* (hostname
    // ASCII; IDN exigiria punycode do chamador).
    FTargetName: AnsiString; // SNI / nome para validação
    FVerifyPeer: Boolean;
    FOptions: TPipeTlsOptions; // credenciais/politica (ver TPipeTlsOptions)
    function DrainBioOut: TBytes;    // esvazia FBioOut (chamar com FLock)
    procedure SendRaw(const AData: TBytes); // envia tudo (SEM FLock)
    procedure FlushBioOut;           // DrainBioOut+SendRaw; só handshake/shutdown
    procedure FlushBioOutBestEffort; // idem, engolindo falhas (caminho de Read)
    function ReadRawIntoBio: Boolean; // lê do socket (SEM FLock) e alimenta FBioIn
    procedure SetupSsl;
    procedure DoHandshake;
    procedure ShutdownTls;
  public
    /// Uso interno: inicializa campos SEM negociar (o lado servidor negocia
    /// depois, na reader thread da conexao).
    constructor CreateDeferred(AUnderlying: TStream);
    constructor Create(AUnderlying: TStream; const ATargetName: string;
      const AOptions: TPipeTlsOptions);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  { Stream TLS SERVIDOR sobre OpenSSL. Reaproveita quase tudo do cliente: os
    BIOs de memoria sao agnosticos de direcao e o proprio DoHandshake serve
    aos dois lados (SSL_do_handshake), porque a direcao e' escolhida por
    SSL_set_accept_state em vez de SSL_set_connect_state.

    So o setup difere: TLS_server_method, certificado + chave PEM, e nenhuma
    validacao do par (mTLS e' T4).

    Como no Schannel, a negociacao NAO acontece no construtor — quem dispara
    e' Negotiate, chamada pela reader thread da conexao. }
  TPipeOpenSslServerStream = class(TPipeOpenSslStream)
  private
    FOptions: TPipeTlsOptions;
    FNegotiated: Boolean;
    // Identidade do cliente sob mTLS. Preenchida uma unica vez, ao fim de
    // Negotiate, e imutavel depois — e' o que dispensa lock na leitura por
    // outra thread (ver TPipeServer.TryClientIdentity).
    FPeerIdentity: TPipePeerIdentity;
    FHasPeerIdentity: Boolean;
    procedure SetupServerSsl;
    procedure CapturePeerIdentity;
  public
    /// Le CertFile/KeyFile (PEM) como identidade do servidor. Se CaFile estiver
    /// preenchido, exige e valida certificado de CLIENTE contra essa CA (mTLS).
    constructor Create(AUnderlying: TStream;
      const AOptions: TPipeTlsOptions);
    /// Idempotente. Levanta EPipeTls se a negociacao falhar.
    procedure Negotiate;
    /// Identidade do cliente sob mTLS. False sem mTLS (nao ha certificado) ou
    /// antes de Negotiate.
    function TryPeerIdentity(out AIdentity: TPipePeerIdentity): Boolean;
  end;

{$ENDIF PIPES_OPENSSL}

implementation

{$IFDEF PIPES_OPENSSL}

// Delphi fora do Windows: LoadLibrary/GetProcAddress vêm do próprio SysUtils
// (já no uses da interface), então lá não há uses de implementation.
{$IFDEF FPC}
uses
  dynlibs;
{$ELSE}
  {$IFDEF MSWINDOWS}
uses
  Windows;
  {$ENDIF}
{$ENDIF}

{ ------------------------------------------------------------------------------
  Bindings OpenSSL (libssl/libcrypto). Assinaturas idênticas em 1.1.1 e 3.x;
  tudo cdecl. 'long' do C: 32 bits no Windows (LLP64), largura de ponteiro nos
  Unix (LP64) — por isso TSslLong/TSslULong.
  ------------------------------------------------------------------------------ }

type
  {$IFDEF PIPES_WINDOWS}
  TSslLong = LongInt;
  TSslULong = LongWord;
  {$ELSE}
  TSslLong = NativeInt;
  TSslULong = NativeUInt;
  {$ENDIF}

  TSslLibHandle = {$IFDEF FPC}TLibHandle{$ELSE}HMODULE{$ENDIF};

const
  // Pares (libcrypto, libssl) tentados em ordem; carregamos os DOIS handles
  // explicitamente porque no Windows GetProcAddress não enxerga dependências
  // (os símbolos ERR_*/BIO_* vivem no libcrypto). DLL de arquitetura errada
  // apenas falha o load e passa ao próximo par.
  {$IFDEF PIPES_WINDOWS}
  SSL_LIB_PAIRS: array[0..3, 0..1] of string = (
    ('libcrypto-3-x64.dll', 'libssl-3-x64.dll'),
    ('libcrypto-3.dll', 'libssl-3.dll'),
    ('libcrypto-1_1-x64.dll', 'libssl-1_1-x64.dll'),
    ('libcrypto-1_1.dll', 'libssl-1_1.dll'));
  {$ELSE}
  SSL_LIB_PAIRS: array[0..2, 0..1] of string = (
    ('libcrypto.so.3', 'libssl.so.3'),
    ('libcrypto.so.1.1', 'libssl.so.1.1'),
    ('libcrypto.so', 'libssl.so'));
  {$ENDIF}

  // SSL_get_error
  SSL_ERROR_WANT_READ   = 2;
  SSL_ERROR_WANT_WRITE  = 3;
  SSL_ERROR_ZERO_RETURN = 6;

  // SSL_CTX_set_verify
  SSL_VERIFY_NONE = 0;
  SSL_VERIFY_PEER = 1;

  // SSL_ctrl / SSL_CTX_ctrl (as "funções" SSL_set_min_proto_version e
  // SSL_set_tlsext_host_name são macros sobre estes cmds)
  SSL_CTRL_SET_TLSEXT_HOSTNAME    = 55;
  SSL_CTRL_SET_MIN_PROTO_VERSION  = 123;
  TLSEXT_NAMETYPE_HOST_NAME       = 0;
  TLS1_2_VERSION                  = $0303;
  // <openssl/ssl.h>: formato do arquivo de chave privada.
  SSL_FILETYPE_PEM = 1;
  // Sem FAIL_IF_NO_PEER_CERT o servidor PEDE o certificado mas aceita quem
  // nao mandar nenhum — mTLS que nao autentica nada.
  SSL_VERIFY_FAIL_IF_NO_PEER_CERT = 2;

  X509_V_OK = 0;
  NID_commonName = 13; // OID 2.5.4.3, estavel desde sempre no OpenSSL

  RAW_CHUNK = 16384; // leitura de socket por rodada (record TLS máx ~16KB)

var
  // libssl
  p_TLS_client_method: function: Pointer; cdecl;
  p_TLS_server_method: function: Pointer; cdecl;
  p_SSL_CTX_use_certificate_chain_file: function(ACtx: Pointer;
    AFile: PAnsiChar): Integer; cdecl;
  p_SSL_CTX_use_PrivateKey_file: function(ACtx: Pointer; AFile: PAnsiChar;
    AType: Integer): Integer; cdecl;
  p_SSL_CTX_check_private_key: function(ACtx: Pointer): Integer; cdecl;
  p_SSL_CTX_load_verify_locations: function(ACtx: Pointer;
    ACAfile, ACApath: PAnsiChar): Integer; cdecl;
  p_SSL_CTX_new: function(AMeth: Pointer): Pointer; cdecl;
  p_SSL_CTX_free: procedure(ACtx: Pointer); cdecl;
  p_SSL_CTX_ctrl: function(ACtx: Pointer; ACmd: Integer; ALarg: TSslLong;
    AParg: Pointer): TSslLong; cdecl;
  p_SSL_CTX_set_verify: procedure(ACtx: Pointer; AMode: Integer;
    ACallback: Pointer); cdecl;
  p_SSL_CTX_set_default_verify_paths: function(ACtx: Pointer): Integer; cdecl;
  p_SSL_new: function(ACtx: Pointer): Pointer; cdecl;
  p_SSL_free: procedure(ASsl: Pointer); cdecl;
  p_SSL_ctrl: function(ASsl: Pointer; ACmd: Integer; ALarg: TSslLong;
    AParg: Pointer): TSslLong; cdecl;
  p_SSL_set1_host: function(ASsl: Pointer; AHost: PAnsiChar): Integer; cdecl;
  p_SSL_set_bio: procedure(ASsl: Pointer; ARbio, AWbio: Pointer); cdecl;
  p_SSL_set_connect_state: procedure(ASsl: Pointer); cdecl;
  p_SSL_set_accept_state: procedure(ASsl: Pointer); cdecl;
  p_SSL_do_handshake: function(ASsl: Pointer): Integer; cdecl;
  p_SSL_read: function(ASsl: Pointer; ABuf: Pointer; ANum: Integer): Integer; cdecl;
  p_SSL_write: function(ASsl: Pointer; ABuf: Pointer; ANum: Integer): Integer; cdecl;
  p_SSL_get_error: function(ASsl: Pointer; ARet: Integer): Integer; cdecl;
  p_SSL_shutdown: function(ASsl: Pointer): Integer; cdecl;
  p_SSL_get_verify_result: function(ASsl: Pointer): TSslLong; cdecl;
  // Certificado do par. EXCECAO a regra "mesmo nome nos dois ramos" declarada
  // no cabecalho desta unit: o 1.1 chama SSL_get_peer_certificate e o 3.x
  // renomeou para SSL_get1_peer_certificate (no C um macro esconde isso; para
  // quem resolve simbolo em runtime, nao). A ASSINATURA e a semantica sao
  // identicas — os dois incrementam o refcount, entao o chamador sempre
  // X509_free. Resolvido por tentativa em SslLoad.
  //
  // O ramo antigo so' e' exercitado numa maquina onde a 3.x NAO exista (com as
  // duas instaladas o loader escolhe a 3.x): a suite roda nele em
  // debian:bullseye, que tem apenas libssl 1.1.1 — ver README, secao Testes.
  p_SSL_get_peer_certificate: function(ASsl: Pointer): Pointer; cdecl;
  // libcrypto
  p_BIO_new: function(AMethod: Pointer): Pointer; cdecl;
  p_BIO_s_mem: function: Pointer; cdecl;
  p_BIO_free: function(ABio: Pointer): Integer; cdecl;
  p_BIO_read: function(ABio: Pointer; ABuf: Pointer; ALen: Integer): Integer; cdecl;
  p_BIO_write: function(ABio: Pointer; ABuf: Pointer; ALen: Integer): Integer; cdecl;
  p_BIO_ctrl_pending: function(ABio: Pointer): NativeUInt; cdecl;
  p_ERR_get_error: function: TSslULong; cdecl;
  p_ERR_error_string_n: procedure(AErr: TSslULong; ABuf: PAnsiChar;
    ALen: NativeUInt); cdecl;
  p_ERR_clear_error: procedure; cdecl;
  // Extracao da identidade do par (nomes iguais em 1.1 e 3.x).
  p_X509_free: procedure(ACert: Pointer); cdecl;
  p_X509_get_subject_name: function(ACert: Pointer): Pointer; cdecl;
  p_X509_NAME_get_text_by_NID: function(AName: Pointer; ANid: Integer;
    ABuf: PAnsiChar; ALen: Integer): Integer; cdecl;
  p_X509_NAME_oneline: function(AName: Pointer; ABuf: PAnsiChar;
    ALen: Integer): PAnsiChar; cdecl;
  // Opcional (só para diagnóstico via PipeTlsBackendInfo); OpenSSL_version(0)
  // = OPENSSL_VERSION, a string completa 'OpenSSL x.y.z data'.
  p_OpenSSL_version: function(AType: Integer): PAnsiChar; cdecl;

  // Carregamento único por processo (as libs nunca são descarregadas).
  GLibLock: TCriticalSection;
  GLibLoaded: Boolean;
  GLibCrypto: TSslLibHandle;
  GLibSsl: TSslLibHandle;

function SslLoadLib(const AName: string): TSslLibHandle;
begin
  {$IFDEF FPC}
  Result := dynlibs.LoadLibrary(AName);
  {$ELSE}
  Result := LoadLibrary(PChar(AName));
  {$ENDIF}
end;

procedure SslFreeLib(AHandle: TSslLibHandle);
begin
  {$IFDEF FPC}
  dynlibs.FreeLibrary(AHandle);
  {$ELSE}
  FreeLibrary(AHandle);
  {$ENDIF}
end;

function SslGetProc(AHandle: TSslLibHandle; const AName: string): Pointer;
begin
  {$IFDEF FPC}
  Result := GetProcedureAddress(AHandle, AName);
  {$ELSE}
    {$IFDEF MSWINDOWS}
  // Winapi.Windows.GetProcAddress recebe LPCSTR (PAnsiChar); PChar aqui
  // seria PWideChar e nem compila. Nomes de símbolo são ASCII.
  Result := GetProcAddress(AHandle, PAnsiChar(AnsiString(AName)));
    {$ELSE}
  Result := GetProcAddress(AHandle, PChar(AName)); // SysUtils POSIX: PChar
    {$ENDIF}
  {$ENDIF}
end;

// Resolve um símbolo obrigatório; falha = instalação de OpenSSL quebrada.
function SslMustGet(AHandle: TSslLibHandle; const AName, ALib: string): Pointer;
begin
  Result := SslGetProc(AHandle, AName);
  if Result = nil then
    raise EPipeTls.CreateFmt('símbolo %s não encontrado em %s (OpenSSL incompatível?)',
      [AName, ALib]);
end;

// Carrega libcrypto+libssl (uma vez por processo) e resolve os símbolos.
procedure EnsureOpenSsl;
var
  I: Integer;
  LCrypto, LSsl: TSslLibHandle;
  LCryptoName, LSslName, LTried: string;
begin
  // Sem fast-path fora do lock: é chamado uma vez por conexão TLS (fora de
  // caminho quente) e a checagem dupla sem barreira de memória não seria
  // segura em CPU de ordenação fraca (ARM está no roadmap).
  GLibLock.Enter;
  try
    if GLibLoaded then
      Exit;

    LCrypto := 0;
    LSsl := 0;
    LCryptoName := '';
    LSslName := '';
    LTried := '';
    for I := Low(SSL_LIB_PAIRS) to High(SSL_LIB_PAIRS) do
    begin
      if LTried <> '' then
        LTried := LTried + ', ';
      LTried := LTried + SSL_LIB_PAIRS[I][1];
      LCrypto := SslLoadLib(SSL_LIB_PAIRS[I][0]);
      if LCrypto = 0 then
        Continue;
      LSsl := SslLoadLib(SSL_LIB_PAIRS[I][1]);
      if LSsl = 0 then
      begin
        SslFreeLib(LCrypto);
        LCrypto := 0;
        Continue;
      end;
      LCryptoName := SSL_LIB_PAIRS[I][0];
      LSslName := SSL_LIB_PAIRS[I][1];
      Break;
    end;
    if LSslName = '' then
      raise EPipeTls.CreateFmt(
        'OpenSSL não encontrado (tentados: %s). Instale libssl/libcrypto, ' +
        'ou use um transporte sem TLS (ptTcp/ptLocal).',
        [LTried]);

    try
      p_TLS_client_method := SslMustGet(LSsl, 'TLS_client_method', LSslName);
      p_SSL_CTX_new := SslMustGet(LSsl, 'SSL_CTX_new', LSslName);
      p_SSL_CTX_free := SslMustGet(LSsl, 'SSL_CTX_free', LSslName);
      p_SSL_CTX_ctrl := SslMustGet(LSsl, 'SSL_CTX_ctrl', LSslName);
      p_SSL_CTX_set_verify := SslMustGet(LSsl, 'SSL_CTX_set_verify', LSslName);
      p_SSL_CTX_set_default_verify_paths :=
        SslMustGet(LSsl, 'SSL_CTX_set_default_verify_paths', LSslName);
      p_SSL_new := SslMustGet(LSsl, 'SSL_new', LSslName);
      p_SSL_free := SslMustGet(LSsl, 'SSL_free', LSslName);
      p_SSL_ctrl := SslMustGet(LSsl, 'SSL_ctrl', LSslName);
      p_SSL_set1_host := SslMustGet(LSsl, 'SSL_set1_host', LSslName);
      p_SSL_set_bio := SslMustGet(LSsl, 'SSL_set_bio', LSslName);
      p_SSL_set_connect_state := SslMustGet(LSsl, 'SSL_set_connect_state', LSslName);
      p_SSL_set_accept_state := SslMustGet(LSsl, 'SSL_set_accept_state', LSslName);
      p_TLS_server_method := SslMustGet(LSsl, 'TLS_server_method', LSslName);
      p_SSL_CTX_use_certificate_chain_file :=
        SslMustGet(LSsl, 'SSL_CTX_use_certificate_chain_file', LSslName);
      p_SSL_CTX_use_PrivateKey_file :=
        SslMustGet(LSsl, 'SSL_CTX_use_PrivateKey_file', LSslName);
      p_SSL_CTX_check_private_key :=
        SslMustGet(LSsl, 'SSL_CTX_check_private_key', LSslName);
      p_SSL_CTX_load_verify_locations :=
        SslMustGet(LSsl, 'SSL_CTX_load_verify_locations', LSslName);
      p_SSL_do_handshake := SslMustGet(LSsl, 'SSL_do_handshake', LSslName);
      p_SSL_read := SslMustGet(LSsl, 'SSL_read', LSslName);
      p_SSL_write := SslMustGet(LSsl, 'SSL_write', LSslName);
      p_SSL_get_error := SslMustGet(LSsl, 'SSL_get_error', LSslName);
      p_SSL_shutdown := SslMustGet(LSsl, 'SSL_shutdown', LSslName);
      p_SSL_get_verify_result := SslMustGet(LSsl, 'SSL_get_verify_result', LSslName);

      p_BIO_new := SslMustGet(LCrypto, 'BIO_new', LCryptoName);
      p_BIO_s_mem := SslMustGet(LCrypto, 'BIO_s_mem', LCryptoName);
      p_BIO_free := SslMustGet(LCrypto, 'BIO_free', LCryptoName);
      p_BIO_read := SslMustGet(LCrypto, 'BIO_read', LCryptoName);
      p_BIO_write := SslMustGet(LCrypto, 'BIO_write', LCryptoName);
      p_BIO_ctrl_pending := SslMustGet(LCrypto, 'BIO_ctrl_pending', LCryptoName);
      p_ERR_get_error := SslMustGet(LCrypto, 'ERR_get_error', LCryptoName);
      p_ERR_error_string_n := SslMustGet(LCrypto, 'ERR_error_string_n', LCryptoName);
      p_ERR_clear_error := SslMustGet(LCrypto, 'ERR_clear_error', LCryptoName);
      p_X509_free := SslMustGet(LCrypto, 'X509_free', LCryptoName);
      p_X509_get_subject_name :=
        SslMustGet(LCrypto, 'X509_get_subject_name', LCryptoName);
      p_X509_NAME_get_text_by_NID :=
        SslMustGet(LCrypto, 'X509_NAME_get_text_by_NID', LCryptoName);
      p_X509_NAME_oneline :=
        SslMustGet(LCrypto, 'X509_NAME_oneline', LCryptoName);
      // O 3.x renomeou este; o 1.1 so tem o nome antigo. Tentar os dois e
      // exigir que UM exista — se nenhum existir, a identidade do par ficaria
      // silenciosamente vazia sob mTLS, que e' pior do que falhar ao carregar.
      p_SSL_get_peer_certificate := SslGetProc(LSsl, 'SSL_get1_peer_certificate');
      if not Assigned(p_SSL_get_peer_certificate) then
        p_SSL_get_peer_certificate :=
          SslMustGet(LSsl, 'SSL_get_peer_certificate', LSslName);
      // Opcional: falta do símbolo não é erro (fica só o nome do backend).
      p_OpenSSL_version := SslGetProc(LCrypto, 'OpenSSL_version');
    except
      // Instalação com símbolo faltando: descarrega pra não acumular uma
      // referência de load a cada nova tentativa de conexão.
      SslFreeLib(LSsl);
      SslFreeLib(LCrypto);
      raise;
    end;

    GLibCrypto := LCrypto;
    GLibSsl := LSsl;

    // Publica o que carregou de fato (versão + soname/DLL) pro chamador poder
    // exibir/logar via PipeTlsBackendInfo.
    if Assigned(p_OpenSSL_version) then
      PipeSetTlsBackendDetail(Format('%s (%s)',
        [string(AnsiString(p_OpenSSL_version(0))), LSslName]))
    else
      PipeSetTlsBackendDetail(Format('OpenSSL (%s)', [LSslName]));

    GLibLoaded := True;
  finally
    GLibLock.Leave;
  end;
end;

// Texto do erro mais recente da fila do OpenSSL ('' se vazia).
function LastSslErrorText: string;
var
  LCode: TSslULong;
  LBuf: array[0..255] of AnsiChar;
begin
  Result := '';
  LCode := p_ERR_get_error();
  if LCode = 0 then
    Exit;
  LBuf[0] := #0;
  p_ERR_error_string_n(LCode, @LBuf[0], SizeOf(LBuf));
  Result := string(AnsiString(PAnsiChar(@LBuf[0])));
end;

// Mensagem para uma falha de SSL_read/SSL_write/SSL_do_handshake.
function SslFailureText(AErr: Integer): string;
begin
  Result := LastSslErrorText;
  if Result = '' then
    Result := Format('SSL_get_error=%d', [AErr]);
end;

{ TPipeOpenSslStream }

// (declaracao adiantada: usada por SetupSsl do cliente, definida adiante)
procedure LoadIdentity(ACtx: Pointer; const AOptions: TPipeTlsOptions); forward;

constructor TPipeOpenSslStream.CreateDeferred(AUnderlying: TStream);
begin
  inherited Create;
  FUnderlying := AUnderlying;
  FLock := TCriticalSection.Create;
  FSendLock := TCriticalSection.Create;
end;

constructor TPipeOpenSslStream.Create(AUnderlying: TStream;
  const ATargetName: string; const AOptions: TPipeTlsOptions);
begin
  CreateDeferred(AUnderlying);
  FTargetName := AnsiString(ATargetName);
  FOptions := AOptions;
  FVerifyPeer := not AOptions.SkipServerVerification; // default valida
  // Se algo abaixo levantar, o destrutor (auto-chamado) libera o que existir
  // (handles guardados em campos) e o stream de baixo — nada de cleanup manual
  // aqui (seria double-free). Mesmo contrato do TPipeSchannelStream.
  EnsureOpenSsl;
  SetupSsl;
  DoHandshake;
end;

destructor TPipeOpenSslStream.Destroy;
begin
  try
    if FSsl <> nil then
      ShutdownTls;
  except
  end;
  if FSsl <> nil then
    p_SSL_free(FSsl) // libera também os dois BIOs (adotados por SSL_set_bio)
  else
  begin
    // Falha entre criar os BIOs e criar o SSL: ainda são nossos.
    if FBioIn <> nil then
      p_BIO_free(FBioIn);
    if FBioOut <> nil then
      p_BIO_free(FBioOut);
  end;
  if FCtx <> nil then
    p_SSL_CTX_free(FCtx);
  FUnderlying.Free;
  FSendLock.Free;
  FLock.Free;
  inherited;
end;

procedure TPipeOpenSslStream.SetupSsl;
var
  LTmp: AnsiString;
begin
  FCtx := p_SSL_CTX_new(p_TLS_client_method());
  if FCtx = nil then
    raise EPipeTls.CreateFmt('SSL_CTX_new falhou (%s)', [LastSslErrorText]);

  // Mínimo TLS 1.2, como no caminho SChannel (defaults modernos do sistema).
  p_SSL_CTX_ctrl(FCtx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil);

  if FVerifyPeer then
  begin
    p_SSL_CTX_set_verify(FCtx, SSL_VERIFY_PEER, nil);
    if FOptions.CaFile <> '' then
    begin
      // CA propria (frota com PKI interna): o certificado do servidor nao
      // esta no trust store do sistema, e nem deveria estar.
      LTmp := AnsiString(FOptions.CaFile);
      if p_SSL_CTX_load_verify_locations(FCtx, PAnsiChar(LTmp), nil) <> 1 then
        raise EPipeTls.CreateFmt('nao foi possivel carregar a CA %s (%s)',
          [FOptions.CaFile, LastSslErrorText]);
    end
    // Trust store do sistema (ex.: /etc/ssl/certs no Linux).
    else if p_SSL_CTX_set_default_verify_paths(FCtx) <> 1 then
      raise EPipeTls.CreateFmt('SSL_CTX_set_default_verify_paths falhou (%s)',
        [LastSslErrorText]);
  end
  else
    p_SSL_CTX_set_verify(FCtx, SSL_VERIFY_NONE, nil);

  // mTLS: o cliente so apresenta certificado se tiver um configurado.
  if FOptions.CertFile <> '' then
    LoadIdentity(FCtx, FOptions);

  // Ordem importa pro cleanup do destrutor: BIOs antes do SSL (se SSL_new
  // falhar, FSsl=nil e o destrutor libera os BIOs); SSL_set_bio logo em
  // seguida (não falha) transfere a posse dos dois pro SSL.
  FBioIn := p_BIO_new(p_BIO_s_mem());
  FBioOut := p_BIO_new(p_BIO_s_mem());
  if (FBioIn = nil) or (FBioOut = nil) then
    raise EPipeTls.Create('BIO_new(BIO_s_mem) falhou');
  FSsl := p_SSL_new(FCtx);
  if FSsl = nil then
    raise EPipeTls.CreateFmt('SSL_new falhou (%s)', [LastSslErrorText]);
  p_SSL_set_bio(FSsl, FBioIn, FBioOut);

  if FTargetName <> '' then
  begin
    // SNI (SSL_set_tlsext_host_name é macro sobre SSL_ctrl).
    p_SSL_ctrl(FSsl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_HOST_NAME,
      PAnsiChar(FTargetName));
    // Validação de hostname contra o cert (só faz sentido com verify).
    if FVerifyPeer and (p_SSL_set1_host(FSsl, PAnsiChar(FTargetName)) <> 1) then
      raise EPipeTls.Create('SSL_set1_host falhou');
  end;

  p_SSL_set_connect_state(FSsl);
end;

// Esvazia FBioOut (o ciphertext que o engine produziu) num buffer; devolve
// nil se não havia nada. Chamar segurando FLock — mas o ENVIO fica fora dele,
// pra nunca segurar o objeto SSL durante I/O de socket (um send bloqueado em
// backpressure não pode parar a thread de leitura, que precisa do FLock pra
// alimentar FBioIn). FSendLock, adquirido antes de FLock, garante que drenos
// concorrentes cheguem ao fio na ordem em que saíram do engine.
function TPipeOpenSslStream.DrainBioOut: TBytes;
var
  LTotal, LN: Integer;
begin
  Result := nil;
  LTotal := 0;
  while p_BIO_ctrl_pending(FBioOut) > 0 do
  begin
    SetLength(Result, LTotal + RAW_CHUNK);
    LN := p_BIO_read(FBioOut, @Result[LTotal], RAW_CHUNK);
    if LN <= 0 then
      Break;
    Inc(LTotal, LN);
  end;
  SetLength(Result, LTotal);
end;

// Envia o buffer inteiro no stream de baixo. Chamar SEM FLock (ver DrainBioOut).
procedure TPipeOpenSslStream.SendRaw(const AData: TBytes);
var
  LWritten, LNow: Integer;
begin
  LWritten := 0;
  while LWritten < Length(AData) do
  begin
    LNow := FUnderlying.Write(AData[LWritten], Length(AData) - LWritten);
    if LNow <= 0 then
      raise EPipeTls.Create('falha ao enviar dados TLS');
    Inc(LWritten, LNow);
  end;
end;

// Drena e envia numa tacada. Só pro handshake (construtor: nenhuma outra
// thread conhece o objeto, dispensa locks); os caminhos concorrentes drenam
// sob FLock e enviam fora dele.
procedure TPipeOpenSslStream.FlushBioOut;
begin
  SendRaw(DrainBioOut);
end;

// Flush do caminho de leitura (raro: resposta a mensagem pós-handshake que o
// SSL_read produziu). Best-effort dos dois lados:
// - TryEnter: se um escritor está com o FSendLock (possivelmente bloqueado num
//   send), não vale segurar a entrega dos bytes já decifrados — o dreno do
//   próprio escritor leva o pendente junto (e heartbeats garantem escritas
//   periódicas).
// - Falha de envio é engolida: perder este flush é melhor que perder os bytes
//   já decifrados (a falha do socket reaparece no próximo Read/Write).
procedure TPipeOpenSslStream.FlushBioOutBestEffort;
var
  LOut: TBytes;
begin
  if not FSendLock.TryEnter then
    Exit;
  try
    FLock.Enter;
    try
      LOut := DrainBioOut;
    finally
      FLock.Leave;
    end;
    try
      SendRaw(LOut);
    except
    end;
  finally
    FSendLock.Leave;
  end;
end;

// Lê um bloco do socket (bloqueante, SEM segurar FLock — é aqui que a thread
// de leitura espera) e o entrega ao engine (FBioIn, sob FLock). False = EOF.
function TPipeOpenSslStream.ReadRawIntoBio: Boolean;
var
  LBuf: array[0..RAW_CHUNK - 1] of Byte;
  LRead: Integer;
begin
  LRead := FUnderlying.Read(LBuf[0], RAW_CHUNK);
  if LRead <= 0 then
    Exit(False);
  FLock.Enter;
  try
    // BIO de memória cresce sob demanda: aceita o bloco inteiro.
    if p_BIO_write(FBioIn, @LBuf[0], LRead) <> LRead then
      raise EPipeTls.Create('BIO_write falhou');
  finally
    FLock.Leave;
  end;
  Result := True;
end;

procedure TPipeOpenSslStream.DoHandshake;
var
  LRet, LErr: Integer;
  LVerify: TSslLong;
begin
  // Síncrono, no construtor: nenhuma outra thread conhece este objeto ainda.
  p_ERR_clear_error();
  while True do
  begin
    LRet := p_SSL_do_handshake(FSsl);
    FlushBioOut; // envia o que foi produzido (ClientHello, Finished, ...)
    if LRet = 1 then
      Break; // handshake concluído
    LErr := p_SSL_get_error(FSsl, LRet);
    case LErr of
      SSL_ERROR_WANT_READ:
        if not ReadRawIntoBio then
          raise EPipeTls.Create('conexão fechada durante o handshake TLS');
      SSL_ERROR_WANT_WRITE:
        ; // já drenado pelo FlushBioOut acima
    else
      begin
        // Diferencia falha de validação de cert (a mais comum) das demais.
        LVerify := p_SSL_get_verify_result(FSsl);
        if FVerifyPeer and (LVerify <> X509_V_OK) then
          raise EPipeTls.CreateFmt(
            'validação do certificado do servidor falhou (X509 err %d; %s)',
            [Integer(LVerify), SslFailureText(LErr)]);
        raise EPipeTls.CreateFmt('handshake TLS falhou (%s)', [SslFailureText(LErr)]);
      end;
    end;
  end;
end;

function TPipeOpenSslStream.Read(var Buffer; Count: Longint): Longint;
var
  LRet, LErr: Integer;
  LHasOut: Boolean;
begin
  if Count <= 0 then
    Exit(0);
  try
    while True do
    begin
      FLock.Enter;
      try
        LRet := p_SSL_read(FSsl, @Buffer, Count);
        if LRet > 0 then
          LErr := 0
        else
          LErr := p_SSL_get_error(FSsl, LRet);
        LHasOut := p_BIO_ctrl_pending(FBioOut) > 0;
      finally
        FLock.Leave;
      end;
      if LHasOut then
        FlushBioOutBestEffort;
      if LRet > 0 then
        Exit(LRet);
      case LErr of
        SSL_ERROR_WANT_READ:
          if not ReadRawIntoBio then
            Exit(0); // conexão caiu: EOF pro framing
        SSL_ERROR_ZERO_RETURN:
          Exit(0);   // close_notify: servidor encerrou o TLS
      else
        Exit(0);     // erro TLS: framing trata como conexão encerrada
      end;
    end;
  except
    // Igual SChannel: Read sinaliza EOF, nunca propaga exceção — nem EPipeTls
    // nem um erro de socket do transporte (no Delphi, Receive pode levantar
    // ESocketError em vez de devolver <= 0).
    Exit(0);
  end;
end;

function TPipeOpenSslStream.Write(const Buffer; Count: Longint): Longint;
var
  LOffset, LChunk, LRet, LErr, LWaitedMs: Integer;
  P: PByte;
  LOut: TBytes;
begin
  P := @Buffer;
  LOffset := 0;
  while LOffset < Count do
  begin
    // Chunk + flush por rodada bounda a memória do FBioOut (uma mensagem
    // grande nunca acumula o ciphertext inteiro no BIO antes do 1º send).
    LChunk := Count - LOffset;
    if LChunk > RAW_CHUNK then
      LChunk := RAW_CHUNK;

    LWaitedMs := 0;
    repeat
      FSendLock.Enter;
      try
        FLock.Enter;
        try
          p_ERR_clear_error();
          LRet := p_SSL_write(FSsl, @P[LOffset], LChunk);
          if LRet <= 0 then
            LErr := p_SSL_get_error(FSsl, LRet)
          else
            LErr := 0;
          LOut := DrainBioOut;
        finally
          FLock.Leave;
        end;
        // Fora do FLock (a leitura segue fluindo); FSendLock garante a ordem.
        SendRaw(LOut);
      finally
        FSendLock.Leave;
      end;
      if LRet > 0 then
        Break;
      case LErr of
        SSL_ERROR_WANT_READ:
        begin
          // Engine precisa de bytes de entrada (renegociação/pós-handshake).
          // Quem alimenta FBioIn é a thread de leitura; aguarda e re-tenta.
          // Na prática não acontece com RabbitMQ (sem renegociação).
          Sleep(5);
          Inc(LWaitedMs, 5);
          if LWaitedMs > 10000 then
            raise EPipeTls.Create('timeout aguardando dados do servidor durante escrita TLS');
        end;
        SSL_ERROR_WANT_WRITE:
          ; // saída já drenada; re-tenta
      else
        raise EPipeTls.CreateFmt('falha ao enviar dados TLS (%s)', [SslFailureText(LErr)]);
      end;
    until False;

    // BIO de memória aceita tudo: SSL_write > 0 escreveu o chunk inteiro.
    Inc(LOffset, LRet);
  end;
  Result := Count;
end;

function TPipeOpenSslStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0; // silencia W5093; a excecao abaixo e que vale
  raise EPipeTls.Create('TPipeOpenSslStream não suporta Seek');
end;

procedure TPipeOpenSslStream.ShutdownTls;
var
  LOut: TBytes;
begin
  // Best-effort: avisa o servidor (close_notify). Falhas são ignoradas.
  FSendLock.Enter;
  try
    FLock.Enter;
    try
      p_SSL_shutdown(FSsl);
      LOut := DrainBioOut;
    finally
      FLock.Leave;
    end;
    try
      SendRaw(LOut);
    except
    end;
  finally
    FSendLock.Leave;
  end;
end;

// Carrega certificado + chave num SSL_CTX. Serve aos dois lados: identidade do
// servidor, ou certificado de cliente para mTLS.
procedure LoadIdentity(ACtx: Pointer; const AOptions: TPipeTlsOptions);
var
  LCert, LKey: AnsiString;
begin
  LCert := AnsiString(AOptions.CertFile);
  LKey := AnsiString(AOptions.KeyFile);
  if p_SSL_CTX_use_certificate_chain_file(ACtx, PAnsiChar(LCert)) <> 1 then
    raise EPipeTls.CreateFmt('nao foi possivel carregar o certificado %s (%s)',
      [AOptions.CertFile, LastSslErrorText]);
  if p_SSL_CTX_use_PrivateKey_file(ACtx, PAnsiChar(LKey),
       SSL_FILETYPE_PEM) <> 1 then
    raise EPipeTls.CreateFmt('nao foi possivel carregar a chave %s (%s)',
      [AOptions.KeyFile, LastSslErrorText]);
  // Detecta cedo o par cert/chave trocado: sem esta checagem o erro so
  // apareceria no handshake, longe da causa.
  if p_SSL_CTX_check_private_key(ACtx) <> 1 then
    raise EPipeTls.CreateFmt('a chave %s nao corresponde ao certificado %s (%s)',
      [AOptions.KeyFile, AOptions.CertFile, LastSslErrorText]);
end;

{ TPipeOpenSslServerStream }

constructor TPipeOpenSslServerStream.Create(AUnderlying: TStream;
  const AOptions: TPipeTlsOptions);
begin
  CreateDeferred(AUnderlying);
  if (AOptions.CertFile = '') or (AOptions.KeyFile = '') then
    raise EPipeTls.Create('servidor TLS exige certificado e chave');
  FOptions := AOptions;
  // No servidor, "verificar o par" significa exigir certificado de cliente, e
  // isso e' ligado por ter uma CA de clientes configurada.
  FVerifyPeer := AOptions.CaFile <> '';
end;

procedure TPipeOpenSslServerStream.Negotiate;
begin
  if FNegotiated then
    Exit;
  EnsureOpenSsl;
  SetupServerSsl;
  DoHandshake; // SSL_do_handshake serve aos dois lados
  // Depois do handshake: com SSL_VERIFY_PEER + FAIL_IF_NO_PEER_CERT, chegar
  // aqui ja significa que o certificado do cliente foi validado contra CaFile.
  CapturePeerIdentity;
  FNegotiated := True;
end;

// Le um campo de texto do subject. Devolve '' se o atributo nao existir.
function SslNameText(AName: Pointer; ANid: Integer): string;
var
  LBuf: array[0..255] of AnsiChar;
  LLen: Integer;
begin
  Result := '';
  LLen := p_X509_NAME_get_text_by_NID(AName, ANid, @LBuf[0], SizeOf(LBuf));
  if LLen > 0 then
    Result := string(AnsiString(PAnsiChar(@LBuf[0])));
end;

procedure TPipeOpenSslServerStream.CapturePeerIdentity;
var
  LCert: Pointer;
  LName: Pointer;
  LBuf: array[0..511] of AnsiChar;
begin
  // Sem mTLS o cliente nao apresenta nada e isto devolve nil — nao e' erro,
  // e' a ausencia de identidade.
  LCert := p_SSL_get_peer_certificate(FSsl);
  if LCert = nil then
    Exit;
  try
    LName := p_X509_get_subject_name(LCert);
    if LName = nil then
      Exit;
    FPeerIdentity.CommonName := SslNameText(LName, NID_commonName);
    if p_X509_NAME_oneline(LName, @LBuf[0], SizeOf(LBuf)) <> nil then
      FPeerIdentity.Subject := string(AnsiString(PAnsiChar(@LBuf[0])));
    FHasPeerIdentity := True;
  finally
    // Os dois nomes do getter incrementam o refcount: liberar sempre.
    p_X509_free(LCert);
  end;
end;

function TPipeOpenSslServerStream.TryPeerIdentity(
  out AIdentity: TPipePeerIdentity): Boolean;
begin
  Result := FHasPeerIdentity;
  if Result then
    AIdentity := FPeerIdentity
  else
  begin
    Finalize(AIdentity);
    FillChar(AIdentity, SizeOf(AIdentity), 0);
  end;
end;

procedure TPipeOpenSslServerStream.SetupServerSsl;
var
  LCa: AnsiString;
begin
  FCtx := p_SSL_CTX_new(p_TLS_server_method());
  if FCtx = nil then
    raise EPipeTls.CreateFmt('SSL_CTX_new(server) falhou (%s)',
      [LastSslErrorText]);

  // Mesmo piso do lado cliente e do SChannel.
  p_SSL_CTX_ctrl(FCtx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil);

  LoadIdentity(FCtx, FOptions);

  if FOptions.CaFile <> '' then
  begin
    // mTLS: so entra quem apresentar certificado assinado por esta CA.
    LCa := AnsiString(FOptions.CaFile);
    if p_SSL_CTX_load_verify_locations(FCtx, PAnsiChar(LCa), nil) <> 1 then
      raise EPipeTls.CreateFmt('nao foi possivel carregar a CA de clientes %s (%s)',
        [FOptions.CaFile, LastSslErrorText]);
    p_SSL_CTX_set_verify(FCtx,
      SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil);
  end
  else
    p_SSL_CTX_set_verify(FCtx, SSL_VERIFY_NONE, nil);

  // Mesma ordem de criacao do lado cliente, pela mesma razao de cleanup.
  FBioIn := p_BIO_new(p_BIO_s_mem());
  FBioOut := p_BIO_new(p_BIO_s_mem());
  if (FBioIn = nil) or (FBioOut = nil) then
    raise EPipeTls.Create('BIO_new(BIO_s_mem) falhou');
  FSsl := p_SSL_new(FCtx);
  if FSsl = nil then
    raise EPipeTls.CreateFmt('SSL_new falhou (%s)', [LastSslErrorText]);
  p_SSL_set_bio(FSsl, FBioIn, FBioOut);

  // A unica diferenca de direcao no handshake.
  p_SSL_set_accept_state(FSsl);
end;

initialization
  GLibLock := TCriticalSection.Create;

finalization
  GLibLock.Free;

{$ENDIF PIPES_OPENSSL}

end.
