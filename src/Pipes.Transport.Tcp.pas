unit Pipes.Transport.Tcp;

{$I pipes.inc}

{ Transporte TCP (ptTcp): sockets SOCK_STREAM sobre AF_INET/AF_INET6, com o
  mesmo contrato de Pipes.Transport dos transportes locais.

  A assimetria entre as plataformas e' grande, e proposital:

  - POSIX: um socket TCP e' o mesmo objeto que um Unix Domain Socket, so muda
    a familia de enderecos. Por isso aqui so se monta o socket (getaddrinfo +
    bind/listen ou connect) e a posse passa para TPipePosixEndpoint /
    TPipePosixListener.CreateFromFd, que ja implementam espera com fpPoll +
    self-pipe, abort e MSG_NOSIGNAL. Zero duplicacao.

  - Windows: o transporte local e' Named Pipe overlapped, que nao serve para
    socket nenhum. Aqui ha implementacao propria, com o analogo Winsock do
    padrao [evento da operacao, evento de stop] usado em
    Pipes.Transport.Windows: WSAEventSelect associa o socket a um WSAEVENT e
    toda espera e' um WSAWaitForMultipleEvents nesse par.

  Invariantes (alem do contrato de Pipes.Transport):
  - Windows: WSAEventSelect deixa o socket NAO-BLOCANTE. Toda operacao tenta
    primeiro recv/send e so espera no evento se voltar WSAEWOULDBLOCK — isso
    evita depender da semantica de borda do FD_READ/FD_WRITE, que so re-sinaliza
    na transicao (chegou dado / buffer de saida destravou).
  - Windows: FStopEvent e' manual-reset e nunca resetado; apos CloseAbort
    qualquer espera futura acorda na hora e levanta EPipeClosed.
  - O socket so e' fechado no destructor (apos o join da thread que o usava),
    mesma razao do handle/fd nos outros transportes: fechar cedo arriscaria IO
    num descritor ja reciclado pelo SO.
  - SO_REUSEADDR e' setado apenas no POSIX. No Windows ele permite que OUTRO
    processo sequestre uma porta ja em uso (semantica diferente do BSD), entao
    aqui a ausencia dele e' proposital.

  Seguranca: diferente de ptLocal, TCP nao herda controle de acesso do SO (nem
  ACL do Windows, nem permissao de arquivo do UDS). Um listener em 0.0.0.0
  aceita qualquer um que alcance a porta — autenticar e' responsabilidade da
  aplicacao. }

interface

uses
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Transport
  {$IFDEF PIPES_WINDOWS}
  , Windows, WinSock2
  {$ELSE}
  , UnixType, BaseUnix, Sockets, Pipes.Transport.Posix
  {$ENDIF};

{$IFDEF PIPES_WINDOWS}
type
  TPipeTcpWinEndpoint = class(TPipeEndpoint)
  private
    FSocket: TSocket;
    FSockEvent: WSAEVENT;  // FD_READ/FD_WRITE/FD_CLOSE do socket
    FStopEvent: WSAEVENT;  // manual-reset, sinalizado por CloseAbort
    FClosed: Integer;      // atomico: 1 apos CloseAbort
    FIoTimeoutMs: Cardinal; // 0 = espera sem prazo (ver SetIoDeadline)
    /// Espera o socket sinalizar algo ou o stop (EPipeClosed).
    procedure WaitReadyOrStop(const AOp: string);
  public
    /// Assume a posse de ASocket (conectado).
    constructor Create(ASocket: TSocket; AKeepAliveSeconds: Cardinal);
    destructor Destroy; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
    procedure SetIoDeadline(ATimeoutMs: Cardinal); override;
  end;

  TPipeTcpWinListener = class(TPipeListener)
  private
    FSocket: TSocket;
    FAcceptEvent: WSAEVENT;
    FStopEvent: WSAEVENT;
    FClosed: Integer;
    FKeepAliveSeconds: Cardinal; // reaplicado em cada socket aceito
  public
    /// Assume a posse de ASocket (ja em listen).
    constructor Create(ASocket: TSocket; AKeepAliveSeconds: Cardinal);
    destructor Destroy; override;
    function Accept: TPipeEndpoint; override;
    procedure Close; override;
  end;
{$ENDIF}

/// AKeepAliveSeconds: ociosidade antes do primeiro probe (0 = desligado). No
/// listener vale para as conexoes ACEITAS, que herdam a opcao do socket de
/// escuta (comportamento documentado do accept nas duas plataformas); no
/// Windows tambem e' reaplicada explicitamente em cada socket aceito.
function TcpPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPipeListener;
function TcpPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal): TPipeEndpoint;

implementation

