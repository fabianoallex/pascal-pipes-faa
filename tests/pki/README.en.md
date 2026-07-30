# TEST PKI — no security value

> 🇧🇷 Este documento também está disponível em [português](LEIA-ME.md) — a versão em
> português é a canônica; em caso de divergência, ela prevalece.

**The private keys in this directory are versioned in the repository and are
public. They protect nothing. Never use any of these files outside the test
suite, and never reuse the `pipestest` password.**

A secret scanner will flag this folder. The flag is right about the fact
(there is a versioned private key) and wrong about the risk: this is material
generated to be public, whose only purpose is to make the TLS tests run on any
machine, on both operating systems, without depending on an installed
`openssl`.

The alternative — generating the PKI in the test `Setup` — was discarded
because, wherever there was no `openssl`, the TLS tests would simply vanish. A
security test that vanishes silently is worse than a missing test: the suite
stays green and nobody notices that authentication is no longer being
exercised.

## Files

| File | Role |
|---|---|
| `ca_cert.pem` / `ca_key.pem` | Test CA. This is what the server sets in `CaFile` to turn on mTLS. |
| `srv_cert.pem` / `srv_key.pem` / `srv.pfx` | Server certificate, `CN=localhost`, with SAN `localhost` + `127.0.0.1`. |
| `cli_cert.pem` / `cli_key.pem` / `cli.pfx` | **Legitimate** client, signed by the CA above. Must connect. |
| `caixa_cert.pem` / `caixa_key.pem` / `caixa.pfx` | **Second** legitimate client, `CN=caixa-02`. It exists because `cli`, `rogue`, `selfsigned` and `gemea` share the same `CN`, and the `GatewaySeguro` sample needs two **accepted and distinct** identities at the same time to prove that a gateway does not cross one caller's identity with another's. |
| `rogue_ca_*`, `rogue_cert.pem` / `rogue_key.pem` / `rogue.pfx` | **Intruder** client: a well-formed certificate from a CA the server does not know. Must be refused. |
| `gemea_ca_*`, `gemea_cert.pem` / `gemea_key.pem` / `gemea.pfx` | Client from a **twin** CA: same `CN` and same serial number as the real CA (`ca_cert.pem`), different private key. Tests whether `VerifyClientChain` compares the root by bytes (`pbCertEncoded`) or only by issuer+serial — the MS docs do not define the criterion of `CERT_FIND_EXISTING` and Wine implements the weak version. Must be refused on native Windows. |

PEM serves the OpenSSL backend (cert and key separate); PFX serves SChannel
(cert + key in one file). Password of all PFX files: `pipestest`.

The intruder certificate uses **the same `CN=pdv-loja-001`** as the legitimate
client, on purpose. If someday the validation starts looking at the name
instead of the chain, the intruder test remains the one that catches it.

Validity: 30 years (until 2056). Long, so the suite does not start failing due
to expiration on an arbitrary day, which would be diagnosed as a code bug.

## Regenerating

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca_key.pem -out ca_cert.pem \
  -days 10950 -subj "/CN=pipes-faa-test-CA"
# server:   SAN localhost/127.0.0.1, EKU serverAuth
# client:   EKU clientAuth, signed by the CA
# intruder: EKU clientAuth, signed by a second CA, same CN as the client
```

The EKU matters: the SChannel backend requires `clientAuth` in the client's
chain (`szOID_PKIX_KP_CLIENT_AUTH` in `CertGetCertificateChain`). A client
certificate without that EKU is refused — correctly.
