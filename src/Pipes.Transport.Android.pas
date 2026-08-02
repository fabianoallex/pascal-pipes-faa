unit Pipes.Transport.Android;

{$I pipes.inc}

{ Transporte Android (Delphi): sockets TCP sobre AF_INET/AF_INET6.

  Terceiro eixo de plataforma, ao lado de Pipes.Transport.Windows (Named Pipe
  overlapped) e Pipes.Transport.Posix (UDS no FPC). NAO e' uma extensao deste
  ultimo: aquele backend usa BaseUnix/Sockets/UnixType, units que nao existem
  em compilador nenhum da Embarcadero. Aqui as chamadas vem das units Posix.*
  da propria RTL.

  Escopo: so ptTcp/ptTls. ptLocal (Named Pipe/UDS) esta fora — app Android e'
  single-process e expor um socket de dominio Unix esbarra em sandboxing
  (docs/ARQUITETURA.md secao 13.1). Pipes.Transport recusa ptLocal no Android
  com mensagem propria, entao esta unit nem tem codigo AF_UNIX.

  Interrupcao de IO blocante = self-pipe, IDENTICO ao backend Linux: cada
  endpoint/listener tem um par pipe() proprio e toda espera e' um poll() no par
  [fd da operacao, lado de leitura do self-pipe]. CloseAbort/Close escrevem 1
  byte no self-pipe (acorda o poll) e, no endpoint, shutdown(SHUT_RDWR) desarma
  qualquer read/write residual no kernel. Nenhuma espera usa timeout de polling:
  acordar e' sempre por evento.

  Por que NAO TSocket.Close(False), que foi o mecanismo validado no spike de
  viabilidade: ele funciona (destrava um Receive bloqueado em ~1-2ms, medido em
  device real), mas fecha o fd na hora, a partir de OUTRA thread, com a reader
  possivelmente ainda dentro do recv — exatamente a corrida de fd reciclado que
  o resto da lib evita adiando o close para o destructor. O self-pipe entrega o
  mesmo desbloqueio sem essa aposta, e de quebra deixa o backend Android com o
  MESMO desenho do Linux em vez de um terceiro modelo para manter.

  Invariantes (alem do contrato de Pipes.Transport):
  - FClosed atomico; o self-pipe nunca e' drenado apos o CloseAbort, entao
    qualquer espera futura acorda na hora e levanta EPipeClosed.
  - O fd so e' fechado no destructor (apos o join da reader/acceptor thread
    na camada de cima).
  - Escritas sempre com MSG_NOSIGNAL: par que morre gera EPIPE (tratado como
    EPipeClosed), nunca SIGPIPE (que mataria o processo inteiro).

  Duas armadilhas de plataforma que custaram tempo e ficam registradas aqui:

  1. O addrinfo do bionic tem ai_canonname ANTES de ai_addr — ordem BSD, ao
     contrario do glibc, onde ai_addr vem primeiro. Por isso esta unit usa o
     addrinfo/getaddrinfo do proprio Posix.NetDB e NAO reaproveita o
     TPipeAddrInfo declarado em Pipes.Transport.Tcp.pas (que segue o layout
     glibc no ramo nao-Windows). Com o layout errado o connect receberia um
     char* no lugar do sockaddr, sem erro de compilacao.

  2. TSocket.Receive/Send (System.Net.Socket) tem um overload tipado
     (array of Byte; Offset; Count) que sombreia o untyped (var Buf; Count)
     quando se passa um array — o Delphi prioriza o tipado e interpreta o 2o
     argumento como Offset. Esta unit nao usa TSocket, entao nao esta exposta a
     isso; o registro fica para quem for escrever sample/teste com TSocket.

  Seguranca: como no ptTcp das outras plataformas, TCP nao herda controle de
  acesso do SO. Em Android vale lembrar ainda que a permissao INTERNET precisa
  estar no manifesto e que trafego em texto claro exige politica propria
  (usesCleartextTraffic) a partir do Android 9 — motivo a mais para ptTls. }

interface

{$IFDEF PIPES_ANDROID}

uses
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Transport;

