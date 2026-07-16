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
  Pipes.Threading;

type
  TPipeThreadingTests = class(TTestCase)
  published
    procedure Atomic_IncDec_DevolvemValorNovo;
    procedure Atomic_SetDevolveAntigo_CasSoTrocaSeIgual;
    procedure Atomic_RoundTrip64;
    procedure TickMs_NaoRetrocede;
    procedure Monitor_WaitComTimeout_RetornaAposPrazo;
    procedure Monitor_PulseAll_AcordaWaiterAntesDoTimeout;
    procedure Pool_ExecutaTodosOsItens;
    procedure Pool_ExcecaoEmItemNaoDerrubaWorker;
    procedure Pool_DestroyComItensPendentes_NaoTrava;
    procedure PoolGlobal_DevolveMesmaInstancia;
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

initialization
  RegisterTest(TPipeThreadingTests);

end.
