# Interoperabilidade — falando com `pascal-pipes-faa` de outra linguagem

> 🇬🇧 This document is also available in [English](INTEROP.en.md).

Este documento descreve o **protocolo de fio** que `TPipeServer`/`TPipeClient` usam, para
quem precisa escrever a outra ponta em outra linguagem (Python, C#, Go, Java, Rust, JS…).
Nada aqui depende de Delphi/FPC — é só formato binário sobre um fluxo de bytes.

- Fonte de verdade do formato: `src/Pipes.Framing.pas` (framing NPF1),
  `src/Pipes.Topics.pas` (envelope de tópico), `src/Pipes.Compression.pas` (kind 7),
  `src/Pipes.Commands.pas` (envelope de comando), `src/Pipes.Discovery.pas` (NPD1).
- Racional de *por que* cada decisão foi tomada: `docs/ARQUITETURA.md`.
- Se este documento divergir do código, o código vence — abra uma issue.

---

## 1. Modelo de comunicação

É **cliente/servidor** com uma conexão viva e full-duplex. Sobre a mesma conexão trafegam
quatro padrões, todos multiplexados pelo mesmo framing:

| Padrão | Quem inicia | Frames |
|---|---|---|
| Mensagem avulsa (fire-and-forget) | qualquer lado | `Message` (kind 0) |
| Request/reply (RPC com correlação) | **só o cliente** pergunta; o servidor responde | `Request` (1) → `Reply` (2) |
| Pub/sub por tópico | cliente assina; servidor entrega | `Subscribe` (4), `Unsubscribe` (5), `Publish` (6) |
| Heartbeat de aplicação | qualquer lado, se ligado | `Ping` (3) |

Observações que definem o que você precisa implementar:

- **O servidor nunca faz `Request` a um cliente.** `Request`/`Reply` são sempre
  cliente→servidor→cliente. Se o servidor quer falar espontaneamente com o cliente, ele
  manda `Message` ou `Publish`.
- **Não há handshake de aplicação.** A conexão abre (TCP, ou TCP+TLS) e os frames já podem
  fluir nos dois sentidos. Não há troca de versão, banner, nem "hello" — o `Magic` de cada
  frame é a única sincronização.
- Se o seu lado vai **assinar tópicos**, mande os `Subscribe` logo após o transporte
  conectar; é o que o cliente Delphi faz (inclusive reenviando as assinaturas depois de uma
  reconexão, antes de qualquer outro tráfego).

---

## 2. Camada de transporte

O lado Delphi escolhe o transporte na property `Transport`. Você abre o socket
correspondente:

| `Transport` | Ordinal | O que abrir |
|---|---|---|
| `ptLocal` | 0 | Named Pipe (Windows) ou Unix Domain Socket (Linux) — ver §2.3 |
| `ptTcp` | 1 | socket TCP puro |
| `ptTls` | 2 | socket TCP + TLS por cima |

Para interoperar, prefira **`ptTcp`** (ou `ptTls` se o tráfego sai da máquina). `ptLocal`
é implementável, mas é o caminho mais trabalhoso e sem ganho de portabilidade.

### 2.1 `ptTcp`

Socket TCP comum, `Address` no formato `host:porta` (IPv6 entre colchetes:
`[::1]:5000`; `*` é atalho de `0.0.0.0` no lado servidor). Sem opções especiais de
socket exigidas pelo protocolo. O lado Delphi liga **TCP keepalive do SO** por padrão
(`KeepAliveSeconds`), mas isso é transparente para você — não passa nenhum byte no fio.

### 2.2 `ptTls`

TCP + TLS 1.2+ padrão. O cliente Delphi:

- envia **SNI** com o host de `Address`;
- **não** usa ALPN;
- valida o certificado do servidor contra o nome de `Address` (host) e a política de
  `TlsOptions` (CA confiável, etc.).

Se o servidor exigir **mTLS**, o seu lado precisa apresentar um certificado de cliente que
encadeie até a CA que o servidor confia. Depois do handshake TLS, o conteúdo é NPF1 puro —
o TLS é só um túnel.

### 2.3 `ptLocal` (se você realmente precisar)

- **Windows:** Named Pipe em modo byte. Nome: `Address` puro (`"MeuServico"`) vira
  `\\.\pipe\MeuServico`; se `Address` já começa com `\\`, é usado como está.
- **Linux:** Unix Domain Socket (`AF_UNIX`, `SOCK_STREAM`) baseado em arquivo. `Address`
  puro (`"MeuServico"`) vira `/tmp/MeuServico.sock`; se `Address` começa com `/`, é o
  caminho do socket. **Não** é abstract namespace.
- **Android:** `ptLocal` não existe — o servidor recusa. Use `ptTcp`/`ptTls`.

Em cima do pipe/socket, o framing é **idêntico** ao de `ptTcp`. Não se usa
`PIPE_READMODE_MESSAGE` — as fronteiras são do NPF1, não do transporte.

---

## 3. Framing NPF1

Todo frame é um **header de 20 bytes + payload**. Todos os campos multibyte são
**little-endian**.

```
 offset  campo      bytes  conteúdo
 ------  ---------  -----  ---------------------------------------------------
   0     Magic        4    'N','P','F','1'  = 0x4E 0x50 0x46 0x31
   4     Kind         1    0..7 (ver §4)
   5     Flags        1    campo de bits (ver §3.1)
   6     Reserved     2    0x00 0x00  (sempre zero; ignore na leitura)
   8     CorrId       8    uint64 LE — correlação request/reply (ver §5)
  16     Length       4    uint32 LE — tamanho do payload em bytes
  20     Payload    Length bytes crus (texto = UTF-8)
```

O tamanho total do frame é `20 + Length`.

### 3.1 Flags

| Bit | Máscara | Nome | Significado |
|---|---|---|---|
| 0 | `0x01` | ERROR | Só em `Reply` (kind 2): a resposta é um erro; o payload é a mensagem de erro em UTF-8. |
| 1 | `0x02` | RETAIN | Só em `Publish` (kind 6): o servidor deve reter esta mensagem como último valor do tópico. Payload vazio + este bit = apaga o retido. |

Os demais bits são reservados (zero). Ignore bits desconhecidos em kinds onde eles não se
aplicam.

### 3.2 Regras de leitura (obrigatórias)

1. **Leia exatamente N bytes num laço.** TCP e pipes entregam parcial: um `recv`/`read`
   pode devolver menos que o pedido. Nunca assuma "um pacote = um frame".
2. **Vários frames podem vir grudados** num único segmento TCP ou numa única escrita (o
   lado Delphi tem envio em lote — `SendBytesBatch`/`PublishBatch`). Faça o parsing pelo
   campo `Length`, nunca pela fronteira do `recv`.
3. **`Magic` inválido → feche a conexão.** Significa stream fora de sincronia; não tente
   ressincronizar.
4. **`Kind > 7` → feche a conexão** com erro claro. Quase sempre significa que o peer fala
   uma versão mais nova do protocolo (foi assim que os kinds 4–7 entraram), não lixo na
   linha.
5. **`Length` acima do seu teto → feche a conexão.** Escolha um teto sensato (o padrão do
   lado Delphi é 16 MiB, configurável via `MaxMessageSize`). É a defesa contra um length
   corrompido ou hostil que faria você alocar gigabytes.
6. **EOF no meio de um frame** = truncamento/queda abrupta. EOF exatamente na fronteira
   entre frames = encerramento limpo.

### 3.3 Regras de escrita (obrigatórias)

1. **Header + payload numa única chamada** `send`/`write` (ou bufferize e descarregue de
   uma vez). Isso evita entrelaçar frames de threads concorrentes no mesmo socket.
2. Se você tem **múltiplas threads** escrevendo na mesma conexão, serialize as escritas com
   um lock — o lado Delphi faz isso (um write lock por conexão).
3. Valide o tamanho do seu payload contra o teto **antes** de escrever qualquer byte.

### 3.4 Texto

Onde o protocolo carrega texto (payload de `*Text`, mensagem de erro, nome de tópico, nome
de comando) é **sempre UTF-8**, sem BOM.

---

## 4. Kinds

| Kind | Nome | Sentido | Precisa implementar se… |
|---|---|---|---|
| 0 | `Message` | qualquer lado → qualquer lado | você usa mensagens avulsas |
| 1 | `Request` | cliente → servidor | você faz RPC a partir do cliente |
| 2 | `Reply` | servidor → cliente | idem |
| 3 | `Ping` | qualquer lado | o lado Delphi liga `HeartbeatIntervalMs` (ver §7) |
| 4 | `Subscribe` | cliente → servidor | você assina tópicos |
| 5 | `Unsubscribe` | cliente → servidor | você cancela assinaturas |
| 6 | `Publish` | servidor → cliente (e cliente → servidor se habilitado) | você usa pub/sub |
| 7 | `Compressed` | qualquer lado | o lado Delphi liga `CompressionMinSize` (ver §8) |

O mínimo absoluto para um cliente request/reply funcional: **kinds 0, 1, 2**.

---

## 5. Message, Request e Reply

### 5.1 Message (kind 0)

- `CorrId`: normalmente `0`. **Pode chegar `!= 0`** — nesse caso é o hash de 64 bits de uma
  "chave de agrupamento" de despacho (ver Apêndice B). Para **receber**, ignore o valor:
  ele nunca muda o significado da mensagem. Para **enviar**, use `0` (a menos que você
  queira reproduzir a ordenação por grupo).
- `Flags`: `0`.
- Payload: os bytes da aplicação.

### 5.2 Request (kind 1) e Reply (kind 2)

Fluxo: o **cliente** manda `Request` com um `CorrId` que ele escolhe; o **servidor**
processa e responde com `Reply` carregando **o mesmo `CorrId`**.

Regras do `CorrId`:

- Deve ser **diferente de zero**.
- Deve ser **único entre os requests em voo** naquela conexão (depois que a resposta
  chega, pode reusar). O cliente Delphi usa um contador de 32 bits incremental promovido a
  uint64 — qualquer esquema equivalente serve.
- O servidor **ecoa o valor exatamente**; ele não interpreta o número.

Resposta de erro:

- `Kind = 2`, `Flags` com o bit `0x01` ligado.
- Payload = mensagem de erro em UTF-8 (ex.: texto de uma exceção do handler).
- O cliente Delphi transforma isso numa exceção `EPipeError` com o texto recebido.

Se a conexão cair antes da resposta, ou estourar o timeout do cliente, o `Request` falha
localmente — não há frame de "cancelamento" no fio.

---

## 6. Pub/sub (kinds 4, 5, 6)

O nome do tópico/filtro **não** fica no header; ele vai **no início do payload**, num
envelope. Isso mantém `Length` cobrindo o frame inteiro, então um peer antigo que não
entende o kind ainda para em sincronia.

### 6.1 Envelope de tópico

```
[ topicLen : uint16 LE ][ topic : topicLen bytes UTF-8 ][ body : resto do payload ]
```

- `topicLen` ≤ **255** (`PIPE_MAX_TOPIC_BYTES`). O campo tem 2 bytes por alinhamento, mas o
  valor nunca passa de 255.
- `Subscribe`/`Unsubscribe`: `body` é vazio; o "topic" é na verdade o **filtro** (pode ter
  curingas — ver §6.2).
- `Publish`: `body` é o conteúdo publicado; o "topic" é um nome concreto (sem curingas).

### 6.2 Regras de nome de tópico e de filtro

Segmentos separados por `.` (ponto). Um nome válido:

- não é vazio, não começa nem termina com `.`, não tem segmento vazio (`a..b` é inválido);
- não tem caracteres de controle (`< 0x20`);
- ≤ 255 bytes em UTF-8.

Um **filtro** (só em `Subscribe`/`Unsubscribe`) aceita, além disso, curingas **como
segmento inteiro**:

| Curinga | Casa |
|---|---|
| `*` | exatamente um segmento (qualquer valor) |
| `#` | zero ou mais segmentos — **só como último segmento do filtro** |

`caixa*` (curinga parcial) é inválido; `a.#.b` (`#` no meio) é inválido.

Exemplos: filtro `loja.*.status` casa `loja.caixa1.status`; filtro `loja.#` casa
`loja.caixa1` e `loja.caixa1.status`.

### 6.3 Semântica

- `Publish` com `Flags` `0x02` (RETAIN): o servidor guarda como último valor do tópico e
  entrega a quem assinar depois. `body` vazio + RETAIN apaga o retido.
- Ao assinar, o cliente recebe imediatamente os valores retidos que casam o filtro, cada um
  num `Publish` (kind 6).
- Um cliente **também** pode enviar `Publish` (kind 6) ao servidor, mas por padrão o
  servidor **não** repassa (`RelayClientPublish = False`); só repassa se o operador do
  servidor habilitar.
- A assinatura vive na conexão: se a conexão cai, as assinaturas somem. O cliente Delphi
  reenvia todas ao reconectar; se você implementa reconexão, faça o mesmo.

---

## 7. Ping / heartbeat (kind 3)

Só entra em jogo se o lado Delphi setar `HeartbeatIntervalMs` (padrão: **desligado**; e só
vale para `ptTcp`/`ptTls`). Quando ligado:

- Frame `Ping`: `Kind = 3`, `Flags = 0`, `CorrId = 0`, `Length = 0` (sem payload).
- **Simétrico e sem correlação:** não existe "Pong". **Qualquer** frame recebido (inclusive
  um `Ping`) reseta o relógio de vida que o peer observa.
- Regra de emissão: se você ficou `HeartbeatIntervalMs` sem **enviar** nada, mande um
  `Ping`.
- Regra de detecção: se você ficou mais de **2×** `HeartbeatIntervalMs` sem **receber**
  nada, considere o peer morto e feche a conexão.

Se o servidor não usa heartbeat, você não precisa enviar `Ping` — mas deve aceitar
receber um sem tratá-lo como erro (basta descartar; o efeito de "resetar o relógio" já
aconteceu ao receber o frame).

---

## 8. Compressão (kind 7)

Só entra em jogo se o lado Delphi setar `CompressionMinSize > 0` (padrão: **desligado**).
Quando ligado, o remetente comprime frames `Message`/`Request`/`Reply`/`Publish` cujo
payload alcança o mínimo **e** de fato encolhe. Se o servidor pode ter isso ligado, o seu
lado **precisa saber descomprimir** kind 7. O seu lado **nunca é obrigado a comprimir** —
mandar tudo sem compressão é sempre válido.

Formato do payload de um frame kind 7:

```
[ origKind : 1 byte ][ origFlags : 1 byte ][ deflate(origPayload) : resto ]
```

- `deflate(...)` é **raw DEFLATE** (RFC 1951), o mesmo que `zlib` produz com
  `windowBits = -15` / `Z_DEFLATE_RAW`. Não é gzip nem tem header zlib.
- O `CorrId` do frame kind 7 é o `CorrId` do frame original (correlação de request/reply e
  hash de group key atravessam sem mudança).
- Depois de inflar, você tem `origKind`, `origFlags` e `origPayload` — trate como se
  tivesse recebido esse frame diretamente.
- **Proteção contra zip bomb:** pare de inflar assim que o total descomprimido passar do
  seu teto (`MaxMessageSize`), durante a decodificação, não só no fim.
- Só esses quatro kinds são comprimíveis. `Ping` não tem payload;
  `Subscribe`/`Unsubscribe`/`Compressed` são estruturais.

---

## 9. Envelope de comando (`Pipes.Commands`) — camada de aplicação, opcional

Se o servidor usa `TPipeCommandRouter` para rotear por **nome de comando**, o nome vai
dentro do payload de um frame `Message` (kind 0) ou `Request` (kind 1), com **o mesmo
layout do envelope de tópico**:

```
[ cmdLen : uint16 LE ][ command : cmdLen bytes UTF-8 ][ body : resto do payload ]
```

- `cmdLen` ≤ **255** (`PIPE_MAX_COMMAND_BYTES`).
- Nomes de comando são **case-sensitive**.
- Isto **não** é parte do transporte — é convenção combinada com quem escreveu o servidor.
  Nada no header distingue "um kind 0 com envelope de comando" de "um kind 0 comum"; o
  servidor decide pelo roteador que ele instalou.
- Do lado `Request`, comando desconhecido ou payload fora da faixa vira um `Reply` de erro
  (bit `0x01`), porque o servidor transforma qualquer exceção do handler em erro.

---

## 10. Encerramento

- **Limpo:** feche o socket (FIN) numa fronteira entre frames. O outro lado vê EOF e
  encerra a sessão normalmente.
- **Abrupto:** RST, cabo removido, processo morto. O outro lado vê erro de socket ou (com
  heartbeat) o timeout de vida. Não há frame de "tchau".
- Não mande um frame parcial e feche — ou o frame inteiro, ou nada.

---

## 11. Limites e defaults

| O quê | Valor | Observação |
|---|---|---|
| Header | 20 bytes | fixo |
| Payload máximo | 16 MiB (padrão) | `MaxMessageSize` no lado Delphi; escolha o seu |
| Nome de tópico | ≤ 255 bytes UTF-8 | `topicLen` é uint16 mas nunca passa de 255 |
| Nome de comando | ≤ 255 bytes UTF-8 | idem |
| Ordem de bytes | little-endian | todos os campos multibyte, em todos os envelopes |
| Encoding de texto | UTF-8 sem BOM | |
| `CorrId` de request | uint64 != 0, único entre os em voo | |

---

## 12. Checklist mínimo (cliente request/reply em outra linguagem)

1. Abrir socket TCP para `host:porta` (ou TCP+TLS com SNI, se `ptTls`).
2. Função "ler N bytes exatos" num laço sobre `recv`.
3. Ler frame: 20 bytes de header → validar `Magic` → checar `Kind ≤ 7` → ler `Length`
   bytes de payload.
4. Escrever frame: montar header LE + payload, um `send` só.
5. `Request`: gerar `CorrId` != 0, enviar kind 1, guardar `CorrId` numa tabela de
   pendentes, aguardar o `Reply` (kind 2) com o mesmo `CorrId`; se bit `0x01`, é erro.
6. Tratar kind 0 (mensagens espontâneas do servidor) e kind 3 (ping — só descartar).
7. Fechar em `Magic` inválido, `Kind` desconhecido, `Length` acima do teto ou EOF no meio
   de um frame.

Pub/sub, heartbeat e compressão só entram se o servidor os usar.

---

## 13. Exemplos (hex)

Cada linha do header está anotada. `|` separa header de payload.

**Message (kind 0), payload `"hi"`, sem group key:**

```
4E 50 46 31   Magic 'NPF1'
00            Kind = 0 (Message)
00            Flags = 0
00 00         Reserved
00 00 00 00 00 00 00 00   CorrId = 0
02 00 00 00   Length = 2
| 68 69       payload "hi"
```

**Request (kind 1), `CorrId = 1`, payload `"ping"`:**

```
4E 50 46 31 01 00 00 00  01 00 00 00 00 00 00 00  04 00 00 00 | 70 69 6E 67
```

**Reply OK (kind 2), `CorrId = 1`, payload `"pong"`:**

```
4E 50 46 31 02 00 00 00  01 00 00 00 00 00 00 00  04 00 00 00 | 70 6F 6E 67
```

**Reply de erro (kind 2), `CorrId = 1`, Flags = ERROR, payload `"comando invalido"`:**

```
4E 50 46 31 02 01 00 00  01 00 00 00 00 00 00 00  10 00 00 00 | 63 6F 6D 61 6E 64 6F 20 69 6E 76 61 6C 69 64 6F
```

**Subscribe (kind 4), filtro `"loja.#"`:**

```
4E 50 46 31 04 00 00 00  00 00 00 00 00 00 00 00  08 00 00 00
| 06 00                       topicLen = 6
  6C 6F 6A 61 2E 23           "loja.#"
  (sem body)
```

**Publish (kind 6, RETAIN), tópico `"loja.caixa1"`, body `"OK"`:**

```
4E 50 46 31 06 02 00 00  00 00 00 00 00 00 00 00  0F 00 00 00
| 0B 00                       topicLen = 11
  6C 6F 6A 61 2E 63 61 69 78 61 31   "loja.caixa1"
  4F 4B                       body "OK"
```

**Ping (kind 3):**

```
4E 50 46 31 03 00 00 00  00 00 00 00 00 00 00 00  00 00 00 00
(sem payload)
```

---

## 14. Pseudocódigo de leitura

```
func read_exactly(sock, n) -> bytes:
    buf = []
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if chunk is empty:            # EOF
            if len(buf) == 0: raise CleanClose
            else: raise Truncated
        buf += chunk
    return buf

func read_frame(sock, max_payload) -> Frame:
    h = read_exactly(sock, 20)
    if h[0:4] != b"NPF1": raise OutOfSync
    kind  = h[4]
    if kind > 7: raise UnknownKind          # peer mais novo
    flags = h[5]
    corr  = u64_le(h[8:16])
    length = u32_le(h[16:20])
    if length > max_payload: raise TooLarge
    payload = read_exactly(sock, length) if length > 0 else b""
    if kind == 7:                            # compressed envelope
        orig_kind  = payload[0]
        orig_flags = payload[1]
        payload    = raw_inflate(payload[2:], limit=max_payload)
        kind, flags = orig_kind, orig_flags
    return Frame(kind, flags, corr, payload)

func write_frame(sock, kind, flags, corr, payload):
    assert len(payload) <= max_payload
    h = b"NPF1" + bytes([kind, flags, 0, 0]) + u64_le(corr) + u32_le(len(payload))
    sock.sendall(h + payload)                # um send só
```

---

## Apêndice A — Descoberta de servidor na LAN (protocolo NPD1)

`Pipes.Discovery` é um **complemento opcional**, não um transporte: nenhum frame NPF1
trafega por ele. Serve para achar o `host:porta` do servidor sem IP configurado. Se você
não precisa de descoberta automática, pule.

- Transporte: **UDP**, IPv4 apenas, porta padrão **42517** (`PIPES_DISCOVERY_DEFAULT_PORT`).
- Cliente manda a **sonda** em broadcast (`255.255.255.255:42517`); o responder do servidor
  devolve a **resposta** em unicast para a origem.
- **O IP do servidor é o endereço de origem do datagrama de resposta** (`recvfrom`), nunca
  um IP embutido no payload — isso resolve multi-NIC. O payload só carrega a **porta**.
- Comprimentos estritos: datagrama com sobra é recusado. Datagrama que não decodifica é
  descartado em silêncio.

```
sonda    = 'NPD1' + kind(1 byte)=1 + tokenLen(1 byte) + token[tokenLen bytes UTF-8]

resposta = 'NPD1' + kind(1 byte)=2 + tokenLen(1 byte) + token[tokenLen bytes UTF-8]
                  + servicePort(2 bytes LE)
                  + transport(1 byte: 0=ptLocal, 1=ptTcp, 2=ptTls)
                  + nameLen(1 byte) + name[nameLen bytes UTF-8]
```

- `token` ≤ 64 bytes UTF-8 (`PIPES_DISCOVERY_MAX_TOKEN_BYTES`); `name` ≤ 128
  (`PIPES_DISCOVERY_MAX_NAME_BYTES`).
- O responder só responde a uma sonda com `Magic` correto **e** token idêntico ao dele.
- O **token não é segurança** — viaja em claro e serve só para separar instalações na mesma
  LAN. Quem autentica o servidor é o `ptTls` na conexão NPF1 que vem depois.
- Descoberta **não** atravessa roteador nem VPN (é broadcast de sub-rede). Cliente remoto
  continua usando IP configurado + failover.

## Apêndice B — Hash de chave de agrupamento (`CorrId` em `Message`)

`SendBytes`/`SendText` do lado Delphi aceitam um `AGroupKey: string` opcional: mensagens da
mesma chave são entregues em ordem entre si mesmo no modo de despacho paralelo. O mecanismo
viaja no `CorrId` do frame `Message` (kind 0), que de outra forma seria `0`.

Você **não precisa** disto para interoperar — mande `CorrId = 0` e suas mensagens seguem o
comportamento padrão. Só implemente se quiser reproduzir a ordenação por grupo.

O valor é **FNV-1a de 64 bits** sobre os bytes UTF-8 da chave:

```
offset basis = 0xCBF29CE484222325
prime        = 0x00000100000001B3
hash = offset_basis
for each byte b in utf8(key):
    hash = hash XOR b
    hash = (hash * prime) mod 2^64        # wraparound silencioso
if hash == 0: hash = 1                    # 0 é reservado para "sem grupo"
key == "" -> 0
```

Colisão entre duas chaves diferentes é inofensiva (só serializa mensagens que não
precisavam; nunca corrompe nada).
