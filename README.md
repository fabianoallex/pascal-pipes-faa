# pascal-pipes-faa

> Antes `pascal-named-pipes-faa`. O nome mudou porque o Named Pipe do Windows passou a ser
> apenas um dos transportes suportados — a API antiga segue funcionando (ver
> [Compatibilidade](#compatibilidade-com-a-api-anterior)).

Biblioteca multiplataforma de **comunicação entre processos** para **Delphi 12+ (Win64)** e
**FPC 3.2.2 / Lazarus (Linux x86_64 e ARM64)**, com uma única base de código e uma API de
alto nível que abstrai completamente as chamadas nativas do sistema operacional.

A mesma API atende três alcances, trocando uma property:

| `Transport` | Alcance | Por baixo |
|---|---|---|
| `ptLocal` (padrão) | mesma máquina | Named Pipe (Windows) / Unix Domain Socket (Linux) |
| `ptTcp` | rede | socket TCP, com keepalive ligado por padrão |
| `ptTls` | rede não confiável | o mesmo TCP com TLS, e mTLS opcional por certificado |

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
TPipeServer.Create('0.0.0.0:5000', ptTls);      // TCP + TLS (credenciais em TlsOptions)
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
> um que alcance a porta — autenticar é responsabilidade da aplicação. É esse buraco que
> `ptTls` fecha.

### TLS (`ptTls`)

`ptTls` é o mesmo socket TCP com TLS por cima: mesmo formato de `Address`, mesmas
garantias de threading. O que muda é que o tráfego é cifrado e que o par pode ser
autenticado por certificado.

```pascal
Srv := TPipeServer.Create('0.0.0.0:5000', ptTls);
Srv.TlsOptions.CertFile := 'srv.pfx';        // PFX no Windows/Schannel
Srv.TlsOptions.CertPassword := 'senha';
Srv.Listen;

Cli := TPipeClient.Create('servidor.empresa:5000', ptTls);
Cli.Connect(5000);
```

As credenciais são lidas **uma vez**, no `Listen`/`Connect`: mudá-las com o componente
ativo levanta `EPipeError` em vez de aceitar em silêncio uma configuração sem efeito.
Erro de senha ou de arquivo aparece já no `Listen`, e não quando o primeiro cliente
conectar.

#### mTLS (autenticar o cliente)

Preencher `CaFile` **no servidor** liga mTLS: o cliente passa a ser obrigado a apresentar
um certificado que encadeie até aquela CA. Quem não apresentar — ou apresentar de outra CA
— é recusado, e `OnClientConnected` nunca dispara para ele.

```pascal
Srv.TlsOptions.CaFile := 'ca.pem';   // liga mTLS
Cli.TlsOptions.CertFile := 'pdv-001.pfx';
Cli.TlsOptions.CertPassword := 'senha';
```

Esse é o desenho pensado para o caso de PDVs de loja sobre VPN: o certificado, e não o IP
de origem, é o que diz quem é quem.

#### O que muda entre os backends

O backend é escolhido em **tempo de compilação** (ver `src/pipes.inc`): Schannel (SSPI
nativo) é o padrão no Windows; OpenSSL é opt-in com `-dPIPES_OPENSSL`, e é o único no
Linux. Três diferenças que importam na configuração:

| | Schannel (Windows) | OpenSSL |
|---|---|---|
| Formato do certificado | `CertFile` = PFX (cert + chave juntos), `CertPassword` | `CertFile` = PEM, `KeyFile` = PEM da chave |
| `CaFile` no **servidor** | CA dos certificados de cliente (mTLS) | idem |
| `CaFile` no **cliente** | **ignorado** — o Windows valida contra o trust store do SO | CA usada para validar o servidor |

A última linha é a pegadinha: uma PKI privada cujo certificado não esteja no trust store
do Windows faz o *cliente* Schannel rejeitar o servidor mesmo com `CaFile` preenchido. Ou
se instala a CA na máquina, ou se usa o backend OpenSSL.

> **Como o cliente vê uma recusa de mTLS — e por que difere por backend.** O Schannel
> completa o handshake e **só então** entrega o certificado do cliente para a aplicação
> validar (é o que `VerifyClientChain` faz). Consequência: um cliente recusado vê
> `OnConnected` disparar normalmente e a conexão cair logo em seguida. No OpenSSL a
> validação acontece dentro do handshake, então a recusa chega como falha de conexão e
> `OnConnected` nunca dispara.
>
> Uma aplicação que precise distinguir "fui aceito" de "vou ser derrubado" no lado cliente
> **não pode confiar só em `OnConnected` sob Schannel**. O padrão prático é o do sample
> `ChatSeguro`: uma sessão que morre quase junto com o `OnConnected` é recusa de
> credencial, não queda de rede — e aí não adianta reconectar, porque a credencial não
> vai passar a ser aceita sozinha.

#### Quem está do outro lado

Sob mTLS o servidor não só valida o certificado do cliente — ele guarda quem é:

```pascal
procedure TForm1.ClienteConectou(Sender: TObject; AConnId: TPipeConnectionId);
var
  LQuem: TPipePeerIdentity;
begin
  if Servidor.TryClientIdentity(AConnId, LQuem) then
    Memo.Lines.Add('conectou: ' + LQuem.CommonName);  // 'pdv-loja-001'
end;
```

O `CommonName` é confiável **porque a cadeia foi validada antes**: um certificado com
`CN` forjado não chega a disparar `OnClientConnected`, é recusado no handshake. Então dá
para usar esse nome para identificar — mostrar, logar, rotear. O que não se deve fazer é o
inverso: derivar autorização de um nome sem que a cadeia tenha sido verificada.

`TryClientIdentity` devolve `False` quando não há identidade *verificada* — sem TLS, ou com
TLS sem mTLS. `False` nunca significa "ainda não chegou": não há o que esperar.

> **Mudança de comportamento:** `ClientCount` e `ClientIds` passaram a contar apenas
> conexões **estabelecidas** — aquelas para as quais `OnClientConnected` já disparou. Antes,
> uma conexão aceita mas ainda negociando TLS já aparecia ali, o que sob mTLS significava
> exibir como "cliente" um par que talvez fosse recusado em seguida. `Broadcast` segue a
> mesma regra, e por um motivo mais forte que contagem: mandar payload para quem ainda não
> se autenticou seria vazar dado. Para `ptLocal` e `ptTcp` nada muda na prática — sem
> handshake, a conexão nasce estabelecida.
>
> `MaxClients` é deliberadamente diferente: como é limite de **recurso**, conta também as
> conexões em negociação — senão um par que nunca conclui o handshake não ocuparia vaga.

#### Prazo do handshake

O handshake tem prazo próprio, `PIPE_TLS_HANDSHAKE_TIMEOUT_DEFAULT` (15 s), ajustável por
`TlsOptions.HandshakeTimeoutMs`. Sem ele, quem abrisse o TCP e nunca mandasse o
`ClientHello` prenderia uma thread do servidor para sempre — algumas dezenas de conexões
meia-abertas derrubariam o serviço sem enviar um byte útil. O prazo vale **só** durante a
negociação: depois dela a conexão volta a poder ficar ociosa à vontade, e quem cuida de
par morto ali é o keepalive.

`HandshakeTimeoutMs = 0` significa *o padrão*, não "sem prazo" — desligar exige
`PIPE_TLS_HANDSHAKE_NO_TIMEOUT` explícito.

### Keepalive (`KeepAliveSeconds`)

Uma conexão TCP pode morrer em silêncio — cabo, máquina desligada, ou o timeout de
ociosidade de um túnel VPN/NAT. Nenhum dos dois lados é avisado, e o reader ficaria
esperando para sempre. Em IPC local isso não existe: a morte do processo par sempre fecha
o pipe.

Por isso `ptTcp` liga keepalive TCP por padrão, com **20 s** de ociosidade
(`PIPES_DEFAULT_KEEPALIVE_SECONDS`). `ptTls` herda a mesma configuração — é o mesmo socket
por baixo, e o keepalive acontece na camada TCP, sem interferir na sessão TLS. `ptLocal`
ignora a property.

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
  As tentativas são **sempre espaçadas** por `ReconnectDelayMs`, inclusive contra um par
  que aceita a conexão e a derruba em seguida (o caso de um servidor mTLS recusando o
  certificado); e `MaxReconnectAttempts` alcança esse caso também. O contador zera quando
  uma sessão dura mais que `ReconnectDelayMs` — sessão curta demais conta como tentativa,
  para que um cliente rejeitado não fique reconectando indefinidamente, e um cliente de
  longa duração que reconecta legitimamente não acumule rumo ao teto.
- **Modos de despacho** (`DispatchMode`) — onde os SEUS handlers executam:
  - `pdmPool` (padrão): pool de threads; paralelo entre conexões.
  - `pdmSerialized`: worker único; ordem FIFO global garantida.
  - `pdmMainThread`: direto na thread da UI via `TThread.Queue` — para apps VCL/LCL, sem
    `Synchronize` manual e sem risco de evento pós-destroy (objeto-guarda interno).
- **Proteção** — `MaxMessageSize` (padrão 16 MB) rejeita frames acima do limite nas duas
  pontas; magic/kind inválidos derrubam só a conexão ofensora (`EPipeProtocol` em `OnError`).
- **TLS e mTLS** (`ptTls`) — tráfego cifrado sobre TCP, com autenticação opcional do cliente
  por certificado: preencher `CaFile` no servidor faz quem não apresentar certificado
  daquela CA ser recusado antes de `OnClientConnected`. Backend nativo por plataforma
  (Schannel no Windows, OpenSSL no Linux) e prazo próprio de handshake, para que um par que
  abra a conexão e não fale não consuma uma thread indefinidamente.

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

**Delphi:** adicione `src\` ao search path (ou abra `Pipes.groupproj`).

**Lazarus:** abra/compile `packages\pipes_faa.lpk` uma vez e adicione `pipes_faa` aos
requisitos do seu projeto (ou use `lazbuild --add-package-link packages\pipes_faa.lpk`).

**Dependências:** nenhuma para `ptLocal` e `ptTcp`, e nenhuma em tempo de compilação em
nenhum caso. Para `ptTls` depende do backend:

- **Schannel** (padrão no Windows): nada a instalar — é SSPI, parte do SO.
- **OpenSSL** (`-dPIPES_OPENSSL`; único no Linux): precisa de `libssl`/`libcrypto` **na
  máquina que roda**. Elas são carregadas dinamicamente na primeira conexão TLS, então a
  ausência não impede compilar nem iniciar o programa — ela aparece como `EPipeTls`
  ("OpenSSL não encontrado") na primeira conexão. Aceita as séries 3.x e 1.1. No Linux as
  distribuições já trazem; no Windows é preciso fornecer as DLLs
  (`libcrypto-3-x64.dll` + `libssl-3-x64.dll`, ou os equivalentes 1.1).

## API (resumo)

```pascal
TPipeBase (abstrata)
  Address, Transport, KeepAliveSeconds, Active, DispatchMode, MaxMessageSize
  TlsOptions: TPipeTlsConfig             // só usado em ptTls; lido no Listen/Connect
    CertFile, CertPassword, KeyFile, CaFile, SkipServerVerification, HandshakeTimeoutMs
  OnMessage: TPipeMessageEvent;  OnError: TPipeErrorEvent

TPipeServer
  Listen; Stop;                          // Listen não-blocante; Stop síncrono
  SendBytes/SendText(ConnId, ...)        // EPipeError se ConnId não existe
  Broadcast/BroadcastText(...)           // snapshot; falha por conexão é engolida
  DisconnectClient(ConnId)               // assíncrono e idempotente
  ClientCount; ClientIds                 // só conexões ESTABELECIDAS
  TryClientIdentity(ConnId, out Ident)   // quem é, pelo certificado mTLS validado
  MaxClients                             // limite de recurso: conta as em handshake
  OnClientConnected/OnClientDisconnected: TPipeConnectionEvent
  OnRequest: TPipeRequestEvent           // (const ARequest: TBytes; out AReply: TBytes)

TPipeClient
  Connect(TimeoutMs); Disconnect;        // Connect re-tenta até o prazo
  SendBytes/SendText(...)                // fire-and-forget
  Request/RequestText(..., TimeoutMs)    // RPC síncrono; EPipeTimeout no prazo
  Connected; AutoReconnect; ReconnectDelayMs; MaxReconnectAttempts
  OnConnected/OnDisconnected: TPipeConnectionEvent

Exceções: EPipeError > EPipeClosed | EPipeTimeout | EPipeProtocol | EPipeTls
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
- **EchoSeguro** (`EchoSeguroServer` + `EchoSeguroClient`) — o mesmo eco, mas sobre `ptTls`
  com mTLS: servidor exige certificado de cliente (`CaFile`), cliente apresenta o dele,
  tráfego cifrado ponta a ponta. Usa a PKI de teste versionada em `tests/pki`; um cliente sem
  certificado (ou um `TPipeClient` comum) é recusado antes de `OnClientConnected` disparar —
  prova de que o mTLS não é decorativo.
- **ChatVcl** — chat com UI (VCL no Delphi, LCL no Lazarus, mesmo fonte): uma instância é o
  servidor-hub (retransmite via `Broadcast`), as outras são clientes. Vitrine do
  `pdmMainThread` (handlers mexem na UI direto) e do `AutoReconnect`.
- **ChatSeguro** — o mesmo chat sobre `ptTls` com mTLS, e a diferença não é só a cifra:
  **quem está na sala vem do certificado, não de um apelido digitado.** O hub rotula cada
  mensagem com o `CommonName` que `TryClientIdentity` devolve, e a lista de participantes
  sai de `ClientIds` — que só mostra conexões estabelecidas. O combo de identidade troca o
  certificado apresentado, incluindo os que **devem ser recusados** (`rogue`, `selfsigned`):
  é aí que se vê o mTLS trabalhando, e não no caminho feliz. Precisa da PKI de
  [`tests/pki/`](tests/pki/LEIA-ME.md), que o próprio form localiza.
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
- FPC/Lazarus (Windows): `lazbuild tests\Unit\fpc\PipesUnitTestsFpc.lpi` e
  `lazbuild tests\Integration\fpc\PipesIntegrationTestsFpc.lpi`; rode os exes com
  `--all --format=plain` (sem parâmetros abre a GUI de testes).
- Linux (Docker): imagem Debian Bookworm traz o FPC 3.2.2 exato:

  ```bash
  docker run --rm -v "$PWD:/work" debian:bookworm bash -c '
    apt-get update -qq && apt-get install -y -qq fpc >/dev/null
    cd /work/tests/Integration/fpc
    fpc -MDelphi -Sh -B -Fu../../../src -Fi../../../src -FU/tmp -o/tmp/t \
      PipesIntegrationTestsFpc.lpr
    /tmp/t --all --format=plain'
  ```

  (`-Fi` é necessário desde que os testes passaram a incluir `pipes.inc`, para enxergar
  quais backends o build tem.)

- OpenSSL **1.1** (o outro ramo suportado): trocar a imagem por `debian:bullseye`, que traz
  `libssl 1.1.1` e **não** tem a 3.x. Não é redundante com a anterior — é a única forma de
  exercitar o fallback de símbolo do getter do certificado do par, que o 3.x renomeou
  (`SSL_get_peer_certificate` → `SSL_get1_peer_certificate`). Com as duas versões instaladas
  o loader escolheria a 3.x e o ramo antigo nunca rodaria; numa imagem onde só existe a 1.1,
  ele é obrigatório.

A suíte de integração inclui stress de encerramento (Stop sob flood < 2 s), detector de
vazamento de handle/fd em quedas abruptas repetidas e correlação RPC sob concorrência.

### Testes de TLS

O fixture `TPipeTlsTests` só existe se o build tiver backend TLS — no Linux, portanto, só
com `-dPIPES_OPENSSL`. Cinco dos oito testes são de **recusa** (cliente sem certificado,
de outra CA, auto-assinado, mudo no handshake): é a metade que prova que existe
autenticação, e não só que o caminho feliz funciona.

As credenciais vêm de [`tests/pki/`](tests/pki/LEIA-ME.md) — uma PKI de teste versionada
no repositório de propósito, **sem valor de segurança**. Um scanner de segredos vai
apontá-la; o apontamento está certo quanto ao fato e errado quanto ao risco. A alternativa
de gerá-la no `Setup` com `openssl` foi descartada porque, onde não houvesse `openssl`, os
testes de TLS sumiriam — e teste de segurança que some em silêncio é pior que teste
ausente. A ausência da PKI **falha**, não pula.

## Estrutura

```
src/                 biblioteca (Pipes.Types, Pipes.Framing, Pipes.Transport[.Windows|.Posix],
                     Pipes.Base, Pipes.Server, Pipes.Client, Pipes.Threading, pipes.inc)
                     rede: Pipes.Transport.Tcp
                     TLS: Pipes.Transport.Tls (fachada) + .Schannel / .OpenSSL (backends)
packages/            pipes_faa.lpk (pacote Lazarus)
samples/             EchoServer, EchoClient, EchoSeguro (TLS + mTLS), ChatVcl, ChatSeguro,
                     PdvDualScreen (Operador + Cliente), FilaImpressao, DespachoTarefas,
                     ServicoInstavel, RpcConcorrente
tests/               Unit + Integration (DUnitX e FPCUnit, espelhados)
tests/pki/           PKI de TESTE versionada, sem valor de seguranca (ver LEIA-ME)
docs/ARQUITETURA.md  arquitetura completa (wire format, ciclo de vida das threads, racional)
Pipes.groupproj      grupo de projetos Delphi    Pipes.lpg  grupo Lazarus
```

## Licença

[MIT](LICENSE) — © 2026 Fabiano Arndt
