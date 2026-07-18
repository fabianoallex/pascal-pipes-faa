# pascal-pipes-faa

> Antes `pascal-named-pipes-faa`. O nome mudou porque o Named Pipe do Windows passou a ser
> apenas um dos transportes suportados — a API antiga segue funcionando (ver
> [Compatibilidade](#compatibilidade-com-a-api-anterior)).

Biblioteca multiplataforma de **IPC local** para **Delphi 12+ (Win64)** e
**FPC 3.2.2 / Lazarus (Linux x86_64 e ARM64)**, com uma única base de código e uma API de
alto nível que abstrai completamente as chamadas nativas do sistema operacional.
O transporte local usa Named Pipes no Windows e Unix Domain Sockets no Linux.

```pascal
// Servidor
Server := TPipeServer.Create('meu_app');
Server.OnMessage := MinhaClasse.HandleMessage;  // procedure ... of object
Server.Listen;

// Cliente
Client := TPipeClient.Create('meu_app');
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

Se `Address` já for um caminho nativo (`\\.\pipe\...` ou `/caminho/abs.sock`), ele é usado
como está — útil para controlar o diretório (e as permissões) do socket no Linux.

### Transporte

A property `Transport` (`TPipeTransport`) escolhe por onde os frames trafegam. O padrão é
`ptLocal`, então quem só faz IPC local não precisa saber que isso existe:

```pascal
TPipeServer.Create('meu_app');                  // ptLocal (padrão)
TPipeServer.Create('meu_app', ptLocal);         // idem, explícito
TPipeServer.Create('0.0.0.0:5000', ptTcp);      // TCP
TPipeClient.Create('192.168.0.10:5000', ptTcp);
```

O enum nomeia **alcance**, não mecanismo: `ptLocal` é "o melhor IPC local deste SO" —
Named Pipe no Windows, Unix Domain Socket no Linux. Um `ptNamedPipe` seria um nome errado
metade das vezes.

`Address` e `Transport` são validados juntos na ativação: `Create('\\.\pipe\X', ptTcp)`
falha com `EPipeError` explicando o conflito, em vez de estourar mais tarde num erro
obscuro de resolução de nome.

Endereços aceitos por `ptTcp`: `host:porta`, IPv6 entre colchetes (`[::1]:5000`) e `*`
como atalho de `0.0.0.0`. A resolução é via `getaddrinfo`, então nome de host e IPv6
funcionam. `TCP_NODELAY` é ligado (o atraso do Nagle penalizaria muito `Request`/`Reply`).

> **Segurança:** diferente de `ptLocal`, `ptTcp` **não** herda controle de acesso do SO
> (ACL do Windows, permissão de arquivo do UDS). Um listener em `0.0.0.0` aceita qualquer
> um que alcance a porta — autenticar é responsabilidade da aplicação.

### Keepalive (`KeepAliveSeconds`)

Uma conexão TCP pode morrer em silêncio — cabo, máquina desligada, ou o timeout de
ociosidade de um túnel VPN/NAT. Nenhum dos dois lados é avisado, e o reader ficaria
esperando para sempre. Em IPC local isso não existe: a morte do processo par sempre fecha
o pipe.

Por isso `ptTcp` liga keepalive TCP por padrão, com **20 s** de ociosidade
(`PIPES_DEFAULT_KEEPALIVE_SECONDS`). `ptLocal` ignora a property.

```pascal
Server.KeepAliveSeconds := 20;  // padrão
Server.KeepAliveSeconds := 0;   // desliga
```

O valor serve a **dois propósitos**, e o segundo costuma ser o mais importante:

1. **Detectar** conexão morta — com os padrões, em ~35 s (20 s ociosos + 3 probes a cada
   5 s). A detecção vira `EPipeClosed`, que dispara `OnClientDisconnected` no servidor e
   `OnDisconnected` + `AutoReconnect` no cliente.
2. **Manter vivo** o mapeamento de NAT/VPN de uma conexão ociosa, evitando que ela morra.
   Por isso o valor precisa ser **menor que o timeout de ociosidade do túnel**, não maior
   — se a sua VPN derruba sessão ociosa em 30 s, `KeepAliveSeconds` tem que ficar
   confortavelmente abaixo disso.

No servidor isso importa mais do que parece: sem keepalive ele acumula conexões zumbi
indefinidamente — `Broadcast` escrevendo para clientes que não existem mais e
`ClientCount` mentindo.

**Diferença entre plataformas:** no POSIX os três parâmetros (ocioso, intervalo, número
de probes) são ajustáveis por socket, então a detecção é exatamente a descrita. No Windows
usa-se `SIO_KEEPALIVE_VALS` (disponível desde o Windows 2000, ao contrário de
`setsockopt(TCP_KEEPIDLE)`, que exige Win10 1709+ — relevante para hardware antigo), e ele
não expõe a contagem de probes: ela é fixa no SO (2 do Vista em diante). O tempo até
detectar difere um pouco; a manutenção do mapeamento NAT/VPN, que depende só do tempo
ocioso, é idêntica nos dois.

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
TPipeBase (abstrata)
  Address, Transport, KeepAliveSeconds, Active, DispatchMode, MaxMessageSize
  OnMessage: TPipeMessageEvent;  OnError: TPipeErrorEvent

TPipeServer
  Listen; Stop;                          // Listen não-blocante; Stop síncrono
  SendBytes/SendText(ConnId, ...)        // EPipeError se ConnId não existe
  Broadcast/BroadcastText(...)           // snapshot; falha por conexão é engolida
  DisconnectClient(ConnId)               // assíncrono e idempotente
  ClientCount; ClientIds; MaxClients
  OnClientConnected/OnClientDisconnected: TPipeConnectionEvent
  OnRequest: TPipeRequestEvent           // (const ARequest: TBytes; out AReply: TBytes)

TPipeClient
  Connect(TimeoutMs); Disconnect;        // Connect re-tenta até o prazo
  SendBytes/SendText(...)                // fire-and-forget
  Request/RequestText(..., TimeoutMs)    // RPC síncrono; EPipeTimeout no prazo
  Connected; AutoReconnect; ReconnectDelayMs; MaxReconnectAttempts
  OnConnected/OnDisconnected: TPipeConnectionEvent

Exceções: EPipeError > EPipeClosed | EPipeTimeout | EPipeProtocol
```

### Compatibilidade com a API anterior

Os nomes antigos continuam válidos e compilam sem alteração — `TNamedPipeBase`,
`TNamedPipeServer` e `TNamedPipeClient` são aliases dos tipos acima, e a property
`PipeName` lê e escreve o mesmo campo de `Address`:

```pascal
Server := TNamedPipeServer.Create('meu_app');  // igual a TPipeServer
Server.PipeName := 'outro';                    // igual a Server.Address
```

O nome antigo amarrava a API ao Named Pipe do Windows, que passa a ser apenas um dos
transportes possíveis — no Linux o backend já é Unix Domain Socket. Os aliases serão
marcados `deprecated` só depois que samples e testes migrarem.

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
  (`Pdv.OperadorChannel`/`Pdv.ClienteChannel`) que encapsula `TPipeServer`/
  `TPipeClient` e o protocolo de mensagens (`Pdv.Protocolo.pas`).
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
- **RpcConcorrente** (`RpcConcorrenteServidor` + `RpcConcorrenteCliente`) — prova a garantia
  de que chamadas `Request`/`RequestText` de várias threads no MESMO `TPipeClient` são
  suportadas: várias `TThread` compartilham uma única instância de cliente e disparam RPCs
  em paralelo; cada uma confere que a resposta que voltou é exatamente a do pedido que ela
  fez (correlation id), expondo qualquer cruzamento de respostas entre chamadores como bug.

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
                     FilaImpressao, DespachoTarefas, ServicoInstavel, RpcConcorrente
tests/               Unit + Integration (DUnitX e FPCUnit, espelhados)
docs/ARQUITETURA.md  arquitetura completa (wire format, ciclo de vida das threads, racional)
Pipes.groupproj      grupo de projetos Delphi    Pipes.lpg  grupo Lazarus
```

## Licença

[MIT](LICENSE) — © 2026 Fabiano Arndt
