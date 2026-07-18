# Arquitetura — Biblioteca Multiplataforma de Named Pipes (v1)

Relatório da proposta arquitetural aprovada em 2026-07-16. O resumo operacional (restrições
e invariantes) vive em `../CLAUDE.md`; este documento guarda o racional completo.

## 1. Objetivo e escopo

Biblioteca de IPC local de alto nível para Delphi 12+ (Win64) e FPC 3.2.2/Lazarus
(Linux x86_64/ARM64), com codebase única. O desenvolvedor final trabalha só com
`TPipeServer`/`TPipeClient`, eventos `of object` e `TBytes`/strings UTF-8 —
nenhuma chamada de SO exposta.

Modelo de concorrência derivado do projeto `pascal-amqp-faa` (comprovado em produção):
thread de leitura dedicada que nunca executa código do usuário + thread pool próprio para
despacho de callbacks + drenagem de callbacks em voo antes de liberar objetos.

## 2. Decisões arquiteturais e racional

### 2.1 Linux: Unix Domain Sockets, não FIFOs

Named Pipes do Windows têm semântica de **conexão**: N clientes simultâneos, cada um com um
canal bidirecional próprio, com notificação de desconexão. FIFOs (`mkfifo`) não têm nada
disso: são um fluxo de bytes único, unidirecional na prática, sem noção de "cliente" e sem
detecção de queda. Emular conexões sobre FIFOs exigiria protocolo de handshake (FIFO de
controle + par de FIFOs por cliente), heartbeat para detectar morte de cliente e limpeza de
FIFOs órfãos — complexidade alta para benefício nulo no caso de uso alvo.

O equivalente semântico real é o **Unix Domain Socket** (`AF_UNIX`, `SOCK_STREAM`) — o que
Docker, PostgreSQL e systemd usam como "pipe nomeado" no Linux. Com UDS, `Broadcast`,
`Request-Reply` e `OnClientConnected/Disconnected` funcionam identicamente nos dois OS.

FIFOs ficam fora do escopo v1. A camada `Pipes.Transport.pas` é abstrata justamente para que
um `TPipeTransportFifo` (ex.: interoperar com scripts shell) possa ser adicionado depois sem
tocar na API pública.

### 2.2 Framing próprio, uniforme nos dois OS

UDS é byte stream; Named Pipe em modo mensagem (`PIPE_READMODE_MESSAGE`) preserva fronteiras,
mas só no Windows, com peculiaridades (`ERROR_MORE_DATA`, limites de buffer). Para ter UMA
semântica de mensagem nos dois OS, o pipe do Windows roda em **modo byte** e a biblioteca
implementa o próprio length-prefix framing (§4). Bônus: mensagens maiores que o buffer do
pipe funcionam naturalmente, e a validação de `MaxMessageSize` protege contra frames
corrompidos/maliciosos.

### 2.3 Threading: cópia renomeada de AMQP.Threading.pas

`AMQP.Threading.pas` fornece exatamente o que precisamos, já dual-compiler:

- **Atomics portáveis** (`InterLocked*` no FPC / `Atomic*` no Delphi), incluindo 64 bits
  (loads crus de 64 bits podem ser "torn" em alvos 32 bits).
- **TAMQPMonitor**: lock + variável de condição com "evento por geração" (sem wakeups
  perdidos) — substitui `System.TMonitor`, inexistente no FPC.
- **TAMQPThreadPool**: pool com workers persistentes, crescimento sob demanda até
  `MaxWorkers`, itens de trabalho como objetos (`TAMQPWorkItem.Execute`) com posse
  transferida ao pool — substitui `TTask.Run`, inexistente no FPC. Exceção em callback de
  usuário é engolida pelo worker (mesmo contrato do TTask).

Decisão: **copiar a unit** para `src/Pipes.Threading.pas` renomeando prefixos
(`TPipeThreadPool`, `TPipeMonitor`, `TPipeWorkItem`, `PipeAtomic*`, `PipePool`). Zero
acoplamento entre repositórios; cada lib é distribuível standalone. Extração para uma lib
compartilhada fica como refactor futuro se um terceiro projeto precisar.

### 2.4 Compatibilidade dual-compiler

- `src/pipes.inc` (molde: `amqp.inc`): no FPC ativa `{$MODE DELPHI}{$H+}`; define
  `PIPES_WINDOWS` (MSWINDOWS ou WINDOWS) e `PIPES_POSIX`.
- Proibições: `reference to`, `System.Threading`, `System.TMonitor`, RTTI estendida,
  inline vars — nada fora do subconjunto que o FPC 3.2.2 compila em modo Delphi.
