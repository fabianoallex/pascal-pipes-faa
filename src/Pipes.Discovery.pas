unit Pipes.Discovery;

{$I pipes.inc}

{ Descoberta de servidor na LAN por broadcast UDP (protocolo NPD1).

  Responde a pergunta "onde esta o servidor?" sem IP configurado: o cliente
  manda uma sonda para 255.255.255.255:<porta de descoberta>, todo host da
  sub-rede recebe, e quem tiver um TPipeDiscoveryResponder ativo devolve
  (em unicast, so para quem perguntou) a porta do servico, o transporte e um
  nome. O resultado alimenta TPipeClient.Address/FailoverAddresses.

  E' um COMPLEMENTO aos transportes, nao um transporte: nenhum frame NPF1
  trafega por aqui e nada nesta unit depende de Pipes.Transport. UDP e'
  aceitavel neste recorte (e so' nele) porque o protocolo e' idempotente por
  natureza: sonda perdida, a proxima acha; resposta perdida, a da proxima
  sonda chega; resposta duplicada, o dedup descarta. Nenhuma das garantias
  da lib (entrega, ordem) e' necessaria.

  Decisoes de design (racional completo em docs/ARQUITETURA.md, secao 16):

  - O IP do servidor vem do ENVELOPE, nao da carta: o cliente usa o endereco
    de origem do datagrama de resposta (recvfrom), nunca um IP embutido no
    payload. Num servidor multi-NIC, o IP de origem que o cliente enxerga e'
    por construcao um que o alcanca; o proprio servidor nao teria como saber
    qual anunciar. O payload so' informa a PORTA do servico.
  - Broadcast, nao multicast: o alcance desejado ("a loja") e' exatamente a
    sub-rede local. Multicast exigiria IGMP e, no Android, MulticastLock.
    Consequencia documentada: descoberta NAO atravessa roteador nem VPN — PDV
    remoto continua usando IP configurado + FailoverAddresses.
  - IPv4 apenas: broadcast nao existe em IPv6 (la seria multicast, fora de
    escopo). O socket e' AF_INET.
  - Descoberta encontra, TLS autentica: qualquer processo na LAN pode
    responder a sonda, inclusive um impostor. A resposta e' um CANDIDATO,
    nunca identidade — quem prova quem e' o servidor e' o ptTls na conexao
    que se segue. O Token e' discriminador de instalacao (higiene), nao
    segredo nem autenticacao: viaja em claro.
  - Anti-amplificacao: o responder so' responde a sonda com magic e token
    validos, e a resposta tem teto pequeno (~200 bytes). Datagrama que nao
    decodifica e' descartado em silencio.

  Protocolo NPD1 (comprimentos estritos; datagrama com sobra e' recusado):
    sonda    = 'NPD1' + kind(1)=1 + tokenLen(1) + token[UTF-8]
    resposta = 'NPD1' + kind(1)=2 + tokenLen(1) + token[UTF-8]
             + porta do servico (2 bytes little-endian)
             + transporte (1 byte, Ord de TPipeTransport)
             + nameLen(1) + nome[UTF-8]

  Threading:
  - O responder tem UMA thread propria, que nao executa codigo de usuario
    nenhum (nao ha callbacks nesta unit) — le sonda, valida, responde com um
    payload pre-codificado no construtor. Parada pelo mesmo mecanismo dos
    transportes: evento WSA no Windows, self-pipe + poll no POSIX/Android;
    nenhuma espera usa timeout de polling.
  - Erro fatal inesperado encerra a thread do responder em silencio (sem
    callback de erro em v1); Stop/Destroy continuam funcionando normalmente.
  - Start/Stop/Active sao thread-safe entre si (FLock); Stop e o destructor
    sao idempotentes. Ordem de teardown: Abort do canal -> WaitFor -> Free.
  - PipeDiscoverServers e' sincrona e roda inteira na thread chamadora; o
    prazo e' ATimeoutMs e nao ha cancelamento externo (nao segure a main
    thread de UI com timeouts longos).

  Limitacoes assumidas: um responder por maquina por porta de descoberta
  (sem SO_REUSEADDR — no Windows ele permitiria sequestro da porta, mesma
  razao do Pipes.Transport.Tcp); mais de um servico na mesma maquina usa
  portas de descoberta distintas. Firewall precisa liberar UDP de entrada na
  porta de descoberta (no Windows o primeiro Start costuma disparar o prompt
  do firewall). }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing; // PipeUtf8Encode/Decode (lossless nos dois compiladores)

const
  /// Porta UDP padrao da descoberta (mude se colidir com algo do ambiente;
  /// cliente e responder precisam usar a MESMA).
  PIPES_DISCOVERY_DEFAULT_PORT = 42517;
  /// Teto do token em bytes UTF-8 (discriminador de instalacao).
  PIPES_DISCOVERY_MAX_TOKEN_BYTES = 64;
  /// Teto do nome anunciado em bytes UTF-8.
  PIPES_DISCOVERY_MAX_NAME_BYTES = 128;

type
  /// Um servidor encontrado. Address ja vem no formato 'ip:porta' aceito por
  /// TPipeClient.Address (o IP e' o endereco de origem da resposta — ver
  /// cabecalho).
  TPipeServerInfo = record
    Address: string;
    Transport: TPipeTransport;
    Name: string;
  end;

  /// Lado servidor: anuncia UM servico numa porta de descoberta. Crie ao lado
  /// do TPipeServer, chame Start depois do Listen e Stop junto do Stop dele.
  /// A resposta e' pre-codificada no construtor (que valida os tetos e ja
  /// levanta EPipeError em nome/token longos ou AServicePort = 0).
  TPipeDiscoveryResponder = class
  private
    FLock: TCriticalSection;
    FChannel: TObject;   // TPipeUdpChannel (interno da implementation)
    FThread: TThread;    // TPipeDiscoveryResponderThread
    FDiscoveryPort: Word;
    FToken: string;
    FReply: TBytes;      // resposta NPD1 pronta; imutavel apos o construtor
  public
    constructor Create(AServicePort: Word; ATransport: TPipeTransport;
      const AName: string;
      ADiscoveryPort: Word = PIPES_DISCOVERY_DEFAULT_PORT;
      const AToken: string = '');
    /// Idempotente; chama Stop.
    destructor Destroy; override;
    /// Abre o socket (bind na porta de descoberta — EPipeError com mensagem
    /// clara se ja houver outro responder nela) e inicia a thread. Idempotente.
    procedure Start;
    /// Para a thread e fecha o socket. Idempotente; conclui em milissegundos.
    procedure Stop;
    function Active: Boolean;
  end;

/// Lado cliente: manda sondas em broadcast e coleta respostas ate ATimeoutMs.
/// Devolve os servidores encontrados na ordem de chegada (o primeiro a
/// responder vem primeiro — na pratica, o de menor RTT) e sem duplicatas.
/// Lista vazia NAO e' erro: e' "ninguem respondeu". EPipeError so' quando nem
/// a primeira sonda pode ser transmitida (sem rede nenhuma, por exemplo).
function PipeDiscoverServers(ATimeoutMs: Cardinal = 1000;
  ADiscoveryPort: Word = PIPES_DISCOVERY_DEFAULT_PORT;
  const AToken: string = ''): TArray<TPipeServerInfo>; overload;

/// Forma dirigida: sonda um host especifico em unicast ("o servidor de IP
/// conhecido esta vivo?") em vez de broadcast — e tambem o caminho dos testes
/// (127.0.0.1). ATargetHost precisa ser um literal IPv4; nome de host nao e'
/// resolvido aqui (EPipeError com mensagem util).
function PipeDiscoverServers(const ATargetHost: string; ATimeoutMs: Cardinal;
  ADiscoveryPort: Word = PIPES_DISCOVERY_DEFAULT_PORT;
  const AToken: string = ''): TArray<TPipeServerInfo>; overload;

// --- Protocolo NPD1 (funcoes puras; expostas para os testes unitarios) ------

/// EPipeError se o token estoura PIPES_DISCOVERY_MAX_TOKEN_BYTES.
function PipeDiscoveryEncodeProbe(const AToken: string): TBytes;
/// True se ADatagram e' uma sonda NPD1 valida COM o token esperado.
function PipeDiscoveryTryDecodeProbe(const ADatagram: TBytes;
  const AToken: string): Boolean;
/// EPipeError se nome/token estouram os tetos ou AServicePort = 0.
function PipeDiscoveryEncodeResponse(AServicePort: Word;
  ATransport: TPipeTransport; const AName, AToken: string): TBytes;
/// True se ADatagram e' uma resposta NPD1 valida com o token esperado e um
/// transporte conhecido (byte de transporte desconhecido = versao mais nova
/// do outro lado: recusa, nao adivinha).
function PipeDiscoveryTryDecodeResponse(const ADatagram: TBytes;
  const AToken: string; out AServicePort: Word;
  out ATransport: TPipeTransport; out AName: string): Boolean;

/// LongWord em ordem de REDE (como sai do recvfrom) -> 'a.b.c.d'.
function PipeIPv4ToString(ANetAddr: LongWord): string;
/// 'a.b.c.d' -> LongWord em ordem de REDE. False se nao for um literal IPv4.
function PipeTryStringToIPv4(const AHost: string;
  out ANetAddr: LongWord): Boolean;

implementation

{$IFDEF PIPES_WINDOWS}
uses
  Windows, WinSock2;
{$ELSE}
  {$IFDEF PIPES_ANDROID}
uses
  Posix.Base,
  Posix.SysTypes,
  Posix.SysSocket,
  Posix.Unistd,
  Posix.Fcntl,
  Posix.Errno;
  {$ELSE}
uses
  UnixType, BaseUnix, Sockets;
  {$ENDIF}
{$ENDIF}

{ =========================== Protocolo NPD1 (puro) ========================= }

const
  DISC_MAGIC_0 = Ord('N');
  DISC_MAGIC_1 = Ord('P');
  DISC_MAGIC_2 = Ord('D');
  DISC_MAGIC_3 = Ord('1');
  DISC_KIND_PROBE = 1;
  DISC_KIND_RESPONSE = 2;
  DISC_HEADER_BYTES = 6; // magic(4) + kind(1) + tokenLen(1)

function TokenToBytes(const AToken: string): TBytes;
begin
  Result := PipeUtf8Encode(AToken);
  if Length(Result) > PIPES_DISCOVERY_MAX_TOKEN_BYTES then
    raise EPipeError.CreateFmt('token de descoberta longo demais ' +
      '(%d bytes UTF-8; maximo %d)',
      [Length(Result), PIPES_DISCOVERY_MAX_TOKEN_BYTES]);
end;

// Preenche magic + kind + token e devolve o offset do primeiro byte livre.
function BuildHeader(var ABuf: TBytes; AKind: Byte;
  const ATokenBytes: TBytes): Integer;
begin
  ABuf[0] := DISC_MAGIC_0;
  ABuf[1] := DISC_MAGIC_1;
  ABuf[2] := DISC_MAGIC_2;
  ABuf[3] := DISC_MAGIC_3;
  ABuf[4] := AKind;
  ABuf[5] := Byte(Length(ATokenBytes));
  if Length(ATokenBytes) > 0 then
    Move(ATokenBytes[0], ABuf[DISC_HEADER_BYTES], Length(ATokenBytes));
  Result := DISC_HEADER_BYTES + Length(ATokenBytes);
end;

// Valida magic + kind + token e devolve em AOffset o primeiro byte apos o
// token. Comprimentos ESTRITOS ficam com o chamador (sonda e resposta tem
// totais diferentes); aqui so' se exige espaco para o proprio header.
function TryParseHeader(const ADatagram: TBytes; AKind: Byte;
  const AToken: string; out AOffset: Integer): Boolean;
var
  LTok: TBytes;
  LTokenLen: Integer;
begin
  Result := False;
  AOffset := 0;
  if Length(ADatagram) < DISC_HEADER_BYTES then
    Exit;
  if (ADatagram[0] <> DISC_MAGIC_0) or (ADatagram[1] <> DISC_MAGIC_1) or
     (ADatagram[2] <> DISC_MAGIC_2) or (ADatagram[3] <> DISC_MAGIC_3) then
    Exit;
  if ADatagram[4] <> AKind then
    Exit;
  LTokenLen := ADatagram[5];
  if Length(ADatagram) < DISC_HEADER_BYTES + LTokenLen then
    Exit;
  // Token esperado maior que o teto nunca casa (o comprimento ja difere de
  // qualquer datagrama valido) — sem caso especial.
  LTok := PipeUtf8Encode(AToken);
  if Length(LTok) <> LTokenLen then
    Exit;
  if (LTokenLen > 0) and
     not CompareMem(@LTok[0], @ADatagram[DISC_HEADER_BYTES], LTokenLen) then
    Exit;
  AOffset := DISC_HEADER_BYTES + LTokenLen;
  Result := True;
end;

function PipeDiscoveryEncodeProbe(const AToken: string): TBytes;
var
  LTok: TBytes;
begin
  Result := nil; // warning 5093 do FPC (Result gerenciado)
  LTok := TokenToBytes(AToken);
  SetLength(Result, DISC_HEADER_BYTES + Length(LTok));
  BuildHeader(Result, DISC_KIND_PROBE, LTok);
end;

function PipeDiscoveryTryDecodeProbe(const ADatagram: TBytes;
  const AToken: string): Boolean;
var
  LOfs: Integer;
begin
  Result := TryParseHeader(ADatagram, DISC_KIND_PROBE, AToken, LOfs)
    and (Length(ADatagram) = LOfs); // estrito: sonda nao tem corpo
end;

function PipeDiscoveryEncodeResponse(AServicePort: Word;
  ATransport: TPipeTransport; const AName, AToken: string): TBytes;
var
  LTok, LName: TBytes;
  LOfs: Integer;
begin
  Result := nil; // warning 5093 do FPC (Result gerenciado)
  if AServicePort = 0 then
    raise EPipeError.Create('porta de servico 0 nao e anunciavel');
  LTok := TokenToBytes(AToken);
  LName := PipeUtf8Encode(AName);
  if Length(LName) > PIPES_DISCOVERY_MAX_NAME_BYTES then
    raise EPipeError.CreateFmt('nome anunciado longo demais ' +
      '(%d bytes UTF-8; maximo %d)',
      [Length(LName), PIPES_DISCOVERY_MAX_NAME_BYTES]);
  SetLength(Result, DISC_HEADER_BYTES + Length(LTok) + 4 + Length(LName));
  LOfs := BuildHeader(Result, DISC_KIND_RESPONSE, LTok);
  Result[LOfs] := Byte(AServicePort and $FF);        // porta little-endian,
  Result[LOfs + 1] := Byte(AServicePort shr 8);      // como no NPF1
  Result[LOfs + 2] := Byte(Ord(ATransport));
  Result[LOfs + 3] := Byte(Length(LName));
  if Length(LName) > 0 then
    Move(LName[0], Result[LOfs + 4], Length(LName));
end;

function PipeDiscoveryTryDecodeResponse(const ADatagram: TBytes;
  const AToken: string; out AServicePort: Word;
  out ATransport: TPipeTransport; out AName: string): Boolean;
var
  LOfs, LNameLen: Integer;
  LTransportByte: Byte;
begin
  Result := False;
  AServicePort := 0;
  ATransport := ptLocal;
  AName := '';
  if not TryParseHeader(ADatagram, DISC_KIND_RESPONSE, AToken, LOfs) then
    Exit;
  if Length(ADatagram) < LOfs + 4 then
    Exit;
  LNameLen := ADatagram[LOfs + 3];
  if Length(ADatagram) <> LOfs + 4 + LNameLen then
    Exit; // estrito: sobra ou falta = lixo
  LTransportByte := ADatagram[LOfs + 2];
  if LTransportByte > Byte(Ord(High(TPipeTransport))) then
    Exit; // transporte de versao futura: recusa em vez de adivinhar
  AServicePort := Word(ADatagram[LOfs]) or (Word(ADatagram[LOfs + 1]) shl 8);
  if AServicePort = 0 then
    Exit;
  ATransport := TPipeTransport(LTransportByte);
  if LNameLen > 0 then
    AName := PipeUtf8Decode(Copy(ADatagram, LOfs + 4, LNameLen));
  Result := True;
end;

{ Os dois helpers de IPv4 guardam/leem o LongWord em ORDEM DE REDE: o byte de
  memoria mais baixo e' o primeiro octeto. Nos alvos do projeto (todos
  little-endian) isso equivale a montar o valor com o primeiro octeto nos bits
  baixos — e' o que recvfrom/sendto esperam em sin_addr. }

function PipeIPv4ToString(ANetAddr: LongWord): string;
begin
  Result := Format('%d.%d.%d.%d',
    [ANetAddr and $FF, (ANetAddr shr 8) and $FF,
     (ANetAddr shr 16) and $FF, (ANetAddr shr 24) and $FF]);
end;

function PipeTryStringToIPv4(const AHost: string;
  out ANetAddr: LongWord): Boolean;
var
  I, LOctet, LDigits, LShift: Integer;
  LDots: Integer;
  C: Char;
begin
  Result := False;
  ANetAddr := 0;
  LOctet := 0;
  LDigits := 0;
  LDots := 0;
  LShift := 0;
  for I := 1 to Length(AHost) do
  begin
    C := AHost[I];
    if (C >= '0') and (C <= '9') then
    begin
      LOctet := LOctet * 10 + (Ord(C) - Ord('0'));
      Inc(LDigits);
      if (LOctet > 255) or (LDigits > 3) then
        Exit;
    end
    else if C = '.' then
    begin
      if LDigits = 0 then
        Exit; // '..' ou '.1'
      Inc(LDots);
      if LDots > 3 then
        Exit;
      ANetAddr := ANetAddr or (LongWord(LOctet) shl LShift);
      Inc(LShift, 8);
      LOctet := 0;
      LDigits := 0;
    end
    else
      Exit; // qualquer outro char: nao e' literal IPv4
  end;
  if (LDots <> 3) or (LDigits = 0) then
    Exit;
  ANetAddr := ANetAddr or (LongWord(LOctet) shl LShift);
  Result := True;
end;

{ ========================= Canal UDP por plataforma ======================== }

type
  { sockaddr_in tem o mesmo layout de fio nas tres plataformas; declarar aqui
    (e passar como ponteiro opaco) evita as divergencias de tipagem entre as
    units de socket — mesmo idioma do TPipeAddrInfo em Pipes.Transport.Tcp. }
  TPipeUdpSockAddr = packed record
    sin_family: Word;
    sin_port: Word;     // ordem de rede
    sin_addr: LongWord; // ordem de rede
    sin_zero: array[0..7] of Byte;
  end;

  TPipeUdpWait = (uwReadable, uwStop, uwTimeout);

const
  DISC_AF_INET = 2;          // identico nas tres plataformas
  DISC_RECV_BUF_BYTES = 600; // > maior datagrama NPD1 valido (~200 bytes)

// Sem swap generico: monta a Word de rede byte a byte (hosts LE em todos os
// alvos; ver comentario dos helpers de IPv4).
function PortToNet(APort: Word): Word;
begin
  Result := Word(((APort and $FF) shl 8) or (APort shr 8));
end;

procedure BuildAddr(out AAddr: TPipeUdpSockAddr; AIp: LongWord; APort: Word);
begin
  FillChar(AAddr, SizeOf(AAddr), 0);
  AAddr.sin_family := DISC_AF_INET;
  AAddr.sin_port := PortToNet(APort);
  AAddr.sin_addr := AIp;
end;

{$IFDEF PIPES_WINDOWS}

{ --- Windows (Winsock, padrao [evento do socket, evento de stop]) ---------- }

const
  DISC_SOCK_DGRAM   = 2;
  DISC_IPPROTO_UDP  = 17;
  DISC_SOL_SOCKET   = $FFFF;
  DISC_SO_BROADCAST = $0020;
  DISC_FD_READ      = $01;
  DISC_WSA_INFINITE = Cardinal($FFFFFFFF);
  DISC_WSA_WAIT_FAILED = Cardinal($FFFFFFFF);
  DISC_WSA_WAIT_EVENT_0 = 0;
  DISC_WSA_WAIT_TIMEOUT = Cardinal(258);
  DISC_WSA_INVALID_EVENT = 0; // (WSAEVENT)NULL; a WinSock2 do FPC nao declara
  // _WSAIOW(IOC_VENDOR, 12) — mstcpip.h. Desliga o comportamento em que um
  // ICMP "porta inalcancavel" (sonda enviada a host sem responder) faz o
  // RECVFROM seguinte falhar com WSAECONNRESET, o que mataria a coleta.
  DISC_SIO_UDP_CONNRESET = LongWord($9800000C);

// sendto/recvfrom/bind com endereco como ponteiro opaco: as declaracoes da
// WinSock2 divergem entre Delphi e FPC (mesma razao do pipe_bind no Tcp).
function disc_bind(ASocket: TSocket; AAddr: Pointer;
  ANameLen: Integer): Integer; stdcall; external 'ws2_32.dll' name 'bind';
function disc_sendto(ASocket: TSocket; ABuf: Pointer; ALen, AFlags: Integer;
  AAddr: Pointer; AToLen: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'sendto';
function disc_recvfrom(ASocket: TSocket; ABuf: Pointer; ALen, AFlags: Integer;
  AFrom: Pointer; AFromLen: PInteger): Integer; stdcall;
  external 'ws2_32.dll' name 'recvfrom';
function disc_WSAIoctl(ASocket: TSocket; ACode: LongWord;
  AInBuf: Pointer; AInSize: LongWord; AOutBuf: Pointer; AOutSize: LongWord;
  ABytesReturned: PLongWord; AOverlapped: Pointer;
  ACompletion: Pointer): Integer; stdcall;
  external 'ws2_32.dll' name 'WSAIoctl';
function disc_WSAEnumNetworkEvents(ASocket: TSocket; AEvent: THandle;
  AEvents: Pointer): Integer; stdcall;
  external 'ws2_32.dll' name 'WSAEnumNetworkEvents';

type
  TDiscNetworkEvents = record
    lNetworkEvents: LongInt;
    iErrorCode: array[0..9] of Integer;
  end;

var
  GDiscWinsockReady: Boolean = False;

procedure EnsureWinsock;
var
  LData: TWSAData;
begin
  // WSAStartup e' contado por chamada no processo: iniciar aqui de novo (alem
  // do Pipes.Transport.Tcp) e' correto e mantem as units independentes.
  if GDiscWinsockReady then
    Exit;
  if WSAStartup($0202, LData) <> 0 then
    raise EPipeError.CreateFmt('WSAStartup falhou (WSA %d)', [WSAGetLastError]);
  GDiscWinsockReady := True;
end;

type
  TPipeUdpChannel = class
  private
    FSocket: TSocket;
    FRecvEvent: WSAEVENT; // FD_READ
    FStopEvent: WSAEVENT; // manual-reset, sinalizado por Abort
    FClosed: Integer;
  public
    constructor Create(ABindPort: Word; ABroadcast: Boolean);
    destructor Destroy; override;
    procedure Abort;
    function WaitReadable(ATimeoutMs: Int64): TPipeUdpWait;
    function TryRecvFrom(out AData: TBytes; out AFromIp: LongWord;
      out AFromPort: Word): Boolean;
    procedure SendTo(AIp: LongWord; APort: Word; const AData: TBytes);
  end;

constructor TPipeUdpChannel.Create(ABindPort: Word; ABroadcast: Boolean);
var
  LOn: Integer;
  LOff: LongWord;
  LReturned: LongWord;
  LAddr: TPipeUdpSockAddr;
  LErr: Integer;
begin
  inherited Create;
  EnsureWinsock;
  FRecvEvent := DISC_WSA_INVALID_EVENT;
  FStopEvent := DISC_WSA_INVALID_EVENT;
  FSocket := WinSock2.socket(DISC_AF_INET, DISC_SOCK_DGRAM, DISC_IPPROTO_UDP);
  if FSocket = INVALID_SOCKET then
    raise EPipeError.CreateFmt('socket UDP falhou (WSA %d)', [WSAGetLastError]);
  if ABroadcast then
  begin
    LOn := 1;
    if setsockopt(FSocket, DISC_SOL_SOCKET, DISC_SO_BROADCAST,
         @LOn, SizeOf(LOn)) <> 0 then
    begin
      LErr := WSAGetLastError;
      closesocket(FSocket);
      raise EPipeError.CreateFmt('SO_BROADCAST falhou (WSA %d)', [LErr]);
    end;
  end;
  // Melhor esforco: sem isto a coleta ainda funciona, so fica sujeita ao
  // WSAECONNRESET (tambem tolerado no TryRecvFrom — cinto e suspensorio).
  LOff := 0;
  LReturned := 0;
  disc_WSAIoctl(FSocket, DISC_SIO_UDP_CONNRESET, @LOff, SizeOf(LOff),
    nil, 0, @LReturned, nil, nil);
  if ABindPort <> 0 then
  begin
    BuildAddr(LAddr, 0 { INADDR_ANY }, ABindPort);
    if disc_bind(FSocket, @LAddr, SizeOf(LAddr)) <> 0 then
    begin
      LErr := WSAGetLastError;
      closesocket(FSocket);
      raise EPipeError.CreateFmt('porta de descoberta %d indisponivel — ja ' +
        'ha outro responder nela? (WSA %d)', [ABindPort, LErr]);
    end;
  end;
  // Associar ao evento torna o socket nao-blocante (cliente: o bind implicito
  // acontece no primeiro sendto).
  FRecvEvent := WSACreateEvent;
  FStopEvent := WSACreateEvent;
  if (FRecvEvent = DISC_WSA_INVALID_EVENT) or
     (FStopEvent = DISC_WSA_INVALID_EVENT) or
     (WSAEventSelect(FSocket, FRecvEvent, DISC_FD_READ) <> 0) then
  begin
    LErr := WSAGetLastError;
    closesocket(FSocket);
    FSocket := INVALID_SOCKET;
    if FRecvEvent <> DISC_WSA_INVALID_EVENT then
      WSACloseEvent(FRecvEvent);
    if FStopEvent <> DISC_WSA_INVALID_EVENT then
      WSACloseEvent(FStopEvent);
    raise EPipeError.CreateFmt('WSAEventSelect(FD_READ) falhou (WSA %d)',
      [LErr]);
  end;
end;

destructor TPipeUdpChannel.Destroy;
begin
  Abort; // idempotente; o dono so libera apos o join de quem usava o canal
  if FSocket <> INVALID_SOCKET then
    closesocket(FSocket);
  if FRecvEvent <> DISC_WSA_INVALID_EVENT then
    WSACloseEvent(FRecvEvent);
  if FStopEvent <> DISC_WSA_INVALID_EVENT then
    WSACloseEvent(FStopEvent);
  inherited;
end;

procedure TPipeUdpChannel.Abort;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit;
  if FStopEvent <> DISC_WSA_INVALID_EVENT then
    WSASetEvent(FStopEvent); // manual-reset: acorda esperas atuais e futuras
end;

function TPipeUdpChannel.WaitReadable(ATimeoutMs: Int64): TPipeUdpWait;
var
  LEvents: array[0..1] of WSAEVENT;
  LNet: TDiscNetworkEvents;
  LWait: Cardinal;
  LRc: Cardinal;
begin
  if PipeAtomicGet(FClosed) <> 0 then
    Exit(uwStop);
  LEvents[0] := FRecvEvent;
  LEvents[1] := FStopEvent;
  if ATimeoutMs < 0 then
    LWait := DISC_WSA_INFINITE
  else
    LWait := Cardinal(ATimeoutMs);
  LRc := WSAWaitForMultipleEvents(2, @LEvents[0], False, LWait, False);
  if LRc = DISC_WSA_WAIT_FAILED then
    raise EPipeError.CreateFmt('espera de descoberta falhou (WSA %d)',
      [WSAGetLastError]);
  if LRc = DISC_WSA_WAIT_TIMEOUT then
    Exit(uwTimeout);
  if (LRc = DISC_WSA_WAIT_EVENT_0 + 1) or (PipeAtomicGet(FClosed) <> 0) then
    Exit(uwStop);
  // Reseta FRecvEvent e consome o FD_READ pendente; sem isso a proxima espera
  // nao bloquearia (mesmo idioma do endpoint TCP).
  FillChar(LNet, SizeOf(LNet), 0);
  disc_WSAEnumNetworkEvents(FSocket, FRecvEvent, @LNet);
  Result := uwReadable;
end;

function TPipeUdpChannel.TryRecvFrom(out AData: TBytes; out AFromIp: LongWord;
  out AFromPort: Word): Boolean;
var
  LBuf: array[0..DISC_RECV_BUF_BYTES - 1] of Byte;
  LAddr: TPipeUdpSockAddr;
  LAddrLen, LGot, LErr: Integer;
begin
  AData := nil;
  AFromIp := 0;
  AFromPort := 0;
  while True do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      Exit(False);
    LAddrLen := SizeOf(LAddr);
    FillChar(LAddr, SizeOf(LAddr), 0);
    LGot := disc_recvfrom(FSocket, @LBuf[0], SizeOf(LBuf), 0,
      @LAddr, @LAddrLen);
    if LGot >= 0 then
    begin
      SetLength(AData, LGot);
      if LGot > 0 then
        Move(LBuf[0], AData[0], LGot);
      AFromIp := LAddr.sin_addr;
      AFromPort := PortToNet(LAddr.sin_port); // swap simetrico rede->host
      Exit(True);
    end;
    LErr := WSAGetLastError;
    case LErr of
      WSAEWOULDBLOCK:
        Exit(False); // fila vazia: volta a esperar no evento
      WSAECONNRESET, WSAENETRESET, WSAEMSGSIZE:
        Continue;    // eco de ICMP ou datagrama gigante: descarta e segue
    else
      raise EPipeError.CreateFmt('recvfrom de descoberta falhou (WSA %d)',
        [LErr]);
    end;
  end;
end;

procedure TPipeUdpChannel.SendTo(AIp: LongWord; APort: Word;
  const AData: TBytes);
var
  LAddr: TPipeUdpSockAddr;
  LErr: Integer;
begin
  BuildAddr(LAddr, AIp, APort);
  if disc_sendto(FSocket, @AData[0], Length(AData), 0,
       @LAddr, SizeOf(LAddr)) >= 0 then
    Exit;
  LErr := WSAGetLastError;
  if LErr = WSAEWOULDBLOCK then
    Exit; // buffer de saida cheio: para UDP equivale a perda na rede
  raise EPipeError.CreateFmt('sendto de descoberta falhou (WSA %d)', [LErr]);
end;

{$ELSE}
{$IFDEF PIPES_ANDROID}

{ --- Android (Posix.* + poll local, padrao self-pipe do backend Android) --- }

const
  DISC_SOCK_DGRAM   = 2;
  // bionic e' Linux: SO_BROADCAST = 6 (a unit Posix.SysSocket nao o expoe de
  // forma uniforme; mesma razao dos SHUT_*/MSG_NOSIGNAL locais no backend
  // POSIX).
  DISC_SO_BROADCAST = 6;
  DISC_POLLIN       = $0001;

type
  TDiscPollFd = record
    fd: Integer;
    events: SmallInt;
    revents: SmallInt;
  end;

// nfds_t = NativeUInt; ver o comentario do android_poll no backend Android.
function disc_poll(AFds: Pointer; ANfds: NativeUInt;
  ATimeoutMs: Integer): Integer; cdecl; external libc name _PU + 'poll';
function disc_bind(ASocket: Integer; AAddr: Pointer;
  ALen: socklen_t): Integer; cdecl; external libc name _PU + 'bind';
function disc_sendto(ASocket: Integer; ABuf: Pointer; ALen: NativeUInt;
  AFlags: Integer; AAddr: Pointer; AToLen: socklen_t): NativeInt; cdecl;
  external libc name _PU + 'sendto';
function disc_recvfrom(ASocket: Integer; ABuf: Pointer; ALen: NativeUInt;
  AFlags: Integer; AFrom: Pointer; AFromLen: Pointer): NativeInt; cdecl;
  external libc name _PU + 'recvfrom';

type
  TPipeUdpChannel = class
  private
    FFd: Integer;
    FStopR: Integer; // self-pipe: lado de leitura (entra em todo poll)
    FStopW: Integer; // self-pipe: lado de escrita (Abort escreve 1 byte)
    FClosed: Integer;
  public
    constructor Create(ABindPort: Word; ABroadcast: Boolean);
    destructor Destroy; override;
    procedure Abort;
    function WaitReadable(ATimeoutMs: Int64): TPipeUdpWait;
    function TryRecvFrom(out AData: TBytes; out AFromIp: LongWord;
      out AFromPort: Word): Boolean;
    procedure SendTo(AIp: LongWord; APort: Word; const AData: TBytes);
  end;

constructor TPipeUdpChannel.Create(ABindPort: Word; ABroadcast: Boolean);
var
  LOn: Integer;
  LAddr: TPipeUdpSockAddr;
  LErr: Integer;
  LFds: TPipeDescriptors;
begin
  inherited Create;
  FStopR := -1;
  FStopW := -1;
  FFd := socket(DISC_AF_INET, DISC_SOCK_DGRAM, 0);
  if FFd < 0 then
    raise EPipeError.CreateFmt('socket UDP falhou (erro %d)', [errno]);
  fcntl(FFd, F_SETFL, fcntl(FFd, F_GETFL) or O_NONBLOCK);
  if ABroadcast then
  begin
    LOn := 1;
    if setsockopt(FFd, SOL_SOCKET, DISC_SO_BROADCAST, LOn, SizeOf(LOn)) <> 0 then
    begin
      LErr := errno;
      __close(FFd);
      raise EPipeError.CreateFmt('SO_BROADCAST falhou (erro %d)', [LErr]);
    end;
  end;
  if ABindPort <> 0 then
  begin
    BuildAddr(LAddr, 0 { INADDR_ANY }, ABindPort);
    if disc_bind(FFd, @LAddr, SizeOf(LAddr)) <> 0 then
    begin
      LErr := errno;
      __close(FFd);
      raise EPipeError.CreateFmt('porta de descoberta %d indisponivel — ja ' +
        'ha outro responder nela? (erro %d)', [ABindPort, LErr]);
    end;
  end;
  if pipe(LFds) <> 0 then
  begin
    LErr := errno;
    __close(FFd);
    raise EPipeError.CreateFmt('pipe falhou (erro %d)', [LErr]);
  end;
  FStopR := LFds.ReadDes;
  FStopW := LFds.WriteDes;
end;

destructor TPipeUdpChannel.Destroy;
begin
  Abort; // idempotente; o dono so libera apos o join de quem usava o canal
  if FFd >= 0 then
    __close(FFd);
  if FStopR >= 0 then
    __close(FStopR);
  if FStopW >= 0 then
    __close(FStopW);
  inherited;
end;

procedure TPipeUdpChannel.Abort;
var
  LByte: Byte;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit;
  LByte := 1;
  if FStopW >= 0 then
    __write(FStopW, @LByte, 1); // acorda esperas atuais e futuras (nunca drenado)
end;

function TPipeUdpChannel.WaitReadable(ATimeoutMs: Int64): TPipeUdpWait;
var
  LFds: array[0..1] of TDiscPollFd;
  LRc: Integer;
  LDeadline: UInt64;
  LWait: Int64;
begin
  if PipeAtomicGet(FClosed) <> 0 then
    Exit(uwStop);
  LDeadline := 0;
  if ATimeoutMs >= 0 then
    LDeadline := PipeTickMs + UInt64(ATimeoutMs);
  repeat
    if ATimeoutMs < 0 then
      LWait := -1
    else
    begin
      // Recalculado a cada volta: um EINTR nao pode reiniciar o prazo.
      LWait := Int64(LDeadline) - Int64(PipeTickMs);
      if LWait < 0 then
        LWait := 0;
    end;
    LFds[0].fd := FFd;
    LFds[0].events := DISC_POLLIN;
    LFds[0].revents := 0;
    LFds[1].fd := FStopR;
    LFds[1].events := DISC_POLLIN;
    LFds[1].revents := 0;
    LRc := disc_poll(@LFds[0], 2, Integer(LWait));
  until (LRc >= 0) or (errno <> EINTR);
  if LRc < 0 then
    raise EPipeError.CreateFmt('poll de descoberta falhou (erro %d)', [errno]);
  if ((LFds[1].revents and DISC_POLLIN) <> 0) or
     (PipeAtomicGet(FClosed) <> 0) then
    Exit(uwStop);
  if LRc = 0 then
    Exit(uwTimeout);
  Result := uwReadable; // POLLERR/POLLHUP: deixa o recvfrom reportar
end;

function TPipeUdpChannel.TryRecvFrom(out AData: TBytes; out AFromIp: LongWord;
  out AFromPort: Word): Boolean;
var
  LBuf: array[0..DISC_RECV_BUF_BYTES - 1] of Byte;
  LAddr: TPipeUdpSockAddr;
  LAddrLen: socklen_t;
  LGot: NativeInt;
  LErr: Integer;
begin
  AData := nil;
  AFromIp := 0;
  AFromPort := 0;
  while True do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      Exit(False);
    LAddrLen := SizeOf(LAddr);
    FillChar(LAddr, SizeOf(LAddr), 0);
    LGot := disc_recvfrom(FFd, @LBuf[0], SizeOf(LBuf), 0, @LAddr, @LAddrLen);
    if LGot >= 0 then
    begin
      SetLength(AData, LGot);
      if LGot > 0 then
        Move(LBuf[0], AData[0], LGot);
      AFromIp := LAddr.sin_addr;
      AFromPort := PortToNet(LAddr.sin_port); // swap simetrico rede->host
      Exit(True);
    end;
    LErr := errno;
    if (LErr = EAGAIN) or (LErr = EWOULDBLOCK) then
      Exit(False); // fila vazia: volta ao poll
    if (LErr = EINTR) or (LErr = ECONNREFUSED) then
      Continue;    // sinal ou eco de ICMP: descarta e segue
    raise EPipeError.CreateFmt('recvfrom de descoberta falhou (erro %d)',
      [LErr]);
  end;
end;

procedure TPipeUdpChannel.SendTo(AIp: LongWord; APort: Word;
  const AData: TBytes);
var
  LAddr: TPipeUdpSockAddr;
  LErr: Integer;
begin
  BuildAddr(LAddr, AIp, APort);
  if disc_sendto(FFd, @AData[0], Length(AData), 0,
       @LAddr, SizeOf(LAddr)) >= 0 then
    Exit;
  LErr := errno;
  if (LErr = EAGAIN) or (LErr = EWOULDBLOCK) then
    Exit; // buffer de saida cheio: para UDP equivale a perda na rede
  raise EPipeError.CreateFmt('sendto de descoberta falhou (erro %d)', [LErr]);
end;

{$ELSE}

{ --- POSIX/FPC (fpPoll + self-pipe, padrao do backend Linux) ---------------- }

const
  // Valores Linux; a unit Sockets do FPC 3.2.2 nao expoe SO_BROADCAST de
  // forma uniforme em todos os alvos (mesma razao dos SHUT_* locais no
  // backend POSIX).
  DISC_SO_BROADCAST = 6;

type
  TPipeUdpChannel = class
  private
    FFd: cint;
    FStopR: cint; // self-pipe: lado de leitura (entra em todo poll)
    FStopW: cint; // self-pipe: lado de escrita (Abort escreve 1 byte)
    FClosed: Integer;
  public
    constructor Create(ABindPort: Word; ABroadcast: Boolean);
    destructor Destroy; override;
    procedure Abort;
    function WaitReadable(ATimeoutMs: Int64): TPipeUdpWait;
    function TryRecvFrom(out AData: TBytes; out AFromIp: LongWord;
      out AFromPort: Word): Boolean;
    procedure SendTo(AIp: LongWord; APort: Word; const AData: TBytes);
  end;

constructor TPipeUdpChannel.Create(ABindPort: Word; ABroadcast: Boolean);
var
  LOn: cint;
  LAddr: TPipeUdpSockAddr;
  LErr: cint;
  LFds: TFilDes;
begin
  inherited Create;
  FStopR := -1;
  FStopW := -1;
  FFd := fpSocket(DISC_AF_INET, SOCK_DGRAM, 0);
  if FFd < 0 then
    raise EPipeError.CreateFmt('socket UDP falhou (erro %d)', [fpgeterrno]);
  fpFcntl(FFd, F_SetFl, fpFcntl(FFd, F_GetFl, 0) or O_NONBLOCK);
  if ABroadcast then
  begin
    LOn := 1;
    if fpSetSockOpt(FFd, SOL_SOCKET, DISC_SO_BROADCAST,
         @LOn, SizeOf(LOn)) <> 0 then
    begin
      LErr := fpgeterrno;
      fpClose(FFd);
      raise EPipeError.CreateFmt('SO_BROADCAST falhou (erro %d)', [LErr]);
    end;
  end;
  if ABindPort <> 0 then
  begin
    BuildAddr(LAddr, 0 { INADDR_ANY }, ABindPort);
    if fpBind(FFd, psockaddr(@LAddr), SizeOf(LAddr)) <> 0 then
    begin
      LErr := fpgeterrno;
      fpClose(FFd);
      raise EPipeError.CreateFmt('porta de descoberta %d indisponivel — ja ' +
        'ha outro responder nela? (erro %d)', [ABindPort, LErr]);
    end;
  end;
  if fpPipe(LFds) <> 0 then
  begin
    LErr := fpgeterrno;
    fpClose(FFd);
    raise EPipeError.CreateFmt('fppipe falhou (erro %d)', [LErr]);
  end;
  FStopR := LFds[0];
  FStopW := LFds[1];
end;

destructor TPipeUdpChannel.Destroy;
begin
  Abort; // idempotente; o dono so libera apos o join de quem usava o canal
  if FFd >= 0 then
    fpClose(FFd);
  if FStopR >= 0 then
    fpClose(FStopR);
  if FStopW >= 0 then
    fpClose(FStopW);
  inherited;
end;

procedure TPipeUdpChannel.Abort;
var
  LByte: Byte;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit;
  LByte := 1;
  if FStopW >= 0 then
    fpWrite(FStopW, LByte, 1); // acorda esperas atuais e futuras (nunca drenado)
end;

function TPipeUdpChannel.WaitReadable(ATimeoutMs: Int64): TPipeUdpWait;
var
  LFds: array[0..1] of pollfd;
  LRc: cint;
  LDeadline: UInt64;
  LWait: Int64;
begin
  if PipeAtomicGet(FClosed) <> 0 then
    Exit(uwStop);
  LDeadline := 0;
  if ATimeoutMs >= 0 then
    LDeadline := PipeTickMs + UInt64(ATimeoutMs);
  repeat
    if ATimeoutMs < 0 then
      LWait := -1
    else
    begin
      // Recalculado a cada volta: um EINTR nao pode reiniciar o prazo.
      LWait := Int64(LDeadline) - Int64(PipeTickMs);
      if LWait < 0 then
        LWait := 0;
    end;
    LFds[0].fd := FFd;
    LFds[0].events := POLLIN;
    LFds[0].revents := 0;
    LFds[1].fd := FStopR;
    LFds[1].events := POLLIN;
    LFds[1].revents := 0;
    LRc := fpPoll(@LFds[0], 2, LWait);
  until (LRc >= 0) or (fpgeterrno <> ESysEINTR);
  if LRc < 0 then
    raise EPipeError.CreateFmt('poll de descoberta falhou (erro %d)',
      [fpgeterrno]);
  if ((LFds[1].revents and POLLIN) <> 0) or
     (PipeAtomicGet(FClosed) <> 0) then
    Exit(uwStop);
  if LRc = 0 then
    Exit(uwTimeout);
  Result := uwReadable; // POLLERR/POLLHUP: deixa o recvfrom reportar
end;

function TPipeUdpChannel.TryRecvFrom(out AData: TBytes; out AFromIp: LongWord;
  out AFromPort: Word): Boolean;
var
  LBuf: array[0..DISC_RECV_BUF_BYTES - 1] of Byte;
  LAddr: TPipeUdpSockAddr;
  LAddrLen: TSockLen;
  LGot: NativeInt;
  LErr: cint;
begin
  AData := nil;
  AFromIp := 0;
  AFromPort := 0;
  while True do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      Exit(False);
    LAddrLen := SizeOf(LAddr);
    FillChar(LAddr, SizeOf(LAddr), 0);
    LGot := fpRecvFrom(FFd, @LBuf[0], SizeOf(LBuf), 0,
      psockaddr(@LAddr), @LAddrLen);
    if LGot >= 0 then
    begin
      SetLength(AData, LGot);
      if LGot > 0 then
        Move(LBuf[0], AData[0], LGot);
      AFromIp := LAddr.sin_addr;
      AFromPort := PortToNet(LAddr.sin_port); // swap simetrico rede->host
      Exit(True);
    end;
    LErr := fpgeterrno;
    // So EAGAIN: no Linux EWOULDBLOCK e' o MESMO valor (e a constante nao
    // existe uniformemente no FPC 3.2.2).
    if LErr = ESysEAGAIN then
      Exit(False); // fila vazia: volta ao poll
    if (LErr = ESysEINTR) or (LErr = ESysECONNREFUSED) then
      Continue;    // sinal ou eco de ICMP: descarta e segue
    raise EPipeError.CreateFmt('recvfrom de descoberta falhou (erro %d)',
      [LErr]);
  end;
end;

procedure TPipeUdpChannel.SendTo(AIp: LongWord; APort: Word;
  const AData: TBytes);
var
  LAddr: TPipeUdpSockAddr;
  LErr: cint;
begin
  BuildAddr(LAddr, AIp, APort);
  if fpSendTo(FFd, @AData[0], Length(AData), 0,
       psockaddr(@LAddr), SizeOf(LAddr)) >= 0 then
    Exit;
  LErr := fpgeterrno;
  if LErr = ESysEAGAIN then // = EWOULDBLOCK no Linux (ver TryRecvFrom)
    Exit; // buffer de saida cheio: para UDP equivale a perda na rede
  raise EPipeError.CreateFmt('sendto de descoberta falhou (erro %d)', [LErr]);
end;

{$ENDIF}
{$ENDIF}

{ ============================ Responder (thread) =========================== }

type
  TPipeDiscoveryResponderThread = class(TThread)
  private
    FChannel: TPipeUdpChannel; // nao e' dono; o responder libera apos o join
    FToken: string;
    FReply: TBytes;
  protected
    procedure Execute; override;
  public
    constructor Create(AChannel: TPipeUdpChannel; const AToken: string;
      const AReply: TBytes);
  end;

constructor TPipeDiscoveryResponderThread.Create(AChannel: TPipeUdpChannel;
  const AToken: string; const AReply: TBytes);
begin
  FChannel := AChannel;
  FToken := AToken;
  FReply := AReply;
  inherited Create(False);
end;

procedure TPipeDiscoveryResponderThread.Execute;
var
  LData: TBytes;
  LIp: LongWord;
  LPort: Word;
begin
  // Nenhum codigo de usuario roda aqui (nao ha callbacks nesta unit); um erro
  // fatal inesperado encerra o responder em silencio — o teardown por Stop
  // continua integro porque so Abort/WaitFor/Free tocam o canal depois disso.
  try
    while not Terminated do
      case FChannel.WaitReadable(-1) of
        uwStop:
          Exit;
        uwReadable:
          while FChannel.TryRecvFrom(LData, LIp, LPort) do
            if PipeDiscoveryTryDecodeProbe(LData, FToken) then
            try
              // Unicast de volta a quem perguntou; falha aqui e' problema do
              // perguntador (que ja pode ter ido embora), nunca do responder.
              FChannel.SendTo(LIp, LPort, FReply);
            except
              on EPipeError do
                ;
            end;
      end;
  except
    // Sem OnError em v1 (ver cabecalho).
  end;
end;

{ TPipeDiscoveryResponder }

constructor TPipeDiscoveryResponder.Create(AServicePort: Word;
  ATransport: TPipeTransport; const AName: string; ADiscoveryPort: Word;
  const AToken: string);
begin
  inherited Create;
  // Valida tudo ja aqui (fail fast): tetos de nome/token e porta 0.
  FReply := PipeDiscoveryEncodeResponse(AServicePort, ATransport, AName,
    AToken);
  FToken := AToken;
  FDiscoveryPort := ADiscoveryPort;
  // Qualificado: no FPC/Win64 a unit Windows (na implementation) declara um
  // TCriticalSection RECORD que sombrearia o do SyncObjs aqui.
  FLock := SyncObjs.TCriticalSection.Create;
end;

destructor TPipeDiscoveryResponder.Destroy;
begin
  if FLock <> nil then
    Stop; // construtor pode ter falhado antes do FLock existir
  FLock.Free;
  inherited;
end;

procedure TPipeDiscoveryResponder.Start;
var
  LChannel: TPipeUdpChannel;
begin
  FLock.Enter;
  try
    if FThread <> nil then
      Exit; // ja ativo
    LChannel := TPipeUdpChannel.Create(FDiscoveryPort, False);
    FChannel := LChannel;
    FThread := TPipeDiscoveryResponderThread.Create(LChannel, FToken, FReply);
  finally
    FLock.Leave;
  end;
end;

procedure TPipeDiscoveryResponder.Stop;
begin
  FLock.Enter;
  try
    if FThread = nil then
      Exit;
    TPipeUdpChannel(FChannel).Abort; // acorda o WaitReadable
    FThread.WaitFor;
    FreeAndNil(FThread);
    FreeAndNil(FChannel); // so apos o join (contrato do canal)
  finally
    FLock.Leave;
  end;
end;

function TPipeDiscoveryResponder.Active: Boolean;
begin
  FLock.Enter;
  try
    Result := FThread <> nil;
  finally
    FLock.Leave;
  end;
end;

{ ============================= Cliente (coleta) ============================ }

const
  // Cadencia de reenvio da sonda dentro da janela: cobre a perda da primeira
  // (e da resposta dela) sem inundar a rede.
  DISC_RESEND_MS = 300;

procedure AppendUnique(var AList: TArray<TPipeServerInfo>;
  const AAddress, AName: string; ATransport: TPipeTransport);
var
  I: Integer;
begin
  for I := 0 to Length(AList) - 1 do
    if AList[I].Address = AAddress then
      Exit; // respostas repetidas (reenvio de sonda) sao esperadas
  SetLength(AList, Length(AList) + 1);
  AList[Length(AList) - 1].Address := AAddress;
  AList[Length(AList) - 1].Transport := ATransport;
  AList[Length(AList) - 1].Name := AName;
end;

function DoDiscover(ATargetIp: LongWord; ATimeoutMs: Cardinal;
  ADiscoveryPort: Word; const AToken: string): TArray<TPipeServerInfo>;
var
  LChannel: TPipeUdpChannel;
  LProbe, LData: TBytes;
  LDeadline, LNextSend: UInt64;
  LRemaining, LWaitMs, LToResend: Int64;
  LIp: LongWord;
  LFromPort, LSvcPort: Word;
  LTransport: TPipeTransport;
  LName: string;
begin
  Result := nil; // warning 5093 do FPC (Result gerenciado)
  LProbe := PipeDiscoveryEncodeProbe(AToken);
  // SO_BROADCAST sempre ligado no cliente: nao custa nada em unicast e cobre
  // tambem broadcast dirigido (ex.: '192.168.1.255').
  LChannel := TPipeUdpChannel.Create(0, True);
  try
    LDeadline := PipeTickMs + ATimeoutMs;
    // Primeira sonda: falha propaga (sem rede nenhuma o usuario tem que
    // saber). Reenvios sao melhor esforco.
    LChannel.SendTo(ATargetIp, ADiscoveryPort, LProbe);
    LNextSend := PipeTickMs + DISC_RESEND_MS;
    while True do
    begin
      LRemaining := Int64(LDeadline) - Int64(PipeTickMs);
      if LRemaining <= 0 then
        Break;
      LWaitMs := LRemaining;
      LToResend := Int64(LNextSend) - Int64(PipeTickMs);
      if LToResend < LWaitMs then
        LWaitMs := LToResend;
      if LWaitMs < 0 then
        LWaitMs := 0;
      case LChannel.WaitReadable(LWaitMs) of
        uwStop:
          Break; // inalcancavel aqui (ninguem chama Abort), mas correto
        uwReadable:
          while LChannel.TryRecvFrom(LData, LIp, LFromPort) do
            if PipeDiscoveryTryDecodeResponse(LData, AToken, LSvcPort,
                 LTransport, LName) then
              // O IP vem do envelope (origem do datagrama); a porta, da carta.
              AppendUnique(Result,
                PipeIPv4ToString(LIp) + ':' + IntToStr(LSvcPort),
                LName, LTransport);
        uwTimeout:
          ; // hora de reenviar ou de encerrar a janela
      end;
      if Int64(PipeTickMs) - Int64(LNextSend) >= 0 then
      begin
        try
          LChannel.SendTo(ATargetIp, ADiscoveryPort, LProbe);
        except
          on EPipeError do
            ; // reenvio perdido = sonda perdida; a janela segue
        end;
        LNextSend := PipeTickMs + DISC_RESEND_MS;
      end;
    end;
  finally
    LChannel.Free;
  end;
end;

function PipeDiscoverServers(ATimeoutMs: Cardinal; ADiscoveryPort: Word;
  const AToken: string): TArray<TPipeServerInfo>;
begin
  Result := DoDiscover($FFFFFFFF { 255.255.255.255 }, ATimeoutMs,
    ADiscoveryPort, AToken);
end;

function PipeDiscoverServers(const ATargetHost: string; ATimeoutMs: Cardinal;
  ADiscoveryPort: Word; const AToken: string): TArray<TPipeServerInfo>;
var
  LIp: LongWord;
begin
  if not PipeTryStringToIPv4(ATargetHost, LIp) then
    raise EPipeError.CreateFmt('"%s" nao e um literal IPv4; a forma dirigida ' +
      'de PipeDiscoverServers nao resolve nomes de host', [ATargetHost]);
  Result := DoDiscover(LIp, ATimeoutMs, ADiscoveryPort, AToken);
end;

{$IFDEF PIPES_WINDOWS}
initialization
  // Vazia de proposito: o Delphi so aceita 'finalization' com 'initialization'
  // (mesma nota do Pipes.Transport.Tcp). O WSAStartup fica em EnsureWinsock.

finalization
  if GDiscWinsockReady then
    WSACleanup;
{$ENDIF}

end.
