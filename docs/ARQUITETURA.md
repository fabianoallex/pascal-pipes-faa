# Arquitetura — pascal-pipes-faa (racional histórico)

> 🇬🇧 This document is also available in [English](ARCHITECTURE.en.md).

Relatório da proposta arquitetural aprovada em 2026-07-16, mantido como registro do
racional de design (por que UDS e não FIFO, por que framing próprio, por que Schannel
valida a cadeia manualmente etc.). Chamava-se "Named Pipes (v1)" porque o Named Pipe era
o único transporte planejado; o projeto e o repositório foram renomeados para
`pascal-pipes-faa` quando `ptTcp`/`ptTls` (§2.5, §7) deixaram de ser hipótese e viraram
código (ver `../README.md`, seção "Compatibilidade com a API anterior").

O resumo operacional (restrições e invariantes de threading) vive em `../CLAUDE.md`. O
**estado atual da API pública** (o que existe hoje, com exemplos) vive em `../README.md` —
este documento aqui é o "porquê", não o "o que tem hoje"; quando os dois divergirem sobre
um detalhe de API, o README é a fonte de verdade.

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

> Esqueleto ilustrativo do racional de design — para as assinaturas exatas e todas as
> propriedades (`Transport`, `TlsOptions`, `KeepAliveSeconds`, identidade de par mTLS etc.),
> ver `../README.md`, seção "API — resumo".

```pascal
type
  TPipeConnectionId = UInt64;  // 0 = inválido; servidor gera sequencial atômico

  TPipeTransportKind = (ptLocal, ptTcp, ptTls);  // §2.5/§7 — Named Pipe/UDS, TCP, TCP+TLS

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

  EPipeError    = class(Exception);
  EPipeTimeout  = class(EPipeError);
  EPipeClosed   = class(EPipeError);
  EPipeProtocol = class(EPipeError);  // frame corrompido, magic inválido, oversize
  EPipeTls      = class(EPipeError);  // falha de handshake/validação de certificado

  TPipeBase = class abstract
  public
    property Address: string;          // 'meu_app' → Win: \\.\pipe\meu_app
                                        //             Linux: /tmp/meu_app.pipe (configurável)
                                        //             ptTcp/ptTls: 'host:porta'
    property Transport: TPipeTransportKind;  // ptLocal (padrão), ptTcp, ptTls — §2.5
    property TlsOptions: TPipeTlsConfig;     // ignorado fora de ptTls; ver §7 (T0-T5)
    property KeepAliveSeconds: Cardinal;     // só ptTcp/ptTls; 0 = desligado
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
    function  ClientCount: Integer;      // só conexões ESTABELECIDAS (pós-handshake TLS)
    function  ClientIds: TArray<TPipeConnectionId>;
    function  TryClientIdentity(AConnId: TPipeConnectionId;
                out AIdentity: TPipePeerIdentity): Boolean;  // identidade do certificado mTLS
    property  MaxClients: Integer;      // 0 = ilimitado; conta a partir do handshake aceito
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
    property  MaxReconnectAttempts: Integer;  // 0 = ilimitado; zera a cada conexão aceita
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
                      4=subscribe  5=unsubscribe  6=publish   (pub/sub, §9)
  Flags    : 1 byte   bit 0 = reply de erro; bit 1 = publicação a reter
  Reserved : 2 bytes  (0)
  CorrId   : 8 bytes  correlation id (request/reply; 0 em msg)
  Length   : 4 bytes  tamanho do payload (validado contra MaxMessageSize)
Payload    : Length bytes (TBytes cru; texto = UTF-8)
```

Nos kinds 4-6 o payload começa com o envelope de tópico: `u16 TopicLen` + tópico UTF-8 +
corpo. O tópico **não** ocupa os 2 bytes `Reserved`, que seriam mais baratos, porque então
`Length` deixaria de cobrir o resto do frame: um peer de versão anterior leria a quantidade
errada de bytes e passaria a acusar "magic inválido" em frames perfeitos. Com o tópico
dentro do payload, esse peer falha no próprio kind desconhecido, com o stream ainda em
sincronia — foi o que permitiu adicionar pub/sub sem trocar o magic.

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

### 5.3 Interrupção da leitura blocante — TCP e TLS

- **POSIX**: um socket TCP é o mesmo objeto que um UDS a nível de fd — reaproveita
  integralmente `fpPoll([fd, fdStop])` + self-pipe de §5.2, sem código extra.
- **Windows**: não há Named Pipe overlapped para socket; `Pipes.Transport.Tcp.pas`
  implementa o análogo Winsock do padrão `[evento da operação, evento de stop]`:
  `WSAEventSelect` associa o socket a um `WSAEVENT` e toda espera é um
  `WSAWaitForMultipleEvents` nesse par. O socket fica não-bloqueante; cada operação tenta
  `recv`/`send` primeiro e só espera no evento se vier `WSAEWOULDBLOCK` (evita depender da
  semântica de borda de `FD_READ`/`FD_WRITE`, que só re-sinaliza na transição).
