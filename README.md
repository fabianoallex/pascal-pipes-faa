# pascal-named-pipes-faa

Biblioteca multiplataforma de **Named Pipes (IPC local)** para **Delphi 12+ (Win64)** e
**FPC 3.2.2 / Lazarus (Linux x86_64 e ARM64)**, com uma única base de código e uma API de
alto nível que abstrai completamente as chamadas nativas do sistema operacional.

```pascal
// Servidor
Server := TNamedPipeServer.Create('meu_app');
Server.OnMessage := MinhaClasse.HandleMessage;  // procedure ... of object
Server.Listen;

// Cliente
Client := TNamedPipeClient.Create('meu_app');
Client.Connect(5000);
Client.SendText('olá!');
Resposta := Client.RequestText('ping', 3000);   // RPC síncrono com timeout
```

## Como funciona por baixo

| | Windows | Linux |
|---|---|---|
| Transporte | Named Pipes reais (`CreateNamedPipe`/`ConnectNamedPipe`), modo byte, **sempre overlapped** | **Unix Domain Sockets** (`AF_UNIX`/`SOCK_STREAM`) |
| Nome nativo | `\\.\pipe\meu_app` | `/tmp/meu_app.sock` |
| Interrupção de I/O blocante | `WaitForMultipleObjects` + `CancelIoEx` | `fpPoll` + self-pipe + `fpShutdown` |

No Linux, "named pipe" é implementado como **Unix Domain Socket** — a mesma abordagem do
.NET (`NamedPipeServerStream`/`NamedPipeClientStream` no Unix). UDS dá paridade semântica
total com o Named Pipe do Windows: conexões por cliente, bidirecional, detecção de queda.
FIFOs (`mkfifo`) ficaram fora da v1; a camada de transporte abstrata deixa a porta aberta.

Se `PipeName` já for um caminho nativo (`\\.\pipe\...` ou `/caminho/abs.sock`), ele é usado
como está — útil para controlar o diretório (e as permissões) do socket no Linux.

As mensagens trafegam num framing próprio (`NPF1`: header de 20 bytes little-endian com
magic, kind, correlation id e length), idêntico nos dois SOs — fronteiras de mensagem são
da biblioteca, nunca do transporte. Payloads são `TBytes`; os métodos `*Text` convertem
de/para UTF-8 de forma portátil.

## Recursos

- **Servidor multi-cliente** — acceptor + uma reader thread por conexão; `MaxClients`
  opcional; `SendBytes/SendText` por conexão; `Broadcast/BroadcastText`;
  `DisconnectClient`; eventos `OnClientConnected`/`OnClientDisconnected`.
- **Request-Reply síncrono** — `Request/RequestText(dados, timeout)` no cliente bloqueia o
  *chamador* (nunca a thread de leitura) até o reply correlacionado; no servidor, o handler
  `OnRequest` devolve o reply e a lib o envia com o correlation id certo. Exceção no
  handler vira reply de erro (`EPipeError` no cliente, com a mensagem do servidor).
  Chamadas concorrentes de várias threads no mesmo cliente são suportadas.
- **AutoReconnect** — o cliente reconecta sozinho após queda do servidor
  (`ReconnectDelayMs`, `MaxReconnectAttempts`). Durante a janela de reconexão, `Send*`
  levanta `EPipeClosed` transitório — re-tente (contrato igual ao republish de um client MQ).
- **Modos de despacho** (`DispatchMode`) — onde os SEUS handlers executam:
  - `pdmPool` (padrão): pool de threads; paralelo entre conexões.
  - `pdmSerialized`: worker único; ordem FIFO global garantida.
  - `pdmMainThread`: direto na thread da UI via `TThread.Queue` — para apps VCL/LCL, sem
    `Synchronize` manual e sem risco de evento pós-destroy (objeto-guarda interno).
- **Proteção** — `MaxMessageSize` (padrão 16 MB) rejeita frames acima do limite nas duas
  pontas; magic/kind inválidos derrubam só a conexão ofensora (`EPipeProtocol` em `OnError`).

## Garantias de threading

- A thread de leitura **nunca** executa código do usuário — só decodifica e despacha.
- `Stop`/`Disconnect`/destructors são **síncronos, idempotentes e sem deadlock**: sinalizam
  tudo, aguardam o join das threads e drenam os callbacks em voo antes de liberar qualquer
  objeto (verificado por teste: `Stop` sob flood de 4 clientes conclui em < 2 s).
- Queda abrupta do par (processo morto, handle fechado) dispara `OnClientDisconnected` /
  `OnDisconnected` sem vazar handles/fds (verificado por teste com contagem de handles).
- Callbacks são sempre `procedure ... of object`; exceções dentro deles são engolidas pelo
  pool (log via `OnError` é responsabilidade sua).
- Detalhe de semântica: um cliente que conecta e morre **antes de o servidor aceitar** a
  conexão é invisível (nenhum evento) — a instância/backlog é reciclada.

## Instalação

**Delphi:** adicione `src\` ao search path (ou abra `Pipes.groupproj`). Sem dependências.

**Lazarus:** abra/compile `packages\pipes_faa.lpk` uma vez e adicione `pipes_faa` aos
requisitos do seu projeto (ou use `lazbuild --add-package-link packages\pipes_faa.lpk`).

## API (resumo)

```pascal
TNamedPipeBase (abstrata)
  PipeName, Active, DispatchMode, MaxMessageSize
  OnMessage: TPipeMessageEvent;  OnError: TPipeErrorEvent

