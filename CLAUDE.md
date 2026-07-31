# pascal-pipes-faa

> Antes `pascal-named-pipes-faa`. Renomeado quando o Named Pipe do Windows deixou de ser o
> único transporte — ver `Transport` abaixo e `README.md`, seção "Compatibilidade com a API
> anterior".

Biblioteca multiplataforma de comunicação entre processos para **Delphi 12+ (Win64)** e
**FPC 3.2.2 / Lazarus (Linux x86_64 e ARM64)**. API de alto nível (`TPipeServer`/
`TPipeClient`) que abstrai totalmente as chamadas nativas do SO, com três alcances
selecionados pela property `Transport`: `ptLocal` (Named Pipe/UDS, padrão), `ptTcp`
(rede) e `ptTls` (rede não confiável, com mTLS opcional). Racional de design completo em
`docs/ARQUITETURA.md` (histórico de *por quê*); estado atual da API com exemplos em
`README.md` (fonte de verdade para *o que existe hoje*) — leia os dois antes de
implementar qualquer milestone novo.

## Decisões arquiteturais (fechadas — não rediscutir sem o usuário)

- **Backend Windows (`ptLocal`):** Named Pipes reais (`CreateNamedPipe`/`ConnectNamedPipe`),
  modo byte (`PIPE_TYPE_BYTE`), sempre com `FILE_FLAG_OVERLAPPED`. Nunca I/O síncrono
  blocante.
- **Backend Linux (`ptLocal`):** Unix Domain Sockets (`AF_UNIX`) — equivalente semântico do
  Named Pipe do Windows. FIFOs (`mkfifo`) estão FORA de escopo (a camada
  `Pipes.Transport.pas` abstrata deixa a porta aberta para um backend FIFO futuro).
- **Framing próprio** (length-prefix, header de 20 bytes com magic `NPF1`, kind, corrId,
  length) idêntico em todos os transportes (`ptLocal`/`ptTcp`/`ptTls`). Não depender de
  `PIPE_READMODE_MESSAGE`.