{ --- getaddrinfo -------------------------------------------------------------

  Declarado localmente (mesmo idioma do CancelIoEx em Pipes.Transport.Windows):
  as units de socket do Delphi e do FPC divergem na assinatura e na presenca
  desta funcao, e o layout do struct difere entre Windows e glibc — ai_addr e
  ai_canonname trocam de ordem, e ai_addrlen e' size_t no Windows e socklen_t
  (32 bits) no glibc. Declarar aqui evita depender de qualquer uma das duas. }

type
  PPipeAddrInfo = ^TPipeAddrInfo;
  TPipeAddrInfo = record
    ai_flags: Integer;
    ai_family: Integer;
    ai_socktype: Integer;
    ai_protocol: Integer;
    {$IFDEF PIPES_WINDOWS}
    ai_addrlen: NativeUInt;   // size_t
    ai_canonname: PAnsiChar;
    ai_addr: Pointer;         // sockaddr*
    {$ELSE}
    ai_addrlen: LongWord;     // socklen_t; o alinhamento cobre o padding
    ai_addr: Pointer;         // sockaddr*
    ai_canonname: PAnsiChar;
    {$ENDIF}
    ai_next: PPipeAddrInfo;
  end;

const
  PIPE_AI_PASSIVE   = 1;
  PIPE_AF_UNSPEC    = 0;
  PIPE_SOCK_STREAM  = 1;
  PIPE_IPPROTO_TCP  = 6;
  PIPE_LISTEN_BACKLOG = 128;

{$IFDEF PIPES_WINDOWS}
function pipe_getaddrinfo(ANode, AService: PAnsiChar; AHints: PPipeAddrInfo;
  out ARes: PPipeAddrInfo): Integer; stdcall;
  external 'ws2_32.dll' name 'getaddrinfo';
procedure pipe_freeaddrinfo(AInfo: PPipeAddrInfo); stdcall;
  external 'ws2_32.dll' name 'freeaddrinfo';
{$ELSE}
function pipe_getaddrinfo(ANode, AService: PAnsiChar; AHints: PPipeAddrInfo;
  out ARes: PPipeAddrInfo): Integer; cdecl;
  external 'c' name 'getaddrinfo';
procedure pipe_freeaddrinfo(AInfo: PPipeAddrInfo); cdecl;
  external 'c' name 'freeaddrinfo';
{$ENDIF}

// Resolve Address ('host:porta') numa lista de candidatos. APassive = listener
// (permite '0.0.0.0'/'::' e AI_PASSIVE). O chamador libera com
// pipe_freeaddrinfo. Levanta EPipeError se nao resolver.
function ResolveAddress(const AAddress: string;
  APassive: Boolean): PPipeAddrInfo;
var
  LHost: string;
  LPort: Word;
  LHints: TPipeAddrInfo;
  LRc: Integer;
  LHostA, LPortA: AnsiString;
begin
  Result := nil;
  PipeParseHostPort(AAddress, LHost, LPort);
  FillChar(LHints, SizeOf(LHints), 0);
  LHints.ai_family := PIPE_AF_UNSPEC;      // IPv4 ou IPv6, o que existir
  LHints.ai_socktype := PIPE_SOCK_STREAM;
  LHints.ai_protocol := PIPE_IPPROTO_TCP;
  if APassive then
    LHints.ai_flags := PIPE_AI_PASSIVE;
  LHostA := AnsiString(LHost);
  LPortA := AnsiString(IntToStr(LPort));
  LRc := pipe_getaddrinfo(PAnsiChar(LHostA), PAnsiChar(LPortA), @LHints, Result);
  if (LRc <> 0) or (Result = nil) then
    raise EPipeError.CreateFmt('nao foi possivel resolver "%s" (getaddrinfo=%d)',
      [AAddress, LRc]);
end;

{$IFDEF PIPES_WINDOWS}

{ ============================ Windows (Winsock) ============================ }

const
  PIPE_SD_BOTH      = 2;
  PIPE_FD_READ      = $01;
  PIPE_FD_WRITE     = $02;
  PIPE_FD_ACCEPT    = $08;
  PIPE_FD_CONNECT   = $10;
  PIPE_FD_CONNECT_BIT = 4; // indice em TWSANetworkEvents.iErrorCode
  PIPE_FD_CLOSE     = $20;
  PIPE_TCP_NODELAY  = 1;
  PIPE_SOL_SOCKET   = $FFFF;
  PIPE_SO_KEEPALIVE = $0008;
  // _WSAIOW(IOC_VENDOR, 4) — mstcpip.h
  PIPE_SIO_KEEPALIVE_VALS = LongWord($98000004);
  PIPE_WSA_INFINITE = Cardinal($FFFFFFFF);
  PIPE_WSA_WAIT_FAILED = Cardinal($FFFFFFFF);
  PIPE_WSA_WAIT_EVENT_0 = 0;
  PIPE_WSA_WAIT_TIMEOUT = Cardinal(258); // = WAIT_TIMEOUT
  // PIPE_WSA_INVALID_EVENT e' (WSAEVENT)NULL; a unit WinSock2 do FPC 3.2.2 nao a
  // declara.
  PIPE_WSA_INVALID_EVENT = 0;

