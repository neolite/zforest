<!-- Astra (gpt-6-astra) review: what to add to zefx Session: 01a1d46b-f8b9-7390-ba1a-7f4abe7efe9e — follow-up to the two-tier review. Summary recorded in ARCHITECTURE.md "Astra review: what to add to zefx".  -->

**My top three: make `sample` reliable, add explicit batching, then add equality-aware store updates.** These address concrete problems in today’s apps. `attach` comes next; async execution and detachable graphs should wait for a demonstrated requirement.

This is a static source review of all seven `src/zefx/*.zig` files, the architecture notes, and the apps’ update paths. I did not run tests or change files.

Two implementation details materially affect the ranking:

- **`sample` is less complete than its advertised API.** `MakeWire.run` discards the clock argument; event sources produce `undefined`; clock-only payload forwarding has no correct value path; source-only shapes get no subscriptions. Effect targets are treated as events and receive `.emit`, whereas `Effect` exposes `.run`. Filters already exist. See [sample.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/sample.zig:73).
- **zmon currently flushes repeatedly within one refresh.** `refreshStores()` performs 13 top-level `.set()` calls, each auto-flushing, followed by `ping.emit()`. Thus one refresh can execute 14 flushes and after-flush hooks—not necessarily 14 SSE batches, because publication happens elsewhere. See [mon_app.zig](/Users/rafkat/Apps/tmp/zforest/src/mon_app.zig:211) and [store.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/store.zig:60).

| Candidate | Problem it solves here | Cost and recommendation |
|---|---|---|
| **Reliable `sample`, including filters and effect targets** | Lets zcar combine vehicle/cart state with submitted contact data; makes event → sample → effect usable without accessing reducer arrays or using watchers for orchestration. | **Medium; first.** Repair existing semantics before adding operators. |
| **Explicit batching** | Lets zmon ingest one complete snapshot, update its revision, settle, and notify once. Useful for future multi-event form updates. | **Medium; second.** Nested, synchronous batches with one outer flush. |
| **Equality-aware store updates** | Avoids repeated derived propagation and live-binding work for unchanged zmon controls/status; suppresses unchanged todo `remaining` notifications. | **Medium; third.** Must cover every update path and respect value lifetimes. |
| **Engine ownership validation** | Prevents accidentally connecting zboard’s shared state graph to a session graph through ordinary operators. | **Small–medium; include immediately with operator work.** Validate every input, target, and store-shaped field. |
| **`attach`** | Captures zcar’s selected vehicle/cart alongside booking parameters; later supports session-specific credentials or configuration without store reads inside handlers. | **Small–medium after sampling is fixed; next.** Useful ergonomics, little immediate benefit to existing apps. |
| **Debounce/throttle** | Useful for future input validation/search, or controlling zmon display refresh frequency under higher input rates. | **Medium with a host clock; otherwise large. Defer.** Current zmon already refreshes around its 10 Hz producer cadence. |
| **Async effect execution** | Enables actual remote booking/validation and keeps slow work outside graph execution. Could support future board persistence work. | **Large; defer until an app needs it.** Requires ownership, completion delivery, cancellation, and server integration. |
| **Detachable edges / scoped graph lifetime** | Enables dynamic per-item graphs that can actually release memory. | **Large; defer.** Current session-lifetime graphs and sparse item UI state avoid this requirement. |
| **More domain/factory wrappers** | Saves some repeated constructor syntax. | **Small implementation cost, ongoing API cost; skip.** `BoundDomain` already covers this. |
| **Dirty-only watcher dispatch and instrumentation** | Reduces full-graph scanning for sparse updates; measures work per refresh. | **Small–medium; instrumentation soon, scheduling optimization after measurement.** |

**1. Make sampling a trustworthy graph boundary.**

I would implement a deliberately limited, explicit contract:

- Clock-only sampling forwards the clock payload.
- Store/shape sources can be combined with the clock payload in the transform and predicate.
- Targets distinguish stores, events, and effects.
- Unsupported configurations fail at compile time rather than installing inert wiring or producing `undefined`.
- Every connected unit belongs to the same engine.

For event sources, either implement “latest source event value, with an initialized flag” properly or reject that form initially. Supporting a smaller correct API is sufficient for these apps.

There is also a scheduling issue beyond payload handling. Sampling currently installs an ordinary reducer on the clock. Its source read therefore depends on reducer registration order, and a derived source may not yet have settled when sampling runs. The existing engine guarantees settled state **for watchers**, not automatically for every sampling read. See [engine.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/engine.zig:91).

Define sampling to observe the intended post-reducer, settled source state, and test registration-order independence and derived-source diamonds. That may require a separate scheduling priority. Simply adding a two-argument callback does not solve it.