- **`ptTls`**: `Pipes.Transport.Tls.pas` é a fachada neutra — não implementa TLS, só
  embrulha o endpoint TCP num `TStream` e delega a um backend por diretiva de compilação:
  `Pipes.Transport.Schannel.pas` (SSPI, Windows) ou `Pipes.Transport.OpenSSL.pas`
  (libssl/libcrypto, POSIX e Windows opt-in). Uma leitura presa no TLS está, na prática,
  presa no `Read` do endpoint TCP de baixo; abortar aquele propaga `EPipeClosed` pela pilha
  de decifragem — não há estado próprio a desarmar no adaptador TLS.
- **Handshake do servidor TLS fora do accept**: o listener devolve o endpoint ainda não
  negociado; quem chama o handshake é a reader thread da própria conexão, não o loop de
  accept — um cliente lento travado no meio do handshake não impede o servidor de aceitar
  os demais. `HandshakeTimeoutMs` limita esse handshake (0 = padrão da lib; ver
  `PIPE_TLS_HANDSHAKE_NO_TIMEOUT` para desligar).
- **mTLS**: servidor implementado nos dois backends — OpenSSL (`SSL_VERIFY_PEER` +
  `FAIL_IF_NO_PEER_CERT`) recusa a conexão dentro do handshake; Schannel completa o
  handshake e só depois valida a cadeia manualmente (§7, nota sobre `VerifyClientChain`),
  então a recusa acontece um passo depois — diferença de comportamento observável que a
  aplicação não deve assumir como idêntica entre plataformas (detalhado em
  `../README.md`, seção sobre mTLS).

### 5.4 Encerramento sem congelar a UI

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
| `src/Pipes.Types.pas` | `TPipeConnectionId`, eventos, exceções, `TPipeDispatchMode`, `TPipeTransportKind`, `TPipePeerIdentity`, constantes de keepalive |
| `src/Pipes.Framing.pas` | encode/decode do frame, helpers UTF-8 |
| `src/Pipes.Topics.pas` | pub/sub: validação de nome/filtro, casamento hierárquico, envelope de tópico. **Unit pura** (sem estado, sem locks, sem IO) — §9 |
| `src/Pipes.Transport.pas` | `TPipeEndpoint`/`TPipeListener` abstratos (Read/Write/Accept interrompíveis + CloseAbort) |
| `src/Pipes.Transport.Windows.pas` | Named Pipe overlapped (`{$IFDEF PIPES_WINDOWS}`) |
| `src/Pipes.Transport.Posix.pas` | UDS + fpPoll + self-pipe (`{$IFDEF PIPES_POSIX}`) |
| `src/Pipes.Transport.Tcp.pas` | socket TCP nos dois OS (`ptTcp`), keepalive (§5.3) |
| `src/Pipes.Transport.Tls.pas` | fachada neutra `ptTls`: embrulha um endpoint TCP numa sessão TLS, escolhe o backend por diretiva (§5.3) |
| `src/Pipes.Transport.Schannel.pas` | backend TLS via SSPI (`{$IFDEF PIPES_SCHANNEL}`), cliente e servidor, validação manual de cadeia (§7) |
| `src/Pipes.Transport.OpenSSL.pas` | backend TLS via OpenSSL (`{$IFDEF PIPES_OPENSSL}`), cliente e servidor, mTLS |
| `src/Pipes.Base.pas` | `TPipeBase` (Address/Transport/TlsOptions/KeepAliveSeconds/DispatchMode), `TPipeTlsConfig`, `TPipeGuard` |
| `src/Pipes.Server.pas` | `TPipeServer` + acceptor + conexões + identidade de par mTLS |
| `src/Pipes.Client.pas` | `TPipeClient` + reconexão + `MaxReconnectAttempts` |
| `tests/Unit/` (`Pipes.ThreadingTests`, `Pipes.FramingTests`, `Pipes.TopicsTests`, `Pipes.AddressTests`) | unitários; DUnit (Delphi) + fpcunit (FPC, em `fpc/`), layout espelhado do pascal-amqp-faa |
| `tests/Integration/` (`Pipes.TransportTests`, `Pipes.EndToEndTests`, `Pipes.PubSubTests`, `Pipes.StressTests`, `Pipes.TlsTests`) | integração dual-OS, inclui mTLS; mesmo espelhamento DUnit/fpcunit |
| `tests/pki/` | PKI de **teste** versionada (sem valor de segurança; ver `LEIA-ME.md`) |
| `samples/` | amostras (echo, chat, PDV, fila de impressão, RPC concorrente, pub/sub etc.) — ver `../README.md`, seção de samples |

## 7. Milestones

