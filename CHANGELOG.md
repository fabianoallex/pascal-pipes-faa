# Changelog

O formato segue o [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/), e as versões
seguem o [Versionamento Semântico](https://semver.org/lang/pt-BR/). Enquanto a versão for 0.x,
uma versão minor pode mudar a API; toda mudança desse tipo aparece aqui.

## [Unreleased]

O transporte TCP/TLS passou para a pascal-common-faa (`PascalCommon.Transport*`, passo 2 da
"Migration order" do `docs/transport-design.md` de lá). Depende da branch `transport` da
common, ainda não lançada (decisão T8 de lá); detalhes em `docs/ARQUITETURA.md` §26.

### Adicionado

- **Backend TLS escolhido em runtime**: `TlsOptions.Backend` (`tbDefault`, `tbSChannel`,
  `tbOpenSsl`; re-exportados por `Pipes.Types`). No Windows os dois backends estão sempre no
  executável — OpenSSL não exige mais outro build. `-dPIPES_OPENSSL` continua valendo, mas só
  troca o que `tbDefault` significa (OpenSSL também no Windows). `PIPES_TLS` passa a estar
  sempre definido, e `PIPES_OPENSSL` é definido automaticamente fora do Windows (Linux e
  Android).
- Testes: `TPipeTlsOpenSslTests` repete a suíte de TLS com `tbOpenSsl` na mesma rodada do
  Windows (24 testes), se a libssl carregar.

### Alterado

- **Mensagens de transporte em inglês** vindas da common (decisão T6 de lá). As classes
  continuam `EPipeClosed`/`EPipeTimeout`/`EPipeTls`/`EPipeError`, com a mesma mensagem que a
  common levantou: a tradução acontece em `TPipeEndpoint`/`TPipeListener`/nas fábricas. Os
  textos de Named Pipe, UDS e do laço de re-tentativa do connect são os mesmos da 0.3.0
  (`timeout (N ms) connecting to host:porta`); os de socket/TLS são os da common.
- **Cliente SChannel com `CaFile` agora valida o servidor contra essa CA**, como o OpenSSL.
  Até a 0.3.0 ele ignorava `CaFile` e só aceitava servidores do trust store do Windows. Quem
  preenchia `CaFile` no cliente SChannel e dependia do trust store para OUTRA CA passa a ser
  recusado; quem desligava a validação só por isso pode religá-la. Os samples `EchoSeguro`,
  `GatewaySeguro` e `ChatSeguro` passaram a validar o servidor nos dois backends, e
  `Tls_ValidaServidorPorIp_Aceita`/`PorNome_Aceita` deixaram de ser só OpenSSL.
- **SChannel, `SEC_I_INCOMPLETE_CREDENTIALS`**: um cliente sem certificado contra um servidor
  que pede um agora continua o handshake sem certificado, e o servidor o recusa com
  `EPipeTls`. Antes o cliente desistia e o servidor só via a conexão fechada.
- **POSIX (UDS e TCP), `MSG_DONTWAIT` em `recv`/`send`** (gotcha 15 da common): sem ele um
  `send` grande, depois de o `poll` anunciar um pouco de espaço, esperava no kernel até
  mandar tudo, e o prazo de `SetIoDeadline` (o do handshake TLS, por exemplo) nunca
  disparava numa escrita. O backend Android recebeu a mesma correção (não verificada em
  aparelho).
- Outras correções que vieram com a common: no Windows, leitor e escritor do mesmo socket
  TCP não roubam mais o aviso um do outro (um evento de acordar por direção); o prazo de IO
  passa a valer também numa conexão TLS (o adaptador antigo não o repassava); falhas do
  socket mantêm a classe através do TLS (prazo = `EPipeTimeout`, `CloseAbort` =
  `EPipeClosed`; antes tudo virava "fechado pelo par"); o certificado do cliente sob mTLS no
  SChannel é conferido com `AUTHTYPE_CLIENT` (era `AUTHTYPE_SERVER`).
- `TPipeTlsOptions` e `TPipePeerIdentity` são aliases de `TPcTlsOptions`/`TPcPeerIdentity`
  (mesmos campos, mais `Backend`). `TPipeEndpoint` e `TPipeListener` viraram fachadas sobre
  o `TPcEndpoint`/`TPcListener` de baixo (property `Inner`); `TPipeEndpoint` descende de
  `TPcEndpoint`, `TPipeListener` não (para `Accept` continuar devolvendo `TPipeEndpoint`).
  `TPipeEndpointStream` e `TPipeRawSockAddr*` são aliases dos `TPc*`.

### Corrigido

- **`MaxReconnectAttempts` contra um par que aceita e derruba** (mTLS recusado no SChannel, ou
  em TLS 1.3 no OpenSSL): o critério de "sessão durável", que zera o contador, media a
  duração da sessão DEPOIS da espera entre tentativas, então uma sessão que morria na hora
  contava ≈ `ReconnectDelayMs` − (connect + handshake). Com o connect abaixo de um tick do
  relógio (~16 ms no Windows, comum em loopback) isso chegava a `ReconnectDelayMs`, o
  contador zerava e o teto demorava a valer (o teste
  `Mtls_MaxReconnectAttempts_AlcancaParQueAceitaEDerruba` via 6 a 16 conexões em vez de 4).
  Agora a duração é medida até o fim da sessão. Bug anterior a esta versão; o transporte novo,
  mais rápido no handshake, o tornou frequente.

### Obsoleto (sai na próxima versão minor)

- `TcpPipeConnect`/`TcpPipeCreateListener` (`Pipes.Transport.Tcp`) e `TlsPipeConnect`/
  `TlsPipeCreateListener` (`Pipes.Transport.Tls`): use `PipeConnect`/`PipeCreateListener`.
- `Pipes.Transport.Schannel` e `Pipes.Transport.OpenSSL`: ficaram vazias, só para não quebrar
  um `uses` ou um `.dproj`.
- `PipeParseHostPort` com IPv6 sem colchetes e com porta (`'::1:5000'`): continua aceito
  nesta versão (a common recusa, por ser ambíguo — também é um IPv6 válido sem porta); use
  `'[::1]:5000'`.

### Removido

- As classes de backend que eram públicas nas units de transporte: `TPipeTcpWinEndpoint`/
  `Listener`, `TPipePosixEndpoint`/`Listener`, `TPipeTlsEndpoint`/`Listener`,
  `TPipeSchannelStream`/`ServerStream`, `TPipeOpenSslStream`/`ServerStream` e as funções
  `PipeSchannelLoadPfx`/`LoadCaStore`/`FreeCert`/`FreeCaStore`. O equivalente está na common
  (`PascalCommon.Transport.Tcp`/`.Posix`/`.Tls`).

## [0.3.0] - 2026-10-15

### Alterado

- **Mensagens de runtime em inglês**, como nas outras bibliotecas `*-faa`: as ~250 strings de
  exceção e de `OnError` de todas as units (`Pipes.Base`/`Client`/`Server`/`Commands`/`Json`/
  `Topics`/`Compression`/`Framing`, os seis backends de transporte e TLS, e `Pipes.Discovery`).
  Comentários do código seguem em português. **Classes de exceção e protocolo não mudam.**
- Quem compara TEXTO de mensagem precisa atualizar. O recomendado é decidir pela classe
  (`EPipeClosed`, `EPipeTimeout`, `EPipeTls`, `EPipeProtocol`, `EPipeCommandError`,
  `EPipeJSONError`) e tratar o texto como diagnóstico. As que mais costumam ser comparadas:

| Antes (≤ 0.2.0) | Agora (0.3.0) | Onde aparece |
|---|---|---|
| `servidor respondeu erro: X` | `server replied with error: X` | cliente (`Request`) |
| `OnMessage levantou EConvertError: X` | `OnMessage raised EConvertError: X` | `OnError` (0.2.0) |
| `servidor sem handler OnRequest` | `server has no OnRequest handler` | **fio** (reply de erro) |
| `filtro de assinatura invalido: F` | `invalid subscription filter: F` | **fio** (corrId 0) e local |
| `teto de N assinaturas por cliente atingido` | `limit of N subscriptions per client reached` | **fio** (corrId 0) |
| `topico de publicacao invalido: T` | `invalid publish topic: T` | **fio** (corrId 0) |
| `comando desconhecido: "C"` | `unknown command: "C"` | *fio* via `HandleRequest` |
| `conexao inicial esgotada apos N tentativas` | `initial connection gave up after N attempts` | `OnError` |
| `reconexao esgotada apos N tentativas` | `reconnection gave up after N attempts` | `OnError` |
| `cliente nao esta conectado` | `client is not connected` | `EPipeClosed` |
| `cliente N nao esta conectado` | `client N is not connected` | `EPipeError` (servidor) |
| `request sem resposta em N ms` | `request got no reply within N ms` | `EPipeTimeout` |
| `conexao encerrada pelo par` | `connection closed by the peer` | `EPipeClosed` |
| `conexao recusada: MaxClients atingido` | `connection refused: MaxClients reached` | `OnError` |
| `OpenSSL não encontrado (tentados: ...)` | `OpenSSL not found (tried: ...)` | `EPipeTls` |

- **Peers de versões diferentes:** o fio não muda (o texto do reply de erro é UTF-8 livre), então
  0.3.0 e ≤ 0.2.0 conversam normalmente. O único efeito é idioma misturado: um cliente 0.3.0
  diante de um servidor 0.2.0 sem `OnRequest` levanta
  `EPipeError: server replied with error: servidor sem handler OnRequest`.

- Verificado em Delphi Win32/Win64, FPC Windows x64 e FPC Linux x86_64. **`tests/Android` não
  foi executado em aparelho nesta versão** — os três casos que comparam texto foram atualizados
  e seguem pendentes de rodada.

### Corrigido

- `Pipes.Discovery.pas` não tem BOM e trazia um travessão (—) dentro de três mensagens de
  "porta de descoberta indisponível". O Delphi lê fonte sem BOM na codepage do sistema, então
  essas mensagens podiam sair com o caractere corrompido. As mensagens agora são ASCII.

## [0.2.0] - 2026-10-15

### Alterado

- **Exceção que escapa de um handler do usuário agora chega ao `OnError`** do mesmo
  componente, em vez de ser engolida em silêncio pelo worker do pool. Vale para todos os
  eventos (`OnMessage`, `OnTopicMessage`, `OnConnected`/`OnDisconnected`,
  `OnClientConnected`/`OnClientDisconnected`, `OnPublish`, `OnSubscribe`/`OnUnsubscribe`,
  `OnDelivered`/`OnDeliveryFailed`, `OnConnectAttemptFailed`) e para os três
  `DispatchMode`, inclusive `pdmPool` com `AGroupKey`. `AConnId` é o da conexão do evento e
  a mensagem é `'<Evento> levantou <Classe>: <mensagem>'`. O `OnError` roda inline, na mesma
  thread do handler que falhou; a conexão não é fechada. Exceção dentro do próprio
  `OnError` continua engolida. `OnRequest` não muda: a exceção segue virando reply de erro.
  Quem usava `OnError` só para erros de transporte passa a receber também esses.
- README: a lista de plataformas passa a ser a testada de fato (Delphi Win32/Win64/Android,
  FPC Windows x64 e Linux x86_64); Linux ARM64 sai da lista por nunca ter sido testado.

## [0.1.1] - 2026-10-05

### Alterado

- Submódulo `external/pascal-common-faa` (só testes/samples/scripts) sobe da `v1.0.0` para a
  `v1.2.0`. O mínimo exigido da aplicação continua sendo a 1.0.0 — o pipes não usa
  `PcProcessorCount`. No FPC/Linux o `PcPool` agora cresce até 4 × núcleos em vez de 16
  workers; nada aqui depende desse teto.
- Os `.dproj` de teste e samples abrem em Win32 por padrão (eram Win64); Win64 continua
  configurado em todos. O `EchoAndroid` e o `tests/Android` seguem em Android64.

## [0.1.0] - 2026-10-04

Primeira versão publicada. Comunicação entre processos para Delphi 12+ (Win64, Win32, Android)
e FPC 3.2.2/Lazarus (Windows e Linux x86_64/ARM64), com `TPipeServer`/`TPipeClient` sobre três
transportes escolhidos pela property `Transport`: `ptLocal` (Named Pipe no Windows, Unix
Domain Socket no Linux), `ptTcp` e `ptTls` (Schannel ou OpenSSL, mTLS opcional).

### Adicionado

- Mensagens, `Broadcast`, Request-Reply síncrono com timeout, envio em lote
  (`SendBytesBatch`), ordem por grupo em `pdmPool` (`AGroupKey`).
- Pub/sub por tópico com curingas e retenção do último valor, reassinatura automática na
  reconexão, confirmação de entrega por assinante (`OnDelivered`/`OnDeliveryFailed`).
- `AutoReconnect`, failover de endereço (`FailoverAddresses`), connect assíncrono
  (`ConnectAsync`) e diagnóstico de tentativas (`OnConnectAttemptFailed`).
- Keepalive TCP, heartbeat de aplicação, métricas (`Stats`/`ConnectionStats`), compressão de
  payload (`CompressionMinSize`), endereço do cliente (`TryClientAddress`).
- Units opcionais: descoberta na LAN (`Pipes.Discovery`), JSON (`Pipes.Json`) e roteador de
  comandos por nome (`Pipes.Commands`).
- Protocolo de fio documentado para outras linguagens em `docs/INTEROP.md`.

### Mudado

- **Incompatível:** atomics, ticks, monitor e pool de threads saíram de `Pipes.Threading` para
  uma biblioteca-base nova,
  [pascal-common-faa](https://github.com/fabianoallex/pascal-common-faa) (1.0.0 ou mais nova),
  compartilhada com as outras libs `*-faa`; a aplicação passa a fornecê-la (ver o README,
  "Instalação"). Renomeações, sem alias: `PipeAtomic*` → `PcAtomic*`, `PipeTickMs` →
  `PcTickMs`, `TPipeMonitor`/`TPipeWorkItem`/`TPipeThreadPool` →
  `TPcMonitor`/`TPcWorkItem`/`TPcThreadPool`, `PipePool` → `PcPool`, `PIPES_WAIT_INFINITE` →
  `PC_WAIT_INFINITE` (units `PascalCommon.Threading` e `PascalCommon.ThreadPool`).
  `TPipeKeyedDispatcher`, `PipeGroupDispatcher` e `TPipeHeartbeatThread` continuam em
  `Pipes.Threading`. `pipes_faa.lpk` exige `pascal_common_faa`; no Delphi, acrescente o `src`
  da pascal-common-faa ao search path. Uma pascal-common-faa velha demais para o build com uma
  mensagem dizendo a versão necessária.
- O pool de `pdmPool` agora é o `PcPool`, do processo inteiro: `PoolQueueDepth` passa a contar
  também o trabalho das outras libs `*-faa` que o usam.
- `TPipeKeyedDispatcher.Destroy` espera as drenagens em voo e recusa `Enqueue` novo (o item é
  liberado sem executar); a ordem "pool primeiro, dispatcher depois" deixou de ser
  obrigatória. `PipeGroupDispatcher` é criado na `initialization` da unit.
- As operações atômicas de 64 bits dão a volta em vez de levantar `EIntOverflow` com `{$Q+}`.

### Corrigido

- A documentação dizia que o `Destroy` do pool descartava os itens pendentes; ele sempre
  executou a fila inteira antes de retornar.

[Unreleased]: https://github.com/fabianoallex/pascal-pipes-faa/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/fabianoallex/pascal-pipes-faa/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/fabianoallex/pascal-pipes-faa/releases/tag/v0.1.0
