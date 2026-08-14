unit Pipes.Transport;

{$I pipes.inc}

{ Camada de transporte abstrata: o contrato que os backends por plataforma
  (Pipes.Transport.Windows = Named Pipe overlapped; Pipes.Transport.Posix =
  Unix Domain Socket, milestone M4; Pipes.Transport.Android = socket TCP sobre
  as units Posix.* da RTL do Delphi, milestone A1) implementam.

  O Android e' o unico dos tres sem transporte LOCAL: la ptLocal e' recusado
  com mensagem propria (RaiseLocalUnsupported), nao cai em backend nenhum.

  Contrato de threads (herdado pela camada de cima):
  - Por endpoint: no maximo UMA thread em Read (a reader thread) e escritas
    serializadas por um write lock externo.
  - CloseAbort/Close sao thread-safe e idempotentes: e' o mecanismo para
    desbloquear uma thread presa em Read/WriteExactly/Accept a partir de
    OUTRA thread (Stop/Disconnect). Depois deles, o objeto so pode ser
    destruido apos o join das threads que o usavam.
  - Read/WriteExactly levantam EPipeClosed quando o par encerra ou quando a
    operacao e' abortada por CloseAbort; nunca devolvem 0. }

interface

uses
  SysUtils,
  Classes,
  Pipes.Types;

type
  { Uma conexao bidirecional estabelecida (lado cliente ou lado servidor). }
  TPipeEndpoint = class
  public
    /// Conclui a negociacao que o endpoint exigir antes do primeiro Read/Write
    /// (hoje so o TLS do lado servidor). Vazio nos transportes que nao
    /// negociam nada, que e' o caso de todos os locais e do TCP puro.
    ///
    /// Existe para tirar o handshake da thread de accept: quem chama e' a
    /// reader thread DA CONEXAO, entao um par que trave no meio da negociacao
    /// prende so a si mesmo. Feito no Accept, prenderia o loop de accept
    /// inteiro e um unico cliente ruim derrubaria o servidor para todos.
    procedure Handshake; virtual;
    /// Le ate ACount bytes (bloqueia ate haver pelo menos 1); devolve quantos
    /// leu (1..ACount). EPipeClosed se o par encerrou ou CloseAbort foi chamado.
    function Read(var ABuffer; ACount: Integer): Integer; virtual; abstract;
    /// Escreve exatamente ACount bytes (bloqueia ate concluir).
    procedure WriteExactly(const ABuffer; ACount: Integer); virtual; abstract;
    /// Aborta IO pendente e marca o endpoint como fechado. Thread-safe e
    /// idempotente; chamavel de qualquer thread. O handle/fd e' liberado de
    /// fato no destructor (apos o join da reader thread).
    procedure CloseAbort; virtual; abstract;
    /// Impoe um prazo as esperas de IO deste endpoint: passado ATimeoutMs sem
    /// o socket ficar pronto, Read/WriteExactly levantam EPipeTimeout em vez de
    /// esperar para sempre. 0 remove o prazo.
    ///
    /// Vale a partir da proxima espera e conta por espera, nao pela operacao
    /// inteira — serve para "o par parou de falar", nao como orcamento total.
    /// Chamar da propria thread que le/escreve.
    ///
    /// Existe para o handshake TLS (ver TPipeTlsEndpoint.Handshake), a unica
    /// fase em que o par ainda nao provou nada e ja consome uma thread. Fora
    /// dela o padrao continua sendo esperar indefinidamente e depender de
    /// CloseAbort/keepalive.
    ///
    /// O padrao NAO FAZ NADA: transportes que nao implementam simplesmente
    /// esperam sem prazo. Hoje so o TCP implementa, que e' o unico que o TLS
    /// envolve — um backend novo sob TLS precisa implementar isto tambem, ou o
    /// prazo some em silencio.
    procedure SetIoDeadline(ATimeoutMs: Cardinal); virtual;
    /// Quem e' o par, segundo o certificado que ele apresentou e que ja foi
    /// validado. False quando nao ha identidade verificada — o caso de todos
    /// os transportes sem TLS e do ptTls sem mTLS.
    ///
    /// So faz sentido chamar DEPOIS de Handshake: antes dele o par ainda nao
    /// apresentou nada.
    function TryPeerIdentity(out AIdentity: TPipePeerIdentity): Boolean; virtual;
    /// Endereco IP:porta do par do outro lado, formato 'host:porta' (IPv6
    /// entre colchetes, mesma convencao de PipeParseHostPort). False nos
    /// transportes sem rede — Named Pipe/UDS (ptLocal) nao tem endereco IP,
    /// so' um handle/fd local; nao ha "ainda nao chegou" aqui, e' sempre
    /// assim para esse transporte.
    function TryPeerAddress(out AAddress: string): Boolean; virtual;
  end;

  { Ponto de escuta do servidor. }
  TPipeListener = class
  public
    /// Espera a proxima conexao. Devolve nil (sem excecao) quando Close foi
    /// chamado. Chamar de UMA unica thread (a acceptor thread).
    function Accept: TPipeEndpoint; virtual; abstract;
    /// Desbloqueia um Accept pendente e impede novos. Thread-safe e
    /// idempotente. Destruir o listener so apos o join da acceptor thread.
    procedure Close; virtual; abstract;
  end;

  { Buffer cru para getpeername (TryPeerAddress dos backends TCP/TLS):
    sockaddr_in/sockaddr_in6 tem o MESMO layout de campos no Windows e no
    POSIX (familia + porta em network byte order + endereco) — so' a
    constante da familia do IPv6 diverge entre eles (23 no Windows, 10 no
    Linux), e cada backend usa a sua. Declarado aqui, e nao importado da unit
    de socket de cada compilador, pelo mesmo motivo de TPipeAddrInfo em
    Pipes.Transport.Tcp.pas: layout que precisa ser IGUAL nos dois lados nao
    pode depender de como cada unit o tipa — e fica AQUI (nao em cada backend)
    justamente para servir aos dois sem duplicar a struct. }
  TPipeRawSockAddrIn = record
    sin_family: Word;
    sin_port: Word;               // network byte order (big-endian)
    sin_addr: array[0..3] of Byte;
    sin_zero: array[0..7] of Byte;
  end;

  TPipeRawSockAddrIn6 = record
    sin6_family: Word;
    sin6_port: Word;               // network byte order
    sin6_flowinfo: LongWord;
    sin6_addr: array[0..15] of Byte;
    sin6_scope_id: LongWord;
  end;

  TPipeRawSockAddrStorage = record
  case Integer of
    0: (Family: Word);
    1: (V4: TPipeRawSockAddrIn);
    2: (V6: TPipeRawSockAddrIn6);
    3: (Pad: array[0..127] of Byte); // folga (sockaddr_storage real e' assim)
  end;

  { Adapta um TPipeEndpoint como TStream para PipeReadFrame/PipeWriteFrame.
    Nao e' dono do endpoint. Nao-seekable (Seek devolve 0). }
  TPipeEndpointStream = class(TStream)
  private
    FEndpoint: TPipeEndpoint;
  public
    constructor Create(AEndpoint: TPipeEndpoint);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

const
  /// Familia IPv4 do socket: mesmo valor no Windows e no POSIX, ao contrario
  /// de IPv6 (23 no Windows, 10 no Linux — por isso cada backend declara a
  /// sua propria constante de familia v6).
  PIPE_AF_INET = 2;

/// 'aaaa:bbbb:...' (8 grupos hex, sem zeros a esquerda), sem a compressao de
/// zeros ('::') do formato canonico — mais verboso, mas continua um IPv6
/// valido e reconectavel, o suficiente para log/exibicao em TryPeerAddress
/// sem o codigo extra de achar o maior grupo de zeros consecutivos.
function PipeFormatIPv6(const AAddr: array of Byte): string;

// --- Fabricas por plataforma -------------------------------------------------

/// Cria o ponto de escuta do servidor para o endereco dado (ja deixa a primeira
/// instancia/socket pronta: um cliente pode conectar antes do primeiro Accept).
///
/// A forma sem ATlsOptions RECUSA ptTls: sem credenciais nao ha servidor TLS
/// possivel, e cair para texto claro por omissao seria a pior saida.
function PipeCreateListener(const AAddress: string;
  ATransport: TPipeTransport = ptLocal;
  AKeepAliveSeconds: Cardinal = 0): TPipeListener; overload;
function PipeCreateListener(const AAddress: string;
  ATransport: TPipeTransport; AKeepAliveSeconds: Cardinal;
  const ATlsOptions: TPipeTlsOptions): TPipeListener; overload;

/// Conecta ao servidor, re-tentando ate ATimeoutMs (cobre servidor ainda nao
/// iniciado e instancias momentaneamente ocupadas). EPipeTimeout no prazo.
///
/// Mesma regra da forma sem ATlsOptions: ptTls e' recusado. No cliente as
/// credenciais podem ate' ser vazias (TLS so' de servidor), mas a politica de
/// validacao vem de la — silenciar isso seria conectar sem validar nada.
function PipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  ATransport: TPipeTransport = ptLocal;
  AKeepAliveSeconds: Cardinal = 0): TPipeEndpoint; overload;
function PipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  ATransport: TPipeTransport; AKeepAliveSeconds: Cardinal;
  const ATlsOptions: TPipeTlsOptions): TPipeEndpoint; overload;