Todos os milestones abaixo (M0-M8 e T0-T5) estão **concluídos**; a tabela fica como
registro histórico do sequenciamento e da alocação de agente, não como plano em aberto.

| # | Milestone | Conteúdo | Agente recomendado | Status |
|---|-----------|----------|--------------------|--------|
| M0 | Bootstrap | git init, pastas, `pipes.inc`, `.gitignore`, projetos de teste compilando vazios | haiku | concluído |
| M1 | Threading | cópia/rename de `AMQP.Threading.pas` + testes de fumaça (pool, monitor, atomics) | haiku + revisão sonnet | concluído |
| M2 | Framing | `Pipes.Types` + `Pipes.Framing` + testes unitários (roundtrip, magic inválido, oversize, UTF-8) | sonnet | concluído |
| M3 | Transporte Windows | `Pipes.Transport` abstrato + implementação overlapped completa | opus | concluído |
| M4 | Transporte Linux | UDS, fpPoll, self-pipe, MSG_NOSIGNAL, unlink | opus | concluído |
| M5 | Alto nível | Server/Client, acceptor, readers, dispatch, DrainInFlight, Stop/Disconnect | opus + revisão fable | concluído |
| M6 | Avançados | Request-Reply, Broadcast, AutoReconnect, pdmMainThread + guarda | sonnet + revisão opus | concluído |
| M7 | Integração | echo, N clientes concorrentes, queda abrupta, stress de Stop sob tráfego — dois OS | sonnet | concluído |
| M8 | Samples/docs | echo console + chat VCL/LCL + README | haiku | concluído |

### Milestones posteriores (fora do plano original)

O `ptTcp` e o `ptTls` vieram depois do M8, quando surgiu o caso de uso de PDVs de loja
conversando com a retaguarda sobre VPN — cenário em que "IPC local" deixa de bastar e
aparecem dois problemas que o desenho original não tinha: conexão ociosa morrendo em
silêncio (keepalive) e listener exposto sem controle de acesso do SO (TLS/mTLS).

| # | Milestone | Conteúdo | Status |
|---|-----------|----------|--------|
| T0 | Base TLS | adaptador `TPipeEndpoint`⇄`TStream`, cliente TLS | concluído |
| T1 | Handshake fora do accept | negociação na reader thread da conexão, não no loop de accept | concluído |
| T2 | Servidor Schannel | `AcceptSecurityContext`, credencial INBOUND, PFX | concluído |
| T3 | Servidor OpenSSL | equivalente no POSIX | concluído |
| T4 | mTLS | OpenSSL (`SSL_VERIFY_PEER` + `FAIL_IF_NO_PEER_CERT`) e Schannel (validação manual da cadeia) | concluído |
| T5 | `ptTls` na API pública | enum, `TlsOptions`, timeout de handshake, suíte e docs | concluído |

**Por que a validação de cadeia do Schannel é manual.** `hRootStore` +
`ASC_REQ_MUTUAL_AUTH` **não** validam a cadeia do cliente: o Schannel apenas *exige* que
ele apresente um certificado e entrega esse certificado à aplicação — decidir se a cadeia
é confiável é dela. Uma versão anterior deste código assumiu o contrário e aceitou um
certificado de CA desconhecida. `TPipeSchannelServerStream.VerifyClientChain` faz o
trabalho em quatro passos, sendo o decisivo comparar a **raiz** da cadeia construída, byte
a byte, com a CA configurada: um cliente pode montar uma cadeia íntegra com a própria CA
auto-assinada, e nesse caso o único defeito é "raiz desconhecida" — que é exatamente o
defeito que toda PKI privada tem e que o servidor precisa tolerar para o cliente legítimo
funcionar.

O caso de teste que guarda isso é o do certificado **auto-assinado**, não o de outra CA: o
segundo é reprovado antes, por cadeia incompleta.

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

## 9. Pub/sub por tópico (milestones P0-P4)

Veio depois do T5, quando ficou claro que entre `SendBytes(ConnId, ...)` e `Broadcast` falta
o caso mais comum de um sistema com várias pontas: **endereçar por assunto**, sem que o
remetente saiba quem está interessado. A API está no `README.md`; aqui fica o *por quê*.

### 9.1 O que isto NÃO é

Não é um broker. Não há durabilidade, ack, QoS, redelivery, fila nomeada ou dead-letter — e
não deve haver: esse é o trabalho do `pascal-amqp-faa`, e duplicá-lo aqui daria uma segunda
implementação pior da mesma coisa. O que existe é **roteamento por assunto sobre uma conexão
viva**. A única concessão a estado é o *retain*, que é cache de último valor (um por tópico),
justamente porque a alternativa — cada cliente perguntar o estado atual ao conectar — é o
handshake ad-hoc que todo mundo escreve errado.

### 9.2 A regra de ouro: decisão de roteamento é código puro na reader thread

