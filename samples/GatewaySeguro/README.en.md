# GatewaySeguro — how to run

> 🇧🇷 Este documento também está disponível em [português](LEIA-ME.md) — a versão em
> português é a canônica; em caso de divergência, ela prevalece.

Run script for this sample's three executables. The **rationale** (where the design's
security comes from, lock invariants, why no `Free` happens inside a callback) is in the
header of [`Gateway.Nucleo.pas`](Gateway.Nucleo.pas) — deliberately not repeated here, so
the two copies cannot diverge.

```
[ClienteRemoto]  --ptTls + mTLS-->  [GatewaySeguro]  --ptLocal-->  [ServicoLocal]
   another machine                  authenticates, forwards       knows nothing about TLS
```

This script also doubles as a **regression checklist**: it is what gets re-run after
touching the gateway. The outputs below are real, from a full run on Windows/SChannel.

## Building

- **Delphi:** open `Pipes.groupproj` at the root and build (the three projects are already
  registered). The `.exe` files land in `samples\GatewaySeguro\Win64\Debug\`.
- **FPC/Lazarus (Windows):** `lazbuild ServicoLocal.lpi`, `lazbuild GatewaySeguro.lpi`,
  `lazbuild ClienteRemoto.lpi`. The `.exe` files land in the sample's own folder.
- **FPC (Linux):** the gateway and the client require `-dPIPES_OPENSSL` (there is no
  SChannel there); `ServicoLocal` uses no TLS and does not need it. Full command lines in
  each `.dpr` header.

The credentials come from the versioned **test** PKI in
[`tests/pki/`](../../tests/pki/README.en.md), which the executables locate on their own by
walking up from their own folder. It has no security value — never reuse it outside this
sample and the suite.

## A — setting up (4 terminals, all in the `.exe` folder)

| # | Command | Expect to see |
|---|---|---|
| 1 | `ServicoLocal.exe` | `servico local escutando em "pipes_faa_servico_local" (ptLocal, sem TLS)` |
| 2 | `GatewaySeguro.exe` | `gateway no ar: 0.0.0.0:5000 (ptTls + mTLS) -> "pipes_faa_servico_local" (ptLocal)` |
| 3 | `ClienteRemoto.exe` | `sessao TLS aberta com o gateway.` |
| 4 | `ClienteRemoto.exe 127.0.0.1:5000 caixa` | same, with `identidade: caixa` |

The empty `backend TLS:` right after the gateway starts is expected: `Listen` is
non-blocking and negotiates nothing on its own, so the backend information only exists
after the first handshake — the gateway prints it again when the first client
authenticates.

The order between terminals 1 and 2 does not matter; the gateway only looks for the local
service when a remote client arrives. Terminals 3 and 4 require the gateway to be up.

## B — the identity does not cross over

Type text in terminals 3 and 4, alternating. Each reply must come back stamped with the
`CommonName` of **that** client's certificate:

```
terminal 3:  servico local respondeu: eco[pdv-loja-001 @ 16:53:45]: 33
terminal 4:  servico local respondeu: eco[caixa-02 @ 16:53:43]: 44
```

And terminal 1 shows the two connections with different identities, each message on the
right pair even when they arrive interleaved:

```
[conn 1] o gateway diz que quem chama e "pdv-loja-001"
[conn 2] o gateway diz que quem chama e "caixa-02"
[conn 1] pdv-loja-001 pediu: 33
[conn 2] caixa-02 pediu: 44
```

`list` in terminal 2 shows the live table:

```
  [remota 1] pdv-loja-001     ->  local #1   (2m14s, 4 msgs)
  [remota 2] caixa-02         ->  local #2   (1m58s, 3 msgs)
```

Identity crossover would be the worst possible bug in a gateway; this is the check that
matters.

## C — the refusals (the half that gives the sample its value)

With terminals 3 and 4 still connected, run in a fifth terminal, one at a time:

```
ClienteRemoto.exe 127.0.0.1:5000 rogue
ClienteRemoto.exe 127.0.0.1:5000 selfsigned
ClienteRemoto.exe 127.0.0.1:5000 nenhum
```

The gateway refuses all three, with verdicts **distinct** from one another — if all gave
the same error, the validation would not be looking at the chain:

```
[remota 3] erro (handshake/mTLS recusado?): mTLS: cadeia do cliente invalida (dwErrorStatus 0x00010000)
[remota 4] erro (handshake/mTLS recusado?): mTLS: certificado de cliente nao encadeia ate a CA configurada
[remota 5] erro (handshake/mTLS recusado?): handshake TLS (servidor) falhou (0x00090317)
```

**What proves the design is not that — it is terminal 1 not gaining a single new line**
while the three attempts happen. No local connection was opened, so nothing leaked behind
the gateway. Terminals 3 and 4 keep working the whole time.

On SChannel the `rogue` and `selfsigned` clients print `sessao TLS aberta com o gateway`
before dropping: the client's chain is checked **after** the handshake. That is why the
message does not say "authenticated" — the proof that the session is worth anything is the
first reply from the local service, not the connection event. On OpenSSL the refusal
happens inside the handshake itself and `Connect` fails; both verdicts are correct.

## D — the two layers of "connected"

**Service dies mid-session:** press Enter in terminal 1. Both clients receive the reason
and drop; the gateway stays up:

```
*** RECUSADO PELO GATEWAY: servico local encerrou a conexao
    (a sessao TLS estava valida: esta recusa e de APLICACAO. Handshake
     concluido nao e o mesmo que ter servico do outro lado.)
```

**Service already down when the client arrives:** with terminal 1 closed, run
`ClienteRemoto.exe`. The mTLS handshake passes and still you get
`RECUSADO| servico local indisponivel: timeout (2000 ms) conectando ao pipe ...`.

That is the sample's lesson: a completed TLS handshake is not the same as a useful session
— which is why the refusal carries a reason instead of being a silently closed socket.

Two consecutive `saiu (0 no total)` lines in terminal 1 are not a miscount: the lib
removes the connection from the registry *before* firing `OnClientDisconnected` (the
removal is the teardown's act of ownership), so when both die together the first handler
already sees zero.

## E — deaths and shutdown

- **Killing a remote client** (closing its window, or `taskkill`): in terminal 1 only
  **its** connection leaves; the other keeps replying. Lifecycle mirroring.
- **Shutting the gateway down under traffic:** with the clients sending messages, type
  `sair` in terminal 2. It must finish immediately — the M7 bar is < 2 s; this session's
  measurement was 223 ms with three clients flooding. The clients receive
  `RECUSADO| gateway encerrando`.
- **Repeated abrupt drops:** 50 cycles of a client connecting and being killed leave the
  connection count balanced on both sides (53 opened / 53 closed, gateway and service).
  The handle growth observed in the gateway process tracks the `EchoSeguroServer`'s (pure
  library) and belongs to the `ptTls`/SChannel path, not to this sample.

## Parameters

```
ServicoLocal.exe   [pipe-name]                        (default pipes_faa_servico_local)
GatewaySeguro.exe  [tls-address] [local-pipe] [max-remotes]
                                                      (defaults 0.0.0.0:5000,
                                                       pipes_faa_servico_local, 8)
ClienteRemoto.exe  [address] [identity]               (defaults 127.0.0.1:5000, cli)
```

Identities accepted by `ClienteRemoto`: `cli` and `caixa` get in; `rogue`, `selfsigned`
and `nenhum` are refused. `MaxClients` on the gateway is a **doubled** resource ceiling:
each accepted remote connection opens a local connection of its own.
