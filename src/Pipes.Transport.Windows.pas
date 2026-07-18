unit Pipes.Transport.Windows;

{$I pipes.inc}

{ Transporte Windows: Named Pipes reais com I/O overlapped.

  Todo IO e' overlapped (FILE_FLAG_OVERLAPPED): nenhuma chamada fica presa no
  kernel de forma nao-cancelavel. Cada espera e' um WaitForMultipleObjects no
  par [evento da operacao, evento de stop]; CloseAbort/Close sinalizam o stop
  e cancelam o IO pendente (CancelIoEx), desbloqueando a thread presa em
  Read/WriteExactly/Accept sem TerminateThread.

  Invariantes (alem do contrato de Pipes.Transport):
  - Os eventos de overlapped (FReadEvent/FWriteEvent) sao reutilizados por
    operacao; isso ASSUME 1 thread lendo e escritas serializadas.
  - FStopEvent e' manual-reset e nunca e' resetado: uma vez abortado, qualquer
    IO futuro no endpoint acorda na hora e levanta EPipeClosed.
  - O handle so e' fechado no destructor (apos o join da reader thread na
    camada de cima) — fechar um handle com a outra thread ainda dentro de um
    ReadFile arriscaria IO num handle reciclado pelo SO.
  - Pipes em modo byte (PIPE_TYPE_BYTE): fronteiras de mensagem sao do
    Pipes.Framing (NPF1), nunca do transporte.

  Seguranca: instancias criadas com o security descriptor padrao (mesmo
  usuario/sessao). Cenarios cross-session (servico <-> app interativo) exigem
  SECURITY_ATTRIBUTES com SDDL — fora do escopo da v1. }

interface

{$IFDEF PIPES_WINDOWS}

uses
  Windows,
  SysUtils,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Transport;

type
  TPipeWinEndpoint = class(TPipeEndpoint)
  private
    FHandle: THandle;
    FReadEvent: THandle;   // manual-reset: OVERLAPPED de leitura
    FWriteEvent: THandle;  // manual-reset: OVERLAPPED de escrita
    FStopEvent: THandle;   // manual-reset: sinalizado por CloseAbort, nunca resetado
    FClosed: Integer;      // atomico: 1 apos CloseAbort
    /// Espera a conclusao do overlapped ou o stop; devolve bytes transferidos.
    function WaitIo(var AOv: TOverlapped; const AOp: string): DWORD;
  public
    /// Assume a posse de AHandle (aberto com FILE_FLAG_OVERLAPPED).
    constructor Create(AHandle: THandle);
    destructor Destroy; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
  end;

  TPipeWinListener = class(TPipeListener)
  private
    FNativeName: string;
    FPending: THandle;      // instancia aguardando ConnectNamedPipe (0 = nenhuma)
    FConnectEvent: THandle; // manual-reset: OVERLAPPED do ConnectNamedPipe
    FStopEvent: THandle;    // manual-reset: sinalizado por Close
    FClosed: Integer;       // atomico
    function CreateInstance: THandle;
  public
    constructor Create(const AAddress: string);
    destructor Destroy; override;
    function Accept: TPipeEndpoint; override;
    procedure Close; override;
  end;

function WinPipeCreateListener(const AAddress: string): TPipeListener;
function WinPipeConnect(const AAddress: string; ATimeoutMs: Cardinal): TPipeEndpoint;

{$ENDIF}

implementation

{$IFDEF PIPES_WINDOWS}

// Declarado localmente: presente no kernel32 desde o Vista, mas nem toda
// versao das units Windows (Delphi/FPC) o expoe.
function CancelIoEx(hFile: THandle; lpOverlapped: POverlapped): BOOL; stdcall;
  external 'kernel32.dll' name 'CancelIoEx';

const
  PIPE_BUFFER_SIZE = 64 * 1024;
  // A unit Windows do FPC 3.2.2 nao declara esta constante do SDK.
  PIPE_UNLIMITED_INSTANCES = 255;

// GetLastError -> excecao da lib. Codigos de "par sumiu/IO abortado" viram
// EPipeClosed (a reader thread trata como fim de conexao); o resto, EPipeError.
procedure RaiseIoErrorCode(const AOp: string; AErr: DWORD);
begin
  case AErr of
    ERROR_BROKEN_PIPE, ERROR_NO_DATA, ERROR_PIPE_NOT_CONNECTED,
    ERROR_OPERATION_ABORTED, ERROR_HANDLE_EOF:
      raise EPipeClosed.CreateFmt('%s: conexao encerrada (erro %d)', [AOp, AErr]);
  else
    raise EPipeError.CreateFmt('%s falhou (erro %d: %s)',
      [AOp, AErr, SysErrorMessage(AErr)]);
  end;
end;

function NewManualResetEvent: THandle;
begin
  Result := CreateEvent(nil, True, False, nil);
  if Result = 0 then
    raise EPipeError.CreateFmt('CreateEvent falhou (erro %d)', [GetLastError]);
end;

{ TPipeWinEndpoint }

