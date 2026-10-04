# F8 (pascal-named-pipes-faa) — findings for pascal-common-faa

Migration of pascal-named-pipes-faa to pascal-common-faa v1.0.0, done 2026-10-04. Nothing in
pascal-common-faa was changed; these are the points to bring back. Most important first.

## 1. `migrating.md`: "drain your in-flight items in your own finalization, as before" is not enough for a dispatcher

**What happened.** Pipes' `PipeGroupDispatcher` (a `TPipeKeyedDispatcher` running on the global
pool) used to be freed in `Pipes.Threading`'s finalization AFTER the pool, which lived in the same
unit: the pool's `Destroy` ran the whole queue and joined the workers, so every
`TPipeMailboxDrainWork` had finished. After the migration the pool is `PcPool`, freed later (in
`PascalCommon.ThreadPool`'s finalization), so the order is reversed: freeing the dispatcher as
before is a use-after-free (a queued drain calls `Fetch` on a freed object) and drops the items
still pending in the mailboxes.

**Measured.** With the dispatcher's `Destroy` unchanged (no wait), the pipes unit suite's new test
(`KeyedDispatcher_DestruidoAntesDoPool_EsperaDrenagemEmVoo`) got 0 of 15 items run, the
finalization check got 0 of 5, and heaptrc reported 6 unfreed blocks. With the fix, 0 leaks and
all items run, on FPC Windows, FPC Linux, and 40 runs at `--cpus=1` with 8 containers at once.

**"As before" is wrong for pipes**: before, pipes didn't drain anything in its finalization — it
relied on owning and freeing the pool first. The phrase assumes the consumer already had its own
drain.

**What pipes did** (worth a paragraph in `migrating.md`, "Behavior to know about"): an object
whose work runs on `PcPool` and that is freed in the consumer's finalization must wait for its
own items itself, counting from **queue time** (not start time) until the work item's
**destructor** (not the end of `Execute`) — the destructor also runs when the pool frees an item
without running it, and it is the last access to the owner. Wait by polling an atomic counter,
not an event: with an event the last act of the work item would be a `SetEvent` on an object
the waiter may already be freeing. See `Pipes.Threading.pas` (`TPipeMailboxDrainWork.Destroy`,
`TPipeKeyedDispatcher.Destroy`) and `docs/ARQUITETURA.md` §15.4/§23.

**Possible follow-up (additive, 1.x):** none required. A helper ("in-flight counter" or a
`TPcWorkItem` base class whose destructor signals an owner) would only be worth it if amqp or
redis need the same thing in F8.

## 2. `migrating.md`'s `sed -i` recipe strips CRLF on Git for Windows

**What happened.** The rename `sed -i -E '...' <files>` from `migrating.md`, run in Git Bash on
Windows, rewrote every file with LF line endings — including files where nothing matched. With
`core.autocrlf=true` git shows no content change, but the working copy differs from a fresh
checkout (and git prints "LF will be replaced by CRLF" for every file).

**Fix in pipes:** `git checkout --` on files without real changes, `unix2dos` on the others;
later renames with `perl -pi -e`, which keeps CRLF.

**Suggestion:** in `migrating.md`, use `perl -pi -E` in the recipe (same regex syntax; `\b`
works), or add a line saying `sed -i` converts CRLF to LF on Git for Windows. Possibly a gotcha.

## 3. Delphi for Android is a consumer target that pascal-common-faa has not compiled for

pipes has a Delphi Android backend (`Pipes.Transport.Android`, suite `tests/Android`, verified
11/11 on a device before this migration). That unit now uses `PascalCommon.Threading`
(`PcAtomic*`, `PcTickMs`). pascal-common-faa's plan records Delphi Win32/Win64 only.

By reading the source, `PascalCommon.Threading` on Delphi non-Windows uses `System.Diagnostics`
(`TStopwatch`) and `TThread.GetTickCount64`, both present in the Android RTL, and the atomics are
the `Atomic*` intrinsics — nothing Windows-only. **Not compiled or run**: Delphi CE on this
machine doesn't build from the command line, Android is checked manually in the IDE + device.

**Suggestion:** state in the README/plan which platforms are verified (FPC x86_64/i386 Windows and
Linux, Delphi Win32/Win64) and that Delphi Android/ARM is a consumer target not yet compiled
there. The eager `PcPool` creation (no double-checked locking) is exactly what makes ARM safe, so
it's worth saying ARM is a reason for that decision.

## 4. Things that worked as documented (no action)

- `.lpk` requiring `pascal_common_faa` by name with `MinVersion Major="1"`, and test/sample
  `.lpi` listing it first with `DefaultFilename` into `external/` and `Prefer="True"`: lazbuild
  built all 2 test projects and 32 samples against the submodule copy (checked in the build
  logs; `pascal_common_faa` is not registered in this machine's IDE, and lazbuild didn't
  register it). pipes' test `.lpi` don't require pipes' own package (they use `src` as a search
  path); listing `pascal_common_faa` alone still works.
- The version check after the `uses` that brings in `PascalCommon.Version` (placed in
  `Pipes.Threading`, which every pipes unit that needs pascal-common-faa compiles): raising the
  minimum to 10001 stops FPC 3.2.2 with `Fatal: User defined: pascal-named-pipes-faa precisa da
  pascal-common-faa 1.0.0 ou mais nova`.
- 64-bit counters: every pipes target variable is `UInt64`, and a `var` parameter needs the exact
  type, so all calls bind to the `UInt64` overloads (FPC compiled them with no ambiguity; the
  Int64 overload can't bind a `UInt64` variable).
- `TPcThreadPool.Destroy` runs the whole queue: pipes' docs said the opposite in the old
  `Pipes.Threading` header and in a test comment; both fixed. The pipes test that relied on the
  old wording now asserts that every pending item ran.

## 5. Delphi confirmation

Delphi 12 CE, built in the IDE and run from the command line, 2026-10-04: Win64 and Win32,
unit 137/137 and integration 139/139, 0 leaks/failures/errors, finalization check silent. "Build
all" of `Pipes.groupproj` ok on Win32 and Win64, and `tests/Android` (Android64) compiled
against pascal-common-faa — so finding 3 is now "compiles for Android", not yet "runs on a
device".

Pipes-side pitfall, possibly worth a gotcha there since the finalization-check pattern comes
from pascal-common-faa: a unit with `finalization` and no `initialization` compiles on FPC 3.2.2
but Delphi rejects it (`E2029 Declaration expected but 'FINALIZATION' found`). A consumer
copying the "separate check unit" idea needs an empty `initialization`.