Toda decisão sobre *quem recebe o quê* roda na thread de leitura, com código sem locks de
usuário e sem IO (`Pipes.Topics` é uma unit pura de propósito). Os callbacks do usuário
(`OnPublish`, `OnSubscribe`, `OnUnsubscribe`) são **notificações** despachadas ao pool
*depois* de a decisão estar tomada.

O desenho alternativo — `OnPublish` com um `var AAllowRelay` para o usuário vetar — foi
rejeitado, e a razão é de ordem, não de estilo: o handler roda no pool, então duas
publicações do **mesmo** cliente poderiam ser retransmitidas fora de ordem em `pdmPool`. O
transporte é ordenado e a aplicação tem o direito de contar com isso. Por isso
`RelayClientPublish` é um Boolean lido na hora. Quem quer decidir caso a caso deixa o relay
desligado e chama `Publish` de dentro do handler, assumindo a ordem que escolher (FIFO
garantida em `pdmSerialized`).

O mesmo argumento vale para assinaturas, com um sintoma pior: aplicar `Subscribe` no pool
deixaria um `Unsubscribe` passar na frente do `Subscribe` que ele cancela, e o estado final
ficaria errado — de forma intermitente e irreproduzível. Daí `OnSubscribe` ser notificação;
para **negar** uma assinatura, o servidor chama `DisconnectClient` (um cliente que pede
tópico alheio não merece meia-medida).

### 9.3 Assinatura na conexão, não em tabela global

A lista de filtros é campo de `TPipeServerConnection`, protegida pelo **`FConnLock` já
existente**, e não por uma tabela `tópico → conexões` com lock próprio. Três consequências,
todas boas:

1. Nenhum nível novo na ordem de locks (`FConnLock → write lock` continua sendo tudo).
2. O fanout tira o snapshot dos destinatários no mesmo passo em que já percorre
   `FConnections` — é o `Broadcast` com um teste de casamento.
3. **A assinatura morre com a conexão, no destructor dela.** Não existe registro global de
   onde desinscrever no teardown, e portanto não existe a classe de vazamento silencioso que
   uma tabela global teria (o teste `AssinaturaMorreNaQuedaAbrupta` guarda isso com um
   endpoint cru que desaparece sem despedida).

O custo é O(N conexões) por publicação em vez de O(assinantes). Na escala real da biblioteca
(dezenas a centenas de conexões, casamento sem alocar) isso é irrelevante, e trocá-lo por um
terceiro nível de lock seria pagar complexidade de concorrência para comprar microssegundos.

### 9.4 Curingas: por que recusar em vez de interpretar

`#` só vale como último segmento e `*`/`#` só valem como segmento inteiro. `a.#.b` e
`caixa*` são **recusados**, não reinterpretados: no primeiro caso as duas leituras possíveis
de `#` dariam resultados diferentes para o mesmo filtro; no segundo, `caixa*` prometeria
casamento parcial dentro do segmento, que este matcher não faz — e um filtro que casa nada
em silêncio é o pior desfecho para quem está depurando. Comparação é byte a byte
(sensível a caixa): não há *upcase* portátil para UTF-8, e um casamento dependente de locale
seria pior que um sensível a caixa.

### 9.5 Recusa assíncrona: reply de erro com corrId 0

`Subscribe` é fire-and-forget (não há ack a esperar). Uma assinatura recusada pelo servidor
— filtro inválido vindo de um peer artesanal, ou teto `MaxSubscriptionsPerClient` — seria
**silêncio puro** no cliente: ele ficaria esperando mensagens que nunca viriam, sem saber por
quê. Por isso o servidor devolve um reply de erro com `corrId 0`, que nenhum `Request` usa (a
sequência do cliente começa em 1), e o cliente o traduz em `OnError`. A recusa aparece nos
dois lados, e a conexão continua de pé.

### 9.6 Reconexão: o buraco que existe e o que o fecha

As assinaturas são **estado desejado do cliente**, não da sessão: vivem em `FSubs` e são
reenviadas em cada sessão nova, dentro do `TryReopenSession`, **antes** de `OnConnected`
disparar. Sem isso a reconexão automática devolveria uma conexão viva e muda — o servidor
perdeu a lista de filtros junto com a conexão anterior (§9.3) e não há quem o lembre. O
sintoma (mensagens que param de chegar depois de uma reconexão que o app nem viu) não se
parece nada com a causa; é o `Resubscribe_AposReconexaoAutomatica` que guarda isso.

O que **não** se recupera é a janela entre a queda e a reassinatura: publicação que passou
ali está perdida. Isso é propriedade, não bug — e é a razão de o *retain* existir.

### 9.7 O bit de retenção no fio responde ao CONSUMIDOR, não ao remetente

`PIPE_FLAG_RETAIN` sai ligado **apenas** no catch-up de assinatura (`SendRetained`); o fanout
ao vivo o desliga sempre, mesmo quando o publicador pediu retenção. Chega ao app como
`ARetained` em `OnTopicMessage`, e a pergunta que ele responde é a do consumidor — *isto
acabou de acontecer, ou é o valor que já vigorava?* — e não a do remetente, que já sabe o
que pediu.

