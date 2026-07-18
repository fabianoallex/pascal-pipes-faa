unit Pipes.Transport.Posix;

{$I pipes.inc}

{ Transporte POSIX: Unix Domain Sockets (AF_UNIX, SOCK_STREAM).

  Interrupcao de IO blocante = self-pipe: cada endpoint/listener tem um par
  fpPipe proprio e toda espera e' um fpPoll no par [fd da operacao, lado de
  leitura do self-pipe]. CloseAbort/Close escrevem 1 byte no self-pipe (acorda
  o poll) e, no endpoint, fpShutdown(SHUT_RDWR) desarma qualquer read/write
  residual no kernel. Nenhuma espera usa timeout de polling: acordar e' sempre
  por evento.

  Invariantes (alem do contrato de Pipes.Transport):
  - FClosed atomico; o self-pipe nunca e' drenado apos o CloseAbort, entao
    qualquer espera futura acorda na hora e levanta EPipeClosed.
  - O fd so e' fechado no destructor (apos o join da reader/acceptor thread
    na camada de cima) — fechar um fd com outra thread ainda dentro de um
    fpPoll arriscaria IO num fd reciclado pelo kernel.
  - Escritas sempre com MSG_NOSIGNAL: par que morre gera EPIPE (tratado como
    EPipeClosed), nunca SIGPIPE (que mataria o processo inteiro).
  - O listener e' o dono do arquivo de socket: unlink antes do bind (limpa
    socket orfao de crash anterior) e de novo no destructor.

  Seguranca: o socket e' criado com a umask do processo no diretorio escolhido
  (padrao /tmp). Restringir o acesso = criar em diretorio proprio com
  permissoes adequadas e passar o caminho absoluto como Address. }

interface

{$IFDEF PIPES_POSIX}

uses
  UnixType,
  BaseUnix,
  Sockets,
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Transport;

type
  TPipePosixEndpoint = class(TPipeEndpoint)
  private
    FFd: cint;
    FStopR: cint;     // self-pipe: lado de leitura (entra em todo fpPoll)
    FStopW: cint;     // self-pipe: lado de escrita (CloseAbort escreve 1 byte)
    FClosed: Integer; // atomico: 1 apos CloseAbort
    /// Espera o fd ficar pronto (AEvents) ou o stop sinalizar (EPipeClosed).
    procedure WaitReadyOrStop(AEvents: SmallInt; const AOp: string);
  public
    /// Assume a posse de AFd (socket conectado).
    constructor Create(AFd: cint);
    destructor Destroy; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
  end;

  TPipePosixListener = class(TPipeListener)
  private
    FNativePath: string;
    FFd: cint;        // socket de escuta
    FStopR: cint;     // self-pipe: lado de leitura
    FStopW: cint;     // self-pipe: lado de escrita (Close escreve 1 byte)
    FClosed: Integer; // atomico
  public
    constructor Create(const AAddress: string);
    destructor Destroy; override;
    function Accept: TPipeEndpoint; override;
    procedure Close; override;
  end;

function PosixPipeCreateListener(const AAddress: string): TPipeListener;
function PosixPipeConnect(const AAddress: string; ATimeoutMs: Cardinal): TPipeEndpoint;

{$ENDIF}

implementation

{$IFDEF PIPES_POSIX}

const
  // Declaradas localmente (valores Linux): a unit Sockets do FPC 3.2.2 nao
  // expoe SHUT_*/MSG_NOSIGNAL de forma uniforme em todos os alvos.
  PIPE_SHUT_RDWR = 2;
  PIPE_MSG_NOSIGNAL = $4000;
  PIPE_LISTEN_BACKLOG = 128;

procedure RaiseIoError(const AOp: string; AErr: cint);
begin
  raise EPipeError.CreateFmt('%s falhou (erro %d: %s)',
    [AOp, AErr, SysErrorMessage(AErr)]);
end;

procedure NewSelfPipe(out AReadFd, AWriteFd: cint);
var
  LFds: TFilDes;
begin
  AReadFd := -1;
  AWriteFd := -1;
  if fpPipe(LFds) <> 0 then
    RaiseIoError('fppipe', fpgeterrno);
  AReadFd := LFds[0];
  AWriteFd := LFds[1];
end;

// Caminho -> sockaddr_un; valida o limite de sun_path (107 chars + #0).
// Preenchimento manual: o helper Str2UnixSockAddr esta deprecated no FPC.
procedure BuildUnixAddr(const APath: string; out AAddr: TUnixSockAddr;
  out ALen: Longint);
