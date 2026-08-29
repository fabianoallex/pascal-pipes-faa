# Interoperability — talking to `pascal-pipes-faa` from another language

> 🇧🇷 Este documento também está disponível em [português](INTEROP.md) — a versão em
> português é a canônica; em caso de divergência, ela prevalece.

This document describes the **wire protocol** that `TPipeServer`/`TPipeClient` use, for
anyone who needs to implement the other end in another language (Python, C#, Go, Java,
Rust, JS…). Nothing here depends on Delphi/FPC — it is just a binary format over a byte
stream.

- Source of truth for the format: `src/Pipes.Framing.pas` (NPF1 framing),
  `src/Pipes.Topics.pas` (topic envelope), `src/Pipes.Compression.pas` (kind 7),
  `src/Pipes.Commands.pas` (command envelope), `src/Pipes.Discovery.pas` (NPD1).
- Rationale for *why* each decision was made: `docs/ARCHITECTURE.en.md`.
- If this document disagrees with the code, the code wins — open an issue.

---

## 1. Communication model

It is **client/server** with a single live, full-duplex connection. Four patterns travel
over that same connection, all multiplexed by the same framing:

| Pattern | Who initiates | Frames |
|---|---|---|
| One-off message (fire-and-forget) | either side | `Message` (kind 0) |
| Request/reply (RPC with correlation) | **only the client** asks; the server replies | `Request` (1) → `Reply` (2) |
| Topic pub/sub | client subscribes; server delivers | `Subscribe` (4), `Unsubscribe` (5), `Publish` (6) |
| Application heartbeat | either side, if enabled | `Ping` (3) |

Points that define what you must implement:

- **The server never issues a `Request` to a client.** `Request`/`Reply` is always
  client→server→client. If the server wants to speak to the client spontaneously, it sends
  a `Message` or a `Publish`.
- **There is no application handshake.** The connection opens (TCP, or TCP+TLS) and frames
  can flow in both directions immediately. There is no version exchange, no banner, no
  "hello" — each frame's `Magic` is the only synchronization.
- If your side is going to **subscribe to topics**, send the `Subscribe` frames right after
  the transport connects; that is what the Delphi client does (including re-sending the
  subscriptions after a reconnection, before any other traffic).

---

## 2. Transport layer

The Delphi side picks the transport via the `Transport` property. You open the matching
socket:

| `Transport` | Ordinal | What to open |
|---|---|---|
| `ptLocal` | 0 | Named Pipe (Windows) or Unix Domain Socket (Linux) — see §2.3 |
| `ptTcp` | 1 | plain TCP socket |
| `ptTls` | 2 | TCP socket + TLS on top |

For interop, prefer **`ptTcp`** (or `ptTls` if the traffic leaves the machine). `ptLocal`
is implementable, but it is the most laborious path with no portability gain.

### 2.1 `ptTcp`

Ordinary TCP socket, `Address` in `host:port` form (IPv6 in brackets: `[::1]:5000`; `*` is
shorthand for `0.0.0.0` on the server side). No special socket options are required by the
protocol. The Delphi side turns on **OS TCP keepalive** by default (`KeepAliveSeconds`),
but that is transparent to you — no bytes cross the wire.

### 2.2 `ptTls`

TCP + standard TLS 1.2+. The Delphi client:

- sends **SNI** with the host from `Address`;
- does **not** use ALPN;
- validates the server certificate against the `Address` host and the `TlsOptions` policy
  (trusted CA, etc.).

If the server requires **mTLS**, your side must present a client certificate chaining to a
CA the server trusts. After the TLS handshake the content is plain NPF1 — TLS is just a
tunnel.

### 2.3 `ptLocal` (if you really need it)

- **Windows:** byte-mode Named Pipe. Name: a plain `Address` (`"MyService"`) becomes
  `\\.\pipe\MyService`; if `Address` already starts with `\\`, it is used as-is.
- **Linux:** file-based Unix Domain Socket (`AF_UNIX`, `SOCK_STREAM`). A plain `Address`
  (`"MyService"`) becomes `/tmp/MyService.sock`; if `Address` starts with `/`, it is the
  socket path. It is **not** the abstract namespace.
- **Android:** `ptLocal` does not exist — the server refuses it. Use `ptTcp`/`ptTls`.

On top of the pipe/socket the framing is **identical** to `ptTcp`. `PIPE_READMODE_MESSAGE`
is not used — boundaries belong to NPF1, not to the transport.

---

## 3. NPF1 framing