/// Nome nativo do pipe: '\\.\pipe\<nome>' no Windows, '/tmp/<nome>.sock' no
/// POSIX. Se AAddress ja for um caminho nativo ('\\...' ou '/...'), e' usado
/// como esta (permite controlar o diretorio do socket no Linux). So faz
/// sentido para ptLocal.
function PipeNativeName(const AAddress: string): string;

/// Quebra 'host:porta' em partes. Aceita IPv6 entre colchetes ('[::1]:5000')
/// e '*' como atalho de '0.0.0.0'. EPipeError se malformado. So faz sentido
/// para ptTcp.
procedure PipeParseHostPort(const AAddress: string; out AHost: string;
  out APort: Word);

/// Garante que AAddress e' plausivel para ATransport; EPipeError com mensagem
/// util caso contrario (ex.: Create('\\.\pipe\X', ptTcp) falha aqui, e nao
/// mais tarde num erro obscuro de resolucao de nome).
procedure PipeValidateAddress(const AAddress: string;
  ATransport: TPipeTransport);

implementation

uses
  // Pipes.Transport.Tls usa ESTA unit na interface; a dependencia so' fecha
  // porque aqui e' na implementation.
  Pipes.Transport.Tcp,
  Pipes.Transport.Tls
{$IFDEF PIPES_WINDOWS}
  , Pipes.Transport.Windows
{$ELSE}
  {$IFNDEF PIPES_ANDROID}
  // Android nao tem transporte local (ver PipeNativeName abaixo), entao nao ha
  // backend de ptLocal a referenciar.
  , Pipes.Transport.Posix
  {$ENDIF}
{$ENDIF}
  ;

