unit Pipes.Threading;

{$I pipes.inc}

{ Primitivas de concorrencia compartilhadas entre Delphi e Free Pascal
  (copia adaptada de AMQP.Threading.pas do projeto pascal-amqp-faa).

  Este projeto nao usa System.Threading (TTask) nem System.TMonitor porque
  nenhum dos dois existe no FPC. Em vez disso:

  - Atomics: wrappers finos sobre os intrinsics de cada compilador
    (AtomicIncrement/... no Delphi, InterLocked* no FPC). Os de 64 bits
    importam no Win32/Linux-32: um load/store cru de 64 bits pode ser "torn".

  - TPipeMonitor: lock + variavel de condicao (equivalente ao subconjunto de
    System.TMonitor que a lib usava: Enter/Exit/Wait/PulseAll). Implementado
    com o padrao de "evento por geracao": cada PulseAll sinaliza o evento da
    geracao corrente e cria uma nova para os proximos waiters — sem wakeups
    perdidos. Waiters podem acordar espuriamente; o chamador SEMPRE re-checa a
    condicao em loop (todo uso nesta lib deve fazer isso).

  - TPipeThreadPool: pool de threads proprio para despachar callbacks de
    usuario (substitui TTask.Run). Cresce sob demanda ate MaxWorkers; workers
    sao persistentes (nao ha idle-exit). Itens de trabalho sao objetos
    (TPipeWorkItem.Execute) porque method pointers `of object` nao capturam
    variaveis locais como closures capturariam.

  PipePool devolve o pool global (lazy). E' liberado na finalizacao da unit;
  quem despacha para o pool deve drenar seus itens antes de destruir os
  objetos que eles referenciam (padrao DrainInFlight; ver docs/ARQUITETURA.md). }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections;

const
  PIPES_WAIT_INFINITE = Cardinal($FFFFFFFF);

// --- Atomics ---------------------------------------------------------------

/// Incrementa/decrementa atomicamente; devolve o valor NOVO.
function PipeAtomicInc(var ATarget: Integer): Integer;
function PipeAtomicDec(var ATarget: Integer): Integer;
/// Leitura atomica de um Integer compartilhado.
function PipeAtomicGet(var ATarget: Integer): Integer;
/// Troca o valor atomicamente; devolve o valor ANTIGO.
function PipeAtomicSet(var ATarget: Integer; AValue: Integer): Integer;
/// Troca por ANew somente se o valor atual for AComparand; devolve o valor
/// ANTIGO (compare-and-swap classico, para loops de CAS).
function PipeAtomicCompareExchange(var ATarget: Integer; ANew, AComparand: Integer): Integer;
/// Leitura/escrita atomica de 64 bits (ticks de heartbeat).
function PipeAtomicRead64(var ATarget: UInt64): UInt64;
procedure PipeAtomicWrite64(var ATarget: UInt64; AValue: UInt64);

/// Milissegundos monotonicos (GetTickCount64).
function PipeTickMs: UInt64;

// --- Monitor (lock + variavel de condicao) ----------------------------------

type
  { Uma "geracao" de espera: um evento manual-reset compartilhado pelos waiters
    que dormiram antes do mesmo PulseAll. Refs conta o dono (o monitor, se for
    a geracao corrente) + waiters; o ultimo a soltar libera o objeto. }
  TPipeCondGen = class
  public
    Event: TEvent;
    Refs: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TPipeMonitor = class
  private
    FLock: TCriticalSection;
    FGen: TPipeCondGen;
    // Solta uma referencia (chamar segurando FLock).
    procedure ReleaseGen(AGen: TPipeCondGen);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enter;
    procedure Leave;
    /// Solta o lock, espera um PulseAll (ou timeout) e readquire o lock.
    /// Chamar SEGURANDO o lock. Pode acordar espuriamente — re-cheque a
    /// condicao em loop com deadline.
    procedure Wait(ATimeoutMs: Cardinal);
    /// Acorda todos os waiters. Chamar SEGURANDO o lock.
    procedure PulseAll;
  end;

// --- Thread pool -------------------------------------------------------------

