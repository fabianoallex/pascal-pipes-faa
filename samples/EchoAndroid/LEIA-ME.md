# EchoAndroid

Cliente Android (FMX) do `EchoServer`: conecta por `ptTcp` ou `ptTls`, manda
texto e mostra a resposta. É o sample do eixo de plataforma Android (milestones
A1/A2 — ver `docs/ARQUITETURA.md` §13).

**Alvo:** Delphi 12+, plataforma **Android64**. Não há equivalente FPC — o Free
Pascal não compila para Android neste projeto.

## Antes de rodar

1. **Suba o servidor** numa máquina da mesma rede. O `samples/EchoServer` aceita
   um segundo parâmetro para o transporte:

   ```
   EchoServer.exe *:5300 tcp
   ```

   `*` é atalho de `0.0.0.0` (todas as interfaces). Com `127.0.0.1:5300` ele
   escutaria **só** na própria máquina e o celular não chegaria. Sem o `tcp` no
   fim, o servidor volta ao `ptLocal` de sempre — que o celular não alcança.

2. **Libere a porta no firewall.** É o motivo nº 1 de "timeout conectando" com
   tudo certo do lado do app. Numa janela de PowerShell **como administrador**:

   ```powershell
   New-NetFirewallRule -DisplayName "pipes-faa 5300" -Direction Inbound `
     -Protocol TCP -LocalPort 5300 -Action Allow -Profile Any
   ```

   O `-Profile Any` não é detalhe: se a rede Wi-Fi estiver classificada como
   **Pública** (comum em roteador doméstico), uma regra só de perfil Privado não
   vale. Confira com `Get-NetConnectionProfile`.

3. **Descubra o IP do servidor** e digite-o no app como `192.168.0.10:5300`.
   Não use `localhost`: no celular isso é o próprio aparelho.

   ```powershell
   Get-NetIPAddress -AddressFamily IPv4 |
     Where-Object { $_.InterfaceAlias -like "Wi-Fi*" -or $_.InterfaceAlias -like "Ethernet*" } |
     Select-Object IPAddress, InterfaceAlias
   ```

   Pegue o IP da interface que está **na mesma rede do celular** — máquinas com
   Docker/WSL/VirtualBox listam vários (`172.*`, `192.168.56.*`) que não servem.

4. **Antes de culpar o celular**, confira o servidor a partir do próprio PC:

   ```
   EchoClient.exe 127.0.0.1:5300 tcp
   ```

   Se isso ecoar, o servidor está bom e o problema é rede/firewall. Se não
   ecoar, nem adianta tentar do aparelho.

## Passos no IDE (obrigatórios na primeira abertura)

O `.dproj` deste sample é enxuto de propósito — o mesmo estilo dos outros
samples do repositório, que não versionam ícones, splash nem seções de
Deployment geradas pelo IDE. Ao abrir o projeto pela primeira vez, confira:

1. **Permissão de INTERNET.** `Project > Options > Application > Uses
   Permissions`, com a plataforma **Android64** selecionada: marque
   `Internet`. Sem ela o `connect()` falha com "permission denied" e nada mais
   funciona. Marque também `Access network state` se quiser detectar rede
   ausente antes de tentar.

2. **Texto claro (`ptTcp`) — já resolvido.** Do Android 9 em diante o sistema
   bloqueia tráfego não cifrado por padrão. O `AndroidManifest.template.xml`
   versionado nesta pasta já traz `android:usesCleartextTraffic="true"`. Em
   produção o certo é o contrário: use `ptTls` e apague essa linha.

3. **OpenSSL (só se for usar `ptTls`).** Ver a seção abaixo.

### Sobre o `AndroidManifest.template.xml` desta pasta

É o template padrão do IDE com **uma** linha a mais,
`android:usesCleartextTraffic="true"` — nada além disso. Está aqui só para o
`ptTcp` funcionar sem você ter que editar nada.

O que ele **não** faz é preencher os atributos do `<application>`. Se o deploy
falhar com

```
error: '' is incompatible with attribute hardwareAccelerated (attr) boolean
```

o problema não é o template: é o `VerInfo_Keys` da plataforma Android no
`.dproj`. É de lá que a tarefa `CreateAndroidManifestFile` tira `persistent`,
`restoreAnyVersion`, `largeHeap`, `hardwareAccelerated`, `theme` e
`installLocation` — não de propriedades `Android_*`, como o nome sugeriria. A
chave completa tem esta cara:

```
package=...;label=...;versionCode=1;versionName=1.0.0;persistent=False;
restoreAnyVersion=False;installLocation=auto;largeHeap=False;theme=TitleBar;
hardwareAccelerated=true;apiKey=
```

(em uma linha só, dentro dos grupos `Base_Android` e `Base_Android64`). Um
`VerInfo_Keys` curto demais gera `android:hardwareAccelerated=""` e o `aapt2`
recusa. Pelo mesmo motivo, `android:icon="%icon%"` só resolve porque as artes de
launcher estão no `<Deployment>` do `.dproj`.

Se o IDE reclamar de alguma propriedade ao abrir o `.dproj`, o caminho mais
rápido é criar um projeto **Multi-Device Application > Blank Application** novo,
apontar o *Search path* para `..\..\src` e adicionar `uEchoAndroidMain.pas` —
os fontes deste diretório são autossuficientes.

### Se o *deploy* falhar com `E7688 NoSuchFileException ...dex.jar`

O `.dproj` versiona a propriedade `EnabledSysJars`, que lista **por nome e versão**
os jars de sistema que o dexer vai empacotar (`fmx.dex.jar`, `play-services-*`,
`androidx`…). Esses nomes mudam entre versões e até entre patches do RAD Studio:
o Delphi 12 desta máquina traz `billing-6.0.1` e `play-services-ads-22.2.0`, mas
uma instalação anterior tinha `google-play-billing-5.0.0` e
`play-services-ads-21.3.0`, e `android-support-v4` sumiu quando tudo migrou para
`androidx`.

Compilar (`Build`) funciona mesmo com a lista errada — a falha só aparece no
*deploy*, quando o R8/D8 tenta abrir cada jar. Se acontecer, a lista correta da
sua instalação está em qualquer projeto de exemplo que veio com ela, por exemplo:

```
$(BDS)\ObjRepos\en\cpp\MobileApps\Tabbed\TabbedApplication.cbproj
```

Copie de lá o conteúdo de `<EnabledSysJars>` para as duas seções
`Base_Android` / `Base_Android64` do `.dproj`. Para conferir o que existe de fato:

```
dir "%BDS%\lib\android\Debug\*.dex.jar"
```

## `ptTls` no Android: de onde vêm as `.so`

Esta é a única peça que não dá para versionar no repositório nem gerar por
script: são binários nativos, por ABI, e a licença/proveniência é decisão de
quem publica o app. Três caminhos, do mais rápido ao mais controlado.

### Opção A — pegar de um pacote pronto (mais rápido)

Vários projetos publicam OpenSSL já compilado para Android. Os dois mais usados
no mundo Delphi:

- **KyIvI/OpenSSL-for-Android** ou similares no GitHub — trazem `libcrypto.so` e
  `libssl.so` por ABI, geralmente OpenSSL 1.1.1 ou 3.x.
- **O pacote que acompanha o Indy/`IdSSLOpenSSLHeaders`** para Android, se você
  já usa Indy em outro projeto.

Confira **sempre** a versão antes de usar: `Pipes.Transport.OpenSSL.pas` fala
com a API pública de 1.1.1 e 3.x, e só com símbolos de assinatura idêntica nas
duas. Uma `.so` de 1.0.2 (ainda encontrada em pacotes antigos) **não** serve — a
ABI mudou.

### Opção B — extrair de um APK que já as tenha

Se você tem à mão um APK que empacota OpenSSL, as bibliotecas estão em
`lib/<abi>/` dentro dele (um APK é um zip). Serve para desbloquear um teste
rápido, mas não para produção: você herda a versão e o histórico de patches de
outra pessoa, sem saber quando ela atualiza.

### Opção C — compilar você mesmo (recomendado para produção)

É o único caminho em que você controla a versão e consegue aplicar correções de
segurança no seu ritmo. Com o NDK instalado:

```bash
export ANDROID_NDK_ROOT=/caminho/para/android-ndk
export PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"

