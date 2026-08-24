# pascal-pipes-faa

> 🇧🇷 Este documento também está disponível em [português](README.md) — a versão em
> português é a canônica; em caso de divergência, ela prevalece.

> Formerly `pascal-named-pipes-faa`. The name changed because the Windows Named Pipe became
> just one of the supported transports — the old API still works (see
> [Compatibility](#compatibility-with-the-previous-api)).

Cross-platform **inter-process communication** library for **Delphi 12+ (Win64 and
Android)** and **FPC 3.2.2 / Lazarus (Linux x86_64 and ARM64)**, with a single codebase and
a high-level API that completely abstracts the native operating system calls.

The same API covers three reaches, switched by a single property:

| `Transport` | Reach | Under the hood |
|---|---|---|
| `ptLocal` (default) | same machine | Named Pipe (Windows) / Unix Domain Socket (Linux) — **does not exist on Android** |
| `ptTcp` | network | TCP socket, keepalive on by default |
| `ptTls` | untrusted network | the same TCP with TLS, plus optional certificate-based mTLS |

```pascal
// Server
Server := TPipeServer.Create('my_app');
Server.OnMessage := MyClass.HandleMessage;      // procedure ... of object
Server.Listen;

// Client
Client := TPipeClient.Create('my_app');
Client.Connect(5000);
Client.SendText('hello!');
Reply := Client.RequestText('ping', 3000);      // synchronous RPC with timeout
```

## How it works under the hood

| | Windows | Linux |
|---|---|---|
| Transport | Real Named Pipes (`CreateNamedPipe`/`ConnectNamedPipe`), byte mode, **always overlapped** | **Unix Domain Sockets** (`AF_UNIX`/`SOCK_STREAM`) |
| Native name | `\\.\pipe\my_app` | `/tmp/my_app.sock` |
| Interrupting blocking I/O | `WaitForMultipleObjects` + `CancelIoEx` | `fpPoll` + self-pipe + `fpShutdown` |

On Linux, "named pipe" is implemented as a **Unix Domain Socket** — the same approach .NET
takes (`NamedPipeServerStream`/`NamedPipeClientStream` on Unix). UDS gives full semantic
parity with the Windows Named Pipe: per-client connections, bidirectional, drop detection.
FIFOs (`mkfifo`) stayed out of v1; the abstract transport layer leaves the door open.

If `Address` is already a native path (`\\.\pipe\...` or `/abs/path.sock`), it is used
as-is — handy for controlling the socket's directory (and permissions) on Linux.

### Transport

The `Transport` property (`TPipeTransport`) chooses where the frames travel. The default is
`ptLocal`, so anyone doing only local IPC never needs to know this exists:

```pascal
TPipeServer.Create('my_app');                   // ptLocal (default)
TPipeServer.Create('my_app', ptLocal);          // same, explicit
TPipeServer.Create('0.0.0.0:5000', ptTcp);      // TCP
TPipeClient.Create('192.168.0.10:5000', ptTcp);
TPipeServer.Create('0.0.0.0:5000', ptTls);      // TCP + TLS (credentials in TlsOptions)
```

The enum names **reach**, not mechanism: `ptLocal` is "this OS's best local IPC" —
Named Pipe on Windows, Unix Domain Socket on Linux. A `ptNamedPipe` would be the wrong name
half of the time.

`Address` and `Transport` are validated together at activation: `Create('\\.\pipe\X', ptTcp)`
fails with an `EPipeError` explaining the conflict, instead of blowing up later with an
obscure name-resolution error.

Addresses accepted by `ptTcp`: `host:port`, IPv6 in brackets (`[::1]:5000`) and `*` as a
shortcut for `0.0.0.0`. Resolution goes through `getaddrinfo`, so hostnames and IPv6 work.
`TCP_NODELAY` is turned on (Nagle's delay would heavily penalize `Request`/`Reply`).

> **Security:** unlike `ptLocal`, `ptTcp` does **not** inherit access control from the OS
> (Windows ACLs, UDS file permissions). A listener on `0.0.0.0` accepts anyone who can
> reach the port — authentication is the application's responsibility. That is the hole
> `ptTls` closes.

#### Android

Android is a third platform axis (Delphi, `Android64`/`Android32`), alongside Delphi/Win64
and FPC/POSIX. The API is the same; what changes is what is available:

- **`ptTcp` and `ptTls` work**, client and server. `ptLocal` **does not exist** — an Android
  app is single-process and exposing a Unix Domain Socket runs into sandboxing. Using it
  raises `EPipeError` telling you what to do, instead of failing obscurely later on.
- **`ptTls` is always OpenSSL** (Schannel is Windows-only), which is why this is the only
  target where `PIPES_OPENSSL` is turned on automatically. You have to package
  `libcrypto.so` and `libssl.so` per ABI in the app's Deployment — see
  `samples/EchoAndroid/LEIA-ME.md`.
- **The `INTERNET` permission** is mandatory in the manifest, and `ptTcp` (cleartext) also
  requires `usesCleartextTraffic` from Android 9 onwards. One more reason to prefer `ptTls`.
- Recommended on a phone: `DispatchMode := pdmMainThread` (events arrive on the main thread,
  so you can touch the UI directly) and `Connect` off the main thread, since it blocks until
  the deadline.

Verification happens on a device: there is no dual-compiler pair (FPC does not compile for
Android in this project). The device suite lives in `tests/Android/`. Full rationale in
[`docs/ARCHITECTURE.en.md`](docs/ARCHITECTURE.en.md) §13.

### Client address (`TryClientAddress`)

On `ptTcp`/`ptTls` (with or without mTLS) the server knows where each client came from:

```pascal
procedure TForm1.ClientConnected(Sender: TObject; AConnId: TPipeConnectionId);
var
  LAddress: string;
begin
  if Server.TryClientAddress(AConnId, LAddress) then
    FileLog('pipe-connection', 'Client connected: ' + LAddress)
  else
    FileLog('pipe-connection', 'Client connected: ' + AConnId.ToString); // ptLocal
end;
```

`False` on `ptLocal`: a Named Pipe/UDS has no IP address, just a local handle/fd — it isn't
"hasn't arrived yet", it's always like that for that transport. The address comes as
`'ip:port'` (IPv6 in brackets, the same convention as the `Address` you pass to `Connect`
yourself) and **survives the client leaving**, the same criterion as `TryClientIdentity`
right below — it lets you answer "where did whoever left come from?" inside
`OnClientDisconnected` itself.

### TLS (`ptTls`)

`ptTls` is the same TCP socket with TLS on top: same `Address` format, same threading
guarantees. What changes is that the traffic is encrypted and the peer can be authenticated
by certificate.

```pascal
Srv := TPipeServer.Create('0.0.0.0:5000', ptTls);
Srv.TlsOptions.CertFile := 'srv.pfx';        // PFX on Windows/Schannel
Srv.TlsOptions.CertPassword := 'secret';
Srv.Listen;

Cli := TPipeClient.Create('server.company:5000', ptTls);
Cli.Connect(5000);
```

Credentials are read **once**, at `Listen`/`Connect`: changing them while the component is
active raises `EPipeError` instead of silently accepting a configuration that has no
effect. A wrong password or missing file shows up right at `Listen`, not when the first
client connects.

#### mTLS (authenticating the client)

Filling `CaFile` **on the server** turns on mTLS: the client is now required to present a
certificate that chains up to that CA. Whoever presents none — or one from another CA — is
refused, and `OnClientConnected` never fires for them.

```pascal
Srv.TlsOptions.CaFile := 'ca.pem';   // turns on mTLS
Cli.TlsOptions.CertFile := 'pdv-001.pfx';
Cli.TlsOptions.CertPassword := 'secret';
```

This is the design intended for the store-POS-over-VPN case: the certificate, not the
source IP, is what says who is who.

#### What changes between backends

The backend is chosen at **compile time** (see `src/pipes.inc`): Schannel (native SSPI) is
the default on Windows; OpenSSL is opt-in via `-dPIPES_OPENSSL`, and is the only one on
Linux. Three differences that matter for configuration:

| | Schannel (Windows) | OpenSSL |
|---|---|---|
| Certificate format | `CertFile` = PFX (cert + key together), `CertPassword` | `CertFile` = PEM, `KeyFile` = key PEM |
| `CaFile` on the **server** | CA of the client certificates (mTLS) | same |
| `CaFile` on the **client** | **ignored** — Windows validates against the OS trust store | CA used to validate the server |

The last row is the gotcha: a private PKI whose certificate is not in the Windows trust
store makes the Schannel *client* reject the server even with `CaFile` filled in. Either
install the CA on the machine, or use the OpenSSL backend.

> **How the client sees an mTLS refusal — and why it differs per backend.** Schannel
> completes the handshake and **only then** hands the client's certificate to the
> application for validation (that is what `VerifyClientChain` does). Consequence: a
> refused client sees `OnConnected` fire normally and the connection drop right after. In
> OpenSSL the validation happens inside the handshake, so the refusal arrives as a
> connection failure and `OnConnected` never fires.
>
> An application that needs to distinguish "I was accepted" from "I am about to be dropped"
> on the client side **cannot rely on `OnConnected` alone under Schannel**. The practical
> pattern is the one in the `ChatSeguro` sample: a session that dies almost together with
> `OnConnected` is a credential refusal, not a network drop — and then reconnecting is
> pointless, because the credential will not become acceptable on its own.

#### Who is on the other side

Under mTLS the server does not just validate the client's certificate — it remembers who
they are:

```pascal
procedure TForm1.ClientConnected(Sender: TObject; AConnId: TPipeConnectionId);
var
  LWho: TPipePeerIdentity;
begin
  if Server.TryClientIdentity(AConnId, LWho) then
    Memo.Lines.Add('connected: ' + LWho.CommonName);  // 'pdv-loja-001'
end;
```

The `CommonName` is trustworthy **because the chain was validated first**: a certificate
with a forged `CN` never gets to fire `OnClientConnected`; it is refused in the handshake.
So this name can be used to identify — display, log, route. What must not be done is the
reverse: deriving authorization from a name whose chain was never verified.

`TryClientIdentity` returns `False` when there is no *verified* identity — no TLS, or TLS
without mTLS. `False` never means "not here yet": there is nothing to wait for.

The identity **survives the client leaving**, so `OnClientDisconnected` can also ask "who
left?" — without that, a dashboard could only say "connection 7 left". The last
`PIPES_RECENT_IDENTITIES` (256) authenticated connections are retained. The reason it is
not released together with the connection is that the event and the cleanup go to different
queues, with no guaranteed order between them: tying the identity's lifetime to the cleanup
would be a race.

> **Behavior change:** `ClientCount` and `ClientIds` now count only **established**
> connections — those for which `OnClientConnected` has already fired. Before, a connection
> accepted but still negotiating TLS already showed up there, which under mTLS meant
> displaying as a "client" a peer that might be refused next. `Broadcast` follows the same
> rule, for a reason stronger than counting: sending payload to someone who has not yet
> authenticated would leak data. For `ptLocal` and `ptTcp` nothing changes in practice —
> with no handshake, a connection is born established.
>
> `MaxClients` is deliberately different: since it is a **resource** limit, it also counts
> connections still negotiating — otherwise a peer that never finishes the handshake would
> not occupy a slot.

#### Handshake deadline

The handshake has its own deadline, `PIPE_TLS_HANDSHAKE_TIMEOUT_DEFAULT` (15 s), adjustable
via `TlsOptions.HandshakeTimeoutMs`. Without it, anyone opening the TCP connection and
never sending the `ClientHello` would pin a server thread forever — a few dozen half-open
connections would take the service down without sending a single useful byte. The deadline
applies **only** during negotiation: after it, the connection may sit idle as long as it
wants, and dead peers there are the keepalive's job.

`HandshakeTimeoutMs = 0` means *the default*, not "no deadline" — turning it off requires
an explicit `PIPE_TLS_HANDSHAKE_NO_TIMEOUT`.

### Keepalive (`KeepAliveSeconds`)

A TCP connection can die silently — a cable, a powered-off machine, or the idle timeout of
a VPN/NAT tunnel. Neither side is told, and the reader would wait forever. In local IPC
this does not exist: the peer process dying always closes the pipe.

That is why `ptTcp` turns TCP keepalive on by default, with **20 s** of idle time
(`PIPES_DEFAULT_KEEPALIVE_SECONDS`). `ptTls` inherits the same setting — it is the same
socket underneath, and keepalive happens at the TCP layer without touching the TLS session.
`ptLocal` ignores the property.

```pascal
Server.KeepAliveSeconds := 20;  // default
Server.KeepAliveSeconds := 0;   // off
```

The value serves **two purposes**, and the second is usually the more important one:

1. **Detecting** a dead connection — with the defaults, in ~35 s (20 s idle + 3 probes
   every 5 s). Detection becomes `EPipeClosed`, which fires `OnClientDisconnected` on the
   server and `OnDisconnected` + `AutoReconnect` on the client.
2. **Keeping alive** the NAT/VPN mapping of an idle connection, preventing it from dying.
   That is why the value must be **smaller than the tunnel's idle timeout**, not larger —
   if your VPN drops idle sessions at 30 s, `KeepAliveSeconds` has to stay comfortably
   below that.

On the server this matters more than it seems: without keepalive it accumulates zombie
connections indefinitely — `Broadcast` writing to clients that no longer exist and
`ClientCount` lying.

**Platform difference:** on POSIX the three parameters (idle, interval, probe count) are
adjustable per socket, so detection is exactly as described. Windows uses
`SIO_KEEPALIVE_VALS` (available since Windows 2000, unlike `setsockopt(TCP_KEEPIDLE)`,
which requires Win10 1709+ — relevant for old hardware), and it does not expose the probe
count: it is fixed by the OS (2 from Vista onward). Time-to-detect differs a bit; keeping
the NAT/VPN mapping alive, which depends only on the idle time, is identical on both.

Messages travel in a custom framing (`NPF1`: 20-byte little-endian header with magic, kind,
correlation id and length), identical on both OSes — message boundaries belong to the
library, never to the transport. Payloads are `TBytes`; the `*Text` methods convert to/from
UTF-8 portably.

### Application heartbeat (`HeartbeatIntervalMs`)

Complementary to Keepalive above, not a replacement. `KeepAliveSeconds` is an OS probe:
cheap, but typically takes minutes to fire, and it only sees the raw TCP socket — never
what crosses the encrypted `ptTls` record. `HeartbeatIntervalMs` solves the same problem
on top of the framing layer, with an application frame (`pfkPing`) and fine-grained
control over detection time:

```pascal
Server.HeartbeatIntervalMs := 5000;  // off by default (0); ptTcp/ptTls only
Client.HeartbeatIntervalMs := 5000;  // same value on both sides, for simplicity
```

Symmetric and uncorrelated: any received frame (the `Ping` itself included) resets the
read clock of whoever received it — there is no `pfkPong` nor an "outstanding ping" to
track. A dead connection means **no frame received within 2x the configured interval**;
whoever detects it closes its own connection and follows the normal drop flow
(`OnClientDisconnected`/`OnDisconnected` + `AutoReconnect`, no dedicated event). `ptLocal`
ignores the property, for the same reason as Keepalive: the peer process dying already
closes the local pipe/UDS right away.

### Metrics/observability (`Stats`/`ConnectionStats`)

On-demand snapshot — same mold as `ClientCount`/`ClientIds`/`Subscriptions`: the library
never pushes anything periodically, the app asks whenever it wants. Always on, no opt-in
(the cost is one atomic increment per frame). Valid on **any transport**, `ptLocal`
included.

```pascal
LConnStats: TPipeConnStats;
if Server.ConnectionStats(AConnId, LConnStats) then
  WriteLn(LConnStats.BytesReceived, ' bytes received on this connection');

LSrvStats := Server.Stats;      // aggregate, cumulative since Listen
LCliStats := Client.Stats;      // current SESSION, resets on every reconnect
WriteLn('pool queue depth: ', LSrvStats.PoolQueueDepth);
WriteLn('avg request latency: ', LCliStats.AvgRequestLatencyMs, ' ms');
```

- **`Server.ConnectionStats(AConnId, out AStats): Boolean`** — bytes/messages sent and
  received by ONE connection. Dies with it (like topic subscriptions), unlike
  `TryClientIdentity`. `False` if the connection doesn't exist or isn't established.
- **`Server.Stats: TPipeServerStats`** — cumulative aggregate since `Listen`, survives
  connections that already dropped: `TotalConnectionsAccepted` (established only),
  `TotalBytesSent/Received`, `TotalMessagesSent/Received`, `ClientCount`, and
  `PoolQueueDepth`. **Caveat:** under `pdmPool` (default) the dispatch pool is GLOBAL,
  shared by every `TPipeServer`/`TPipeClient` in the process — `PoolQueueDepth` reflects
  everyone's backlog, not just this server's. It's only exclusive to it under
  `pdmSerialized`.
- **`Client.Stats: TPipeClientStats`** — bytes/messages of the current SESSION (resets on
  every `Connect`/reconnect, no cross-session cumulative counter), `ReconnectAttempts`,
  `PendingRequests`, and `AvgRequestLatencyMs`/`MaxRequestLatencyMs` — only count Requests
  that actually got a reply (timeout and error are excluded: "the server didn't respond"
  is a different question from "how long did it take").

### Ordering by group under `pdmPool` (`AGroupKey` in `SendBytes`/`SendText`)

`pdmPool` (the default `DispatchMode`) dispatches each received message to a pool of
workers — fast, but with no delivery-order guarantee between distinct messages reaching
`OnMessage` (only the order on the wire, which is always preserved). Most apps never need
more than that; for the ones that need a SUBSET of messages to process in the order they
were sent (e.g. the events from one specific register in a store), without giving up
parallelism for everything else:

```pascal
Client.SendBytes(AData, 'register.3');   // every message tagged 'register.3' processes in
                                          // order...
Client.SendBytes(AData2, 'register.4');  // ...and in PARALLEL with 'register.4', never behind it
```

- No `AGroupKey` (default, `''`): the usual behavior, at zero cost.
- The guarantee is about DELIVERY to the RECEIVING side's `OnMessage`, not about the sender —
  both `TPipeClient.SendBytes` and `TPipeServer.SendBytes` accept the parameter, and it is the
  RECEIVER's `DispatchMode` that decides whether the key makes any difference.
- Only applies under `pdmPool`: in `pdmSerialized`/`pdmMainThread` the order is already total,
  so the key is ignored (harmless, not an error to pass one).
- Keys are ephemeral — there is no cap on distinct keys and no residual cost: the internal
  structure is born with the first pending message for that key and dies once none remain.
  Reusing a key after it drains starts from scratch.
- No wire format change: the key travels inside the NPF1 header's own `CorrId` (a 64-bit
  hash), a field that already existed and that plain messages never used.

### Asynchronous connect (`ConnectAsync`)

`Connect(TimeoutMs)` blocks the calling thread and raises if the server does not answer
within the deadline. `AutoReconnect` does not help there: it only kicks in after a session
has ALREADY existed and dropped. The case left unanswered is the most common one in a store:
**the app starts before the server**.

```pascal
Client := TPipeClient.Create('backoffice:9000', ptTcp);
Client.OnConnected := HandleConnected;
Client.OnError := HandleError;
Client.AutoReconnect := True;     // takes care of drops AFTER the first connection
Client.ReconnectDelayMs := 3000;  // per-attempt budget AND spacing between attempts
Client.ConnectAsync;              // returns at once; keeps trying in the background

// while Client.Connecting, Client.Connected is False and Send*/Request raise
// EPipeClosed, as in any window without a session.
```

- **No timeout parameter, on purpose.** The budget is `MaxReconnectAttempts` ×
  `ReconnectDelayMs`, the properties that already existed — with `MaxReconnectAttempts = 0`
  (the default) it tries forever. It is an APPROXIMATE wall-clock ceiling; anyone needing an
  exact deadline calls `Disconnect` from a timer.
- **Success in `OnConnected`, giving up in `OnError`** (`'conexao inicial esgotada apos N
  tentativas'`) — there is no exception to raise, the caller already returned.
- **`Connecting`** says whether it is still trying. It is only about `ConnectAsync`:
  synchronous `Connect` and automatic reconnection never set it.
- **`Disconnect` cancels** (and calling `ConnectAsync` again does too: it cancels the
  previous attempt and restarts). Cancellation applies from the in-flight attempt onward — a
  `PipeConnect` already in progress can still take up to `ReconnectDelayMs` to return, the
  same trade-off automatic reconnection already accepts.
- **Composes with the rest**: `AutoReconnect` takes care of drops after the first
  connection; `FailoverAddresses` is honoured on every attempt, with the same rule as
  reconnection; pub/sub subscriptions made before connecting are sent once the session is up.
- While it is trying, `Address`/`Transport`/`TlsOptions` are **locked** (`EPipeError`), just
  as with an active component — otherwise the next attempt would aim at a different server
  with nobody having asked for it.

### Attempt diagnostics (`OnConnectAttemptFailed`)

The library operates silently: through an outage the client keeps trying, and if reconnection
succeeds nobody is interrupted. The price is a log that goes mute in exactly the window that
matters when someone reports, hours later, that "it wasn't working".

`OnConnectAttemptFailed` fires on every attempt that fails — from `ConnectAsync` (first
connection) **or** from automatic reconnection, indistinctly:

```pascal
procedure TApp.AttemptFailed(Sender: TObject; const AAddress: string;
  AAttempt: Integer; const AError: string);
begin
  Log.Debug(Format('attempt %d against %s failed: %s', [AAttempt, AAddress, AError]));
end;

Client.OnConnectAttemptFailed := AttemptFailed;
```

- **It is not `OnError`, on purpose.** `OnError` is what the app must handle; a failed attempt
  is the normal state of a client waiting for its server — the next one is already on its way.
  The definitive outcome still arrives in `OnConnected` or in the exhaustion `OnError`.
- **`AAddress` is the address that FAILED**, passed by value. Do not read `ActiveAddress` in
  the handler: with `FailoverAddresses` the index has already advanced when the event is
  raised, so the property would answer for the *next* address.
- **`AAttempt`** is the same counter `MaxReconnectAttempts` caps (starts at 1, resets when a
  session lasts longer than `ReconnectDelayMs`).
- **`AError`** is the transport's message — what separates "server absent" from "server
  refused my certificate".
- **Frequency**: ~1 event per `ReconnectDelayMs` for as long as the outage lasts. The library
  does not decimate or aggregate; `AAttempt` is what lets your logger space records out and
  just accumulate the counter. With no handler assigned, zero cost.

### Address failover (`FailoverAddresses`)

`TPipeClient` only (`TPipeServer` listens on a single `Address`; there is nothing to "fail
over" to on the accepting side). Addresses are tried in order AFTER `Address`, the primary —
empty by default, behaviour identical to before this property existed. They all share the
client's `Transport`/`TlsOptions`/`KeepAliveSeconds`: they are alternative network locations
of the SAME service (e.g. main store and DR of the same back office), not a way to talk to a
different server.

```pascal
Client := TPipeClient.Create('main-store:9000', ptTcp);
Client.FailoverAddresses := ['dr-store:9000'];
Client.AutoReconnect := True;
Client.Connect(5000);             // splits the deadline across the addresses
WriteLn(Client.ActiveAddress);    // which one the current session uses
```

`Connect(ATimeoutMs)` goes around the list with an equal slice of the deadline per address,
until one connects or the total expires. Automatic reconnection (`AutoReconnect`) advances
one address per failed attempt, and goes back to preferring the primary as soon as a session
lasts longer than `ReconnectDelayMs` — a "real" session on an alternate does not leave the
client stuck on it: the NEXT failure tries the primary again before spreading to the others.
`MaxReconnectAttempts`/`ReconnectDelayMs` still count/space per ATTEMPT, with no separate
per-address budget.

### Payload compression (`CompressionMinSize`)

Optional deflate for large, compressible payloads (verbose JSON, repetitive text) — zero
new dependency: `System.ZLib` on Delphi and `paszlib`/`zstream` on FPC, both already part of
the standard install. `CompressionMinSize` (on `TPipeServer`/`TPipeClient`, just like
`MaxMessageSize`) is `0` by default — off, behaviour identical to before this property
existed. Turning it on only affects local PRODUCTION; decoding compressed frames received
from the peer is always active, so you can turn it on on one side only, or on both at
different points of a rollout, without breaking anything.

```pascal
Client.CompressionMinSize := 512; // only tries to compress payloads >= 512 bytes
Client.SendText(LargeRepetitiveJson); // goes out compressed if it pays off
```

Only `SendBytes`/`SendText`/`Request`/`Publish` (and their batch versions) are candidates —
a payload below the minimum, or one that doesn't pay off (already-compressed data like an
image), goes out raw with no warning at all: it's a silent optimization, not a wire-format
guarantee. `Stats`'s `BytesSent`/`BytesReceived` keep counting the LOGICAL payload (the
app's view); whoever wants to see the real bandwidth savings uses the sibling fields
`BytesSentWire`/`BytesReceivedWire` (see the "Metrics/observability" section above) —
including on the side that only RECEIVES, which otherwise would have no way to know
(decompression already returns the logical bytes before the app sees the frame).
`MaxMessageSize` is validated against the ORIGINAL payload before compressing, and decoding
is protected against zip bombs (a small compressed payload that "explodes" when
decompressed): the ceiling is the same `MaxMessageSize`, checked during decompression, not
just on the final result. Full rationale (why it's a new NPF1 kind and not a flag bit) in
`docs/ARCHITECTURE.en.md`.

### LAN server discovery (`Pipes.Discovery`)

"Where is the server?" without typing an IP: the server announces itself with a
`TPipeDiscoveryResponder` and the client asks over UDP broadcast with
`PipeDiscoverServers`. The reply carries an address ready for `Address` (the IP is the
reply's source address — correct even on a multi-NIC server), the transport and a display
name. It is a **complement** to the transports, not a transport: nothing of NPF1 travels
here, and security stays where it always was — discovery finds candidates, `ptTls`
authenticates who is real.

```pascal
// Server side, next to Listen:
Responder := TPipeDiscoveryResponder.Create(
  9000,           // SERVICE port (the TPipeServer one)
  ptTls,          // transport the client should use
  'Store 3 backend'
);                // discovery port and token are optional
Responder.Start;

// Client side, before Connect:
Found := PipeDiscoverServers(1000); // 1s window on the subnet
if Length(Found) > 0 then
begin
  Client.Address := Found[0].Address;         // ready-made 'ip:port'
  // with more than one, the rest becomes failover:
  // Client.FailoverAddresses := [Found[1].Address, ...];
  Client.Connect(5000);
end;
```

An empty list is not an error — it means "nobody answered" (the window expires silently).
An optional `Token` separates installations sharing the same network (a discriminator, not
authentication). The reach is the **local subnet**: broadcast does not cross routers or
VPNs — a remote POS keeps its configured IP + `FailoverAddresses`. The directed form
`PipeDiscoverServers('192.168.1.10', ...)` probes a specific host ("is the server
alive?"). Details and rationale in `docs/ARCHITECTURE.en.md` §16.

## Features

- **Multi-client server** — acceptor + one reader thread per connection; optional
  `MaxClients`; per-connection `SendBytes/SendText`; `Broadcast/BroadcastText`;
  `DisconnectClient`; `OnClientConnected`/`OnClientDisconnected` events.
- **Synchronous Request-Reply** — `Request/RequestText(data, timeout)` on the client blocks
  the *caller* (never the read thread) until the correlated reply; on the server, the
  `OnRequest` handler returns the reply and the lib sends it with the right correlation id.
  An exception in the handler becomes an error reply (`EPipeError` on the client, carrying
  the server's message). Concurrent calls from multiple threads on the same client are
  supported.
- **Topic pub/sub** — the sender names a **subject**, not a recipient:
  `Server.Publish('caixa.3.status', data)` reaches every client whose filter matches the
  topic, and no one else. The client subscribes with hierarchical wildcards
  (`Subscribe('caixa.*.status')`, `Subscribe('caixa.#')`) and receives in `OnTopicMessage`.
  Subscriptions are **restored automatically** on every reconnection. Optionally the server
  **retains the last value** of a topic (`Publish(..., ARetain := True)`), delivered
  immediately to whoever subscribes later. See [Pub/sub](#pubsub-topics).
- **AutoReconnect** — the client reconnects on its own after the server goes down
  (`ReconnectDelayMs`, `MaxReconnectAttempts`). During the reconnection window, `Send*`
  raises a transient `EPipeClosed` — retry (same contract as republishing on an MQ client).
  Attempts are **always spaced** by `ReconnectDelayMs`, including against a peer that
  accepts the connection and drops it right away (the case of an mTLS server refusing the
  certificate); and `MaxReconnectAttempts` covers that case too. The counter resets when a
  session lasts longer than `ReconnectDelayMs` — a too-short session counts as an attempt,
  so a rejected client does not reconnect forever, and a long-lived client that
  legitimately reconnects does not accumulate toward the ceiling.
- **ConnectAsync** — the first connection attempted in the BACKGROUND, for when the app
  starts BEFORE the server. `Connect` blocks and fails at the deadline; `AutoReconnect` only
  kicks in after a session has existed and dropped — `ConnectAsync` covers the gap between
  the two. See [Asynchronous connect](#asynchronous-connect-connectasync).
- **Attempt diagnostics** (`OnConnectAttemptFailed`) — one event per failed connection
  attempt, carrying the address, the attempt number and the transport message. For forensic
  logging: it fills the silent window between the drop and the recovery. See
  [Attempt diagnostics](#attempt-diagnostics-onconnectattemptfailed).
- **Dispatch modes** (`DispatchMode`) — where YOUR handlers run:
  - `pdmPool` (default): thread pool; parallel across connections.
  - `pdmSerialized`: single worker; global FIFO order guaranteed.
  - `pdmMainThread`: straight on the UI thread via `TThread.Queue` — for VCL/LCL apps,
    without manual `Synchronize` and without post-destroy event risk (internal guard
    object).
- **Protection** — `MaxMessageSize` (default 16 MB) rejects frames above the limit on both
  ends; invalid magic/kind takes down only the offending connection (`EPipeProtocol` in
  `OnError`).
- **TLS and mTLS** (`ptTls`) — encrypted traffic over TCP, with optional certificate-based
  client authentication: filling `CaFile` on the server makes anyone not presenting a
  certificate from that CA get refused before `OnClientConnected`. Native backend per
  platform (Schannel on Windows, OpenSSL on Linux) and a dedicated handshake deadline, so a
  peer that opens the connection and stays silent does not consume a thread indefinitely.
- **LAN discovery** (`Pipes.Discovery`) — `TPipeDiscoveryResponder` on the server +
  `PipeDiscoverServers` on the client find the server on the subnet via UDP broadcast,
  with no configured IP; the result feeds `Address`/`FailoverAddresses`. See
  [LAN server discovery](#lan-server-discovery-pipesdiscovery).

## Pub/sub (topics)

`SendBytes` needs a `ConnId`; `Broadcast` goes to everyone. Between the two, the most
common case in a system with several endpoints is missing: **sending by subject**, without
the sender knowing who is interested. That is what pub/sub solves.

```pascal
// --- server ---
Server.Publish('caixa.3.status', data);                // only subscribers receive it
Server.PublishText('loja.tabela.versao', 'v42', True); // True = retain the last value

// --- client ---
Client.OnTopicMessage := Self.Received;  // (...; const ATopic; const AData; ARetained)
Client.Subscribe('caixa.*.status');      // one segment in place of '*'
Client.Subscribe('loja.#');              // everything below 'loja'
Client.PublishText('caixa.3.status', 'busy');
```

**Names and wildcards.** A topic is hierarchical, dot-separated, case-sensitive, with no
empty segments. Publishers use literal names; subscribers may use wildcards, always
occupying a whole segment:

| Filter | Matches | Does not match |
|---|---|---|
| `caixa.3.status` | `caixa.3.status` | `caixa.4.status` |
| `caixa.*.status` | `caixa.3.status` | `caixa.3.a.status` |
| `caixa.#` | `caixa.3`, `caixa.3.a.b`, `caixa` | `loja.3` |

`#` may only be the last segment (`a.#.b` is refused: its two possible readings would give
different results). `caixa*` is also refused — a wildcard glued to text would promise a
partial match the lib does not do. `Subscribe` raises `EPipeError` immediately for an
invalid filter; so does a `Publish` with an invalid name.

**Who may relay.** A **client** publication does not reach the other clients by default: it
arrives at the server in `OnPublish`, which decides. Turning on
`RelayClientPublish := True` makes the lib relay on its own (including back to the author,
if they subscribe to the topic) — convenient for a chat, and dangerous in a system where a
client should not be able to inject content into another's subject. The default (off)
keeps the server authoritative, as in the game samples:

```pascal
procedure TBackoffice.OnClientPublication(Sender: TObject; AConnId: TPipeConnectionId;
  const ATopic: string; const AData: TBytes);
begin
  if not PipeTopicMatches('caixa.*.status', ATopic) then Exit;  // wrong place: ignore
  Server.Publish(ATopic, AData, True);                          // republish, retaining
end;
```

**Retention (`ARetain`) is a last-value cache, not a queue.** The server stores **one**
message per topic and delivers it to whoever subscribes later — it is the answer to "the
client that just came online needs the current state" without it having to ask. Publishing
an empty body with `ARetain := True` deletes the retained value. The ceiling is
`MaxRetained` (256 by default; beyond it the oldest retained topic is evicted). A message
that must survive the process, or be delivered with guarantees, calls for a real queue —
that is what [pascal-amqp-faa](https://github.com/fabianoallex/pascal-amqp-faa) is for.

The last parameter of `OnTopicMessage`, **`ARetained`**, answers the question the consumer
needs to ask: *did this just happen, or is it the value that was already in force?* `True`
only on subscription catch-up; a live publication arrives **always** `False`, even when the
publisher asked for retention (MQTT semantics, and for the same reason: the receiver wants
to know whether the message is news or history, not what the sender asked of the server).
Use it to avoid ringing the bell or counting a sale twice on reconnection. On the server
side, `OnPublish`'s `ARetained` has the other meaning — the only one possible there: the
client **asked** to retain.

**Reconnection.** Subscriptions are the client's desired state, not the session's:
`Subscribe` works while disconnected, and everything is resent to the server on each new
session **before** `OnConnected` fires — your handler does not need to resubscribe
anything. What is not recovered is the window between the drop and the resubscription: a
publication that passed through there is lost (that is where retain helps).

**Order and limits.** Delivery from a single publisher preserves order; across different
publishers there is no global order (use `pdmSerialized` if you need FIFO in your
handlers). `OnPublish`, `OnSubscribe` and `OnUnsubscribe` are **notifications** — routing
has already happened by the time they run, and there is no vetoing from inside them; to
deny a subscription, call `DisconnectClient`. `MaxSubscriptionsPerClient` (64 by default)
limits how many filters a client may register; the refusal shows up in `OnError` **on both
sides**, and the connection stays up.

**Delivery confirmation.** `Publish`'s log (one call, from the publisher's side) does not
say whether each subscriber received it — that is what `OnDelivered`/`OnDeliveryFailed` are
for, on the server: they fire **once per connection** that matched a publication made by the
**server itself** (`Publish`/`PublishBatch`, live or retained replay — `ARetained` in the
same sense as `OnTopicMessage`), after that connection's `Write` returns. "Delivered" only
goes as far as the OS — the payload was handed to the socket/pipe buffer, not that the
client's app processed it; the protocol never had an application ACK. `OnPublish` is a
different thing: it is about a **client** publishing, it does not cover the server being the
publisher.

**Wire compatibility.** The pub/sub frame kinds are new in the `NPF1` protocol. A peer
built with an earlier version of the lib that receives one of them drops with
`EPipeProtocol` ("the peer probably speaks a newer protocol version") instead of
misreading bytes — update both sides.

## Threading guarantees

- The read thread **never** runs user code — it only decodes and dispatches.
- `Stop`/`Disconnect`/destructors are **synchronous, idempotent and deadlock-free**: they
  signal everything, wait for the threads to join, and drain in-flight callbacks before
  releasing any object (verified by test: `Stop` under a 4-client flood finishes in < 2 s).
- Abrupt peer death (killed process, closed handle) fires `OnClientDisconnected` /
  `OnDisconnected` without leaking handles/fds (verified by a handle-counting test).
- Callbacks are always `procedure ... of object`; exceptions inside them are swallowed by
  the pool (logging via `OnError` is your responsibility).
- Semantic detail: a client that connects and dies **before the server accepts** the
  connection is invisible (no events) — the instance/backlog is recycled.

## Installation

**Delphi:** add `src\` to the search path (or open `Pipes.groupproj`).

**Lazarus:** open/compile `packages\pipes_faa.lpk` once and add `pipes_faa` to your
project's requirements (or use `lazbuild --add-package-link packages\pipes_faa.lpk`).

**Dependencies:** none for `ptLocal` and `ptTcp`, and none at compile time in any case. For
`ptTls` it depends on the backend:

- **Schannel** (default on Windows): nothing to install — it is SSPI, part of the OS.
- **OpenSSL** (`-dPIPES_OPENSSL`; the only one on Linux): needs `libssl`/`libcrypto` **on
  the machine that runs**. They are loaded dynamically at the first TLS connection, so
  their absence does not prevent compiling or starting the program — it shows up as
  `EPipeTls` ("OpenSSL not found") at the first connection. The 3.x and 1.1 series are
  accepted. On Linux the distributions already ship them; on Windows you must provide the
  DLLs (`libcrypto-3-x64.dll` + `libssl-3-x64.dll`, or the 1.1 equivalents).

## API (summary)

```pascal
TPipeBase (abstract)
  Address, Transport, KeepAliveSeconds, HeartbeatIntervalMs, Active, DispatchMode,
  MaxMessageSize
  CompressionMinSize                     // 0 (default) = production off; decoding of
                                          // received frames is always active
  TlsOptions: TPipeTlsConfig             // only used by ptTls; read at Listen/Connect
    CertFile, CertPassword, KeyFile, CaFile, SkipServerVerification, HandshakeTimeoutMs
  OnMessage: TPipeMessageEvent;  OnError: TPipeErrorEvent

TPipeServer
  Listen; Stop;                          // Listen non-blocking; Stop synchronous
  SendBytes/SendText(ConnId, ..., AGroupKey = '')  // EPipeError if ConnId does not exist
                                          // AGroupKey: order between calls preserved in the
                                          // RECEIVER's OnMessage even under pdmPool (the
                                          // default); different keys stay parallel
  SendBytesBatch(ConnId, TArray<TBytes>) // N messages, a single Write; order preserved
  Broadcast/BroadcastText(...)           // snapshot; per-connection failure is swallowed
  Publish/PublishText(Topic, ..., Retain = False)  // only topic subscribers
  PublishBatch(TArray<TPipePublishItem>) // N items (Topic/Payload/Retain); one Write per connection
  SubscriberCount(Topic)                 // how many would receive a publication
  ClientSubscriptions(ConnId)            // filters that client subscribed to
  ClearRetained                          // retained values do not die on Stop
  RelayClientPublish                     // False: clients cannot inject into others
  MaxSubscriptionsPerClient; MaxRetained
  OnPublish: TPipeTopicEvent             // notification: the fanout already happened
                                         // ARetained here = the client ASKED to retain
  OnSubscribe/OnUnsubscribe: TPipeSubscriptionEvent  // same; deny with DisconnectClient
  OnDelivered: TPipeTopicEvent            // 1x per subscriber that RECEIVED a publication
                                          // made by the SERVER itself (Publish/PublishBatch);
                                          // "delivered" = Write without exception, not an app ACK
  OnDeliveryFailed: TPipeDeliveryFailedEvent  // same, on the failure side; AError = the exception
  DisconnectClient(ConnId)               // asynchronous and idempotent
  ClientCount; ClientIds                 // only ESTABLISHED connections
  TryClientIdentity(ConnId, out Ident)   // who it is, from the validated mTLS certificate
  TryClientAddress(ConnId, out Addr)     // 'ip:port'; False on ptLocal (no IP address)
  MaxClients                             // resource limit: counts handshaking connections
  OnClientConnected/OnClientDisconnected: TPipeConnectionEvent
  OnRequest: TPipeRequestEvent           // (const ARequest: TBytes; out AReply: TBytes)
  Stats: TPipeServerStats                // aggregate, cumulative since Listen
  ConnectionStats(ConnId, out Stats): Boolean  // per connection; dies with it

TPipeClient
  Connect(TimeoutMs); Disconnect;        // Connect retries until the deadline
  ConnectAsync;                          // non-blocking; keeps trying until the server is up
                                         // (success in OnConnected, giving up in OnError)
  SendBytes/SendText(..., AGroupKey = '')  // fire-and-forget; AGroupKey see TPipeServer above
  SendBytesBatch(TArray<TBytes>)         // N messages, a single Write; order preserved
  Request/RequestText(..., TimeoutMs)    // synchronous RPC; EPipeTimeout at the deadline
  Subscribe/Unsubscribe(Filter)          // works while disconnected; redone on reconnect
  Subscriptions                          // subscribed filters (desired state)
  Publish/PublishText(Topic, ...)        // EPipeClosed without a session
  PublishBatch(TArray<TPipePublishItem>) // N items (Topic/Payload/Retain), a single Write
  OnTopicMessage: TPipeTopicEvent        // (...; ATopic; AData; ARetained)
                                         // ARetained: True only on subscription catch-up
  Connected; AutoReconnect; ReconnectDelayMs; MaxReconnectAttempts
  Connecting                             // a ConnectAsync is in flight (only about that)
  FailoverAddresses: TArray<string>      // tried after Address; empty = Address only (default)
  ActiveAddress                          // which address the current session uses (snapshot)
  OnConnected/OnDisconnected: TPipeConnectionEvent
  OnConnectAttemptFailed: TPipeAttemptFailedEvent  // (...; AAddress; AAttempt; AError)
                                         // diagnostics: ONE attempt failed
  Stats: TPipeClientStats                // current SESSION; resets on every reconnect

Pipes.Topics (pure unit, also useful outside the lib)
  PipeTopicMatches(Filter, Topic); PipeIsValidTopic; PipeIsValidTopicFilter
  TPipePublishItem = record Topic; Payload: TBytes; Retain: Boolean; end  // see PublishBatch

Pipes.Json (OPTIONAL — only included by whoever uses it; see "JSON" below)
  TPipeJSONValue                         // = TJSONValue (Delphi) / TJSONData (FPC)
  PipeBytesToJSON(Data): TPipeJSONValue  // parse; EPipeJSONError if invalid/empty
  PipeJSONToBytes(Value): TBytes         // serializes; does not free Value
  PipeSendJSON(Client/Server, ..., Value)     // wrapper over SendBytes
  PipeRequestJSON(Client, Value, TimeoutMs): TPipeJSONValue  // wrapper over Request

Pipes.Commands (OPTIONAL — only included by whoever uses it; see "Commands" below)
  TPipeCommandRouter.RegisterCommand(Command, Handler, AMinSize = -1, AMaxSize = -1)
                                          // EPipeCommandError: duplicate, nil handler,
                                          // invalid name/limits (programming error)
  TPipeCommandRouter.HandleMessage       // same signature as TPipeMessageEvent;
                                          // assign directly to Server/Client.OnMessage
  OnUnknownCommand; OnInvalidPayload: TPipeCommandEvent  // optional, silent
  TPipeCommandRouter.RegisterRequestCommand(Command, Handler, AMinSize = -1, AMaxSize = -1)
                                          // its OWN registry, independent of the message one
  TPipeCommandRouter.HandleRequest       // same signature as TPipeRequestEvent;
                                          // assign directly to Server.OnRequest — RAISES
                                          // (EPipeProtocol) on unknown command/invalid
                                          // payload, unlike HandleMessage
  PipeEncodeCommandPayload/PipeDecodeCommandPayload(Command, Body)  // manual envelope
  PipeSendCommand/PipeSendCommandText(Client|Server, ..., Command, Body)  // SendBytes wrapper
  PipeRequestCommand/PipeRequestCommandText(Client, Command, Body, TimeoutMs)  // Request wrapper

Exceptions: EPipeError > EPipeClosed | EPipeTimeout | EPipeProtocol | EPipeTls |
            EPipeJSONError | EPipeCommandError
```

### JSON (`Pipes.Json.pas`, optional)

The API carries `TBytes`; text becomes JSON like any other text — `SendText`/`RequestText`
are enough if the app builds and reads the JSON with the library of its choice. What
`Pipes.Json.pas` adds is only the bytes⇄JSON boundary using each compiler's native library
(`System.JSON` on Delphi, `fpjson`/`jsonparser` on FPC), hidden behind the `TPipeJSONValue`
alias, plus two thin wrappers (`PipeSendJSON`/`PipeRequestJSON`) over `SendBytes`/`Request`.
It is not part of the core — `Pipes.Client`/`Pipes.Server` know nothing about it — and does
not need to be included by anyone not using JSON.

Building and reading the value (`AddPair` vs `Add`, `GetValue<T>` vs `Get`) remains each
library's native API; unifying that is also outside the unit's scope — anyone with a
specific case (another format, another JSON library) implements it themselves on top of
`TBytes`/`SendBytes`, with no penalty.

```pascal
uses Pipes.Client, Pipes.Json, System.JSON; // or fpjson on FPC

var
  Obj, Reply: TJSONObject;
begin
  Obj := TJSONObject.Create;
  try
    Obj.AddPair('event', 'drawer-opened');
    Obj.AddPair('register', TJSONNumber.Create(3));
    PipeSendJSON(Client, Obj);              // fire-and-forget

    Reply := PipeRequestJSON(Client, Obj, 3000) as TJSONObject; // synchronous RPC
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

### Commands (`Pipes.Commands.pas`, optional)

When the app carries several operations over the same connection (`SAVE_ORDER`, `CANCEL`,
`PING`, ...), the alternative to an `if`/`case` chain inside a single `OnMessage` is
`TPipeCommandRouter`: one `RegisterCommand` per command, each with its own handler. Nothing
changes on the wire — the command name travels inside the payload, and `HandleMessage` has
the same signature as `OnMessage`, so you just assign it directly:

```pascal
uses Pipes.Server, Pipes.Commands;

var
  Router: TPipeCommandRouter;
begin
  Router := TPipeCommandRouter.Create;
  Router.RegisterCommand('PING', OnPing);
  Router.RegisterCommand('SAVE_ORDER', OnSaveOrder, 1); // AMinSize = 1: body cannot be empty
  Server.OnMessage := Router.HandleMessage;
  Server.Listen;
end;

procedure TMyApp.OnSaveOrder(Sender: TObject; AConnId: TPipeConnectionId;
  const ACommand: string; const APayload: TBytes);
begin
  // APayload already comes WITHOUT the envelope prefix, just the body
end;
```

Whoever sends can build the same envelope with `PipeEncodeCommandPayload('SAVE_ORDER', Data)`
and send it through `SendBytes`/`Request` directly, or use the thin wrapper that already does
that: `PipeSendCommand(Client, 'SAVE_ORDER', Data)` (fire-and-forget; there is also a
`PipeSendCommand(Server, AConnId, ...)` overload for the server to reply). Both forms have
`...Text` variants (`PipeSendCommandText`) for a text UTF-8 body/reply, same pattern as
`SendText`/`RequestText`.

`RegisterCommand` takes optional `AMinSize`/`AMaxSize` (`PIPE_COMMAND_NO_LIMIT`,
the default, turns off the respective ceiling), validated BEFORE the handler runs, and
raises `EPipeCommandError` right at registration if the command already exists, the name is
invalid, the handler isn't assigned, or the limits are inconsistent — a programming error,
not a network one. A command with no handler falls through to `OnUnknownCommand`; a payload
outside the range or a malformed envelope falls through to `OnInvalidPayload` — both
optional and silent when nobody subscribes, the same way an `OnMessage` with no subscriber
does nothing. Command names are case-sensitive (same reasoning as topics: there is no
portable UTF-8 upcase). Full rationale, including why it sits on top of `OnMessage` instead
of being a new NPF1 kind, in `docs/ARCHITECTURE.en.md` §18.

The same router also covers the request-reply side, with its OWN registry and method
(`RegisterRequestCommand`/`HandleRequest`, independent of `RegisterCommand`/`HandleMessage`
— the same command name can exist in both without conflict, because `OnMessage`/`OnRequest`
already arrive through different wire kinds):

```pascal
Router.RegisterRequestCommand('SUM', OnSumRequest, 1); // AMinSize = 1
Server.OnRequest := Router.HandleRequest; // same signature as TPipeRequestEvent

procedure TMyApp.OnSumRequest(Sender: TObject; AConnId: TPipeConnectionId;
  const ACommand: string; const APayload: TBytes; out AReply: TBytes);
begin
  AReply := ...; // becomes the reply; NO envelope — the Request caller already knows the command
end;
```

The error contract is the OPPOSITE of the message side, on purpose: `HandleRequest` RAISES
(`EPipeProtocol`) on an unknown command or a payload outside the range, instead of calling
`OnUnknownCommand`/`OnInvalidPayload` — those events don't exist on this side. The reason is
that `TPipeServer.ExecuteRequest` already turns ANY exception coming from `OnRequest` into
an error reply for the client (the client-side `Request` re-raises it as `EPipeError`), the
same path the `EchoJsonServer` sample already uses on purpose with `EPipeJSONError` — and,
unlike `OnMessage`, a `Request` always gets SOME response, so there is no equivalent
"silence" to reuse. Full rationale in `docs/ARCHITECTURE.en.md` §18.8.

On the caller side of the request, `PipeRequestCommand(Client, 'SUM', Data, TimeoutMs)`
builds the envelope and calls `Request` in one step — the return value is the raw `AReply`
from the handler (no envelope, same contract as `HandleRequest`). `PipeRequestCommandText` is
the text UTF-8 variant, same pattern as `RequestText`. Full rationale in
`docs/ARCHITECTURE.en.md` §18.9.

### Compatibility with the previous API

The old names remain valid and compile unchanged — `TNamedPipeBase`, `TNamedPipeServer`
and `TNamedPipeClient` are aliases of the types above, and the `PipeName` property reads
and writes the same field as `Address`:

```pascal
Server := TNamedPipeServer.Create('my_app');   // same as TPipeServer
Server.PipeName := 'other';                    // same as Server.Address
```

The old name tied the API to the Windows Named Pipe, which is now just one of the possible
transports — on Linux the backend is already a Unix Domain Socket. The aliases will be
marked `deprecated` only after samples and tests migrate.

## Samples (`samples/`)

- **EchoServer / EchoClient** — console, same source on both compilers. Run the server,
  then the client: plain text uses `SendText` (asynchronous echo via `OnMessage`); lines
  starting with `?` use `RequestText` (RPC). Both take an optional second argument `tcp`
  (`EchoServer.exe *:5300 tcp`, `EchoClient.exe 192.168.0.10:5300 tcp`) to swap `ptLocal`
  for `ptTcp` — that is how **EchoAndroid** talks to them, since a phone cannot reach a
  Named Pipe or a Unix Domain Socket. Without the argument, behaviour is unchanged.
- **EchoJson** (`EchoJsonServer` + `EchoJsonClient`) — the same echo, but with a JSON
  payload via `Pipes.Json.pas` instead of raw text (see the "JSON" section above). Type
  `item quantity` (e.g. `coffee 2`) for fire-and-forget `PipeSendJSON` — the asynchronous
  acknowledgement arrives in `OnMessage` — or `?item quantity` for a synchronous
  `PipeRequestJSON`, with the total computed by the server in the reply. It also shows the
  one part `Pipes.Json.pas` does not hide: building/reading the value (`AddPair` vs `Add`,
  `GetValue<T>` vs `Get`) is a `{$IFDEF FPC}` local to the sample, behind two small
  functions (`JStr`/`JInt`).
- **EchoCommand** (`EchoCommandServer` + `EchoCommandClient`) — showcase for
  `TPipeCommandRouter` on both sides (see the "Commands" section above): fire-and-forget
  commands (`PING`/`ECO` on the server, `PONG`/`ECO_OK` on the client, via `OnMessage`) and
  a request-reply command (`SOMAR`, via `OnRequest`/`Request`), each with its own handler
  instead of an `if` chain. Type `ping`/`eco <text>` for the asynchronous ones, `?soma <a>
  <b>` for the synchronous RPC (adds two integers, keyboard prompts are in Portuguese in
  this sample) — and `?ping` to see the request-reply "unknown command" path on purpose:
  `PING` is only registered on the message side, so asking for it as a `Request` raises
  `EPipeError` on the client. Both sides send through the convenience wrappers
  `PipeSendCommand`/`PipeSendCommandText`/`PipeRequestCommand`/`PipeRequestCommandText`
  instead of building `PipeEncodeCommandPayload` + `SendBytes`/`Request` by hand.
- **EchoFailover** (just `EchoFailoverClient` — it reuses the usual `EchoServer.exe`, run
  twice) — showcase for `FailoverAddresses`/`ActiveAddress` (see the "Address failover"
  section above). Start `EchoServer.exe pipes_faa_primario` and
  `EchoServer.exe pipes_faa_backup`, then
  `EchoFailoverClient.exe pipes_faa_primario pipes_faa_backup`: exchange messages (the log
  shows `endereço ativo: pipes_faa_primario`), close the primary's window and exchange
  messages again — without restarting the client, the log switches to
  `endereço ativo: pipes_faa_backup`. Full script in the header of
  `EchoFailoverClient.dpr`.
- **EchoDiscovery** (just `EchoDiscoveryClient` — it reuses the usual `EchoServer.exe`, with
  one extra argument) — showcase for `Pipes.Discovery` (see the "LAN server discovery"
  section above). Start `EchoServer.exe *:5300 tcp discover` (the trailing `discover` turns
  on a `TPipeDiscoveryResponder` alongside `Listen`), then run `EchoDiscoveryClient.exe`
  with no argument at all: it probes the subnet for 1s, logs a line naming the server found
  at its address/transport and connects on its own, no IP typed in. With
  `EchoServer.exe *:5300 tls ..\..\tests\pki mtls discover` +
  `EchoDiscoveryClient.exe ..\..\tests\pki cli` you can see §16.4's distinction in practice:
  discovery only finds the candidate (address, transport, name) — what actually
  authenticates is the `ptTls`/mTLS handshake that follows, not the UDP probe.
- **EchoAndroid** — **Android** client (FMX, Delphi only) for `EchoServer`: connects over
  `ptTcp` or `ptTls`, sends text and shows the reply. A showcase of what changes on a
  phone — `pdmMainThread`, `Connect` off the main thread, `HeartbeatIntervalMs` on (sleeping
  Wi-Fi and carrier NAT drop idle connections silently). The sample's `LEIA-ME.md` has the
  IDE steps that cannot be versioned in the `.dproj`: the `INTERNET` permission,
  `usesCleartextTraffic` and packaging OpenSSL per ABI.
- **EchoSeguro** (`EchoSeguroServer` + `EchoSeguroClient`) — the same echo, but over
  `ptTls` with mTLS: the server demands a client certificate (`CaFile`), the client
  presents its own, traffic encrypted end to end. Uses the test PKI versioned in
  `tests/pki`; a client without a certificate (or a plain `TPipeClient`) is refused before
  `OnClientConnected` fires — proof that the mTLS is not decorative.
- **ChatVcl** — chat with a UI (VCL on Delphi, LCL on Lazarus, same source): one instance
  is the server-hub (relays via `Broadcast`), the others are clients. Showcase of
  `pdmMainThread` (handlers touch the UI directly) and `AutoReconnect`.
- **ChatSeguro** — the same chat over `ptTls` with mTLS, and the difference is not just the
  encryption: **who is in the room comes from the certificate, not from a typed nickname.**
  The hub labels each message with the `CommonName` that `TryClientIdentity` returns, and
  the participant list comes from `ClientIds` — which only shows established connections.
  The identity combo switches the presented certificate, including the ones that **must be
  refused** (`rogue`, `selfsigned`): that is where you see mTLS working, not on the happy
  path. Needs the PKI from [`tests/pki/`](tests/pki/README.en.md), which the form locates
  by itself.
- **PontosECaixas** — the dots-and-boxes game for two players, one window each (VCL on
  Delphi, LCL on Lazarus, same source). One side clicks **Host**, the other types the
  address and clicks **Join**; the combo picks `ptLocal` (two windows on the same machine)
  or `ptTcp` (two machines) — the game code does not change, only the `Transport` value.
  What it shows that the others do not:
  **authoritative server** (the host holds the only `TJogoPartida` that counts; the guest
  *requests* the move and waits for the state to come back, never applying its own —
  playing out of turn or on a used edge is refused by the same `TentarJogar` that validates
  the local click); **reconnection that returns the seat** (the guest repeats a token in
  `OnConnected`, which the lib also fires on every automatic reconnection — close its
  window mid-game and reopen to see the board come back whole); **two refusal layers with
  different roles** (`MaxClients` is a resource ceiling, "the game already has two players"
  is business logic in the `OI`, which is why it manages to send the reason before hanging
  up); and the handling of the **zombie connection** — when the same token arrives on a new
  connection, the previous one usually remains alive on the server (TCP dead in silence,
  typical of VPN/NAT) and is taken down with `DisconnectClient` before the seat is
  reassigned.
  It also shows the price of synchronizing by **state** instead of by event: the full board
  does not say *what changed*, so the receiver would not know where the opponent played —
  the edge would simply appear. That is why the `ESTADO` carries the last edge played,
  which the UI highlights for ~0.6 s (edge thickening and brightening + rings expanding on
  both dots). Two checkboxes at join time enable the AI-controlled player (`Jogo.Ia.pas`,
  chain heuristic with *double-cross*): **"computer plays for me"**, valid in both roles —
  on the guest the bot becomes an autonomous client, sending `JOGADA` over the network and
  passing the same validation as any human — and **"computer takes the guest's seat"**,
  which gives a solo game against the machine (then a human who tries to join is refused
  with the reason). Check both and you can watch bot against bot.
- **PingPong** — the classic pong for two players, one window each, same `Host`/`Join`
  scheme and same `ptLocal`/`ptTcp` combo as PontosECaixas. **To try it alone you do not
  need a second window: check "Computer takes the guest's seat" and click Host.** What it
  shows that PontosECaixas does not is a world that **moves on its own** — and the five
  consequences of that:
  **the game clock is not the `TTimer`** (an accumulator measures real time and takes as
  many 16 ms steps as fit, otherwise the ball would move faster or slower with timer
  jitter, and the two screens would diverge);
  **input goes by edge, state comes by level** (the guest only sends `ENTRADA` when the
  paddle direction *changes*; the host sends the whole snapshot ~31x per second — the first
  choice is only safe because the transport is reliable and ordered, and would be a bug
  over UDP);
  **the guest predicts** (it runs the same physics locally between one snapshot and the
  next, with `AEhAutoridade = False`: predicting movement is one thing, deciding a point is
  another — the mirror that sees the ball leave the field just stops and waits for the
  `ESTADO` to say what happened);
  **even prediction has a deadline** (1.5 s without a snapshot and it freezes, with the
  screen saying so, instead of animating a game that may no longer exist);
  and **the bot has no timer** — it is called inside the simulation step, together with the
  physics, and the direction it returns enters through the same door as the keyboard (on
  the guest, it becomes `ENTRADA` on the network). Floating-point numbers go on the wire as
  integers in hundredths on purpose: `FloatToStr` uses the *locale's* decimal separator,
  and a pt-BR host sending `412,75` to an en-US guest is a network bug nobody looks for.
  The bot level (`Pong.Ia.pas`) changes only the **reaction horizon** and the prediction
  quality, never the paddle speed — see the unit header for why that is the only lever that
  closes a point.
  Alongside it comes **`PongCheck`**, a console program in the same directory that verifies
  the game core **without opening a window and without waiting for the clock**: it runs ~48
  minutes of simulated play in ~40 ms. That is only possible because the three game units
  depend neither on the UI nor on the library (`uses SysUtils` and nothing else), which is
  the practical argument for the separation the sample preaches. It checks the `ESTADO`
  round-trip field by field, that the mirror does **not score on its own** after 15 s
  without a snapshot, the prediction error under four rate combinations, and that the bot
  closes points at all three levels — it caught the first version of the bot, where two
  "mediums" would draw for ten minutes. Fixed `Random` seed, so a failure is reproducible.
  It does not cover `uPongMain.pas` or the library: it is a test of the pure core, not
  integration.
- **PdvDualScreen** (`Operador` + `Cliente`) — dual-screen POS: the operator enters items
  and requests the payment method; the customer follows along and answers. Shows the
  pattern recommended for production use: neither side's UI speaks
  `TBytes`/`TPipeConnectionId` directly, only the domain types (`TPdvItem`,
  `TPdvFormaPagamento`) through a facade (`Pdv.OperadorChannel`/`Pdv.ClienteChannel`) that
  encapsulates `TPipeServer`/`TPipeClient` and the message protocol (`Pdv.Protocolo.pas`).
- **FilaImpressao** (`FilaServidor` + `FilaCliente`) — shows `pdmSerialized` vs `pdmPool`
  in practice: a handler with (deliberately) lock-free shared state processes jobs arriving
  in sequence; `FilaServidor pipe serialized` (default) never detects reentrancy and
  finishes in arrival order, `FilaServidor pipe pool` detects real concurrency and
  out-of-order completion with the same load.
- **DespachoTarefas** (`DespachoServidor` + `DespachoWorker`) — shows per-connection
  addressing instead of `Broadcast`: the operator types `job <text>` and the server
  dispatches to ONE worker at a time (round-robin over `ClientIds`); also exercises
  `MaxClients`, `DisconnectClient` (`kick` command) and `list`.
- **ServicoInstavel** (`ServicoInstavel` + `ClienteResiliente`) — a server that simulates
  slowness and random business failures in `OnRequest`; the client shows a retry pattern
  with exponential backoff that treats `EPipeTimeout`/`EPipeClosed` (transient, retry) and
  `EPipeError` (business error, do not retry) differently.
- **RpcConcorrente** (`RpcConcorrenteServidor` + `RpcConcorrenteCliente`) — proves the
  guarantee that `Request`/`RequestText` calls from several threads on the SAME
  `TPipeClient` are supported: several `TThread`s share a single client instance and fire
  RPCs in parallel; each one checks that the reply that came back is exactly the one for
  the request it made (correlation id), exposing any reply crossover between callers as a
  bug. Prints `Client.Stats` at the end: it's the showcase for Request latency
  (average/max), the metric that only makes sense with concurrent traffic like this.
- **GatewaySeguro** (`ServicoLocal` + `GatewaySeguro` + `ClienteRemoto`) — the only sample
  where `TPipeServer` and `TPipeClient` are **alive at the same time** in the same process,
  with different transports on each end:
  `[ClienteRemoto] --ptTls+mTLS--> [GatewaySeguro] --ptLocal--> [ServicoLocal]`. The other
  samples prove that reach is a property; this one proves that reaches **compose**. The use
  case is what people actually have: a service that only speaks local IPC and will never
  learn TLS, and the need to expose it to the network with authentication.
  The gateway authenticates via mTLS, knows who the peer is (`TryClientIdentity` returns
  the `CommonName` **already validated against the CA** — a forged CN never gets there) and
  needs to **tell** the local service who is calling (`IDENT|` frame), because `ptLocal`
  has no TLS and therefore no identity at all. Why should the service believe it? Because
  `ptLocal` inherits the operating system's access control — **the gateway's security does
  not come from the gateway; it comes from the reach of the transport behind it**. With
  `ServicoLocal` on `ptTcp` listening on `0.0.0.0`, the whole scheme collapses: anyone
  skips the gateway and declares themselves whoever they want.
  It also shows the **two layers of "connected"** (the remote peer can authenticate
  successfully and still receive `RECUSADO|<reason>` because `ServicoLocal` is down — a
  completed TLS handshake is not the same as a useful session, which is why the refusal
  carries a reason instead of being a silently closed socket) and the pattern that avoids
  the worst deadlock in this design: `TPipeClient.Disconnect` is synchronous (reader-thread
  join + `DrainInFlight`), so **no peer `Free`/`Disconnect` happens inside a callback** —
  the callback only marks, and a reaper (`TThread` with a queue and an event) destroys. The
  full rationale, with the lock invariants and what was left out of this version (`Request`
  relay), is in the header of
  [`Gateway.Nucleo.pas`](samples/GatewaySeguro/Gateway.Nucleo.pas).
  `ClienteRemoto <address> <identity>` picks the certificate: `cli` and `caixa` get in —
  run both together and watch `ServicoLocal` stamp the **right** identity on each reply,
  because identity crossover would be the worst possible bug in a gateway; `rogue`,
  `selfsigned` and `nenhum` are refused **and `ServicoLocal` logs absolutely nothing**,
  which is the proof that nothing leaked through. Needs the PKI from
  [`tests/pki/`](tests/pki/README.en.md). Run script for the three processes (and
  regression checklist) in
  [`samples/GatewaySeguro/README.en.md`](samples/GatewaySeguro/README.en.md).
- **PainelLoja** — the **pub/sub** sample: one executable, three roles chosen by the first
  parameter, one window each.

  ```
  PainelLoja retaguarda        PainelLoja caixa 3        PainelLoja painel
  ```

  None of the three calls `SendBytes` with any `ConnId`: the backoffice publishes on
  `loja.tabela.versao`, each register publishes `caixa.<n>.status`, the panel subscribes to
  `caixa.#` and sees them all — **including registers that did not exist yet** when it
  subscribed. Adding a register does not change one line of the backoffice.
  What it shows that the others do not: **relay off** (the default) with the backoffice
  deciding in `OnPublish` whether to republish, and using `PipeTopicMatches` to check
  whether the client published in the right place — the same authoritative design as the
  game samples, now over topics; and **retain** doing real work: **open the panel last**
  and it draws the store's current state immediately, without waiting for anyone's next
  tick. Close and reopen: it rebuilds the state, not the conversation — retain stores the
  last value of each topic, not history. The register, with `AutoReconnect`, shows both
  sides of the coin: publishing without a session **raises** (it logs and the next tick
  retries), while **subscriptions** come back on their own, with nothing in `OnConnected`.
- **MonitorTopicos** — pub/sub with a **UI** (VCL on Delphi, LCL on Lazarus, same source)
  and, in practice, a **tool**: it serves to debug the pub/sub of any app built with the
  lib. One window `Host`, the others `Join`, same `ptLocal`/`ptTcp` combo as the game
  samples. Three things about the feature are only visible here:
  **subscriptions manipulated live** (subscribe and unsubscribe with the app running;
  better, build the list *disconnected* — `Subscribe` is desired state — connect afterward
  and it already holds);
  **the effect of `RelayClientPublish` in one click** (two client windows subscribing to
  the same topic: check the box on the host and what one publishes reaches the other,
  uncheck and delivery stops instantly — it is the feature's central decision, and the
  property has no `EnsureInactive` precisely to allow this experiment);
  and **the refusal path**, which no other sample exercises (lower `MaxSubscriptions` and
  watch the subscription get refused with the message appearing on **both** sides,
  connection up; type `caixa*` and watch `EPipeError` immediately, before it becomes a
  frame).
  The received list stamps **`ret`** on what came from the retained cache, which makes
  visible the difference between *drawing the state that already existed* and *following
  what happens*. Hosting, the subscriptions panel shows **who subscribed to what**
  (`ClientSubscriptions` per connection) and the `SubscriberCount` count for the topic in
  the Publish field — the router's view; as a client, it shows your own, editable. 2-minute
  walkthrough in the header of
  [`MonitorTopicos.dpr`](samples/MonitorTopicos/MonitorTopicos.dpr).
- **TransferenciaArquivos** — file transfer with a **UI** (VCL on Delphi, LCL on Lazarus,
  same source), a showcase for `CompressionMinSize` and `Stats`'s `*Wire` fields. One
  instance `Ser servidor` (saves what arrives into `recebidos/`), the other `Ser cliente`
  (`Selecionar...` picks the file, `Enviar arquivo` sends it). The "Compress" checkbox is
  only editable BEFORE connecting — it locks afterward, the same rule as `MaxMessageSize`
  (`EnsureInactive`) — and shows in practice why it's a new NPF1 kind, not a `Flags` bit:
  turning it on on one side only doesn't break anything on the other. Each send logs the
  real savings on BOTH sides: the client via the delta in `Client.Stats` (`BytesSent` vs
  `BytesSentWire`) before/after `SendBytes`, and the server via
  `ConnectionStats.BytesReceivedWire` — the only way for whoever only RECEIVES to see the
  savings, since decompression returns the logical payload before `OnMessage` runs (opaque
  by design). The file protocol itself belongs only to this sample (not the lib): a raw
  `[NameLength][UTF8Name][Bytes]` envelope over `SendBytes`, the whole file in memory — no
  chunking, not production streaming.

## Tests

- Delphi: open `Pipes.groupproj` and run `Pipes.UnitTests` and `Pipes.IntegrationTests`
  (DUnitX).
- FPC/Lazarus (Windows): `lazbuild tests\Unit\fpc\PipesUnitTestsFpc.lpi` and
  `lazbuild tests\Integration\fpc\PipesIntegrationTestsFpc.lpi`; run the exes with
  `--all --format=plain` (no parameters opens the test GUI).
- Linux (Docker): the Debian Bookworm image ships the exact FPC 3.2.2:

  ```bash
  docker run --rm -v "$PWD:/work" debian:bookworm bash -c '
    apt-get update -qq && apt-get install -y -qq fpc >/dev/null
    cd /work/tests/Integration/fpc
    fpc -MDelphi -Sh -B -Fu../../../src -Fi../../../src -FU/tmp -o/tmp/t \
      PipesIntegrationTestsFpc.lpr
    /tmp/t --all --format=plain'
  ```

  (`-Fi` is required since the tests started including `pipes.inc`, to see which backends
  the build has.)

- OpenSSL **1.1** (the other supported branch): swap the image for `debian:bullseye`, which
  ships `libssl 1.1.1` and does **not** have 3.x, and compile with `-dPIPES_OPENSSL`
  (without the directive there is no TLS backend and the `ptTls` suite does not run). It is
  not redundant with the previous one — it is the only way to exercise the 1.1/3.x
  divergences, and **two have already bitten for real**:

  ```bash
  docker run --rm -v "$PWD:/work" debian:bullseye bash -c '
    apt-get update -qq && apt-get install -y -qq fpc libssl1.1 >/dev/null
    cd /work/tests/Integration/fpc
    fpc -MDelphi -Sh -B -dPIPES_OPENSSL -Fu../../../src -Fi../../../src \
      -FU/tmp -o/tmp/t PipesIntegrationTestsFpc.lpr
    /tmp/t --all --format=plain'
  ```

  1. The **symbol fallback** of the peer-certificate getter, which 3.x renamed
     (`SSL_get_peer_certificate` → `SSL_get1_peer_certificate`). With both versions
     installed the loader would pick 3.x and the old branch would never run.
  2. **Validation by IP address** (`Tls_ValidaServidorPorIp_Aceita`). An IP address lives in
     a SAN of type `iPAddress` and requires `X509_VERIFY_PARAM_set1_ip_asc`; on 3.x
     `SSL_set1_host` accepts an IP literal and masks the difference. That test **passes on
     3.x with or without the fix** — only the 1.1 image makes it a real guard. History in
     [`docs/ARCHITECTURE.en.md`](docs/ARCHITECTURE.en.md) §13.9.

The integration suite includes shutdown stress (Stop under flood < 2 s), a handle/fd leak
detector under repeated abrupt drops, and RPC correlation under concurrency.

**Android is not part of that suite**: FPC does not compile for Android in this project and
an APK has no console runner, so the Android backend is verified on a device, with the FMX
suite in `tests/Android` (loopback: server and client in the same app). See
`tests/Android/LEIA-ME.md` for each case's numeric limits and the reference run.

### TLS tests

The `TPipeTlsTests` fixture only exists if the build has a TLS backend — on Linux,
therefore, only with `-dPIPES_OPENSSL`. Five of the eight tests are **refusal** tests
(client without a certificate, from another CA, self-signed, silent during the handshake):
that is the half proving that authentication exists, not just that the happy path works.

The credentials come from [`tests/pki/`](tests/pki/README.en.md) — a test PKI versioned in
the repository on purpose, **with no security value**. A secret scanner will flag it; the
flag is right about the fact and wrong about the risk. The alternative of generating it in
`Setup` with `openssl` was discarded because, wherever there was no `openssl`, the TLS
tests would silently vanish — and a security test that vanishes silently is worse than a
missing test. A missing PKI **fails**, it does not skip.

## Structure

```
src/                 library (Pipes.Types, Pipes.Framing,
                     Pipes.Transport[.Windows|.Posix|.Android],
                     Pipes.Base, Pipes.Server, Pipes.Client, Pipes.Threading, pipes.inc)
                     pub/sub: Pipes.Topics (names, wildcards and envelope; pure unit)
                     network: Pipes.Transport.Tcp
                     TLS: Pipes.Transport.Tls (facade) + .Schannel / .OpenSSL (backends)
                     LAN discovery: Pipes.Discovery (UDP broadcast; a complement, not a transport)
                     Pipes.Compression (optional deflate, CompressionMinSize; pfkCompressed kind)
                     Pipes.Json (bytes<->JSON, OPTIONAL - not coupled to the core)
                     Pipes.Commands (command router by name, OPTIONAL, on top of
                     OnMessage - not coupled to the core)
packages/            pipes_faa.lpk (Lazarus package)
samples/             EchoServer, EchoClient, EchoSeguro (TLS + mTLS), ChatVcl, ChatSeguro,
                     PontosECaixas (turn-based game), PingPong (real-time game),
                     PainelLoja (topic pub/sub, three roles in one exe),
                     MonitorTopicos (pub/sub explorer with a VCL/LCL UI),
                     PdvDualScreen (Operador + Cliente),
                     FilaImpressao, DespachoTarefas, ServicoInstavel, RpcConcorrente,
                     GatewaySeguro (ptTls -> ptLocal, server + client in one process),
                     EchoJson (Pipes.Json.pas, optional),
                     EchoCommand (Pipes.Commands.pas, optional),
                     EchoFailover (FailoverAddresses, reuses EchoServer.exe),
                     EchoDiscovery (Pipes.Discovery, same idea, just EchoServer.exe
                     gains "discover" on the command line),
                     TransferenciaArquivos (CompressionMinSize and Stats.*Wire, VCL/LCL UI),
                     EchoAndroid (FMX/Android, Delphi only)
tests/               Unit + Integration (DUnitX and FPCUnit, mirrored)
tests/Android/       DEVICE suite for the Android backend (loopback; no dual-compiler pair)
tests/pki/           versioned TEST PKI, no security value (see its README)
docs/ARQUITETURA.md  full architecture (wire format, thread lifecycle, rationale)
                     English version: docs/ARCHITECTURE.en.md
Pipes.groupproj      Delphi project group       Pipes.lpg  Lazarus group
```

## License

[MIT](LICENSE) — © 2026 Fabiano Arndt
