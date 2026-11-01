unit Pipes.Transport.Posix;

{$I pipes.inc}

{ Transporte POSIX local (ptLocal): Unix Domain Sockets (AF_UNIX, SOCK_STREAM).

  Desde a 0.4.0 esta unit so' MONTA o socket (caminho, unlink, bind/listen ou
  connect com re-tentativa) e entrega o fd a TPcPosixSocketEndpoint/
  TPcPosixSocketListener da pascal-common-faa (PascalCommon.Transport.Posix),
  as mesmas classes que servem o TCP de la — o fd de um UDS e o de um socket
  TCP sao o mesmo objeto para poll/recv/send. Antes havia uma copia dessas
  classes aqui; a da common traz de quebra o MSG_DONTWAIT em recv/send, sem o
  qual um prazo de escrita nunca disparava numa escrita grande (gotcha 15 da
  common).

  Invariantes que valem para o fd (implementadas na common):
  - Interrupcao de IO blocante = self-pipe + fpPoll; CloseAbort/Close
    escrevem 1 byte no self-pipe, e o endpoint faz fpShutdown(SHUT_RDWR).
  - O fd so e' fechado no destructor (apos o join da reader/acceptor thread).
  - Escritas sempre com MSG_NOSIGNAL: par que morre gera EPIPE (EPipeClosed na
    fronteira), nunca SIGPIPE.
  - O listener e' dono do arquivo de socket: unlink antes do bind (aqui; limpa
    socket orfao de crash anterior) e de novo no destructor (na common, pelo
    AUnlinkPath).

  Seguranca: o socket e' criado com a umask do processo no diretorio escolhido
  (padrao /tmp). Restringir o acesso = criar em diretorio proprio com
  permissoes adequadas e passar o caminho absoluto como Address. }

interface

{$IFDEF PIPES_POSIX}

uses
  SysUtils,
  PascalCommon.Transport;

/// Socket AF_UNIX em listen no caminho de PipeNativeName(AAddress).
function PosixPipeCreateListener(const AAddress: string): TPcListener;
/// Conecta, re-tentando ate ATimeoutMs enquanto o socket nao existir
/// (ENOENT) ou ninguem escutar (ECONNREFUSED). EPcTransportTimeout no prazo.
function PosixPipeConnect(const AAddress: string;
  ATimeoutMs: Cardinal): TPcEndpoint;

{$ENDIF}

implementation

{$IFDEF PIPES_POSIX}

uses
  UnixType,
  BaseUnix,
  Sockets,
  PascalCommon.Threading,
  PascalCommon.Transport.Posix,
  Pipes.Transport;

const
  PIPE_LISTEN_BACKLOG = 128;

// Caminho -> sockaddr_un; valida o limite de sun_path (107 chars + #0).
// Preenchimento manual: o helper Str2UnixSockAddr esta deprecated no FPC.
procedure BuildUnixAddr(const APath: string; out AAddr: TUnixSockAddr;
  out ALen: Longint);
begin
  if Length(APath) >= SizeOf(AAddr.path) then
    raise EPcTransport.CreateFmt(
      'socket path too long (%d chars; maximum %d): %s',
      [Length(APath), SizeOf(AAddr.path) - 1, APath]);
  FillChar(AAddr, SizeOf(AAddr), 0);
  AAddr.family := AF_UNIX;
  Move(APath[1], AAddr.path[0], Length(APath));
  ALen := SizeOf(AAddr.family) + Length(APath) + 1; // familia + path + #0
end;

function PosixPipeCreateListener(const AAddress: string): TPcListener;
var
  LNative: string;
  LAddr: TUnixSockAddr;
  LLen: Longint;
  LFd, LErr: cint;
begin
  LNative := PipeNativeName(AAddress);
  BuildUnixAddr(LNative, LAddr, LLen);
  LFd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if LFd < 0 then
    PcRaisePosixError('socket(AF_UNIX)', fpgeterrno);
  fpUnlink(LNative); // socket orfao de execucao anterior (crash sem unlink)
  if fpBind(LFd, psockaddr(@LAddr), LLen) <> 0 then
  begin
    LErr := fpgeterrno;
    fpClose(LFd);
    PcRaisePosixError(Format('bind(%s)', [LNative]), LErr);
  end;
  if fpListen(LFd, PIPE_LISTEN_BACKLOG) <> 0 then
  begin
    LErr := fpgeterrno;
    fpClose(LFd);
    fpUnlink(LNative);
    PcRaisePosixError(Format('listen(%s)', [LNative]), LErr);
  end;
  // A partir daqui o fd e o arquivo sao do listener (inclusive se o
  // construtor levantar: o destructor dele fecha e remove).
  Result := TPcPosixSocketListener.Create(LFd, LNative);
end;

function PosixPipeConnect(const AAddress: string;
  ATimeoutMs: Cardinal): TPcEndpoint;
var
  LNative: string;
  LAddr: TUnixSockAddr;
  LLen: Longint;
  LDeadline: UInt64;
  LFd, LErr: cint;
begin
  LNative := PipeNativeName(AAddress);
  BuildUnixAddr(LNative, LAddr, LLen);
  LDeadline := PcTickMs + ATimeoutMs;
  while True do
  begin
    LFd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
    if LFd < 0 then
      PcRaisePosixError('socket(AF_UNIX)', fpgeterrno);
    if fpConnect(LFd, psockaddr(@LAddr), LLen) = 0 then
      Exit(TPcPosixSocketEndpoint.Create(LFd));
    LErr := fpgeterrno;
    fpClose(LFd);
    // ENOENT = servidor ainda nao criou o socket; ECONNREFUSED = arquivo
    // existe mas ninguem escuta (servidor reiniciando ou backlog cheio).
    // Ambos re-tentam ate o prazo — e' o que da semantica uniforme de
    // Connect(timeout) nas duas plataformas.
    if (LErr <> ESysENOENT) and (LErr <> ESysECONNREFUSED) then
      PcRaisePosixError(Format('connect to socket %s', [LNative]), LErr);
    if Int64(LDeadline) - Int64(PcTickMs) <= 0 then
      raise EPcTransportTimeout.CreateFmt(
        'timeout (%u ms) connecting to socket %s', [ATimeoutMs, LNative]);
    Sleep(25); // servidor ausente/ocupado: polling curto
  end;
end;

{$ENDIF}

end.