- Work items carregam dados em campos e decrementam `FInFlight` no `finally` do `Execute`
  (padrão `TAMQPDeliveryWork` de `AMQP.Connection.pas`).

## 3. API pública (esqueleto)

```pascal
type
  TPipeConnectionId = UInt64;  // 0 = inválido; servidor gera sequencial atômico

  TPipeMessageEvent    = procedure(Sender: TObject; AConnId: TPipeConnectionId;
                                   const AData: TBytes) of object;
  TPipeRequestEvent    = procedure(Sender: TObject; AConnId: TPipeConnectionId;
                                   const ARequest: TBytes; out AReply: TBytes) of object;
  TPipeConnectionEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId) of object;
  TPipeErrorEvent      = procedure(Sender: TObject; AConnId: TPipeConnectionId;
                                   const AError: string) of object;

  // Onde os eventos do usuário executam:
  //  pdmPool       — pool de threads (padrão; paralelismo entre conexões)
  //  pdmSerialized — pool dedicado de 1 worker (ordem FIFO global garantida)
  //  pdmMainThread — TThread.Queue p/ a main thread (VCL/LCL sem Synchronize manual)
  TPipeDispatchMode = (pdmPool, pdmSerialized, pdmMainThread);

  EPipeError   = class(Exception);
  EPipeTimeout = class(EPipeError);
  EPipeClosed  = class(EPipeError);

  TPipeBase = class abstract
  public
    property Address: string;          // 'meu_app' → Win: \\.\pipe\meu_app
                                        //             Linux: /tmp/meu_app.pipe (configurável)
    property Active: Boolean;           // read-only
    property DispatchMode: TPipeDispatchMode;
    property MaxMessageSize: Cardinal;  // padrão 16 MB; frame maior = erro de protocolo
    property OnMessage: TPipeMessageEvent;
    property OnError: TPipeErrorEvent;
  end;

  TPipeServer = class(TPipeBase)
  public
    procedure Listen;                   // não-blocante: sobe a thread acceptor
    procedure Stop;                     // síncrono e idempotente: join de todas as threads
    procedure SendBytes(AConnId: TPipeConnectionId; const AData: TBytes);
    procedure SendText (AConnId: TPipeConnectionId; const AText: string);   // UTF-8
    procedure Broadcast(const AData: TBytes);
    procedure BroadcastText(const AText: string);
    procedure DisconnectClient(AConnId: TPipeConnectionId);
    function  ClientCount: Integer;
    function  ClientIds: TArray<TPipeConnectionId>;
    property  MaxClients: Integer;      // 0 = ilimitado
    property  OnClientConnected: TPipeConnectionEvent;
    property  OnClientDisconnected: TPipeConnectionEvent;
    property  OnRequest: TPipeRequestEvent;  // retorno do handler vira frame reply
  end;

  TPipeClient = class(TPipeBase)
  public
    procedure Connect(ATimeoutMs: Cardinal = 5000);
    procedure Disconnect;               // síncrono e idempotente
    procedure SendBytes(const AData: TBytes);   // fire-and-forget
    procedure SendText (const AText: string);
    // Request-Reply síncrono: bloqueia o CHAMADOR (nunca a thread de leitura)
    function  Request    (const AData: TBytes; ATimeoutMs: Cardinal = 30000): TBytes;
    function  RequestText(const AText: string; ATimeoutMs: Cardinal = 30000): string;
    property  Connected: Boolean;
    property  AutoReconnect: Boolean;
    property  ReconnectDelayMs: Cardinal;
    property  OnConnected: TPipeConnectionEvent;
    property  OnDisconnected: TPipeConnectionEvent;
  end;
```

`Broadcast` tira um snapshot da lista de conexões sob o lock da lista e envia FORA do lock
(write lock individual de cada conexão) — um cliente lento não trava a lista.

## 4. Wire format

```
Header (20 bytes, little-endian):
  Magic    : 4 bytes  'NPF1'   (sincronia + versão de protocolo)
  Kind     : 1 byte   0=msg  1=request  2=reply  3=ping (reservado)
  Flags    : 1 byte   reservado (0)
  Reserved : 2 bytes  (0)
  CorrId   : 8 bytes  correlation id (request/reply; 0 em msg)
  Length   : 4 bytes  tamanho do payload (validado contra MaxMessageSize)
Payload    : Length bytes (TBytes cru; texto = UTF-8)
```

**Request-Reply** (mesmo padrão do RPC de `AMQP.Connection`):

