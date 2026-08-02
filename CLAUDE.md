# pascal-pipes-faa

> Antes `pascal-named-pipes-faa`. Renomeado quando o Named Pipe do Windows deixou de ser o
> único transporte — ver `Transport` abaixo e `README.md`, seção "Compatibilidade com a API
> anterior".

Biblioteca multiplataforma de comunicação entre processos para **Delphi 12+ (Win64 e
Android)** e **FPC 3.2.2 / Lazarus (Linux x86_64 e ARM64)**. API de alto nível (`TPipeServer`/
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
  (POSIX e Windows opt-in; **Android sem opt-in** — não há Schannel lá), com mTLS
  suportado nos dois backends. Milestones T0-T5 em `docs/ARQUITETURA.md`.
- **Backend Android (`PIPES_ANDROID`, milestones A0-A3):** terceiro eixo de plataforma, só
  `ptTcp`/`ptTls` (`ptLocal` é recusado com mensagem própria). `Pipes.Transport.Android.pas`
  usa as units `Posix.*` da RTL do Delphi + `poll()` declarado localmente, e a interrupção
  de leitura é **self-pipe + poll, idêntica ao backend Linux** — NÃO `TSocket.Close`, que
  fecharia o fd de outra thread. `pipes.inc` testa `ANDROID` ANTES de cair em
  `PIPES_POSIX` (que é FPC-only). Duas armadilhas registradas: o `addrinfo` do bionic tem
  `ai_canonname` antes de `ai_addr` (ao contrário do glibc — por isso o backend usa o
  `Posix.NetDB` e não o `TPipeAddrInfo` de `Tcp.pas`), e o trust store padrão do OpenSSL
  não existe no Android. Racional completo em `docs/ARQUITETURA.md` §13, incluindo §13.7
  com o que a implementação inverteu em relação à proposta do spike.
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
SendBytes/SendText por ConnId (com `AGroupKey` opcional — ordem de entrega entre
mensagens da mesma chave em `pdmPool`, ver abaixo), SendBytesBatch (N mensagens, um
Write só, ordem preservada), Broadcast, DisconnectClient, ClientCount/ClientIds
(só conexões estabelecidas), TryClientIdentity (identidade do par mTLS), MaxClients,
OnClientConnected/Disconnected, OnRequest, Stats/ConnectionStats — métricas, ver abaixo)
e `TPipeClient` (Connect, Disconnect, SendBytes/SendText (idem `AGroupKey`), SendBytesBatch,
Request/RequestText síncrono com timeout, AutoReconnect, MaxReconnectAttempts,
FailoverAddresses/ActiveAddress — failover, ver abaixo —, OnConnected/OnDisconnected, Stats).
Assinaturas completas e exemplos em `README.md`; racional de design em
`docs/ARQUITETURA.md`.

Ordem por grupo em `pdmPool` (milestone informal, `docs/ARQUITETURA.md` §15):
`SendBytes`/`SendText` aceitam `AGroupKey: string = ''` — mensagens da mesma chave chegam
ao `OnMessage` do RECEPTOR em ordem entre si mesmo em `pdmPool` (que por padrão não
garante ordem de entrega entre mensagens distintas, só no fio), sem perder paralelismo
entre chaves diferentes. Mecanismo: `Pipes.Threading.TPipeKeyedDispatcher` — mailbox por
chave com dono cooperativo (nenhum worker fixo, nenhum teto de chaves para configurar),
por cima do `TPipeThreadPool` já existente, sem mexer nele. A chave viaja no `CorrId` do
header NPF1 (hash de 64 bits via `PipeGroupKeyHash`) — campo que já existia e que
`pfkMessage` nunca usava, então zero mudança de wire format. Só afeta `pdmPool`;
`pdmSerialized`/`pdmMainThread` já dão ordem total e ignoram a chave.

Failover de endereço (milestones F0-F3, `docs/ARQUITETURA.md` §12): `Client.FailoverAddresses:
TArray<string>` — endereços tentados em ordem DEPOIS de `Address` (o primário), com o mesmo
`Transport`/`TlsOptions`/`KeepAliveSeconds`; vazio por padrão (nenhuma mudança de
comportamento). `Connect` divide `ATimeoutMs` entre os endereços da lista; a reconexão
automática avança um endereço por tentativa que falha e volta a preferir o primário quando
uma sessão é DURÁVEL (mesmo critério que já zera `MaxReconnectAttempts`). Só no cliente — o
servidor escuta um único `Address`. `Client.ActiveAddress` (snapshot) diz qual endereço a
sessão atual usa.