{ TPipeEndpoint }

procedure TPipeEndpoint.Handshake;
begin
  // Nada a negociar por padrao.
end;

procedure TPipeEndpoint.SetIoDeadline(ATimeoutMs: Cardinal);
begin
  // Sem prazo por padrao (ver o comentario da declaracao).
end;

function TPipeEndpoint.TryPeerIdentity(
  out AIdentity: TPipePeerIdentity): Boolean;
begin
  // Transporte sem TLS nao tem certificado do par. Identidade por credencial
  // do SO (SO_PEERCRED, GetNamedPipeClientProcessId) e' outra coisa — uid/pid,
  // nao um nome — e ficaria errada atras desta mesma API.
  Finalize(AIdentity);
  FillChar(AIdentity, SizeOf(AIdentity), 0);
  Result := False;
end;

function TPipeEndpoint.TryPeerAddress(out AAddress: string): Boolean;
begin
  AAddress := '';
  Result := False;
end;

function PipeFormatIPv6(const AAddr: array of Byte): string;
var
  I: Integer;
  LGroup: Word;
begin
  Result := '';
  for I := 0 to 7 do
  begin
    LGroup := (Word(AAddr[I * 2]) shl 8) or AAddr[I * 2 + 1];
    if I > 0 then
      Result := Result + ':';
    Result := Result + LowerCase(IntToHex(LGroup, 1));
  end;
end;

{ TPipeEndpointStream }