// bind/connect declarados localmente: a WinSock2 do FPC os tipa como
// TSockAddrIn, o que impediria passar o sockaddr_in6 devolvido pelo
// getaddrinfo. Aqui o endereco trafega como ponteiro opaco + tamanho, que e' o
// contrato real da API.
function pipe_bind(ASocket: TSocket; AAddr: Pointer;
  ANameLen: Integer): Integer; stdcall; external 'ws2_32.dll' name 'bind';
function pipe_connect(ASocket: TSocket; AAddr: Pointer;
  ANameLen: Integer): Integer; stdcall; external 'ws2_32.dll' name 'connect';

type
  { Layout fixo do WSANETWORKEVENTS (FD_MAX_EVENTS = 10). Declarado aqui pelo
    mesmo motivo dos demais: o FPC recebe o parametro como ponteiro e o Delphi
    como 'var', o que nao compila nos dois com uma unica chamada. }
  TPipeNetworkEvents = record
    lNetworkEvents: LongInt;
    iErrorCode: array[0..9] of Integer;
  end;

function pipe_WSAEnumNetworkEvents(ASocket: TSocket; AEvent: THandle;
  AEvents: Pointer): Integer; stdcall;
  external 'ws2_32.dll' name 'WSAEnumNetworkEvents';

var
  GWinsockReady: Boolean = False;

procedure RaiseWsaError(const AOp: string; AErr: Integer);
begin
  case AErr of
    WSAECONNRESET, WSAECONNABORTED, WSAESHUTDOWN, WSAENETRESET, WSAENOTCONN:
      raise EPipeClosed.CreateFmt('%s: conexao encerrada (WSA %d)', [AOp, AErr]);
  else
    raise EPipeError.CreateFmt('%s falhou (WSA %d: %s)',
      [AOp, AErr, SysErrorMessage(AErr)]);
  end;
end;

function NewWsaEvent: WSAEVENT;
begin
  Result := WSACreateEvent; // manual-reset, nao sinalizado
  if Result = PIPE_WSA_INVALID_EVENT then
    raise EPipeError.CreateFmt('WSACreateEvent falhou (WSA %d)',
      [WSAGetLastError]);
end;

procedure SetNoDelay(ASocket: TSocket);
var
  LOn: Integer;
begin
  LOn := 1;
  // Melhor esforco: RPC request-reply sofre muito com o atraso do Nagle, mas
  // falhar aqui nao justifica derrubar a conexao.
  setsockopt(ASocket, PIPE_IPPROTO_TCP, PIPE_TCP_NODELAY, @LOn, SizeOf(LOn));
end;

type
  { Layout de tcp_keepalive (mstcpip.h), argumento do SIO_KEEPALIVE_VALS. }
  TPipeTcpKeepalive = record
    onoff: LongWord;
    keepalivetime: LongWord;     // ms de ociosidade antes do 1o probe
    keepaliveinterval: LongWord; // ms entre probes
  end;

function pipe_WSAIoctl(ASocket: TSocket; ACode: LongWord;
  AInBuf: Pointer; AInSize: LongWord; AOutBuf: Pointer; AOutSize: LongWord;
  ABytesReturned: PLongWord; AOverlapped: Pointer;
  ACompletion: Pointer): Integer; stdcall;
  external 'ws2_32.dll' name 'WSAIoctl';

// Liga keepalive com tempos POR SOCKET. Usa SIO_KEEPALIVE_VALS (existe desde o
// Windows 2000) em vez de setsockopt(TCP_KEEPIDLE), que so chegou no Win10
// 1709 — hardware de PDV costuma ser antigo demais para depender disso.
//
// O SIO_KEEPALIVE_VALS nao expoe a contagem de probes: no Windows ela e' fixa
// (10 no XP/2003, 2 do Vista em diante), entao a deteccao la sai um pouco
// diferente do POSIX. Manter vivo o mapeamento de NAT/VPN, que e' o objetivo
// principal, depende so do keepalivetime e funciona igual nos dois.
procedure SetKeepAlive(ASocket: TSocket; ASeconds: Cardinal);
var
  LVals: TPipeTcpKeepalive;
  LOn: Integer;
  LReturned: LongWord;