Propagar o bit adiante no fanout seria a leitura errada e um bug esperando: o app trataria a
venda de agora como catch-up (ou o contrário) e contaria duas vezes, ou nenhuma. É a mesma
regra do MQTT, e por isso mesmo: um app que já sabe MQTT não é surpreendido aqui. O teste
`Retido_AoVivoNaoVemMarcado` guarda os dois lados — a publicação ao vivo *com* retain chega
sem marca, e o valor fica guardado do mesmo jeito para o próximo assinante.

Do lado do servidor, o mesmo parâmetro em `OnPublish` tem o único sentido possível ali: o
cliente **pediu** para reter (pedido atendido só com `RelayClientPublish` ligado).

### 9.8 Milestones

| # | Milestone | Conteúdo | Status |
|---|-----------|----------|--------|
| P0 | `Pipes.Topics.pas` | nomes, curingas, envelope; testes unitários sem IO | concluído |
| P1 | Servidor | kinds 4-6, assinatura por conexão, fanout, retain, tetos | concluído |
| P2 | Cliente | `Subscribe`/`Unsubscribe`/`Publish`, replay na reconexão | concluído |
| P3 | Integração | fanout, ciclo de vida, retain, recusas, `Stop` sob carga | concluído |
| P4 | Sample + docs | `samples/PainelLoja` (console, três papéis num exe) | concluído |
| P5 | `ARetained` + sample GUI | bit de retenção na API (§9.7) e `samples/MonitorTopicos` (VCL/LCL) | concluído |

## 10. Heartbeat de aplicação (`ptTcp`/`ptTls`)

Veio depois do T5, motivado pelo mesmo caso de uso que trouxe o `ptTcp` (§7, "Milestones
posteriores": PDV de loja conversando com a retaguarda sobre VPN, onde conexão ociosa
morrendo em silêncio já era um dos dois problemas citados). `KeepAliveSeconds`
(§2, `Pipes.Base`) já detecta essa morte silenciosa, mas é um probe do SO — tipicamente
leva minutos (`TCP_KEEPIDLE`/`TCP_KEEPINTVL`/`TCP_KEEPCNT`, não configuráveis por segundo)
e enxerga só o socket TCP por baixo, nunca o que atravessa o registro cifrado do `ptTls`.
`HeartbeatIntervalMs` é o mesmo problema resolvido em cima do framing: um frame de
aplicação, com controle total da aplicação sobre o tempo de detecção.

### 10.1 Simétrico e sem correlação: por que não há `pfkPong`

O `pfkPing` (kind 3) já estava reservado no NPF1 desde o M2 e nunca ganhou um `pfkPong`
irmão. A razão: heartbeat não é uma pergunta que espera resposta, é um sinal de vida
observado nos dois sentidos ao mesmo tempo. **Qualquer frame recebido — o próprio Ping
incluso — reseta o relógio de leitura de quem o recebeu.** Isso elimina todo o estado que
um ping/pong correlacionado exigiria (nonce, tabela de "ping em aberto", timeout por
tentativa) e é o mesmo desenho que o heartbeat do AMQP 0-9-1 usa (`AMQP.Connection.pas`,
`TAMQPHeartbeatThread`/`HeartbeatTick` no `pascal-amqp-faa`): cada lado manda um heartbeat
quando está ocioso na escrita, e cada lado mede sozinho a própria ociosidade na leitura.

### 10.2 Matar a conexão é só `CloseAbort` — nenhum mecanismo de interrupção novo

Detectar morte (nenhum frame recebido, Ping incluso, há mais de **2× o intervalo**) e agir
sobre ela é uma única chamada: `FEndpoint.CloseAbort`. É o mesmo mecanismo "thread-safe e
idempotente" (`Pipes.Transport.pas`, cabeçalho) que qualquer erro de protocolo já usa
(`Pipes.Server.pas` `ReaderFinished`, por exemplo) — desbloqueia a reader thread com
`EPipeClosed`, que cai no `except` de sempre e segue o teardown normal
(`OnClientDisconnected` no servidor; `OnDisconnected` + `AutoReconnect` no cliente). Não
existe um novo par sinal/cancelamento a manter: o heartbeat *reaproveita* a interrupção que
o M3-M5 já resolveram, na íntegra.

### 10.3 `TPipeHeartbeatThread`: uma thread genérica em `Pipes.Threading`