constructor TPipeEndpointStream.Create(AEndpoint: TPipeEndpoint);
begin
  inherited Create;
  FEndpoint := AEndpoint;
end;

function TPipeEndpointStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := FEndpoint.Read(Buffer, Count);
end;

function TPipeEndpointStream.Write(const Buffer; Count: Longint): Longint;
begin
  FEndpoint.WriteExactly(Buffer, Count);
  Result := Count;
end;

function TPipeEndpointStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0; // nao-seekable (mesmo contrato do TAMQPSocketStream)
end;

{ --- fabricas --- }

{$IFDEF PIPES_ANDROID}
// ptLocal nao existe no Android e a recusa e' explicita, num unico lugar: app
// Android e' single-process (nao ha o cenario de IPC local que justifica Named
// Pipe/UDS) e expor um socket de dominio Unix esbarra em sandboxing. Ver
// docs/ARQUITETURA.md secao 13.1. Sem esta mensagem, quem esquecesse de trocar
// o Transport ao portar um app veria um erro obscuro de "unit nao encontrada"
// em compilacao ou de socket em runtime.
procedure RaiseLocalUnsupported;
begin
  raise EPipeError.Create('ptLocal (Named Pipe/UDS) nao existe no Android; ' +
    'use Transport := ptTcp ou ptTls com Address no formato "host:porta"');
end;
{$ENDIF}

function PipeNativeName(const AAddress: string): string;
begin
  if AAddress = '' then
    raise EPipeError.Create('nome do pipe vazio');
  {$IFDEF PIPES_ANDROID}
  Result := '';
  RaiseLocalUnsupported;
  {$ELSE}
  {$IFDEF PIPES_WINDOWS}
  if Pos('\\', AAddress) = 1 then
    Result := AAddress // ja e' um caminho nativo (\\.\pipe\... ou \\server\pipe\...)
  else
    Result := '\\.\pipe\' + AAddress;
  {$ELSE}
  if AAddress[1] = '/' then
    Result := AAddress // caminho absoluto de socket, controlado pelo chamador
  else
    Result := '/tmp/' + AAddress + '.sock';
  {$ENDIF}
  {$ENDIF}
end;

procedure PipeParseHostPort(const AAddress: string; out AHost: string;
  out APort: Word);
var
  LSep, LPortVal, LErr: Integer;
  LPortStr: string;
begin
  AHost := '';
  APort := 0;
  if AAddress = '' then
    raise EPipeError.Create('endereco vazio');
  if AAddress[1] = '[' then
  begin
    // IPv6 literal: o separador e' o ':' DEPOIS do ']', pois o proprio
    // endereco esta cheio de ':'.
    LSep := Pos(']', AAddress);
    if LSep = 0 then
      raise EPipeError.CreateFmt('endereco IPv6 sem "]": %s', [AAddress]);
    AHost := Copy(AAddress, 2, LSep - 2);
    if (Length(AAddress) <= LSep) or (AAddress[LSep + 1] <> ':') then
      raise EPipeError.CreateFmt('endereco sem porta: %s', [AAddress]);
    LPortStr := Copy(AAddress, LSep + 2, MaxInt);
  end
  else
  begin
    LSep := LastDelimiter(':', AAddress);
    if LSep = 0 then
      raise EPipeError.CreateFmt(
        'endereco sem porta: %s (esperado "host:porta")', [AAddress]);
    AHost := Copy(AAddress, 1, LSep - 1);
    LPortStr := Copy(AAddress, LSep + 1, MaxInt);
  end;
  if AHost = '' then
    raise EPipeError.CreateFmt('endereco sem host: %s', [AAddress]);
  if AHost = '*' then
    AHost := '0.0.0.0'; // atalho para "escutar em todas as interfaces"
  Val(LPortStr, LPortVal, LErr);
  if (LErr <> 0) or (LPortVal < 1) or (LPortVal > 65535) then
    raise EPipeError.CreateFmt('porta invalida em %s: "%s" (1..65535)',
      [AAddress, LPortStr]);
  APort := Word(LPortVal);
end;

procedure PipeValidateAddress(const AAddress: string;
  ATransport: TPipeTransport);
var
  LHost: string;
  LPort: Word;