begin
  if ASeconds = 0 then
    Exit;
  LOn := 1;
  setsockopt(ASocket, PIPE_SOL_SOCKET, PIPE_SO_KEEPALIVE, @LOn, SizeOf(LOn));
  LVals.onoff := 1;
  LVals.keepalivetime := ASeconds * 1000;
  LVals.keepaliveinterval := PIPES_KEEPALIVE_INTERVAL_SECONDS * 1000;
  LReturned := 0;
  // Melhor esforco, como o TCP_NODELAY: sem keepalive a conexao ainda
  // funciona, so perde a deteccao/manutencao de ociosidade.
  pipe_WSAIoctl(ASocket, PIPE_SIO_KEEPALIVE_VALS, @LVals, SizeOf(LVals),
    nil, 0, @LReturned, nil, nil);
end;

{ TPipeTcpWinEndpoint }

constructor TPipeTcpWinEndpoint.Create(ASocket: TSocket;
  AKeepAliveSeconds: Cardinal);
begin
  inherited Create;
  FSocket := ASocket;
  FSockEvent := NewWsaEvent;
  FStopEvent := NewWsaEvent;
  // Associa o socket ao evento. Efeito colateral documentado: o socket passa a
  // NAO-BLOCANTE. Tambem desfaz a associacao herdada do listener no accept.
  if WSAEventSelect(FSocket, FSockEvent,
       PIPE_FD_READ or PIPE_FD_WRITE or PIPE_FD_CLOSE) <> 0 then
    raise EPipeError.CreateFmt('WSAEventSelect falhou (WSA %d)',
      [WSAGetLastError]);
  SetNoDelay(FSocket);
  SetKeepAlive(FSocket, AKeepAliveSeconds);
end;

destructor TPipeTcpWinEndpoint.Destroy;
begin
  CloseAbort; // idempotente
  if FSocket <> INVALID_SOCKET then
    closesocket(FSocket);
  if FSockEvent <> PIPE_WSA_INVALID_EVENT then
    WSACloseEvent(FSockEvent);
  if FStopEvent <> PIPE_WSA_INVALID_EVENT then
    WSACloseEvent(FStopEvent);
  inherited;
end;

procedure TPipeTcpWinEndpoint.CloseAbort;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit; // ja abortado
  if FStopEvent <> PIPE_WSA_INVALID_EVENT then
    WSASetEvent(FStopEvent);          // acorda esperas atuais e futuras
  if FSocket <> INVALID_SOCKET then
    shutdown(FSocket, PIPE_SD_BOTH);  // desarma recv/send residual no kernel
end;

procedure TPipeTcpWinEndpoint.SetIoDeadline(ATimeoutMs: Cardinal);
begin
  FIoTimeoutMs := ATimeoutMs;
end;

procedure TPipeTcpWinEndpoint.WaitReadyOrStop(const AOp: string);
var
  LEvents: array[0..1] of WSAEVENT;
  LNet: TPipeNetworkEvents;
  LRc: DWORD;
  LWait: DWORD;
begin
  if PipeAtomicGet(FClosed) <> 0 then
    raise EPipeClosed.Create(AOp + ' em endpoint fechado');
  LEvents[0] := FSockEvent;
  LEvents[1] := FStopEvent;
  if FIoTimeoutMs = 0 then
    LWait := PIPE_WSA_INFINITE
  else
    LWait := FIoTimeoutMs;
  LRc := WSAWaitForMultipleEvents(2, @LEvents[0], False, LWait, False);
  if LRc = PIPE_WSA_WAIT_FAILED then
    RaiseWsaError(AOp + ' (wait)', WSAGetLastError);
  if LRc = PIPE_WSA_WAIT_TIMEOUT then
    raise EPipeTimeout.CreateFmt('%s: o par nao respondeu em %u ms',
      [AOp, FIoTimeoutMs]);
  // Stop pode estar sinalizado junto com o socket; a checagem explicita evita
  // depender de qual indice o wait devolveu.
  if (LRc = PIPE_WSA_WAIT_EVENT_0 + 1) or (PipeAtomicGet(FClosed) <> 0) then
    raise EPipeClosed.Create(AOp + ' abortada (CloseAbort)');
  // Reseta FSockEvent e consome os eventos pendentes; sem isso o evento fica
  // sinalizado e a proxima espera nao bloquearia.
  FillChar(LNet, SizeOf(LNet), 0);
  pipe_WSAEnumNetworkEvents(FSocket, FSockEvent, @LNet);
  // Erro concreto (ex.: FD_CLOSE com erro) fica para o recv/send seguinte
  // reportar: ainda pode haver dado enfileirado para ler depois do FD_CLOSE.
end;

function TPipeTcpWinEndpoint.Read(var ABuffer; ACount: Integer): Integer;
var
  LGot, LErr: Integer;