Servidor e cliente precisavam do mesmo laço (acordar a cada metade do intervalo por uma
espera interrompível — nunca `TTimer` — e chamar um tick), então a thread mora em
`Pipes.Threading.pas` parametrizada por um callback `of object`
(`TPipeHeartbeatTick = procedure of object`), não por closure (proibidas nesta lib). Quem
decide o que fazer no tick é o dono (`TPipeServerConnection.HeartbeatTick` ou
`TPipeClient.HeartbeatTick`), não a thread — ela só embrulha o "acordar periodicamente de
forma cancelável" que já se repetia no padrão de thread pool e no `TAMQPHeartbeatThread`
do projeto irmão.

### 10.4 Ciclo de vida: os MESMOS pontos que já juntam (join) o reader

No servidor, `StartHeartbeat` roda na própria reader thread, logo após
`OnClientConnected` (a conexão só entra em "estabelecida"); `StopHeartbeat` roda nos
mesmos dois lugares que já dão `WaitFor` no `FReader` da conexão (`Stop` e `RunCleanup`) —
nunca dentro do próprio `HeartbeatTick`, e sempre antes do `Destroy` que libera
`FStream`/`FEndpoint`.

No cliente a vida é por **sessão**, não pelo cliente inteiro: `StartHeartbeat` roda em
`Connect` e em cada `TryReopenSession` bem-sucedido; `StopHeartbeat` roda nos mesmos
pontos que já juntam o `FReader` da sessão que está saindo (`Disconnect` e o topo de
`TryReopenSession`) — **antes** de `FStream`/`FEndpoint` serem trocados ou liberados. Sem
essa ordem, a heartbeat thread de uma sessão morta poderia escrever no stream da sessão
seguinte (ou, pior, num objeto já liberado): a razão de existir dessa ordem é a mesma de
`FWriteLock` proteger o próprio par `FStream`/`FEndpoint` contra troca concorrente (ver
cabeçalho de `Pipes.Client.pas`).

### 10.5 Escopo: só `ptTcp`/`ptTls`

`ptLocal` ignora `HeartbeatIntervalMs` de propósito — mesma regra e mesma razão de
`KeepAliveSeconds`: a morte do processo par já fecha o Named Pipe/UDS local na hora
(`ERROR_BROKEN_PIPE`/`POLLHUP`, §5.1-5.2), então não há "zumbi" local a detectar. O teste
`PtLocal_IgnoraHeartbeatIntervalMs` guarda isso configurando o intervalo e confirmando que
uma sessão ociosa nos dois sentidos sobrevive ao prazo que a derrubaria em `ptTcp`.

### 10.6 Milestones

| # | Milestone | Conteúdo | Status |
|---|-----------|----------|--------|
| H0 | `Pipes.Framing` + `Pipes.Threading` | `TPipeFrame.Ping` (kind 3, sem correlação); `TPipeHeartbeatThread` genérica | concluído |
| H1 | `TPipeBase` | property `HeartbeatIntervalMs` (0 = desligado; só `ptTcp`/`ptTls`) | concluído |
| H2 | Servidor | ticks por conexão, `StartHeartbeat`/`StopHeartbeat`/`HeartbeatTick`, `CloseAbort` no timeout | concluído |
| H3 | Cliente | heartbeat por sessão (Connect + cada reconexão), mesmos pontos de join do `FReader` | concluído |
| H4 | Testes | zumbi detectado nos dois sentidos, `ptLocal` imune, `Stop`/`Disconnect` <2s com heartbeat ativo | concluído |

## 11. Métricas/observabilidade (`Stats`/`ConnectionStats`)

Veio logo depois do heartbeat, do mesmo diagnóstico: o alvo de produção (PDV de loja) precisa
de visibilidade sem log verboso — "está fluindo tráfego?", "tem request lento?", "quantos
clientes de verdade?" — sem instrumentar a aplicação por fora. Ao contrário do heartbeat,
isto vale para **qualquer transporte** (`ptLocal` incluso: um Named Pipe também se beneficia
de saber quantos bytes passaram).

### 11.1 Snapshot, não evento — o mesmo molde de `ClientCount`

A lib já resolveu essa decisão de design antes: `ClientCount`, `ClientIds`, `Subscriptions`,
`SubscriberCount`, `TryClientIdentity` são todos **snapshots sob demanda** — o app pergunta
quando quer saber, a lib não empurra nada periodicamente. `Stats`/`ConnectionStats` seguem o
mesmo molde, em vez de um `OnStats` com timer e `DispatchMode` próprios: menos API nova, zero
mecanismo de despacho a inventar. Quem quer uma amostra periódica usa o próprio timer da
aplicação chamando `Stats` quando convier.

### 11.2 Sempre ativos, sem opt-in

Ao contrário do heartbeat (que só existe com `HeartbeatIntervalMs` configurado), os
contadores de bytes/mensagens custam um `PipeAtomicAdd64` por frame — nanossegundos, a mesma
ordem de grandeza que `FInFlight` já paga em todo callback despachado. Não há property
`EnableStats`: o custo é baixo demais para justificar mais uma decisão de configuração, e uma
métrica que só existe às vezes é a fonte clássica de "por que não vi isso no painel".

