# Architecture — pascal-pipes-faa (historical rationale)

> 🇧🇷 Este documento também está disponível em [português](ARQUITETURA.md) — a versão em
> português é a canônica; em caso de divergência, ela prevalece.

Report of the architectural proposal approved on 2026-07-16, kept as a record of the
design rationale (why UDS and not FIFO, why a custom framing, why Schannel validates the
chain manually, etc.). It used to be called "Named Pipes (v1)" because the Named Pipe was
the only planned transport; the project and the repository were renamed to
`pascal-pipes-faa` when `ptTcp`/`ptTls` (§2.5, §7) stopped being a hypothesis and became
code (see `../README.en.md`, section "Compatibility with the previous API").

The operational summary (constraints and threading invariants) lives in `../CLAUDE.md`.
The **current state of the public API** (what exists today, with examples) lives in
`../README.en.md` — this document is the "why", not the "what exists today"; when the two
diverge on an API detail, the README is the source of truth.

## 1. Goal and scope

High-level local IPC library for Delphi 12+ (Win64) and FPC 3.2.2/Lazarus
(Linux x86_64/ARM64), with a single codebase. The end developer works only with
`TPipeServer`/`TPipeClient`, `of object` events and `TBytes`/UTF-8 strings —
no OS call exposed.

Concurrency model derived from the `pascal-amqp-faa` project (proven in production):
a dedicated read thread that never runs user code + the library's own thread pool for
callback dispatch + draining of in-flight callbacks before releasing objects.

## 2. Architectural decisions and rationale

### 2.1 Linux: Unix Domain Sockets, not FIFOs

Windows Named Pipes have **connection** semantics: N simultaneous clients, each with its
own bidirectional channel, with disconnection notification. FIFOs (`mkfifo`) have none of
that: they are a single byte stream, unidirectional in practice, with no notion of
"client" and no drop detection. Emulating connections over FIFOs would require a handshake
protocol (a control FIFO + a FIFO pair per client), heartbeats to detect client death and
cleanup of orphaned FIFOs — high complexity for zero benefit in the target use case.

The real semantic equivalent is the **Unix Domain Socket** (`AF_UNIX`, `SOCK_STREAM`) —
what Docker, PostgreSQL and systemd use as a "named pipe" on Linux. With UDS, `Broadcast`,
`Request-Reply` and `OnClientConnected/Disconnected` work identically on both OSes.

FIFOs are out of scope for v1. The `Pipes.Transport.pas` layer is abstract precisely so
that a `TPipeTransportFifo` (e.g., to interoperate with shell scripts) can be added later
without touching the public API.

### 2.2 Custom framing, uniform on both OSes

UDS is a byte stream; a Named Pipe in message mode (`PIPE_READMODE_MESSAGE`) preserves
boundaries, but only on Windows, with quirks (`ERROR_MORE_DATA`, buffer limits). To get ONE
message semantics on both OSes, the Windows pipe runs in **byte mode** and the library
implements its own length-prefix framing (§4). Bonus: messages larger than the pipe buffer
work naturally, and the `MaxMessageSize` validation protects against corrupted/malicious
frames.

### 2.3 Threading: renamed copy of AMQP.Threading.pas

`AMQP.Threading.pas` provides exactly what we need, already dual-compiler:

- **Portable atomics** (`InterLocked*` on FPC / `Atomic*` on Delphi), including 64-bit
  (raw 64-bit loads can be "torn" on 32-bit targets).
- **TAMQPMonitor**: lock + condition variable with a "per-generation event" (no lost
  wakeups) — replaces `System.TMonitor`, nonexistent in FPC.
- **TAMQPThreadPool**: pool with persistent workers, on-demand growth up to `MaxWorkers`,
  work items as objects (`TAMQPWorkItem.Execute`) with ownership transferred to the pool —
  replaces `TTask.Run`, nonexistent in FPC. An exception in a user callback is swallowed by
  the worker (same contract as TTask).