begin
  while True do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      raise EPipeClosed.Create('leitura em endpoint fechado');
    LGot := recv(FSocket, ABuffer, ACount, 0);
    if LGot > 0 then
      Exit(LGot);
    if LGot = 0 then
      raise EPipeClosed.Create('conexao encerrada pelo par');
    LErr := WSAGetLastError;
    if LErr = WSAEWOULDBLOCK then
      WaitReadyOrStop('leitura') // sem dado ainda: espera o socket ou o stop
    else
      RaiseWsaError('leitura', LErr);
  end;
end;

procedure TPipeTcpWinEndpoint.WriteExactly(const ABuffer; ACount: Integer);
var
  P: PByte;
  LSent, LErr: Integer;
begin
  P := @ABuffer;
  while ACount > 0 do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      raise EPipeClosed.Create('escrita em endpoint fechado');
    LSent := send(FSocket, P^, ACount, 0);
    if LSent > 0 then
    begin
      Inc(P, LSent);
      Dec(ACount, LSent);
      Continue;
    end;
    LErr := WSAGetLastError;
    if LErr = WSAEWOULDBLOCK then
      WaitReadyOrStop('escrita') // buffer de saida cheio: espera destravar
    else
      RaiseWsaError('escrita', LErr);
  end;
end;

{ TPipeTcpWinListener }

constructor TPipeTcpWinListener.Create(ASocket: TSocket;
  AKeepAliveSeconds: Cardinal);
begin
  inherited Create;
  FSocket := ASocket;
  FAcceptEvent := NewWsaEvent;
  FStopEvent := NewWsaEvent;
  FKeepAliveSeconds := AKeepAliveSeconds;
  if WSAEventSelect(FSocket, FAcceptEvent, PIPE_FD_ACCEPT) <> 0 then
    raise EPipeError.CreateFmt('WSAEventSelect(accept) falhou (WSA %d)',
      [WSAGetLastError]);
end;

destructor TPipeTcpWinListener.Destroy;
begin
  Close; // idempotente
  // Assume acceptor thread ja joinada (contrato de Pipes.Transport).
  if FSocket <> INVALID_SOCKET then
    closesocket(FSocket);
  if FAcceptEvent <> PIPE_WSA_INVALID_EVENT then
    WSACloseEvent(FAcceptEvent);
  if FStopEvent <> PIPE_WSA_INVALID_EVENT then
    WSACloseEvent(FStopEvent);
  inherited;
end;

procedure TPipeTcpWinListener.Close;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit;
  if FStopEvent <> PIPE_WSA_INVALID_EVENT then
    WSASetEvent(FStopEvent); // desbloqueia o Accept pendente (devolve nil)
end;

function TPipeTcpWinListener.Accept: TPipeEndpoint;
var
  LEvents: array[0..1] of WSAEVENT;
  LNet: TPipeNetworkEvents;
  LRc: DWORD;
  LConn: TSocket;
  LErr: Integer;
begin
  Result := nil;
  // Loop: um cliente que conecta e cai antes do accept recicla a espera, sem
  // devolver endpoint morto (mesma semantica dos listeners locais).
  while True do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      Exit;
    LConn := WinSock2.accept(FSocket, nil, nil);
    if LConn <> INVALID_SOCKET then
      Exit(TPipeTcpWinEndpoint.Create(LConn, FKeepAliveSeconds));
    LErr := WSAGetLastError;
    if LErr <> WSAEWOULDBLOCK then
    begin
      if LErr = WSAECONNRESET then
        Continue; // cliente caiu antes do accept: volta a esperar
      RaiseWsaError('accept', LErr);
    end;
    LEvents[0] := FAcceptEvent;
    LEvents[1] := FStopEvent;
    LRc := WSAWaitForMultipleEvents(2, @LEvents[0], False, PIPE_WSA_INFINITE,
      False);
    if LRc = PIPE_WSA_WAIT_FAILED then
      RaiseWsaError('accept (wait)', WSAGetLastError);
    if (LRc = PIPE_WSA_WAIT_EVENT_0 + 1) or (PipeAtomicGet(FClosed) <> 0) then
      Exit; // Close: devolve nil
    FillChar(LNet, SizeOf(LNet), 0);
    pipe_WSAEnumNetworkEvents(FSocket, FAcceptEvent, @LNet);
  end;
end;

{ --- fabricas (Windows) --- }

procedure EnsureWinsock;
var
  LData: TWSAData;
begin
  if GWinsockReady then
    Exit;
  if WSAStartup($0202, LData) <> 0 then
    raise EPipeError.CreateFmt('WSAStartup falhou (WSA %d)', [WSAGetLastError]);
  GWinsockReady := True;