begin
  if AAddress = '' then
    raise EPipeError.Create('Address vazio');
  // Sem 'else': um transporte novo que esqueca de entrar aqui passaria sem
  // validacao nenhuma. O else torna esse esquecimento barulhento.
  case ATransport of
    ptLocal:
      {$IFDEF PIPES_ANDROID}
      RaiseLocalUnsupported
      {$ELSE}
      // qualquer nome/caminho serve; PipeNativeName resolve
      {$ENDIF}
      ;
    ptTcp, ptTls:
      begin
        // ptTls e' TCP por baixo: mesmo Address, mesma validacao.
        if (Pos('\\', AAddress) = 1) or (AAddress[1] = '/') then
          raise EPipeError.CreateFmt(
            'Address "%s" e um caminho local, incompativel com o transporte ' +
            'escolhido (esperado "host:porta")', [AAddress]);
        PipeParseHostPort(AAddress, LHost, LPort); // valida o formato
      end;
  else
    raise EPipeError.CreateFmt('transporte desconhecido (%d)', [Ord(ATransport)]);
  end;
end;

// Erro comum as duas fabricas sem opcoes TLS.
procedure RaiseTlsNeedsOptions;
begin
  raise EPipeTls.Create('ptTls exige TlsOptions (certificado e politica de ' +
    'validacao); use a forma que recebe TPipeTlsOptions');
end;

function PipeCreateListener(const AAddress: string;
  ATransport: TPipeTransport; AKeepAliveSeconds: Cardinal): TPipeListener;
begin
  if ATransport = ptTls then
    RaiseTlsNeedsOptions;
  PipeValidateAddress(AAddress, ATransport);
  if ATransport = ptTcp then
    Exit(TcpPipeCreateListener(AAddress, AKeepAliveSeconds));
  // Daqui para baixo so' resta ptLocal. No Android e' inalcancavel (o
  // PipeValidateAddress acima ja recusou), mas ainda precisa compilar.
  {$IFDEF PIPES_ANDROID}
  Result := nil;
  RaiseLocalUnsupported;
  {$ELSE}
  {$IFDEF PIPES_WINDOWS}
  Result := WinPipeCreateListener(AAddress);
  {$ELSE}
  Result := PosixPipeCreateListener(AAddress);
  {$ENDIF}
  {$ENDIF}
end;

function PipeCreateListener(const AAddress: string;
  ATransport: TPipeTransport; AKeepAliveSeconds: Cardinal;
  const ATlsOptions: TPipeTlsOptions): TPipeListener;
begin
  if ATransport <> ptTls then
    Exit(PipeCreateListener(AAddress, ATransport, AKeepAliveSeconds));
  PipeValidateAddress(AAddress, ATransport);
  Result := TlsPipeCreateListener(AAddress, AKeepAliveSeconds, ATlsOptions);
end;

function PipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  ATransport: TPipeTransport; AKeepAliveSeconds: Cardinal): TPipeEndpoint;
begin
  if ATransport = ptTls then
    RaiseTlsNeedsOptions;
  PipeValidateAddress(AAddress, ATransport);
  if ATransport = ptTcp then
    Exit(TcpPipeConnect(AAddress, ATimeoutMs, AKeepAliveSeconds));
  // Idem ao listener: inalcancavel no Android, mas precisa compilar.
  {$IFDEF PIPES_ANDROID}
  Result := nil;
  RaiseLocalUnsupported;
  {$ELSE}
  {$IFDEF PIPES_WINDOWS}
  Result := WinPipeConnect(AAddress, ATimeoutMs);
  {$ELSE}
  Result := PosixPipeConnect(AAddress, ATimeoutMs);
  {$ENDIF}
  {$ENDIF}
end;

function PipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  ATransport: TPipeTransport; AKeepAliveSeconds: Cardinal;
  const ATlsOptions: TPipeTlsOptions): TPipeEndpoint;
begin
  if ATransport <> ptTls then
    Exit(PipeConnect(AAddress, ATimeoutMs, ATransport, AKeepAliveSeconds));
  PipeValidateAddress(AAddress, ATransport);
  Result := TlsPipeConnect(AAddress, ATimeoutMs, AKeepAliveSeconds, ATlsOptions);
end;

end.