# arm64-v8a (Android64) — o alvo deste sample
./Configure android-arm64 -D__ANDROID_API__=23 no-shared-not-needed \
  --prefix=$PWD/out-arm64
make -j"$(nproc)" && make install_sw

# armeabi-v7a (Android 32 bits), se você também publicar essa ABI
./Configure android-arm -D__ANDROID_API__=23 --prefix=$PWD/out-arm
```

Depois **renomeie** os artefatos para `libcrypto.so` e `libssl.so`, sem sufixo
de versão — ver a explicação no passo 2 da seção seguinte.

### Onde guardar as `.so` no disco

**Dentro do repositório, num diretório ignorado.** A convenção deste projeto é:

```
tools/openssl-android/arm64-v8a/libcrypto.so
tools/openssl-android/arm64-v8a/libssl.so
tools/openssl-android/armeabi-v7a/...      (se você publicar 32 bits também)
```

`tools/*/` já é ignorado pelo `.gitignore`, e existe ainda uma regra `*.so`
global como rede de segurança — são megabytes de binário de terceiro, com
licença e procedência próprias, que não devem entrar num `git add .` por
descuido. (Se algum dia houver decisão consciente de versioná-los, `git add -f`.)

Guardar **fora** do repositório parece mais "limpo", mas sai pior: o *LocalName*
do Deployment vira um caminho absoluto da sua máquina (`C:\...\openssl\...`),
e esse caminho fica gravado no `.dproj` — que é versionado. Caminho relativo
dentro da árvore funciona em qualquer clone que tenha o diretório.

Anote junto de onde elas vieram (URL e versão). Sem isso, daqui a um ano
ninguém sabe se aquele `libssl.so` é 1.1.1d, 1.1.1w ou 3.x, nem se já foi
alcançado por algum CVE.

### Como saber se deu certo

O carregamento é preguiçoso: um app que só usa `ptTcp` sobe normalmente mesmo
sem as `.so`. O erro só aparece na primeira conexão `ptTls`, e o modo de falha
é característico — o servidor loga conexão e desconexão **sem erro de
protocolo**, porque o cliente morre carregando a biblioteca antes de enviar o
ClientHello. Se você vir exatamente isso, o problema é a `.so`, não o
certificado. (Registrado em `docs/ARQUITETURA.md` §13.9.)

## `ptTls` no Android: empacotando o OpenSSL

O Schannel é exclusivo do Windows, então no Android o único backend de TLS é o
OpenSSL — e por isso o `pipes.inc` liga `PIPES_OPENSSL` sozinho neste alvo (é a
única plataforma onde ele não é opt-in). O carregamento é preguiçoso: um app que
só usa `ptTcp` não precisa das bibliotecas.

Para usar `ptTls`:

1. Obtenha `libcrypto.so` e `libssl.so` compilados para **cada ABI** que o app
   suporta (`arm64-v8a` para Android64, `armeabi-v7a` para Android 32 bits).

2. Os nomes precisam ser exatamente esses, **sem sufixo de versão**: o
   instalador do Android só extrai do APK arquivos que casem com `lib*.so`, e
   `libssl.so.3` nunca chegaria ao aparelho. A lista de candidatos em
   `Pipes.Transport.OpenSSL.pas` já tem um par só no Android por essa razão.

3. Adicione-as em `Project > Deployment`, plataforma Android64, e **corrija o
   *Remote Path***. É a única coluna que precisa de ajuste — e a que o IDE
   preenche errado para este caso:

   | Coluna | Padrão do IDE | O que tem que ficar |
   |---|---|---|
   | Type | `File` | `File` (não é editável, e está certo) |
   | **Remote Path** | `.\` | `library\lib\arm64-v8a\` |

   Com `.\` a biblioteca vai para a raiz do APK, onde o `dlopen` não a enxerga:
   o linker do Android só procura no diretório de bibliotecas nativas do app.
   E o sintoma é mudo — o arquivo aparece marcado na lista, o build passa, o
   deploy passa, e o erro só surge na primeira conexão `ptTls`:

   ```
   EPipeTls: OpenSSL não encontrado (tentados: libssl.so)
   ```

   O destino `library\lib\arm64-v8a\` não é chute: é o `APK_LibraryDir` que o
   `$(BDS)\bin\CodeGear.Deployment.Targets` define para a plataforma Android64
   (para Android 32 bits seria `library\lib\armeabi-v7a`).

   Para conferir sem depender do aparelho, o APK é um zip:

   ```powershell
   Add-Type -A System.IO.Compression.FileSystem
   $apk = "Android64\Debug\EchoAndroid\bin\EchoAndroid.apk"
   [IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk)).Entries |
     Where-Object FullName -like "lib/*" | Select-Object FullName, Length
   ```

   Tem que aparecer `lib/arm64-v8a/libcrypto.so` e `lib/arm64-v8a/libssl.so`.

## A PKI: por que ela não está versionada aqui

O certificado do servidor precisa ter, no **SAN**, o endereço que o celular
disca. Como esse endereço é o IP da *sua* rede, não dá para versionar um
certificado que sirva para todo mundo — a PKI de teste em `tests/pki` tem
`DNS:localhost, IP:127.0.0.1` e por isso **falha** (corretamente) quando o
aparelho conecta por IP de LAN.

Gere a sua, com o IP da máquina que roda o servidor:

```bash
cd tools
./gerar-pki.sh -o ./pki-android -s pipes-faa-lan \
  -a "IP:192.168.0.10,DNS:localhost,IP:127.0.0.1" android-001
```

O diretório `tools/pki-android/` é ignorado pelo git (`/tools/*/` no
`.gitignore`) — chaves privadas não entram no repositório. Confira o SAN antes
de usar:

```bash
openssl x509 -in tools/pki-android/srv_cert.pem -noout -ext subjectAltName
```

### Levando os PEMs para o aparelho

Este `.dproj` **não** traz entradas de Deployment para a PKI, de propósito:
elas apontariam para um diretório que não existe num clone novo, e quebrariam o
deploy de quem só quer ver o `ptTcp` funcionando. São quatro cliques no IDE:

1. `Project > Deployment`, plataforma **Android64**, configuração **Debug**.
2. *Add Files*: `tools\pki-android\ca_cert.pem`,
   `tools\pki-android\android-001_cert.pem`,
   `tools\pki-android\android-001_key.pem`.
3. Em cada um, *Remote Path* = `assets\internal\`.
4. Renomeie o *Remote Name* dos dois últimos para `cli_cert.pem` e
   `cli_key.pem` — são os nomes que `ConfiguraTls` procura.

O `System.StartUpCopy` do `.dpr` copia `assets/internal` para a pasta de
documentos do app no primeiro start; é de lá que o sample lê. O log da tela diz
o que encontrou:

```
TLS: validando o servidor contra ca_cert.pem
TLS: apresentando cli_cert.pem (mTLS)
```

Se aparecer `sem ca_cert.pem` ou `sem certificado de cliente`, os arquivos não
chegaram — reveja o Remote Path.

### Do lado do servidor (PC)

`samples/EchoSeguro/EchoSeguroServer.exe` usa a PKI de `tests/pki`, que não tem
o IP da sua LAN no SAN. Para o teste com o celular, aponte-o para a PKI nova —
ou rode um servidor próprio com:

```pascal
Srv.TlsOptions.CertFile := '...\tools\pki-android\srv_cert.pem';
Srv.TlsOptions.KeyFile  := '...\tools\pki-android\srv_key.pem';
Srv.TlsOptions.CaFile   := '...\tools\pki-android\ca_cert.pem';  // liga mTLS
```

Sem `CaFile` o servidor não exige certificado de cliente, e o app conecta mesmo
sem os `cli_*` — útil para separar "o TLS subiu?" de "o mTLS está certo?".

### Sobre o trust store do sistema

Com `CaFile` vazio a lib valida contra o trust store do aparelho. Isso exige um
cuidado que a lib já toma por você: o `SSL_CTX_set_default_verify_paths` do
OpenSSL aponta para um `OPENSSLDIR` que não existe no Android, então
`Pipes.Transport.OpenSSL.pas` usa `/apex/com.android.conscrypt/cacerts` ou
`/system/etc/security/cacerts`. CAs que o *usuário* instalou pelas configurações
do Android **não** entram — desde o Android 7 elas ficam num store separado,
válido só para quem usa a API de rede do próprio sistema.

## O que o sample mostra

- `DispatchMode := pdmMainThread` — os eventos chegam pela thread principal
  (via `TThread.Queue`), então o handler mexe na UI direto, sem `Synchronize`.
- `Connect` numa thread própria (`TConnectThread`). Ele bloqueia até conectar ou
  estourar o prazo; segurar a thread principal por segundos num celular dispara
  o diálogo de "o app não está respondendo".
- `HeartbeatIntervalMs` + `KeepAliveSeconds` ligados. Wi-Fi que dorme e NAT de
  operadora derrubam conexão ociosa em silêncio — é o mesmo modo de falha que
  motivou o `ptTcp` para PDV sobre VPN.
- `ptLocal` **não existe** no Android. Se você trocar o `Transport`, a lib
  recusa com mensagem explícita em vez de falhar obscuramente mais adiante.
