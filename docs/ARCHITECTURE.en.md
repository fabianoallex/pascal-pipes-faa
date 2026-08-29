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

> The complete, Delphi/FPC-independent spec of this format — meant for anyone implementing
> the other end in another language — is in [`INTEROP.en.md`](INTEROP.en.md): every kind,
> the topic/command envelopes, kind 7 (compression), NPD1 (discovery), hex examples and
> pseudocode. This file remains the *why* behind each decision; `INTEROP.en.md` is the
> *what* for the external implementer.

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
| `src/Pipes.Transport.Posix.pas` | UDS + fpPoll + self-pipe (`{$IFDEF PIPES_POSIX}`, FPC-only) |
| `src/Pipes.Transport.Android.pas` | `ptTcp` over the RTL's `Posix.*` units + local `poll` + self-pipe (`{$IFDEF PIPES_ANDROID}`, Delphi-only); endpoint, listener and factories — §13 |
| `src/Pipes.Transport.Tcp.pas` | TCP socket on both OSes (`ptTcp`), keepalive (§5.3); on Android it is just a facade that delegates (§13.3) |
| `src/Pipes.Transport.Tls.pas` | neutral `ptTls` facade: wraps a TCP endpoint in a TLS session, picks the backend by directive (§5.3) |
| `src/Pipes.Transport.Schannel.pas` | TLS backend via SSPI (`{$IFDEF PIPES_SCHANNEL}`), client and server, manual chain validation (§7) |
| `src/Pipes.Transport.OpenSSL.pas` | TLS backend via OpenSSL (`{$IFDEF PIPES_OPENSSL}`), client and server, mTLS |
| `src/Pipes.Base.pas` | `TPipeBase` (Address/Transport/TlsOptions/KeepAliveSeconds/DispatchMode), `TPipeTlsConfig`, `TPipeGuard` |
| `src/Pipes.Server.pas` | `TPipeServer` + acceptor + connections + mTLS peer identity |
| `src/Pipes.Client.pas` | `TPipeClient` + reconnection + `MaxReconnectAttempts` + address failover (§12) |
| `src/Pipes.Json.pas` | **optional** bytes⇄JSON (`System.JSON`/`fpjson`); not coupled to the core — see `../README.en.md` |
| `tests/Unit/` (`Pipes.ThreadingTests`, `Pipes.FramingTests`, `Pipes.TopicsTests`, `Pipes.AddressTests`) | unit tests; DUnit (Delphi) + fpcunit (FPC, under `fpc/`), layout mirrored from pascal-amqp-faa |
| `tests/Integration/` (`Pipes.TransportTests`, `Pipes.EndToEndTests`, `Pipes.PubSubTests`, `Pipes.StressTests`, `Pipes.TlsTests`, `Pipes.HeartbeatTests`, `Pipes.StatsTests`, `Pipes.JsonTests`, `Pipes.FailoverTests`) | dual-OS integration, includes mTLS; same DUnit/fpcunit mirroring |
| `tests/Android/` | **device** suite for the Android backend (FMX, loopback). No dual-compiler pair: FPC does not compile for Android in this project — §13.8 |
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

## 10. Application heartbeat (`ptTcp`/`ptTls`)

Came after T5, driven by the same use case that brought `ptTcp` (§7, "Later milestones":
a store POS talking to the back office over VPN, where an idle connection dying in
silence was already one of the two problems cited). `KeepAliveSeconds` (§2, `Pipes.Base`)
already detects that silent death, but it is an OS probe — typically takes minutes
(`TCP_KEEPIDLE`/`TCP_KEEPINTVL`/`TCP_KEEPCNT`, not configurable to the second) and only
ever sees the raw TCP socket, never what crosses the encrypted `ptTls` record.
`HeartbeatIntervalMs` solves the same problem on top of the framing layer: an application
frame, with the application in full control of detection time.

### 10.1 Symmetric and uncorrelated: why there is no `pfkPong`

`pfkPing` (kind 3) had been reserved in NPF1 since M2 and never grew a `pfkPong` sibling.
The reason: a heartbeat is not a question waiting for an answer, it is a liveness signal
observed on both sides at once. **Any frame received — the Ping itself included — resets
the read clock of whoever received it.** That removes all the state a correlated
ping/pong would require (nonce, "outstanding ping" table, per-attempt timeout), and it is
the same design AMQP 0-9-1's heartbeat uses (`AMQP.Connection.pas`,
`TAMQPHeartbeatThread`/`HeartbeatTick` in `pascal-amqp-faa`): each side sends a heartbeat
when idle on writes, and each side measures its own read idleness independently.

### 10.2 Killing the connection is just `CloseAbort` — no new interruption mechanism

Detecting death (no frame received, Ping included, for more than **2x the interval**) and
acting on it is a single call: `FEndpoint.CloseAbort`. It is the same "thread-safe and
idempotent" mechanism (`Pipes.Transport.pas`, header comment) that any protocol error
already uses (`Pipes.Server.pas` `ReaderFinished`, for instance) — it unblocks the reader
thread with `EPipeClosed`, which falls into the usual `except` and follows the normal
teardown (`OnClientDisconnected` on the server; `OnDisconnected` + `AutoReconnect` on the
client). There is no new signal/cancellation pair to maintain: the heartbeat *reuses* the
interruption M3-M5 already solved, in full.

### 10.3 `TPipeHeartbeatThread`: a generic thread in `Pipes.Threading`

Server and client needed the same loop (wake every half the interval through a
cancellable wait — never `TTimer` — and call a tick), so the thread lives in
`Pipes.Threading.pas`, parameterized by an `of object` callback
(`TPipeHeartbeatTick = procedure of object`), not a closure (banned in this library).
The owner (`TPipeServerConnection.HeartbeatTick` or `TPipeClient.HeartbeatTick`) decides
what to do on each tick, not the thread — it only wraps the "wake up periodically,
cancellably" pattern already repeated in the thread pool and in the sibling project's
`TAMQPHeartbeatThread`.

### 10.4 Lifecycle: the SAME points that already join the reader

On the server, `StartHeartbeat` runs on the reader thread itself, right after
`OnClientConnected` (the connection just became "established"); `StopHeartbeat` runs at
the same two places that already `WaitFor` the connection's `FReader` (`Stop` and
`RunCleanup`) — never inside `HeartbeatTick` itself, and always before the `Destroy` that
frees `FStream`/`FEndpoint`.

On the client the lifetime is per **session**, not per client instance: `StartHeartbeat`
runs in `Connect` and on every successful `TryReopenSession`; `StopHeartbeat` runs at the
same points that already join the outgoing session's `FReader` (`Disconnect` and the top
of `TryReopenSession`) — **before** `FStream`/`FEndpoint` are swapped or freed. Without
that ordering, a dead session's heartbeat thread could write into the next session's
stream (or, worse, into an already-freed object): the reason for this ordering is the
same reason `FWriteLock` protects the `FStream`/`FEndpoint` pair itself against
concurrent swap (see the header of `Pipes.Client.pas`).

### 10.5 Scope: `ptTcp`/`ptTls` only

`ptLocal` ignores `HeartbeatIntervalMs` on purpose — same rule and same reason as
`KeepAliveSeconds`: the peer process dying already closes the local Named Pipe/UDS right
away (`ERROR_BROKEN_PIPE`/`POLLHUP`, §5.1-5.2), so there is no local "zombie" to detect.
The `PtLocal_IgnoraHeartbeatIntervalMs` test guards this by configuring the interval and
confirming an idle session on both sides survives past the deadline that would kill it
under `ptTcp`.

### 10.6 Milestones

| # | Milestone | Content | Status |
|---|-----------|---------|--------|
| H0 | `Pipes.Framing` + `Pipes.Threading` | `TPipeFrame.Ping` (kind 3, uncorrelated); generic `TPipeHeartbeatThread` | done |
| H1 | `TPipeBase` | `HeartbeatIntervalMs` property (0 = off; `ptTcp`/`ptTls` only) | done |
| H2 | Server | per-connection ticks, `StartHeartbeat`/`StopHeartbeat`/`HeartbeatTick`, `CloseAbort` on timeout | done |
| H3 | Client | per-session heartbeat (Connect + every reconnection), same `FReader` join points | done |
| H4 | Tests | zombie detected both ways, `ptLocal` immune, `Stop`/`Disconnect` <2s with heartbeat active | done |

## 11. Metrics/observability (`Stats`/`ConnectionStats`)

Came right after the heartbeat, from the same diagnosis: the production target (store POS)
needs visibility without verbose logging — "is traffic actually flowing?", "any slow
requests?", "how many real clients?" — without instrumenting the application from outside.
Unlike the heartbeat, this applies to **any transport** (`ptLocal` included: a Named Pipe
benefits from knowing how many bytes went through too).

### 11.1 Snapshot, not event — the same mold as `ClientCount`

The library already settled this design decision before: `ClientCount`, `ClientIds`,
`Subscriptions`, `SubscriberCount`, `TryClientIdentity` are all **on-demand snapshots** — the
app asks when it wants to know, the library never pushes anything periodically.
`Stats`/`ConnectionStats` follow the same mold, instead of an `OnStats` with its own timer and
`DispatchMode`: less new API, zero dispatch mechanism to invent. Whoever wants a periodic
sample uses their own app timer calling `Stats` whenever convenient.

### 11.2 Always on, no opt-in

Unlike the heartbeat (which only exists with `HeartbeatIntervalMs` configured), the
byte/message counters cost one `PipeAtomicAdd64` per frame — nanoseconds, the same order of
magnitude `FInFlight` already pays on every dispatched callback. There is no `EnableStats`
property: the cost is too low to justify one more configuration decision, and a metric that
only sometimes exists is the classic source of "why didn't I see this on the dashboard."

### 11.3 Per-connection dies with it; server aggregate survives

`TPipeConnStats` (per connection, via `ConnectionStats`) dies with the connection — like
`FSubs`, unlike `TPipePeerIdentity` (which survives on purpose to answer "who left?" in
`OnClientDisconnected`, §3). `TPipeServerStats` (via `Stats`) is the opposite: cumulative
since `Listen`, survives connections that already dropped — it's the number for a
health-check or ops dashboard ("how much traffic has this process moved"), not for debugging
ONE specific connection. `TotalConnectionsAccepted` only counts **established** connections,
same criterion as `ClientCount`/`ClientIds`: a connection refused mid-handshake under mTLS
doesn't inflate the number.

### 11.4 `PoolQueueDepth` can lie — and that's documented, not hidden

Under `pdmPool` (the default), `EventPool` resolves to the process's **global** pool
(`Pipes.Threading.PipePool`), shared by every `TPipeServer`/`TPipeClient` in the same
application. `Server.Stats.PoolQueueDepth` reflects EVERYONE's backlog in that case, not just
this server's — it's only exclusive to it under `pdmSerialized` (private 1-worker pool). The
alternative — filtering by owner inside the global pool — would require linking each work
item back to the server that queued it, real complexity for a number that's already cheap the
simple way. The choice was to document the caveat in the property's XMLDoc rather than solve
the wrong problem.

### 11.5 Request latency: only the success path counts

