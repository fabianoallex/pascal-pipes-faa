# Changelog

O formato segue o [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/), e as versões
seguem o [Versionamento Semântico](https://semver.org/lang/pt-BR/). Enquanto a versão for 0.x,
uma versão minor pode mudar a API; toda mudança desse tipo aparece aqui.

## [Unreleased]

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