Every frame is a **20-byte header + payload**. All multi-byte fields are
**little-endian**.

```
 offset  field      bytes  content
 ------  ---------  -----  ---------------------------------------------------
   0     Magic        4    'N','P','F','1'  = 0x4E 0x50 0x46 0x31
   4     Kind         1    0..7 (see §4)
   5     Flags        1    bit field (see §3.1)
   6     Reserved     2    0x00 0x00  (always zero; ignore on read)
   8     CorrId       8    uint64 LE — request/reply correlation (see §5)
  16     Length       4    uint32 LE — payload size in bytes
  20     Payload    Length raw bytes (text = UTF-8)
```

The total frame size is `20 + Length`.

### 3.1 Flags

| Bit | Mask | Name | Meaning |
|---|---|---|---|
| 0 | `0x01` | ERROR | Only on `Reply` (kind 2): the reply is an error; the payload is the error message in UTF-8. |
| 1 | `0x02` | RETAIN | Only on `Publish` (kind 6): the server should retain this message as the topic's last value. Empty payload + this bit = clear the retained value. |

The other bits are reserved (zero). Ignore unknown bits in kinds where they do not apply.

### 3.2 Read rules (mandatory)

1. **Read exactly N bytes in a loop.** TCP and pipes deliver partial data: one `recv`/`read`
   may return less than requested. Never assume "one packet = one frame".
2. **Several frames may arrive back-to-back** in a single TCP segment or a single write
   (the Delphi side has batch sending — `SendBytesBatch`/`PublishBatch`). Parse by the
   `Length` field, never by the `recv` boundary.
3. **Invalid `Magic` → close the connection.** It means the stream is out of sync; do not
   try to resynchronize.
4. **`Kind > 7` → close the connection** with a clear error. It almost always means the
   peer speaks a newer version of the protocol (that is how kinds 4–7 were added), not line
   noise.
5. **`Length` above your cap → close the connection.** Pick a sane cap (the Delphi-side
   default is 16 MiB, configurable via `MaxMessageSize`). It is the defense against a
   corrupt or hostile length that would make you allocate gigabytes.
6. **EOF in the middle of a frame** = truncation / abrupt drop. EOF exactly on a frame
   boundary = clean shutdown.

### 3.3 Write rules (mandatory)

1. **Header + payload in a single** `send`/`write` call (or buffer and flush at once). This
   avoids interleaving frames from concurrent threads on the same socket.
2. If you have **multiple threads** writing to the same connection, serialize the writes
   with a lock — the Delphi side does this (one write lock per connection).
3. Validate your payload size against the cap **before** writing any bytes.

### 3.4 Text

Wherever the protocol carries text (payload of `*Text`, error message, topic name, command
name) it is **always UTF-8**, no BOM.

---

## 4. Kinds

| Kind | Name | Direction | Implement if… |
|---|---|---|---|
| 0 | `Message` | either side → either side | you use one-off messages |
| 1 | `Request` | client → server | you do RPC from the client |
| 2 | `Reply` | server → client | same |
| 3 | `Ping` | either side | the Delphi side enables `HeartbeatIntervalMs` (see §7) |
| 4 | `Subscribe` | client → server | you subscribe to topics |
| 5 | `Unsubscribe` | client → server | you cancel subscriptions |
| 6 | `Publish` | server → client (and client → server if enabled) | you use pub/sub |
| 7 | `Compressed` | either side | the Delphi side enables `CompressionMinSize` (see §8) |

The absolute minimum for a working request/reply client: **kinds 0, 1, 2**.

---

## 5. Message, Request and Reply

### 5.1 Message (kind 0)

- `CorrId`: normally `0`. **It may arrive `!= 0`** — in that case it is the 64-bit hash of
  a dispatch "group key" (see Appendix B). To **receive**, ignore the value: it never
  changes what the message means. To **send**, use `0` (unless you want to reproduce the
  by-group ordering).
- `Flags`: `0`.
- Payload: the application bytes.

### 5.2 Request (kind 1) and Reply (kind 2)

Flow: the **client** sends a `Request` with a `CorrId` of its choosing; the **server**
processes it and answers with a `Reply` carrying **the same `CorrId`**.

`CorrId` rules:

- Must be **non-zero**.
- Must be **unique among the in-flight requests** on that connection (once the reply
  arrives it may be reused). The Delphi client uses an incrementing 32-bit counter widened
  to uint64 — any equivalent scheme works.
- The server **echoes the value exactly**; it does not interpret the number.

Error reply:

- `Kind = 2`, `Flags` with bit `0x01` set.
- Payload = error message in UTF-8 (e.g. the text of a handler exception).
- The Delphi client turns this into an `EPipeError` exception carrying the received text.

If the connection drops before the reply, or the client's timeout fires, the `Request`
fails locally — there is no "cancel" frame on the wire.

---

## 6. Pub/sub (kinds 4, 5, 6)

The topic/filter name is **not** in the header; it goes **at the start of the payload**, in
an envelope. This keeps `Length` covering the whole frame, so a peer that does not
understand the kind still stops in sync.

### 6.1 Topic envelope

```
[ topicLen : uint16 LE ][ topic : topicLen bytes UTF-8 ][ body : rest of payload ]
```

- `topicLen` ≤ **255** (`PIPE_MAX_TOPIC_BYTES`). The field is 2 bytes for alignment, but the
  value never exceeds 255.
- `Subscribe`/`Unsubscribe`: `body` is empty; the "topic" is really the **filter** (may
  contain wildcards — see §6.2).
- `Publish`: `body` is the published content; the "topic" is a concrete name (no
  wildcards).

### 6.2 Topic-name and filter rules

Segments separated by `.` (dot). A valid name:

- is not empty, does not start or end with `.`, has no empty segment (`a..b` is invalid);
- has no control characters (`< 0x20`);
- is ≤ 255 bytes in UTF-8.

A **filter** (only in `Subscribe`/`Unsubscribe`) additionally allows wildcards **as a
whole segment**:

| Wildcard | Matches |
|---|---|
| `*` | exactly one segment (any value) |
| `#` | zero or more segments — **only as the filter's last segment** |

`caixa*` (partial wildcard) is invalid; `a.#.b` (`#` in the middle) is invalid.

Examples: filter `store.*.status` matches `store.till1.status`; filter `store.#` matches
`store.till1` and `store.till1.status`.

### 6.3 Semantics

- `Publish` with `Flags` `0x02` (RETAIN): the server keeps it as the topic's last value and
  delivers it to whoever subscribes later. Empty `body` + RETAIN clears the retained value.
- On subscribing, the client immediately receives the retained values matching the filter,
  each in its own `Publish` (kind 6).
- A client **may also** send `Publish` (kind 6) to the server, but by default the server
  does **not** relay it (`RelayClientPublish = False`); it only relays if the server
  operator enables it.
- A subscription lives on the connection: if the connection drops, subscriptions are gone.
  The Delphi client re-sends them all on reconnect; if you implement reconnection, do the
  same.

---

## 7. Ping / heartbeat (kind 3)

Only in play if the Delphi side sets `HeartbeatIntervalMs` (default: **off**; and only for
`ptTcp`/`ptTls`). When on:

- `Ping` frame: `Kind = 3`, `Flags = 0`, `CorrId = 0`, `Length = 0` (no payload).
- **Symmetric and correlation-free:** there is no "Pong". **Any** frame received (including
  a `Ping`) resets the liveness clock the peer watches.
- Emission rule: if you went `HeartbeatIntervalMs` without **sending** anything, send a
  `Ping`.
- Detection rule: if you went more than **2×** `HeartbeatIntervalMs` without **receiving**
  anything, consider the peer dead and close the connection.

If the server does not use heartbeat, you need not send `Ping` — but you must accept
receiving one without treating it as an error (just discard it; the "reset the clock"
effect already happened when the frame was received).

---

## 8. Compression (kind 7)

Only in play if the Delphi side sets `CompressionMinSize > 0` (default: **off**). When on,
the sender compresses `Message`/`Request`/`Reply`/`Publish` frames whose payload reaches
the minimum **and** actually shrinks. If the server might have this on, your side **must be
able to decompress** kind 7. Your side is **never required to compress** — sending
everything uncompressed is always valid.

Payload format of a kind-7 frame:

```
[ origKind : 1 byte ][ origFlags : 1 byte ][ deflate(origPayload) : rest ]
```

- `deflate(...)` is **raw DEFLATE** (RFC 1951), the same that `zlib` produces with
  `windowBits = -15` / `Z_DEFLATE_RAW`. It is not gzip and has no zlib header.
- The kind-7 frame's `CorrId` is the original frame's `CorrId` (request/reply correlation
  and group-key hash pass through unchanged).
- After inflating you have `origKind`, `origFlags` and `origPayload` — treat it as if you
  had received that frame directly.
- **Zip-bomb protection:** stop inflating as soon as the decompressed total exceeds your
  cap (`MaxMessageSize`), during decoding, not just at the end.