type
  TPipeAndroidEndpoint = class(TPipeEndpoint)
  private
    FFd: Integer;
    FStopR: Integer;  // self-pipe: lado de leitura (entra em todo poll)
    FStopW: Integer;  // self-pipe: lado de escrita (CloseAbort escreve 1 byte)
    FClosed: Integer; // atomico: 1 apos CloseAbort
    FIoTimeoutMs: Cardinal; // 0 = espera sem prazo (ver SetIoDeadline)
    /// Espera o fd ficar pronto (AEvents) ou o stop sinalizar (EPipeClosed).
    procedure WaitReadyOrStop(AEvents: SmallInt; const AOp: string);
  public
    /// Assume a posse de AFd (socket conectado).
    constructor Create(AFd: Integer);
    destructor Destroy; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
    procedure SetIoDeadline(ATimeoutMs: Cardinal); override;
  end;

  TPipeAndroidListener = class(TPipeListener)
  private
    FFd: Integer;     // socket de escuta
    FStopR: Integer;  // self-pipe: lado de leitura
    FStopW: Integer;  // self-pipe: lado de escrita (Close escreve 1 byte)
    FClosed: Integer; // atomico
  public
    /// Assume a posse de um socket JA em listen.
    constructor CreateFromFd(AFd: Integer);
    destructor Destroy; override;
    function Accept: TPipeEndpoint; override;
    procedure Close; override;
  end;

/// Fabricas de ptTcp no Android. Mesma assinatura e semantica das de
/// Pipes.Transport.Tcp.pas, que delega para ca sob PIPES_ANDROID.
///
/// O listener existe apesar de a secao 13.1 dizer que servidor Android nao faz
/// sentido no caso de uso alvo: sem ele nao ha como rodar um teste de
/// integracao loopback (servidor + cliente no mesmo app) no aparelho, que e' a
/// unica forma pratica de verificar este backend — nao ha par dual-compiler
/// aqui, o FPC nao compila para Android neste projeto.
function AndroidTcpCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPipeListener;
function AndroidTcpConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal): TPipeEndpoint;

{$ENDIF}

implementation

{$IFDEF PIPES_ANDROID}

uses
  Posix.Base,
  Posix.SysTypes,
  Posix.SysSocket,
  Posix.NetDB,
  Posix.NetinetIn,
  Posix.NetinetTCP,
  Posix.Unistd,
  Posix.Fcntl,
  Posix.Errno;

{ --- poll() e as chamadas de endereco -----------------------------------------

  poll nao tem unit na RTL (existe Posix.SysSelect, nao Posix.Poll), entao e'
  declarado aqui contra o mesmo libc que as units Posix.* usam. Mesmo idioma do
  getaddrinfo local em Pipes.Transport.Tcp.pas e do CancelIoEx em
  Pipes.Transport.Windows.pas.

  accept/bind/connect tambem sao redeclarados: as versoes da RTL recebem
  'sockaddr' TIPADO, que tem 16 bytes — passar por ali o sockaddr_in6 de 28
  bytes devolvido pelo getaddrinfo estouraria o registro. Aqui o endereco
  trafega como ponteiro opaco + tamanho, que e' o contrato real da API (e o que
  permite passar nil no accept, que nao quer o endereco do par). }

type
  TAndroidPollFd = record
    fd: Integer;
    events: SmallInt;
    revents: SmallInt;
  end;

const
  ANDROID_POLLIN  = $0001;
  ANDROID_POLLOUT = $0004;
  ANDROID_LISTEN_BACKLOG = 128;

// ANfds e' nfds_t, que no bionic e' 'unsigned long' — 64 bits no Android64 e 32
// no Android32. Tem que ser NativeUInt, nao LongWord: com LongWord o registro
// de argumento chegaria com o meio superior sujo no aarch64.
function android_poll(AFds: Pointer; ANfds: NativeUInt;
  ATimeoutMs: Integer): Integer; cdecl; external libc name _PU + 'poll';
function android_accept(ASocket: Integer; AAddr: Pointer;
  AAddrLen: Pointer): Integer; cdecl; external libc name _PU + 'accept';
function android_bind(ASocket: Integer; AAddr: Pointer;
  ALen: socklen_t): Integer; cdecl; external libc name _PU + 'bind';