constructor TPipeWinEndpoint.Create(AHandle: THandle);
begin
  inherited Create;
  FHandle := AHandle;
  FReadEvent := NewManualResetEvent;
  FWriteEvent := NewManualResetEvent;
  FStopEvent := NewManualResetEvent;
end;

destructor TPipeWinEndpoint.Destroy;
begin
  CloseAbort; // idempotente
  if (FHandle <> 0) and (FHandle <> INVALID_HANDLE_VALUE) then
    CloseHandle(FHandle);
  if FReadEvent <> 0 then
    CloseHandle(FReadEvent);
  if FWriteEvent <> 0 then
    CloseHandle(FWriteEvent);
  if FStopEvent <> 0 then
    CloseHandle(FStopEvent);
  inherited;
end;

procedure TPipeWinEndpoint.CloseAbort;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit; // ja abortado
  SetEvent(FStopEvent);        // acorda esperas atuais e futuras (manual-reset)
  CancelIoEx(FHandle, nil);    // cancela IO pendente emitido por outra thread
end;

function TPipeWinEndpoint.WaitIo(var AOv: TOverlapped; const AOp: string): DWORD;
var
  LHandles: array[0..1] of THandle;
  LWait: DWORD;
  LGot: DWORD;
begin
  LHandles[0] := AOv.hEvent;
  LHandles[1] := FStopEvent;
  LWait := WaitForMultipleObjects(2, @LHandles[0], False, INFINITE);
  if LWait = WAIT_OBJECT_0 + 1 then
  begin
    // CloseAbort: cancela e COLHE o overlapped antes de sair (obrigatorio;
    // liberar a OVERLAPPED com o IO ainda vivo corromperia a pilha).
    CancelIoEx(FHandle, @AOv);
    LGot := 0;
    GetOverlappedResult(FHandle, AOv, LGot, True);
    raise EPipeClosed.Create(AOp + ' abortada (CloseAbort)');
  end;
  LGot := 0;
  if not GetOverlappedResult(FHandle, AOv, LGot, True) then
    RaiseIoErrorCode(AOp, GetLastError);
  Result := LGot;
end;

function TPipeWinEndpoint.Read(var ABuffer; ACount: Integer): Integer;
var
  LOv: TOverlapped;
  LDummy, LGot, LErr: DWORD;
begin
  if PipeAtomicGet(FClosed) <> 0 then
    raise EPipeClosed.Create('leitura em endpoint fechado');
  FillChar(LOv, SizeOf(LOv), 0);
  ResetEvent(FReadEvent);
  LOv.hEvent := FReadEvent;
  LDummy := 0;
  if not ReadFile(FHandle, ABuffer, DWORD(ACount), LDummy, @LOv) then
  begin
    LErr := GetLastError;
    if LErr <> ERROR_IO_PENDING then
      RaiseIoErrorCode('leitura', LErr);
  end;
  LGot := WaitIo(LOv, 'leitura');
  if LGot = 0 then
    raise EPipeClosed.Create('conexao encerrada pelo par');
  Result := Integer(LGot);
end;

procedure TPipeWinEndpoint.WriteExactly(const ABuffer; ACount: Integer);
var
  LOv: TOverlapped;
  LDummy, LWrote, LErr: DWORD;
  P: PByte;
begin
  P := @ABuffer;
  while ACount > 0 do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      raise EPipeClosed.Create('escrita em endpoint fechado');
    FillChar(LOv, SizeOf(LOv), 0);
    ResetEvent(FWriteEvent);
    LOv.hEvent := FWriteEvent;
    LDummy := 0;
    if not WriteFile(FHandle, P^, DWORD(ACount), LDummy, @LOv) then
    begin
      LErr := GetLastError;
      if LErr <> ERROR_IO_PENDING then
        RaiseIoErrorCode('escrita', LErr);
    end;
    LWrote := WaitIo(LOv, 'escrita');
    if LWrote = 0 then
      raise EPipeClosed.Create('conexao encerrada pelo par durante a escrita');
    Inc(P, LWrote);
    Dec(ACount, Integer(LWrote));
  end;
end;

{ TPipeWinListener }

constructor TPipeWinListener.Create(const AAddress: string);
begin
  inherited Create;
  FNativeName := PipeNativeName(AAddress);
  FConnectEvent := NewManualResetEvent;
  FStopEvent := NewManualResetEvent;
  // Primeira instancia criada JA na construcao: um cliente que conecte entre
  // o Listen e o primeiro Accept nao leva ERROR_FILE_NOT_FOUND.
  FPending := CreateInstance;
end;

destructor TPipeWinListener.Destroy;
begin
  Close; // idempotente
  // Assume acceptor thread ja joinada (contrato de Pipes.Transport).
  if (FPending <> 0) and (FPending <> INVALID_HANDLE_VALUE) then
    CloseHandle(FPending);
  if FConnectEvent <> 0 then
    CloseHandle(FConnectEvent);
  if FStopEvent <> 0 then
    CloseHandle(FStopEvent);
  inherited;
end;