- Only those four kinds are compressible. `Ping` has no payload;
  `Subscribe`/`Unsubscribe`/`Compressed` are structural.

---

## 9. Command envelope (`Pipes.Commands`) — application layer, optional

If the server uses `TPipeCommandRouter` to route by **command name**, the name goes inside
the payload of a `Message` (kind 0) or `Request` (kind 1) frame, with **the same layout as
the topic envelope**:

```
[ cmdLen : uint16 LE ][ command : cmdLen bytes UTF-8 ][ body : rest of payload ]
```

- `cmdLen` ≤ **255** (`PIPE_MAX_COMMAND_BYTES`).
- Command names are **case-sensitive**.
- This is **not** part of the transport — it is a convention agreed with whoever wrote the
  server. Nothing in the header tells "a kind 0 with a command envelope" apart from "a
  plain kind 0"; the server decides by the router it installed.
- On the `Request` side, an unknown command or an out-of-range payload becomes a `Reply`
  error (bit `0x01`), because the server turns any handler exception into an error.

---

## 10. Shutdown

- **Clean:** close the socket (FIN) on a frame boundary. The other side sees EOF and ends
  the session normally.
- **Abrupt:** RST, cable pulled, process killed. The other side sees a socket error or
  (with heartbeat) the liveness timeout. There is no "goodbye" frame.
- Do not send a partial frame and close — either the whole frame, or nothing.

---

## 11. Limits and defaults

| Item | Value | Note |
|---|---|---|
| Header | 20 bytes | fixed |
| Max payload | 16 MiB (default) | `MaxMessageSize` on the Delphi side; pick your own |
| Topic name | ≤ 255 bytes UTF-8 | `topicLen` is uint16 but never exceeds 255 |
| Command name | ≤ 255 bytes UTF-8 | same |
| Byte order | little-endian | all multi-byte fields, in every envelope |
| Text encoding | UTF-8 without BOM | |
| Request `CorrId` | uint64 != 0, unique among in-flight | |

---

## 12. Minimum checklist (request/reply client in another language)

1. Open a TCP socket to `host:port` (or TCP+TLS with SNI, if `ptTls`).
2. A "read exactly N bytes" helper looping over `recv`.
3. Read a frame: 20 header bytes → validate `Magic` → check `Kind ≤ 7` → read `Length`
   payload bytes.
4. Write a frame: build the LE header + payload, one `send`.
5. `Request`: generate a `CorrId` != 0, send kind 1, store `CorrId` in a pending table,
   wait for the `Reply` (kind 2) with the same `CorrId`; if bit `0x01`, it is an error.
6. Handle kind 0 (spontaneous messages from the server) and kind 3 (ping — just discard).
7. Close on invalid `Magic`, unknown `Kind`, `Length` above the cap, or EOF in the middle
   of a frame.

Pub/sub, heartbeat and compression only come in if the server uses them.

---

## 13. Examples (hex)

Each header line is annotated. `|` separates header from payload.

**Message (kind 0), payload `"hi"`, no group key:**

```
4E 50 46 31   Magic 'NPF1'
00            Kind = 0 (Message)
00            Flags = 0
00 00         Reserved
00 00 00 00 00 00 00 00   CorrId = 0
02 00 00 00   Length = 2
| 68 69       payload "hi"
```

**Request (kind 1), `CorrId = 1`, payload `"ping"`:**

```
4E 50 46 31 01 00 00 00  01 00 00 00 00 00 00 00  04 00 00 00 | 70 69 6E 67
```

**Reply OK (kind 2), `CorrId = 1`, payload `"pong"`:**

```
4E 50 46 31 02 00 00 00  01 00 00 00 00 00 00 00  04 00 00 00 | 70 6F 6E 67
```

**Error Reply (kind 2), `CorrId = 1`, Flags = ERROR, payload `"invalid command"`:**

```
4E 50 46 31 02 01 00 00  01 00 00 00 00 00 00 00  0F 00 00 00 | 69 6E 76 61 6C 69 64 20 63 6F 6D 6D 61 6E 64
```

**Subscribe (kind 4), filter `"store.#"`:**

```
4E 50 46 31 04 00 00 00  00 00 00 00 00 00 00 00  09 00 00 00
| 07 00                       topicLen = 7
  73 74 6F 72 65 2E 23        "store.#"
  (no body)
```

**Publish (kind 6, RETAIN), topic `"store.till1"`, body `"OK"`:**