```
Cliente                                    Servidor
Request():                                 reader: lê frame request
  corrId := PipeAtomicInc(FCorrSeq)          despacha TPipeRequestWork ao pool
  registra slot {corrId → TEvent}          worker: chama OnRequest(..., out Reply)
  envia frame(request, corrId)               envia frame(reply, corrId) [write lock,
  slot.Event.WaitFor(timeout)                 guarda de refcount da conexão]
reader: lê frame(reply, corrId)
  preenche slot.Bytes; SetEvent  ────────►  Request() retorna os bytes
timeout → remove slot, EPipeTimeout        (reply tardio de slot removido é descartado)
```

## 5. Ciclo de vida das threads

```
SERVIDOR                                   CLIENTE
┌─ Acceptor thread ───────────────┐        ┌─ Reader thread ─────────────┐
│ aceita conexão                  │        │ lê frame → decodifica →     │
│ registra TPipeServerConnection  │        │ despacha work item          │
│ sobe Reader thread da conexão   │        └─────────────────────────────┘
└─────────────────────────────────┘        ┌─ Reconnect thread (efêmera, │
┌─ Reader thread (1 por conexão) ─┐        │  FreeOnTerminate) ──────────┘
│ lê frame → decodifica →         │
│ despacha work item              │        ┌─ TPipeThreadPool ───────────┐
└─────────────────────────────────┘        │ executa OnMessage/OnRequest/│
                                           │ OnConnected... do usuário   │
                                           └─────────────────────────────┘
```

Regras:
1. Reader nunca executa código do usuário e nunca escreve exceto via write lock.
2. Um write lock (`TCriticalSection`) por conexão serializa todas as escritas (reply de
   worker, SendBytes de qualquer thread, Broadcast).
3. Ordem de locks "de fora pra dentro": lock da lista de conexões → write lock da conexão.
   Nunca adquirir o lock da lista segurando um write lock.
4. `FInFlight` (atômico) conta callbacks em voo por conexão; `DrainInFlight` (loop
   `Sleep(10)` até zerar) roda antes de liberar a conexão — evita use-after-free.
   Consequência documentada: não chamar `Stop`/`Disconnect` de dentro de um callback da
   própria conexão (auto-espera).

### 5.1 Interrupção da leitura blocante — Windows

Todos os handles com `FILE_FLAG_OVERLAPPED`; nenhuma chamada síncrona blocante.

- **Leitura**: `ReadFile` overlapped → `WaitForMultipleObjects([hIoEvent, hStopEvent])`.
  Se `hStopEvent`: `CancelIoEx(hPipe)` → `GetOverlappedResult` (colhe o cancelamento,
  obrigatório antes de liberar a OVERLAPPED) → sai do loop.
- **Accept**: `ConnectNamedPipe` overlapped com a mesma técnica. O acceptor cria a próxima
  instância (`CreateNamedPipe` com `PIPE_UNLIMITED_INSTANCES`, `PIPE_TYPE_BYTE`) a cada
  cliente aceito; no `Stop`, a instância pendente é fechada.
- **Sequência de Stop por conexão**: `SetEvent(hStop)` → `CancelIoEx` → `CloseHandle` →
  `Thread.WaitFor` → `FreeAndNil`.
- Desconexão de cliente detectada por `ERROR_BROKEN_PIPE`/`ERROR_PIPE_NOT_CONNECTED` no
  read → dispara `OnClientDisconnected` via pool.

### 5.2 Interrupção da leitura blocante — Linux

- **fd de parada**: self-pipe (`fppipe`) por objeto servidor/cliente. (eventfd é otimização
  futura; self-pipe é idêntico em x86_64 e ARM64 e não precisa de binding extra.)
- **Leitura**: `fpPoll([fdConn, fdStop])`; retornou por `fdStop` → sai. `POLLHUP`/read 0 =
  desconexão do par.
- **Accept**: `fpPoll([fdListen, fdStop])` + `fpAccept`.
- **Sequência de Stop**: escreve 1 byte no self-pipe → `fpShutdown(fd, SHUT_RDWR)` (acorda
  read residual) → `fpClose` → `Thread.WaitFor`.
- **SIGPIPE**: todas as escritas com `MSG_NOSIGNAL` (via `fpSend`) — cliente que morreu não
  pode derrubar o servidor.
- **Socket path**: `fpUnlink` antes do `fpBind` (remove socket órfão de crash anterior) e
  no `Stop`.

### 5.3 Encerramento sem congelar a UI

- `Stop`/`Disconnect`/destructor: sinalizar todos → join de todos → `DrainInFlight` →
  liberar. Nunca `TerminateThread`/`KillThread`. Destructor idempotente chama Stop.