begin
  if Length(APath) >= SizeOf(AAddr.path) then
    raise EPipeError.CreateFmt(
      'caminho de socket longo demais (%d chars; maximo %d): %s',
      [Length(APath), SizeOf(AAddr.path) - 1, APath]);
  FillChar(AAddr, SizeOf(AAddr), 0);
  AAddr.family := AF_UNIX;
  Move(APath[1], AAddr.path[0], Length(APath));
  ALen := SizeOf(AAddr.family) + Length(APath) + 1; // familia + path + #0
end;

{ TPipePosixEndpoint }

constructor TPipePosixEndpoint.Create(AFd: cint);
begin
  inherited Create;
  FFd := AFd;
  NewSelfPipe(FStopR, FStopW); // se falhar, o destructor fecha AFd
end;

destructor TPipePosixEndpoint.Destroy;
begin
  CloseAbort; // idempotente
  if FFd >= 0 then
    fpClose(FFd);
  if FStopR >= 0 then
    fpClose(FStopR);
  if FStopW >= 0 then
    fpClose(FStopW);
  inherited;
end;

procedure TPipePosixEndpoint.CloseAbort;
var
  LByte: Byte;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit; // ja abortado
  LByte := 1;
  if FStopW >= 0 then
    fpWrite(FStopW, LByte, 1);    // acorda esperas atuais e futuras (nunca drenado)
  fpShutdown(FFd, PIPE_SHUT_RDWR); // desarma read/write residual no kernel
end;

procedure TPipePosixEndpoint.WaitReadyOrStop(AEvents: SmallInt; const AOp: string);
var
  LFds: array[0..1] of pollfd;
  LRc: cint;
begin
  if PipeAtomicGet(FClosed) <> 0 then
    raise EPipeClosed.Create(AOp + ' em endpoint fechado');
  repeat
    LFds[0].fd := FFd;
    LFds[0].events := AEvents;
    LFds[0].revents := 0;
    LFds[1].fd := FStopR;
    LFds[1].events := POLLIN;
    LFds[1].revents := 0;
    LRc := fpPoll(@LFds[0], 2, -1);
  until (LRc >= 0) or (fpgeterrno <> ESysEINTR);
  if LRc < 0 then
    RaiseIoError(AOp + ' (poll)', fpgeterrno);
  if ((LFds[1].revents and POLLIN) <> 0) or (PipeAtomicGet(FClosed) <> 0) then
    raise EPipeClosed.Create(AOp + ' abortada (CloseAbort)');
  // POLLERR/POLLHUP no fd da operacao: deixa o recv/send reportar — ainda
  // pode haver dados enfileirados para ler apos o HUP.
end;

function TPipePosixEndpoint.Read(var ABuffer; ACount: Integer): Integer;
var
  LGot: NativeInt;
  LErr: cint;
begin
  while True do
  begin
    WaitReadyOrStop(POLLIN, 'leitura');
    LGot := NativeInt(fpRecv(FFd, @ABuffer, ACount, 0));
    if LGot > 0 then
      Exit(Integer(LGot));
    if LGot = 0 then
      raise EPipeClosed.Create('conexao encerrada pelo par');
    LErr := fpgeterrno;
    case LErr of
      ESysEINTR, ESysEAGAIN:
        ; // re-tenta (volta ao poll)
      ESysECONNRESET, ESysEPIPE:
        raise EPipeClosed.CreateFmt('leitura: conexao encerrada (erro %d)', [LErr]);
    else
      RaiseIoError('leitura', LErr);
    end;
  end;
end;

procedure TPipePosixEndpoint.WriteExactly(const ABuffer; ACount: Integer);
var
  P: PByte;
  LWrote: NativeInt;
  LErr: cint;
begin
  P := @ABuffer;
  while ACount > 0 do
  begin
    WaitReadyOrStop(POLLOUT, 'escrita');
    LWrote := NativeInt(fpSend(FFd, P, ACount, PIPE_MSG_NOSIGNAL));
    if LWrote > 0 then
    begin
      Inc(P, LWrote);
      Dec(ACount, Integer(LWrote));
      Continue;
    end;
    LErr := fpgeterrno;
    case LErr of
      ESysEINTR, ESysEAGAIN:
        ; // re-tenta (volta ao poll)
      ESysEPIPE, ESysECONNRESET:
        raise EPipeClosed.CreateFmt('escrita: conexao encerrada (erro %d)', [LErr]);
    else
      RaiseIoError('escrita', LErr);
    end;
  end;
end;

{ TPipePosixListener }

constructor TPipePosixListener.Create(const AAddress: string);
var
  LAddr: TUnixSockAddr;
  LLen: Longint;