```
4E 50 46 31 06 02 00 00  00 00 00 00 00 00 00 00  0F 00 00 00
| 0B 00                       topicLen = 11
  73 74 6F 72 65 2E 74 69 6C 6C 31   "store.till1"
  4F 4B                       body "OK"
```

**Ping (kind 3):**

```
4E 50 46 31 03 00 00 00  00 00 00 00 00 00 00 00  00 00 00 00
(no payload)
```

---

## 14. Read pseudocode

```
func read_exactly(sock, n) -> bytes:
    buf = []
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if chunk is empty:            # EOF
            if len(buf) == 0: raise CleanClose
            else: raise Truncated
        buf += chunk
    return buf

func read_frame(sock, max_payload) -> Frame:
    h = read_exactly(sock, 20)
    if h[0:4] != b"NPF1": raise OutOfSync
    kind  = h[4]
    if kind > 7: raise UnknownKind          # newer peer
    flags = h[5]
    corr  = u64_le(h[8:16])
    length = u32_le(h[16:20])
    if length > max_payload: raise TooLarge
    payload = read_exactly(sock, length) if length > 0 else b""
    if kind == 7:                            # compressed envelope
        orig_kind  = payload[0]
        orig_flags = payload[1]
        payload    = raw_inflate(payload[2:], limit=max_payload)
        kind, flags = orig_kind, orig_flags
    return Frame(kind, flags, corr, payload)

func write_frame(sock, kind, flags, corr, payload):
    assert len(payload) <= max_payload
    h = b"NPF1" + bytes([kind, flags, 0, 0]) + u64_le(corr) + u32_le(len(payload))
    sock.sendall(h + payload)                # a single send
```

---

## Appendix A — LAN server discovery (NPD1 protocol)

`Pipes.Discovery` is an **optional complement**, not a transport: no NPF1 frame travels
over it. It finds the server's `host:port` without a configured IP. If you do not need
automatic discovery, skip this.

- Transport: **UDP**, IPv4 only, default port **42517** (`PIPES_DISCOVERY_DEFAULT_PORT`).
- The client sends the **probe** by broadcast (`255.255.255.255:42517`); the server's
  responder replies by unicast to the source.
- **The server IP is the source address of the reply datagram** (`recvfrom`), never an IP
  embedded in the payload — that solves multi-NIC. The payload only carries the **port**.
- Strict lengths: a datagram with trailing bytes is rejected. A datagram that does not
  decode is dropped silently.

```
probe    = 'NPD1' + kind(1 byte)=1 + tokenLen(1 byte) + token[tokenLen bytes UTF-8]

reply    = 'NPD1' + kind(1 byte)=2 + tokenLen(1 byte) + token[tokenLen bytes UTF-8]
                  + servicePort(2 bytes LE)
                  + transport(1 byte: 0=ptLocal, 1=ptTcp, 2=ptTls)
                  + nameLen(1 byte) + name[nameLen bytes UTF-8]
```

- `token` ≤ 64 bytes UTF-8 (`PIPES_DISCOVERY_MAX_TOKEN_BYTES`); `name` ≤ 128
  (`PIPES_DISCOVERY_MAX_NAME_BYTES`).
- The responder only answers a probe with the correct `Magic` **and** a token identical to
  its own.
- The **token is not security** — it travels in the clear and only separates installs on
  the same LAN. What authenticates the server is `ptTls` on the NPF1 connection that
  follows.
- Discovery does **not** cross a router or a VPN (it is subnet broadcast). A remote client
  keeps using a configured IP + failover.

## Appendix B — Group-key hash (`CorrId` in `Message`)

The Delphi side's `SendBytes`/`SendText` accept an optional `AGroupKey: string`: messages
with the same key are delivered in order relative to each other even in the parallel
dispatch mode. The mechanism travels in the `CorrId` of the `Message` frame (kind 0),
which would otherwise be `0`.

You **do not need** this to interoperate — send `CorrId = 0` and your messages follow the
default behavior. Only implement it if you want to reproduce the by-group ordering.

The value is **FNV-1a 64-bit** over the key's UTF-8 bytes:

```
offset basis = 0xCBF29CE484222325
prime        = 0x00000100000001B3
hash = offset_basis
for each byte b in utf8(key):
    hash = hash XOR b
    hash = (hash * prime) mod 2^64        # silent wraparound
if hash == 0: hash = 1                    # 0 is reserved for "no group"
key == "" -> 0
```

A collision between two different keys is harmless (it only serializes messages that did
not need it; it never corrupts anything).