type
  { Unidade de trabalho enfileirada no pool. O pool assume a posse: apos
    Execute (com ou sem excecao), o item e' liberado pelo worker. }
  TPipeWorkItem = class
  public
    procedure Execute; virtual; abstract;
  end;

  TPipeThreadPool = class;

  TPipePoolWorker = class(TThread)
  private
    FPool: TPipeThreadPool;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TPipeThreadPool);
  end;

  TPipeThreadPool = class
  private
    FLock: TCriticalSection;
    FWork: TEvent;                       // auto-reset: 1 Set acorda 1 worker
    FQueue: TQueue<TPipeWorkItem>;
    FWorkers: TList<TPipePoolWorker>;
    FIdle: Integer;                      // workers dormindo (sob FLock)
    FMaxWorkers: Integer;
    FShutdown: Boolean;
    /// Loop do worker: devolve False quando o pool esta encerrando.
    function Fetch(out AItem: TPipeWorkItem): Boolean;
  public
    /// AMaxWorkers = 0 usa o padrao: max(16, 4x nucleos). Callbacks de usuario
    /// podem bloquear em IO por segundos (caso de uso alvo), entao o teto e'
    /// generoso; limite o trabalho em voo na camada de cima, se preciso.
    constructor Create(AMaxWorkers: Integer = 0);
    destructor Destroy; override;
    /// Enfileira e garante um worker para atender (cria um, se todos ocupados
    /// e abaixo do teto). Assume a posse do item.
    procedure Queue(AItem: TPipeWorkItem);
  end;

/// Pool global compartilhado (criado sob demanda, liberado na finalizacao).
function PipePool: TPipeThreadPool;

implementation

{ --- Atomics --- }

