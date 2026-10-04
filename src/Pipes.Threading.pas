unit Pipes.Threading;

{$I pipes.inc}

{ Concorrencia propria do pipes, por cima da pascal-common-faa: o despacho
  por chave (TPipeKeyedDispatcher, com o global PipeGroupDispatcher) e a
  thread de heartbeat (TPipeHeartbeatThread).

  Atomics, PcTickMs, monitor, pool e o pool global vieram da copia de
  AMQP.Threading que esta unit carregava e agora sao da pascal-common-faa
  (PascalCommon.Threading e PascalCommon.ThreadPool; mapa de nomes em
  external/pascal-common-faa/docs/migrating.md). Sem alias: quem usava
  PipeAtomic*/TPipeThreadPool/PipePool passa a usar PcAtomic*/TPcThreadPool/
  PcPool direto.

  PcPool e' de TODO o processo, nao so' do pipes: outras libs *-faa (amqp,
  redis) despacham no mesmo pool. Em pdmPool, os callbacks do pipes disputam
  os workers com os delas, e TPcThreadPool.QueueDepth conta os itens de
  todas (ver TPipeServerStats.PoolQueueDepth).

  Esta unit e' a que todo consumidor do pipes compila com a pascal-common-faa
  (Base, Transport, Discovery usam-na), por isso a checagem da versao minima
  fica aqui, logo depois do uses que traz PascalCommon.Version.

  Finalizacao: as units sao finalizadas na ordem inversa da inicializacao, e
  esta usa PascalCommon.ThreadPool, entao roda ANTES da finalizacao dela —
  PcPool ainda existe e ainda executa trabalho quando o PipeGroupDispatcher e'
  liberado aqui. Por isso TPipeKeyedDispatcher.Destroy espera as drenagens
  em voo terminarem antes de liberar o que elas tocam (ver o cabecalho da
  classe). Antes da migracao o pool era desta unit e era liberado primeiro;
  agora a ordem se inverteu e a espera e' o que mantem a liberacao segura. }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  PascalCommon.Version,
  PascalCommon.ThreadPool;

{$IF PASCALCOMMON_VERSION < 10000}
  {$MESSAGE FATAL 'pascal-named-pipes-faa precisa da pascal-common-faa 1.0.0 ou mais nova'}
{$IFEND}

// --- Despacho por chave (ordem preservada por chave, paralelo entre chaves) -

type
  TPipeKeyedDispatcher = class;

  { Work item que drena a mailbox de UMA chave ate esvaziar, um item por vez,
    e so' entao libera a chave (ver TPipeKeyedDispatcher). Roda como qualquer
    outro TPcWorkItem no pool que o dispatcher usa como motor.

    Vive do Enqueue que o cria ate o Free do pool: o Destroy desconta a
    drenagem em FActiveDrains do dispatcher, e e' a ULTIMA coisa que toca o
    dispatcher — rode ou seja descartado pelo pool (Queue depois do Destroy
    do pool libera o item sem executar), o desconto acontece. }
  TPipeMailboxDrainWork = class(TPcWorkItem)
  private
    FDispatcher: TPipeKeyedDispatcher;
    FKey: UInt64;
  public
    constructor Create(ADispatcher: TPipeKeyedDispatcher; AKey: UInt64);
    destructor Destroy; override;
    procedure Execute; override;
  end;

  { Roteamento por chave sobre um TPcThreadPool: itens da MESMA chave nunca
    executam ao mesmo tempo (ordem preservada, FIFO por chave); chaves
    diferentes correm em paralelo no MESMO pool. Mailbox por ator, dono
    cooperativo — nao ha' worker fixo por chave, nem teto de chaves para
    configurar; o paralelismo se autorregula pelo numero de chaves com
    trabalho pendente, ate o teto de workers que o pool ja tem.

    A entrada de uma chave no dicionario e' EFEMERA: nasce no primeiro Enqueue
    daquela chave, morre quando a mailbox esvazia (Fetch devolve False). Uma
    chave reaproveitada depois de esvaziar comeca do zero, sem estado
    residual — quem usa nao precisa "gerenciar" chaves, so' escolher qual usar
    por envio.

    Concorrencia: "esvaziou, libero a chave" (Fetch) e "esta ocupada? so'
    anexo, ou crio e disparo drenagem" (Enqueue) sao a MESMA secao critica
    (FLock) dos dois lados — sem isso existe uma corrida classica de mailbox:
    um item novo podendo chegar exatamente no instante em que o drenador
    desiste ficaria orfao, sem ninguem para consumi-lo.

    Ciclo de vida: o dispatcher NAO E' DONO do pool (so' referencia, ver
    Create), e as duas ordens de destruicao sao seguras:
    - pool primeiro: TPcThreadPool.Destroy executa a fila inteira e junta os
      workers, entao toda drenagem ja terminou quando o dispatcher e'
      liberado;
    - dispatcher primeiro (a do PipeGroupDispatcher, cujo pool e' o PcPool,
      liberado depois desta unit): Destroy recusa Enqueue novo (o item e'
      liberado sem executar, mesmo contrato de TPcThreadPool.Queue depois do
      Destroy), espera FActiveDrains zerar — cada drenagem ja enfileirada
      ou em execucao termina a mailbox dela — e so' entao libera FMailboxes
      e FLock.
    A espera e' por polling de um contador atomico, nao por evento: o
    decremento e' o ultimo acesso da drenagem ao dispatcher, entao nao sobra
    um SetEvent/Leave sobre um objeto que quem espera ja pode ter liberado.
    Nao chame Destroy de dentro de um item despachado por este mesmo
    dispatcher: ele esperaria a propria drenagem. }
  TPipeKeyedDispatcher = class
  private
    FLock: TCriticalSection;
    FMailboxes: TDictionary<UInt64, TQueue<TPcWorkItem>>;
    FPool: TPcThreadPool;
    FShutdown: Boolean;       // sob FLock
    FActiveDrains: Integer;   // atomico: TPipeMailboxDrainWork vivos
    // Chamado SO' pelo TPipeMailboxDrainWork da propria chave.
    function Fetch(AKey: UInt64; out AItem: TPcWorkItem): Boolean;
  public
    /// APool nao e' possuido por este objeto (ver ciclo de vida no cabecalho
    /// da classe) — normalmente PcPool (o global).
    constructor Create(APool: TPcThreadPool);
    /// Espera as drenagens em voo terminarem (cada uma esvazia a mailbox
    /// dela) e libera o que sobrou. Ver o ciclo de vida no cabecalho.
    destructor Destroy; override;
    /// Enfileira; assume a posse do item. Se a chave nao esta sendo drenada
    /// agora, dispara UM TPipeMailboxDrainWork no pool para drena-la. Depois
    /// que Destroy comecou, libera o item sem executar.
    procedure Enqueue(AKey: UInt64; AItem: TPcWorkItem);
    /// Drenagens vivas (enfileiradas no pool ou executando). Para testes e
    /// diagnostico; o valor ja pode ter mudado quando volta.
    function ActiveDrains: Integer;
  end;