end;

function TcpPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPipeListener;
var
  LInfo, LCur: PPipeAddrInfo;
  LSock: TSocket;
  LErr: Integer;
begin
  EnsureWinsock;
  LErr := 0;
  LInfo := ResolveAddress(AAddress, True);
  try
    LCur := LInfo;
    while LCur <> nil do
    begin
      LSock := WinSock2.socket(LCur^.ai_family, LCur^.ai_socktype,
        LCur^.ai_protocol);
      if LSock <> INVALID_SOCKET then
      begin
        // Sem SO_REUSEADDR de proposito: no Windows ele permitiria outro
        // processo sequestrar a porta (ver cabecalho da unit).
        // No socket de escuta as opcoes valem como molde: o accept devolve
        // socket que as herda. No Windows o TPipeTcpWinEndpoint ainda reaplica
        // explicitamente, entao a heranca aqui e' cinto e suspensorio.
        SetKeepAlive(LSock, AKeepAliveSeconds);
        if (pipe_bind(LSock, LCur^.ai_addr, Integer(LCur^.ai_addrlen)) = 0)
          and (WinSock2.listen(LSock, PIPE_LISTEN_BACKLOG) = 0) then
          Exit(TPipeTcpWinListener.Create(LSock, AKeepAliveSeconds));
        LErr := WSAGetLastError;
        closesocket(LSock);
      end
      else
        LErr := WSAGetLastError;
      LCur := LCur^.ai_next;
    end;
  finally
    pipe_freeaddrinfo(LInfo);
  end;
  RaiseWsaError(Format('escuta em %s', [AAddress]), LErr);
  Result := nil; // inalcancavel (RaiseWsaError sempre levanta)
end;

// Tenta UM candidato com connect nao-blocante, limitado por ADeadline. Devolve
// o socket conectado ou INVALID_SOCKET (com AErr preenchido).
//
// O connect precisa ser nao-blocante: blocante, uma unica tentativa presa no
// kernel ignora ATimeoutMs por completo (num host que nao responde o SYN, o
// Windows insiste ~20s antes de desistir), e Connect(300) levaria segundos.
function ConnectCandidate(ACand: PPipeAddrInfo; ADeadline: UInt64;
  out AErr: Integer): TSocket;
var
  LSock: TSocket;
  LEvent: WSAEVENT;
  LNet: TPipeNetworkEvents;
  LRemaining: Int64;
  LRc: DWORD;
begin
  Result := INVALID_SOCKET;
  AErr := 0;
  LSock := WinSock2.socket(ACand^.ai_family, ACand^.ai_socktype,
    ACand^.ai_protocol);
  if LSock = INVALID_SOCKET then
  begin
    AErr := WSAGetLastError;
    Exit;
  end;
  LEvent := WSACreateEvent;
  if LEvent = PIPE_WSA_INVALID_EVENT then
  begin
    AErr := WSAGetLastError;
    closesocket(LSock);
    Exit;
  end;
  try
    // Associar ao evento ja torna o socket nao-blocante.
    if WSAEventSelect(LSock, LEvent, PIPE_FD_CONNECT) <> 0 then
    begin
      AErr := WSAGetLastError;
      closesocket(LSock);
      Exit;
    end;
    if pipe_connect(LSock, ACand^.ai_addr, Integer(ACand^.ai_addrlen)) = 0 then
      Exit(LSock); // conectou de imediato (loopback costuma cair aqui)
    AErr := WSAGetLastError;
    if AErr <> WSAEWOULDBLOCK then
    begin
      closesocket(LSock);
      Exit;
    end;
    LRemaining := Int64(ADeadline) - Int64(PipeTickMs);
    if LRemaining < 0 then
      LRemaining := 0;
    LRc := WSAWaitForMultipleEvents(1, @LEvent, True, DWORD(LRemaining), False);
    if LRc <> PIPE_WSA_WAIT_EVENT_0 then
    begin
      // WSA_WAIT_TIMEOUT ou falha: desiste deste candidato dentro do prazo.
      AErr := WSAETIMEDOUT;
      closesocket(LSock);
      Exit;
    end;
    FillChar(LNet, SizeOf(LNet), 0);
    if pipe_WSAEnumNetworkEvents(LSock, LEvent, @LNet) <> 0 then
    begin
      AErr := WSAGetLastError;
      closesocket(LSock);
      Exit;
    end;
    AErr := LNet.iErrorCode[PIPE_FD_CONNECT_BIT];
    if AErr <> 0 then
    begin
      closesocket(LSock); // recusado / inalcancavel
      Exit;
    end;
    Result := LSock;
  finally
    WSACloseEvent(LEvent);
  end;