function android_connect(ASocket: Integer; AAddr: Pointer;
  ALen: socklen_t): Integer; cdecl; external libc name _PU + 'connect';

procedure RaiseIoError(const AOp: string; AErr: Integer);
begin
  raise EPipeError.CreateFmt('%s falhou (erro %d: %s)',
    [AOp, AErr, SysErrorMessage(AErr)]);
end;

procedure NewSelfPipe(out AReadFd, AWriteFd: Integer);
var
  LFds: TPipeDescriptors;
begin
  AReadFd := -1;
  AWriteFd := -1;
  if pipe(LFds) <> 0 then
    RaiseIoError('pipe', errno);
  AReadFd := LFds.ReadDes;
  AWriteFd := LFds.WriteDes;
end;

// Resolve Address ('host:porta') numa lista de candidatos. APassive = listener
// (permite '0.0.0.0'/'::' e AI_PASSIVE). O chamador libera com freeaddrinfo.
//
// Usa o addrinfo do Posix.NetDB de proposito: o layout do bionic difere do
// glibc (ver cabecalho da unit, armadilha 1).
function ResolveAddress(const AAddress: string;
  APassive: Boolean): Paddrinfo;
var
  LHost: string;
  LPort: Word;
  LHints: addrinfo;
  LRc: Integer;
  LHostA, LPortA: RawByteString;
begin
  Result := nil;
  PipeParseHostPort(AAddress, LHost, LPort);
  FillChar(LHints, SizeOf(LHints), 0);
  LHints.ai_family := AF_UNSPEC;      // IPv4 ou IPv6, o que existir
  LHints.ai_socktype := SOCK_STREAM;
  LHints.ai_protocol := IPPROTO_TCP;
  if APassive then
    LHints.ai_flags := AI_PASSIVE;
  LHostA := RawByteString(UTF8Encode(LHost));
  LPortA := RawByteString(UTF8Encode(IntToStr(LPort)));
  LRc := getaddrinfo(MarshaledAString(PAnsiChar(LHostA)),
    MarshaledAString(PAnsiChar(LPortA)), LHints, Result);
  if (LRc <> 0) or (Result = nil) then
    raise EPipeError.CreateFmt('nao foi possivel resolver "%s" (getaddrinfo=%d)',
      [AAddress, LRc]);
end;

procedure SetNoDelay(AFd: Integer);
var
  LOn: Integer;
begin
  LOn := 1;
  // Melhor esforco: RPC request-reply sofre muito com o atraso do Nagle, mas
  // falhar aqui nao justifica derrubar a conexao.
  setsockopt(AFd, IPPROTO_TCP, TCP_NODELAY, LOn, SizeOf(LOn));
end;

// Os tres parametros sao ajustaveis por socket (bionic e' Linux por baixo), o
// que torna a deteccao previsivel: ASeconds ociosos + PROBE_COUNT probes a
// cada INTERVAL segundos — os mesmos numeros do backend Linux.
procedure SetKeepAlive(AFd: Integer; ASeconds: Cardinal);
var
  LVal: Integer;
begin
  if ASeconds = 0 then
    Exit;
  LVal := 1;
  setsockopt(AFd, SOL_SOCKET, SO_KEEPALIVE, LVal, SizeOf(LVal));
  LVal := Integer(ASeconds);
  setsockopt(AFd, IPPROTO_TCP, TCP_KEEPIDLE, LVal, SizeOf(LVal));
  LVal := PIPES_KEEPALIVE_INTERVAL_SECONDS;
  setsockopt(AFd, IPPROTO_TCP, TCP_KEEPINTVL, LVal, SizeOf(LVal));
  LVal := PIPES_KEEPALIVE_PROBE_COUNT;
  setsockopt(AFd, IPPROTO_TCP, TCP_KEEPCNT, LVal, SizeOf(LVal));
end;

{ TPipeAndroidEndpoint }

constructor TPipeAndroidEndpoint.Create(AFd: Integer);
begin
  inherited Create;
  FFd := AFd;
  NewSelfPipe(FStopR, FStopW); // se falhar, o destructor fecha AFd
end;

destructor TPipeAndroidEndpoint.Destroy;
begin
  CloseAbort; // idempotente
  if FFd >= 0 then
    __close(FFd);
  if FStopR >= 0 then
    __close(FStopR);
  if FStopW >= 0 then
    __close(FStopW);
  inherited;