/// Dispatcher de chave global sobre PcPool, criado na initialization desta
/// unit (nunca sob demanda: double-checked locking sem barreira e' inseguro
/// em CPU de ordenacao fraca, como ARM — Android e Linux ARM64 sao alvos) e
/// liberado na finalization, enquanto PcPool ainda roda. Mesma natureza
/// compartilhada de pdmPool: chaves de componentes diferentes coexistem no
/// mesmo dicionario (colisao de hash e' so' um hotspot raro e inofensivo,
/// nunca incorretude — ver PipeGroupKeyHash em Pipes.Framing).
function PipeGroupDispatcher: TPipeKeyedDispatcher;

// --- Heartbeat de aplicacao (ptTcp/ptTls; ver Pipes.Base.HeartbeatIntervalMs) -

type
  /// Chamado a cada acordar do TPipeHeartbeatThread. Sem parametros e sem
  /// closures (reference to e' proibido nesta lib): o metodo capturado le os
  /// dados do dono em campos proprios (TPipeServerConnection/TPipeClient).
  TPipeHeartbeatTick = procedure of object;

  { Thread generica de heartbeat, reaproveitada por TPipeServerConnection e
    TPipeClient: acorda periodicamente por uma espera interrompivel (NAO
    TTimer, mesmo padrao de TAMQPHeartbeatThread no pascal-amqp-faa) e chama
    AOnTick. O dono decide o que fazer no tick (mandar Ping se ocioso na
    escrita, CloseAbort se ocioso na leitura ha' tempo demais).

    AStopEvent e' do DONO (criado e liberado por ele, nao por esta thread):
    a parada segue o mesmo par Terminate + SetEvent + WaitFor de qualquer
    outra thread desta lib (reader, acceptor etc.). }
  TPipeHeartbeatThread = class(TThread)
  private
    FStopEvent: TEvent;
    FIntervalMs: Cardinal;
    FOnTick: TPipeHeartbeatTick;
  protected
    procedure Execute; override;
  public
    constructor Create(AIntervalMs: Cardinal; AStopEvent: TEvent;
      AOnTick: TPipeHeartbeatTick);
  end;

implementation

uses
  PascalCommon.Threading;

{ TPipeHeartbeatThread }

constructor TPipeHeartbeatThread.Create(AIntervalMs: Cardinal;
  AStopEvent: TEvent; AOnTick: TPipeHeartbeatTick);
begin
  FIntervalMs := AIntervalMs;
  FStopEvent := AStopEvent;
  FOnTick := AOnTick;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPipeHeartbeatThread.Execute;
var
  LWaitMs: Cardinal;
begin
  // Acorda a cada metade do intervalo (minimo 1s); FOnTick decide sozinho,
  // a cada acordar, se e' hora de mandar Ping ou de declarar a conexao morta.
  LWaitMs := FIntervalMs div 2;
  if LWaitMs < 1000 then
    LWaitMs := 1000;
  while not Terminated do
  begin
    if FStopEvent.WaitFor(LWaitMs) = wrSignaled then
      Break; // parada solicitada
    if Terminated then
      Break;
    FOnTick;
  end;
end;

{ TPipeMailboxDrainWork }

constructor TPipeMailboxDrainWork.Create(ADispatcher: TPipeKeyedDispatcher;
  AKey: UInt64);
begin
  inherited Create;
  FDispatcher := ADispatcher;
  FKey := AKey;
end;

destructor TPipeMailboxDrainWork.Destroy;
begin
  // Ultimo acesso ao dispatcher (ver o cabecalho da classe): depois disto
  // TPipeKeyedDispatcher.Destroy pode liberar tudo.
  PcAtomicDec(FDispatcher.FActiveDrains);
  inherited;
end;

procedure TPipeMailboxDrainWork.Execute;
var
  LItem: TPcWorkItem;
begin
  while FDispatcher.Fetch(FKey, LItem) do
  begin
    try
      LItem.Execute;
    except
      // Mesma regra do worker do pool (TPcThreadPool): excecao de usuario
      // nao pode derrubar quem drena as demais mensagens da chave.
    end;
    LItem.Free;
  end;
end;

{ TPipeKeyedDispatcher }

constructor TPipeKeyedDispatcher.Create(APool: TPcThreadPool);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMailboxes := TDictionary<UInt64, TQueue<TPcWorkItem>>.Create;
  FPool := APool;
end;

destructor TPipeKeyedDispatcher.Destroy;
var
  LQueue: TQueue<TPcWorkItem>;
begin
  FLock.Enter;
  try
    FShutdown := True; // daqui em diante nenhuma drenagem nova nasce
  finally
    FLock.Leave;
  end;
  // Cada drenagem viva esvazia a mailbox dela e so' entao se desconta.
  while PcAtomicGet(FActiveDrains) > 0 do
    Sleep(1);
  // So' sobra mailbox se o pool descartou a drenagem dela sem executar (pool
  // ja destruido quando o Enqueue foi feito).
  for LQueue in FMailboxes.Values do
  begin
    while LQueue.Count > 0 do
      LQueue.Dequeue.Free;
    LQueue.Free;
  end;
  FMailboxes.Free;
  FLock.Free;
  inherited;
end;

function TPipeKeyedDispatcher.ActiveDrains: Integer;
begin
  Result := PcAtomicGet(FActiveDrains);
end;

function TPipeKeyedDispatcher.Fetch(AKey: UInt64;
  out AItem: TPcWorkItem): Boolean;
var
  LQueue: TQueue<TPcWorkItem>;
begin
  AItem := nil;
  FLock.Enter;
  try
    if not FMailboxes.TryGetValue(AKey, LQueue) then
      Exit(False); // nao deveria acontecer: so' o proprio drenador chama Fetch
    if LQueue.Count = 0 then
    begin
      FMailboxes.Remove(AKey); // efemera: sem estado residual pra proxima vez
      LQueue.Free;
      Exit(False);
    end;
    AItem := LQueue.Dequeue;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TPipeKeyedDispatcher.Enqueue(AKey: UInt64; AItem: TPcWorkItem);
var
  LQueue: TQueue<TPcWorkItem>;
  LMustSpawn: Boolean;
begin
  FLock.Enter;
  try
    if FShutdown then
    begin
      AItem.Free; // Destroy em curso: mesmo contrato de TPcThreadPool.Queue
      Exit;
    end;
    if FMailboxes.TryGetValue(AKey, LQueue) then
    begin
      LQueue.Enqueue(AItem); // ja' tem quem drena: ele vai ver este item
      LMustSpawn := False;
    end
    else
    begin
      LQueue := TQueue<TPcWorkItem>.Create;
      LQueue.Enqueue(AItem);
      FMailboxes.Add(AKey, LQueue);
      // Contado ainda sob FLock: um Destroy que ja viu FShutdown = False
      // aqui vai ver esta drenagem no contador.
      PcAtomicInc(FActiveDrains);
      LMustSpawn := True;
    end;
  finally
    FLock.Leave;
  end;
  if LMustSpawn then
    FPool.Queue(TPipeMailboxDrainWork.Create(Self, AKey));
end;

{ --- Dispatcher de chave global --- }

var
  GGroupDispatcher: TPipeKeyedDispatcher;

function PipeGroupDispatcher: TPipeKeyedDispatcher;
begin
  Result := GGroupDispatcher;
end;

initialization
  // Criado aqui, numa thread so', nunca sob demanda (ver PipeGroupDispatcher).
  // PcPool ja existe: PascalCommon.ThreadPool e' inicializada antes desta.
  GGroupDispatcher := TPipeKeyedDispatcher.Create(PcPool);

finalization
  // Roda ANTES da finalizacao de PascalCommon.ThreadPool, com PcPool vivo:
  // Destroy espera as drenagens em voo (ver o cabecalho desta unit).
  FreeAndNil(GGroupDispatcher);

end.
