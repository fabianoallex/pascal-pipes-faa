# PKI de TESTE — sem valor de segurança

**As chaves privadas deste diretório estão versionadas no repositório e são
públicas. Não protegem nada. Nunca use nenhum destes arquivos fora da suíte de
testes, e nunca reaproveite a senha `pipestest`.**

Um scanner de segredos vai apontar esta pasta. O apontamento está certo quanto
ao fato (há chave privada versionada) e errado quanto ao risco: é material
gerado para ser público, cuja única função é fazer os testes de TLS rodarem em
qualquer máquina, nos dois sistemas operacionais, sem depender de um `openssl`
instalado.

A alternativa — gerar a PKI no `Setup` do teste — foi descartada porque, onde
não houvesse `openssl`, os testes de TLS simplesmente sumiriam. Teste de
segurança que some em silêncio é pior do que teste ausente: a suíte fica verde
e ninguém nota que a autenticação deixou de ser exercitada.

## Arquivos

| Arquivo | Papel |
|---|---|
| `ca_cert.pem` / `ca_key.pem` | CA de teste. É esta que o servidor configura em `CaFile` para ligar mTLS. |
| `srv_cert.pem` / `srv_key.pem` / `srv.pfx` | Certificado do servidor, `CN=localhost`, com SAN `localhost` + `127.0.0.1`. |
| `cli_cert.pem` / `cli_key.pem` / `cli.pfx` | Cliente **legítimo**, assinado pela CA acima. Deve conectar. |
| `rogue_ca_*`, `rogue_cert.pem` / `rogue_key.pem` / `rogue.pfx` | Cliente **intruso**: certificado bem formado, de uma CA que o servidor não conhece. Deve ser recusado. |

PEM serve ao backend OpenSSL (cert e chave separados); PFX serve ao SChannel
(cert + chave num arquivo só). Senha de todos os PFX: `pipestest`.

O certificado intruso usa **o mesmo `CN=pdv-loja-001`** do cliente legítimo, de
propósito. Se algum dia a validação passar a olhar o nome em vez da cadeia, o
teste do intruso continua sendo o que pega isso.

Validade: 30 anos (até 2056). Longa para que a suíte não comece a falhar por
expiração num dia arbitrário, o que seria diagnosticado como bug de código.

## Regerar

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca_key.pem -out ca_cert.pem \
  -days 10950 -subj "/CN=pipes-faa-test-CA"
# servidor: SAN localhost/127.0.0.1, EKU serverAuth
# cliente:  EKU clientAuth, assinado pela CA
# intruso:  EKU clientAuth, assinado por uma segunda CA, mesmo CN do cliente
```

O EKU importa: o backend SChannel exige `clientAuth` na cadeia do cliente
(`szOID_PKIX_KP_CLIENT_AUTH` em `CertGetCertificateChain`). Um certificado de
cliente sem esse EKU é recusado — corretamente.
