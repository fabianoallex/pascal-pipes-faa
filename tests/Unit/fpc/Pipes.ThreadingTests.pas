unit Pipes.ThreadingTests;

{$mode delphi}{$H+}

{ Testes de fumaca de Pipes.Threading: atomics, monitor (lock + variavel de
  condicao) e thread pool. Versao FPCUnit; espelha a cobertura da versao
  DUnitX em tests/Unit/Pipes.ThreadingTests.pas. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  Pipes.Threading;

type
  TPipeThreadingTests = class(TTestCase)
  published
    procedure Atomic_IncDec_DevolvemValorNovo;
    procedure Atomic_SetDevolveAntigo_CasSoTrocaSeIgual;
    procedure Atomic_RoundTrip64;
    procedure Atomic_CompareExchange64_TrocaSoSeIgual;
    procedure Atomic_Add64_ConcorrenteSomaCorreta;
    procedure TickMs_NaoRetrocede;
    procedure Monitor_WaitComTimeout_RetornaAposPrazo;
    procedure Monitor_PulseAll_AcordaWaiterAntesDoTimeout;
    procedure Pool_ExecutaTodosOsItens;
    procedure Pool_ExcecaoEmItemNaoDerrubaWorker;
    procedure Pool_DestroyComItensPendentes_NaoTrava;
    procedure PoolGlobal_DevolveMesmaInstancia;
    procedure KeyedDispatcher_MesmaChave_NuncaSobrepoeEPreservaOrdem;
    procedure KeyedDispatcher_ChavesDiferentes_ExecutamEmParalelo;
    procedure KeyedDispatcher_ChaveReaproveitadaAposEsvaziar_ComecaDoZero;
    procedure KeyedDispatcher_ExcecaoEmItem_NaoTravaOsDemaisDaChave;
    procedure KeyedDispatcher_DestroyComItensPendentes_NaoTrava;
    procedure GroupDispatcherGlobal_DevolveMesmaInstancia;
  end;

implementation

type
  { Incrementa um contador compartilhado (com atraso opcional, para encher a
    fila do pool nos testes de shutdown). }
  TCounterWork = class(TPipeWorkItem)
  private
    FCounter: PInteger;
    FDelayMs: Integer;
  public
    constructor Create(ACounter: PInteger; ADelayMs: Integer = 0);
    procedure Execute; override;
  end;

  TRaiseWork = class(TPipeWorkItem)
  public
    procedure Execute; override;
  end;

  { Prova mutua-exclusao (CAS num flag compartilhado, com Sleep no meio pra
    alargar a janela de uma eventual sobreposicao) e registra a ordem de
    execucao observada — usado pelos testes de TPipeKeyedDispatcher. }
  TKeyedProbeWork = class(TPipeWorkItem)
  private
    FSeq: Integer;
    FBusyFlag: PInteger; // 0 = livre, 1 = ocupado (CAS)
    FViolation: PInteger; // vira 1 se duas instancias da MESMA chave se sobrepoem
    FLock: TCriticalSection;
    FLog: TList<Integer>;
    FDelayMs: Integer;
  public
    constructor Create(ASeq: Integer; ABusyFlag, AViolation: PInteger;
      ALock: TCriticalSection; ALog: TList<Integer>; ADelayMs: Integer = 5);
    procedure Execute; override;
  end;

  { Soma AAmount ao contador compartilhado, ATimes vezes, via PipeAtomicAdd64
    — usado para provar que o CAS loop nao perde incrementos sob concorrencia
    real (um teste sequencial nao pegaria um loop de CAS mal escrito). }
  TAdderThread = class(TThread)
  private
    FTarget: PUInt64;
    FTimes: Integer;
    FAmount: UInt64;
  protected
    procedure Execute; override;
  public
    constructor Create(ATarget: PUInt64; ATimes: Integer; AAmount: UInt64);
  end;

  { Entra no monitor, sinaliza que vai dormir e espera um PulseAll. }
  TMonitorWaiter = class(TThread)
  private
    FMon: TPipeMonitor;
    FInWait: PInteger;
    FAwake: PInteger;
  protected
    procedure Execute; override;
  public
    constructor Create(AMon: TPipeMonitor; AInWait, AAwake: PInteger);
  end;

constructor TCounterWork.Create(ACounter: PInteger; ADelayMs: Integer);
begin
  inherited Create;
  FCounter := ACounter;
  FDelayMs := ADelayMs;
end;

procedure TCounterWork.Execute;
begin
  if FDelayMs > 0 then
    Sleep(FDelayMs);
  PipeAtomicInc(FCounter^);
end;

procedure TRaiseWork.Execute;
begin
  raise Exception.Create('excecao proposital do teste');
end;

constructor TKeyedProbeWork.Create(ASeq: Integer; ABusyFlag, AViolation: PInteger;
  ALock: TCriticalSection; ALog: TList<Integer>; ADelayMs: Integer);
begin
  inherited Create;
  FSeq := ASeq;
  FBusyFlag := ABusyFlag;
  FViolation := AViolation;
  FLock := ALock;
  FLog := ALog;
  FDelayMs := ADelayMs;
end;

procedure TKeyedProbeWork.Execute;
begin
  if PipeAtomicCompareExchange(FBusyFlag^, 1, 0) <> 0 then
    PipeAtomicSet(FViolation^, 1); // outra instancia da MESMA chave ja rodando
  try
    Sleep(FDelayMs); // alarga a janela: implementacao quebrada sobreporia aqui
    FLock.Enter;
    try
      FLog.Add(FSeq);
    finally
      FLock.Leave;
    end;
  finally
    PipeAtomicSet(FBusyFlag^, 0);
  end;
end;

constructor TAdderThread.Create(ATarget: PUInt64; ATimes: Integer;
  AAmount: UInt64);
begin
  FTarget := ATarget;
  FTimes := ATimes;
  FAmount := AAmount;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TAdderThread.Execute;
var
  I: Integer;
begin
  for I := 1 to FTimes do
    PipeAtomicAdd64(FTarget^, FAmount);
end;

constructor TMonitorWaiter.Create(AMon: TPipeMonitor; AInWait, AAwake: PInteger);
begin
  FMon := AMon;
  FInWait := AInWait;
  FAwake := AAwake;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TMonitorWaiter.Execute;
begin
  FMon.Enter;
  PipeAtomicSet(FInWait^, 1);
  FMon.Wait(10000); // acordado pelo PulseAll do teste; 10s e' valvula de escape
  FMon.Leave;
  PipeAtomicSet(FAwake^, 1);
end;

// Espera ACounter atingir AExpected (polling); False se estourar o prazo.
function WaitCounter(var ACounter: Integer; AExpected: Integer;
  ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  while (PipeAtomicGet(ACounter) <> AExpected) and (PipeTickMs < LDeadline) do
    Sleep(5);
  Result := PipeAtomicGet(ACounter) = AExpected;
end;

// Espera ALog.Count atingir ao menos AExpected (polling sob ALock).
function WaitListCount(ALock: TCriticalSection; AList: TList<Integer>;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
  LCount: Integer;
begin
  LDeadline := PipeTickMs + ATimeoutMs;
  repeat
    ALock.Enter;
    try
      LCount := AList.Count;
    finally
      ALock.Leave;
    end;
    if LCount >= AExpected then
      Exit(True);
    Sleep(5);
  until PipeTickMs >= LDeadline;
  Result := False;
end;

{ TPipeThreadingTests }

procedure TPipeThreadingTests.Atomic_IncDec_DevolvemValorNovo;
var
  V: Integer;
begin
  V := 0;
  AssertEquals(1, PipeAtomicInc(V));
  AssertEquals(2, PipeAtomicInc(V));
  AssertEquals(1, PipeAtomicDec(V));
  AssertEquals(1, PipeAtomicGet(V));
end;

procedure TPipeThreadingTests.Atomic_SetDevolveAntigo_CasSoTrocaSeIgual;
var
  V: Integer;
begin
  V := 5;
  AssertEquals(5, PipeAtomicSet(V, 9));
  AssertEquals(9, PipeAtomicGet(V));
  AssertEquals(9, PipeAtomicCompareExchange(V, 20, 9));   // comparand bate: troca
  AssertEquals(20, PipeAtomicGet(V));
  AssertEquals(20, PipeAtomicCompareExchange(V, 30, 99)); // nao bate: mantem
  AssertEquals(20, PipeAtomicGet(V));
end;

procedure TPipeThreadingTests.Atomic_RoundTrip64;
var
  W: UInt64;
begin
  W := 0;
  PipeAtomicWrite64(W, UInt64($0123456789ABCDEF));
  AssertTrue('roundtrip de 64 bits corrompeu o valor',
    PipeAtomicRead64(W) = UInt64($0123456789ABCDEF));
end;

procedure TPipeThreadingTests.Atomic_CompareExchange64_TrocaSoSeIgual;
var
  W: UInt64;
begin
  W := 100;
  AssertTrue('comparand bateu: devia trocar',
    PipeAtomicCompareExchange64(W, 200, 100) = 100); // devolve o valor ANTIGO
  AssertTrue(W = 200);
  AssertTrue('comparand nao bateu: devia manter',
    PipeAtomicCompareExchange64(W, 300, 999) = 200);
  AssertTrue('valor nao devia ter mudado', W = 200);
end;

procedure TPipeThreadingTests.Atomic_Add64_ConcorrenteSomaCorreta;
const
  NUM_THREADS = 8;
  TIMES_PER_THREAD = 1000;
var
  LCounter: UInt64;
  LThreads: array[0..NUM_THREADS - 1] of TAdderThread;
  I: Integer;
begin
  LCounter := 0;
  for I := 0 to NUM_THREADS - 1 do
    LThreads[I] := TAdderThread.Create(@LCounter, TIMES_PER_THREAD, 1);
  for I := 0 to NUM_THREADS - 1 do
    LThreads[I].WaitFor;
  for I := 0 to NUM_THREADS - 1 do
    LThreads[I].Free;
  AssertTrue('CAS loop perdeu incrementos sob concorrencia',
    LCounter = UInt64(NUM_THREADS * TIMES_PER_THREAD));
end;

procedure TPipeThreadingTests.TickMs_NaoRetrocede;
var
  T1, T2: UInt64;
begin
  T1 := PipeTickMs;
  Sleep(20);
  T2 := PipeTickMs;
  AssertTrue('tick monotonico retrocedeu', T2 >= T1);
  AssertTrue(T2 > 0);
end;

procedure TPipeThreadingTests.Monitor_WaitComTimeout_RetornaAposPrazo;
var
  LMon: TPipeMonitor;
  T0: UInt64;
begin
  LMon := TPipeMonitor.Create;
  try
    LMon.Enter;
    T0 := PipeTickMs;
    LMon.Wait(200);
    LMon.Leave;
    AssertTrue('Wait retornou antes do timeout', PipeTickMs - T0 >= 150);
  finally
    LMon.Free;
  end;
end;

procedure TPipeThreadingTests.Monitor_PulseAll_AcordaWaiterAntesDoTimeout;
var
  LMon: TPipeMonitor;
  LWaiter: TMonitorWaiter;
  LInWait, LAwake: Integer;
  T0: UInt64;
begin
  LInWait := 0;
  LAwake := 0;
  LMon := TPipeMonitor.Create;
  try
    LWaiter := TMonitorWaiter.Create(LMon, @LInWait, @LAwake);
    try
      AssertTrue('waiter nao chegou ao Wait', WaitCounter(LInWait, 1, 2000));
      // O Enter abaixo so retorna depois de o waiter capturar a geracao e
      // soltar o lock (dentro do Wait) - logo o PulseAll acorda exatamente ele.
      LMon.Enter;
      T0 := PipeTickMs;
      LMon.PulseAll;
      LMon.Leave;
      AssertTrue('PulseAll nao acordou o waiter', WaitCounter(LAwake, 1, 3000));
      AssertTrue('waiter so acordou pelo timeout', PipeTickMs - T0 < 5000);
    finally
      LWaiter.WaitFor;
      LWaiter.Free;
    end;
  finally
    LMon.Free;
  end;
end;

procedure TPipeThreadingTests.Pool_ExecutaTodosOsItens;
var
  LPool: TPipeThreadPool;
  LCounter, I: Integer;
begin
  LCounter := 0;
  LPool := TPipeThreadPool.Create(4);
  try
    for I := 1 to 50 do
      LPool.Queue(TCounterWork.Create(@LCounter));
    AssertTrue('pool nao executou os 50 itens', WaitCounter(LCounter, 50, 5000));
  finally
    LPool.Free;
  end;
end;

procedure TPipeThreadingTests.Pool_ExcecaoEmItemNaoDerrubaWorker;
var
  LPool: TPipeThreadPool;
  LCounter: Integer;
begin
  LCounter := 0;
  // 1 worker: o item seguinte prova que o MESMO worker sobreviveu a excecao.
  LPool := TPipeThreadPool.Create(1);
  try
    LPool.Queue(TRaiseWork.Create);
    LPool.Queue(TCounterWork.Create(@LCounter));
    AssertTrue('worker morreu apos excecao', WaitCounter(LCounter, 1, 5000));
  finally
    LPool.Free;
  end;
end;

procedure TPipeThreadingTests.Pool_DestroyComItensPendentes_NaoTrava;
var
  LPool: TPipeThreadPool;
  LCounter, I: Integer;
begin
  LCounter := 0;
  LPool := TPipeThreadPool.Create(2);
  for I := 1 to 20 do
    LPool.Queue(TCounterWork.Create(@LCounter, 30)); // 30ms cada: fila acumula
  // Destroy deve concluir os itens em execucao, descartar os pendentes e
  // retornar - se travar, o teste trava (detector de deadlock do runner/CI).
  LPool.Free;
  AssertTrue(PipeAtomicGet(LCounter) <= 20);
end;

procedure TPipeThreadingTests.PoolGlobal_DevolveMesmaInstancia;
begin
  AssertNotNull(PipePool);
  AssertTrue('PipePool deve devolver sempre a mesma instancia',
    PipePool = PipePool);
end;

procedure TPipeThreadingTests.KeyedDispatcher_MesmaChave_NuncaSobrepoeEPreservaOrdem;
const
  N = 30;
var
  LPool: TPipeThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LLock: TCriticalSection;
  LLog: TList<Integer>;
  LBusy, LViolation: Integer;
  I: Integer;
begin
  LPool := TPipeThreadPool.Create(8); // varios workers: so' a chave impede sobreposicao
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  LLock := TCriticalSection.Create;
  LLog := TList<Integer>.Create;
  LBusy := 0;
  LViolation := 0;
  try
    for I := 1 to N do
      LDispatcher.Enqueue(777, TKeyedProbeWork.Create(I, @LBusy, @LViolation,
        LLock, LLog, 3));
    AssertTrue('itens da mesma chave nao terminaram',
      WaitListCount(LLock, LLog, N, 5000));
    AssertEquals('duas instancias da mesma chave rodaram ao mesmo tempo',
      0, PipeAtomicGet(LViolation));
    LLock.Enter;
    try
      AssertEquals(N, LLog.Count);
      for I := 0 to N - 1 do
        AssertEquals('ordem dentro da chave nao preservada', I + 1, LLog[I]);
    finally
      LLock.Leave;
    end;
  finally
    // Ordem obrigatoria: o pool primeiro (drena qualquer TPipeMailboxDrainWork
    // em voo), so' depois o dispatcher (ver o cabecalho de TPipeKeyedDispatcher).
    LPool.Free;
    LDispatcher.Free;
    LLog.Free;
    LLock.Free;
  end;
end;

procedure TPipeThreadingTests.KeyedDispatcher_ChavesDiferentes_ExecutamEmParalelo;
var
  LPool: TPipeThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LLock: TCriticalSection;
  LLog: TList<Integer>;
  LBusyA, LBusyB, LViolation: Integer;
  T0: UInt64;
begin
  LPool := TPipeThreadPool.Create(8);
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  LLock := TCriticalSection.Create;
  LLog := TList<Integer>.Create;
  LBusyA := 0;
  LBusyB := 0;
  LViolation := 0;
  try
    T0 := PipeTickMs;
    LDispatcher.Enqueue(111, TKeyedProbeWork.Create(1, @LBusyA, @LViolation,
      LLock, LLog, 200));
    LDispatcher.Enqueue(222, TKeyedProbeWork.Create(2, @LBusyB, @LViolation,
      LLock, LLog, 200));
    AssertTrue('as duas chaves nao terminaram', WaitListCount(LLock, LLog, 2, 3000));
    // Serializado (bug) levaria ~400ms; em paralelo, ~200ms — folga generosa
    // pra nao ficar flaky, mas longe o bastante de 400 pra provar o ponto.
    AssertTrue('chaves diferentes nao rodaram em paralelo (parece serializado)',
      PipeTickMs - T0 < 350);
  finally
    LPool.Free;
    LDispatcher.Free;
    LLog.Free;
    LLock.Free;
  end;
end;

procedure TPipeThreadingTests.KeyedDispatcher_ChaveReaproveitadaAposEsvaziar_ComecaDoZero;
var
  LPool: TPipeThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LLock: TCriticalSection;
  LLog: TList<Integer>;
  LBusy, LViolation: Integer;
begin
  LPool := TPipeThreadPool.Create(4);
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  LLock := TCriticalSection.Create;
  LLog := TList<Integer>.Create;
  LBusy := 0;
  LViolation := 0;
  try
    LDispatcher.Enqueue(555, TKeyedProbeWork.Create(1, @LBusy, @LViolation,
      LLock, LLog, 5));
    AssertTrue(WaitListCount(LLock, LLog, 1, 3000));
    Sleep(50); // garante que a mailbox ja esvaziou e a chave saiu do dicionario
    LDispatcher.Enqueue(555, TKeyedProbeWork.Create(2, @LBusy, @LViolation,
      LLock, LLog, 5));
    AssertTrue('chave reaproveitada nao processou o item novo',
      WaitListCount(LLock, LLog, 2, 3000));
    AssertEquals(0, PipeAtomicGet(LViolation));
    LLock.Enter;
    try
      AssertEquals(2, LLog.Count);
      AssertEquals(1, LLog[0]);
      AssertEquals(2, LLog[1]);
    finally
      LLock.Leave;
    end;
  finally
    LPool.Free;
    LDispatcher.Free;
    LLog.Free;
    LLock.Free;
  end;
end;

procedure TPipeThreadingTests.KeyedDispatcher_ExcecaoEmItem_NaoTravaOsDemaisDaChave;
var
  LPool: TPipeThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LCounter: Integer;
begin
  LCounter := 0;
  LPool := TPipeThreadPool.Create(4);
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  try
    LDispatcher.Enqueue(999, TRaiseWork.Create);
    LDispatcher.Enqueue(999, TCounterWork.Create(@LCounter));
    AssertTrue('item apos excecao na mesma chave nao rodou',
      WaitCounter(LCounter, 1, 3000));
  finally
    LPool.Free;
    LDispatcher.Free;
  end;
end;

procedure TPipeThreadingTests.KeyedDispatcher_DestroyComItensPendentes_NaoTrava;
var
  LPool: TPipeThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LLock: TCriticalSection;
  LLog: TList<Integer>;
  LBusy, LViolation: Integer;
  I: Integer;
begin
  LLock := TCriticalSection.Create;
  LLog := TList<Integer>.Create;
  LBusy := 0;
  LViolation := 0;
  LPool := TPipeThreadPool.Create(2);
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  try
    for I := 1 to 10 do
      LDispatcher.Enqueue(333, TKeyedProbeWork.Create(I, @LBusy, @LViolation,
        LLock, LLog, 20));
    // LPool.Free tem de concluir (junta os workers, drenando a mailbox em
    // voo) sem travar - mesmo detector de deadlock de
    // Pool_DestroyComItensPendentes_NaoTrava, so' que atras' de uma chave.
    LPool.Free;
    LDispatcher.Free;
  finally
    LLog.Free;
    LLock.Free;
  end;
end;

procedure TPipeThreadingTests.GroupDispatcherGlobal_DevolveMesmaInstancia;
begin
  AssertNotNull(PipeGroupDispatcher);
  AssertTrue('PipeGroupDispatcher deve devolver sempre a mesma instancia',
    PipeGroupDispatcher = PipeGroupDispatcher);
end;

initialization
  RegisterTest(TPipeThreadingTests);

end.