- `pdmMainThread` usa `TThread.Queue` (assíncrono). **Nunca** `Synchronize` a partir do
  reader: main thread esperando `Stop` + reader esperando `Synchronize` = deadlock.
- Como um `Queue` pendente pode disparar após o destroy do componente, callbacks
  `pdmMainThread` passam por um objeto-guarda refcounted que o destructor invalida; o item
  enfileirado checa a guarda antes de invocar o evento do usuário.

## 6. Estrutura de units

| Unit | Conteúdo |
|------|----------|
| `src/pipes.inc` | diretivas duais (molde `amqp.inc`) |
| `src/Pipes.Threading.pas` | cópia renomeada de `AMQP.Threading.pas` |
| `src/Pipes.Types.pas` | `TPipeConnectionId`, eventos, exceções, `TPipeDispatchMode` |
| `src/Pipes.Framing.pas` | encode/decode do frame, helpers UTF-8 |
| `src/Pipes.Transport.pas` | `TPipeEndpoint`/`TPipeListener` abstratos (Read/Write/Accept interrompíveis + CloseAbort) |
| `src/Pipes.Transport.Windows.pas` | Named Pipe overlapped (`{$IFDEF PIPES_WINDOWS}`) |
| `src/Pipes.Transport.Posix.pas` | UDS + fpPoll + self-pipe (`{$IFDEF PIPES_POSIX}`) |
| `src/Pipes.Server.pas` | `TPipeServer` + acceptor + conexões |
| `src/Pipes.Client.pas` | `TPipeClient` + reconexão |
| `tests/Unit`, `tests/Integration` | DUnit (Delphi) + fpcunit (FPC), layout espelhado do pascal-amqp-faa |
| `samples/` | echo console; chat VCL/LCL |

## 7. Milestones

| # | Milestone | Conteúdo | Agente recomendado |
|---|-----------|----------|--------------------|
| M0 | Bootstrap | git init, pastas, `pipes.inc`, `.gitignore`, projetos de teste compilando vazios | haiku |
| M1 | Threading | cópia/rename de `AMQP.Threading.pas` + testes de fumaça (pool, monitor, atomics) | haiku + revisão sonnet |
| M2 | Framing | `Pipes.Types` + `Pipes.Framing` + testes unitários (roundtrip, magic inválido, oversize, UTF-8) | sonnet |
| M3 | Transporte Windows | `Pipes.Transport` abstrato + implementação overlapped completa | opus |
| M4 | Transporte Linux | UDS, fpPoll, self-pipe, MSG_NOSIGNAL, unlink | opus |
| M5 | Alto nível | Server/Client, acceptor, readers, dispatch, DrainInFlight, Stop/Disconnect | opus + revisão fable |
| M6 | Avançados | Request-Reply, Broadcast, AutoReconnect, pdmMainThread + guarda | sonnet + revisão opus |
| M7 | Integração | echo, N clientes concorrentes, queda abrupta, stress de Stop sob tráfego — dois OS | sonnet |
| M8 | Samples/docs | echo console + chat VCL/LCL + README | haiku |

Dependências: `M0 → M1 → M2 → (M3 ‖ M4) → M5 → M6 → M7 → M8`. Desenvolvimento começa no
Windows (máquina atual); M4 e a metade Linux do M7 validam via FPC em CI ou máquina alvo.

**Critérios de aceite transversais**: cada milestone fecha compilando em dcc64 E fpc, com
testes verdes nos dois. M7 exige: `Stop` sob tráfego intenso conclui em < 2 s (detector de
deadlock) e queda abrupta de cliente (kill -9) dispara `OnClientDisconnected` sem vazar
handle/fd.

## 8. Padrões de referência no pascal-amqp-faa

| Padrão | Onde |
|--------|------|
| Include dual-compiler | `src/amqp.inc` |
| Atomics/monitor/pool | `src/AMQP.Threading.pas` |
| Cabeçalho de invariantes de lock | `src/AMQP.Connection.pas:5-32` |
| Reader que nunca roda código de usuário | `TAMQPReaderThread.Execute` |
| Parada de reader (Terminate + fechar transporte + WaitFor) | `TAMQPConnection.StopReadThread` |
| Drenagem de callbacks em voo | `TAMQPChannel.DrainInFlight` |
| Work item com dados em campos + dec no finally | `TAMQPDeliveryWork` |
| Thread efêmera de reconexão | `TAMQPReconnectThread` |
| Pool dedicado de 1 worker (ordem FIFO) | `TAMQPChannel.FDispatchPool` |