function PipeAtomicInc(var ATarget: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedIncrement(ATarget);
  {$ELSE}
  Result := AtomicIncrement(ATarget);
  {$ENDIF}
end;

function PipeAtomicDec(var ATarget: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedDecrement(ATarget);
  {$ELSE}
  Result := AtomicDecrement(ATarget);
  {$ENDIF}
end;

function PipeAtomicGet(var ATarget: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(ATarget, 0, 0);
  {$ELSE}
  Result := AtomicCmpExchange(ATarget, 0, 0);
  {$ENDIF}
end;

function PipeAtomicSet(var ATarget: Integer; AValue: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedExchange(ATarget, AValue);
  {$ELSE}
  Result := AtomicExchange(ATarget, AValue);
  {$ENDIF}
end;

function PipeAtomicCompareExchange(var ATarget: Integer; ANew, AComparand: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(ATarget, ANew, AComparand);
  {$ELSE}
  Result := AtomicCmpExchange(ATarget, ANew, AComparand);
  {$ENDIF}
end;

function PipeAtomicRead64(var ATarget: UInt64): UInt64;
begin
  {$IFDEF FPC}
  Result := UInt64(InterlockedCompareExchange64(PInt64(@ATarget)^, 0, 0));
  {$ELSE}
  Result := UInt64(AtomicCmpExchange(PInt64(@ATarget)^, 0, 0));
  {$ENDIF}
end;

procedure PipeAtomicWrite64(var ATarget: UInt64; AValue: UInt64);
begin
  {$IFDEF FPC}
  InterlockedExchange64(PInt64(@ATarget)^, Int64(AValue));
  {$ELSE}
  AtomicExchange(PInt64(@ATarget)^, Int64(AValue));
  {$ENDIF}
end;

function PipeTickMs: UInt64;
begin
  {$IFDEF FPC}
  Result := GetTickCount64;
  {$ELSE}
  Result := TThread.GetTickCount64;
  {$ENDIF}
end;

{ TPipeCondGen }

constructor TPipeCondGen.Create;
begin
  inherited Create;
  Event := TEvent.Create(nil, True, False, ''); // manual-reset
  Refs := 1;
end;

destructor TPipeCondGen.Destroy;
begin
  Event.Free;
  inherited;
end;

{ TPipeMonitor }

constructor TPipeMonitor.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FGen := TPipeCondGen.Create; // Refs=1: a referencia do proprio monitor
end;

destructor TPipeMonitor.Destroy;
begin
  // Assume que nao ha waiters (os usos drenam antes de destruir o canal).
  FGen.Free;
  FLock.Free;
  inherited;
end;

procedure TPipeMonitor.Enter;
begin
  FLock.Enter;
end;

procedure TPipeMonitor.Leave;
begin
  FLock.Leave;
end;

procedure TPipeMonitor.ReleaseGen(AGen: TPipeCondGen);
begin
  Dec(AGen.Refs);
  if AGen.Refs = 0 then
    AGen.Free; // so acontece com geracoes antigas (o monitor segura a corrente)
end;

procedure TPipeMonitor.Wait(ATimeoutMs: Cardinal);
var
  LGen: TPipeCondGen;
begin
  // Captura a geracao corrente ANTES de soltar o lock: um PulseAll que ocorra
  // entre o Leave e o WaitFor sinaliza exatamente este evento (sem wakeup
  // perdido; o evento manual-reset fica sinalizado).
  LGen := FGen;
  Inc(LGen.Refs);
  FLock.Leave;
  try
    LGen.Event.WaitFor(ATimeoutMs);
  finally
    FLock.Enter;
    ReleaseGen(LGen);
  end;
end;

procedure TPipeMonitor.PulseAll;
var
  LOld: TPipeCondGen;
begin
  LOld := FGen;
  LOld.Event.SetEvent;          // acorda quem capturou esta geracao
  FGen := TPipeCondGen.Create;  // proximos waiters dormem na nova
  ReleaseGen(LOld);             // solta a referencia do monitor na antiga
end;

{ TPipePoolWorker }

constructor TPipePoolWorker.Create(APool: TPipeThreadPool);
begin
  FPool := APool;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPipePoolWorker.Execute;
var
  LItem: TPipeWorkItem;
begin
  while FPool.Fetch(LItem) do
  begin
    try
      LItem.Execute;
    except
      // Excecao em callback de usuario nao pode derrubar o worker (mesmo
      // contrato do TTask: a excecao e' engolida).
    end;
    LItem.Free;
  end;
end;

{ TPipeThreadPool }

constructor TPipeThreadPool.Create(AMaxWorkers: Integer);
begin
  inherited Create;
  if AMaxWorkers <= 0 then
  begin
    AMaxWorkers := TThread.ProcessorCount * 4;
    if AMaxWorkers < 16 then
      AMaxWorkers := 16;
  end;
  FMaxWorkers := AMaxWorkers;
  FLock := TCriticalSection.Create;
  FWork := TEvent.Create(nil, False, False, ''); // auto-reset
  FQueue := TQueue<TPipeWorkItem>.Create;
  FWorkers := TList<TPipePoolWorker>.Create;
end;

destructor TPipeThreadPool.Destroy;
var
  LWorker: TPipePoolWorker;
begin
  FLock.Enter;
  try
    FShutdown := True;
  finally
    FLock.Leave;
  end;
  FWork.SetEvent; // cada worker que acorda re-sinaliza (cascata) e encerra
  for LWorker in FWorkers do
  begin
    LWorker.WaitFor;
    LWorker.Free;
  end;
  FWorkers.Free;
  // Itens que ninguem chegou a executar.
  while FQueue.Count > 0 do
    FQueue.Dequeue.Free;
  FQueue.Free;
  FWork.Free;
  FLock.Free;
  inherited;
end;

function TPipeThreadPool.Fetch(out AItem: TPipeWorkItem): Boolean;
begin
  AItem := nil;
  FLock.Enter;
  while True do
  begin
    if FQueue.Count > 0 then
    begin
      AItem := FQueue.Dequeue;
      if FQueue.Count > 0 then
        FWork.SetEvent; // "passa o bastao": ha mais trabalho, acorda outro
      FLock.Leave;
      Exit(True);
    end;
    if FShutdown then
    begin
      FWork.SetEvent;   // cascata: acorda o proximo para ele tambem encerrar
      FLock.Leave;
      Exit(False);
    end;
    Inc(FIdle);
    FLock.Leave;
    FWork.WaitFor(PIPES_WAIT_INFINITE);
    FLock.Enter;
    Dec(FIdle);
  end;
end;

procedure TPipeThreadPool.Queue(AItem: TPipeWorkItem);
begin
  FLock.Enter;
  try
    if FShutdown then
    begin
      AItem.Free;
      Exit;
    end;
    FQueue.Enqueue(AItem);
    if (FIdle = 0) and (FWorkers.Count < FMaxWorkers) then
      FWorkers.Add(TPipePoolWorker.Create(Self)) // atende sem depender do evento
    else
      FWork.SetEvent;
  finally
    FLock.Leave;
  end;
end;

{ --- Pool global --- }

var
  GPoolLock: TCriticalSection;
  GPool: TPipeThreadPool;

function PipePool: TPipeThreadPool;
begin
  if GPool = nil then
  begin
    GPoolLock.Enter;
    try
      if GPool = nil then
        GPool := TPipeThreadPool.Create;
    finally
      GPoolLock.Leave;
    end;
  end;
  Result := GPool;
end;

initialization
  GPoolLock := TCriticalSection.Create;

finalization
  GPool.Free;
  GPoolLock.Free;

end.