### 11.3 Por conexão morre com ela; agregado do servidor sobrevive

`TPipeConnStats` (por conexão, via `ConnectionStats`) morre com a conexão — como `FSubs`, ao
contrário de `TPipePeerIdentity` (que sobrevive de propósito para responder "quem saiu?" em
`OnClientDisconnected`, §3). `TPipeServerStats` (via `Stats`) é o oposto: cumulativo desde o
`Listen`, sobrevive a conexões que já caíram — é o número para um health-check ou painel de
operação ("quanto tráfego este processo já moveu"), não para depurar UMA conexão específica.
`TotalConnectionsAccepted` só conta conexões **estabelecidas**, mesmo critério de
`ClientCount`/`ClientIds`: uma conexão recusada no meio do handshake mTLS não infla o número.

### 11.4 `PoolQueueDepth` pode mentir — e isso está documentado, não escondido

Em `pdmPool` (o padrão), `EventPool` resolve para o pool **global** do processo
(`Pipes.Threading.PipePool`), compartilhado por todo `TPipeServer`/`TPipeClient` da mesma
aplicação. `Server.Stats.PoolQueueDepth` reflete o backlog de TODO MUNDO nesse caso, não só
deste servidor — só é exclusivo dele em `pdmSerialized` (pool privado de 1 worker). A
alternativa — filtrar por dono no pool global — exigiria linkar cada item de trabalho ao
servidor que o enfileirou, complexidade real para um número que já existe barato do jeito
simples. A opção foi documentar a ressalva no XMLDoc da property em vez de resolver o
problema errado.

### 11.5 Latência de Request: só o caminho de sucesso conta

`TPipeClient.Request` já sabe quando começou (antes de escrever) e quando terminou (o
`WaitFor` do slot RPC). `AvgRequestLatencyMs`/`MaxRequestLatencyMs` só são atualizados no
`if LSlot.Ok then` — nunca em timeout ou reply de erro. A razão: "quanto tempo o servidor
levou para responder" e "o servidor não respondeu" são perguntas diferentes, e somar um
timeout de 30s à média de latência transformaria um problema de disponibilidade num número
de performance mentiroso. `MaxRequestLatencyMs` usa um CAS loop (não um `PipeAtomicAdd64`,
que soma — aqui a operação é "troca só se for maior"), pela mesma razão que motivou
`PipeAtomicAdd64` existir: não há um `InterlockedMax64` portátil nos dois compiladores.

### 11.6 Contadores do cliente são por SESSÃO, sem cumulativo entre sessões

Mesma decisão de `FLastReadTick`/`FLastWriteTick` do heartbeat: zeram em `Connect` e em cada
`TryReopenSession` bem-sucedido (`ResetSessionStats`, chamado incondicionalmente — ao
contrário de `StartHeartbeat`, não depende de `HeartbeatIntervalMs`). Decisão explícita do
usuário ao aprovar o design: **sem** um segundo par de campos "desde sempre" ao lado do
por-sessão — o cliente é uma conexão de cada vez, e `ReconnectAttempts` já responde "por que a
sessão trocou" melhor do que um total histórico de bytes responderia.

### 11.7 Milestones

| # | Milestone | Conteúdo | Status |
|---|-----------|----------|--------|
| S0 | `Pipes.Threading` | `PipeAtomicCompareExchange64`/`PipeAtomicAdd64` (CAS loop); `TPipeThreadPool.QueueDepth` | concluído |
| S1 | `Pipes.Types` | `TPipeConnStats`/`TPipeServerStats`/`TPipeClientStats` | concluído |
| S2 | Servidor | contadores por conexão e agregados, `Stats`/`ConnectionStats` (padrão Try* de `TryClientIdentity`) | concluído |
| S3 | Cliente | contadores por sessão, latência de Request (só sucesso), `Stats` | concluído |
| S4 | Testes | bytes/mensagens batem com o enviado, `ConnectionStats` de conexão inexistente, timeout excluído da latência | concluído |

## 12. Failover de endereço (`TPipeClient.FailoverAddresses`)

Mesmo diagnóstico do heartbeat e das métricas: o alvo de produção é o PDV de loja sobre VPN
(§7, "Milestones posteriores"), e lá o servidor principal cair é um modo de falha real, não
hipotético. Até aqui `AutoReconnect` só sabia insistir no MESMO `Address`; se o principal
ficasse fora do ar por mais tempo (manutenção, queda do link da loja específica), o cliente
não tinha como alcançar um secundário sem o app derrubar e recriar o `TPipeClient` com outro
endereço — perdendo assinaturas de pub/sub, contadores de sessão e o próprio `AutoReconnect`
em voo.

### 12.1 Só no `TPipeClient` — o servidor não tem o que "falhar para"

