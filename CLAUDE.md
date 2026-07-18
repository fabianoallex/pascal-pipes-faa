# pascal-named-pipes-faa

Biblioteca multiplataforma de Named Pipes (IPC local) para **Delphi 12+ (Win64)** e
**FPC 3.2.2 / Lazarus (Linux x86_64 e ARM64)**. API de alto nível que abstrai totalmente as
chamadas nativas do SO. Arquitetura completa em `docs/ARQUITETURA.md` — leia antes de
implementar qualquer milestone.

## Decisões arquiteturais (fechadas — não rediscutir sem o usuário)

- **Backend Windows:** Named Pipes reais (`CreateNamedPipe`/`ConnectNamedPipe`), modo byte
  (`PIPE_TYPE_BYTE`), sempre com `FILE_FLAG_OVERLAPPED`. Nunca I/O síncrono blocante.
- **Backend Linux:** Unix Domain Sockets (`AF_UNIX`) — equivalente semântico do Named Pipe
  do Windows. FIFOs (`mkfifo`) estão FORA do escopo v1 (a camada `Pipes.Transport.pas`
  abstrata deixa a porta aberta para um backend FIFO futuro).
- **Framing próprio** (length-prefix, header de 20 bytes com magic `NPF1`, kind, corrId,
  length) idêntico nos dois OS. Não depender de `PIPE_READMODE_MESSAGE`.
- **Threading:** cópia renomeada de `AMQP.Threading.pas` (do projeto
  `..\pascal-amqp-faa\src\`) como `Pipes.Threading.pas` — prefixos `TPipe*`/`Pipe*`.
  Sem dependência entre repositórios.

## Restrições obrigatórias de código (compat dual Delphi/FPC)

- Toda unit começa com `{$I pipes.inc}` (no FPC ativa `{$MODE DELPHI}{$H+}`; define
  `PIPES_WINDOWS`/`PIPES_POSIX` — molde: `..\pascal-amqp-faa\src\amqp.inc`).
- **PROIBIDO:** métodos anônimos (`reference to`), `System.Threading` (TTask),
  `System.TMonitor`, atributos/RTTI estendida, inline vars. Nada que não compile no
  FPC 3.2.2 em modo Delphi.
- Callbacks/eventos: sempre `procedure ... of object`.
- Work items do pool carregam dados capturados em **campos** (padrão `TAMQPDeliveryWork`
  em `AMQP.Connection.pas`), nunca closures.
- API pública trafega `TBytes`; texto convertido internamente como UTF-8
  (`TEncoding.UTF8.GetBytes/GetString`).
- Cada unit com concorrência documenta suas invariantes de lock no cabeçalho (molde:
  `AMQP.Connection.pas:5-32`).

## Invariantes de threading (violar = deadlock/use-after-free)

1. A thread de leitura NUNCA executa código do usuário — só lê frame, decodifica e
   despacha `TPipeWorkItem` ao pool.
2. Escritas serializadas por write lock (`TCriticalSection`) por conexão. Ordem de locks
   "de fora pra dentro": lista de conexões → write lock; nunca o inverso.
3. Contador atômico `FInFlight` por conexão + `DrainInFlight` antes de liberar qualquer
   objeto referenciado por callbacks em voo.
4. Interrupção de leitura blocante:
   - Windows: `ReadFile`/`ConnectNamedPipe` overlapped + `WaitForMultipleObjects([hIo,
     hStop])`; Stop = `SetEvent(hStop)` → `CancelIoEx` → fechar handle → `WaitFor` da thread.
   - Linux: `fpPoll([fd, fdStopSelfPipe])`; Stop = escrever no self-pipe → `fpShutdown` →
     `fpClose` → `WaitFor`. Escrever sempre com `MSG_NOSIGNAL` (SIGPIPE mata o processo).
5. Encerramento: sinalizar todos → join de todos → drenar in-flight → liberar. Nunca
   `TerminateThread`. Destructor idempotente chama Stop/Disconnect.
6. `pdmMainThread` usa `TThread.Queue` (nunca `Synchronize` a partir do reader) com
   objeto-guarda refcounted invalidado no destroy.

## API pública (resumo)

`TPipeBase` (abstrata: Address, Active, DispatchMode, MaxMessageSize, OnMessage,
OnError) → `TPipeServer` (Listen, Stop, SendBytes/SendText por ConnId, Broadcast,
DisconnectClient, OnClientConnected/Disconnected, OnRequest) e `TPipeClient`
(Connect, Disconnect, SendBytes/SendText, Request/RequestText síncrono com timeout,
AutoReconnect, OnConnected/OnDisconnected). Assinaturas completas em `docs/ARQUITETURA.md`.

`TPipeDispatchMode`: `pdmPool` (padrão), `pdmSerialized` (pool de 1 worker, ordem FIFO),
`pdmMainThread` (TThread.Queue — apps VCL/LCL).

## Estrutura de units

```
src/pipes.inc                    src/Pipes.Threading.pas   src/Pipes.Types.pas
src/Pipes.Framing.pas            src/Pipes.Transport.pas
src/Pipes.Transport.Windows.pas  src/Pipes.Transport.Posix.pas
src/Pipes.Client.pas             src/Pipes.Server.pas
tests/Unit + tests/Integration (DUnit e fpcunit, layout espelhado do pascal-amqp-faa)
samples/  docs/ARQUITETURA.md
Pipes.groupproj (grupo Delphi) + Pipes.lpg (grupo Lazarus) na raiz
```

Todo `.dproj`/`.lpi` novo (teste, sample) deve ser registrado nos DOIS grupos da
raiz: `Pipes.groupproj` (Projects + Targets + CallTarget de Build/Clean/Make) e
`Pipes.lpg` (Target com BuildModes), como no pascal-amqp-faa.

## Milestones e agente recomendado (economia de tokens)

| # | Milestone | Agente |
|---|-----------|--------|
| M0 | Bootstrap (git, pastas, pipes.inc, projetos de teste compilando) | haiku |
| M1 | Pipes.Threading.pas (cópia/rename) + testes de fumaça | haiku + revisão sonnet |
| M2 | Pipes.Types + Pipes.Framing + testes unitários | sonnet |
| M3 | Transporte Windows (overlapped, CancelIoEx, multi-instância) | opus |
| M4 | Transporte Linux (UDS, fpPoll, self-pipe) | opus |
| M5 | Server/Client alto nível (acceptor, readers, dispatch, drain) | opus + revisão fable |
| M6 | Request-Reply, Broadcast, AutoReconnect, pdmMainThread | sonnet + revisão opus |
| M7 | Testes de integração (stress de Stop, queda abrupta) dual-OS | sonnet |
| M8 | Samples (echo console, chat VCL/LCL) + README | haiku |

Dependências: M0 → M1 → M2 → (M3 ‖ M4) → M5 → M6 → M7 → M8.

## Verificação por milestone

Compilar em ambos (dcc64 e fpc) + suíte de testes verde nos dois. M7 exige: Stop durante
tráfego intenso conclui em < 2s (detector de deadlock) e queda abrupta de cliente dispara
OnClientDisconnected sem vazar handle/fd.