TNamedPipeServer
  Listen; Stop;                          // Listen não-blocante; Stop síncrono
  SendBytes/SendText(ConnId, ...)        // EPipeError se ConnId não existe
  Broadcast/BroadcastText(...)           // snapshot; falha por conexão é engolida
  DisconnectClient(ConnId)               // assíncrono e idempotente
  ClientCount; ClientIds; MaxClients
  OnClientConnected/OnClientDisconnected: TPipeConnectionEvent
  OnRequest: TPipeRequestEvent           // (const ARequest: TBytes; out AReply: TBytes)

TNamedPipeClient
  Connect(TimeoutMs); Disconnect;        // Connect re-tenta até o prazo
  SendBytes/SendText(...)                // fire-and-forget
  Request/RequestText(..., TimeoutMs)    // RPC síncrono; EPipeTimeout no prazo
  Connected; AutoReconnect; ReconnectDelayMs; MaxReconnectAttempts
  OnConnected/OnDisconnected: TPipeConnectionEvent

Exceções: EPipeError > EPipeClosed | EPipeTimeout | EPipeProtocol
```

## Samples (`samples/`)

- **EchoServer / EchoClient** — console, mesmo fonte nos dois compiladores. Rode o servidor,
  depois o cliente: texto simples usa `SendText` (eco assíncrono via `OnMessage`); linhas
  começando com `?` usam `RequestText` (RPC).
- **ChatVcl** — chat com UI (VCL no Delphi, LCL no Lazarus, mesmo fonte): uma instância é o
  servidor-hub (retransmite via `Broadcast`), as outras são clientes. Vitrine do
  `pdmMainThread` (handlers mexem na UI direto) e do `AutoReconnect`.
- **PdvDualScreen** (`Operador` + `Cliente`) — PDV de tela dupla: o operador lança itens e
  pede a forma de pagamento; o cliente acompanha e responde. Mostra o padrão recomendado
  para uso em produção: a UI de cada lado não fala `TBytes`/`TPipeConnectionId` diretamente,
  só os tipos de domínio (`TPdvItem`, `TPdvFormaPagamento`) através de uma fachada
  (`Pdv.OperadorChannel`/`Pdv.ClienteChannel`) que encapsula `TNamedPipeServer`/
  `TNamedPipeClient` e o protocolo de mensagens (`Pdv.Protocolo.pas`).
- **FilaImpressao** (`FilaServidor` + `FilaCliente`) — mostra `pdmSerialized` vs `pdmPool` na
  prática: um handler com estado compartilhado sem lock (de propósito) processa jobs vindos
  em sequência; `FilaServidor pipe serialized` (padrão) nunca acusa reentrância e conclui na
  ordem de chegada, `FilaServidor pipe pool` acusa concorrência real e conclusão fora de
  ordem com a mesma carga.
- **DespachoTarefas** (`DespachoServidor` + `DespachoWorker`) — mostra endereçamento por
  conexão em vez de `Broadcast`: o operador digita `job <texto>` e o servidor despacha para
  UM worker por vez (round-robin sobre `ClientIds`); também exercita `MaxClients`,
  `DisconnectClient` (comando `kick`) e `list`.
- **ServicoInstavel** (`ServicoInstavel` + `ClienteResiliente`) — servidor que simula
  lentidão e falhas de negócio aleatórias em `OnRequest`; o cliente mostra um padrão de
  retry com backoff exponencial que trata `EPipeTimeout`/`EPipeClosed` (transitório, repete)
  e `EPipeError` (erro de negócio, não repete) de formas diferentes.

## Testes

- Delphi: abra `Pipes.groupproj` e rode `Pipes.UnitTests` e `Pipes.IntegrationTests` (DUnitX).
- FPC/Lazarus (Windows): `lazbuild tests\Unit\fpc\PipesUnitTestsFpc.lpi` e rode o exe com
  `--all --format=plain` (sem parâmetros abre a GUI de testes).
- Linux (Docker): imagem Debian Bookworm traz o FPC 3.2.2 exato:

  ```bash
  docker run --rm -v "$PWD:/work" debian:bookworm bash -c '
    apt-get update -qq && apt-get install -y -qq fpc >/dev/null
    cd /work/tests/Integration/fpc
    fpc -MDelphi -Sh -B -Fu../../../src -FU/tmp -o/tmp/t PipesIntegrationTestsFpc.lpr
    /tmp/t --all --format=plain'
  ```

A suíte de integração inclui stress de encerramento (Stop sob flood < 2 s), detector de
vazamento de handle/fd em quedas abruptas repetidas e correlação RPC sob concorrência.

## Estrutura

```
src/                 biblioteca (Pipes.Types, Pipes.Framing, Pipes.Transport[.Windows|.Posix],
                     Pipes.Base, Pipes.Server, Pipes.Client, Pipes.Threading, pipes.inc)
packages/            pipes_faa.lpk (pacote Lazarus)
samples/             EchoServer, EchoClient, ChatVcl, PdvDualScreen (Operador + Cliente),
                     FilaImpressao, DespachoTarefas, ServicoInstavel
tests/               Unit + Integration (DUnitX e FPCUnit, espelhados)
docs/ARQUITETURA.md  arquitetura completa (wire format, ciclo de vida das threads, racional)
Pipes.groupproj      grupo de projetos Delphi    Pipes.lpg  grupo Lazarus
```

## Licença

[MIT](LICENSE) — © 2026 Fabiano Arndt