Decision: **copy the unit** to `src/Pipes.Threading.pas`, renaming the prefixes
(`TPipeThreadPool`, `TPipeMonitor`, `TPipeWorkItem`, `PipeAtomic*`, `PipePool`). Zero
coupling between repositories; each lib is distributable standalone. Extracting a shared
lib remains a future refactor if a third project ever needs it.

### 2.4 Dual-compiler compatibility

- `src/pipes.inc` (template: `amqp.inc`): on FPC enables `{$MODE DELPHI}{$H+}`; defines
  `PIPES_WINDOWS` (MSWINDOWS or WINDOWS) and `PIPES_POSIX`.
- Prohibitions: `reference to`, `System.Threading`, `System.TMonitor`, extended RTTI,
  inline vars — nothing outside the subset FPC 3.2.2 compiles in Delphi mode.
- Work items carry data in fields and decrement `FInFlight` in the `finally` of `Execute`
  (the `TAMQPDeliveryWork` pattern from `AMQP.Connection.pas`).

## 3. Public API (skeleton)

> Illustrative skeleton of the design rationale — for the exact signatures and all the
> properties (`Transport`, `TlsOptions`, `KeepAliveSeconds`, mTLS peer identity, etc.),
> see `../README.en.md`, section "API (summary)".

```pascal
type
  TPipeConnectionId = UInt64;  // 0 = invalid; server generates atomic sequential ids

  TPipeTransportKind = (ptLocal, ptTcp, ptTls);  // §2.5/§7 — Named Pipe/UDS, TCP, TCP+TLS

  TPipeMessageEvent    = procedure(Sender: TObject; AConnId: TPipeConnectionId;
                                   const AData: TBytes) of object;
  TPipeRequestEvent    = procedure(Sender: TObject; AConnId: TPipeConnectionId;
                                   const ARequest: TBytes; out AReply: TBytes) of object;
  TPipeConnectionEvent = procedure(Sender: TObject; AConnId: TPipeConnectionId) of object;
  TPipeErrorEvent      = procedure(Sender: TObject; AConnId: TPipeConnectionId;
                                   const AError: string) of object;

  // Where user events run:
  //  pdmPool       — thread pool (default; parallelism across connections)
  //  pdmSerialized — dedicated 1-worker pool (global FIFO order guaranteed)
  //  pdmMainThread — TThread.Queue to the main thread (VCL/LCL without manual Synchronize)
  TPipeDispatchMode = (pdmPool, pdmSerialized, pdmMainThread);

  EPipeError    = class(Exception);
  EPipeTimeout  = class(EPipeError);
  EPipeClosed   = class(EPipeError);
  EPipeProtocol = class(EPipeError);  // corrupted frame, invalid magic, oversize
  EPipeTls      = class(EPipeError);  // handshake/certificate validation failure

  TPipeBase = class abstract
  public
    property Address: string;          // 'my_app' → Win: \\.\pipe\my_app
                                        //            Linux: /tmp/my_app.pipe (configurable)
                                        //            ptTcp/ptTls: 'host:port'
    property Transport: TPipeTransportKind;  // ptLocal (default), ptTcp, ptTls — §2.5
    property TlsOptions: TPipeTlsConfig;     // ignored outside ptTls; see §7 (T0-T5)
    property KeepAliveSeconds: Cardinal;     // ptTcp/ptTls only; 0 = off
    property Active: Boolean;           // read-only
    property DispatchMode: TPipeDispatchMode;
    property MaxMessageSize: Cardinal;  // default 16 MB; bigger frame = protocol error
    property OnMessage: TPipeMessageEvent;
    property OnError: TPipeErrorEvent;
  end;

  TPipeServer = class(TPipeBase)
  public
    procedure Listen;                   // non-blocking: starts the acceptor thread
    procedure Stop;                     // synchronous and idempotent: joins all threads
    procedure SendBytes(AConnId: TPipeConnectionId; const AData: TBytes);
    procedure SendText (AConnId: TPipeConnectionId; const AText: string);   // UTF-8
    procedure Broadcast(const AData: TBytes);
    procedure BroadcastText(const AText: string);
    procedure DisconnectClient(AConnId: TPipeConnectionId);
    function  ClientCount: Integer;      // only ESTABLISHED connections (post TLS handshake)
    function  ClientIds: TArray<TPipeConnectionId>;
    function  TryClientIdentity(AConnId: TPipeConnectionId;
                out AIdentity: TPipePeerIdentity): Boolean;  // mTLS certificate identity
    property  MaxClients: Integer;      // 0 = unlimited; counts from the accepted handshake
    property  OnClientConnected: TPipeConnectionEvent;
    property  OnClientDisconnected: TPipeConnectionEvent;
    property  OnRequest: TPipeRequestEvent;  // handler's return becomes a reply frame
  end;

  TPipeClient = class(TPipeBase)
  public
    procedure Connect(ATimeoutMs: Cardinal = 5000);
    procedure Disconnect;               // synchronous and idempotent
    procedure SendBytes(const AData: TBytes);   // fire-and-forget
    procedure SendText (const AText: string);
    // Synchronous Request-Reply: blocks the CALLER (never the read thread)
    function  Request    (const AData: TBytes; ATimeoutMs: Cardinal = 30000): TBytes;
    function  RequestText(const AText: string; ATimeoutMs: Cardinal = 30000): string;
    property  Connected: Boolean;
    property  AutoReconnect: Boolean;
    property  ReconnectDelayMs: Cardinal;
    property  MaxReconnectAttempts: Integer;  // 0 = unlimited; resets on each accepted connection
    property  OnConnected: TPipeConnectionEvent;
    property  OnDisconnected: TPipeConnectionEvent;
  end;
```