`TPipeServer` escuta um único `Address`; failover não tem sentido do lado de quem aceita
conexões. A property fica ao lado de `AutoReconnect`/`ReconnectDelayMs`/`MaxReconnectAttempts`,
que já eram exclusivas do cliente pelo mesmo motivo.

### 12.2 `Address` continua o primário; `FailoverAddresses` é aditivo e vazio por padrão

Nenhum código existente muda de comportamento: com `FailoverAddresses` vazio,
`ConnectAnyAddress` é uma única chamada a `PipeConnect(Address, ...)`, idêntica à de antes
desta feature. Todos os endereços da lista compartilham `Transport`/`TlsOptions`/
`KeepAliveSeconds` do cliente — são locais de rede alternativos do MESMO serviço (ex.:
loja principal e DR da mesma retaguarda), não um jeito de falar com um servidor diferente
com outro protocolo ou outra credencial.

### 12.3 `Connect` divide o orçamento; `TryReopenSession` avança um endereço por tentativa

Os dois pontos que abrem conexão têm formas diferentes de gastar tempo, e o failover respeita
a forma de cada um em vez de unificar à força:

- `Connect(ATimeoutMs)` já era "re-tenta até o prazo" para UM endereço (`PipeConnect`
  interno, ver `WinPipeConnect`/`PosixPipeConnect`, retry até `ERROR_FILE_NOT_FOUND`
  parar de acontecer). Com mais de um endereço, `ConnectAnyAddress` dá voltas pela lista
  inteira com uma fatia igual de `ATimeoutMs` por endereço, repetindo até um conectar ou o
  prazo total estourar — o mesmo formato "`while true` com deadline" que já existia para um
  endereço só, um nível acima.
- `TryReopenSession` já era um laço espaçado por `ReconnectDelayMs` (o funil único de
  reabertura, §"Reconexão" no cabeçalho de `Pipes.Client.pas`); failover só acrescenta
  "endereço atual falhou → mira o próximo (com wraparound) na PRÓXIMA tentativa", sem
  orçamento próprio nem mudar o espaçamento entre tentativas.

### 12.4 Sessão DURÁVEL volta a preferir o primário

`FAddrIndex` é zerado no MESMO critério que já zera `FReconnectAttempts` — uma sessão que
durou mais que `ReconnectDelayMs` foi sessão de verdade, e a PRÓXIMA falha (se houver) deve
tentar o primário de novo antes de espalhar pelos alternativos. Sem isso, um cliente que
migrou para o secundário ficaria "grudado" nele (ou pior, avançando cegamente para o
terceiro endereço) mesmo depois do principal voltar ao ar — o teste
`Reconexao_SessaoDuravelNoBackup_VoltaAoPrimarioDepois` existe justamente para travar essa
diferença contra o "avança pro próximo" ingênuo.

### 12.5 `MaxReconnectAttempts`/`ReconnectDelayMs` continuam por TENTATIVA, não por endereço

O teto e o espaçamento não ganharam um orçamento separado por endereço: cada chamada a
`PipeConnect` — mire ela o primário ou um alternativo — continua contando como UMA tentativa
para `MaxReconnectAttempts`, e o intervalo entre tentativas continua o mesmo
`ReconnectDelayMs`, não importa se a próxima mira o mesmo endereço ou um diferente. Trocar de
endereço "na hora" (sem esperar o espaçamento) foi considerado e descartado: mais um estado a
raciocinar numa unit que o próprio cabeçalho já trata como apertada em invariantes, por um
ganho marginal.

### 12.6 Nenhuma mudança no wire format (NPF1) nem no lado do servidor

Failover é inteiramente uma decisão de QUAL ENDEREÇO DISCAR, resolvida antes de qualquer
frame trafegar — `Pipes.Framing`, `Pipes.Server.pas` e o protocolo no fio ficam intocados.
`ActiveAddress` (snapshot, mesmo molde de `ClientCount`/`Stats`) é a única forma de o app
saber qual endereço a sessão atual usa, já que `TPipeConnectionEvent`
(`OnConnected`/`OnDisconnected`) não ganhou parâmetro novo — mudar aquela assinatura afetaria
todo o resto da lib por um dado que a property já resolve sem quebrar nada em uso.

### 12.7 Milestones

| # | Milestone | Conteúdo | Status |
|---|-----------|----------|--------|
| F0 | `Pipes.Client` | `FailoverAddresses`/`ActiveAddress`, `FAddrIndex`, `AddressAt`/`AddressCount` | concluído |
| F1 | `Connect` | `ConnectAnyAddress` (volta pela lista, orçamento dividido por `ATimeoutMs`) | concluído |
| F2 | `TryReopenSession` | avança um endereço por tentativa falha; reseta ao primário em sessão DURÁVEL | concluído |
| F3 | Testes | primário vivo/morto em `Connect`, migração na reconexão, reset ao primário após sessão durável, `MaxReconnectAttempts` compartilhado entre endereços | concluído |
