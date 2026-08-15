# pascal-pipes-faa

> 🇬🇧 This document is also available in [English](README.en.md).

> Antes `pascal-named-pipes-faa`. O nome mudou porque o Named Pipe do Windows passou a ser
> apenas um dos transportes suportados — a API antiga segue funcionando (ver
> [Compatibilidade](#compatibilidade-com-a-api-anterior)).

Biblioteca multiplataforma de **comunicação entre processos** para **Delphi 12+ (Win64 e
Android)** e **FPC 3.2.2 / Lazarus (Linux x86_64 e ARM64)**, com uma única base de código e
uma API de alto nível que abstrai completamente as chamadas nativas do sistema operacional.

A mesma API atende três alcances, trocando uma property:

| `Transport` | Alcance | Por baixo |
|---|---|---|
| `ptLocal` (padrão) | mesma máquina | Named Pipe (Windows) / Unix Domain Socket (Linux) — **não existe no Android** |
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

#### Android

Android é um terceiro eixo de plataforma (Delphi, `Android64`/`Android32`), ao lado de
Delphi/Win64 e FPC/POSIX. A API é a mesma; muda o que está disponível:

- **`ptTcp` e `ptTls` funcionam**, cliente e servidor. `ptLocal` **não existe** — app
  Android é single-process e expor um Unix Domain Socket esbarra em sandboxing. Usá-lo
  levanta `EPipeError` dizendo o que fazer, em vez de falhar obscuramente adiante.
- **`ptTls` é sempre OpenSSL** (Schannel é Windows-only), e por isso é o único alvo onde
  `PIPES_OPENSSL` é ligado automaticamente. Você precisa empacotar `libcrypto.so` e
  `libssl.so` por ABI no Deployment do app — ver `samples/EchoAndroid/LEIA-ME.md`.
- **Permissão `INTERNET` no manifesto** é obrigatória, e `ptTcp` (texto claro) ainda exige
  `usesCleartextTraffic` do Android 9 em diante. Mais um motivo para preferir `ptTls`.
- Recomendado num celular: `DispatchMode := pdmMainThread` (eventos chegam pela thread
  principal, dá para mexer na UI direto) e `Connect` fora da thread principal, já que ele
  bloqueia até o prazo.

Verificação é em aparelho: não há par dual-compiler (o FPC não compila para Android neste
projeto). A suíte de device fica em `tests/Android/`. Racional completo em
[`docs/ARQUITETURA.md`](docs/ARQUITETURA.md) §13.

### Endereço do cliente (`TryClientAddress`)

Em `ptTcp`/`ptTls` (com ou sem mTLS) o servidor sabe de onde cada cliente veio:

```pascal
procedure TForm1.ClienteConectou(Sender: TObject; AConnId: TPipeConnectionId);
var
  LEndereco: string;
begin
  if Servidor.TryClientAddress(AConnId, LEndereco) then
    FileLog('pipe-connection', 'Cliente conectado: ' + LEndereco)
  else
    FileLog('pipe-connection', 'Cliente conectado: ' + AConnId.ToString); // ptLocal
end;
```

`False` em `ptLocal`: Named Pipe/UDS não tem endereço IP, só um handle/fd local — não é
"ainda não chegou", é sempre assim para esse transporte. O endereço vem no formato
`'ip:porta'` (IPv6 entre colchetes, mesma convenção do `Address` que você mesmo passa para
`Connect`) e **sobrevive à saída do cliente**, mesmo critério de `TryClientIdentity` logo
abaixo — dá para responder "de onde veio quem saiu?" dentro do próprio
`OnClientDisconnected`.

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

Para gerar sua própria CA/certificados (não a PKI de teste de `tests/pki`), veja
`tools/gerar-pki.sh` e o guia passo a passo em `tools/LEIA-ME.md`.

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

A identidade **sobrevive à saída do cliente**, então `OnClientDisconnected` também pode
perguntar "quem saiu?" — sem isso um painel só conseguiria dizer "conexão 7 saiu". Ficam
retidas as últimas `PIPES_RECENT_IDENTITIES` (256) conexões autenticadas. O motivo de não
liberar junto com a conexão é que o evento e a limpeza vão para filas diferentes, sem
ordem garantida entre si: amarrar a vida da identidade à limpeza seria uma corrida.

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

### Heartbeat de aplicação (`HeartbeatIntervalMs`)

Complementar ao Keepalive acima, não substituto. `KeepAliveSeconds` é um probe do SO:
barato, mas tipicamente leva minutos para acusar e enxerga só o socket TCP por baixo —
nunca o que atravessa o registro cifrado do `ptTls`. `HeartbeatIntervalMs` resolve o mesmo
problema em cima do framing, com um frame de aplicação (`pfkPing`) e controle fino do
tempo de detecção:

```pascal
Server.HeartbeatIntervalMs := 5000;  // desligado por padrao (0); so' ptTcp/ptTls
Client.HeartbeatIntervalMs := 5000;  // mesmo valor nos dois lados, por simplicidade
```

Simétrico e sem correlação: qualquer frame recebido (o próprio `Ping` incluso) reseta o
relógio de leitura de quem o recebeu — não existe `pfkPong` nem "ping em aberto" a
rastrear. Conexão morta = **nenhum frame recebido em 2x o intervalo configurado**; quem
detecta fecha a própria conexão e segue o fluxo normal de queda
(`OnClientDisconnected`/`OnDisconnected` + `AutoReconnect`, sem evento dedicado). `ptLocal`
ignora a property, pela mesma razão do Keepalive: a morte do processo par já fecha o
pipe/UDS local na hora.

### Métricas/observabilidade (`Stats`/`ConnectionStats`)

Snapshot sob demanda — mesmo molde de `ClientCount`/`ClientIds`/`Subscriptions`: a lib não
empurra nada periodicamente, o app pergunta quando quiser. Sempre ativos, sem opt-in (o
custo é um incremento atômico por frame). Válido em **qualquer transporte**, inclusive
`ptLocal`.

```pascal
LConnStats: TPipeConnStats;
if Server.ConnectionStats(AConnId, LConnStats) then
  WriteLn(LConnStats.BytesReceived, ' bytes recebidos desta conexao');

LSrvStats := Server.Stats;      // agregado, cumulativo desde o Listen
LCliStats := Client.Stats;      // da SESSAO atual, zera a cada reconexao
WriteLn('fila do pool: ', LSrvStats.PoolQueueDepth);
WriteLn('latencia media de request: ', LCliStats.AvgRequestLatencyMs, ' ms');
```

- **`Server.ConnectionStats(AConnId, out AStats): Boolean`** — bytes/mensagens enviados e
  recebidos por UMA conexão. Morre com ela (como as assinaturas de tópico), diferente de
  `TryClientIdentity`. `False` se a conexão não existe ou não está estabelecida.
- **`Server.Stats: TPipeServerStats`** — agregado cumulativo desde o `Listen`, sobrevive a
  conexões que já caíram: `TotalConnectionsAccepted` (só estabelecidas), `TotalBytesSent/
  Received`, `TotalMessagesSent/Received`, `ClientCount`, e `PoolQueueDepth`. **Ressalva:**
  em `pdmPool` (padrão) o pool de despacho é GLOBAL, compartilhado por todo `TPipeServer`/
  `TPipeClient` do processo — `PoolQueueDepth` reflete o backlog de todo mundo, não só deste
  servidor. Só é exclusivo dele em `pdmSerialized`.
- **`Client.Stats: TPipeClientStats`** — bytes/mensagens da SESSÃO atual (zera a cada
  `Connect`/reconexão, sem contador cumulativo entre sessões), `ReconnectAttempts`,
  `PendingRequests`, e `AvgRequestLatencyMs`/`MaxRequestLatencyMs` — só contam Requests que
  chegaram a ter reply (timeout e erro ficam de fora: são "o servidor não respondeu", uma
  pergunta diferente de "quanto tempo levou").
- **`BytesSent`/`BytesReceived` vs `BytesSentWire`/`BytesReceivedWire`** (nos três: `Server.
  ConnectionStats`, `Server.Stats` como `TotalBytesSent/ReceivedWire`, e `Client.Stats`) — os
  primeiros são o payload LÓGICO (visão do app, o que `CompressionMinSize` NÃO muda); os
  `*Wire` são o que de fato passou pelo fio, já refletindo a compressão quando ela comprimiu
  algum frame. `BytesSent - BytesSentWire` é a economia real de banda; sem `CompressionMinSize`
  ligado os dois pares são sempre idênticos.

### Ordem por grupo em `pdmPool` (`AGroupKey` de `SendBytes`/`SendText`)

`pdmPool` (o `DispatchMode` padrão) despacha cada mensagem recebida a um pool de workers —
rápido, mas sem ordem garantida de entrega entre mensagens distintas ao `OnMessage` (só a
ordem no fio, que já é sempre preservada). Para a maioria dos apps isso nunca importa; para
quem precisa que um SUBCONJUNTO das mensagens processe na ordem em que foi mandado (ex.: os
eventos de um caixa específico numa loja), sem abrir mão do paralelismo entre os demais:

```pascal
Client.SendBytes(AData, 'caixa.3');   // toda mensagem de 'caixa.3' processa em ordem...
Client.SendBytes(AData2, 'caixa.4');  // ...e em PARALELO com 'caixa.4', nao atras dela
```

- Sem `AGroupKey` (padrão, `''`): comportamento de sempre, sem custo nenhum.
- A garantia é sobre a ENTREGA ao `OnMessage` do lado que RECEBE, não sobre quem manda — tanto
  `TPipeClient.SendBytes` quanto `TPipeServer.SendBytes` aceitam o parâmetro, e é o
  `DispatchMode` de quem RECEBE que decide se a chave faz diferença.
- Só se aplica a `pdmPool`: em `pdmSerialized`/`pdmMainThread` a ordem já é total, a chave é
  ignorada (não muda nada, não é erro usar).
- Chaves são efêmeras — não há limite de chaves distintas nem custo residual: a estrutura
  interna nasce com a primeira mensagem pendente daquela chave e morre quando não há mais
  nenhuma. Reaproveitar uma chave depois de esvaziar começa do zero.
- Sem mudança de wire format: a chave viaja no próprio `CorrId` do header NPF1 (hash de 64
  bits), campo que já existia e que mensagens avulsas nunca usavam.

### Failover de endereço (`FailoverAddresses`)

Só em `TPipeClient` (`TPipeServer` escuta um único `Address`; não há o que "falhar para" do
lado de quem aceita). Endereços tentados em ordem DEPOIS de `Address`, o primário — vazio
por padrão, comportamento idêntico a antes desta property existir. Todos compartilham
`Transport`/`TlsOptions`/`KeepAliveSeconds` do cliente: são locais de rede alternativos do
MESMO serviço (ex.: loja principal e DR da mesma retaguarda), não um jeito de falar com um
servidor diferente.

```pascal
Client := TPipeClient.Create('loja-principal:9000', ptTcp);
Client.FailoverAddresses := ['loja-dr:9000'];
Client.AutoReconnect := True;
Client.Connect(5000);             // divide o prazo entre os enderecos da lista
WriteLn(Client.ActiveAddress);    // qual deles a sessao atual usa
```

`Connect(ATimeoutMs)` dá voltas pela lista com uma fatia igual do prazo por endereço, até um
conectar ou o total estourar. A reconexão automática (`AutoReconnect`) avança um endereço por
tentativa que falha, e volta a preferir o primário assim que uma sessão dura mais que
`ReconnectDelayMs` — uma sessão "de verdade" num alternativo não deixa o cliente grudado
nele: a PRÓXIMA falha tenta o primário de novo antes de espalhar pelos outros.
`MaxReconnectAttempts`/`ReconnectDelayMs` continuam contando/espaçando por TENTATIVA, sem
orçamento separado por endereço.

### Compressão de payload (`CompressionMinSize`)

Deflate opcional para payloads grandes e compressíveis (JSON verboso, texto repetitivo) —
zero dependência nova: `System.ZLib` no Delphi e `paszlib`/`zstream` no FPC, os dois já vêm
na instalação padrão. `CompressionMinSize` (em `TPipeServer`/`TPipeClient`, igual
`MaxMessageSize`) é `0` por padrão — desligado, comportamento idêntico a antes desta
property existir. Ligar só afeta a PRODUÇÃO local; a decodificação de frames comprimidos
recebidos do peer é sempre ativa, então dá para ligar de um lado só, ou nos dois em momentos
diferentes do rollout, sem quebrar nada.

```pascal
Client.CompressionMinSize := 512; // so' tenta comprimir payload >= 512 bytes
Client.SendText(JsonGrandeERepetitivo); // vai comprimido se compensar
```

Só `SendBytes`/`SendText`/`Request`/`Publish` (e as versões em lote) são candidatos —
payload abaixo do mínimo, ou que não compensa (dado já compresso tipo imagem), sai cru sem
aviso nenhum: é uma otimização silenciosa, não uma garantia de formato no fio. `BytesSent`/
`BytesReceived` de `Stats` continuam contando o payload LÓGICO (visão do app); quem quer ver
a economia real de banda usa os campos irmãos `BytesSentWire`/`BytesReceivedWire` (ver seção
"Métricas/observabilidade" acima) — inclusive do lado de quem SÓ RECEBE, que de outro jeito
não teria como saber (a descompressão já devolve os bytes lógicos antes do app ver o frame).
`MaxMessageSize` é validado no payload ORIGINAL antes de comprimir, e a decodificação
tem proteção contra zip bomb (payload comprimido pequeno que "explode" ao descomprimir):
o teto é o mesmo `MaxMessageSize`, verificado durante a descompressão, não só no resultado
final. Racional completo (por que é um kind novo do NPF1 e não um bit de flag) em
`docs/ARQUITETURA.md`.

### Descoberta de servidor na LAN (`Pipes.Discovery`)

"Onde está o servidor?" sem digitar IP: o servidor anuncia a si mesmo com um
`TPipeDiscoveryResponder` e o cliente pergunta por broadcast UDP com
`PipeDiscoverServers`. A resposta traz o endereço pronto para `Address` (o IP é o
endereço de origem da resposta — funciona certo até com servidor multi-NIC), o
transporte e um nome de exibição. É um **complemento** aos transportes, não um
transporte: nada do NPF1 passa por aqui, e a segurança continua onde sempre esteve —
descoberta encontra candidatos, `ptTls` autentica quem é de verdade.

```pascal
// Lado servidor, junto do Listen:
Responder := TPipeDiscoveryResponder.Create(
  9000,               // porta do SERVICO (a do TPipeServer)
  ptTls,              // transporte que o cliente deve usar
  'Retaguarda Loja 3' // nome de exibicao
);                    // porta de descoberta e token opcionais
Responder.Start;

// Lado cliente, antes do Connect:
Encontrados := PipeDiscoverServers(1000); // janela de 1s na sub-rede
if Length(Encontrados) > 0 then
begin
  Client.Address := Encontrados[0].Address;         // 'ip:porta' pronto
  // sobrando mais de um, o resto vira failover:
  // Client.FailoverAddresses := [Encontrados[1].Address, ...];
  Client.Connect(5000);
end;
```

Lista vazia não é erro — é "ninguém respondeu" (a janela expira em silêncio). Um `Token`
opcional separa instalações que dividem a mesma rede (é discriminador, não autenticação).
Alcance é a **sub-rede local**: broadcast não atravessa roteador nem VPN — PDV remoto
continua com IP configurado + `FailoverAddresses`. A forma dirigida
`PipeDiscoverServers('192.168.1.10', ...)` sonda um host específico ("o servidor está
vivo?"). Detalhes e racional em `docs/ARQUITETURA.md` §16. Vitrine executável no sample
**EchoDiscovery** (ver [Samples](#samples-samples)).

## Recursos

- **Servidor multi-cliente** — acceptor + uma reader thread por conexão; `MaxClients`
  opcional; `SendBytes/SendText` por conexão; `Broadcast/BroadcastText`;
  `DisconnectClient`; eventos `OnClientConnected`/`OnClientDisconnected`.
- **Request-Reply síncrono** — `Request/RequestText(dados, timeout)` no cliente bloqueia o
  *chamador* (nunca a thread de leitura) até o reply correlacionado; no servidor, o handler
  `OnRequest` devolve o reply e a lib o envia com o correlation id certo. Exceção no
  handler vira reply de erro (`EPipeError` no cliente, com a mensagem do servidor).
  Chamadas concorrentes de várias threads no mesmo cliente são suportadas.
- **Pub/sub por tópico** — quem envia nomeia um **assunto**, não um destinatário:
  `Server.Publish('caixa.3.status', dados)` chega a todos os clientes cujo filtro alcança o
  tópico, e a mais ninguém. O cliente assina com curingas hierárquicos
  (`Subscribe('caixa.*.status')`, `Subscribe('caixa.#')`) e recebe em `OnTopicMessage`.
  As assinaturas são **restauradas automaticamente** em cada reconexão. Opcionalmente o
  servidor **retém o último valor** de um tópico (`Publish(..., ARetain := True)`), entregue
  na hora a quem assinar depois. Ver [Pub/sub](#pubsub-tópicos).
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
- **Descoberta na LAN** (`Pipes.Discovery`) — `TPipeDiscoveryResponder` no servidor +
  `PipeDiscoverServers` no cliente acham o servidor na sub-rede por broadcast UDP, sem IP
  configurado; o resultado alimenta `Address`/`FailoverAddresses`. Ver
  [Descoberta de servidor na LAN](#descoberta-de-servidor-na-lan-pipesdiscovery).

## Pub/sub (tópicos)

`SendBytes` precisa de um `ConnId`; `Broadcast` vai para todo mundo. Entre os dois falta o
caso mais comum de um sistema com várias pontas: **mandar por assunto**, sem que o remetente
saiba quem está interessado. É o que o pub/sub resolve.

```pascal
// --- servidor ---
Server.Publish('caixa.3.status', dados);              // só quem assinou o assunto recebe
Server.PublishText('loja.tabela.versao', 'v42', True); // True = retém o último valor

// --- cliente ---
Client.OnTopicMessage := Self.Recebeu;   // (...; const ATopic; const AData; ARetained)
Client.Subscribe('caixa.*.status');      // um segmento no lugar do '*'
Client.Subscribe('loja.#');              // tudo abaixo de 'loja'
Client.PublishText('caixa.3.status', 'ocupado');
```

**Nomes e curingas.** Tópico é hierárquico, separado por ponto, sensível a caixa e sem
segmento vazio. Quem publica usa nome literal; quem assina pode usar curingas, sempre
ocupando um segmento inteiro:

| Filtro | Alcança | Não alcança |
|---|---|---|
| `caixa.3.status` | `caixa.3.status` | `caixa.4.status` |
| `caixa.*.status` | `caixa.3.status` | `caixa.3.a.status` |
| `caixa.#` | `caixa.3`, `caixa.3.a.b`, `caixa` | `loja.3` |

`#` só pode ser o último segmento (`a.#.b` é recusado: as duas leituras possíveis dariam
resultados diferentes). `caixa*` também é recusado — curinga colado em texto prometeria um
casamento parcial que a lib não faz. `Subscribe` levanta `EPipeError` na hora para filtro
inválido; um `Publish` com nome inválido também.

**Quem pode retransmitir.** Uma publicação de **cliente** não vai para os outros clientes
por padrão: ela chega ao servidor em `OnPublish`, que decide. Ligar
`RelayClientPublish := True` faz a lib retransmitir sozinha (incluindo de volta ao próprio
autor, se ele assinar o tópico) — cômodo para um chat, e perigoso num sistema onde um
cliente não deveria poder injetar conteúdo no assunto de outro. O padrão desligado deixa o
servidor autoritativo, como nos samples de jogo:

```pascal
procedure TRetaguarda.OnPublicacaoDeCliente(Sender: TObject; AConnId: TPipeConnectionId;
  const ATopic: string; const AData: TBytes);
begin
  if not PipeTopicMatches('caixa.*.status', ATopic) then Exit;  // fora do lugar: ignora
  Server.Publish(ATopic, AData, True);                          // republica retendo
end;
```

**Retenção (`ARetain`) é cache de último valor, não fila.** O servidor guarda **uma**
mensagem por tópico e a entrega a quem assinar depois — é a resposta para "o cliente que
acabou de ligar precisa do estado atual" sem que ele tenha de pedir. Publicar com corpo
vazio e `ARetain := True` apaga o valor retido. O teto é `MaxRetained` (256 por padrão;
além dele o tópico retido mais antigo sai). Mensagem que precise sobreviver ao processo, ou
ser entregue com garantia, pede uma fila de verdade — para isso existe o
[pascal-amqp-faa](https://github.com/fabianoallex/pascal-amqp-faa).

O último parâmetro de `OnTopicMessage`, **`ARetained`**, responde a pergunta que o
consumidor precisa fazer: *isto acabou de acontecer, ou é o valor que já vigorava?*
`True` só em catch-up de assinatura; uma publicação ao vivo chega **sempre** `False`,
mesmo quando o publicador pediu retenção (semântica do MQTT, e pela mesma razão: quem
recebe quer saber se a mensagem é notícia ou histórico, não o que o remetente pediu ao
servidor). Use para não tocar campainha nem contar venda duas vezes ao reconectar. Do lado
do servidor, o `ARetained` de `OnPublish` tem o outro sentido — o único possível ali: o
cliente **pediu** para reter.

**Reconexão.** As assinaturas são estado desejado do cliente, não da sessão: `Subscribe`
funciona desconectado, e tudo é reenviado ao servidor a cada nova sessão **antes** de
`OnConnected` disparar — o seu handler não precisa reassinar nada. O que não se recupera é
a janela entre a queda e a reassinatura: publicação que passou ali está perdida (é aí que o
retain ajuda).

**Ordem e limites.** A entrega de um mesmo publicador preserva a ordem; entre publicadores
diferentes, não há ordem global (use `pdmSerialized` se precisar de FIFO nos seus handlers).
`OnPublish`, `OnSubscribe` e `OnUnsubscribe` são **notificações** — o roteamento já
aconteceu quando eles rodam, e não há como vetar de dentro deles; para negar uma assinatura,
chame `DisconnectClient`. `MaxSubscriptionsPerClient` (64 por padrão) limita quantos filtros
um cliente pode registrar; a recusa aparece em `OnError` **nos dois lados**, e a conexão
continua de pé.

**Compatibilidade de wire.** Os tipos de frame do pub/sub são novos no protocolo `NPF1`. Um
peer compilado com uma versão anterior da lib que receba um deles cai com `EPipeProtocol`
("o peer provavelmente fala uma versão mais nova do protocolo") em vez de interpretar bytes
errados — atualize os dois lados.

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
  Address, Transport, KeepAliveSeconds, HeartbeatIntervalMs, Active, DispatchMode,
  MaxMessageSize
  CompressionMinSize                     // 0 (padrao) = producao desligada; decodificacao
                                          // de frames recebidos e' sempre ativa
  TlsOptions: TPipeTlsConfig             // só usado em ptTls; lido no Listen/Connect
    CertFile, CertPassword, KeyFile, CaFile, SkipServerVerification, HandshakeTimeoutMs
  OnMessage: TPipeMessageEvent;  OnError: TPipeErrorEvent

TPipeServer
  Listen; Stop;                          // Listen não-blocante; Stop síncrono
  SendBytes/SendText(ConnId, ..., AGroupKey = '')  // EPipeError se ConnId não existe
                                          // AGroupKey: ordem entre chamadas preservada no
                                          // OnMessage do RECEPTOR mesmo em pdmPool (o
                                          // padrão); chaves diferentes continuam paralelas
  SendBytesBatch(ConnId, TArray<TBytes>) // N mensagens, um Write só; ordem preservada
  Broadcast/BroadcastText(...)           // snapshot; falha por conexão é engolida
  Publish/PublishText(Topico, ..., Retain = False)  // só quem assinou o tópico
  PublishBatch(TArray<TPipePublishItem>) // N itens (Topic/Payload/Retain); um Write por conexão
  SubscriberCount(Topico)                // quantos receberiam uma publicação
  ClientSubscriptions(ConnId)            // filtros que aquele cliente assinou
  ClearRetained                          // valores retidos não morrem no Stop
  RelayClientPublish                     // False: cliente não injeta nos outros
  MaxSubscriptionsPerClient; MaxRetained
  OnPublish: TPipeTopicEvent             // notificação: o fanout já ocorreu
                                         // ARetained aqui = o cliente PEDIU para reter
  OnSubscribe/OnUnsubscribe: TPipeSubscriptionEvent  // idem; negue com DisconnectClient
  DisconnectClient(ConnId)               // assíncrono e idempotente
  ClientCount; ClientIds                 // só conexões ESTABELECIDAS
  TryClientIdentity(ConnId, out Ident)   // quem é, pelo certificado mTLS validado
  TryClientAddress(ConnId, out Addr)     // 'ip:porta'; False em ptLocal (sem endereco IP)
  MaxClients                             // limite de recurso: conta as em handshake
  OnClientConnected/OnClientDisconnected: TPipeConnectionEvent
  OnRequest: TPipeRequestEvent           // (const ARequest: TBytes; out AReply: TBytes)
  Stats: TPipeServerStats                // agregado, cumulativo desde o Listen
  ConnectionStats(ConnId, out Stats): Boolean  // por conexao; morre com ela

TPipeClient
  Connect(TimeoutMs); Disconnect;        // Connect re-tenta até o prazo
  SendBytes/SendText(..., AGroupKey = '')  // fire-and-forget; AGroupKey ver TPipeServer acima
  SendBytesBatch(TArray<TBytes>)         // N mensagens, um Write só; ordem preservada
  Request/RequestText(..., TimeoutMs)    // RPC síncrono; EPipeTimeout no prazo
  Subscribe/Unsubscribe(Filtro)          // funciona desconectado; refeito na reconexão
  Subscriptions                          // filtros assinados (estado desejado)
  Publish/PublishText(Topico, ...)       // EPipeClosed sem sessão
  PublishBatch(TArray<TPipePublishItem>) // N itens (Topic/Payload/Retain), um Write só
  OnTopicMessage: TPipeTopicEvent        // (...; ATopic; AData; ARetained)
                                         // ARetained: True só em catch-up de assinatura
  Connected; AutoReconnect; ReconnectDelayMs; MaxReconnectAttempts
  FailoverAddresses: TArray<string>      // tentados apos Address; vazio = so Address (padrao)
  ActiveAddress                          // qual endereco a sessao atual usa (snapshot)
  OnConnected/OnDisconnected: TPipeConnectionEvent
  Stats: TPipeClientStats                // da SESSAO atual; zera a cada reconexao

Pipes.Topics (unit pura, útil também fora da lib)
  PipeTopicMatches(Filtro, Topico); PipeIsValidTopic; PipeIsValidTopicFilter
  TPipePublishItem = record Topic; Payload: TBytes; Retain: Boolean; end  // ver PublishBatch

Pipes.Json (OPCIONAL — só inclui quem for usar; ver "JSON" abaixo)
  TPipeJSONValue                         // = TJSONValue (Delphi) / TJSONData (FPC)
  PipeBytesToJSON(Data): TPipeJSONValue  // parse; EPipeJSONError se inválido/vazio
  PipeJSONToBytes(Value): TBytes         // serializa; não libera Value
  PipeSendJSON(Client/Server, ..., Value)     // wrapper de SendBytes
  PipeRequestJSON(Client, Value, TimeoutMs): TPipeJSONValue  // wrapper de Request

Pipes.Commands (OPCIONAL — só inclui quem for usar; ver "Comandos" abaixo)
  TPipeCommandRouter.RegisterCommand(Comando, Handler, AMinSize = -1, AMaxSize = -1)
                                          // EPipeCommandError: duplicado, handler nil,
                                          // nome/limites invalidos (erro de programacao)
  TPipeCommandRouter.HandleMessage       // mesma assinatura de TPipeMessageEvent;
                                          // atribua direto a Server/Client.OnMessage
  OnUnknownCommand; OnInvalidPayload: TPipeCommandEvent  // opcionais, silenciosos
  TPipeCommandRouter.RegisterRequestCommand(Comando, Handler, AMinSize = -1, AMaxSize = -1)
                                          // registro PROPRIO, independente do de mensagem
  TPipeCommandRouter.HandleRequest       // mesma assinatura de TPipeRequestEvent;
                                          // atribua direto a Server.OnRequest — LEVANTA
                                          // (EPipeProtocol) em comando desconhecido/payload
                                          // invalido, ao contrario de HandleMessage
  PipeEncodeCommandPayload/PipeDecodeCommandPayload(Comando, Corpo)  // envelope manual

Exceções: EPipeError > EPipeClosed | EPipeTimeout | EPipeProtocol | EPipeTls |
          EPipeJSONError | EPipeCommandError
```

### JSON (`Pipes.Json.pas`, opcional)

A API trafega `TBytes`; texto vira JSON como qualquer outro texto — `SendText`/
`RequestText` já bastam se o app monta e lê o JSON com a lib da sua preferência. O que
`Pipes.Json.pas` acrescenta é só a fronteira bytes↔JSON usando a lib nativa de cada
compilador (`System.JSON` no Delphi, `fpjson`/`jsonparser` no FPC), escondida atrás do
alias `TPipeJSONValue`, mais dois wrappers finos (`PipeSendJSON`/`PipeRequestJSON`) sobre
`SendBytes`/`Request`. Não faz parte do core — `Pipes.Client`/`Pipes.Server` não a
conhecem — e não precisa ser incluída por quem não for usar JSON.

Construir e ler o valor (`AddPair` vs `Add`, `GetValue<T>` vs `Get`) continua sendo a API
nativa de cada lib; unificar isso também não está no escopo da unit — quem tiver um caso
específico (outro formato, outra lib JSON) implementa por conta própria em cima de
`TBytes`/`SendBytes`, sem nenhuma penalidade.

```pascal
uses Pipes.Client, Pipes.Json, System.JSON; // ou fpjson no FPC

var
  Obj, Reply: TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('evento', 'abriu-caixa');
    Obj.AddPair('caixa', TJSONNumber.Create(3));
    PipeSendJSON(Client, Obj);              // fire-and-forget

    Reply := PipeRequestJSON(Client, Obj, 3000) as TJSONObject; // RPC síncrono
    try
      // ... Reply.GetValue<...>(...)
    finally
      Reply.Free;
    end;
  finally
    Obj.Free;
  end;
end;
```

### Comandos (`Pipes.Commands.pas`, opcional)

Quando o app trafega várias operações na mesma conexão (`SALVAR_PEDIDO`, `CANCELAR`,
`PING`, ...), a alternativa a uma cadeia de `if`/`case` dentro de um único `OnMessage` é
`TPipeCommandRouter`: um `RegisterCommand` por comando, cada um com seu próprio handler.
Não muda nada no fio — o nome do comando viaja dentro do payload, e `HandleMessage` tem a
mesma assinatura de `OnMessage`, então basta atribuir direto:

```pascal
uses Pipes.Server, Pipes.Commands;

var
  Router: TPipeCommandRouter;
begin
  Router := TPipeCommandRouter.Create;
  Router.RegisterCommand('PING', OnPing);
  Router.RegisterCommand('SALVAR_PEDIDO', OnSalvarPedido, 1); // AMinSize = 1: corpo nao pode vir vazio
  Server.OnMessage := Router.HandleMessage;
  Server.Listen;
end;

procedure TMeuApp.OnSalvarPedido(Sender: TObject; AConnId: TPipeConnectionId;
  const ACommand: string; const APayload: TBytes);
begin
  // APayload ja' vem SEM o prefixo do envelope, so' o corpo
end;
```

Quem envia monta o mesmo envelope com `PipeEncodeCommandPayload('SALVAR_PEDIDO', Dados)` e
manda por `SendBytes`/`Request` normalmente — não há wrapper de conveniência nesta versão.
`RegisterCommand` aceita `AMinSize`/`AMaxSize` opcionais (`PIPE_COMMAND_NO_LIMIT`, o padrão,
desliga o respectivo teto) validados ANTES do handler rodar, e levanta `EPipeCommandError`
na hora do registro se o comando já existir, o nome for inválido, o handler não estiver
atribuído ou os limites forem inconsistentes — erro de programação, não de rede. Comando
sem handler cai em `OnUnknownCommand`; payload fora da faixa ou envelope malformado caem em
`OnInvalidPayload` — os dois opcionais e silenciosos quando ninguém assina, do mesmo jeito
que um `OnMessage` sem assinante. Nomes de comando são case-sensitive (mesmo raciocínio dos
tópicos: não há upcase portátil para UTF-8). Racional completo, inclusive por que é por
CIMA de `OnMessage` em vez de um kind novo do NPF1, em `docs/ARQUITETURA.md` §18.

O mesmo roteador também cobre o lado request-reply, com registro e método PRÓPRIOS
(`RegisterRequestCommand`/`HandleRequest`, independentes de `RegisterCommand`/
`HandleMessage` — o mesmo nome de comando pode existir nos dois sem conflito, porque
`OnMessage`/`OnRequest` já chegam por kinds diferentes no fio):

```pascal
Router.RegisterRequestCommand('SOMAR', OnSomarRequest, 1); // AMinSize = 1
Server.OnRequest := Router.HandleRequest; // mesma assinatura de TPipeRequestEvent

procedure TMeuApp.OnSomarRequest(Sender: TObject; AConnId: TPipeConnectionId;
  const ACommand: string; const APayload: TBytes; out AReply: TBytes);
begin
  AReply := ...; // vira o reply; SEM envelope — quem chamou Request ja sabe o comando
end;
```

O contrato de erro é o OPOSTO do lado mensagem, de propósito: `HandleRequest` LEVANTA
(`EPipeProtocol`) em comando desconhecido ou payload fora da faixa, em vez de chamar
`OnUnknownCommand`/`OnInvalidPayload` — não há esses eventos deste lado. A razão é que
`TPipeServer.ExecuteRequest` já transforma QUALQUER exceção vinda do `OnRequest` num reply
de erro para o cliente (o `Request` do lado cliente relança como `EPipeError`), o mesmo
caminho que o sample `EchoJsonServer` já usa de propósito com `EPipeJSONError` — e, ao
contrário de `OnMessage`, um `Request` sempre recebe ALGUMA resposta, então não existe um
"silêncio" equivalente para reaproveitar. Racional completo em `docs/ARQUITETURA.md` §18.8.

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
  começando com `?` usam `RequestText` (RPC). Os dois aceitam um segundo parâmetro opcional
  `tcp` (`EchoServer.exe *:5300 tcp`, `EchoClient.exe 192.168.0.10:5300 tcp`) para trocar
  `ptLocal` por `ptTcp` — é como o **EchoAndroid** fala com eles, já que celular não alcança
  Named Pipe nem Unix Domain Socket. Sem o parâmetro, o comportamento é o de sempre.
- **EchoJson** (`EchoJsonServer` + `EchoJsonClient`) — o mesmo eco, mas com payload JSON via
  `Pipes.Json.pas` em vez de texto cru (ver seção "JSON" acima). Digite `item quantidade`
  (ex.: `cafe 2`) para `PipeSendJSON` fire-and-forget — a
  confirmação assíncrona chega em `OnMessage` — ou `?item quantidade` para `PipeRequestJSON`
  síncrono, com o total calculado pelo servidor no reply. Mostra também a única parte que
  `Pipes.Json.pas` não esconde: montar/ler o valor (`AddPair` vs `Add`, `GetValue<T>` vs
  `Get`) é `{$IFDEF FPC}` local ao sample, atrás de duas funções pequenas (`JStr`/`JInt`).
- **EchoCommand** (`EchoCommandServer` + `EchoCommandClient`) — vitrine de
  `TPipeCommandRouter` dos dois lados (ver seção "Comandos" acima): comandos
  fire-and-forget (`PING`/`ECO` no servidor, `PONG`/`ECO_OK` no cliente, via `OnMessage`) e
  um comando request-reply (`SOMAR`, via `OnRequest`/`Request`), cada um com seu próprio
  handler em vez de uma cadeia de `if`. Digite `ping`/`eco <texto>` para os assíncronos,
  `?soma <a> <b>` para o RPC síncrono (soma dois inteiros) — e `?ping` para ver o caminho de
  "comando desconhecido" do lado request-reply de propósito: `PING` só está registrado do
  lado mensagem, então pedi-lo como `Request` levanta `EPipeError` no cliente. `SendCommand`
  de conveniência continua fora desta versão, então o envio é `PipeEncodeCommandPayload` +
  `SendBytes`/`Request` direto no app.
- **EchoFailover** (só `EchoFailoverClient` — reaproveita o `EchoServer.exe` de sempre, rodado
  duas vezes) — vitrine de `FailoverAddresses`/`ActiveAddress` (ver seção "Failover de
  endereço" acima). Suba `EchoServer.exe pipes_faa_primario` e
  `EchoServer.exe pipes_faa_backup`, depois
  `EchoFailoverClient.exe pipes_faa_primario pipes_faa_backup`: troque mensagens (o log
  mostra `endereço ativo: pipes_faa_primario`), derrube a janela do primário e troque
  mensagens de novo — sem reiniciar o cliente, o log passa a mostrar
  `endereço ativo: pipes_faa_backup`. Roteiro completo no cabeçalho de
  `EchoFailoverClient.dpr`.
- **EchoDiscovery** (só `EchoDiscoveryClient` — reaproveita o `EchoServer.exe` de sempre,
  com um parâmetro a mais) — vitrine de `Pipes.Discovery` (ver seção "Descoberta de
  servidor na LAN" acima). Suba `EchoServer.exe *:5300 tcp discover` (o `discover` no fim
  liga um `TPipeDiscoveryResponder` junto do `Listen`) e depois
  `EchoDiscoveryClient.exe` sem argumento nenhum: ele sonda a sub-rede por 1s, loga
  `encontrado: "EchoServer" em <ip>:5300 (ptTcp)` e conecta sozinho, nenhum IP digitado.
  Com `EchoServer.exe *:5300 tls ..\..\tests\pki mtls discover` +
  `EchoDiscoveryClient.exe ..\..\tests\pki cli` dá pra ver a distinção do §16.4 na prática:
  a descoberta só acha o candidato (endereço, transporte, nome) — quem autentica de
  verdade é o handshake `ptTls`/mTLS que vem a seguir, não a sonda UDP.
- **EchoSeguro** (`EchoSeguroServer` + `EchoSeguroClient`) — o mesmo eco, mas sobre `ptTls`
  com mTLS: servidor exige certificado de cliente (`CaFile`), cliente apresenta o dele,
  tráfego cifrado ponta a ponta. Usa a PKI de teste versionada em `tests/pki`; um cliente sem
  certificado (ou um `TPipeClient` comum) é recusado antes de `OnClientConnected` disparar —
  prova de que o mTLS não é decorativo.
- **EchoAndroid** — cliente **Android** (FMX, só Delphi) do `EchoServer`: conecta por
  `ptTcp` ou `ptTls`, manda texto e mostra a resposta. Vitrine do que muda num celular —
  `pdmMainThread`, `Connect` fora da thread principal, `HeartbeatIntervalMs` ligado (Wi-Fi
  que dorme e NAT de operadora derrubam conexão ociosa em silêncio). O `LEIA-ME.md` do
  sample tem os passos de IDE que não dá para versionar no `.dproj`: permissão `INTERNET`,
  `usesCleartextTraffic` e o empacotamento do OpenSSL por ABI.
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
- **PontosECaixas** — o jogo "pontos e caixas" (dots and boxes) para dois jogadores, uma
  janela cada (VCL no Delphi, LCL no Lazarus, mesmo fonte). Um lado clica **Hospedar**, o
  outro digita o endereço e clica **Entrar**; o combo escolhe `ptLocal` (duas janelas na
  mesma máquina) ou `ptTcp` (duas máquinas) — o código do jogo não muda, só o valor de
  `Transport`. O que ele mostra e os outros não:
  **servidor autoritativo** (o hospedeiro tem a única `TJogoPartida` que vale; o convidado
  *pede* a jogada e espera o estado voltar, nunca aplica a própria — jogar fora da vez ou
  numa aresta já usada é recusado no mesmo `TentarJogar` que valida o clique local);
  **reconexão que devolve a vaga** (o convidado repete um token no `OnConnected`, que a lib
  dispara também a cada reconexão automática — feche a janela dele no meio da partida e
  reabra para ver o tabuleiro voltar inteiro); **duas camadas de recusa com papéis
  diferentes** (`MaxClients` é teto de recurso, "a partida já tem dois jogadores" é regra de
  negócio no `OI`, e por isso consegue mandar o motivo antes de desligar); e o tratamento da
  **conexão zumbi** — quando o mesmo token chega numa conexão nova, a anterior costuma
  continuar viva no servidor (TCP morto em silêncio, típico de VPN/NAT) e é derrubada com
  `DisconnectClient` antes de a vaga ser reatribuída.
  Mostra também o preço de sincronizar por **estado** em vez de por evento: o tabuleiro
  completo não diz *o que mudou*, então quem recebe não saberia onde o adversário jogou —
  a aresta simplesmente apareceria. O `ESTADO` carrega por isso a última aresta jogada, que
  a UI realça por ~0,6 s (aresta que engrossa e clareia + anéis expandindo nos dois pontos).
  Duas marcações no momento de entrar ligam o jogador controlado por IA (`Jogo.Ia.pas`,
  heurística de cadeias com *double-cross*): **"computador joga por mim"**, válida nos dois
  papéis — no convidado o bot vira um cliente autônomo, mandando `JOGADA` pela rede e
  passando pela mesma validação de qualquer humano — e **"computador ocupa a vaga do
  convidado"**, que dá a partida solo contra a máquina (aí um humano que tentar entrar é
  recusado com o motivo). Marcando as duas, dá para assistir bot contra bot.
- **PingPong** — o pong clássico para dois jogadores, uma janela cada, mesmo esquema de
  `Hospedar`/`Entrar` e mesmo combo `ptLocal`/`ptTcp` do PontosECaixas. **Para experimentar
  sozinho não precisa de segunda janela: marque "Computador ocupa a vaga do convidado" e
  clique Hospedar.** O que ele mostra e o PontosECaixas não mostra é o mundo que **anda
  sozinho** — e as cinco consequências disso:
  **o relógio do jogo não é o `TTimer`** (um acumulador mede o tempo real e dá quantos
  passos de 16 ms couberem, senão a bola andaria mais rápido ou mais devagar conforme o
  jitter do timer, e as duas telas divergiriam);
  **entrada vai por borda, estado vem por nível** (o convidado só manda `ENTRADA` quando a
  direção da raquete *muda*, o hospedeiro manda a fotografia inteira ~31x por segundo —
  a primeira escolha só é segura porque o transporte é confiável e ordenado, e seria um bug
  em UDP);
  **o convidado prevê** (roda a mesma física localmente entre um snapshot e o próximo, com
  `AEhAutoridade = False`: prever movimento é uma coisa, decidir ponto é outra — o espelho
  que vê a bola sair do campo apenas para, e espera o `ESTADO` dizer o que houve);
  **até a previsão tem prazo** (1,5 s sem snapshot e ela congela, com a tela dizendo isso,
  em vez de animar uma partida que talvez não exista mais);
  e **o bot não tem timer** — é chamado dentro do passo de simulação, junto com a física,
  e a direção que ele devolve entra pela mesma porta do teclado (no convidado, vira
  `ENTRADA` na rede). Os números de ponto flutuante vão no fio como inteiro em centésimos
  de propósito: `FloatToStr` usa o separador decimal do *locale*, e um hospedeiro pt-BR
  mandando `412,75` para um convidado en-US é um bug de rede que ninguém procura.
  O nível do bot (`Pong.Ia.pas`) mexe só no **horizonte de reação** e na qualidade da
  previsão, nunca na velocidade da raquete — ver no cabeçalho da unit por que essa é a
  única alavanca que fecha ponto.
  Junto vai o **`PongCheck`**, um programa de console no mesmo diretório que verifica o
  núcleo do jogo **sem abrir janela e sem esperar o relógio**: ele roda ~48 minutos de jogo
  simulado em ~40 ms. Só é possível porque as três units de jogo não dependem nem da UI nem
  da biblioteca (`uses SysUtils` e mais nada), o que é o argumento prático para a separação
  que o sample prega. Ele confere o round-trip do `ESTADO` campo a campo, que o espelho
  **não pontua sozinho** depois de 15 s sem snapshot, o erro da previsão em quatro
  combinações de taxa, e que o bot fecha ponto nos três níveis — foi ele que pegou a
  primeira versão do bot, em que dois "médios" empatavam por dez minutos. Semente de
  `Random` fixa, para uma falha ser reproduzível. Não cobre `uPongMain.pas` nem a
  biblioteca: é teste do núcleo puro, não de integração.
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
  Ao final imprime `Client.Stats`: é a vitrine de latência de Request (média/máxima), a
  métrica que só faz sentido com tráfego concorrente como este.
- **GatewaySeguro** (`ServicoLocal` + `GatewaySeguro` + `ClienteRemoto`) — o único sample em que
  `TPipeServer` e `TPipeClient` estão **vivos ao mesmo tempo** no mesmo processo, com
  transportes diferentes em cada ponta:
  `[ClienteRemoto] --ptTls+mTLS--> [GatewaySeguro] --ptLocal--> [ServicoLocal]`. Os outros
  samples provam que o alcance é uma property; este prova que os alcances **se compõem**. O
  caso de uso é o que as pessoas realmente têm: um serviço que só fala IPC local e nunca vai
  aprender TLS, e a necessidade de expô-lo à rede com autenticação.
  O gateway autentica por mTLS, sabe quem é o par (`TryClientIdentity` devolve o `CommonName`
  **já validado contra a CA** — CN forjado não chega ali) e precisa **contar** ao serviço local
  quem está chamando (frame `IDENT|`), porque `ptLocal` não tem TLS e portanto não tem
  identidade nenhuma. Por que o serviço deveria acreditar? Porque `ptLocal` herda o controle de
  acesso do sistema operacional — **a segurança do gateway não vem do gateway; vem do alcance
  do transporte de trás**. Com o `ServicoLocal` em `ptTcp` ouvindo em `0.0.0.0`, o esquema
  inteiro cai: qualquer um pula o gateway e se declara quem quiser.
  Mostra também as **duas camadas de "conectado"** (o remoto pode autenticar com sucesso e
  ainda assim receber `RECUSADO|<motivo>` porque o `ServicoLocal` está fora do ar — handshake
  TLS concluído não é o mesmo que sessão útil, e por isso a recusa carrega motivo em vez de ser
  um socket fechado calado) e o padrão que evita o pior deadlock deste desenho:
  `TPipeClient.Disconnect` é síncrono (join da reader thread + `DrainInFlight`), então
  **nenhum `Free`/`Disconnect` de par acontece dentro de callback** — o callback só marca e um
  ceifador (`TThread` com fila e evento) destrói. O racional completo, com as invariantes de
  lock e o que ficou fora desta versão (relay de `Request`), está no cabeçalho de
  [`Gateway.Nucleo.pas`](samples/GatewaySeguro/Gateway.Nucleo.pas).
  `ClienteRemoto <endereço> <identidade>` escolhe o certificado: `cli` e `caixa` entram — rode
  os dois juntos e veja o `ServicoLocal` carimbar a identidade **certa** em cada resposta,
  porque cruzamento de identidade seria o pior bug possível num gateway; `rogue`, `selfsigned`
  e `nenhum` são recusados **e o `ServicoLocal` não registra absolutamente nada**, que é a prova
  de que não vazou nada para trás. Precisa da PKI de [`tests/pki/`](tests/pki/LEIA-ME.md).
  Roteiro de execução dos três processos (e checklist de regressão) em
  [`samples/GatewaySeguro/LEIA-ME.md`](samples/GatewaySeguro/LEIA-ME.md).
- **PainelLoja** — o sample de **pub/sub**: um executável, três papéis escolhidos pelo
  primeiro parâmetro, uma janela para cada.

  ```
  PainelLoja retaguarda        PainelLoja caixa 3        PainelLoja painel
  ```

  Nenhum dos três chama `SendBytes` com `ConnId` nenhum: a retaguarda publica em
  `loja.tabela.versao`, cada caixa publica `caixa.<n>.status`, o painel assina `caixa.#` e
  vê todos — **incluindo caixas que ainda não existiam** quando ele assinou. Adicionar um
  caixa não muda uma linha da retaguarda.
  O que ele mostra e os outros não: **relay desligado** (o padrão) com a retaguarda
  decidindo em `OnPublish` se republica, e usando `PipeTopicMatches` para conferir se o
  cliente publicou no lugar certo — o mesmo desenho autoritativo dos samples de jogo, agora
  sobre tópicos; e o **retain** trabalhando de verdade: **abra o painel por último** e ele
  desenha o estado atual da loja imediatamente, sem esperar o próximo tick de ninguém.
  Feche e reabra: ele reconstrói o estado, não a conversa — o retain guarda o último valor
  de cada tópico, não histórico. O caixa, com `AutoReconnect`, mostra os dois lados da
  moeda: publicar sem sessão **levanta** (ele registra e o próximo tick tenta de novo),
  enquanto as **assinaturas** voltam sozinhas, sem nada no `OnConnected`.
- **MonitorTopicos** — o pub/sub com **UI** (VCL no Delphi, LCL no Lazarus, mesmo fonte) e,
  na prática, uma **ferramenta**: serve para depurar o pub/sub de qualquer app feito com a
  lib. Uma janela `Hospedar`, as outras `Entrar`, mesmo combo `ptLocal`/`ptTcp` dos samples
  de jogo. Três coisas do recurso só ficam visíveis aqui:
  **assinatura manipulada ao vivo** (assine e cancele com o app rodando; melhor, monte a
  lista *desconectado* — `Subscribe` é estado desejado — conecte depois e ela já vale);
  **o efeito do `RelayClientPublish` num clique** (duas janelas cliente assinando o mesmo
  tópico: marque a caixa no hospedeiro e o que uma publica alcança a outra, desmarque e a
  entrega para na hora — é a decisão central do recurso, e a property não tem
  `EnsureInactive` justamente para permitir esse experimento);
  e **o caminho da recusa**, que nenhum outro sample exercita (baixe `MaxSubscriptions` e
  veja a assinatura ser recusada com a mensagem aparecendo nos **dois** lados, conexão de
  pé; digite `caixa*` e veja `EPipeError` na hora, antes de virar frame).
  A lista de recebidas carimba **`ret`** no que veio do cache de retidos, o que torna
  visível a diferença entre *desenhar o estado que já existia* e *acompanhar o que
  acontece*. Hospedando, o painel de assinaturas mostra **quem assinou o quê**
  (`ClientSubscriptions` por conexão) e a contagem de `SubscriberCount` do tópico do campo
  Publicar — a visão do roteador; como cliente, mostra as próprias, editáveis. Roteiro de
  2 minutos no cabeçalho de
  [`MonitorTopicos.dpr`](samples/MonitorTopicos/MonitorTopicos.dpr).
- **TransferenciaArquivos** — envio de arquivo com **UI** (VCL no Delphi, LCL no Lazarus,
  mesmo fonte), vitrine de `CompressionMinSize` e dos campos `*Wire` de `Stats`. Uma
  instância `Ser servidor` (salva o que chega em `recebidos/`), a outra `Ser cliente`
  (`Selecionar...` escolhe o arquivo, `Enviar arquivo` manda). O checkbox "Comprimir" só
  fica editável ANTES de conectar — trava depois, mesma regra de `MaxMessageSize`
  (`EnsureInactive`) — e mostra na prática por que é um kind novo no NPF1, não um bit de
  `Flags`: liga só de um lado sem quebrar nada no outro. Cada envio loga a economia real dos
  DOIS lados: o cliente pelo delta de `Client.Stats` (`BytesSent` vs `BytesSentWire`) antes/
  depois do `SendBytes`, e o servidor por `ConnectionStats.BytesReceivedWire` — a única forma
  de quem só RECEBE enxergar a economia, já que a descompressão devolve o payload lógico
  antes de `OnMessage` rodar (opaco por design). Protocolo do arquivo em si é só deste
  sample (não da lib): envelope `[TamanhoDoNome][NomeUTF8][Bytes]` cru sobre `SendBytes`,
  arquivo inteiro em memória — sem chunking, não é streaming de produção.

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
  `libssl 1.1.1` e **não** tem a 3.x, e compilar com `-dPIPES_OPENSSL` (sem a diretiva não
  há backend TLS e a suíte de `ptTls` não roda). Não é redundante com a anterior — é a
  única forma de exercitar as divergências 1.1/3.x, e **duas já morderam de verdade**:

  ```bash
  docker run --rm -v "$PWD:/work" debian:bullseye bash -c '
    apt-get update -qq && apt-get install -y -qq fpc libssl1.1 >/dev/null
    cd /work/tests/Integration/fpc
    fpc -MDelphi -Sh -B -dPIPES_OPENSSL -Fu../../../src -Fi../../../src       -FU/tmp -o/tmp/t PipesIntegrationTestsFpc.lpr
    /tmp/t --all --format=plain'
  ```

  1. O **fallback de símbolo** do getter do certificado do par, que o 3.x renomeou
     (`SSL_get_peer_certificate` → `SSL_get1_peer_certificate`). Com as duas versões
     instaladas o loader escolheria a 3.x e o ramo antigo nunca rodaria.
  2. A **validação por endereço IP** (`Tls_ValidaServidorPorIp_Aceita`). Endereço IP mora em
     SAN do tipo `iPAddress` e exige `X509_VERIFY_PARAM_set1_ip_asc`; na 3.x o
     `SSL_set1_host` aceita um literal de IP e mascara a diferença. Esse teste **passa na
     3.x com ou sem a correção** — só a imagem 1.1 o torna um guarda de verdade. Histórico
     em [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md) §13.9.

A suíte de integração inclui stress de encerramento (Stop sob flood < 2 s), detector de
vazamento de handle/fd em quedas abruptas repetidas e correlação RPC sob concorrência.

**Android não entra nessa suíte**: o FPC não compila para Android neste projeto e um APK não
tem runner de console, então o backend Android se verifica em aparelho, com a suíte FMX de
`tests/Android` (loopback: servidor e cliente no mesmo app). Ver `tests/Android/LEIA-ME.md`
para os limites numéricos de cada caso e a rodada de referência.

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
src/                 biblioteca (Pipes.Types, Pipes.Framing,
                     Pipes.Transport[.Windows|.Posix|.Android],
                     Pipes.Base, Pipes.Server, Pipes.Client, Pipes.Threading, pipes.inc)
                     pub/sub: Pipes.Topics (nomes, curingas e envelope; unit pura)
                     rede: Pipes.Transport.Tcp
                     TLS: Pipes.Transport.Tls (fachada) + .Schannel / .OpenSSL (backends)
                     descoberta LAN: Pipes.Discovery (broadcast UDP; complemento, nao transporte)
                     Pipes.Compression (deflate opcional, CompressionMinSize; kind pfkCompressed)
                     Pipes.Json (bytes<->JSON, OPCIONAL — nao acoplada ao core)
                     Pipes.Commands (roteador de comandos por nome, OPCIONAL, por
                     cima de OnMessage — nao acoplada ao core)
packages/            pipes_faa.lpk (pacote Lazarus)
samples/             EchoServer, EchoClient, EchoJson (Pipes.Json.pas, opcional),
                     EchoCommand (Pipes.Commands.pas, opcional),
                     EchoFailover (FailoverAddresses, reaproveita o EchoServer.exe),
                     EchoDiscovery (Pipes.Discovery, idem, so' o EchoServer.exe ganha
                     "discover" na linha de comando),
                     EchoSeguro (TLS + mTLS), ChatVcl, ChatSeguro,
                     PontosECaixas (jogo de turno), PingPong (jogo em tempo real),
                     PainelLoja (pub/sub por topico, tres papeis num exe),
                     MonitorTopicos (explorador de pub/sub com UI VCL/LCL),
                     PdvDualScreen (Operador + Cliente),
                     FilaImpressao, DespachoTarefas, ServicoInstavel, RpcConcorrente,
                     GatewaySeguro (ptTls -> ptLocal, servidor + cliente no mesmo processo),
                     TransferenciaArquivos (CompressionMinSize e Stats.*Wire, UI VCL/LCL),
                     EchoAndroid (FMX/Android, so Delphi)
tests/               Unit + Integration (DUnitX e FPCUnit, espelhados)
tests/Android/       suite de DEVICE do backend Android (loopback; sem par dual-compiler)
tests/pki/           PKI de TESTE versionada, sem valor de seguranca (ver LEIA-ME)
docs/ARQUITETURA.md  arquitetura completa (wire format, ciclo de vida das threads, racional)
Pipes.groupproj      grupo de projetos Delphi    Pipes.lpg  grupo Lazarus
```

## Licença

[MIT](LICENSE) — © 2026 Fabiano Arndt
