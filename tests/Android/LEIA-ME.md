# Testes de device — backend Android

Suíte do milestone A3. Roda **no aparelho** (ou emulador), em loopback:
servidor e cliente vivem no mesmo app, falando por `127.0.0.1`.

## Por que não é DUnit/fpcunit como o resto da suíte

Os outros milestones se verificam compilando nos dois compiladores e rodando a
suíte nos dois. O Android não tem esse par: o FPC não compila para Android
neste projeto, e um APK não tem runner de console. Então aqui os casos são
código comum, executados por uma thread e reportados numa tela.

O critério de aprovação, esse sim, é o mesmo do resto do repositório:

| Caso | Critério |
|------|----------|
| `ptLocal recusado com mensagem clara` | A recusa cita `ptLocal` — não é erro obscuro de socket |
| `eco loopback ptTcp` | Mensagem chega íntegra |
| `request/reply ptTcp` | Resposta correlacionada volta |
| `CloseAbort destrava Read em ms` | **≤ 250 ms** (o spike mediu ~1-2 ms) |
| `Disconnect com conexão ociosa` | **< 2 s** (teto de M7/H0-H4) |
| `Stop com conexão ociosa` | **< 2 s** |
| `Stop sob tráfego intenso` | **< 2 s** |
| `queda abrupta notifica o servidor` | `OnClientDisconnected` dispara |
| `mTLS com cliente legítimo` | Tráfego cifrado passa |
| `CA desconhecida recusada` | Cliente rejeita o servidor |
| `auto-assinado sob mTLS recusado` | Servidor rejeita o cliente, por motivo **distinto** do caso acima |

O limite de 250 ms do desbloqueio não é folga: é o que separa "acordou por
evento" (self-pipe, o mecanismo forte) de "acordou por timeout de `recv`" —
o plano B que a investigação de viabilidade deixou documentado mas que **não**
está em uso. Se esse caso começar a medir centenas de milissegundos, o backend
regrediu para polling.

## Rodada de referência (device real, 2026-08-01)

`8 ok, 0 falha(s), 3 pulado(s)` — os três pulados são os de `ptTls`, por falta da PKI no
aparelho.

| Caso | Medido | Teto |
|------|--------|------|
| `CloseAbort` destrava `Read` | **1 ms** | 250 ms |
| `Disconnect` com conexão ociosa | 2 ms | 2000 ms |
| `Stop` com conexão ociosa | 6 ms | 2000 ms |
| `Stop` sob tráfego intenso (1043 msgs vistas) | 1 ms | 2000 ms |

Use esses números como linha de base: uma regressão do mecanismo forte para polling não
faria o caso passar de "verde" a "vermelho" de imediato — faria o desbloqueio pular de 1 ms
para a ordem do timeout de `recv`. Se o número subir para dezenas ou centenas de
milissegundos, investigue antes de mexer no limite.

## Como rodar

1. Abra `PipesAndroidDeviceTests.dproj` no Delphi 12+, plataforma **Android64**.
2. Marque a permissão `Internet` em `Project > Options > Application > Uses
   Permissions` (loopback também passa pela stack de rede).
3. Rode no aparelho e toque em **Rodar**.

O `AndroidManifest.template.xml` desta pasta é o template padrão do IDE com uma
linha a mais, `android:usesCleartextTraffic="true"` — os casos de `ptTcp` são
texto claro, e do Android 9 em diante isso precisa ser declarado.

Se o deploy falhar (`dex.jar` inexistente, ou `'' is incompatible with attribute
hardwareAccelerated`), a causa e a receita estão em
`samples/EchoAndroid/LEIA-ME.md` — são propriedades do `.dproj`, não do
manifesto.

> Se o *deploy* falhar com `E7688 ... NoSuchFileException ...dex.jar`, é a lista
> `EnabledSysJars` do `.dproj` apontando para jars que não existem na sua
> instalação — o `Build` passa, só o deploy quebra. Como corrigir está em
> `samples/EchoAndroid/LEIA-ME.md`.

### Repita passando pelo segundo plano

O ponto mais específico do Android: mande o app para o segundo plano (Home),
espere alguns segundos, volte e **rode de novo**. O `Close`/`shutdown` de um
socket já passou por restrições de execução em segundo plano em versões
diferentes do sistema; o caso `CloseAbort destrava Read em ms` tem que
continuar medindo milissegundos. Foi assim que o spike de viabilidade validou
o mecanismo antes de ele virar código.

## Os casos de `ptTls` são pulados sem a PKI

Eles procuram os PEMs em `TPath.GetDocumentsPath`. Sem eles a suíte reporta
**PULADO** (não falha) — pulado em silêncio seria pior, dá impressão de
cobertura que não existe.

Para tê-los no aparelho:

1. Gere a PKI com `tools/gerar-pki.sh` (ver `tools/LEIA-ME.md`).
2. Adicione ao `Project > Deployment`, com *Remote Path* `assets\internal\`:
   `ca_cert.pem`, `srv_cert.pem`, `srv_key.pem`, `cli_cert.pem`, `cli_key.pem`,
   `gemea_ca_cert.pem` e, para o último caso, `selfsigned_cert.pem` /
   `selfsigned_key.pem`.
3. Empacote `libcrypto.so` e `libssl.so` por ABI — ver
   `samples/EchoAndroid/LEIA-ME.md`, seção "`ptTls` no Android".

Sem as bibliotecas do OpenSSL os casos de `ptTls` falham (não pulam), com a
mensagem de biblioteca ausente vinda do carregador — que é o comportamento
correto: a PKI estar presente e o TLS não funcionar é um problema de verdade.