`TPipeClient.Request` already knows when it started (before writing) and when it finished
(the RPC slot's `WaitFor`). `AvgRequestLatencyMs`/`MaxRequestLatencyMs` are only updated
inside `if LSlot.Ok then` — never on timeout or error reply. The reason: "how long did the
server take to respond" and "the server didn't respond" are different questions, and adding a
30s timeout into the latency average would turn an availability problem into a lying
performance number. `MaxRequestLatencyMs` uses a CAS loop (not a `PipeAtomicAdd64`, which
sums — here the operation is "swap only if greater"), for the same reason that motivated
`PipeAtomicAdd64` to exist: there is no portable `InterlockedMax64` across both compilers.

### 11.6 Client counters are per SESSION, no cross-session cumulative

Same decision as the heartbeat's `FLastReadTick`/`FLastWriteTick`: they zero on `Connect` and
on every successful `TryReopenSession` (`ResetSessionStats`, called unconditionally — unlike
`StartHeartbeat`, it does not depend on `HeartbeatIntervalMs`). Explicit decision by the user
when approving the design: **no** second "since forever" pair of fields alongside the
per-session ones — the client is one connection at a time, and `ReconnectAttempts` already
answers "why did the session change" better than a lifetime byte total would.

### 11.7 Milestones

| # | Milestone | Content | Status |
|---|-----------|---------|--------|
| S0 | `Pipes.Threading` | `PipeAtomicCompareExchange64`/`PipeAtomicAdd64` (CAS loop); `TPipeThreadPool.QueueDepth` | done |
| S1 | `Pipes.Types` | `TPipeConnStats`/`TPipeServerStats`/`TPipeClientStats` | done |
| S2 | Server | per-connection and aggregate counters, `Stats`/`ConnectionStats` (same Try* pattern as `TryClientIdentity`) | done |
| S3 | Client | per-session counters, Request latency (success only), `Stats` | done |
| S4 | Tests | bytes/messages match what was sent, `ConnectionStats` for a nonexistent connection, timeout excluded from latency | done |

## 12. Address failover (`TPipeClient.FailoverAddresses`)

Same diagnosis as the heartbeat and the metrics: the production target is the store POS
terminal over VPN (§7, "Later milestones"), and there the main server going down is a real
failure mode, not a hypothetical one. Until now `AutoReconnect` only knew how to keep
insisting on the SAME `Address`; if the primary stayed down for a while (maintenance, that
particular store's link dropping), the client had no way to reach a secondary without the
app tearing down and recreating `TPipeClient` with a different address — losing pub/sub
subscriptions, session counters and the in-flight `AutoReconnect` itself.

### 12.1 Client-side only — the server has nothing to "fail over" to

`TPipeServer` listens on a single `Address`; failover makes no sense on the side that
accepts connections. The property sits next to `AutoReconnect`/`ReconnectDelayMs`/
`MaxReconnectAttempts`, which were already client-exclusive for the same reason.

### 12.2 `Address` stays the primary; `FailoverAddresses` is additive and empty by default

No existing code changes behaviour: with `FailoverAddresses` empty, `ConnectAnyAddress` is
a single call to `PipeConnect(Address, ...)`, identical to before this feature. Every
address in the list shares the client's `Transport`/`TlsOptions`/`KeepAliveSeconds` — they
are alternative network locations of the SAME service (e.g. main store and DR of the same
back office), not a way to talk to a different server with another protocol or another
credential.

### 12.3 `Connect` splits the budget; `TryReopenSession` advances one address per attempt

The two places that open a connection spend time in different ways, and failover respects
each one's shape instead of forcing them together:

- `Connect(ATimeoutMs)` already meant "retry until the deadline" for ONE address (internal
  `PipeConnect`, see `WinPipeConnect`/`PosixPipeConnect`, retrying until
  `ERROR_FILE_NOT_FOUND` stops happening). With more than one address, `ConnectAnyAddress`
  goes around the whole list with an equal slice of `ATimeoutMs` per address, repeating
  until one connects or the total deadline expires — the same "`while true` with a
  deadline" shape that already existed for a single address, one level up.
- `TryReopenSession` was already a loop spaced by `ReconnectDelayMs` (the single reopen
  funnel, §"Reconnection" in the `Pipes.Client.pas` header); failover only adds "current
  address failed → aim at the next one (with wraparound) on the NEXT attempt", with no
  budget of its own and no change to the spacing between attempts.

### 12.4 A DURABLE session goes back to preferring the primary

`FAddrIndex` is reset by the SAME criterion that already resets `FReconnectAttempts` — a
session that lasted longer than `ReconnectDelayMs` was a real session, and the NEXT failure
(if any) should try the primary again before spreading across the alternates. Without this,
a client that migrated to the secondary would stay "stuck" on it (or worse, blindly advance
to the third address) even after the main one came back up — the test
`Reconexao_SessaoDuravelNoBackup_VoltaAoPrimarioDepois` exists precisely to pin that
difference down against the naive "just advance to the next one".

### 12.5 `MaxReconnectAttempts`/`ReconnectDelayMs` remain per ATTEMPT, not per address

The cap and the spacing did not gain a separate per-address budget: every call to
`PipeConnect` — whether it aims at the primary or an alternate — still counts as ONE
attempt against `MaxReconnectAttempts`, and the interval between attempts is still the same
`ReconnectDelayMs`, regardless of whether the next one aims at the same address or a
different one. Switching addresses "immediately" (without waiting for the spacing) was
considered and dropped: one more piece of state to reason about in a unit whose own header
already calls it tight on invariants, for a marginal gain.

### 12.6 No change to the wire format (NPF1) nor to the server side

Failover is entirely a decision about WHICH ADDRESS TO DIAL, resolved before any frame
travels — `Pipes.Framing`, `Pipes.Server.pas` and the on-the-wire protocol are untouched.
`ActiveAddress` (a snapshot, same mold as `ClientCount`/`Stats`) is the only way for the app
to know which address the current session uses, since `TPipeConnectionEvent`
(`OnConnected`/`OnDisconnected`) did not gain a new parameter — changing that signature
would affect the whole rest of the library for a datum the property already delivers without
breaking anything in use.

### 12.7 Milestones

| # | Milestone | Content | Status |
|---|-----------|---------|--------|
| F0 | `Pipes.Client` | `FailoverAddresses`/`ActiveAddress`, `FAddrIndex`, `AddressAt`/`AddressCount` | done |
| F1 | `Connect` | `ConnectAnyAddress` (goes around the list, budget split from `ATimeoutMs`) | done |
| F2 | `TryReopenSession` | advances one address per failed attempt; resets to the primary on a DURABLE session | done |
| F3 | Tests | primary alive/dead in `Connect`, migration on reconnect, reset to primary after a durable session, `MaxReconnectAttempts` shared across addresses | done |

## 13. Delphi Android (`ptTcp`/`ptTls`)

> **Status: A0-A3 VERIFIED on a real device.** This section began as the rationale of a
> feasibility investigation (a throwaway spike, outside the repo) and became the "why"
> history of the implementation. The `tests/Android/` suite runs **11 ok, 0 failures, 0
> skipped** on a device — numbers in §13.8 —, and the `EchoAndroid` sample closes the real
> use case: phone against a Windows server over the LAN IP, with `ptTls` and mTLS, accepting
> the legitimate client and refusing the one with no certificate. §13.7 records what the implementation changed
> relative to the original proposal; §13.9, the portability bug that verifying `ptTls` on
> the device revealed and that neither of the two desktop compilers would have exposed.

Delphi Android is a **third platform axis**, alongside Delphi/Win64 and FPC/POSIX — not an
extension of either. The doubt that motivated the investigation: the blocking-read
interruption invariant (§5) depends on platform-specific mechanisms (`CancelIoEx` on
Windows, self-pipe+`fpPoll` on Linux); there was no guarantee a viable equivalent existed
on Android without falling back to polling.

### 13.1 Scope: `ptTcp`/`ptTls` only — `ptLocal` is out

Android apps are single-process by default — there is no "two parts of the same app
exchanging local IPC" scenario to justify a Named Pipe/UDS the way there is on
Windows/Linux. Exposing a UDS to another process/app runs into sandboxing (SELinux, scoped
storage). The real mobile use case is a network client talking to the same existing
Windows/Linux server (the same rationale as the store POS over VPN that motivated `ptTcp`,
§7 "Later milestones"), not local IPC.

`ptLocal` does not fall through to any backend on Android: `PipeValidateAddress` refuses
with a message that says what to do ("use `ptTcp` or `ptTls`"). That beats the silent
alternative — someone porting a Windows app and forgetting to change `Transport` would see
an obscure name-resolution error much further down the line.

**The listener does exist, contrary to what this section said while it was a proposal.**
The reasoning that "an Android server makes no sense in the target use case" still holds
for *applications*, but it led to a consequence that only surfaced at implementation time:
without `Accept` there is no **loopback** test (server and client in the same app), and
without loopback, verifying this backend would depend on an external server being up and a
working network — an infrastructure test disguised as a transport test. Since `Accept`
costs ~40 lines on top of the same `poll`+self-pipe the endpoint already uses, the cost of
having it is far lower than the cost of not being able to test. See
`tests/Android/LEIA-ME.md`.

### 13.2 It is not an extension of `PIPES_POSIX`

`PIPES_POSIX` is **FPC-exclusive** code: `Pipes.Transport.Posix.pas` uses `BaseUnix`,
`Sockets`, `UnixType` — units that do not exist in Delphi, on any platform. `pipes.inc`
used to define `PIPES_POSIX` whenever `PIPES_WINDOWS` was not defined, which INCLUDED
Android by accident — with no handling of its own, an Android build would pull in that
FPC-only backend and fail to compile at all.

A0 fixed this by testing `ANDROID` **first**: in the Delphi compiler, Android also defines
`POSIX`, so the order is what separates the two axes. `PIPES_ANDROID` and `PIPES_POSIX` are
mutually exclusive by construction.

### 13.3 Transport backend: the RTL's `Posix.*`, not `System.Net.Socket.TSocket`

Reading the source of `System.Net.Socket.pas` (RAD Studio 12, `...\source\rtl\net\`):
`TSocket` only has `MSWINDOWS`/`POSIX` branches — no third path for Android — meaning
**Android implies `POSIX` in the Delphi compiler's defines**, and `TSocket` really does use
`Posix.SysSocket`/`recv`/`shutdown`/`Posix.Unistd.__close` underneath; it is not a JNI/Java
wrapper. That finding is what unblocked feasibility.

The original proposal was to build the backend **on top of** `TSocket`, to avoid rewriting
bind/connect/accept against `Posix.*`. At implementation time that was inverted, for three
concrete reasons:

1. **The interruption mechanism comes out weaker** (§13.4). `TSocket.Close` closes the fd
   immediately, from another thread, with the reader possibly still inside `recv` — the
   recycled-fd race the rest of the library deliberately avoids by deferring the `close` to
   the destructor (`Pipes.Transport.Posix.pas`, header invariants).
2. **All the `Posix.*` units exist for Android** — checked in `lib\Android64\release`: all
   100 of them, including `Posix.SysSocket` (with `MSG_NOSIGNAL`, `SHUT_RDWR`,
   `SO_KEEPALIVE`, `SO_ERROR`), `Posix.NetDB`, `Posix.Unistd`, `Posix.Fcntl`, `Posix.Errno`,
   `Posix.NetinetTCP`. The premise that "socket support in `Posix.*` on Android is patchy"
   did not hold up. There is no `Posix.Poll`, but `poll()` is declared locally against the
   same `libc` as `Posix.Base` — an idiom the library already used for `getaddrinfo`
   (`Pipes.Transport.Tcp.pas`) and `CancelIoEx` (`Pipes.Transport.Windows.pas`).
3. **One fewer model to maintain.** With `Posix.*` the Android backend is the Linux backend
   with different function names; with `TSocket` it would be a third design.

Two platform traps are recorded in the header of `Pipes.Transport.Android.pas`:

- **bionic's `addrinfo` has `ai_canonname` BEFORE `ai_addr`** — BSD order, unlike glibc.
  The local `TPipeAddrInfo` in `Pipes.Transport.Tcp.pas` follows the glibc layout in the
  non-Windows branch; reusing it on Android would pass a `char*` to `connect()` as if it
  were the `sockaddr`, with no compile error. That is why the Android backend uses
  `Posix.NetDB`'s own `addrinfo` and is self-contained — `Pipes.Transport.Tcp.pas` merely
  delegates.
- **`TSocket.Receive`/`Send` have a typed overload** (`array of Byte; Offset; Count`) that
  shadows the untyped one (`var Buf; Count`) when an array is passed: Delphi prefers the
  typed one and reads the 2nd argument as `Offset`. This is what almost masked the spike's
  test. The library does not use `TSocket`, so it is not exposed; the note is for whoever
  writes a sample/test with it — the fix is to assign the method to a procedural variable
  with an explicit signature before calling.

### 13.4 Blocking-read interruption invariant: self-pipe + `poll`, same as Linux

The spike answered the question that was blocking everything:
`TSocket.Close(ForceClosed=False)` does `shutdown(BOTH)` → drains residual `recv` →
`closesocket`, and on a real Android device (not an emulator) it unblocked a thread stuck in
`Receive` in **~1-2 ms**, returning EOF with no exception. Repeated with the app going
through the background during the wait: same result. That matched the best case of the
acceptance criterion — the **strong** mechanism (wake by event, no polling) is portable.

The implementation went one step beyond what the spike measured. It does not use
`TSocket.Close`; it uses the same design as `Pipes.Transport.Posix.pas`: every
endpoint/listener has its own `pipe()` pair, every wait is a `poll()` on
`[operation fd, read end of the self-pipe]`, and `CloseAbort` writes 1 byte into the
self-pipe (never drained, so future waits also wake immediately) plus `shutdown(SHUT_RDWR)`.
**The fd is only closed in the destructor**, after the join.

The difference matters: with `TSocket.Close`, unblocking depends on closing the fd out from
under a thread that may still be inside `recv` — it works, but it bets against descriptor
recycling. With the self-pipe, `poll` wakes on the *other* fd and `recv` is never called
again; unblocking does not depend on the kernel doing anything to the socket. Same
observable result, without the bet, and with the Android backend being the Linux backend
under different names.

The weak variant (`TSocket.ReceiveTimeout`, which sets `SO_RCVTIMEO`) was also tested in the
spike and works (~205 ms for a 200 ms timeout). It is **not** in use and stands as a plan B
documented FOR ANDROID ONLY, should some future edge case prove otherwise — without touching
the invariant on `PIPES_WINDOWS`/`PIPES_POSIX` (FPC), which remain polling-free. The
`CloseAbort destrava Read em ms` case in `tests/Android/` exists precisely to catch a
regression in that direction: it fails above 250 ms.

### 13.5 TLS: OpenSSL only, and no opt-in

Schannel is Windows-only (native SSPI); Android has only OpenSSL as a TLS backend. The
dynamic loader in `Pipes.Transport.OpenSSL.pas` already had the "Delphi outside Windows"
branch via `SysUtils.LoadLibrary`/`GetProcAddress`, which on POSIX maps to `dlopen`/`dlsym`
— that part was reused as-is.

Three adjustments were needed:

- **`PIPES_OPENSSL` is automatic on Android**, the only platform where it is not opt-in.
  There is no second option to choose, and leaving it opt-in would only yield a "build with
  no TLS backend" at runtime. Loading is lazy, so an app that only uses `ptTcp` pays
  nothing.
- **A single soname pair, with no version suffix** (`libcrypto.so`/`libssl.so`). The Android
  installer only extracts files matching `lib*.so` from the APK — `libssl.so.3` would never
  reach the device, and trying it would be a wasted `dlopen`. Android's own
  `/system/lib*/libcrypto.so` (BoringSSL, incompatible ABI) is not a hazard: since Android 7
  it is outside the public namespace for apps.
- **The system trust store.** `SSL_CTX_set_default_verify_paths` uses the `OPENSSLDIR`
  compiled into the `.so` (something like `/usr/local/ssl`), a directory that does not exist
  on the device — chain validation would fail with a generic "unable to get local issuer
  certificate", as though the certificate were invalid. Android's CAs live in
  `/apex/com.android.conscrypt/cacerts` (14+) or `/system/etc/security/cacerts`, already in
  the hashed-directory format OpenSSL expects as `CApath`. `ApplyDefaultTrustStore` tries
  both, **checking that the directory exists** — a directory `X509_LOOKUP` returns success
  even for a nonexistent path, so without that check the first candidate would always
  "succeed". CAs the user installs through Android's settings do not count: since Android 7
  they live in a separate store.

Packaging `libssl.so`/`libcrypto.so` per ABI (`armeabi-v7a`/`arm64-v8a`) in the app's
Deployment remains the job of whoever builds the APK — see `samples/EchoAndroid/LEIA-ME.md`.

### 13.6 Milestones

| # | Milestone | Content | Status |
|---|-----------|---------|--------|
| A0 | `pipes.inc` | `PIPES_ANDROID` define tested before `POSIX`; automatic `PIPES_OPENSSL` | done, verified on device |
| A1 | `Pipes.Transport.Android.pas` | `ptTcp` backend over `Posix.*` + local `poll`; self-pipe interruption (§13.4); endpoint AND listener; `ptLocal` refused with its own message | done, verified on device |
| A2 | `ptTls` | OpenSSL with no opt-in, Android sonames, system trust store (§13.5) | done, verified on device (§13.9) |
| A3 | Sample + tests | `samples/EchoAndroid` (FMX) and `tests/Android` (device suite, loopback) | done; suite runs 11/11 |

Dependencies: T5 (done) → A0 → A1 → A2 → A3. An axis independent of P0-P5/H0-H4/S0-S4/
F0-F3 (pub/sub, heartbeat, stats, failover) — nothing there changes, and the Android backend
inherits all of it for free through the shared `Pipes.Client`/`Pipes.Server`.

### 13.7 What the implementation changed relative to the proposal

Three decisions in this section were inverted when the code was written. They are recorded
because the original proposal came from a spike, not from an implementation — and a reader
who only knows the previous version of this section would think the code diverged from the
plan by carelessness.

| Item | Proposal (spike) | Implementation | Why |
|------|------------------|----------------|-----|
| Backend | `System.Net.Socket.TSocket` | `Posix.*` units + local `poll()` | §13.3 |
| Interruption | `TSocket.Close(False)` | self-pipe + `poll`, fd closed only in the destructor | §13.4 |
| Listener | out of scope | implemented | §13.1 (enables the loopback test) |

None of this weakens what the spike concluded: the answer to the central question ("is there
a viable equivalent to `CancelIoEx`/`fpPoll` on Android without falling back to polling?")
is still **yes**, and that is what the backend rests on. What changed was which of the two
forms of "yes" made it into the code.

### 13.8 Verification: there is no dual-compiler pair

The other milestones are verified by compiling on both compilers and running the suite on
both. Here that pair does not exist — FPC does not compile for Android in this project, and
an APK has no console runner. On top of that, the Delphi CE on this machine refuses
command-line compilation (including `dccaarm64`), so **the Android build and the device run
are manual, through the IDE**.

What the development machine can guarantee on its own, and did:

- FPC/Win64 and FPC/Linux stay green (unit and integration suites) — A0 touched `pipes.inc`,
  which everything includes, so this is not a formality.
- `Pipes.Transport.Tls.pas` compiles under FPC with `-dPIPES_OPENSSL` (the branch A2
  changed).

What only the device can answer is in `tests/Android/LEIA-ME.md`, with the numeric limits
for each case — in particular the 250 ms on the read unblock, which is the number that
separates "woke on an event" from "woke on a timeout".

**Reference run (real device, 2026-08-01): 11 ok, 0 failures, 0 skipped.**

| Case | Measured | Ceiling |
|------|----------|---------|
| `CloseAbort` unblocks `Read` | **0-2 ms** | 250 ms |
| `Disconnect` on an idle connection | 1 ms | 2000 ms |
| `Stop` on an idle connection | 6 ms | 2000 ms |
| `Stop` under heavy traffic | 3 ms | 2000 ms |

The first is the result that backs §13.4: **single-digit milliseconds** is the signature of
waking on an event. Had the mechanism regressed to `SO_RCVTIMEO`, the number would be on the
order of the configured timeout (the spike measured ~205 ms for a 200 ms timeout) and the
case would fail. The other three confirm that shutdown does not depend on draining anything
— `Stop` under load cuts the flow mid-stream, with a fraction of the 2000 messages seen,
which is the correct behaviour.

The `ptTls` cases closed with the right and **distinct** verdicts: an unknown CA yields
`X509 err 20` (`UNABLE_TO_GET_ISSUER_CERT_LOCALLY`) on the client; a self-signed client
under mTLS is refused by the SERVER, and on the client side that raises nothing — under
TLS 1.3 the client completes its handshake before the server evaluates its certificate, so
the refusal shows up as the message never arriving. It is the same asymmetry already
documented for Schannel in §7.

The remaining cases (`ptLocal` refusal, loopback echo, request/reply, abrupt drop notifying
the server) passed with no number worth recording.

### 13.9 What device verification found: IP-SAN broken on 1.1.1

Closing A2 on the device was not paperwork — it exposed a **real portability bug** in the
OpenSSL backend, one that also affects Linux and Windows with OpenSSL 1.1.1 and that neither
of the two desktop compilers would have revealed.

Connecting over `ptTls` by **IP address** failed with `X509_V_ERR_HOSTNAME_MISMATCH`
(err 62) even with `IP:127.0.0.1` in the certificate's SAN. The cause: `SetupSsl` only
called `SSL_set1_host`, which compares against **DNS** SANs. An IP address lives in a SAN of
type `iPAddress`, and only `X509_VERIFY_PARAM_set1_ip_asc` consults it.

Why nobody had seen it: **on 3.x the distinction does not appear** — `set1_host` accepts an
IP literal. The desktop uses 3.x, and the IP-SAN test passed there; the unit header even
recorded that as "measured, not presumed". Android is the only platform in the project where
the available OpenSSL is 1.1.1, and it is the one that brought the defect to light.

`SetupSsl` now tries the IP first and falls back to hostname. `set1_ip_asc` returns 0 when
the string is not a valid IP, which doubles as the detector and avoids writing an IP parser
— working the same for IPv4 and IPv6. Both new symbols have existed since 1.0.2 with the
same signature in 1.1.1 and 3.x, within the unit's binding rule.

**A lesson about method.** The question the device suite answered was not "does Android
work?" but "what can only Android ask?". A new platform axis is worth less for what it adds
than for what it **disproves** — here, an assumption about the OpenSSL API that two
compilers and two green suites had been confirming by accident.

The regression guard now lives on the desktop, but it took a second finding to get there:
running the suite on `debian:bullseye` (1.1.1) with the fix reverted still passed 96/96. The
TLS harness turns `SkipServerVerification` on for nearly every case, and the only case with
verification active asserts **refusal**. There was no case requiring **success** with a
correct `CaFile` — so validation that started refusing *everything* would stay green.
`Tls_ValidaServidorPorIp_Aceita` and `Tls_ValidaServidorPorNome_Aceita` cover both branches
of the fix; the IP one only bites under 1.1.1, which makes the bullseye run part of its
contract rather than an extra.

### 13.10 Negative TLS tests: four ways to pass without proving anything

The device suite was written from scratch and reintroduced, in four variants, the trap §7
already recorded for the desktop TLS tests: a negative case that asserts only "an exception
happened" is satisfied by ANY failure, including the ones that mean the test never ran. Each
one surfaced only because something else broke first and the case stayed green:

| Actual failure | What the case "proved" | Guard |
|---|---|---|
| `libssl.so` missing | certificate refusal | `ExigeVeredictoDeTls` |
| PEM not deployed (`gemea_ca_cert.pem`) | unknown-CA refusal | `ExigePkiArquivos` |
| IP validation broken | server refusing the client | verdict must come from the right side |
| no message arrives | mTLS refused | only valid if the handshake happened |

The pattern that closes all four: **a negative test must assert WHICH refusal happened**,
not that one did. A TLS case that passes because TLS does not exist is worse than a red one
— it lies about coverage, and it disappears from view exactly when the regression is most
serious. The corollary, which cost a full session: wherever there is a negative case, there
must be the matching **positive** one, or a breakage that makes everything refuse stays
green.

## 14. Send/publish batching (`SendBytesBatch`/`PublishBatch`)

Motivation: a burst of N plain messages paid the lock+write-syscall pair N times
(`FWriteLock.Enter/Leave` + `Write` on the stream), even though each individual frame was
already a single `Write` call (`PipeWriteFrame` had emitted header+payload together since
M2). The mechanical gain of batching was never about saving `Write` calls per frame — that
was already one — but about not paying the lock/syscall N times when the app already has N
messages ready at once.

### 14.1 `PipeWriteFrames`: the same guarantee as `PipeWriteFrame`, for a list

`Pipes.Framing.PipeWriteFrames(AStream, AFrames, AMaxPayload)` validates ALL frames before
writing a single byte (the same all-or-nothing rule `PipeWriteFrame` applies per frame), then
concatenates the encoded frames into one buffer and issues ONE `Write` call. Zero wire-format
change: the reader (`PipeReadFrame`) never knew and never needs to know whether the bytes
arrived in a single `recv()`/`ReadFile` or several — an old peer without `SendBytesBatch`
keeps understanding the stream with no change at all.

### 14.2 `TPipePublishItem`: why a record in `Pipes.Topics`, not `Pipes.Framing`

The Topic/Payload/Retain trio mirrors the three arguments of `Publish`/`PipePublishFrame` —
it lives in `Pipes.Topics` (a pure unit, no IO) for the same reason `PipePublishFrame` lives
there: that unit builds the publish frame, not `Pipes.Framing`, which knows nothing about
topics.

### 14.3 `PublishBatch`: topic matching still runs UNDER `FConnLock`, one Write per connection

`TPipeServer.PublishBatch` follows the same mechanics as `FanOut` (§9.3): `MatchesTopic`
matching runs inside `FConnLock`, because that is where each connection's filter list can be
read safely — not afterward. The difference from `FanOut` is that here the per-connection
result is not a single frame's "goes or doesn't go," but a SUBSET of the batch (only the
items whose topic some filter of that connection reaches), assembled still under the lock and
sent with a single `SendFrames` outside it. A connection matching nothing in the batch
triggers no `Write` at all — it isn't an empty batch being sent, the whole connection is
skipped.

An invalid topic in ANY item of the batch refuses the entire batch (`EPipeError`, before
publishing/retaining any item) — the same all-or-nothing rule as `PipeWriteFrames`, so a typo
in the middle of a batch cannot leave retention half-done.

### 14.4 Internal use: retained replay on reconnect got atomicity for free

`SendRetained` (delivering retained values to a fresh subscriber — §9.6) swapped its
`for ... SendFrame ... except Break` loop for a single `SendFrames`. Good side effect:
previously, a client dying MID-REPLAY received an arbitrary PREFIX of the retained values (the
`Break` only stopped the loop, without signaling anything); now the whole replay is one write
unit — either everything arrives, or the exception falls into the same `except` as before and
nothing arrives. That wasn't the reason to build the batch (the motivation was the app's own
burst, §14 above), but it's the kind of correction that only shows up once a sequence of
writes becomes one.

### 14.5 Wire order ≠ callback delivery order

The trap that caught this feature's first test: `SendBytesBatch`/`PublishBatch` guarantee
order ON THE WIRE (the same sequence as the array, one `Write`). The order in which the app
SEES that in `OnMessage`/`OnTopicMessage` depends on `DispatchMode` — under `pdmPool` (the
default), each frame read becomes a work item dispatched to a worker pool, with no order
guarantee between them, exactly as already held for any sequence of plain `SendBytes` calls
before this milestone (which is why `OrdemPreservadaComSerialized`, from M6, already existed
using `pdmSerialized`). The batch neither changes nor loosens that rule; `SendBytesBatch`'s
order tests use `pdmSerialized` for the same reason.

### 14.6 Scope of what did NOT go in

True request-reply pipelining (firing N requests without waiting for each reply before the
next) was considered and dropped this round: `Request` is synchronous per call, and
parallelizing that would need a brand-new async API (`... of object`, no `reference to`) — a
project of its own, not an extension of the plain-message/publish batch.

## 15. Ordering by group under `pdmPool` (`AGroupKey` in `SendBytes`/`SendText`)

Motivation: `pdmPool` (the default `DispatchMode`) dispatches every incoming `OnMessage` to a
worker pool — fast, but with no delivery-order guarantee between distinct messages (only
order ON THE WIRE, which is always preserved, including by `SendBytesBatch`; see §14.5). For
the library's target use case (store PDV, §7 "Later milestones"), that matters when a SUBSET
of messages — the events for ONE specific register — needs to process in the order it was
sent, without that stalling the events of other registers behind it in the queue.

### 15.1 Why this did not become a new `TPipeDispatchMode`

The first idea (`hash(key) mod K` for K fixed workers, in a PRIVATE per-instance pool —
generalizing `pdmSerialized`, which is already exactly this pattern with K=1, see
`Pipes.Base.FDispatchPool`) was dropped for two reasons: it would need a new property just to
tune K, and hash collisions would serialize two UNRELATED groups against each other just for
landing in the same bucket — worse still considering `pdmPool` is already a GLOBAL pool shared
by the whole application (`Pipes.Threading.PipePool`), so groups from DIFFERENT components
could collide by chance.

The design that stuck is simpler to use and more correct: a per-key mailbox with a
cooperative owner (the same pattern actor mailboxes use, e.g. Akka) — each key gets its own
queue, only ONE worker drains it at a time, and parallelism across keys self-regulates
against the pool's own worker cap, with no new property. `AGroupKey` is just one more
parameter on `SendBytes`; there is no new dispatch mode to learn.

### 15.2 `TPipeKeyedDispatcher` (`Pipes.Threading.pas`): additive, does not touch `TPipeThreadPool`

`TPipeThreadPool`/`TPipeWorkItem` (the engine copied/adapted from `pascal-amqp-faa`, see the
unit header) needed NO changes at all. `TPipeKeyedDispatcher` is a layer on top:

- `Enqueue(AKey, AItem)`: under `FLock`, appends `AItem` to `AKey`'s mailbox (creating it if
  absent). If the mailbox JUST got created (nobody was draining it), it fires ONE
  `TPipeMailboxDrainWork` into the pool.
- `TPipeMailboxDrainWork.Execute`: a loop that calls `Fetch(AKey)` — takes the next item from
  the mailbox and executes it, or (mailbox empty) removes the key from the dictionary and
  ends.

Since `TPipeMailboxDrainWork` is just another regular `TPipeWorkItem`, it occupies a pool
worker like any other job — no new API on `TPipeThreadPool`, no dedicated worker.
`TPipeMessageWork` (the item that already existed for plain messages) is reused as-is as the
item that travels inside the mailbox — `DispatchMessage` only decides WHERE to send that same
instance (`EventPool.Queue` directly, or `PipeGroupDispatcher.Enqueue`).

### 15.3 Ephemeral key: born with the first pending message, dies once it drains

A key's dictionary entry is not managed by the caller — it is born on that key's first
`Enqueue` and dies once `Fetch` finds the mailbox empty. Reusing a key after it drains starts
from scratch, with no residual state. That means memory cost is proportional to how many keys
have PENDING work right now, never to the total number of distinct keys ever used — an app
can mint a fresh key per transaction (any id) without accumulating anything once each one
finishes.

**The classic mailbox race** (and the reason `Enqueue`/`Fetch` are the SAME critical section):
a new message could arrive at the exact instant the drainer decides "mailbox empty, I'm done"
and end up orphaned — appended to a queue nobody is watching anymore, since nothing reads
`FMailboxes` at that exact moment except under `FLock`. With `Fetch` (deciding "there's a next
item" OR "remove the key") and `Enqueue` (deciding "append" OR "create and fire") pinned to
the same lock, that window doesn't exist: the two decisions are serialized, one always sees
the other's outcome.

### 15.4 Lifecycle: the dispatcher does NOT own the pool — Destroy order matters

`TPipeKeyedDispatcher.Create(APool)` only references the pool, it does not own it.
`TPipeThreadPool.Destroy` already joins (`WaitFor`) each worker before returning — which, by
transitivity, drains any `TPipeMailboxDrainWork` in flight (its `Execute` only returns once
the WHOLE MAILBOX has drained, not just the current item). That's why the GLOBAL dispatcher's
(`PipeGroupDispatcher`, paired with `PipePool`) finalization order is **always pool first**:

```pascal
finalization
  GPool.Free;             // joins workers; drains any TPipeMailboxDrainWork in flight
  GGroupDispatcher.Free;  // only now can no thread still touch FMailboxes
```

The reverse order would be a use-after-free: a pool thread still running
`TPipeMailboxDrainWork.Execute` (calling `FDispatcher.Fetch`) while the dispatcher has already
been freed. `TPipeKeyedDispatcher.Destroy` cleans up any leftover mailbox as a safety net, but
under the documented lifecycle it already arrives empty (the preceding `GPool.Free` already
drained everything).

### 15.5 Wire: reuses `CorrId`, zero format change

The key travels in the NPF1 header's `CorrId` — a field that already existed in EVERY frame
and that `pfkMessage` never used (always 0, and never reached the app: `TPipeMessageEvent` has
no `CorrId` parameter). `PipeGroupKeyHash` (64-bit FNV-1a, `Pipes.Framing.pas`) reduces the
string to a `UInt64`: `''` always becomes 0 ("no group," the usual behavior, at zero cost);
any other input never lands on 0 (bumped to 1 in the astronomically rare case of a collision).
The hash runs exactly once, on the sender — the receiver uses `AFrame.CorrId` directly as the
key, with no re-hashing. A collision between two DIFFERENT keys is harmless (just a
parallelism hotspot — the two start serializing against each other —, never incorrectness),
the same reasoning behind `PoolQueueDepth` already being shared across components under
`pdmPool`.

No new protocol version, no peer breaks: an old peer that knows nothing about groups already
ignored `CorrId` in `pfkMessage` before this feature, and keeps ignoring it — the field was
there, just inert.

### 15.6 Only under `pdmPool`; `pdmSerialized`/`pdmMainThread` ignore the key

`pdmSerialized` is already 1 worker/TOTAL order (`FDispatchPool`, a private per-instance pool
— see §5); `pdmMainThread` is also already total order (the single `TThread.Queue` queue). In
both, a grouping key would be redundant — `DispatchMessage` simply falls through to the usual
path (`EventPool.Queue`) whenever `FDispatchMode <> pdmPool`, even with `AGroupKey` set. It is
not an error to use the key in those modes, it just changes nothing.

### 15.7 Tests: proof of mutual exclusion, not just timing

The wrong way to test "order preserved" is to only measure time (flaky) or only check the
final list without proving there was NEVER any real overlap. The `TPipeKeyedDispatcher` tests
(`tests/Unit/{,fpc/}Pipes.ThreadingTests.pas`) use a CAS on a flag shared per key (0↔1 on each
item's entry/exit, with a deliberate `Sleep` in between to widen the window) — any overlap
between two messages of the SAME key is caught deterministically and directly, not inferred
from an absence of evidence. The test for parallelism across DIFFERENT keys does use timing
(2 keys × 200 ms each; accidentally-serialized would take ~400 ms, parallel takes ~200 ms),
with a generous margin to avoid flakiness. The end-to-end tests
(`tests/Integration/{,fpc/}Pipes.EndToEndTests.pas`) repeat both proofs through the full wire
path (`SendBytes` → `AFrame.CorrId` → `DispatchMessage`), not just in the pure unit.

## 16. LAN server discovery (`Pipes.Discovery`, NPD1 protocol)

Motivation: to open a TCP connection the client must know the destination FIRST — a
chicken-and-egg problem when the requirement is "plug the POS into the store network and
it finds the server by itself". UDP broadcast is the only way the IP stack offers to ask
without knowing anyone: a `sendto` to `255.255.255.255:<discovery port>` reaches every
host on the subnet, and whoever has an active `TPipeDiscoveryResponder` replies — in
unicast, only to the asker — with the service port, the transport and a name. The result
feeds `TPipeClient.Address`/`FailoverAddresses`, closing the loop with failover (§12) and
mTLS (§7). It is the same pattern as SQL Server Browser (UDP 1434), mDNS and SSDP — here
in a minimal proprietary version.

### 16.1 A complement, not a transport — why UDP is acceptable here and only here

`ptUdp` as a fourth transport was evaluated and rejected: every API promise (delivery,
ordering, `AGroupKey`, stateful pub/sub, heartbeat "dead = no frame for 2x the interval")
assumes a reliable stream, and UDP silently drops/duplicates/reorders — the same call with
the opposite contract. Discovery is the single cut where UDP fits, because the protocol is
idempotent by nature: a lost probe, the next one finds (resend every 300 ms within the
window); a lost reply, the next probe's reply arrives; a duplicated reply, the per-address
dedup drops it. No NPF1 frame travels here and `Pipes.Discovery` does not depend on
`Pipes.Transport` — it is a parallel unit, outside the `TPipeBase` hierarchy.

### 16.2 Broadcast, not multicast; IPv4 only

The desired reach ("the store") is exactly the local subnet, which is broadcast's reach.
Multicast would go further IF the infrastructure cooperated (IGMP — in store networks,
almost never), requires group joins and, on Android, `WifiManager.MulticastLock`; plain
broadcast requires none of that and works on all three platforms, Android included.
Documented consequences: discovery does NOT cross routers or VPNs (a remote POS keeps
using a configured IP + failover), and the socket is `AF_INET` — broadcast does not exist
in IPv6, and the IPv6-only LAN that one day needs this will need multicast, out of scope.

### 16.3 The server's IP comes from the ENVELOPE, not the letter

The client builds `Address` from the SOURCE address of the reply datagram (which
`recvfrom` hands over for free) + the port announced in the payload. There is never an IP
inside the payload: on a multi-NIC server (cable + Wi-Fi + Docker + VPN), the server
itself has no way to know which of its IPs reaches that client — but the source IP the
client sees is, by construction, one that worked. This detail also spares the responder
from enumerating interfaces, which would keep state that goes stale.

### 16.4 Security: discovery FINDS, TLS AUTHENTICATES

Any process on the LAN can answer the probe, impostors included. The defense is not to
make discovery smarter — it is the composition with what already exists: a reply is a
CANDIDATE, never an identity; whoever proves the server's identity is `ptTls` on the
connection that follows (a discovered impostor fails the handshake exactly as a hand-typed
one would). The `Token` is an installation discriminator (two networks/environments on the
same LAN don't see each other), travels in cleartext and is NOT authentication.
Anti-amplification: the responder only answers probes with valid magic and token, the
reply has a small ceiling (~200 bytes) and datagrams that fail to decode die silently.

### 16.5 NPD1 wire: strict lengths, conservative transport byte

```
probe = 'NPD1' + kind(1)=1 + tokenLen(1) + token[UTF-8 <= 64 bytes]
reply = 'NPD1' + kind(1)=2 + tokenLen(1) + token
      + servicePort(2, little-endian) + transport(1, Ord)
      + nameLen(1) + name[UTF-8 <= 128 bytes]
```

A datagram with extra or missing bytes is refused (UDP preserves message boundaries, so
"exact length" is verifiable — unlike NPF1, which runs over a stream and therefore needs
the length prefix). A transport byte outside the known enum = a reply from a newer
version: refuse, don't guess. Port 0 is refused on both ends. A REPLY never decodes as a
probe (distinct kinds) — otherwise two responders on the same port would loop answering
each other.

### 16.6 UDP channel per platform: the usual interruption patterns

`TPipeUdpChannel` (internal to the unit) reuses the idioms already paid for: Windows =
`WSAEventSelect(FD_READ)` + `WSAWaitForMultipleEvents([event, stop])` (§5); POSIX/Android
= `poll([fd, self-pipe])` (§5/§13). No wait uses polling timeouts; the responder's `Stop`
wakes the thread by event and completes in milliseconds. Two UDP accidents handled in the
channel: on Windows, `SIO_UDP_CONNRESET` is turned off (without it, an ICMP "port
unreachable" echoed from an earlier `sendto` makes the NEXT `recvfrom` fail with
`WSAECONNRESET` and would kill the collection — and `TryRecvFrom` still tolerates the
error, belt and suspenders); on POSIX, `ECONNREFUSED` in `recvfrom` is discarded for the
same reason. The responder thread runs NO user code at all (the unit has no callbacks) —
the reply is pre-encoded in the constructor and the loop is read-validate-answer.

### 16.7 Assumed limitations (documented, not solved)

One responder per machine per discovery port — no `SO_REUSEADDR`, for the same reason as
the TCP listener on Windows (see the `Pipes.Transport.Tcp` header): a second `Start` on
the same port is an `EPipeError` with a clear message, and multiple services on the same
machine use distinct discovery ports. The firewall must allow inbound UDP on the port (on
Windows the first `Start` usually triggers the prompt). Wi-Fi AP isolation blocks
client→client. The directed form (`PipeDiscoverServers('192.168.1.10', ...)`) requires an
IPv4 literal — the unit does no name resolution (whoever has a hostname already has a
better address than discovery). A multi-homed client sends through the routing table's
default; enumerating interfaces and sending a directed broadcast per interface remains an
open door.

### 16.8 Tests: directed at 127.0.0.1, broadcast deliberately left out

Real broadcast depends on active interfaces, firewall and topology — not deterministic in
CI. The integration tests use the directed form over loopback, which exercises EVERYTHING
except the literal `255.255.255.255` in `sendto` (same socket, same collection, same
dedup). What each one proves: a window longer than the resend cadence returns ONE entry
(real dedup, with the responder answering 2-3 probes); a wrong token and a port with no
responder return an EMPTY list without error (the latter is the regression test for the
ICMP accident of §16.6); two responders on distinct ports don't leak into each other;
`Start` on a busy port raises immediately; `Stop` completes in < 2s (same ceiling as
M7/H0-H4) and the SAME object can `Start` again with the port released. The pure protocol
(encode/decode, strict lengths, multibyte UTF-8, network-order IPv4) has a full unit-test
pair in both frameworks.

## 17. Payload compression (`CompressionMinSize`, `Pipes.Compression.pas`)

Motivation: large, compressible payloads (verbose JSON, repetitive text) pay bandwidth and
wire time unnecessarily — optional deflate cuts both when it's worth it, with no new
dependency required (§17.2).

### 17.1 `pfkCompressed`: a new KIND, not a `Flags` bit

Using a free bit in `Flags` (offset 5 of the NPF1 header — only bits 0/1 occupied, by
`PIPE_FLAG_ERROR`/`PIPE_FLAG_RETAIN`) was considered, but that would break a guarantee the
rest of NPF1 already gives: today, an out-of-date peer that receives a new capability FAILS
LOUDLY (`EPipeProtocol` "unknown kind... peer speaks a newer version"), never interprets the
wrong bytes — that works because every previous extension (pub/sub kinds 4-6,
`PIPE_FLAG_RETAIN`) piggybacked on a NEW kind. A `Flags` bit on `pfkMessage`/`pfkRequest`/
`pfkReply` (kinds that have existed since M2) would not have that protection: an old peer
would process the frame normally and hand raw deflate to the app, silently corrupting it —
unlike `PIPE_FLAG_RETAIN`, which is only safe because it's only read on `pfkPublish`
(kind 6), itself already new enough to hit "unknown kind" on any peer older than P0.

`pfkCompressed` (kind 7) wraps a whole Message/Request/Reply/Publish frame: `Payload =
[OrigKind:1][OrigFlags:1][Deflate(OrigPayload)]`, `CorrId` = the SAME `CorrId` as the
original frame — request/reply correlation and the `AGroupKey` hash (`Pipes.Threading`)
cross the envelope unchanged. An out-of-date peer hits the SAME `if LKind >
High(TPipeFrameKind)` that already exists in `PipeReadFrame`, the same diagnostic P0-P4
already uses — zero new detection mechanism.

### 17.2 Codec: zero new dependency on either compiler

`Pipes.Compression.pas` delegates to `System.ZLib` (Delphi) and `paszlib`/`zstream` (FPC),
via `{$IFDEF FPC}`. Confirmed on both toolchains on this machine: on FPC, `paszlib`/
`zstream` is a 100% Pascal port of zlib (`zbase`/`zdeflate`/`zinflate`), no `external`,
compiled straight into the binary — zero runtime dependency on either platform (Windows and
Linux). On Delphi, `System.ZLib` is statically linked on Windows (outside the source's
`{$IFDEF POSIX}` block there is no `external` at all); on Android/Linux (POSIX in Delphi's
sense) the unit links against the OS's own `libz.so` — on Android that's part of bionic,
present on every device; on desktop Linux it's as universal as `libc`. Both sides use
zlib's DEFAULT compression level (`zcDefault`/`cldefault` — which zlib itself documents as
equivalent to level 6) and the standard zlib window/header, compatible with each other in
both directions.

### 17.3 `PipeMaybeCompress`/`PipeUndoCompress`: transparent to Stats and `MaxMessageSize`

`PipeMaybeCompress(AFrame, AMinSize)` only produces `pfkCompressed` if `AMinSize > 0`
(`CompressionMinSize`, `0` = off by default), the kind is eligible (`PipeIsCompressible`:
Message/Request/Reply/Publish — Ping has no payload; Subscribe/Unsubscribe/Compressed are
structural), the payload reaches the minimum, AND the resulting deflate is actually smaller
than the original (already-compressed data, e.g. JPEG, goes out raw with no warning).
`Pipes.Server`/`Pipes.Client` always validate `MaxMessageSize` against the ORIGINAL frame,
never `PipeMaybeCompress`'s result — validating the compressed one would let a logical
payload bigger than `MaxMessageSize` through whenever it compressed well, punching a hole in
the ceiling the property documents. `Stats.BytesSent/BytesReceived` follow the same rule
(ORIGINAL payload); the sibling pair `BytesSentWire/BytesReceivedWire` is what measures what
actually crossed the wire — see §17.6. Validation/compression runs OUTSIDE the connection's
write lock (it's pure CPU): a large payload compressing does not block other writers on the
same connection.

On the read side, `PipeUndoCompress` runs right after `PipeReadFrame`, at a single point per
side (`Pipes.Server`/`Pipes.Client`, on the reader thread) — the reconstituted frame goes on
to `Stats`/`HandleFrame` as if it had never been compressed on the wire. The `case
AFrame.Kind of` dispatches by kind (one in each unit) gained an unreachable `pfkCompressed:
;` branch, only so the compiler doesn't complain about an incomplete case — the kind never
reaches that point because the envelope was already undone before.

### 17.4 Zip bomb: the ceiling is checked DURING decompression, not just on the result

`PipeInflate(ASource, AMaxDecompressedSize)` reads in 64 KB blocks
(`TZDecompressionStream`/`TDecompressionStream` over a `TMemoryStream`) and sums the total
as it decodes — a small compressed payload that would "explode" to gigabytes raises
`EPipeProtocol` as soon as the total goes past the limit, without trying to allocate the
whole result first. The ceiling is always the connection's SAME `MaxMessageSize` (no new
property for this), the same reasoning that already protects the NPF1 header's `Length` in
`PipeReadFrame`.

### 17.5 Tests

Unit (`Pipes.CompressionTests`, dual): deflate/inflate round-trip; `PipeMaybeCompress`
off (`AMinSize=0`)/below the minimum/ineligible kind/incompressible payload — in all four
cases returns the original frame untouched; `CorrId` crosses unchanged; a full envelope
round-trip restores Kind/Flags/Payload (including `PIPE_FLAG_ERROR` from `ErrorReply`);
`PipeUndoCompress` on a frame that isn't `pfkCompressed` raises `EArgumentException` (a
caller usage error); a zip bomb (1 MB of zeros compressed, 1000-byte ceiling) raises
`EPipeProtocol`. Integration (`Pipes.EndToEndTests`, dual): a 20000-byte repetitive payload
in both directions (client→server and server→client) arrives intact once decoded, and
`Stats.TotalBytesReceived` matches the text's LOGICAL size, not the compressed one — proof
that §17.3's transparency holds through the real stack, not just in the pure unit.
`Pipes.StatsTests` (dual) covers the §17.6 extension: without `CompressionMinSize`,
`BytesSentWire`/`BytesReceivedWire` are IDENTICAL to the logical fields, on both sides; with
compression on and a compressible payload, `BytesSentWire < BytesSent` on the client and
`BytesReceivedWire < BytesReceived` on the server (per-connection AND in the aggregate
`Stats`), with only the client turning on `CompressionMinSize` — decoding (and therefore
Wire counting) on the server side doesn't depend on it being configured too.

### 17.6 `BytesSentWire`/`BytesReceivedWire`: aggregate visibility without breaking transparency

After closing out C0, it became clear that whoever only RECEIVES had no way at all to know
that compression was saving bandwidth — unlike whoever SENDS, who could at least run
`PipeDeflate` again locally to estimate. The cause is §17.3's own transparency:
`PipeUndoCompress` already returns the logical frame before `HandleFrame`/`OnMessage` runs,
so no application code (not even the server) ever sees the raw `pfkCompressed` envelope.

The option discarded was making compression visible per message (one more parameter on
`OnMessage`, or a new event) — that would leak a transport decision into the application
API, exactly the kind of coupling the `pfkCompressed` kind's design (§17.1) was built to
AVOID. The option adopted was to extend `Stats` (S0-S4, §11), which already operates at
exactly that level — aggregate, cumulative, no per-message hook: `TPipeConnStats`/
`TPipeServerStats`/`TPipeClientStats` gained `BytesSentWire`/`BytesReceivedWire` (and
`TotalBytesSentWire`/`TotalBytesReceivedWire` in the server aggregate) as SIBLING fields to
the existing ones, never replacements — `BytesSent`/`BytesReceived` keep being the LOGICAL
payload, exactly as documented before, and every piece of code that already reads `Stats`
today doesn't change behaviour.

Mechanics: at the same points that already compute `LWire`/`LWireFrames` (write) or capture
the frame before `PipeUndoCompress` (read), plus one `PipeAtomicAdd64` — identical cost to
what S0-S4 already pays per frame, no new lock. For kinds that are never compressed (Ping,
Subscribe/Unsubscribe), the Wire value always equals the logical one by construction (same
call, same number) — important so the `TotalBytesSentWire` arithmetic stays comparable to
`TotalBytesSent` even on a connection with lots of control/heartbeat traffic and little
compressible messaging: if Wire only counted eligible frames, the "how much compression
saved" ratio would come out artificially optimistic.

## 18. Command router by name (`Pipes.Commands.pas`)

Motivation: an app carrying several operations over the same connection (`SAVE_ORDER`,
`CANCEL`, `PING`, ...) ends up with an `if`/`case` chain growing inside a single
`OnMessage`, each branch dispatching to a different function. `TPipeCommandRouter` swaps
that chain for one `RegisterCommand` per command — a name→handler dictionary decorating the
event that already exists.

### 18.1 On top of `OnMessage`, not a new NPF1 kind

Unlike topic pub/sub (§9) and compression (§17), which needed a new kind because the
decision happens BEFORE the app sees the frame — fanout to subscribers, decompression
before `HandleFrame` —, commands are just a way of organizing what the app was already
going to receive in `OnMessage`. There is no routing decision on the reader thread, nothing
another peer needs to understand on the wire: the command name is application content, not
transport protocol. That's why `TPipeCommandRouter.HandleMessage` has the SAME signature as
`TPipeMessageEvent` — `Server.OnMessage := Router.HandleMessage;` directly, no wrapper, no
change to `Pipes.Base`/`Pipes.Server`/`Pipes.Client`. Like `Pipes.Json`, the unit is
OPTIONAL: the core doesn't know about it, only the reverse, and whoever doesn't use commands
pays nothing for it.

### 18.2 Envelope: the same binary layout as `Pipes.Topics`, its own function

`PipeEncodeCommandPayload`/`PipeDecodeCommandPayload` use the SAME layout as
`PipeEncodeTopicPayload`/`PipeDecodeTopicPayload` (§9.3 and the "Envelope" note in
`Pipes.Topics.pas`'s header): a `u16 LE` name length, UTF-8 name, body. The coincidence is
only in shape — a topic (the subject of a publication, routed by the server) and a command
(a requested operation, routed inside the app itself) are different domain concepts, and the
decision was NOT to import the function from `Pipes.Topics` into `Pipes.Commands`: coupling
"commands needs topics" just to reuse a byte layout would be worse than duplicating four
dozen lines — the same "three similar lines beats a premature abstraction" reasoning that
already governs the rest of the lib.

### 18.3 Registration versus message: `raise` on one side, an event on the other

`RegisterCommand` raises `EPipeCommandError` right away — empty name or over
`PIPE_MAX_COMMAND_BYTES`, unassigned handler, invalid `AMinSize`/`AMaxSize`, `AMaxSize <
AMinSize`, or a command already registered. All of these are PROGRAMMING errors (the dev is
assembling the router, typically in the app's `Create`/`Setup`), never network errors — so
they fail early, on the first malformed `RegisterCommand`, not silently on the first frame
that arrives.

`HandleMessage` is the opposite: it NEVER raises. A malformed envelope, a command with no
registered handler, or a payload outside the `MinSize`/`MaxSize` range call
`OnInvalidPayload`/`OnUnknownCommand` — optional events, silent when nobody subscribes, the
same way an `OnMessage` with no subscriber does nothing. The reason isn't stylistic:
`HandleMessage` runs INSIDE the work item that already dispatches `OnMessage`
(`TPipeMessageWork.Execute`, in `Pipes.Base.pas`), and an exception there does NOT reach
`OnError` — `TPipePoolWorker.Execute` (`Pipes.Threading.pas`) swallows any exception from a
user callback so it doesn't take down the worker, exactly as it would with a bug inside the
dev's own `OnMessage`. If `HandleMessage` raised instead of calling an event, discarding an
unknown command or a malformed payload would vanish in total silence — the same problem that
motivated the event instead of the `raise`.

### 18.4 Size validation runs BEFORE the handler

`RegisterCommand(ACommand, AHandler, AMinSize, AMaxSize)` — both ceilings are optional
(`PIPE_COMMAND_NO_LIMIT`, the default, turns off the respective side) and are checked
against the BODY (already without the envelope prefix) before the handler runs. It's
cheap — one `Length` comparison — and saves every handler from starting with the same
"payload too short" first line; whoever wants FORMAT validation (schema, field types) still
does that inside the handler itself, because that's an application decision, not a
transport one — the same boundary that already keeps `Pipes.Json` out of the core.

### 18.5 Command names are case-sensitive

Same reasoning as §9.4/topics: there is no portable UTF-8 upcase, and a locale-dependent
match would be worse than a case-sensitive one. `TDictionary<string, ...>` with the default
comparer already handles this with no extra code — the same mechanism
`Pipes.Server.FRetained` (retained topics) already uses.

### 18.6 Scope of this first round

Deliberately narrow, at the user's request: only registration (with duplicate detection)
and size limits. Left out, not forgotten:

- `UnregisterCommand` — no concrete use case yet asked for removing a command after
  registration.
- A `SendCommand`/`RequestCommand` convenience wrapper on `TPipeClient`/`TPipeServer` — today
  the sender builds the envelope with `PipeEncodeCommandPayload` and calls `SendBytes`/
  `Request` directly; a thin wrapper can land later without breaking anything. **Closed in a
  later round — see §18.9.**

Routing on the `OnRequest`/`TPipeRequestEvent` side (request-reply by command) got its own
round of decisions — see §18.8.

### 18.7 Tests

Unit (`Pipes.CommandsTests`, dual): plain registration, and each of the four ways
`RegisterCommand` raises `EPipeCommandError` (empty name, name too long, nil handler,
inconsistent limits) plus the fifth (duplicate command); dispatch to the right handler with
the payload already stripped of its prefix; an unknown command calling
`OnUnknownCommand` (and not raising when nobody subscribes); a payload below/above the
range calling `OnInvalidPayload` without calling the handler; a payload exactly at the
limits calling the handler; a malformed envelope calling `OnInvalidPayload` with `ACommand =
''`; envelope round-trip, binary layout, empty body, non-ASCII name (size in UTF-8 bytes,
not characters, same case as `Pipes.TopicsTests.Envelope_TopicoNaoAscii`), and both forms of
truncated payload raising `EPipeProtocol`. No dedicated sample this round — the unit is
small enough that usage is clear from the tests themselves and the README example.

### 18.8 Request-reply side routing (`RegisterRequestCommand`/`HandleRequest`)

Motivation: the CMD0 round (§18.1-18.7) deliberately left out routing on the
`OnRequest`/`TPipeRequestEvent` side, because the handler signature changes (it gains
`out AReply: TBytes`) and that deserved its own decision instead of riding along. This
section closes that decision.

**Its own registry, not a union with the message one.** `RegisterRequestCommand` validates
with the SAME private `ValidateRegistration` that `RegisterCommand` already used (empty/too
long name, nil handler, inconsistent limits, duplicate command — factored out in this round
just to avoid duplicating the five checks), but stores into its OWN `TDictionary`
(`FRequestCommands`), independent of the `FCommands` that `HandleMessage` looks up. A
command can share the SAME name across both registries without an `EPipeCommandError` for
duplicates — there is no possible ambiguity, because `OnMessage`/`OnRequest` already arrive
through different NPF1 kinds (`pfkMessage` vs `pfkRequest`) before any lookup in the router.
The `EchoCommand` sample showcases this independence on purpose: `PING` is only registered
on the message side, and asking for `?ping` (a Request) from the client triggers the
request-reply "unknown command" path, not the `OnMessage` handler.

**`HandleRequest` RAISES — a contract deliberately OPPOSITE to `HandleMessage`'s.** An
unknown command or a payload outside the `MinSize`/`MaxSize` range raises `EPipeProtocol`
directly, unlike `HandleMessage`, which calls `OnUnknownCommand`/`OnInvalidPayload` and
never raises. The reason isn't inconsistency: `TPipeServer.ExecuteRequest`
(`Pipes.Server.pas`) already catches ANY exception raised from inside the `OnRequest`
callback and turns it into an error reply for the client — the same path the
`EchoJsonServer` sample already uses on purpose with `EPipeJSONError`. Reusing that existing
mechanism is simpler than reinventing a "silence" that makes no sense in request-reply:
unlike `OnMessage` (fire-and-forget, where "do nothing" is a valid response), `ExecuteRequest`
ALWAYS sends some response to the client — a success or error reply, never nothing. That is
why there is no `OnUnknownCommand`/`OnInvalidPayload` equivalent on the request side: the
client is already informed via `EPipeError` from `Request`'s return
(`'servidor respondeu erro: ' + <exception message>`), and there would be no way to
"silence" that without breaking the contract that every `Request` gets a response.

**No envelope on the reply.** Only the REQUEST uses `PipeEncodeCommandPayload` (command name
+ body) — whoever called `Request` already knows which command they sent, so
`AReply: TBytes` stays raw, with no `PipeDecodeCommandPayload` on the receiving side.

**Tests:** 9 new cases (request-side registration mirroring the 4 relevant ones from
`RegisterCommand`, plus proof that the same name in both registries does not conflict;
dispatch covering a registered command with a reply, an unknown command, a payload outside
the range, a payload at the limits, and a malformed envelope — the last four checking
`Assert.WillRaise`/`AssertException(EPipeProtocol, ...)` instead of events). Suite total:
147 (was 138). Verified on both compilers: FPC/Win64
(`PipesUnitTestsFpc.exe --all --format=plain`, 147/147, 0 errors/failures) and Delphi/DUnitX
(147/147 unit + 121/121 integration, 0 leaks/failures/errors, confirmed by the user on
2026-08-15). The `EchoCommand` sample (`samples/EchoCommand/`) gained the `SOMAR` command
(request-reply, sums two integers) and the `?ping` scenario (unknown command on the request
side) — verified end-to-end on FPC/Win64 (real server + client).

### 18.9 `PipeSendCommand`/`PipeRequestCommand`: the `SendCommand` convenience left out in §18.6

Motivation: the real usage pattern for commands is always "build the envelope, send it" —
`PipeEncodeCommandPayload(ACommand, ABody)` followed by `SendBytes`/`Request` showed up
repeated in every call site, both in the user's own app and in the `EchoCommand` sample
itself. §18.6 left this wrapper out on purpose for lack of a concrete use; that reason was
overturned when the user asked for exactly this helper for a VCL client that queries a
`CONSULTA_NFE` (invoice lookup) command via a synchronous `Request`.

**Same mold as `PipeSendJSON`/`PipeRequestJSON` (`Pipes.Json.pas`), not a new mechanism.**
`PipeSendCommand` has two overloads — `(AClient, ACommand, ABody, AGroupKey = '')` and
`(AServer, AConnId, ACommand, ABody, AGroupKey = '')` — mirroring `PipeSendJSON`'s overloads
exactly; `PipeRequestCommand` only exists on the `TPipeClient` side, because `Request` only
exists there. The `PipeSendCommandText`/`PipeRequestCommandText` variants do the
`PipeUtf8Encode`/`PipeUtf8Decode` of the body, same pattern as `SendText`/`RequestText` — not
`Pipes.Json`'s pattern (JSON has no separate "raw text" form of its own, a command does,
because a command's body is generic `TBytes`, not necessarily JSON).

**`PipeRequestCommand`'s reply stays RAW.** Just as `HandleRequest` does not decode the
incoming request as an envelope on the reply side (§18.8, "No envelope on the reply"),
`PipeRequestCommand` does not decode the received `AReply` — whoever called it already knows
which command they asked for, so the return value is the handler's raw body, only run through
`PipeUtf8Decode` in the `...Text` variant.

**Nothing changes in `TPipeClient`/`TPipeServer`.** These are free functions in
`Pipes.Commands.pas`, which already depended on `Pipes.Types`/`Pipes.Framing`; the unit now
also imports `Pipes.Client`/`Pipes.Server` (no circular-dependency risk — neither of those
knows about `Pipes.Commands`), the same dependency direction `Pipes.Json.pas` already uses.

**`UnregisterCommand` is still out of scope** — no concrete use case has shown up for it in
this round.

The `EchoCommand` sample was migrated to use all four wrappers on both sides (`PONG`/`ECO_OK`
on the server via `PipeSendCommand`/`PipeSendCommandText`; `ping`/`eco`/`?soma`/`?ping` on the
client via all four). Verified on both compilers: FPC/Win64 unit suite 147/147 (suite
unchanged — the wrappers are one-line functions over `PipeEncodeCommandPayload`/`SendBytes`/
`Request`, already covered, so no dedicated test), real server + client run end-to-end
(`ping`, `eco`, `?soma 3 4` → `7`, `?ping` → the expected `EPipeError`); and Delphi/DUnitX
147/147 unit + 121/121 integration, 0 leaks/failures/errors, confirmed by the user on
2026-08-17.

## 19. Client address (`TryClientAddress`)

Motivation: an app logging connections (audit, diagnostics) only had `AConnId` to identify
who connected — an opaque number with no meaning outside the process. On `ptTcp`/`ptTls`,
even without mTLS, the peer's IP is already available on the socket; it just wasn't exposed.

### 19.1 `TryPeerAddress` on the abstract contract, not just a server-side hack

Follows the SAME pattern as `TryPeerIdentity` (see `TPipeEndpoint` in
`Pipes.Transport.pas`): a virtual method on the abstract class, `Result := False` by
default, and each backend overrides where it makes sense. `ptLocal` (Windows
`TPipeWinEndpoint`, POSIX `TPipePosixEndpoint` over an `AF_UNIX` fd) overrides nothing —
inherits the `False` — because a Named Pipe/UDS has no concept of a network address, just a
local handle/fd. `TPipeTlsEndpoint.TryPeerAddress` always delegates to the underlying TCP
endpoint (`FInner`), on both backends (Schannel/OpenSSL) and even BEFORE `Handshake` —
unlike `TryPeerIdentity`, address isn't certificate content, it's a socket property.

### 19.2 `TPipeRawSockAddrIn`/`TPipeRawSockAddrIn6`: a hand-declared struct, and why

`getpeername` returns a `sockaddr` whose real layout depends on the family (`AF_INET` vs.
`AF_INET6`), and each compiler's socket unit types this incompatibly with the other — the
same problem that already led `Pipes.Transport.Tcp.pas` to hand-declare `TPipeAddrInfo` for
`getaddrinfo` instead of trusting `WinSock2`/`Sockets` (see that unit's header). The
solution here is the same: `TPipeRawSockAddrIn`/`TPipeRawSockAddrIn6`/
`TPipeRawSockAddrStorage` (`Pipes.Transport.pas`) are the raw byte layout — family as a
`Word`, port in network byte order, address as a byte array — that is **identical** between
Windows and POSIX (only the VALUE of the IPv6 family constant diverges: 23 on Windows, 10 on
Linux, each backend with its own). `pipe_getpeername` is declared locally in each backend
(`Pipes.Transport.Tcp.pas` for Windows, `Pipes.Transport.Posix.pas` for POSIX), the same
idiom as `pipe_bind`/`pipe_connect`: the address travels as an opaque pointer + size, so the
buffer fits whatever family the kernel returns.

The structs and `PipeFormatIPv6` (formats without the canonical `::` zero-compression — more
verbose, but still a valid, reconnectable IPv6, good enough for logging) live in
`Pipes.Transport.pas` — not in `Pipes.Transport.Tcp.pas`, even though that's the unit
implementing Windows's TCP backend — because `Pipes.Transport.Posix.pas` (the POSIX
backend) also needs them for its OWN `TryPeerAddress`, and both units already depend on
`Pipes.Transport`.

### 19.3 The same class serves both UDS and TCP on POSIX: family is the discriminator

`TPipePosixEndpoint` (`Pipes.Transport.Posix.pas`) wraps both an `AF_UNIX` socket
(`ptLocal`) and an `AF_INET`/`AF_INET6` one (`ptTcp`, assembled in
`Pipes.Transport.Tcp.pas` with ownership handed off to this class — see that unit's header)
— it's the SAME class, with no flag or subclass to tell the fd's origin apart.
`TryPeerAddress` doesn't need that flag: it calls `getpeername` unconditionally and only
recognizes `PIPE_AF_INET`/`PIPE_AF_INET6` in the `case`; an `AF_UNIX` socket returns a
family other than those two and falls through to the `else` (`Result := False`) by the same
mechanism, with no extra code. The family check DOES the job a second class would, with one
fewer line.

### 19.4 `FAddresses`/`FAddressOrder`: the same lifecycle as `FIdentities`, deliberately duplicated

`TPipeServer.PublishEstablished` (called by the reader thread after `Handshake`, before
`OnClientConnected`) now also calls `AConn.FEndpoint.TryPeerAddress` and stores the result
in its OWN dictionary (`FAddresses`/`FAddressOrder`), with the SAME oldest-first eviction and
the SAME `PIPES_RECENT_IDENTITIES` ceiling as `FIdentities`/`FIdentityOrder` — the reason to
exist is identical: the address needs to survive `OnClientDisconnected` to answer "where did
whoever left come from?", and connection cleanup has no guaranteed order relative to that
event (same rationale as `FIdentities`, see `Pipes.Server.pas`'s header). The decision was to
duplicate the dictionary/list/eviction rather than generalize the two into a single metadata
cache: it's more total code, but each mechanism stays additive and isolated — the pattern
`TPipeKeyedDispatcher` (§15.2) and other extensions to this lib already follow, instead of
reopening a structure that already works to accommodate a second piece of data.

### 19.5 Platform coverage: Windows and POSIX/Linux implemented, Android out of this round

Windows and POSIX (Linux) have `TryPeerAddress` implemented and verified — FPC/Win64
(`PipesIntegrationTestsFpc.exe`, `Pipes.PeerAddressTests` suite) and Delphi/DUnitX. The
POSIX branch **compiles** (same discipline as always: symbols are hand-declared, with no
dependency on any version quirk of the `Sockets` unit), but was **not exercised** this
round — this development machine has no Linux toolchain, the same limitation already noted
for other POSIX parts of this project (see §16, LAN discovery). `Pipes.Transport.Android`
did not gain `TryPeerAddress` this round: it's a separate platform axis (§13), and the
request that motivated this feature was about logging on a desktop server.

### 19.6 Tests

Integration (`Pipes.PeerAddressTests`, dual): a connected `ptTcp` client returns
`'127.0.0.1:<ephemeral port>'` (only checks the port is a number > 0, never a fixed value —
the OS picks it); `ptLocal` returns `False` with an empty string; a nonexistent `AConnId`
returns `False` (same case as `ConnectionStats`); and the address is still queryable AFTER
`OnClientDisconnected` fires, proving §19.4's survival. The first three wait for
`ServerStats.ClientCount` to reach 1 before reading `ClientIds` — the client-side `Connect`
returns before `PublishEstablished` runs on the server, a real race that
`Pipes.StatsTests` already avoids the same way (`WaitCount` before reading any
`ClientIds`/`Stats`).

## 20. Per-subscriber delivery confirmation (`OnDelivered`/`OnDeliveryFailed`)

Motivation: a production app with many subscribers (dashboard/POS) needed to log, per
recipient, whether a publication made by the server ITSELF (`Publish`/`PublishBatch`, live or
retained replay) reached the OS on that connection's side — `Publish`'s log (one call, from
the publisher's side) does not distinguish "nobody was subscribed" from "was subscribed and
the Write failed", and that distinction is exactly what is needed during a rollout phase to
answer a field-reported inconsistency. `OnPublish` does not serve this: it exists for the
CLIENT publishing, not for the server being the publisher.

### 20.1 Two events, not one with a success flag

User decision, with an explicit trade-off: a single `OnDelivered(..., ASuccess: Boolean)`
would be less code, but forces every handler to filter out the case it does not care about
(success goes to a metric, failure goes to an alert — rarely the same handler wants both).
Two events with distinct signatures (`TPipeTopicEvent` for success — reusing the SAME type as
`OnPublish`/`OnTopicMessage`, since the fields are identical; a new `TPipeDeliveryFailedEvent`
just for failure, with an extra `AError`) let anyone who only wants to alert on failures
subscribe to ONE event, without filtering anything.

### 20.2 "Delivered" means as far as the OS, never an application ACK

`ARetained` here has the SAME meaning as the server-side `TPipeTopicEvent` used by the
client's `OnTopicMessage`: `False` = live delivery, `True` = replay of a retained value at
subscribe time. The event is deliberately named `OnDelivered`, not `OnAcked` or
`OnConfirmed`: it fires when `SendFrame`/`SendFrames` returns without an exception, i.e. when
the payload was handed to the socket/pipe buffer of the OS — the same cut that `Stats`/
`BytesSentWire` already make (§11/§17.6). The protocol NEVER had an application ACK (no
`pfkAck`, no correlation coming back from the client); promising processing confirmation
would be an API lie. A client that hangs or discards the message after it lands in the
socket remains invisible to this event — that is the deliberate boundary of this feature.

### 20.3 Where it fires: FanOut, SendRetained and PublishBatch — always in the send loop, outside the lock

The three existing fan-out points gained the firing, without changing how they decide WHO
receives (that is still §9.2: topic matching is pure code under `FConnLock`, no IO or
allocation):

- `FanOut` (live publication, a single `TPipeFrame` reused across connections): each
  `LConn.SendFrame` was already inside a per-connection `try/except` (so one connection
  falling does not interrupt the fan-out for the rest); the firing goes into that same
  `try/except` — success calls `DispatchTopicEvent(FOnDelivered, ...)`, failure calls
  `DispatchDeliveryFailedEvent(FOnDeliveryFailed, ..., E.Message)`. Always `ARetained =
  False` — it is the SAME frame that goes out with `PIPE_FLAG_RETAIN` off on the wire (§9,
  "Always goes out with PIPE_FLAG_RETAIN off").
- `SendRetained` (replay at subscribe time, `Length(LTopics)` values in a single atomic
  `SendFrames` — see §9.6, "either the whole replay arrives or none does"): the atomicity of
  the WRITE does not change; what changes is that, after `SendFrames` returns (success OR
  exception), a loop fires one event PER retained topic — each stored value is still a
  logically distinct delivery for whoever logs observability, even though it went out in a
  single Write. Always `ARetained = True`.
- `PublishBatch`: the per-connection frame subset (`TPipeConnFrameBatch`) gained two arrays
  parallel to `Frames` — `Topics`/`Payloads` — only for this correlation; after that
  connection's `SendFrames`, a loop fires one event per matched batch ITEM. Always
  `ARetained = False`, even when the item asked for `Retain = True`: that is about the
  STORED value (already settled by `StoreRetained` before the fan-out), not about this
  delivery being catch-up — same reasoning as `FanOut`.

In none of the three is the connection dropped because of the failure: its reader will
already report the fall via `OnClientDisconnected`, with no correlation to which specific
publication failed — that missing correlation is exactly what `OnDeliveryFailed` exists to
fill.

### 20.4 Dispatch mechanism: reused, not reinvented

`OnDelivered` reuses the `DispatchTopicEvent`/`TPipeTopicWork` that already existed for
`OnPublish`/`OnTopicMessage` (same `TPipeTopicEvent` type, zero new code in `Pipes.Base.pas`
beyond calling what already existed). `OnDeliveryFailed` needed a new, symmetric pair —
`TPipeDeliveryFailedEvent`, `TPipeDeliveryFailedWork`, `qeDeliveryFailed` in
`TPipeQueuedKind`, `DispatchDeliveryFailedEvent` — because its signature has one extra field
(`AError`); the mechanics (drained via `FInFlight`, `pdmMainThread` via a guarded queue, the
other modes via `EventPool`) are identical to any other event in the lib, only reusing
`TPipeQueuedEvent.FMsg` (already existed for `OnError`) instead of a dedicated string field.

### 20.5 Tests: success is deterministic; failure uses `MaxMessageSize`, not a socket race

The three success cases (`OnDelivered_FanOut_UmaVezPorAssinante`,
`OnDelivered_Retido_ChegaComARetainedTrue`, `OnDelivered_PublishBatch_UmPorItemPorConexao`, in
`Pipes.PubSubTests`, dual) are normal happy-path, no special timing. The failure case
(`OnDeliveryFailed_PayloadExcedeMaxMessageSize`) does **not** try to reproduce a connection
dying at the exact moment of the send — that race between "the reader detects the drop and
removes the connection" and "the test manages to publish before that" is exactly the kind of
flaky test §7 (T4/T5) and §13.10 already flagged as a trap. Instead, the test opens the
server with a `MaxMessageSize` small enough to let the subscription through (the filter alone
fits) but too small for the topic+body envelope of the publication:
`PipeValidateMaxPayload` refuses the `Write` BEFORE touching the socket/pipe, 100%
deterministically, exercising the same `except` block a dead connection would — without
depending on any real OS-level race. Verified on both compilers: FPC/Win64
(`PipesIntegrationTestsFpc.exe`, `TPipePubSubTests` suite, 27/27, within the full 126/126
integration suite) and Delphi/DUnitX (147/147 unit + 126/126 integration, 0 leaks/failures/
errors, confirmed by the user on 2026-08-22).

### 20.6 Side effect: a pre-existing bug found and fixed in `PublishBatch`

Writing `OnDelivered_PublishBatch_UmPorItemPorConexao` exposed that `PublishBatch` was
writing the LIVE frame's `PIPE_FLAG_RETAIN` bit directly from each `TPipePublishItem`'s
`Retain` field, instead of always `False` the way `FanOut`/`Publish` do (§9, "Always goes
out with PIPE_FLAG_RETAIN off"). Effect: an item with `Retain = True` delivered to a
subscriber that was ALREADY connected arrived with `ARetained = True` in `OnTopicMessage` —
the client was misled about "is this news or history?", since no existing test covered a
subscriber connected AT THE TIME of the publication (the only batch-retain test subscribed
AFTER, receiving it through `SendRetained`'s replay, where `ARetained = True` is correct).
Fixed alongside this feature: the line that builds the batch's `TPipeFrame` now always
passes `False`, same as `FanOut`; a regression test,
`PublishBatch_RetainAoVivo_NaoMarcaARetainedParaQuemJaAssinava`, covers the missing path.

## 21. Asynchronous connect (`TPipeClient.ConnectAsync`)

`Connect(ATimeoutMs)` is synchronous: if the server is not up within the deadline, it raises
`EPipeTimeout`/`EPipeError` and the app is left holding the problem. `AutoReconnect` does not
cover that gap — it only kicks in after a session has ALREADY existed and dropped, because
what triggers it is `ReaderFinished`, and `ReaderFinished` only runs from a live session's
reader thread. In other words: **"the app starts before the server" had no answer in the
library**. Anyone who needed it wrote a manual retry loop around `Connect` — reinventing, and
worse, the spacing, the attempt ceiling and the failover that the library already had right
there.

`ConnectAsync` closes exactly that case: it returns immediately, and an internal thread keeps
trying until the server shows up. Success arrives in `OnConnected`; giving up, in `OnError`;
`Connecting` says whether it is still trying; `Disconnect` cancels.

### 21.1 Reuse the reconnect thread, don't build a second state machine

The central decision: `ConnectAsync` has **no thread and no state machine of its own**. It
sets a flag and starts the SAME `TPipeReconnectThread`.

This is not code economy, it is recognizing that it was already the same operation.
`TryReopenSession` literally IS "connect until the server answers, with spacing between
attempts, an attempt ceiling and a walk through the failover list" — what differs between
reconnecting and connecting for the first time is only the CALL SITE, not what has to happen.
Duplicating would have cost a second copy of the spacing (`WaitBetweenRetries`), of the
ceiling (`FReconnectAttempts`/`FGaveUp`), of the `FAddrIndex` advance and — worst — a second
thread capable of installing a session, with all the new coordination that implies against
the first one.

It is worth contrasting with the **opposite** precedent in `ADDR0` (§19), where
`FAddresses`/`FAddressOrder` were deliberately duplicated from `FIdentities`/`FIdentityOrder`
instead of generalized: there they were two independent DATA that merely happened to share a
shape, and unifying them would have created coupling where none existed. Here it is a single
OPERATION with two entry points. Generalizing gets one right and the other wrong — the
question to ask is not "does it look the same?", it is "is it the same thing?".

### 21.2 The gate: `ReopenAllowed`, in BOTH places (missing the second one is a silent bug)

The entire contact surface between the new feature and the existing engine is a one-line
function:

```pascal
function TPipeClient.ReopenAllowed: Boolean;
begin
  Result := FAutoReconnect or (PipeAtomicGet(FConnectingAsync) <> 0);
end;
```

`TryReopenSession` consulted `FAutoReconnect` in **two** places, and both had to become
`ReopenAllowed`:

1. **On entry**, before trying. Obvious: without it, a `ConnectAsync` with
   `AutoReconnect = False` would give up before the first attempt.
2. **On the re-check with the connection ALREADY OPEN**, right after `PipeConnect` returns.
   That is the one that slips by, and forgetting it is far worse than "doesn't work": the
   `PipeConnect` would succeed and the freshly connected endpoint would be closed and
   discarded right there, silently, whenever `AutoReconnect = False`. `ConnectAsync` would
   keep trying forever against a server that is up and accepting.

That second check exists for a real reason (a decision to stop can arrive DURING the
`PipeConnect`; installing the session after that would announce `OnConnected` to someone who
already asked to stop) — so it does not go away, it just starts asking the right question.

### 21.3 Who clears `FConnectingAsync` — and why it is NOT `TryReopenSession`

The clearing lives in `TPipeReconnectThread.Execute` (and, deliberately, in `Disconnect`),
**never** in `TryReopenSession` next to `PipeAtomicSet(FReconnecting, 0)`. That looks like the
natural place, and it is wrong — this paragraph exists so nobody "simplifies it back".

The case that breaks is the peer that **accepts and drops**: the mTLS server on the SChannel
backend completes the handshake and only THEN validates the chain, so a client with a rejected
certificate sees a connection established followed by an immediate drop (the same case already
documented in the `Pipes.Client.pas` header and in §7). With `AutoReconnect = False` and a
`ConnectAsync` in flight:

1. `TryReopenSession` installs the session, fires `OnConnected` and returns `True`, clearing
   `FReconnecting`.
2. The session drops at that very moment. Since `AutoReconnect = False`, `ReaderFinished`
   does **not** create a new thread — the one that has to resume is this same thread.
3. In `Execute`, the CAS on `FReconnecting` succeeds (it was cleared in step 1) and the loop
   continues.
4. ...but `TryReopenSession` checks `ReopenAllowed` right on entry. Had the flag been cleared
   in step 1, the gate would be shut and the attempt would abort **silently**: `Connecting`
   `False`, no live session at all and no error anywhere.

Hence the rule: only whoever **owns the cycle** on the way out clears it. In `Execute` that
is explicit:

```pascal
LConn  := FClient.FConnected;
LDelib := PipeAtomicGet(FClient.FDeliberate) <> 0;
LDePe  := LDelib or LConn or
          (PipeAtomicCompareExchange(FClient.FReconnecting, 1, 0) <> 0);
if LDePe then
begin
  if LConn or LDelib then
    PipeAtomicSet(FClient.FConnectingAsync, 0);
  Exit;
end;
```

Exits with a session up (`LConn`) or on a deliberate `Disconnect` (`LDelib`) → this thread is
done, clear it. Exits because the **CAS failed** → the session dropped at that instant and
`ReaderFinished` has already created a NEW `TPipeReconnectThread` (possible when
`AutoReconnect` is on at the same time as a `ConnectAsync` in flight); the one that clears is
that new thread, and clearing here would wipe `Connecting` with the attempt still alive.

Two notes on the shape:

- **The snapshot is deliberately single.** `LConn`/`LDelib` are read ONCE and serve both
  decisions (leaving the loop and clearing the flag). Re-reading `FConnected` inside the `if`
  would open a window where the session drops between the two reads: the loop exits on "it was
  up" but the clearing never happens, and with `AutoReconnect = False` there is no new thread
  to clear it later — `Connecting` would stay `True` forever. The expression is point-for-point
  equivalent to the original (`not (A and B and C)` = `(not A) or (not B) or (not C)`),
  including the short-circuit that guarantees the CAS only runs when no session is up.
- **The exit below the loop** (gave up: deliberate or exhausted) clears `FConnectingAsync`
  BEFORE `FReconnecting`, because the latter is what releases `Disconnect`'s
  `WaitReconnectDone` — whoever wakes up there must already see `Connecting = False`.

`Disconnect` also clears the flag explicitly, right after `WaitReconnectDone`. That is not
defensive redundancy: without it, cancellation would depend on the order in which the thread
clears the two flags, and `Connecting` could read `True` for an instant AFTER `Disconnect`
returned — exactly the question an app would ask to decide whether it is still trying.

### 21.4 No timeout parameter: the budget is the reconnection's

`ConnectAsync` has no `ATimeoutMs`. The budget is `MaxReconnectAttempts` ×
`ReconnectDelayMs`, the two properties that already existed — the same refusal as in §12.5 to
create a budget of its own "for a marginal gain". With `MaxReconnectAttempts = 0` (the
default) it tries forever, which is what the use case asks for: the POS powers up before the
back office and waits.

This is an **approximate** wall-clock ceiling, not an exact one — each attempt spends up to
`ReconnectDelayMs` inside `PipeConnect`, and the spacing consumes whatever is left of that
same interval. Anyone needing an exact deadline composes: call `Disconnect` from a timer.
Inventing a budget of its own would require reconciling it with the two existing ones on every
attempt, and the result would be three numbers fighting over the same clock.

Exhaustion arrives in `OnError`, not as an exception — there is nobody to raise to, the caller
already returned. The message is context-dependent (`'conexao inicial esgotada apos N
tentativas'` instead of `'reconexao esgotada...'`): someone who never had a session at all,
reading "reconnection exhausted" in the log, would go looking for a drop that never happened.

### 21.5 `GetLifecycleLocked`: `Connecting` also locks configuration

`EnsureInactive` now consults `GetLifecycleLocked` (virtual on `TPipeBase`, defaulting to
`GetActive`) instead of `GetActive` directly. `TPipeClient` overrides it as
`FConnected or Connecting`.

The reason is a window that **only exists** with asynchronous activation: with a synchronous
`Connect()` the caller is blocked inside the object itself and has no way to change `Address`
mid-attempt. With `ConnectAsync` it returns immediately, and nothing would stop the app from
touching `Address`/`Transport`/`TlsOptions` while the thread is still trying — the next
attempt would aim at a different server, or the same one over a different transport, with
nobody having asked for it.

A new method instead of changing `GetActive`: `Connected`/`Active` are public API with an
established meaning ("there is a session"), and widening it to "there is a session or I am
trying" would make `Connected = True` with no session at all — breaking every piece of code
that decides whether to send based on that property. `TPipeServer` inherits the default and
does not change at all.

### 21.6 No changes in `Pipes.Transport.*`

None of the five `PipeConnect` backends (Windows, POSIX, Tcp, Tls, Android) has a mechanism to
cancel an in-progress connect from another thread, and this feature **did not invent one**.
Cancelling a `ConnectAsync` inherits the same trade-off `Disconnect` already accepts today for
automatic reconnection, and which `WaitReconnectDone` has always documented: "worst case, it
waits for a `PipeConnect` of up to `ReconnectDelayMs` to finish".

That is a choice, not an oversight. Real cancellation would mean touching the five platform
backends — the highest-risk point in the project, with no precedent and with Android and POSIX
verification this machine cannot run (§13, §16) — to turn a wait of milliseconds-to-
`ReconnectDelayMs` into zero. The cancellation test asserts what the library actually
guarantees (**it stops trying within at most one in-flight attempt**), and not an "instant
return" that would be a lie.

### 21.7 Tests

Nine integration tests in `Pipes.ConnectAsyncTests` (mirrored DUnitX + FPCUnit), always
waiting on a deadline (`WaitCount`/`WaitClientCount`/`WaitNotConnecting`), never a fixed
`Sleep` as an assertion. `WaitNotConnecting` exists because `Connecting` drops one step AFTER
`OnConnected` — what clears the flag is the reconnect thread, already outside
`TryReopenSession`.

| Test | What it guards |
|------|----------------|
| `ConnectAsync_ServidorJaNoAr_ConectaENotifica` | trivial path: does not block even when the server is already there |
| `ConnectAsync_ServidorSobeDepois_ConectaQuandoAparece` | **the central test**: `Connecting=True`/`Connected=False` right after the call, server comes up later, `OnConnected` fires |
| `ConnectAsync_ServidorNuncaAparece_EsgotaComMensagemDeConexaoInicial` | exhausts via `OnError` with the INITIAL-connection message (not "reconnection"), `Connecting` drops, `OnConnected` never fires |
| `ConnectAsync_CanceladoPorDisconnect_ParaDeTentar` | `Disconnect` stops the otherwise infinite loop within one in-flight attempt, and stays stopped 1.5s later (§21.6) |
| `ConnectAsync_ChamadoDeNovoEnquantoEmVoo_ReiniciaSemDuplicar` | a re-call cancels the previous one; an orphan thread would show up as a SECOND `OnConnected`/`ClientCount = 2` |
| `ConnectAsync_ComFailoverAddresses_MigraParaBackupSemPrimario` | per-address advance through the list, the SAME rule as reconnection |
| `ConnectAsync_ComAutoReconnect_ContinuaReconectandoDepois` | this is where a leaked `FConnectingAsync` (or one cleared too early) would show: after `ConnectAsync` has done its job, the normal `AutoReconnect` life cycle carries on intact |
| `Connecting_SemChamarConnectAsync_PermaneceFalse` | sanity: synchronous `Connect()` never sets `Connecting` |
| `ConnectAsync_EmVoo_ImpedeTrocarTransportOuAddress` | `GetLifecycleLocked`/`EnsureInactive` (§21.5), and the lock lifts along with `Disconnect` |

The two risky ones (cancellation and coexistence with `AutoReconnect`) were run five times in
a row in isolation, with a stable suite time (~5.7s), for the same reason recorded in §13.10:
a concurrency test that passes once has proven nothing.

### 21.8 Milestones

| # | Milestone | Content | Status |
|---|-----------|---------|--------|
| CONN0a | `Pipes.Base` | virtual `GetLifecycleLocked`; `EnsureInactive` now consults it | done |
| CONN0b | `Pipes.Client` (engine) | `FConnectingAsync`, `ReopenAllowed` on BOTH `TryReopenSession` gates, conditional clearing in `Execute` and in `Disconnect`, context-dependent exhaustion message | done |
| CONN0c | `Pipes.Client` (API) | `ConnectAsync`, `Connecting`, `GetLifecycleLocked` override | done |
| CONN0d | Tests | 9 integration tests in both frameworks | done |

## 22. Connection-attempt diagnostics (`OnConnectAttemptFailed`)

Driven by a real use case: the application operates silently on purpose — the client keeps
working through a drop, and if reconnection succeeds nobody is interrupted. The problem shows
up later, when someone reports "around 2:40pm it wasn't working right" and the log has nothing
to say about that window.

With `AutoReconnect` (and now `ConnectAsync`), the event trail up to here was:

```
14:37:02  OnError('leitura falhou: conexao encerrada')   <- ReaderFinished
14:37:02  OnDisconnected
          ................. 15 minutes of silence .................
14:52:19  OnConnected
```

The middle is what matters: was it 300 attempts against a server that was down, or 3 attempts
refused over a certificate, or did failover migrate to the backup and come back?
`OnConnectAttemptFailed` fills that window.

### 22.1 A new event, not `OnError`

Routing attempt-failed into `OnError` would have been a one-liner, and it would have been
wrong for two reasons. First, it would change behaviour for **everyone** already using
`AutoReconnect`: an app that today shows a red banner on `OnError` would start showing it
every `ReconnectDelayMs`. Second, and more fundamentally, it conflates two meanings: `OnError`
is "something the app has to handle", whereas a failed attempt is the NORMAL state of a client
waiting for its server — the next attempt is already on its way and there is nothing to decide.

The definitive outcome still arrives through the usual events: `OnConnected` when some attempt
succeeds, and the exhaustion `OnError` (`'conexao inicial esgotada...'` / `'reconexao
esgotada...'`, §21.4) when `MaxReconnectAttempts` is reached.

With no handler assigned the event costs nothing — `DispatchAttemptFailedEvent` returns at the
first `if not Assigned(AEvent)`. There is no boolean opt-in property: it would be
configuration with no function, since not assigning the handler IS the opt-out.

### 22.2 It fires on BOTH paths, deliberately

`ConnectAsync` and automatic reconnection share the same `TPipeReconnectThread` (§21.1), and
the event is raised from the single point every attempt passes through — the `except` around
`PipeConnect` in `TryReopenSession`. Consequence: one event covers both "I never connected"
and "I dropped and I'm coming back".

That is the right call for the purpose. Splitting it in two would leave the log blind in
precisely the most common case — the session that dropped mid-shift — and would force whoever
logs to subscribe to both to get the full story. Anyone who wants to tell the cases apart has
`Connecting` on the object itself.

Note the event also reaches those who do **not** use `ConnectAsync`: a client with synchronous
`Connect` + `AutoReconnect` gets its reconnection attempts normally (that is what
`AttemptFailed_ReconexaoAutomatica_TambemDispara` pins down).

### 22.3 `AAddress` BY VALUE — the trap the event avoids

```pascal
TPipeAttemptFailedEvent = procedure(Sender: TObject; const AAddress: string;
  AAttempt: Integer; const AError: string) of object;
```

The address travels as a parameter, captured into `LTentado` BEFORE `PipeConnect`, rather than
being read from `ActiveAddress` inside the handler. The reason is subtle and expensive: with
`FailoverAddresses`, `FAddrIndex` advances **inside the `except` itself**, before the event is
raised. A handler consulting `Client.ActiveAddress` would record the NEXT attempt's address,
not the one that just failed — a forensic log that swaps the culprit is worse than no log,
because it looks correct.

The `except` also went from `on EPipeError do` to `on E: EPipeError do`: the transport's
message is what separates "server absent" from "server refused my certificate", and that was
exactly what was being discarded.

`AAttempt` is the same `FReconnectAttempts` that `MaxReconnectAttempts` caps — it starts at 1
and counts from the last DURABLE session, not from the beginning of time (same criterion as
§12.4). It is the field that lets a logger apply a decimation policy ("I logged the 1st, the
5th, the 20th") without keeping state of its own between calls.

There is no `AConnId`, unlike every other event in the library: there is no connection — that
is precisely what the event is about. An always-zero parameter would be noise.

### 22.4 Frequency: the library does not decimate

An attempt against an absent server consumes the whole `ReconnectDelayMs` (`WinPipeConnect`
polls until the deadline, §21.6), so the event fires roughly every `ReconnectDelayMs` for as
long as the outage lasts. At 3 s per attempt that is ~20 events a minute; a store with its
server down overnight produces ~10,000.

The library does **not** aggregate, decimate, or apply a suppression window. That is
deliberate: the right policy depends on the domain (rotating file? syslog? telemetry billed
per event?), and `AAttempt` already gives the app everything it needs to implement its own —
typically logging at growing intervals, accumulating the counter between records. Decimation
baked into the library would be one more policy to configure and one more case to debug when
the log looked like it was "missing lines".

### 22.5 Dispatch infrastructure: mirrored, not invented

`TPipeAttemptFailedWork` + `qeAttemptFailed` + `DispatchAttemptFailedEvent` in `Pipes.Base.pas`
mirror `TPipeDeliveryFailedWork`/`qeDeliveryFailed`/`DispatchDeliveryFailedEvent` from §20
exactly — same `IncInFlight`/`DecInFlight` contract, same `pdmMainThread` alternate path
through `TPipeQueuedEvent`/`TThread.Queue` with the refcounted guard.

`TPipeQueuedEvent` got its own fields (`FAddress`, `FAttempt`) instead of reusing `FTopic` as a
generic string slot, which is what `qeSubscription` does for its filter. Two extra fields on an
object created only under `pdmMainThread` are cheap; a connection address travelling in a field
named `FTopic` would charge the next reader dearly.

The event is raised from the **reconnect thread**, not the reader thread — the same place the
exhaustion `DispatchError` already came from. No new threading invariant (invariant 1 still
holds: the reader thread runs no user code).

### 22.6 Tests

Four tests in `Pipes.ConnectAsyncTests` (same fixture, mirrored DUnitX/FPCUnit — it already
sets up a primary server + backup + client + counters, and the event fires on both paths the
unit already exercises):

| Test | What it guards |
|------|----------------|
| `AttemptFailed_ServidorAusente_DisparaPorTentativaComContador` | one event per attempt (exactly 3 with a ceiling of 3), `AAttempt` = `1\|2\|3`, correct address on all of them, non-empty error message, and it STOPS firing once exhausted |
| `AttemptFailed_ComFailover_ReportaOEnderecoQueFalhou` | §22.3: the event reports the PRIMARY, even though `ActiveAddress` already points at the backup |
| `AttemptFailed_ReconexaoAutomatica_TambemDispara` | §22.2: it reaches users of synchronous `Connect` + `AutoReconnect`, with no `ConnectAsync` involved |
| `AttemptFailed_ConexaoBemSucedida_NaoDispara` | silent operation: a connection that succeeds first try produces no noise |

### 22.7 Milestones

| # | Milestone | Content | Status |
|---|-----------|---------|--------|
| DIAG0a | `Pipes.Types` | `TPipeAttemptFailedEvent` | done |
| DIAG0b | `Pipes.Base` | `qeAttemptFailed`, `TPipeAttemptFailedWork`, `DispatchAttemptFailedEvent` | done |
| DIAG0c | `Pipes.Client` | `OnConnectAttemptFailed`, `LTentado` and `on E:` in `TryReopenSession`'s `except` | done |
| DIAG0d | Tests | 4 integration tests in both frameworks | done |