function TPipeWinListener.CreateInstance: THandle;
begin
  Result := CreateNamedPipe(PChar(FNativeName),
    PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
    PIPE_UNLIMITED_INSTANCES, PIPE_BUFFER_SIZE, PIPE_BUFFER_SIZE, 0, nil);
  if Result = INVALID_HANDLE_VALUE then
    raise EPipeError.CreateFmt('CreateNamedPipe(%s) falhou (erro %d: %s)',
      [FNativeName, GetLastError, SysErrorMessage(GetLastError)]);
end;

procedure TPipeWinListener.Close;
begin
  if PipeAtomicSet(FClosed, 1) = 1 then
    Exit;
  SetEvent(FStopEvent); // desbloqueia o Accept pendente (que devolve nil)
end;

function TPipeWinListener.Accept: TPipeEndpoint;
var
  LOv: TOverlapped;
  LHandles: array[0..1] of THandle;
  LErr, LWait, LGot: DWORD;
  LConn: THandle;
begin
  Result := nil;
  // Loop: um cliente que conecta e cai antes de completar o handshake recicla
  // a instancia e volta a esperar, sem devolver endpoint morto.
  while True do
  begin
    if PipeAtomicGet(FClosed) <> 0 then
      Exit;
    if FPending = 0 then
      FPending := CreateInstance;
    FillChar(LOv, SizeOf(LOv), 0);
    ResetEvent(FConnectEvent);
    LOv.hEvent := FConnectEvent;
    if ConnectNamedPipe(FPending, @LOv) then
      LErr := ERROR_PIPE_CONNECTED // conectou sincrono (raro, mas valido)
    else
      LErr := GetLastError;
    case LErr of
      ERROR_PIPE_CONNECTED:
        ; // cliente ja conectado entre o CreateInstance e o ConnectNamedPipe
      ERROR_IO_PENDING:
        begin
          LHandles[0] := FConnectEvent;
          LHandles[1] := FStopEvent;
          LWait := WaitForMultipleObjects(2, @LHandles[0], False, INFINITE);
          if LWait = WAIT_OBJECT_0 + 1 then
          begin
            // Close: cancela, colhe o overlapped e devolve nil.
            CancelIoEx(FPending, @LOv);
            LGot := 0;
            GetOverlappedResult(FPending, LOv, LGot, True);
            Exit;
          end;
          LGot := 0;
          if not GetOverlappedResult(FPending, LOv, LGot, True) then
          begin
            CloseHandle(FPending); // cliente caiu no meio: recicla
            FPending := 0;
            Continue;
          end;
        end;
      ERROR_NO_DATA, ERROR_BROKEN_PIPE:
        begin
          CloseHandle(FPending); // conectou e desconectou imediatamente
          FPending := 0;
          Continue;
        end;
    else
      RaiseIoErrorCode('ConnectNamedPipe', LErr);
    end;
    LConn := FPending;
    FPending := 0; // a posse do handle passa para o endpoint
    Exit(TPipeWinEndpoint.Create(LConn));
  end;
end;

{ --- fabricas --- }

function WinPipeCreateListener(const AAddress: string): TPipeListener;
begin
  Result := TPipeWinListener.Create(AAddress);
end;

function WinPipeConnect(const AAddress: string; ATimeoutMs: Cardinal): TPipeEndpoint;
var
  LNative: string;
  LDeadline: UInt64;
  LRemaining: Int64;
  LHandle: THandle;
  LErr: DWORD;
  LWaitMs: DWORD;
begin
  LNative := PipeNativeName(AAddress);
  LDeadline := PipeTickMs + ATimeoutMs;
  while True do
  begin
    LHandle := CreateFile(PChar(LNative), GENERIC_READ or GENERIC_WRITE,
      0, nil, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, 0);
    if LHandle <> INVALID_HANDLE_VALUE then
      Exit(TPipeWinEndpoint.Create(LHandle));
    LErr := GetLastError;
    // BUSY = todas as instancias ocupadas (janela entre um accept e o proximo
    // CreateInstance); NOT_FOUND = servidor ainda nao subiu. Ambos re-tentam
    // ate o prazo — e' o que da semantica uniforme de Connect(timeout) nas
    // duas plataformas.
    if (LErr <> ERROR_PIPE_BUSY) and (LErr <> ERROR_FILE_NOT_FOUND) then
      raise EPipeError.CreateFmt('conexao ao pipe %s falhou (erro %d: %s)',
        [LNative, LErr, SysErrorMessage(LErr)]);
    LRemaining := Int64(LDeadline) - Int64(PipeTickMs);
    if LRemaining <= 0 then
      raise EPipeTimeout.CreateFmt('timeout (%u ms) conectando ao pipe %s',
        [ATimeoutMs, LNative]);
    if LRemaining > 100 then
      LWaitMs := 100
    else
      LWaitMs := DWORD(LRemaining);
    if LErr = ERROR_PIPE_BUSY then
      WaitNamedPipe(PChar(LNative), LWaitMs) // espera uma instancia vagar
    else
      Sleep(25); // servidor ausente: polling curto
  end;
end;

{$ENDIF}

end.