end;

procedure TPipeAndroidEndpoint.CloseAbort;
var
  LByte: Byte;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit; // ja abortado
  LByte := 1;
  if FStopW >= 0 then
    __write(FStopW, @LByte, 1);  // acorda esperas atuais e futuras (nunca drenado)
  shutdown(FFd, SHUT_RDWR);      // desarma read/write residual no kernel
end;

procedure TPipeAndroidEndpoint.SetIoDeadline(ATimeoutMs: Cardinal);
begin
  FIoTimeoutMs := ATimeoutMs;
end;

procedure TPipeAndroidEndpoint.WaitReadyOrStop(AEvents: SmallInt;
  const AOp: string);
var
  LFds: array[0..1] of TAndroidPollFd;
  LRc: Integer;
  LDeadline: UInt64;
  LWait: Int64;
begin
  if PipeAtomicGet(FClosed) <> 0 then
    raise EPipeClosed.Create(AOp + ' em endpoint fechado');
  LDeadline := 0;
  if FIoTimeoutMs <> 0 then
    LDeadline := PipeTickMs + FIoTimeoutMs;
  repeat
    if FIoTimeoutMs = 0 then
      LWait := -1
    else
    begin
      // Recalculado a cada volta: sem isso um EINTR reiniciaria o prazo, e uma
      // rajada de sinais esticaria a espera indefinidamente.
      LWait := Int64(LDeadline) - Int64(PipeTickMs);
      if LWait < 0 then
        LWait := 0;
    end;
    LFds[0].fd := FFd;
    LFds[0].events := AEvents;
    LFds[0].revents := 0;
    LFds[1].fd := FStopR;
    LFds[1].events := ANDROID_POLLIN;
    LFds[1].revents := 0;
    LRc := android_poll(@LFds[0], 2, Integer(LWait));
  until (LRc >= 0) or (errno <> EINTR);
  if LRc < 0 then
    RaiseIoError(AOp + ' (poll)', errno);
  if (LRc = 0) and (FIoTimeoutMs <> 0) then
    raise EPipeTimeout.CreateFmt('%s: o par nao respondeu em %u ms',
      [AOp, FIoTimeoutMs]);
  if ((LFds[1].revents and ANDROID_POLLIN) <> 0)
    or (PipeAtomicGet(FClosed) <> 0) then
    raise EPipeClosed.Create(AOp + ' abortada (CloseAbort)');
  // POLLERR/POLLHUP no fd da operacao: deixa o recv/send reportar — ainda
  // pode haver dados enfileirados para ler apos o HUP.
end;

function TPipeAndroidEndpoint.Read(var ABuffer; ACount: Integer): Integer;
var
  LGot: ssize_t;
  LErr: Integer;
begin
  while True do
  begin
    WaitReadyOrStop(ANDROID_POLLIN, 'leitura');
    LGot := recv(FFd, ABuffer, size_t(ACount), 0);
    if LGot > 0 then
      Exit(Integer(LGot));
    if LGot = 0 then
      raise EPipeClosed.Create('conexao encerrada pelo par');
    LErr := errno;
    case LErr of
      EINTR, EAGAIN:
        ; // re-tenta (volta ao poll)
      ECONNRESET, EPIPE:
        raise EPipeClosed.CreateFmt('leitura: conexao encerrada (erro %d)', [LErr]);
    else
      RaiseIoError('leitura', LErr);
    end;
  end;
end;

procedure TPipeAndroidEndpoint.WriteExactly(const ABuffer; ACount: Integer);
var
  P: PByte;
  LWrote: ssize_t;
  LErr: Integer;
begin
  P := @ABuffer;
  while ACount > 0 do
  begin
    WaitReadyOrStop(ANDROID_POLLOUT, 'escrita');
    LWrote := send(FFd, P^, size_t(ACount), MSG_NOSIGNAL);
    if LWrote > 0 then
    begin
      Inc(P, LWrote);
      Dec(ACount, Integer(LWrote));
      Continue;
    end;
    LErr := errno;
    case LErr of
      EINTR, EAGAIN:
        ; // re-tenta (volta ao poll)
      EPIPE, ECONNRESET:
        raise EPipeClosed.CreateFmt('escrita: conexao encerrada (erro %d)', [LErr]);
    else
      RaiseIoError('escrita', LErr);
    end;
  end;