- **Threading:** cópia renomeada de `AMQP.Threading.pas` (do projeto
  `..\pascal-amqp-faa\src\`) como `Pipes.Threading.pas` — prefixos `TPipe*`/`Pipe*`.
  Sem dependência entre repositórios.
- **Backend `ptTcp`:** socket TCP nos dois OS, keepalive ligado por padrão
  (`KeepAliveSeconds`). Adicionado depois do M8 para o caso de PDVs de loja sobre VPN
  (ver `docs/ARQUITETURA.md`, "Milestones posteriores").
- **Heartbeat de aplicação (`HeartbeatIntervalMs`, milestones H0-H4):** só `ptTcp`/`ptTls`
  (`ptLocal` ignora, mesma razão de `KeepAliveSeconds`). Simétrico e sem correlação — usa
  o `pfkPing` (kind 3) já reservado no NPF1 desde o M2, sem `pfkPong`: qualquer frame
  recebido reseta o relógio de leitura do peer. Morte = sem NENHUM frame recebido há mais
  de 2x o intervalo; quem detecta chama `CloseAbort` (mecanismo já existente,
  thread-safe/idempotente) e segue o teardown normal — nenhuma interrupção nova foi
  inventada. Racional completo em `docs/ARQUITETURA.md` §10.
- **Backend `ptTls`:** TCP + TLS via `Pipes.Transport.Tls.pas`, fachada neutra que delega
  a `Pipes.Transport.Schannel.pas` (Windows, SSPI nativo) ou `Pipes.Transport.OpenSSL.pas`
  (POSIX e Windows opt-in), com mTLS suportado nos dois backends. Milestones T0-T5 em
  `docs/ARQUITETURA.md`.
- **Pub/sub (`Pipes.Topics.pas`, milestones P0-P4):** roteamento por tópico sobre a conexão
  viva — NÃO é broker (sem durabilidade, ack, QoS ou fila; isso é o `pascal-amqp-faa`).
  Kinds 4-6 do NPF1, tópico no INÍCIO DO PAYLOAD (nunca nos bytes Reserved, senão `Length`
  deixa de cobrir o frame e peer antigo sai de sincronia). Racional completo em
  `docs/ARQUITETURA.md` §9. Duas decisões que não se rediscutem sem ler §9.2 e §9.3:
  **toda decisão de roteamento é código puro na reader thread** (callbacks de pub/sub são
  notificações, nunca vetos — veto no pool reordenaria publicações do mesmo cliente), e
  **a lista de filtros vive na conexão sob `FConnLock`**, não em tabela global
  `tópico → conexões` (é o que faz a assinatura morrer com a conexão, sem vazamento).

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
   - Windows (`ptLocal`): `ReadFile`/`ConnectNamedPipe` overlapped + `WaitForMultipleObjects
     ([hIo, hStop])`; Stop = `SetEvent(hStop)` → `CancelIoEx` → fechar handle → `WaitFor`.
   - Linux (`ptLocal`/`ptTcp`): `fpPoll([fd, fdStopSelfPipe])`; Stop = escrever no self-pipe
     → `fpShutdown` → `fpClose` → `WaitFor`. Escrever sempre com `MSG_NOSIGNAL` (SIGPIPE mata
     o processo). Socket TCP reaproveita o mesmo mecanismo (é o mesmo fd que um UDS).
   - Windows (`ptTcp`): sem Named Pipe overlapped para socket; `WSAEventSelect` associa o
     socket a um `WSAEVENT`, espera é `WSAWaitForMultipleEvents([hSock, hStop])`.
   - `ptTls`: reaproveita a interrupção do TCP de baixo — abortar o endpoint TCP propaga
     `EPipeClosed` através da decifragem, sem estado próprio a desarmar no adaptador TLS.
5. Encerramento: sinalizar todos → join de todos → drenar in-flight → liberar. Nunca
   `TerminateThread`. Destructor idempotente chama Stop/Disconnect.
6. `pdmMainThread` usa `TThread.Queue` (nunca `Synchronize` a partir do reader) com
   objeto-guarda refcounted invalidado no destroy.
7. Pub/sub: frames de controle (subscribe/unsubscribe) e publicações de cliente são
   tratados NA reader thread — inclusive as escritas de volta (recusa, valores retidos).
   Isso é permitido porque não roda código de usuário; o casamento de tópico
   (`PipeTopicMatches`) roda sob `FConnLock` e por isso não pode alocar nem fazer IO.
   O cliente reenvia as assinaturas em `TryReopenSession` ANTES de `OnConnected`; nunca
   segure `FSubLock` do cliente enquanto pega `FWriteLock`.

## API pública (resumo)

`TPipeBase` (abstrata: Address, Transport, TlsOptions, KeepAliveSeconds,
HeartbeatIntervalMs, Active, DispatchMode, MaxMessageSize, OnMessage, OnError) →
`TPipeServer` (Listen, Stop,
SendBytes/SendText por ConnId, Broadcast, DisconnectClient, ClientCount/ClientIds
(só conexões estabelecidas), TryClientIdentity (identidade do par mTLS), MaxClients,
OnClientConnected/Disconnected, OnRequest) e `TPipeClient` (Connect, Disconnect,
SendBytes/SendText, Request/RequestText síncrono com timeout, AutoReconnect,
MaxReconnectAttempts, OnConnected/OnDisconnected). Assinaturas completas e exemplos em
`README.md`; racional de design em `docs/ARQUITETURA.md`.

`TPipeDispatchMode`: `pdmPool` (padrão), `pdmSerialized` (pool de 1 worker, ordem FIFO),
`pdmMainThread` (TThread.Queue — apps VCL/LCL).

`TPipeTransportKind`: `ptLocal` (padrão, Named Pipe/UDS), `ptTcp`, `ptTls` (mTLS opcional
via `TlsOptions`).

Pub/sub: servidor `Publish/PublishText` (com `ARetain`), `SubscriberCount`,
`ClientSubscriptions`, `ClearRetained`, `RelayClientPublish` (default **False**),
`MaxSubscriptionsPerClient`, `MaxRetained`, `OnPublish`/`OnSubscribe`/`OnUnsubscribe`;
cliente `Subscribe`/`Unsubscribe` (funcionam desconectado), `Subscriptions`, `Publish`,
`OnTopicMessage`. Filtros: `.` separa, `*` = um segmento, `#` = o resto (só no fim).
`TPipeTopicEvent` termina em `ARetained: Boolean`, e o sentido dele MUDA por lado: no
cliente, "veio do cache de retidos" (ao vivo é sempre False, mesmo com retain pedido — ver
`docs/ARQUITETURA.md` §9.7); no servidor, "o cliente pediu para reter".

## Estrutura de units

```
src/pipes.inc                    src/Pipes.Threading.pas       src/Pipes.Types.pas
src/Pipes.Base.pas                src/Pipes.Framing.pas         src/Pipes.Transport.pas
src/Pipes.Topics.pas             (pub/sub: nomes, curingas, envelope — unit PURA)
src/Pipes.Transport.Windows.pas  src/Pipes.Transport.Posix.pas
src/Pipes.Transport.Tcp.pas      src/Pipes.Transport.Tls.pas
src/Pipes.Transport.Schannel.pas src/Pipes.Transport.OpenSSL.pas
src/Pipes.Client.pas             src/Pipes.Server.pas
tests/Unit (Threading/Framing/Topics/Address)
  + tests/Integration (Transport/EndToEnd/PubSub/Stress/Tls/Heartbeat)
  — DUnit e fpcunit, layout espelhado do pascal-amqp-faa
samples/ (14 amostras — ver README.md)  docs/ARQUITETURA.md  README.md
Pipes.groupproj (grupo Delphi) + Pipes.lpg (grupo Lazarus) na raiz
```

Todo `.dproj`/`.lpi` novo (teste, sample) deve ser registrado nos DOIS grupos da
raiz: `Pipes.groupproj` (Projects + Targets + CallTarget de Build/Clean/Make) e
`Pipes.lpg` (Target com BuildModes), como no pascal-amqp-faa.

## Milestones e agente recomendado (economia de tokens)

Todos os milestones abaixo — M0-M8 (escopo original, `ptLocal`), T0-T5 (`ptTcp`/`ptTls`) e
P0-P4 (pub/sub por tópico), os dois últimos grupos detalhados em `docs/ARQUITETURA.md` §7 e
§9 — estão **concluídos**. A tabela fica como referência de sequenciamento e alocação de
agente para o próximo milestone que surgir, não como trabalho pendente.

| # | Milestone | Agente | Status |
|---|-----------|--------|--------|
| M0 | Bootstrap (git, pastas, pipes.inc, projetos de teste compilando) | haiku | concluído |
| M1 | Pipes.Threading.pas (cópia/rename) + testes de fumaça | haiku + revisão sonnet | concluído |
| M2 | Pipes.Types + Pipes.Framing + testes unitários | sonnet | concluído |
| M3 | Transporte Windows (overlapped, CancelIoEx, multi-instância) | opus | concluído |
| M4 | Transporte Linux (UDS, fpPoll, self-pipe) | opus | concluído |
| M5 | Server/Client alto nível (acceptor, readers, dispatch, drain) | opus + revisão fable | concluído |
| M6 | Request-Reply, Broadcast, AutoReconnect, pdmMainThread | sonnet + revisão opus | concluído |
| M7 | Testes de integração (stress de Stop, queda abrupta) dual-OS | sonnet | concluído |
| M8 | Samples (echo console, chat VCL/LCL) + README | haiku | concluído |
| T0-T5 | `ptTcp`/`ptTls`, mTLS, samples seguros — ver tabela em `docs/ARQUITETURA.md` §7 | opus/sonnet | concluído |
| P0-P5 | Pub/sub por tópico (`Pipes.Topics`, fanout, retain, replay na reconexão, samples `PainelLoja` e `MonitorTopicos`) — ver `docs/ARQUITETURA.md` §9 | opus | concluído |
| H0-H4 | Heartbeat de aplicação (`ptTcp`/`ptTls`): `TPipeFrame.Ping`, `TPipeHeartbeatThread`, `HeartbeatIntervalMs`, detecção de zumbi nos dois sentidos — ver `docs/ARQUITETURA.md` §10 | sonnet | concluído |

Dependências: M0 → M1 → M2 → (M3 ‖ M4) → M5 → M6 → M7 → M8 → (T0 → T1 → (T2 ‖ T3) → T4 → T5).

## Verificação por milestone

Compilar em ambos (dcc64 e fpc) + suíte de testes verde nos dois. P0-P4 exigem, além do
fanout correto: assinatura que NÃO sobrevive à queda abrupta da conexão (teste com endpoint
cru que desaparece sem despedida), `Stop` sob publicação intensa em < 2s, e reassinatura
automática após reconexão **sem o app reassinar nada**. M7 exige: Stop durante
tráfego intenso conclui em < 2s (detector de deadlock) e queda abrupta de cliente dispara
OnClientDisconnected sem vazar handle/fd. T4/T5 exigem além disso: certificado de CA
desconhecida e certificado auto-assinado sob mTLS têm veredito correto e distinto (ver
`docs/ARQUITETURA.md` §7, nota sobre `VerifyClientChain`) em Schannel e OpenSSL. H0-H4
exigem: zumbi (endpoint cru que aceita e nunca mais fala nada, sem FIN) detectado nos dois
sentidos dentro de ~2x `HeartbeatIntervalMs`, `ptLocal` imune à property, e `Stop`/
`Disconnect` com heartbeat ativo concluindo em < 2s.