`Broadcast` takes a snapshot of the connection list under the list lock and sends OUTSIDE
the lock (each connection's individual write lock) — a slow client does not stall the
list.

## 4. Wire format

```
Header (20 bytes, little-endian):
  Magic    : 4 bytes  'NPF1'   (sync + protocol version)
  Kind     : 1 byte   0=msg  1=request  2=reply  3=ping (reserved)
                      4=subscribe  5=unsubscribe  6=publish   (pub/sub, §9)
  Flags    : 1 byte   bit 0 = error reply; bit 1 = publication to retain
  Reserved : 2 bytes  (0)
  CorrId   : 8 bytes  correlation id (request/reply; 0 in msg)
  Length   : 4 bytes  payload size (validated against MaxMessageSize)
Payload    : Length bytes (raw TBytes; text = UTF-8)
```

In kinds 4-6 the payload starts with the topic envelope: `u16 TopicLen` + UTF-8 topic +
body. The topic does **not** occupy the 2 `Reserved` bytes, which would be cheaper,
because then `Length` would stop covering the rest of the frame: a peer of an earlier
version would read the wrong number of bytes and start reporting "invalid magic" on
perfectly good frames. With the topic inside the payload, that peer fails on the unknown
kind itself, with the stream still in sync — which is what allowed adding pub/sub without
changing the magic.

**Request-Reply** (same pattern as the `AMQP.Connection` RPC):

```
Client                                     Server
Request():                                 reader: reads request frame
  corrId := PipeAtomicInc(FCorrSeq)          dispatches TPipeRequestWork to the pool
  registers slot {corrId → TEvent}         worker: calls OnRequest(..., out Reply)
  sends frame(request, corrId)               sends frame(reply, corrId) [write lock,
  slot.Event.WaitFor(timeout)                 connection refcount guard]
reader: reads frame(reply, corrId)
  fills slot.Bytes; SetEvent  ──────────►  Request() returns the bytes
timeout → removes slot, EPipeTimeout       (late reply for a removed slot is discarded)
```

## 5. Thread lifecycle

```
SERVER                                     CLIENT
┌─ Acceptor thread ───────────────┐        ┌─ Reader thread ─────────────┐
│ accepts connection              │        │ reads frame → decodes →     │
│ registers TPipeServerConnection │        │ dispatches work item        │
│ starts the connection's Reader  │        └─────────────────────────────┘
└─────────────────────────────────┘        ┌─ Reconnect thread (ephemeral,│
┌─ Reader thread (1 per conn) ────┐        │  FreeOnTerminate) ──────────┘
│ reads frame → decodes →         │
│ dispatches work item            │        ┌─ TPipeThreadPool ───────────┐
└─────────────────────────────────┘        │ runs the user's OnMessage/  │
                                           │ OnRequest/OnConnected...    │
                                           └─────────────────────────────┘
```

Rules:
1. The reader never runs user code and never writes except via the write lock.
2. One write lock (`TCriticalSection`) per connection serializes all writes (worker reply,
   SendBytes from any thread, Broadcast).
3. Lock order "outside-in": connection list lock → connection write lock. Never acquire
   the list lock while holding a write lock.
4. `FInFlight` (atomic) counts in-flight callbacks per connection; `DrainInFlight`
   (a `Sleep(10)` loop until zero) runs before releasing the connection — prevents
   use-after-free. Documented consequence: do not call `Stop`/`Disconnect` from inside a
   callback of the same connection (self-wait).

### 5.1 Interrupting the blocking read — Windows

All handles use `FILE_FLAG_OVERLAPPED`; no synchronous blocking call.

- **Read**: overlapped `ReadFile` → `WaitForMultipleObjects([hIoEvent, hStopEvent])`.
  If `hStopEvent`: `CancelIoEx(hPipe)` → `GetOverlappedResult` (harvests the cancellation,
  mandatory before releasing the OVERLAPPED) → exits the loop.
- **Accept**: overlapped `ConnectNamedPipe` with the same technique. The acceptor creates
  the next instance (`CreateNamedPipe` with `PIPE_UNLIMITED_INSTANCES`, `PIPE_TYPE_BYTE`)
  on each accepted client; on `Stop`, the pending instance is closed.
- **Per-connection Stop sequence**: `SetEvent(hStop)` → `CancelIoEx` → `CloseHandle` →
  `Thread.WaitFor` → `FreeAndNil`.
- Client disconnection detected via `ERROR_BROKEN_PIPE`/`ERROR_PIPE_NOT_CONNECTED` on
  read → fires `OnClientDisconnected` via the pool.

### 5.2 Interrupting the blocking read — Linux

- **Stop fd**: a self-pipe (`fppipe`) per server/client object. (eventfd is a future
  optimization; the self-pipe is identical on x86_64 and ARM64 and needs no extra
  binding.)
- **Read**: `fpPoll([fdConn, fdStop])`; woke up on `fdStop` → exit. `POLLHUP`/read 0 =
  peer disconnection.
- **Accept**: `fpPoll([fdListen, fdStop])` + `fpAccept`.
- **Stop sequence**: write 1 byte to the self-pipe → `fpShutdown(fd, SHUT_RDWR)` (wakes a
  residual read) → `fpClose` → `Thread.WaitFor`.
- **SIGPIPE**: all writes use `MSG_NOSIGNAL` (via `fpSend`) — a dead client cannot take
  the server down.
- **Socket path**: `fpUnlink` before `fpBind` (removes an orphaned socket from a previous
  crash) and on `Stop`.

### 5.3 Interrupting the blocking read — TCP and TLS

- **POSIX**: a TCP socket is the same object as a UDS at the fd level — it fully reuses
  §5.2's `fpPoll([fd, fdStop])` + self-pipe, with no extra code.
- **Windows**: there is no overlapped Named Pipe for a socket; `Pipes.Transport.Tcp.pas`
  implements the Winsock analog of the `[operation event, stop event]` pattern:
  `WSAEventSelect` associates the socket with a `WSAEVENT` and every wait is a
  `WSAWaitForMultipleEvents` on that pair. The socket is non-blocking; each operation
  tries `recv`/`send` first and only waits on the event on `WSAEWOULDBLOCK` (avoiding a
  dependency on the edge semantics of `FD_READ`/`FD_WRITE`, which only re-signal on
  transition).
- **`ptTls`**: `Pipes.Transport.Tls.pas` is the neutral facade — it does not implement
  TLS, it only wraps the TCP endpoint in a `TStream` and delegates to a backend chosen by
  compiler directive: `Pipes.Transport.Schannel.pas` (SSPI, Windows) or
  `Pipes.Transport.OpenSSL.pas` (libssl/libcrypto, POSIX and Windows opt-in). A read stuck
  in TLS is, in practice, stuck in the underlying TCP endpoint's `Read`; aborting that one
  propagates `EPipeClosed` through the decryption stack — there is no state of its own to
  disarm in the TLS adapter.
- **TLS server handshake outside the accept loop**: the listener returns the
  not-yet-negotiated endpoint; the handshake is invoked by the connection's own reader
  thread, not by the accept loop — a slow client stuck mid-handshake does not prevent the
  server from accepting the others. `HandshakeTimeoutMs` bounds that handshake (0 = the
  lib's default; see `PIPE_TLS_HANDSHAKE_NO_TIMEOUT` to turn it off).
- **mTLS**: server implemented in both backends — OpenSSL (`SSL_VERIFY_PEER` +
  `FAIL_IF_NO_PEER_CERT`) refuses the connection inside the handshake; Schannel completes
  the handshake and only afterward validates the chain manually (§7, note on
  `VerifyClientChain`), so the refusal happens one step later — an observable behavior
  difference the application must not assume identical across platforms (detailed in
  `../README.en.md`, mTLS section).

### 5.4 Shutting down without freezing the UI

- `Stop`/`Disconnect`/destructor: signal everyone → join everyone → `DrainInFlight` →
  release. Never `TerminateThread`/`KillThread`. The idempotent destructor calls Stop.
- `pdmMainThread` uses `TThread.Queue` (asynchronous). **Never** `Synchronize` from the
  reader: main thread waiting on `Stop` + reader waiting on `Synchronize` = deadlock.
- Since a pending `Queue` may fire after the component is destroyed, `pdmMainThread`
  callbacks go through a refcounted guard object the destructor invalidates; the queued
  item checks the guard before invoking the user's event.

## 6. Unit structure

| Unit | Content |
|------|---------|
| `src/pipes.inc` | dual directives (template `amqp.inc`) |
| `src/Pipes.Threading.pas` | renamed copy of `AMQP.Threading.pas` |
| `src/Pipes.Types.pas` | `TPipeConnectionId`, events, exceptions, `TPipeDispatchMode`, `TPipeTransportKind`, `TPipePeerIdentity`, keepalive constants |
| `src/Pipes.Framing.pas` | frame encode/decode, UTF-8 helpers |
| `src/Pipes.Topics.pas` | pub/sub: name/filter validation, hierarchical matching, topic envelope. **Pure unit** (no state, no locks, no IO) — §9 |
| `src/Pipes.Transport.pas` | abstract `TPipeEndpoint`/`TPipeListener` (interruptible Read/Write/Accept + CloseAbort) |
| `src/Pipes.Transport.Windows.pas` | overlapped Named Pipe (`{$IFDEF PIPES_WINDOWS}`) |
| `src/Pipes.Transport.Posix.pas` | UDS + fpPoll + self-pipe (`{$IFDEF PIPES_POSIX}`) |
| `src/Pipes.Transport.Tcp.pas` | TCP socket on both OSes (`ptTcp`), keepalive (§5.3) |
| `src/Pipes.Transport.Tls.pas` | neutral `ptTls` facade: wraps a TCP endpoint in a TLS session, picks the backend by directive (§5.3) |
| `src/Pipes.Transport.Schannel.pas` | TLS backend via SSPI (`{$IFDEF PIPES_SCHANNEL}`), client and server, manual chain validation (§7) |
| `src/Pipes.Transport.OpenSSL.pas` | TLS backend via OpenSSL (`{$IFDEF PIPES_OPENSSL}`), client and server, mTLS |
| `src/Pipes.Base.pas` | `TPipeBase` (Address/Transport/TlsOptions/KeepAliveSeconds/DispatchMode), `TPipeTlsConfig`, `TPipeGuard` |
| `src/Pipes.Server.pas` | `TPipeServer` + acceptor + connections + mTLS peer identity |
| `src/Pipes.Client.pas` | `TPipeClient` + reconnection + `MaxReconnectAttempts` |
| `tests/Unit/` (`Pipes.ThreadingTests`, `Pipes.FramingTests`, `Pipes.TopicsTests`, `Pipes.AddressTests`) | unit tests; DUnit (Delphi) + fpcunit (FPC, under `fpc/`), layout mirrored from pascal-amqp-faa |
| `tests/Integration/` (`Pipes.TransportTests`, `Pipes.EndToEndTests`, `Pipes.PubSubTests`, `Pipes.StressTests`, `Pipes.TlsTests`) | dual-OS integration, includes mTLS; same DUnit/fpcunit mirroring |
| `tests/pki/` | versioned **test** PKI (no security value; see its README) |
| `samples/` | samples (echo, chat, POS, print queue, concurrent RPC, pub/sub, etc.) — see `../README.en.md`, samples section |

## 7. Milestones

All the milestones below (M0-M8 and T0-T5) are **done**; the table remains as a historical
record of sequencing and agent allocation, not as an open plan.

| # | Milestone | Content | Recommended agent | Status |
|---|-----------|---------|-------------------|--------|
| M0 | Bootstrap | git init, folders, `pipes.inc`, `.gitignore`, empty test projects compiling | haiku | done |
| M1 | Threading | copy/rename of `AMQP.Threading.pas` + smoke tests (pool, monitor, atomics) | haiku + sonnet review | done |
| M2 | Framing | `Pipes.Types` + `Pipes.Framing` + unit tests (roundtrip, invalid magic, oversize, UTF-8) | sonnet | done |
| M3 | Windows transport | abstract `Pipes.Transport` + full overlapped implementation | opus | done |
| M4 | Linux transport | UDS, fpPoll, self-pipe, MSG_NOSIGNAL, unlink | opus | done |
| M5 | High level | Server/Client, acceptor, readers, dispatch, DrainInFlight, Stop/Disconnect | opus + fable review | done |
| M6 | Advanced | Request-Reply, Broadcast, AutoReconnect, pdmMainThread + guard | sonnet + opus review | done |
| M7 | Integration | echo, N concurrent clients, abrupt drop, Stop stress under traffic — both OSes | sonnet | done |
| M8 | Samples/docs | console echo + VCL/LCL chat + README | haiku | done |

### Later milestones (outside the original plan)

`ptTcp` and `ptTls` came after M8, when the use case of store POS terminals talking to the
back office over VPN appeared — a scenario where "local IPC" is no longer enough and two
problems the original design did not have show up: idle connections dying silently
(keepalive) and an exposed listener without OS access control (TLS/mTLS).

| # | Milestone | Content | Status |
|---|-----------|---------|--------|
| T0 | TLS base | `TPipeEndpoint`⇄`TStream` adapter, TLS client | done |
| T1 | Handshake outside accept | negotiation on the connection's reader thread, not in the accept loop | done |
| T2 | Schannel server | `AcceptSecurityContext`, INBOUND credential, PFX | done |
| T3 | OpenSSL server | POSIX equivalent | done |
| T4 | mTLS | OpenSSL (`SSL_VERIFY_PEER` + `FAIL_IF_NO_PEER_CERT`) and Schannel (manual chain validation) | done |
| T5 | `ptTls` in the public API | enum, `TlsOptions`, handshake timeout, suite and docs | done |

**Why Schannel's chain validation is manual.** `hRootStore` + `ASC_REQ_MUTUAL_AUTH` do
**not** validate the client's chain: Schannel merely *requires* it to present a
certificate and hands that certificate to the application — deciding whether the chain is
trustworthy is the application's job. An earlier version of this code assumed the opposite
and accepted a certificate from an unknown CA. `TPipeSchannelServerStream.VerifyClientChain`
does the work in four steps, the decisive one being comparing the **root** of the built
chain, byte for byte, against the configured CA: a client can assemble an intact chain
with its own self-signed CA, in which case the only defect is "unknown root" — which is
exactly the defect every private PKI has and that the server must tolerate for the
legitimate client to work.

The test case guarding this is the **self-signed** certificate, not the other-CA one: the
latter is rejected earlier, for an incomplete chain.

Dependencies: `M0 → M1 → M2 → (M3 ‖ M4) → M5 → M6 → M7 → M8`. Development starts on
Windows (current machine); M4 and the Linux half of M7 validate via FPC in CI or on a
target machine.

**Cross-cutting acceptance criteria**: each milestone closes compiling on dcc64 AND fpc,
with green tests on both. M7 requires: `Stop` under heavy traffic finishes in < 2 s
(deadlock detector) and an abrupt client drop (kill -9) fires `OnClientDisconnected`
without leaking a handle/fd.

## 8. Reference patterns in pascal-amqp-faa

| Pattern | Where |
|---------|-------|
| Dual-compiler include | `src/amqp.inc` |
| Atomics/monitor/pool | `src/AMQP.Threading.pas` |
| Lock-invariants header | `src/AMQP.Connection.pas:5-32` |
| Reader that never runs user code | `TAMQPReaderThread.Execute` |
| Reader stop (Terminate + close transport + WaitFor) | `TAMQPConnection.StopReadThread` |
| In-flight callback draining | `TAMQPChannel.DrainInFlight` |
| Work item with data in fields + dec in finally | `TAMQPDeliveryWork` |
| Ephemeral reconnect thread | `TAMQPReconnectThread` |
| Dedicated 1-worker pool (FIFO order) | `TAMQPChannel.FDispatchPool` |

## 9. Topic pub/sub (milestones P0-P4)

It came after T5, when it became clear that between `SendBytes(ConnId, ...)` and
`Broadcast` the most common case in a system with several endpoints was missing:
**addressing by subject**, without the sender knowing who is interested. The API is in the
`README.en.md`; here lives the *why*.

### 9.1 What this is NOT

It is not a broker. There is no durability, ack, QoS, redelivery, named queue or
dead-letter — and there must not be: that is `pascal-amqp-faa`'s job, and duplicating it
here would produce a second, worse implementation of the same thing. What exists is
**subject routing over a live connection**. The only concession to state is *retain*,
which is a last-value cache (one per topic), precisely because the alternative — each
client asking for the current state upon connecting — is the ad-hoc handshake everyone
writes wrong.

### 9.2 The golden rule: routing decisions are pure code on the reader thread

Every decision about *who receives what* runs on the read thread, with code that takes no
user locks and does no IO (`Pipes.Topics` is a pure unit on purpose). The user callbacks
(`OnPublish`, `OnSubscribe`, `OnUnsubscribe`) are **notifications** dispatched to the pool
*after* the decision is made.

The alternative design — `OnPublish` with a `var AAllowRelay` for the user to veto — was
rejected, and the reason is about ordering, not style: the handler runs on the pool, so
two publications from the **same** client could be relayed out of order in `pdmPool`. The
transport is ordered and the application has the right to count on that. That is why
`RelayClientPublish` is a Boolean read on the spot. Whoever wants to decide case by case
leaves the relay off and calls `Publish` from inside the handler, owning whatever order
they choose (FIFO guaranteed in `pdmSerialized`).

The same argument applies to subscriptions, with a worse symptom: applying `Subscribe` on
the pool would let an `Unsubscribe` overtake the `Subscribe` it cancels, and the final
state would be wrong — intermittently and irreproducibly. Hence `OnSubscribe` being a
notification; to **deny** a subscription, the server calls `DisconnectClient` (a client
asking for someone else's topic deserves no half-measures).

### 9.3 Subscription on the connection, not in a global table

The filter list is a field of `TPipeServerConnection`, protected by the **already
existing `FConnLock`**, and not by a `topic → connections` table with its own lock. Three
consequences, all good:

1. No new level in the lock order (`FConnLock → write lock` remains everything).
2. The fanout takes the recipients' snapshot in the same pass it already makes over
   `FConnections` — it is `Broadcast` with a match test.
3. **The subscription dies with the connection, in its destructor.** There is no global
   registry to unsubscribe from during teardown, and therefore the class of silent leak a
   global table would have does not exist (the `AssinaturaMorreNaQuedaAbrupta` test guards
   this with a raw endpoint that vanishes without a goodbye).

The cost is O(N connections) per publication instead of O(subscribers). At the library's
real scale (tens to hundreds of connections, allocation-free matching) that is
irrelevant, and trading it for a third lock level would be paying concurrency complexity
to buy microseconds.

### 9.4 Wildcards: why refuse instead of interpret

`#` is only valid as the last segment and `*`/`#` are only valid as whole segments.
`a.#.b` and `caixa*` are **refused**, not reinterpreted: in the first case the two
possible readings of `#` would give different results for the same filter; in the second,
`caixa*` would promise partial matching inside the segment, which this matcher does not do
— and a filter that silently matches nothing is the worst outcome for whoever is
debugging. Comparison is byte-for-byte (case-sensitive): there is no portable *upcase* for
UTF-8, and a locale-dependent match would be worse than a case-sensitive one.

### 9.5 Asynchronous refusal: error reply with corrId 0

`Subscribe` is fire-and-forget (there is no ack to wait for). A subscription refused by
the server — an invalid filter from a hand-rolled peer, or the `MaxSubscriptionsPerClient`
ceiling — would be **pure silence** on the client: it would wait for messages that never
come, without knowing why. So the server returns an error reply with `corrId 0`, which no
`Request` uses (the client's sequence starts at 1), and the client translates it into
`OnError`. The refusal shows up on both sides, and the connection stays up.

### 9.6 Reconnection: the hole that exists and what closes it

Subscriptions are the **client's desired state**, not the session's: they live in `FSubs`
and are resent on each new session, inside `TryReopenSession`, **before** `OnConnected`
fires. Without that, automatic reconnection would hand back a live but mute connection —
the server lost the filter list along with the previous connection (§9.3) and there is no
one to remind it. The symptom (messages that stop arriving after a reconnection the app
never even saw) looks nothing like the cause; the `Resubscribe_AposReconexaoAutomatica`
test guards this.

What is **not** recovered is the window between the drop and the resubscription: a
publication that passed through there is lost. That is a property, not a bug — and it is
the reason *retain* exists.

### 9.7 The retain bit on the wire answers the CONSUMER, not the sender

`PIPE_FLAG_RETAIN` goes out set **only** on subscription catch-up (`SendRetained`); live
fanout always clears it, even when the publisher asked for retention. It reaches the app
as `ARetained` in `OnTopicMessage`, and the question it answers is the consumer's — *did
this just happen, or is it the value that was already in force?* — not the sender's, who
already knows what they asked for.

Propagating the bit onward in the fanout would be the wrong reading and a bug waiting to
happen: the app would treat the sale happening now as catch-up (or the reverse) and count
it twice, or not at all. It is the same rule as MQTT, and for that very reason: an app
that already knows MQTT is not surprised here. The `Retido_AoVivoNaoVemMarcado` test
guards both sides — the live publication *with* retain arrives unmarked, and the value is
stored all the same for the next subscriber.

On the server side, the same parameter in `OnPublish` has the only meaning possible
there: the client **asked** to retain (a request honored only with `RelayClientPublish`
on).

### 9.8 Milestones

| # | Milestone | Content | Status |
|---|-----------|---------|--------|
| P0 | `Pipes.Topics.pas` | names, wildcards, envelope; IO-free unit tests | done |
| P1 | Server | kinds 4-6, per-connection subscription, fanout, retain, ceilings | done |
| P2 | Client | `Subscribe`/`Unsubscribe`/`Publish`, replay on reconnection | done |
| P3 | Integration | fanout, lifecycle, retain, refusals, `Stop` under load | done |
| P4 | Sample + docs | `samples/PainelLoja` (console, three roles in one exe) | done |
| P5 | `ARetained` + GUI sample | retain bit in the API (§9.7) and `samples/MonitorTopicos` (VCL/LCL) | done |
