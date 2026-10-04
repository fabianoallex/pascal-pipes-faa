unit Pipes.ThreadingTests;

{ Testes de Pipes.Threading: o despacho por chave (TPipeKeyedDispatcher) e o
  PipeGroupDispatcher global. Versao DUnitX/Delphi; a versao FPCUnit em
  tests/Unit/fpc espelha a mesma cobertura.

  Atomics, monitor e pool foram para a pascal-common-faa e sao testados la
  (PascalCommon.ThreadingTests/ThreadPoolTests). TPipeHeartbeatThread nunca
  teve teste de unidade proprio: e' coberto ponta a ponta por
  tests/Integration/Pipes.HeartbeatTests.

  A finalization desta unit enfileira itens lentos no PipeGroupDispatcher
  para Pipes.FinalizationCheck provar que a liberacao do dispatcher global
  espera as drenagens em voo (ver o cabecalho daquela unit). }

interface

uses
  DUnitX.TestFramework,
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  PascalCommon.Threading,
  PascalCommon.ThreadPool,
  Pipes.Threading;

type
  [TestFixture]
  TPipeThreadingTests = class
  published
    [Test] procedure KeyedDispatcher_MesmaChave_NuncaSobrepoeEPreservaOrdem;
    [Test] procedure KeyedDispatcher_ChavesDiferentes_ExecutamEmParalelo;
    [Test] procedure KeyedDispatcher_ChaveReaproveitadaAposEsvaziar_ComecaDoZero;
    [Test] procedure KeyedDispatcher_ExcecaoEmItem_NaoTravaOsDemaisDaChave;
    [Test] procedure KeyedDispatcher_PoolDestruidoPrimeiro_ExecutaTodosOsPendentes;
    [Test] procedure KeyedDispatcher_DestruidoAntesDoPool_EsperaDrenagemEmVoo;
    [Test] procedure KeyedDispatcher_EnqueueDuranteDestroy_LiberaSemExecutar;
    [Test] procedure GroupDispatcherGlobal_DevolveMesmaInstancia;
  end;

implementation

uses
  Pipes.FinalizationCheck;

type
  { Incrementa um contador compartilhado (com atraso opcional, para acumular
    itens pendentes na mailbox). }
  TCounterWork = class(TPcWorkItem)
  private
    FCounter: PInteger;
    FDelayMs: Integer;
  public
    constructor Create(ACounter: PInteger; ADelayMs: Integer = 0);
    procedure Execute; override;
  end;

  TRaiseWork = class(TPcWorkItem)
  public
    procedure Execute; override;
  end;

  { Prova mutua-exclusao (CAS num flag compartilhado, com Sleep no meio pra
    alargar a janela de uma eventual sobreposicao) e registra a ordem de
    execucao observada. }
  TKeyedProbeWork = class(TPcWorkItem)
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

  { Sinaliza que comecou e fica preso ate AGate abrir: segura a drenagem da
    chave dele (e portanto o Destroy do dispatcher) pelo tempo que o teste
    quiser, sem depender de Sleep. }
  TGateWork = class(TPcWorkItem)
  private
    FGate: TEvent;
    FStarted: PInteger;
  public
    constructor Create(AGate: TEvent; AStarted: PInteger);
    procedure Execute; override;
  end;

  { Registra separadamente "executou" (Execute) e "foi liberado" (destrutor):
    um item liberado sem ter executado foi recusado. }
  TFlagWork = class(TPcWorkItem)
  private
    FRan: PInteger;
    FFreed: PInteger;
  public
    constructor Create(ARan, AFreed: PInteger);
    destructor Destroy; override;
    procedure Execute; override;
  end;

  { Libera o dispatcher em outra thread (Destroy bloqueia enquanto ha'
    drenagem em voo). }
  TDestroyerThread = class(TThread)
  private
    FDispatcher: TPipeKeyedDispatcher;
  protected
    procedure Execute; override;
  public
    constructor Create(ADispatcher: TPipeKeyedDispatcher);
  end;

  { Item da checagem de finalizacao (ver Pipes.FinalizationCheck). }
  TFinalizationProbeWork = class(TPcWorkItem)
  public
    procedure Execute; override;
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
  PcAtomicInc(FCounter^);
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
  if PcAtomicCompareExchange(FBusyFlag^, 1, 0) <> 0 then
    PcAtomicSet(FViolation^, 1); // outra instancia da MESMA chave ja rodando
  try
    Sleep(FDelayMs); // alarga a janela: implementacao quebrada sobreporia aqui
    FLock.Enter;
    try
      FLog.Add(FSeq);
    finally
      FLock.Leave;
    end;
  finally
    PcAtomicSet(FBusyFlag^, 0);
  end;