end;

function TcpPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal): TPipeEndpoint;
var
  LInfo, LCur: PPipeAddrInfo;
  LSock: TSocket;
  LDeadline: UInt64;
  LErr: Integer;
begin
  EnsureWinsock;
  LDeadline := PipeTickMs + ATimeoutMs;
  LInfo := ResolveAddress(AAddress, False);
  try
    while True do
    begin
      LErr := 0;
      LCur := LInfo;
      while LCur <> nil do
      begin
        LSock := ConnectCandidate(LCur, LDeadline, LErr);
        if LSock <> INVALID_SOCKET then
          Exit(TPipeTcpWinEndpoint.Create(LSock, AKeepAliveSeconds));
        LCur := LCur^.ai_next;
      end;
      // Servidor ainda nao subiu ou backlog cheio: re-tenta ate o prazo, que
      // e' o que da a Connect(timeout) semantica igual a do transporte local.
      if (LErr <> WSAECONNREFUSED) and (LErr <> WSAETIMEDOUT) then
        RaiseWsaError(Format('conexao a %s', [AAddress]), LErr);
      if Int64(LDeadline) - Int64(PipeTickMs) <= 0 then
        raise EPipeTimeout.CreateFmt('timeout (%u ms) conectando a %s',
          [ATimeoutMs, AAddress]);
      Sleep(25);
    end;
  finally
    pipe_freeaddrinfo(LInfo);
  end;
end;

{$ELSE}

{ ============================== POSIX (sockets) ============================= }

procedure RaiseIoError(const AOp: string; AErr: cint);
begin
  raise EPipeError.CreateFmt('%s falhou (erro %d: %s)',
    [AOp, AErr, SysErrorMessage(AErr)]);
end;

const
  PIPE_TCP_NODELAY  = 1;
  // <netinet/tcp.h> (Linux). Nao expostos pela unit Sockets do FPC 3.2.2.
  PIPE_TCP_KEEPIDLE  = 4;
  PIPE_TCP_KEEPINTVL = 5;
  PIPE_TCP_KEEPCNT   = 6;

procedure SetNoDelay(AFd: cint);
var
  LOn: cint;
begin
  LOn := 1;
  // Melhor esforco (ver equivalente Windows).
  fpSetSockOpt(AFd, PIPE_IPPROTO_TCP, PIPE_TCP_NODELAY, @LOn, SizeOf(LOn));
end;

// Aqui, diferente do Windows, os tres parametros sao ajustaveis por socket, o
// que torna a deteccao previsivel: ASeconds ociosos + PROBE_COUNT probes a
// cada INTERVAL segundos.
procedure SetKeepAlive(AFd: cint; ASeconds: Cardinal);
var
  LVal: cint;
begin
  if ASeconds = 0 then
    Exit;
  LVal := 1;
  fpSetSockOpt(AFd, SOL_SOCKET, SO_KEEPALIVE, @LVal, SizeOf(LVal));
  LVal := cint(ASeconds);
  fpSetSockOpt(AFd, PIPE_IPPROTO_TCP, PIPE_TCP_KEEPIDLE, @LVal, SizeOf(LVal));
  LVal := PIPES_KEEPALIVE_INTERVAL_SECONDS;
  fpSetSockOpt(AFd, PIPE_IPPROTO_TCP, PIPE_TCP_KEEPINTVL, @LVal, SizeOf(LVal));
  LVal := PIPES_KEEPALIVE_PROBE_COUNT;
  fpSetSockOpt(AFd, PIPE_IPPROTO_TCP, PIPE_TCP_KEEPCNT, @LVal, SizeOf(LVal));
end;

function TcpPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal): TPipeListener;
var
  LInfo, LCur: PPipeAddrInfo;
  LFd, LErr, LOn: cint;
begin
  LErr := 0;
  LInfo := ResolveAddress(AAddress, True);
  try
    LCur := LInfo;
    while LCur <> nil do
    begin
      LFd := fpSocket(LCur^.ai_family, LCur^.ai_socktype, LCur^.ai_protocol);
      if LFd >= 0 then
      begin
        // No POSIX SO_REUSEADDR so evita o TIME_WAIT barrar o rebind — e' o
        // comportamento desejado, diferente do Windows.
        LOn := 1;
        fpSetSockOpt(LFd, SOL_SOCKET, SO_REUSEADDR, @LOn, SizeOf(LOn));
        // No POSIX o socket aceito HERDA as opcoes do socket de escuta (nao ha
        // hook de accept aqui: quem aceita e' o TPipePosixListener, que e'
        // compartilhado com o transporte UDS). Por isso o keepalive e' setado
        // no molde, antes do bind.
        SetKeepAlive(LFd, AKeepAliveSeconds);
        if (fpBind(LFd, LCur^.ai_addr, LCur^.ai_addrlen) = 0)
          and (fpListen(LFd, PIPE_LISTEN_BACKLOG) = 0) then
          // Path vazio: nao ha arquivo de socket para remover no destructor.
          Exit(TPipePosixListener.CreateFromFd(LFd, ''));
        LErr := fpgeterrno;
        fpClose(LFd);
      end
      else
        LErr := fpgeterrno;
      LCur := LCur^.ai_next;
    end;
  finally
    pipe_freeaddrinfo(LInfo);
  end;
  RaiseIoError(Format('escuta em %s', [AAddress]), LErr);
  Result := nil; // inalcancavel
