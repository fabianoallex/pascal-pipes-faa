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
- **Compressão de payload (`CompressionMinSize`, `Pipes.Compression.pas`):** deflate opcional
  via `System.ZLib`/`paszlib`, zero dependência nova nos dois compiladores. `pfkCompressed`
  (kind 7 do NPF1) é um KIND novo, não um bit de `Flags` — um peer desatualizado recebendo um
  bit de `Flags` desconhecido em `pfkMessage`/`pfkRequest`/`pfkReply` (kinds que ele já
  entende) processaria o frame normalmente e entregaria deflate cru ao app; um kind novo cai
  no "kind desconhecido" que `PipeReadFrame` já usa, o mesmo diagnóstico alto e claro de
  P0-P4. `CompressionMinSize = 0` (padrão) desliga só a PRODUÇÃO local; a decodificação de
  frames comprimidos recebidos é sempre ativa. `Stats`/`MaxMessageSize` sempre olham o
  payload ORIGINAL, nunca o comprimido; a descompressão tem teto de zip bomb verificado
  DURANTE a decodificação (streaming), não só no resultado final. Racional completo em
  `docs/ARQUITETURA.md` §17.
- **Roteador de comandos por nome (`Pipes.Commands.pas`):** unit OPCIONAL, por CIMA de
  `OnMessage` — `TPipeCommandRouter.HandleMessage` tem a mesma assinatura de
  `TPipeMessageEvent`, sem kind novo no NPF1 (o nome do comando é conteúdo de aplicação, não
  protocolo de transporte, diferente de Pub/Sub e Compressão). Envelope reaproveita o layout
  binário de `Pipes.Topics` (u16 LE + UTF-8 + corpo) como função PRÓPRIA, não importada — são
  domínios diferentes, só a forma coincide. `RegisterCommand` levanta `EPipeCommandError` na
  hora (nome/limites inválidos, handler nil, comando duplicado — erro de programação);
  `HandleMessage` NUNCA levanta — comando desconhecido e payload fora da faixa
  `AMinSize`/`AMaxSize` caem em `OnUnknownCommand`/`OnInvalidPayload`, opcionais e
  silenciosos, porque uma exceção ali seria engolida em silêncio pelo pool sem chegar a
  `OnError` (mesmo contrato de qualquer bug dentro do `OnMessage` do próprio dev). O mesmo
  router também cobre o lado request-reply (`RegisterRequestCommand`/`HandleRequest`,
  registro PRÓPRIO, independente do de mensagem — mesmo nome pode existir nos dois sem
  conflito, já que `OnMessage`/`OnRequest` chegam por kinds diferentes do NPF1) com contrato
  de erro OPOSTO de propósito: `HandleRequest` LEVANTA (`EPipeProtocol`) em vez de eventos,
  porque `TPipeServer.ExecuteRequest` já transforma qualquer exceção do `OnRequest` em reply
  de erro pro cliente — reaproveitar isso é mais simples do que inventar um "silêncio" que
  não existe no request-reply (`Request` sempre recebe alguma resposta). Racional completo
  em `docs/ARQUITETURA.md` §18, incluindo §18.8 para o lado request-reply.
- **Endereço do cliente (`TPipeServer.TryClientAddress`):** `TryPeerAddress` no contrato
  abstrato `TPipeEndpoint` (`Pipes.Transport.pas`), mesmo padrão de `TryPeerIdentity` —
  `False` por padrão, sobrescrito onde faz sentido. `ptLocal` (Named Pipe/UDS) sempre `False`
  (sem endereço de rede); `ptTcp`/`ptTls` devolvem `'ip:porta'` via `getpeername`, com layout
  de `sockaddr` declarado à mão (`TPipeRawSockAddrIn`/`In6`/`Storage` em
  `Pipes.Transport.pas`, reaproveitado por Windows e POSIX) pelo mesmo motivo de
  `TPipeAddrInfo` já existir: cada compilador tipa `sockaddr` de um jeito incompatível com o
  outro. No POSIX a MESMA classe (`TPipePosixEndpoint`) serve UDS e TCP; a família devolvida
  por `getpeername` (`AF_INET`/`AF_INET6` vs. `AF_UNIX`) já é o discriminador, sem subclasse
  nova. `FAddresses`/`FAddressOrder` em `Pipes.Server.pas` espelham `FIdentities`/
  `FIdentityOrder` (mesmo teto `PIPES_RECENT_IDENTITIES`, mesma sobrevivência a
  `OnClientDisconnected`) — duplicado de propósito, não generalizado num cache único.
  Windows e POSIX/Linux implementados e com `TryPeerAddress` verificado em FPC/Win64 +
  Delphi/DUnitX; POSIX compila mas não foi executado (sem toolchain Linux nesta máquina,
  mesma limitação de §16); Android fica fora desta rodada. Racional completo em
  `docs/ARQUITETURA.md` §19.