end;

{ TPipeAndroidListener }

constructor TPipeAndroidListener.CreateFromFd(AFd: Integer);
begin
  inherited Create;
  FFd := AFd;
  FStopR := -1;
  FStopW := -1;
  NewSelfPipe(FStopR, FStopW); // se falhar, o destructor fecha AFd
end;

destructor TPipeAndroidListener.Destroy;
begin
  Close; // idempotente
  // Assume acceptor thread ja joinada (contrato de Pipes.Transport).
  if FFd >= 0 then
    __close(FFd);
  if FStopR >= 0 then
    __close(FStopR);
  if FStopW >= 0 then
    __close(FStopW);
  inherited;
end;

procedure TPipeAndroidListener.Close;
var
  LByte: Byte;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit;
  LByte := 1;
  if FStopW >= 0 then
    __write(FStopW, @LByte, 1); // desbloqueia o Accept pendente (devolve nil)
end;

function TPipeAndroidListener.Accept: TPipeEndpoint;
var
  LFds: array[0..1] of TAndroidPollFd;
  LRc, LConn, LErr: Integer;
begin
  Result := nil;
  // Loop: um cliente que conecta e cai antes do accept recicla a espera, sem
  // devolver endpoint morto (mesma semantica dos demais listeners).
  while True do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      Exit;
    LFds[0].fd := FFd;
    LFds[0].events := ANDROID_POLLIN;
    LFds[0].revents := 0;
    LFds[1].fd := FStopR;
    LFds[1].events := ANDROID_POLLIN;
    LFds[1].revents := 0;
    LRc := android_poll(@LFds[0], 2, -1);
    if LRc < 0 then
    begin
      if errno = EINTR then
        Continue;
      RaiseIoError('accept (poll)', errno);
    end;
    if ((LFds[1].revents and ANDROID_POLLIN) <> 0)
      or (PipeAtomicGet(FClosed) <> 0) then
      Exit; // Close: devolve nil
    LConn := android_accept(FFd, nil, nil);
    if LConn >= 0 then
      Exit(TPipeAndroidEndpoint.Create(LConn));
    LErr := errno;
    if (LErr = EINTR) or (LErr = ECONNABORTED) or (LErr = EAGAIN) then
      Continue; // cliente caiu entre o poll e o accept: volta a esperar
    RaiseIoError('accept', LErr);
  end;
end;

{ --- fabricas --- }

function AndroidTcpCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPipeListener;
var
  LInfo, LCur: Paddrinfo;
  LFd, LErr, LOn: Integer;
begin
  LErr := 0;
  LInfo := ResolveAddress(AAddress, True);
  try
    LCur := LInfo;
    while LCur <> nil do
    begin
      LFd := socket(LCur^.ai_family, LCur^.ai_socktype, LCur^.ai_protocol);
      if LFd >= 0 then
      begin
        // SO_REUSEADDR aqui so evita o TIME_WAIT barrar o rebind (semantica
        // BSD/Linux) — mesma escolha do backend POSIX, oposta a do Windows.
        LOn := 1;
        setsockopt(LFd, SOL_SOCKET, SO_REUSEADDR, LOn, SizeOf(LOn));
        // O socket aceito HERDA as opcoes do socket de escuta, entao o
        // keepalive e' setado no molde, antes do bind.
        SetKeepAlive(LFd, AKeepAliveSeconds);
        if (android_bind(LFd, LCur^.ai_addr, LCur^.ai_addrlen) = 0)
          and (listen(LFd, ANDROID_LISTEN_BACKLOG) = 0) then
          Exit(TPipeAndroidListener.CreateFromFd(LFd));
        LErr := errno;
        __close(LFd);
      end
      else
        LErr := errno;
      LCur := LCur^.ai_next;
    end;
  finally
    freeaddrinfo(LInfo^);
  end;
  RaiseIoError(Format('escuta em %s', [AAddress]), LErr);
  Result := nil; // inalcancavel (RaiseIoError sempre levanta)