begin
  inherited Create;
  FFd := -1;
  FStopR := -1;
  FStopW := -1;
  FNativePath := PipeNativeName(AAddress);
  BuildUnixAddr(FNativePath, LAddr, LLen);
  NewSelfPipe(FStopR, FStopW);
  FFd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if FFd < 0 then
    RaiseIoError('socket(AF_UNIX)', fpgeterrno);
  fpUnlink(FNativePath); // socket orfao de execucao anterior (crash sem unlink)
  if fpBind(FFd, psockaddr(@LAddr), LLen) <> 0 then
    RaiseIoError(Format('bind(%s)', [FNativePath]), fpgeterrno);
  if fpListen(FFd, PIPE_LISTEN_BACKLOG) <> 0 then
    RaiseIoError(Format('listen(%s)', [FNativePath]), fpgeterrno);
end;

destructor TPipePosixListener.Destroy;
begin
  Close; // idempotente
  // Assume acceptor thread ja joinada (contrato de Pipes.Transport).
  if FFd >= 0 then
    fpClose(FFd);
  if FStopR >= 0 then
    fpClose(FStopR);
  if FStopW >= 0 then
    fpClose(FStopW);
  if FNativePath <> '' then
    fpUnlink(FNativePath);
  inherited;
end;

procedure TPipePosixListener.Close;
var
  LByte: Byte;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit;
  LByte := 1;
  if FStopW >= 0 then
    fpWrite(FStopW, LByte, 1); // desbloqueia o Accept pendente (devolve nil)
end;

function TPipePosixListener.Accept: TPipeEndpoint;
var
  LFds: array[0..1] of pollfd;
  LRc, LConn, LErr: cint;
begin
  Result := nil;
  // Loop: um cliente que conecta e cai antes do fpAccept recicla a espera,
  // sem devolver endpoint morto (paridade com o listener Windows).
  while True do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      Exit;
    LFds[0].fd := FFd;
    LFds[0].events := POLLIN;
    LFds[0].revents := 0;
    LFds[1].fd := FStopR;
    LFds[1].events := POLLIN;
    LFds[1].revents := 0;
    LRc := fpPoll(@LFds[0], 2, -1);
    if LRc < 0 then
    begin
      if fpgeterrno = ESysEINTR then
        Continue;
      RaiseIoError('accept (poll)', fpgeterrno);
    end;
    if ((LFds[1].revents and POLLIN) <> 0) or (PipeAtomicGet(FClosed) <> 0) then
      Exit; // Close: devolve nil
    LConn := fpAccept(FFd, nil, nil);
    if LConn >= 0 then
      Exit(TPipePosixEndpoint.Create(LConn));
    LErr := fpgeterrno;
    if (LErr = ESysEINTR) or (LErr = ESysECONNABORTED) or (LErr = ESysEAGAIN) then
      Continue; // cliente caiu entre o poll e o accept: volta a esperar
    RaiseIoError('accept', LErr);
  end;
end;

{ --- fabricas --- }

function PosixPipeCreateListener(const AAddress: string): TPipeListener;
begin
  Result := TPipePosixListener.Create(AAddress);
end;

function PosixPipeConnect(const AAddress: string; ATimeoutMs: Cardinal): TPipeEndpoint;
var
  LNative: string;
  LAddr: TUnixSockAddr;
  LLen: Longint;
  LDeadline: UInt64;
  LFd, LErr: cint;
begin
  LNative := PipeNativeName(AAddress);
  BuildUnixAddr(LNative, LAddr, LLen);
  LDeadline := PipeTickMs + ATimeoutMs;
  while True do
  begin
    LFd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
    if LFd < 0 then
      RaiseIoError('socket(AF_UNIX)', fpgeterrno);
    if fpConnect(LFd, psockaddr(@LAddr), LLen) = 0 then
      Exit(TPipePosixEndpoint.Create(LFd));
    LErr := fpgeterrno;
    fpClose(LFd);
    // ENOENT = servidor ainda nao criou o socket; ECONNREFUSED = arquivo
    // existe mas ninguem escuta (servidor reiniciando ou backlog cheio).
    // Ambos re-tentam ate o prazo — e' o que da semantica uniforme de
    // Connect(timeout) nas duas plataformas.
    if (LErr <> ESysENOENT) and (LErr <> ESysECONNREFUSED) then
      RaiseIoError(Format('conexao ao socket %s', [LNative]), LErr);
    if Int64(LDeadline) - Int64(PipeTickMs) <= 0 then
      raise EPipeTimeout.CreateFmt('timeout (%u ms) conectando ao socket %s',
        [ATimeoutMs, LNative]);
    Sleep(25); // servidor ausente/ocupado: polling curto
  end;
end;

{$ENDIF}

end.