Métricas/observabilidade (milestones S0-S4, `docs/ARQUITETURA.md` §11): `Server.Stats:
TPipeServerStats` (agregado cumulativo desde o Listen) e `Server.ConnectionStats(ConnId,
out): Boolean` (por conexão, morre com ela — padrão Try* de `TryClientIdentity`) e
`Client.Stats: TPipeClientStats` (da SESSÃO atual, zera a cada reconexão, sem contador
cumulativo entre sessões). Snapshot sob demanda, mesmo molde de `ClientCount`/
`Subscriptions` — NÃO é um evento periódico. Sempre ativos, sem opt-in (custo de um
`PipeAtomicAdd64` por frame). `PoolQueueDepth` é o backlog do pool GLOBAL em `pdmPool`,
não só deste servidor — só é exclusivo dele em `pdmSerialized`. Latência de Request só
conta o caminho de SUCESSO (timeout e erro ficam de fora).

`TPipeDispatchMode`: `pdmPool` (padrão), `pdmSerialized` (pool de 1 worker, ordem FIFO),
`pdmMainThread` (TThread.Queue — apps VCL/LCL).

`TPipeTransportKind`: `ptLocal` (padrão, Named Pipe/UDS), `ptTcp`, `ptTls` (mTLS opcional
via `TlsOptions`).

Pub/sub: servidor `Publish/PublishText` (com `ARetain`), `PublishBatch` (N itens
`TPipePublishItem` — Topic/Payload/Retain —, um Write por conexão, só para quem
casa cada item), `SubscriberCount`, `ClientSubscriptions`, `ClearRetained`,
`RelayClientPublish` (default **False**), `MaxSubscriptionsPerClient`, `MaxRetained`,
`OnPublish`/`OnSubscribe`/`OnUnsubscribe`; cliente `Subscribe`/`Unsubscribe` (funcionam
desconectado), `Subscriptions`, `Publish`, `PublishBatch`, `OnTopicMessage`. Filtros:
`.` separa, `*` = um segmento, `#` = o resto (só no fim).
`TPipeTopicEvent` termina em `ARetained: Boolean`, e o sentido dele MUDA por lado: no
cliente, "veio do cache de retidos" (ao vivo é sempre False, mesmo com retain pedido — ver
`docs/ARQUITETURA.md` §9.7); no servidor, "o cliente pediu para reter".

## Estrutura de units

```
src/pipes.inc                    src/Pipes.Threading.pas       src/Pipes.Types.pas
src/Pipes.Base.pas                src/Pipes.Framing.pas         src/Pipes.Transport.pas
src/Pipes.Topics.pas             (pub/sub: nomes, curingas, envelope — unit PURA)
src/Pipes.Transport.Windows.pas  src/Pipes.Transport.Posix.pas
src/Pipes.Transport.Android.pas  (Delphi/Android: ptTcp/ptTls sobre Posix.* + poll)
src/Pipes.Transport.Tcp.pas      src/Pipes.Transport.Tls.pas
src/Pipes.Transport.Schannel.pas src/Pipes.Transport.OpenSSL.pas
src/Pipes.Client.pas             src/Pipes.Server.pas
src/Pipes.Json.pas                (bytes<->JSON OPCIONAL: System.JSON/fpjson — ver README.md)
tests/Unit (Threading/Framing/Topics/Address)
  + tests/Integration (Transport/EndToEnd/PubSub/Stress/Tls/Heartbeat/Stats/Json)
  — DUnit e fpcunit, layout espelhado do pascal-amqp-faa
tests/Android (suite de DEVICE do backend Android; FMX, loopback, sem par dual-compiler)
samples/ (17 amostras — ver README.md)  docs/ARQUITETURA.md  README.md
Pipes.groupproj (grupo Delphi) + Pipes.lpg (grupo Lazarus) na raiz
```

Todo `.dproj`/`.lpi` novo (teste, sample) deve ser registrado nos DOIS grupos da
raiz: `Pipes.groupproj` (Projects + Targets + CallTarget de Build/Clean/Make) e
`Pipes.lpg` (Target com BuildModes), como no pascal-amqp-faa. **Exceção: projetos
Android** (`tests/Android`, `samples/EchoAndroid`) entram no `Pipes.groupproj` com alvo
próprio mas FORA dos CallTarget agregados — são os únicos que não compilam para Win64, e
um grupo inteiro não deve falhar em quem não tem o SDK do Android. Não têm `.lpi`: o FPC
não compila para Android neste projeto.