end;

// Tenta UM candidato com connect nao-blocante, limitado por ADeadline. Devolve
// o fd conectado (em modo blocante de novo) ou -1, com AErr preenchido.
//
// O connect precisa ser nao-blocante: blocante, uma unica tentativa presa no
// kernel ignoraria ATimeoutMs por completo. Em mobile isso e' pior que no
// desktop — numa rede movel que engole o SYN sem responder, o retry do kernel
// leva dezenas de segundos e Connect(300) travaria a UI.
function ConnectCandidate(ACand: Paddrinfo; ADeadline: UInt64;
  out AErr: Integer): Integer;
var
  LFd, LFlags, LRc: Integer;
  LPoll: TAndroidPollFd;
  LSoErr: Integer;
  LLen: socklen_t;
  LRemaining: Int64;
begin
  Result := -1;
  AErr := 0;
  LFd := socket(ACand^.ai_family, ACand^.ai_socktype, ACand^.ai_protocol);
  if LFd < 0 then
  begin
    AErr := errno;
    Exit;
  end;
  LFlags := fcntl(LFd, F_GETFL);
  fcntl(LFd, F_SETFL, LFlags or O_NONBLOCK);
  if android_connect(LFd, ACand^.ai_addr, ACand^.ai_addrlen) <> 0 then
  begin
    AErr := errno;
    if AErr <> EINPROGRESS then
    begin
      __close(LFd);
      Exit;
    end;
    LRemaining := Int64(ADeadline) - Int64(PipeTickMs);
    if LRemaining < 0 then
      LRemaining := 0;
    repeat
      LPoll.fd := LFd;
      LPoll.events := ANDROID_POLLOUT;
      LPoll.revents := 0;
      LRc := android_poll(@LPoll, 1, Integer(LRemaining));
    until (LRc >= 0) or (errno <> EINTR);
    if LRc <= 0 then
    begin
      // 0 = estourou o prazo; <0 = erro no proprio poll.
      if LRc = 0 then
        AErr := ETIMEDOUT
      else
        AErr := errno;
      __close(LFd);
      Exit;
    end;
    // POLLOUT sozinho nao significa sucesso: o resultado real do connect vem
    // do SO_ERROR do socket.
    LSoErr := 0;
    LLen := SizeOf(LSoErr);
    if getsockopt(LFd, SOL_SOCKET, SO_ERROR, LSoErr, LLen) <> 0 then
      LSoErr := errno;
    if LSoErr <> 0 then
    begin
      AErr := LSoErr;
      __close(LFd);
      Exit;
    end;
  end;
  // Restaura o modo blocante: TPipeAndroidEndpoint espera poll antes de cada
  // operacao + recv/send blocantes.
  fcntl(LFd, F_SETFL, LFlags);
  AErr := 0;
  Result := LFd;
end;

function AndroidTcpConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal): TPipeEndpoint;
var
  LInfo, LCur: Paddrinfo;
  LFd, LErr: Integer;
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  LInfo := ResolveAddress(AAddress, False);
  try
    while True do
    begin
      LErr := 0;
      LCur := LInfo;
      while LCur <> nil do
      begin
        LFd := ConnectCandidate(LCur, LDeadline, LErr);
        if LFd >= 0 then
        begin
          SetNoDelay(LFd);
          SetKeepAlive(LFd, AKeepAliveSeconds);
          Exit(TPipeAndroidEndpoint.Create(LFd));
        end;
        LCur := LCur^.ai_next;
      end;
      // Servidor ainda nao subiu ou backlog cheio: re-tenta ate o prazo, que
      // e' o que da a Connect(timeout) a mesma semantica das outras plataformas.
      if (LErr <> ECONNREFUSED) and (LErr <> ETIMEDOUT) then
        RaiseIoError(Format('conexao a %s', [AAddress]), LErr);
      if Int64(LDeadline) - Int64(PipeTickMs) <= 0 then
        raise EPipeTimeout.CreateFmt('timeout (%u ms) conectando a %s',
          [ATimeoutMs, AAddress]);
      Sleep(25);
    end;
  finally
    freeaddrinfo(LInfo^);
  end;
end;

{$ENDIF}

end.
