unit Pipes.Transport;

{$I pipes.inc}

{ Camada de transporte abstrata: o contrato que os backends por plataforma
  (Pipes.Transport.Windows = Named Pipe overlapped; Pipes.Transport.Posix =
  Unix Domain Socket, milestone M4) implementam.

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
    /// Le ate ACount bytes (bloqueia ate haver pelo menos 1); devolve quantos
    /// leu (1..ACount). EPipeClosed se o par encerrou ou CloseAbort foi chamado.
    function Read(var ABuffer; ACount: Integer): Integer; virtual; abstract;
    /// Escreve exatamente ACount bytes (bloqueia ate concluir).
    procedure WriteExactly(const ABuffer; ACount: Integer); virtual; abstract;
    /// Aborta IO pendente e marca o endpoint como fechado. Thread-safe e
    /// idempotente; chamavel de qualquer thread. O handle/fd e' liberado de
    /// fato no destructor (apos o join da reader thread).
    procedure CloseAbort; virtual; abstract;
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

// --- Fabricas por plataforma -------------------------------------------------

/// Cria o ponto de escuta do servidor para o endereco dado (ja deixa a primeira
/// instancia/socket pronta: um cliente pode conectar antes do primeiro Accept).
function PipeCreateListener(const AAddress: string;
  ATransport: TPipeTransport = ptLocal;
  AKeepAliveSeconds: Cardinal = 0): TPipeListener;

/// Conecta ao servidor, re-tentando ate ATimeoutMs (cobre servidor ainda nao
/// iniciado e instancias momentaneamente ocupadas). EPipeTimeout no prazo.
function PipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  ATransport: TPipeTransport = ptLocal;
  AKeepAliveSeconds: Cardinal = 0): TPipeEndpoint;

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
  Pipes.Transport.Tcp,
{$IFDEF PIPES_WINDOWS}
  Pipes.Transport.Windows;
{$ELSE}
  Pipes.Transport.Posix;
{$ENDIF}

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

function PipeNativeName(const AAddress: string): string;
begin
  if AAddress = '' then
    raise EPipeError.Create('nome do pipe vazio');
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
  case ATransport of
    ptLocal:
      ; // qualquer nome/caminho serve; PipeNativeName resolve
    ptTcp:
      begin
        if (Pos('\\', AAddress) = 1) or (AAddress[1] = '/') then
          raise EPipeError.CreateFmt(
            'Address "%s" e um caminho local, incompativel com ptTcp ' +
            '(esperado "host:porta")', [AAddress]);
        PipeParseHostPort(AAddress, LHost, LPort); // valida o formato
      end;
  end;
end;

function PipeCreateListener(const AAddress: string;
  ATransport: TPipeTransport; AKeepAliveSeconds: Cardinal): TPipeListener;
begin
  PipeValidateAddress(AAddress, ATransport);
  if ATransport = ptTcp then
    Exit(TcpPipeCreateListener(AAddress, AKeepAliveSeconds));
  {$IFDEF PIPES_WINDOWS}
  Result := WinPipeCreateListener(AAddress);
  {$ELSE}
  Result := PosixPipeCreateListener(AAddress);
  {$ENDIF}
end;

function PipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  ATransport: TPipeTransport; AKeepAliveSeconds: Cardinal): TPipeEndpoint;
begin
  PipeValidateAddress(AAddress, ATransport);
  if ATransport = ptTcp then
    Exit(TcpPipeConnect(AAddress, ATimeoutMs, AKeepAliveSeconds));
  {$IFDEF PIPES_WINDOWS}
  Result := WinPipeConnect(AAddress, ATimeoutMs);
  {$ELSE}
  Result := PosixPipeConnect(AAddress, ATimeoutMs);
  {$ENDIF}
end;

end.