## Milestones e agente recomendado (economia de tokens)

Todos os milestones abaixo — M0-M8 (escopo original, `ptLocal`), T0-T5 (`ptTcp`/`ptTls`) e
P0-P4 (pub/sub por tópico), os dois últimos grupos detalhados em `docs/ARQUITETURA.md` §7 e
§9 — estão **concluídos**. A tabela fica como referência de sequenciamento e alocação de
agente para o próximo milestone que surgir, não como trabalho pendente.

**A0-A3 (Delphi Android) estão verificados em aparelho real**: `tests/Android` roda
11 ok / 0 falhas / 0 pulados. O desbloqueio de leitura mede milissegundos de um dígito
(teto 250 ms), confirmando que o self-pipe + `poll` acorda por evento também no Android.
Fechar A2 revelou um bug de portabilidade real — validação por IP-SAN quebrada no OpenSSL
1.1.1, que o desktop (3.x) mascarava; ver `docs/ARQUITETURA.md` §13.9. Números da rodada
em §13.8, e §13.10 registra as quatro formas de um teste negativo de TLS passar sem provar
nada, todas encontradas nessa verificação.

O Delphi CE desta máquina recusa build por linha de comando (inclusive `dccaarm64`), então
qualquer nova verificação Android continua sendo manual, pelo IDE + aparelho.

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
| S0-S4 | Métricas/observabilidade: `Stats`/`ConnectionStats`, `PipeAtomicAdd64`, latência de Request — ver `docs/ARQUITETURA.md` §11 | sonnet | concluído |
| F0-F3 | Failover de endereço (só `TPipeClient`): `FailoverAddresses`/`ActiveAddress`, `Connect` dividindo orçamento entre endereços, reconexão avançando por tentativa e voltando ao primário em sessão durável — ver `docs/ARQUITETURA.md` §12 | sonnet | concluído |
| A0-A3 | Delphi Android (`ptTcp`/`ptTls`, `ptLocal` fora de escopo): define `PIPES_ANDROID`, backend sobre as units `Posix.*` + `poll` (self-pipe, igual ao Linux), TLS via OpenSSL sem opt-in, `samples/EchoAndroid` + `tests/Android` — ver `docs/ARQUITETURA.md` §13 | opus | concluído, verificado em device (11/11) |

Dependências: M0 → M1 → M2 → (M3 ‖ M4) → M5 → M6 → M7 → M8 → (T0 → T1 → (T2 ‖ T3) → T4 → T5).
A0-A3 dependem de T5 (concluído) mas são um eixo à parte, independente de P0-P5/H0-H4/
S0-S4/F0-F3.

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
`Disconnect` com heartbeat ativo concluindo em < 2s. S0-S4 exigem: bytes/mensagens
contados batem exatamente com o que foi enviado (servidor e cliente), `ConnectionStats`
de uma conexão inexistente devolve `False`, e um Request que estoura o timeout NÃO entra
na latência média/máxima (só o caminho de sucesso conta). F0-F3 exigem: `Connect` alcança
um endereço da lista mesmo com o primário fora do ar, reconexão automática migra para um
alternativo quando o primário cai em definitivo, uma sessão DURÁVEL num alternativo faz a
PRÓXIMA falha voltar a preferir o primário (não só avançar para o próximo da lista), e
`MaxReconnectAttempts` conta tentativas contra QUALQUER endereço num teto só, não um por
endereço.

A0-A3 não têm par dual-compiler tradicional — FPC não compila para Android neste projeto,
e o Delphi CE desta máquina não compila por linha de comando. O que a máquina de
desenvolvimento garante: FPC/Win64 e FPC/Linux verdes (A0 mexeu no `pipes.inc`, que todo
mundo inclui) e `Pipes.Transport.Tls.pas` compilando no FPC com `-dPIPES_OPENSSL` (o ramo
que A2 alterou). O resto é em device/emulador real, rodando `tests/Android` — que já
implementa cada critério e imprime os números medidos: `CloseAbort` destrava um `Read`
bloqueado em outra thread em **milissegundos** (o caso reprova acima de 250ms, que é o que
separa "acordou por evento" de "acordou por timeout de recv"), inclusive com o app tendo
passado por segundo plano; certificado de CA desconhecida/auto-assinado sob mTLS têm
veredito correto e distinto no backend OpenSSL (mesmo critério de T4/T5); e `Stop`/
`Disconnect` concluem em < 2s com conexão ociosa e sob tráfego intenso — mesmo teto usado
por M7/H0-H4.