end;

// Tenta UM candidato com connect nao-blocante, limitado por ADeadline. Devolve
// o fd conectado (em modo blocante de novo) ou -1, com AErr preenchido.
//
// Mesma razao do equivalente Windows: connect blocante ignoraria ATimeoutMs
// enquanto o kernel insiste no SYN de um host que nao responde.
function ConnectCandidate(ACand: PPipeAddrInfo; ADeadline: UInt64;
  out AErr: cint): cint;
var
  LFd, LFlags, LRc: cint;
  LPoll: pollfd;
  LSoErr: cint;
  LLen: TSockLen;
  LRemaining: Int64;
begin
  Result := -1;
  AErr := 0;
  LFd := fpSocket(ACand^.ai_family, ACand^.ai_socktype, ACand^.ai_protocol);
  if LFd < 0 then
  begin
    AErr := fpgeterrno;
    Exit;
  end;
  LFlags := fpFcntl(LFd, F_GetFl, 0);
  fpFcntl(LFd, F_SetFl, LFlags or O_NONBLOCK);
  if fpConnect(LFd, ACand^.ai_addr, ACand^.ai_addrlen) <> 0 then
  begin
    AErr := fpgeterrno;
    if AErr <> ESysEINPROGRESS then
    begin
      fpClose(LFd);
      Exit;
    end;
    LRemaining := Int64(ADeadline) - Int64(PipeTickMs);
    if LRemaining < 0 then
      LRemaining := 0;
    repeat
      LPoll.fd := LFd;
      LPoll.events := POLLOUT;
      LPoll.revents := 0;
      LRc := fpPoll(@LPoll, 1, LRemaining);
    until (LRc >= 0) or (fpgeterrno <> ESysEINTR);
    if LRc <= 0 then
    begin
      // 0 = estourou o prazo; <0 = erro no proprio poll.
      if LRc = 0 then
        AErr := ESysETIMEDOUT
      else
        AErr := fpgeterrno;
      fpClose(LFd);
      Exit;
    end;
    // POLLOUT sozinho nao significa sucesso: o resultado real do connect vem
    // do SO_ERROR do socket.
    LSoErr := 0;
    LLen := SizeOf(LSoErr);
    if fpGetSockOpt(LFd, SOL_SOCKET, SO_ERROR, @LSoErr, @LLen) <> 0 then
      LSoErr := fpgeterrno;
    if LSoErr <> 0 then
    begin
      AErr := LSoErr;
      fpClose(LFd);
      Exit;
    end;
  end;
  // Restaura o modo blocante: TPipePosixEndpoint espera a mesma semantica do
  // socket AF_UNIX (poll antes de cada operacao, recv/send blocantes).
  fpFcntl(LFd, F_SetFl, LFlags);
  AErr := 0;
  Result := LFd;
end;

function TcpPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal): TPipeEndpoint;
var
  LInfo, LCur: PPipeAddrInfo;
  LFd, LErr: cint;
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
          Exit(TPipePosixEndpoint.Create(LFd));
        end;
        LCur := LCur^.ai_next;
      end;
      if (LErr <> ESysECONNREFUSED) and (LErr <> ESysETIMEDOUT) then
        RaiseIoError(Format('conexao a %s', [AAddress]), LErr);
      if Int64(LDeadline) - Int64(PipeTickMs) <= 0 then
        raise EPipeTimeout.CreateFmt('timeout (%u ms) conectando a %s',
          [ATimeoutMs, AAddress]);
      Sleep(25);
    end;
  finally
    pipe_freeaddrinfo(LInfo);
  end;
end;

{$ENDIF}

{$IFDEF PIPES_WINDOWS}
initialization
  // Vazia de proposito: o Delphi so aceita 'finalization' se houver
  // 'initialization' (o FPC aceita a secao sozinha). O WSAStartup fica em
  // EnsureWinsock, para nao cobrar Winsock de quem so usa ptLocal.

finalization
  if GWinsockReady then
    WSACleanup;
{$ENDIF}

end.