end;

constructor TGateWork.Create(AGate: TEvent; AStarted: PInteger);
begin
  inherited Create;
  FGate := AGate;
  FStarted := AStarted;
end;

procedure TGateWork.Execute;
begin
  PcAtomicSet(FStarted^, 1);
  FGate.WaitFor(10000); // 10s e' valvula de escape; o teste abre antes
end;

constructor TFlagWork.Create(ARan, AFreed: PInteger);
begin
  inherited Create;
  FRan := ARan;
  FFreed := AFreed;
end;

destructor TFlagWork.Destroy;
begin
  PcAtomicSet(FFreed^, 1);
  inherited;
end;

procedure TFlagWork.Execute;
begin
  PcAtomicSet(FRan^, 1);
end;

constructor TDestroyerThread.Create(ADispatcher: TPipeKeyedDispatcher);
begin
  FDispatcher := ADispatcher;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TDestroyerThread.Execute;
begin
  FDispatcher.Free;
end;

procedure TFinalizationProbeWork.Execute;
begin
  Sleep(20); // a fila da chave leva ~100ms: sem a espera no Destroy, sobraria item
  PcAtomicInc(GFinalizationRan);
end;

// Espera ACounter atingir AExpected (polling); False se estourar o prazo.
function WaitCounter(var ACounter: Integer; AExpected: Integer;
  ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PcTickMs + ATimeoutMs;
  while (PcAtomicGet(ACounter) <> AExpected) and (PcTickMs < LDeadline) do
    Sleep(5);
  Result := PcAtomicGet(ACounter) = AExpected;
end;

// Espera ALog.Count atingir ao menos AExpected (polling sob ALock).
function WaitListCount(ALock: TCriticalSection; AList: TList<Integer>;
  AExpected: Integer; ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
  LCount: Integer;
begin
  LDeadline := PcTickMs + ATimeoutMs;
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
  until PcTickMs >= LDeadline;
  Result := False;
end;

// Espera o dispatcher ficar sem drenagem viva (polling); False se estourar.
function WaitNoActiveDrains(ADispatcher: TPipeKeyedDispatcher;
  ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := PcTickMs + ATimeoutMs;
  while (ADispatcher.ActiveDrains <> 0) and (PcTickMs < LDeadline) do
    Sleep(5);
  Result := ADispatcher.ActiveDrains = 0;
end;

// Comparacao nao-generica (evita E2532: TList<Integer>.Count nao infere T
// igual ao literal no Win64 — mesma armadilha de Length() nas outras units).
procedure EqualInt(AExpected, AActual: Integer; const AMsg: string = '');
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

{ TPipeThreadingTests }

procedure TPipeThreadingTests.KeyedDispatcher_MesmaChave_NuncaSobrepoeEPreservaOrdem;
const
  N = 30;
var
  LPool: TPcThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LLock: TCriticalSection;
  LLog: TList<Integer>;
  LBusy, LViolation: Integer;
  I: Integer;
begin
  LPool := TPcThreadPool.Create(8); // varios workers: so' a chave impede sobreposicao
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  LLock := TCriticalSection.Create;
  LLog := TList<Integer>.Create;
  LBusy := 0;
  LViolation := 0;
  try
    for I := 1 to N do
      LDispatcher.Enqueue(777, TKeyedProbeWork.Create(I, @LBusy, @LViolation,
        LLock, LLog, 3));
    Assert.IsTrue(WaitListCount(LLock, LLog, N, 5000),
      'itens da mesma chave nao terminaram');
    Assert.AreEqual(0, PcAtomicGet(LViolation),
      'duas instancias da mesma chave rodaram ao mesmo tempo');
    LLock.Enter;
    try
      EqualInt(N, LLog.Count);
      for I := 0 to N - 1 do
        Assert.AreEqual(I + 1, LLog[I], 'ordem dentro da chave nao preservada');
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

procedure TPipeThreadingTests.KeyedDispatcher_ChavesDiferentes_ExecutamEmParalelo;
var
  LPool: TPcThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LLock: TCriticalSection;
  LLog: TList<Integer>;
  LBusyA, LBusyB, LViolation: Integer;
  T0: UInt64;
begin
  LPool := TPcThreadPool.Create(8);
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  LLock := TCriticalSection.Create;
  LLog := TList<Integer>.Create;
  LBusyA := 0;
  LBusyB := 0;
  LViolation := 0;
  try
    T0 := PcTickMs;
    LDispatcher.Enqueue(111, TKeyedProbeWork.Create(1, @LBusyA, @LViolation,
      LLock, LLog, 200));
    LDispatcher.Enqueue(222, TKeyedProbeWork.Create(2, @LBusyB, @LViolation,
      LLock, LLog, 200));
    Assert.IsTrue(WaitListCount(LLock, LLog, 2, 3000), 'as duas chaves nao terminaram');
    // Serializado (bug) levaria ~400ms; em paralelo, ~200ms — folga generosa
    // pra nao ficar flaky, mas longe o bastante de 400 pra provar o ponto.
    Assert.IsTrue(PcTickMs - T0 < 350,
      'chaves diferentes nao rodaram em paralelo (parece serializado)');
  finally
    LPool.Free;
    LDispatcher.Free;
    LLog.Free;
    LLock.Free;
  end;
end;

procedure TPipeThreadingTests.KeyedDispatcher_ChaveReaproveitadaAposEsvaziar_ComecaDoZero;
var
  LPool: TPcThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LLock: TCriticalSection;
  LLog: TList<Integer>;
  LBusy, LViolation: Integer;
begin
  LPool := TPcThreadPool.Create(4);
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  LLock := TCriticalSection.Create;
  LLog := TList<Integer>.Create;
  LBusy := 0;
  LViolation := 0;
  try
    LDispatcher.Enqueue(555, TKeyedProbeWork.Create(1, @LBusy, @LViolation,
      LLock, LLog, 5));
    Assert.IsTrue(WaitListCount(LLock, LLog, 1, 3000));
    // A drenagem se desconta so' depois de tirar a chave do dicionario: com
    // ActiveDrains = 0 a mailbox ja' sumiu (sem Sleep-e-torcer).
    Assert.IsTrue(WaitNoActiveDrains(LDispatcher, 3000), 'a mailbox da chave nao esvaziou');
    LDispatcher.Enqueue(555, TKeyedProbeWork.Create(2, @LBusy, @LViolation,
      LLock, LLog, 5));
    Assert.IsTrue(WaitListCount(LLock, LLog, 2, 3000),
      'chave reaproveitada nao processou o item novo');
    Assert.AreEqual(0, PcAtomicGet(LViolation));
    LLock.Enter;
    try
      EqualInt(2, LLog.Count);
      Assert.AreEqual(1, LLog[0]);
      Assert.AreEqual(2, LLog[1]);
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
  LPool: TPcThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LCounter: Integer;
begin
  LCounter := 0;
  LPool := TPcThreadPool.Create(4);
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  try
    LDispatcher.Enqueue(999, TRaiseWork.Create);
    LDispatcher.Enqueue(999, TCounterWork.Create(@LCounter));
    Assert.IsTrue(WaitCounter(LCounter, 1, 3000),
      'item apos excecao na mesma chave nao rodou');
  finally
    LPool.Free;
    LDispatcher.Free;
  end;
end;

procedure TPipeThreadingTests.KeyedDispatcher_PoolDestruidoPrimeiro_ExecutaTodosOsPendentes;
const
  N = 10;
var
  LPool: TPcThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LCounter, I: Integer;
begin
  LCounter := 0;
  LPool := TPcThreadPool.Create(2);
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  try
    for I := 1 to N do
      LDispatcher.Enqueue(333, TCounterWork.Create(@LCounter, 20));
    // TPcThreadPool.Destroy executa a fila inteira antes de juntar os
    // workers — e a drenagem da chave so' termina com a mailbox vazia. Logo,
    // quando Free volta, TODOS os pendentes rodaram (nao "alguns": o pool
    // nunca descartou itens enfileirados, ao contrario do que esta suite
    // dizia antes da pascal-common-faa).
    LPool.Free;
    LPool := nil;
    EqualInt(N, PcAtomicGet(LCounter), 'pool destruido nao executou todos os pendentes');
    EqualInt(0, LDispatcher.ActiveDrains, 'sobrou drenagem viva');
  finally
    LPool.Free;
    LDispatcher.Free;
  end;
end;

procedure TPipeThreadingTests.KeyedDispatcher_DestruidoAntesDoPool_EsperaDrenagemEmVoo;
const
  KEYS = 3;
  PER_KEY = 5;
var
  LPool: TPcThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LCounter, K, I: Integer;
begin
  // A ordem do PipeGroupDispatcher global depois da migracao: ele e'
  // liberado na finalization de Pipes.Threading, com o PcPool ainda vivo.
  LCounter := 0;
  LPool := TPcThreadPool.Create(4);
  LDispatcher := TPipeKeyedDispatcher.Create(LPool);
  try
    for K := 1 to KEYS do
      for I := 1 to PER_KEY do
        LDispatcher.Enqueue(UInt64(K), TCounterWork.Create(@LCounter, 20));
    Assert.IsTrue(LDispatcher.ActiveDrains > 0, 'o teste precisa de drenagem em voo');
    // Sem a espera em Destroy, Free liberaria as mailboxes com itens ainda
    // pendentes (que nunca rodariam) e a drenagem chamaria Fetch num objeto
    // liberado.
    LDispatcher.Free;
    LDispatcher := nil;
    EqualInt(KEYS * PER_KEY, PcAtomicGet(LCounter),
      'Destroy do dispatcher voltou antes de as drenagens terminarem');
  finally
    LDispatcher.Free;
    LPool.Free;
  end;
end;

procedure TPipeThreadingTests.KeyedDispatcher_EnqueueDuranteDestroy_LiberaSemExecutar;
var
  LPool: TPcThreadPool;
  LDispatcher: TPipeKeyedDispatcher;
  LGate: TEvent;
  LDestroyer: TDestroyerThread;
  LStarted, LRan, LFreed: Integer;
  LRejected: Boolean;
  LDeadline: UInt64;
begin
  LStarted := 0;
  LRejected := False;
  LGate := TEvent.Create(nil, True, False, '');
  LPool := TPcThreadPool.Create(4);
  try
    LDispatcher := TPipeKeyedDispatcher.Create(LPool);
    LDispatcher.Enqueue(1, TGateWork.Create(LGate, @LStarted));
    Assert.IsTrue(WaitCounter(LStarted, 1, 3000), 'o item da comporta nao comecou');
    // Destroy fica preso esperando a drenagem da chave 1 (presa na comporta).
    LDestroyer := TDestroyerThread.Create(LDispatcher);
    try
      // Enfileira na chave 2 ate um item ser recusado: antes de o Destroy
      // marcar o desligamento, cada um roda normalmente; depois, e' liberado
      // sem rodar. Cada volta espera o item da anterior ser liberado.
      LDeadline := PcTickMs + 5000;
      repeat
        LRan := 0;
        LFreed := 0;
        LDispatcher.Enqueue(2, TFlagWork.Create(@LRan, @LFreed));
        if not WaitCounter(LFreed, 1, 3000) then
          Break;
        LRejected := PcAtomicGet(LRan) = 0;
      until LRejected or (PcTickMs >= LDeadline);
    finally
      LGate.SetEvent; // libera a drenagem da chave 1, e com ela o Destroy
      LDestroyer.WaitFor;
      LDestroyer.Free;
    end;
    Assert.IsTrue(LRejected, 'Enqueue durante o Destroy executou o item ou nao o liberou');
  finally
    LPool.Free;
    LGate.Free;
  end;
end;

procedure TPipeThreadingTests.GroupDispatcherGlobal_DevolveMesmaInstancia;
begin
  // Criado na initialization de Pipes.Threading: ja existe antes do 1o uso.
  Assert.IsNotNull(PipeGroupDispatcher);
  Assert.AreSame(PipeGroupDispatcher, PipeGroupDispatcher);
end;

const
  FINALIZATION_ITEMS = 5;

procedure QueueFinalizationProbe;
var
  I: Integer;
begin
  // Roda antes da finalization de Pipes.Threading (esta unit a usa): os itens
  // ainda estao na fila da chave quando o PipeGroupDispatcher e' liberado.
  GFinalizationQueued := FINALIZATION_ITEMS;
  for I := 1 to FINALIZATION_ITEMS do
    PipeGroupDispatcher.Enqueue(UInt64($F1A1), TFinalizationProbeWork.Create);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeThreadingTests);

finalization
  QueueFinalizationProbe;

end.
