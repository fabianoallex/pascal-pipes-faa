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

3. Adicione-as em `Project > Deployment`, com *Remote Path* `library\lib\arm64-v8a\`
   (ou `armeabi-v7a`), plataforma Android64 e a configuração desejada.

4. **CA para validar o servidor.** Com PKI própria — o caso típico de frota —
   copie o `ca_cert.pem` gerado por `tools/gerar-pki.sh` via Deployment para
   `assets\internal\` e aponte:

   ```pascal
   FClient.TlsOptions.CaFile :=
     TPath.Combine(TPath.GetDocumentsPath, 'ca_cert.pem');
   ```

   Com `CaFile` vazio a lib valida contra o trust store do sistema. No Android
   isso exige um cuidado que a lib já toma por você: o
   `SSL_CTX_set_default_verify_paths` do OpenSSL aponta para um `OPENSSLDIR`
   que não existe no aparelho, então `Pipes.Transport.OpenSSL.pas` usa
   `/apex/com.android.conscrypt/cacerts` ou `/system/etc/security/cacerts`.
   CAs que o *usuário* instalou pelas configurações do Android **não** entram —
   desde o Android 7 elas ficam num store separado, válido só para quem usa a
   API de rede do próprio sistema.

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
