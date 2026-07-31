# tools/gerar-pki.sh — gerando sua própria PKI para mTLS

Este guia é para quem vai usar `ptTls` com mTLS **de verdade** (não a PKI de
teste versionada em `tests/pki`, que é pública e só serve para a suíte e os
samples) e não trabalha com certificados no dia a dia. Se os termos abaixo já
são familiares, pule direto para "Uso rápido".

## Por que existem três tipos de arquivo

- **CA (autoridade certificadora)** — um par de arquivos (`ca_cert.pem` +
  `ca_key.pem`) que você cria uma vez. `ca_cert.pem` é o "carimbo": tanto o
  servidor quanto os clientes confiam nele. `ca_key.pem` é o que assina novos
  certificados — quem tiver essa chave pode criar um certificado que o seu
  servidor aceita como cliente legítimo, então ela é o segredo mais importante
  de todos.
- **Certificado de servidor** (`srv_cert.pem`/`srv_key.pem`/`srv.pfx`) — prova
  para o cliente que ele está falando com o servidor certo, não com um
  impostor no meio do caminho.
- **Certificado de cliente** (um por identidade: `pdv-001`, `pdv-002`...) —
  prova para o servidor quem é o cliente. É isso que faz o mTLS ser "mútuo":
  os dois lados se identificam, não só o servidor.

Em mTLS **os dois lados apresentam certificado**. Em TLS comum (a maioria dos
sites HTTPS) só o servidor apresenta — é por isso que qualquer navegador
consegue acessar um site sem "ter um certificado instalado".

## Uso rápido

```sh
cd tools
./gerar-pki.sh -o ./minha-pki -s retaguarda.empresa.local pdv-001 pdv-002 pdv-003
```

Isso cria `./minha-pki/` com a CA, o certificado do servidor (CN e SAN batendo
com `retaguarda.empresa.local`) e um certificado para cada cliente listado
(`pdv-001`, `pdv-002`, `pdv-003`). Cada certificado sai em dois formatos —
`.pem` (backend OpenSSL) e `.pfx` (backend Schannel/Windows) — então você não
precisa saber de antemão qual backend vai usar.

Rode `./gerar-pki.sh` sem argumentos para ver todas as opções (`-a` para SAN
customizado, `-p` para senha fixa do `.pfx`, `-l`/`-c` para validade).

Requer `openssl` no `PATH`. No Windows com Git Bash ele normalmente já está em
`C:\Program Files\Git\mingw64\bin`.

**No Windows, rode a partir de um terminal já aberto, não com duplo-clique.**
Dar duplo-clique num `.sh` e escolher "Git Bash" abre uma janela de console
nova que **fecha sozinha assim que o script termina** — a saída inteira,
inclusive a senha impressa na tela, some junto. Em vez disso: abra o Git Bash
(ou clique com o botão direito na pasta `tools` e escolha "Git Bash Here"),
depois rode o comando normalmente. A janela do terminal continua aberta
depois que o script termina.

Mesmo assim, se a senha foi gerada automaticamente (sem `-p`), o script também
grava ela em `senha-pfx.txt` dentro da pasta de saída — então mesmo que a
janela feche, a senha não se perde.

## O que fazer com os arquivos gerados

No **servidor**:

```pascal
Srv := TPipeServer.Create('0.0.0.0:5000', ptTls);
{$IFDEF PIPES_SCHANNEL}
Srv.TlsOptions.CertFile := 'minha-pki/srv.pfx';
Srv.TlsOptions.CertPassword := '...';           // a senha impressa pelo script
{$ELSE}
Srv.TlsOptions.CertFile := 'minha-pki/srv_cert.pem';
Srv.TlsOptions.KeyFile := 'minha-pki/srv_key.pem';
{$ENDIF}
Srv.TlsOptions.CaFile := 'minha-pki/ca_cert.pem';  // presente = liga o mTLS
Srv.Listen;
```

Em cada **cliente** (troque `pdv-001` pelo CN daquela máquina/identidade):

```pascal
Cli := TPipeClient.Create('retaguarda.empresa.local:5000', ptTls);
{$IFDEF PIPES_SCHANNEL}
Cli.TlsOptions.CertFile := 'minha-pki/pdv-001.pfx';
Cli.TlsOptions.CertPassword := '...';
{$ELSE}
Cli.TlsOptions.CertFile := 'minha-pki/pdv-001_cert.pem';
Cli.TlsOptions.KeyFile := 'minha-pki/pdv-001_key.pem';
Cli.TlsOptions.CaFile := 'minha-pki/ca_cert.pem';
{$ENDIF}
Cli.Connect(5000);
```

Detalhes completos (o que cada campo faz, diferença entre backends) estão no
`README.md` da raiz, seção "TLS (`ptTls`)".

## Dúvidas comuns