- **Connect assíncrono (`TPipeClient.ConnectAsync`, milestone CONN0):** cobre "o app sobe
  ANTES do servidor" — o buraco entre `Connect` (bloqueia e falha no prazo) e
  `AutoReconnect` (só entra depois de uma sessão ter existido e caído, porque quem o dispara
  é `ReaderFinished`). NÃO tem thread nem máquina de estados própria: liga
  `FConnectingAsync` e dispara a MESMA `TPipeReconnectThread`, porque `TryReopenSession` já
  É "conectar até o servidor responder, com espaçamento, teto e failover" — a mesma OPERAÇÃO
  com outra origem (o oposto de `ADDR0`, onde duplicar foi certo por serem dois DADOS
  independentes). Todo o ponto de contato é `ReopenAllowed` (`FAutoReconnect OR
  FConnectingAsync`), aplicado nos DOIS gates de `TryReopenSession` — esquecer o segundo (a
  rechecagem com a conexão já aberta) descartaria em silêncio o endpoint recém-conectado
  quando `AutoReconnect = False`. A limpeza de `FConnectingAsync` vive em
  `TPipeReconnectThread.Execute` (só quem detém o ciclo limpa) e em `Disconnect`, NUNCA em
  `TryReopenSession`: limpar junto com `FReconnecting` quebraria o par que "aceita e derruba"
  (mTLS/SChannel) com `AutoReconnect = False`. Sem parâmetro de timeout — o orçamento é
  `MaxReconnectAttempts` × `ReconnectDelayMs`, e o esgotamento vai para `OnError` com
  mensagem própria ("conexao inicial esgotada"), não como exceção. `EnsureInactive` passou a
  consultar `GetLifecycleLocked` (virtual novo em `TPipeBase`, default `GetActive`) para que
  `Connecting` também trave `Address`/`Transport`/`TlsOptions`. NENHUMA mudança em
  `Pipes.Transport.*`: cancelar herda o mesmo trade-off que `WaitReconnectDone` já aceita
  (espera até `ReconnectDelayMs` do `PipeConnect` em curso). Racional completo em
  `docs/ARQUITETURA.md` §21.

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
HeartbeatIntervalMs, Active, DispatchMode, MaxMessageSize, CompressionMinSize, OnMessage,
OnError) →
`TPipeServer` (Listen, Stop,
SendBytes/SendText por ConnId (com `AGroupKey` opcional — ordem de entrega entre
mensagens da mesma chave em `pdmPool`, ver abaixo), SendBytesBatch (N mensagens, um
Write só, ordem preservada), Broadcast, DisconnectClient, ClientCount/ClientIds
(só conexões estabelecidas), TryClientIdentity (identidade do par mTLS),
TryClientAddress ('ip:porta' em ptTcp/ptTls, False em ptLocal — ver §19), MaxClients,
OnClientConnected/Disconnected, OnRequest, Stats/ConnectionStats — métricas, ver abaixo)
e `TPipeClient` (Connect, ConnectAsync/Connecting — connect não-bloqueante, ver abaixo —,
Disconnect, SendBytes/SendText (idem `AGroupKey`), SendBytesBatch,
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

Descoberta de servidor na LAN (milestone D0, `docs/ARQUITETURA.md` §16): `Pipes.Discovery`,
unit paralela FORA da hierarquia `TPipeBase` — `TPipeDiscoveryResponder` (servidor anuncia
porta/transporte/nome numa porta UDP de descoberta) + `PipeDiscoverServers` (cliente sonda
por broadcast e coleta respostas unicast; forma dirigida aceita literal IPv4). Protocolo
NPD1 próprio (não NPF1), comprimentos estritos, IPv4/broadcast apenas (multicast e IPv6
fora de escopo). Três decisões que não se rediscutem sem ler §16: o IP do resultado vem do
ENVELOPE (origem do recvfrom), nunca do payload (multi-NIC); descoberta ENCONTRA e ptTls
AUTENTICA (token é discriminador, não segurança); e `ptUdp` como transporte foi avaliado e
rejeitado — UDP só é aceitável neste recorte porque o protocolo é idempotente por natureza.

Métricas/observabilidade (milestones S0-S4, `docs/ARQUITETURA.md` §11): `Server.Stats:
TPipeServerStats` (agregado cumulativo desde o Listen) e `Server.ConnectionStats(ConnId,
out): Boolean` (por conexão, morre com ela — padrão Try* de `TryClientIdentity`) e
`Client.Stats: TPipeClientStats` (da SESSÃO atual, zera a cada reconexão, sem contador
cumulativo entre sessões). Snapshot sob demanda, mesmo molde de `ClientCount`/
`Subscriptions` — NÃO é um evento periódico. Sempre ativos, sem opt-in (custo de um
`PipeAtomicAdd64` por frame). `PoolQueueDepth` é o backlog do pool GLOBAL em `pdmPool`,
não só deste servidor — só é exclusivo dele em `pdmSerialized`. Latência de Request só
conta o caminho de SUCESSO (timeout e erro ficam de fora). `BytesSentWire`/
`BytesReceivedWire` (irmãos aditivos de `BytesSent`/`BytesReceived`, entraram junto com C0
— ver `docs/ARQUITETURA.md` §17.6) são o que de fato passou pelo fio; os originais continuam
sendo o payload lógico, sem mudança de significado.

Compressão de payload (milestone C0, `docs/ARQUITETURA.md` §17): `CompressionMinSize:
Cardinal` (em `TPipeBase`, 0 = desligado por padrão) — deflate opcional via
`Pipes.Compression.pas` (`System.ZLib`/`paszlib`, zero dependência nova) quando o payload
de `SendBytes`/`SendText`/`Request`/`Publish` (e as versões em lote) alcança o mínimo E
comprime de fato menor. Liga só a PRODUÇÃO local; a decodificação de `pfkCompressed` (kind 7
do NPF1) recebido do peer é sempre ativa. `Stats`/`MaxMessageSize` sempre olham o payload
ORIGINAL, nunca o comprimido — a descompressão tem teto de zip bomb verificado DURANTE a
decodificação, não só no resultado final.

Roteador de comandos por nome (`Pipes.Commands.pas`, `docs/ARQUITETURA.md` §18):
`TPipeCommandRouter.RegisterCommand(Comando, Handler, AMinSize = -1, AMaxSize = -1)` —
dicionário nome→handler por CIMA de `OnMessage`, opt-in, sem kind novo no NPF1.
`HandleMessage` tem a mesma assinatura de `TPipeMessageEvent` (atribua direto a
`Server.OnMessage`/`Client.OnMessage`). `RegisterRequestCommand`/`HandleRequest` (§18.8)
fazem o mesmo do lado request-reply, com registro PRÓPRIO (mesmo nome pode existir nos dois
sem conflito) e `HandleRequest` atribuível a `Server.OnRequest`; ao contrário de
`HandleMessage`, LEVANTA (`EPipeProtocol`) em comando desconhecido/payload inválido, porque
`ExecuteRequest` já transforma isso em reply de erro — não há `OnUnknownCommand`/
`OnInvalidPayload` deste lado. `PipeSendCommand`/`PipeSendCommandText` (Client e Server, mesmo
molde de dois overloads de `PipeSendJSON`) e `PipeRequestCommand`/`PipeRequestCommandText`
(Client) são wrappers finos sobre `SendBytes`/`Request` que já montam/desmontam o envelope —
ver `docs/ARQUITETURA.md` §18.9. Escopo restante fora desta rodada: só `UnregisterCommand`.

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

Confirmação de entrega (milestone DLV0, `docs/ARQUITETURA.md` §20): `TPipeServer.OnDelivered:
TPipeTopicEvent` (mesmo tipo de `OnPublish`) e `OnDeliveryFailed: TPipeDeliveryFailedEvent`
disparam **por conexão** que casou uma publicação do PRÓPRIO servidor (`Publish`/
`PublishBatch`, ao vivo ou replay de retido — `ARetained` no sentido de `OnTopicMessage`),
um depois do `SendFrame`/`SendFrames` daquela conexão retornar sem exceção, o outro depois de
retornar COM exceção (`AError`). "Entregue" vai só até o SO (o `Write` retornou), nunca ACK de
app — o protocolo não tem isso. Dois eventos, não um com flag de sucesso: decisão do usuário,
para quem só quer alertar sobre falha não precisar filtrar sucesso. Diferente de `OnPublish`,
que é sobre um CLIENTE publicando.

Connect assíncrono (milestone CONN0, `docs/ARQUITETURA.md` §21): `TPipeClient.ConnectAsync`
— como `Connect`, mas volta na hora e uma thread interna insiste até o servidor aparecer
(sucesso em `OnConnected`, desistência em `OnError`, `Connecting` diz se ainda tenta,
`Disconnect` cancela). Sem parâmetro de timeout de propósito: o orçamento é
`MaxReconnectAttempts` × `ReconnectDelayMs`. Compõe com `AutoReconnect` (que segue cuidando
das quedas DEPOIS da primeira conexão) e com `FailoverAddresses` (avança um endereço por
tentativa, mesma regra da reconexão). Enquanto `Connecting`, `Address`/`Transport`/
`TlsOptions` ficam travados (`EPipeError`), via o `GetLifecycleLocked` novo de `TPipeBase`.

## Estrutura de units

```
src/pipes.inc                    src/Pipes.Threading.pas       src/Pipes.Types.pas
src/Pipes.Base.pas                src/Pipes.Framing.pas         src/Pipes.Transport.pas
src/Pipes.Compression.pas        (deflate opcional: System.ZLib/paszlib — ver §17)
src/Pipes.Topics.pas             (pub/sub: nomes, curingas, envelope — unit PURA)
src/Pipes.Transport.Windows.pas  src/Pipes.Transport.Posix.pas
src/Pipes.Transport.Android.pas  (Delphi/Android: ptTcp/ptTls sobre Posix.* + poll)
src/Pipes.Transport.Tcp.pas      src/Pipes.Transport.Tls.pas
src/Pipes.Transport.Schannel.pas src/Pipes.Transport.OpenSSL.pas
src/Pipes.Client.pas             src/Pipes.Server.pas
src/Pipes.Discovery.pas          (descoberta LAN por broadcast UDP — complemento, não
                                  transporte; NÃO depende de Pipes.Transport — ver §16)
src/Pipes.Json.pas                (bytes<->JSON OPCIONAL: System.JSON/fpjson — ver README.md)
src/Pipes.Commands.pas            (roteador de comandos por nome OPCIONAL, por cima de
                                  OnMessage — ver §18)
tests/Unit (Threading/Framing/Topics/Commands/Address/Discovery)
  + tests/Integration (Transport/EndToEnd/PubSub/Stress/Tls/Heartbeat/Stats/Json/Failover/
    Discovery/PeerAddress)
  — DUnit e fpcunit, layout espelhado do pascal-amqp-faa
tests/Android (suite de DEVICE do backend Android; FMX, loopback, sem par dual-compiler)
samples/ (20 amostras — ver README.md)  docs/ARQUITETURA.md  README.md
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
| D0 | Descoberta de servidor na LAN: `Pipes.Discovery` (NPD1 sobre broadcast UDP), `TPipeDiscoveryResponder` + `PipeDiscoverServers`, testes unit+integração nos dois frameworks, sample `EchoDiscovery` (reaproveita o `EchoServer.exe`, so' ganha `discover` na linha de comando) — ver `docs/ARQUITETURA.md` §16 | fable | concluído: verde nos dois compiladores no Win64 (FPC 102 unit + 113 integração; Delphi confirmado 2026-08-03). FPC/Linux pendente (ramo POSIX ainda sem compilador; sem toolchain local) |
| C0 | Compressão de payload: `Pipes.Compression.pas` (deflate via `System.ZLib`/`paszlib`), `pfkCompressed` (kind 7 do NPF1), `CompressionMinSize` em `TPipeBase`, `BytesSentWire`/`BytesReceivedWire` em `Stats`, proteção de zip bomb — ver `docs/ARQUITETURA.md` §17 | sonnet | concluído: verde nos dois compiladores (FPC 115 unit + 117 integração; Delphi/IDE confirmado 2026-08-04, extensão de Stats verificada só no FPC até aqui) |
| CMD0 | Roteador de comandos por nome: `Pipes.Commands.pas` (`TPipeCommandRouter`, opt-in por cima de `OnMessage`, sem kind novo no NPF1), `RegisterCommand` com detecção de duplicado e limites `AMinSize`/`AMaxSize`, `OnUnknownCommand`/`OnInvalidPayload` — ver `docs/ARQUITETURA.md` §18 | sonnet | concluído: verde nos dois compiladores (FPC 138/138 via `PipesUnitTestsFpc.exe`; Delphi/DUnitX 138/138, sem leak, confirmado 2026-08-14). Escopo reduzido de propósito: sem `UnregisterCommand`, `SendCommand` de conveniência nem roteamento do lado `OnRequest` |
| CMD1 | Roteamento por comando do lado request-reply: `RegisterRequestCommand`/`HandleRequest` (`TPipeRequestEvent`, registro PRÓPRIO independente do de mensagem), contrato de erro OPOSTO de propósito (`HandleRequest` LEVANTA em vez de eventos, reaproveitando que `ExecuteRequest` já transforma exceção em reply de erro) — ver `docs/ARQUITETURA.md` §18.8. Sample `EchoCommand` ganhou o comando `SOMAR` e o cenário `?ping` (comando desconhecido do lado request) | sonnet | concluído: verde nos dois compiladores (FPC 147/147 via `PipesUnitTestsFpc.exe`, eram 138; Delphi/DUnitX 147/147 unit + 121/121 integração, 0 leak/falha/erro, confirmado pelo usuário 2026-08-15). Sample verificado ponta a ponta no FPC |
| ADDR0 | Endereço do cliente: `TryPeerAddress` no contrato `TPipeEndpoint` (mesmo padrão de `TryPeerIdentity`), `TPipeServer.TryClientAddress`, backends Windows e POSIX via `getpeername` com `sockaddr` declarado à mão — ver `docs/ARQUITETURA.md` §19 | sonnet | concluído: FPC/Win64 verde (unit 138/138 + integração 121/121, suíte `Pipes.PeerAddressTests`); Delphi/DUnitX pendente de confirmação do usuário. POSIX/Linux compila mas não foi executado (sem toolchain local); `Pipes.Transport.Android` fora desta rodada |
| CMD2 | `SendCommand`/`RequestCommand` de conveniência que CMD0 tinha deixado de fora: `PipeSendCommand`/`PipeSendCommandText` (overloads Client/Server, mesmo molde de `PipeSendJSON`) e `PipeRequestCommand`/`PipeRequestCommandText` (Client) em `Pipes.Commands.pas`, wrappers finos sobre `SendBytes`/`Request` — ver `docs/ARQUITETURA.md` §18.9 | sonnet | concluído: verde nos dois compiladores (FPC 147/147 unit via `PipesUnitTestsFpc.exe`, suíte inalterada — wrappers de uma linha já cobertos pelos testes de `PipeEncodeCommandPayload`/`SendBytes`/`Request`; Delphi/DUnitX 147/147 unit + 121/121 integração, 0 leak/falha/erro, confirmado pelo usuário 2026-08-17). Sample `EchoCommand` migrado para os quatro wrappers nos dois lados e verificado ponta a ponta (servidor + cliente reais) |
| CONN0 | Connect assíncrono: `TPipeClient.ConnectAsync`/`Connecting`, `FConnectingAsync` + `ReopenAllowed` reaproveitando a `TPipeReconnectThread` existente, `GetLifecycleLocked` em `TPipeBase` — ver `docs/ARQUITETURA.md` §21 | opus | concluído: verde nos dois compiladores (FPC/Win64 unit 147/147 + integração 135/135, eram 126 — suíte `TPipeConnectAsyncTests` com 9 testes novos, os 2 de risco rodados 5x seguidas; Delphi/DUnitX 147/147 unit + 135/135 integração, 0 leak/falha/erro, confirmado pelo usuário 2026-08-24). O plano formalizado tinha dois furos reais encontrados na implementação: o SEGUNDO gate de `TryReopenSession` (a rechecagem com a conexão já aberta) e um TOCTOU na limpeza de `FConnectingAsync` em `Execute` — ver §21.2/§21.3 |
| DLV0 | Confirmação de entrega por assinante: `TPipeServer.OnDelivered`/`OnDeliveryFailed`, disparados por conexão em `FanOut`/`SendRetained`/`PublishBatch` depois do `Write` retornar (sucesso/exceção) — ver `docs/ARQUITETURA.md` §20 | sonnet | concluído: verde nos dois compiladores (FPC/Win64 unit 147/147 + integração 126/126, suíte `TPipePubSubTests` com os 4 testes novos + 1 regressão; Delphi/DUnitX 147/147 unit + 126/126 integração, 0 leak/falha/erro, confirmado pelo usuário 2026-08-22). Encontrou e corrigiu de lambuja um bug pré-existente em `PublishBatch` (`ARetained` errado em entrega ao vivo — ver §20.6) |

Dependências: M0 → M1 → M2 → (M3 ‖ M4) → M5 → M6 → M7 → M8 → (T0 → T1 → (T2 ‖ T3) → T4 → T5).
A0-A3 dependem de T5 (concluído) mas são um eixo à parte, independente de P0-P5/H0-H4/
S0-S4/F0-F3/C0/CMD0/CMD1/ADDR0/DLV0. CMD1 depende de CMD0 (mesma unit, `HandleRequest`
reaproveita `ValidateRegistration` já fatorada). CMD2 depende de CMD0 (mesma unit;
independente de CMD1 — não toca em `HandleRequest`). DLV0 depende de P0-P5 (mesmo mecanismo de
fan-out) e reaproveita o despacho de eventos já usado por CMD0-2/ADDR0. CONN0 depende de
F0-F3 (a tentativa assíncrona avança pela lista de failover como a reconexão) e é o único
milestone até aqui a mexer no motor de reconexão compartilhado — daí o checkpoint do motor
verde ANTES da API nova.

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

D0 exige: janela de coleta maior que a cadência de reenvio (300ms) devolve UMA entrada
(dedup real); token errado e porta sem responder devolvem lista VAZIA sem erro (o segundo
é a regressão do eco de ICMP — `SIO_UDP_CONNRESET`/`ECONNREFUSED`); `Start` em porta de
descoberta ocupada levanta `EPipeError` na hora; `Stop` conclui em < 2s e o MESMO objeto
aceita `Start` de novo (porta liberada). Testes de integração usam SEMPRE a forma dirigida
a 127.0.0.1 — broadcast real não é determinístico em CI (ver §16.8).

CONN0 exige: `ConnectAsync` com o servidor SUBINDO DEPOIS conecta sozinho (o caso que
`Connect` e `AutoReconnect` não cobrem); esgotamento chega em `OnError` com a mensagem de
conexão INICIAL, não a de reconexão; `Disconnect` para o laço (que é infinito por padrão) em
no máximo UMA tentativa em curso — não "instantâneo", que seria mentira sem cancelamento nos
backends; uma segunda chamada de `ConnectAsync` em voo não deixa thread órfã (apareceria
como um SEGUNDO `OnConnected`/`ClientCount = 2`); e o ciclo de vida do `AutoReconnect`
continua intacto DEPOIS de o `ConnectAsync` ter cumprido o papel (é onde um
`FConnectingAsync` vazado apareceria). Os dois testes de risco (cancelamento e convivência
com `AutoReconnect`) rodam várias vezes seguidas, pela razão de §13.10.

DLV0 exige: `OnDelivered` dispara exatamente uma vez por conexão que casou (fan-out ao vivo,
replay de retido com `ARetained = True`, e por item de `PublishBatch`); uma entrega que falha
NÃO conta em `OnDelivered` e conta em `OnDeliveryFailed`; o teste de falha é DETERMINÍSTICO
(payload maior que `MaxMessageSize` recusado por `PipeValidateMaxPayload` antes do socket/pipe
— nunca uma corrida contra uma conexão morrendo na hora certa, isso seria flaky pela mesma
razão já registrada em §13.10/T4-T5).

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