This matters most for zcar if its current imperative vehicle cascade becomes store-based: booking should see the final vehicle, cart and validity state. Today those fields are ordinary session data, so this is enabling infrastructure—not a claim that zcar already exercises these operators. See [car_app.zig](/Users/rafkat/Apps/tmp/zforest/src/car_app.zig:346).

**2. Add a synchronous batch boundary with defined reentrancy.**

The immediate consumer is zmon: wrap snapshot ingestion and revision advancement in one boundary, then settle and notify once. Its live bindings should observe a complete refresh instead of successive partial field updates.

Required semantics:

- Nested batches flush only at the outer boundary.
- Events retain their order and multiplicity.
- No watcher or after-flush render runs halfway through the batch.
- Borrowed payloads remain valid until that outer flush completes.
- Reentrant `flush()` cannot recursively drain the same queues.
- After-flush emissions have an explicit policy; they must not accidentally recurse through hooks.

Keep existing auto-flush behavior outside batches. Do not expose “temporarily set `phase = .pure`” as the public batching API.

This is **notification batching, not rollback or a database transaction**. Todo and zcar already apply most actions through one mutation event; they gain less immediately. Board’s `global_seq` polling already skips unchanged revisions, so batching does not replace its cross-session delivery mechanism. See [board_app.zig](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:176).

Acceptance evidence should include one zmon refresh producing one hook invocation, with watchers seeing the complete snapshot.

**3. Add equality policies at the common store-write boundary.**

Changing only `Store.set()` is insufficient. `.on`, `.reset`, `.map`, and `combine` write `value` and call `markDirty()` directly. They must share the same equality policy. See [store.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/store.zig:151) and [root.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/root.zig:437).

I would use straightforward equality for scalar values, explicit comparators for compound values, and an explicit always-notify option. Avoid automatic deep equality for arbitrary Zig types.

**zmon’s strings make this less trivial than it looks.** `refreshStores()` resets `fmt_arena` before replacing the old store slices. Comparing old and new contents after that reset is invalid: old backing storage may already have been reused. Keeping an “equal” old slice can also retain expired storage. Scalar dedupe can ship first; string dedupe needs stable ownership or comparison before the old storage is retired.

Benefits are primarily avoided recomputation and binding callbacks. DOM tracking already suppresses many unchanged operations. Also, equality suppression alone will not eliminate todo’s full render: its revision still advances and the after-flush hook still runs.

**What I would add afterward**

`attach` should be a small composition over the repaired sampling/effect machinery: snapshot dependencies when the invocation is accepted, map them with call parameters, then pass explicit parameters to the handler. Avoid a separate dependency-injection framework. `shape.readSnapshot` already supplies much of the structural machinery in [shape.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/shape.zig:38).

For timers, keep time supplied by the host and make tests use a fake clock. Define leading/trailing behavior, cancellation and retained-payload ownership. Prefer throttling or periodic latest-value sampling for continuously active dashboard data: trailing debounce can postpone delivery indefinitely. Server debounce also does not reduce incoming browser POST traffic.

For async effects, add an **executor interface**, not threads inside every engine. The host runs owned jobs outside the server mutex and delivers owned completions back through the session’s serialized execution path. Necessary contracts include request IDs, session-generation checks, bounded queues, stale-result handling and `inFlight`-derived `pending`.

Today, handlers already run from an effects queue inside `flush`; moving them to an after-flush hook would still block the caller. Request dispatch holds the server mutex, so actual offloading requires host integration. See [effect.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/effect.zig:30) and [http.zig](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:286). Board writes currently happen directly in `BoardModel`, so an async zefx API alone would not accelerate them.

Detachment should eventually cover reducer handles, notifier removal, queued-work invalidation, cleanup removal and hooks. Unlinking a reducer is insufficient because `Event.emit()` copies its raw context into queued work. Existing generational watcher handles solve observer removal, not graph disposal. See [event.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/event.zig:106).

A smaller addition worth considering first is a typed context-aware reducer registration API: all four apps currently manipulate `.reducers.append` directly. It would centralize ownership checks without promising detachable graphs.

**What not to build now**

- Full Effector compatibility, more aliases, domain hierarchies, or a factory framework.
- Cross-engine `sample`/`combine` edges; keep revisioned shared-model delivery outside ordinary graph wiring.
- Per-item reactive cells before complete disposal semantics; retain sparse item UI state.
- A built-in thread pool, timer thread per engine, or general async workflow framework.
- Debounced SQLite writes without explicit durability and ACK semantics. Board currently writes before publishing its mutation.
- HTTP/SSE revisions, DOM lifecycle, shared-model polling or persistence policy inside zefx.
- Automatic deep equality or generic deep-copying of arbitrary payloads.

The architecture instructions require recording this discussion in [ARCHITECTURE.md](/Users/rafkat/Apps/tmp/zforest/ARCHITECTURE.md). I could not append it because this session’s filesystem is read-only.