**Esses arquivos podem ir para o Git?**
Não. `*_key.pem`, `*.pfx` e `senha-pfx.txt` são segredos — qualquer um com a
chave privada do servidor pode se passar por ele, e qualquer um com
`ca_key.pem` pode fabricar um certificado de cliente aceito pelo seu
servidor. Coloque a pasta de saída
(`minha-pki/` ou o nome que você escolher) no `.gitignore` do seu projeto que
consome a lib. A única PKI versionada neste repositório é `tests/pki`, e ela é
deliberadamente pública — leia `tests/pki/LEIA-ME.md` antes de pensar em
imitar esse padrão para credenciais reais.

**Onde eu guardo `ca_key.pem`?**
Fora do servidor e de qualquer cliente. Ele só é necessário no momento de
*emitir* um certificado novo (rodar o script de novo apontando `-o` para a
mesma pasta). Se um cliente for comprometido, o dano fica restrito ao
certificado dele — só vira problema maior se `ca_key.pem` vazar junto.

**Preciso gerar uma CA nova a cada vez que rodar o script?**
Não. Se `ca_cert.pem` já existir na pasta `-o`, o script reaproveita a CA e só
gera os certificados novos pedidos — útil para adicionar um cliente novo sem
invalidar os que já existem.

**`Cli.Connect` falhou com erro de handshake/certificado. Por onde eu começo
a debugar?**
No servidor, o `OnError` dispara com o motivo (`FServer.OnError` no exemplo do
sample `EchoSeguro`) — é aí que aparece "cliente sem certificado" ou
"certificado de CA desconhecida". Cheque, nesta ordem: (1) o cliente está
apontando para o `.pem`/`.pfx` certo para o backend dele; (2) a senha do
`.pfx` está certa; (3) o certificado do cliente foi mesmo assinado pela CA que
o servidor tem em `CaFile`, com `openssl verify -CAfile ca_cert.pem
pdv-001_cert.pem`.

**No Windows, configurei `Cli.TlsOptions.CaFile` mas o cliente ainda rejeita o
servidor. Por quê?**
Esse é o ponto que mais confunde. **No backend Schannel, `CaFile` do CLIENTE é
ignorado** — o Windows valida o certificado do servidor contra o trust store
do sistema operacional, não contra o arquivo que você configurou. Duas
saídas: instalar `ca_cert.pem` no trust store da máquina —

```powershell
Import-Certificate -FilePath ca_cert.pem -CertStoreLocation Cert:\LocalMachine\Root
```

— ou compilar esse lado com `-dPIPES_OPENSSL`, onde `CaFile` do cliente vale
de verdade. `CaFile` do **servidor** funciona igual nos dois backends (é ele
quem liga o mTLS).

**Existe algum atalho para "não validar" enquanto eu só estou testando local?**
Existe (`TlsOptions.SkipServerVerification := True`), mas ele desliga a
verificação de que o servidor é quem diz ser — a conexão continua cifrada,
porém qualquer um no meio do caminho pode se passar pelo servidor sem o
cliente perceber (ataque "man-in-the-middle"). Use isso **só** em teste
local, nunca com tráfego real, e nunca deixe esse valor em código que vai para
produção. Se o objetivo é só testar mTLS localmente sem instalar nada no
trust store do Windows, prefira compilar com `-dPIPES_OPENSSL` — aí a
validação acontece de verdade contra `CaFile`.

**Por quanto tempo os certificados são válidos? O que acontece quando
vencem?**
Por padrão o script gera certificados de cliente/servidor com 825 dias
(~2 anos e 3 meses) e a CA com 3650 dias (10 anos) — ajustável com `-l`/`-c`.
Quando um certificado vence, o handshake passa a falhar para aquela
identidade; a correção é gerar um novo certificado para ela (rodando o script
de novo, reaproveitando a mesma CA) e distribuí-lo — não existe renovação
automática na lib, isso é responsabilidade de quem opera o sistema.

**Um cliente saiu da empresa / um PDV foi roubado. Como eu revogo o acesso
dele sem afetar os outros?**
A lib **não implementa CRL nem OCSP** — a validação de cadeia atual não checa
revogação, só confiança na CA e validade de data. Hoje a forma prática de
"revogar" um cliente é rotacionar a CA (gerar uma CA nova e reemitir
certificado para todos os clientes legítimos, exceto o comprometido) ou parar
de aceitar aquele `CommonName` na aplicação mesmo com certificado válido (veja
`TryClientIdentity` no `README.md`, seção "Quem está do outro lado" — a
validação de cadeia não impede que a sua própria lógica recuse um CN
específico).

## Onde ver isso funcionando

- `samples/EchoSeguro/` — servidor e cliente completos usando mTLS, incluindo
  o `{$IFDEF PIPES_SCHANNEL}` para alternar entre PFX e PEM.
- `tests/pki/LEIA-ME.md` — a PKI de teste do próprio repositório, com os
  mesmos comandos "na mão" (sem o script) e a explicação de cada arquivo.
- `README.md`, seção "TLS (`ptTls`)" — referência completa de cada campo de
  `TlsOptions` e as diferenças finas entre os backends Schannel e OpenSSL.
