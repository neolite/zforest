<!-- Devin correctness review: module identity / memory / loop safety — static pass over zefx/forest/zserver/zmeta/zdb + all five example apps. Static review of zforest + zforest-examples. -->

# Framework correctness review — zforest @ `edc1690` + zforest-examples @ `7cc2237`

Scope: `src/zefx/*.zig`, `src/forest/*.zig`, `src/server/*.zig`, `src/zmeta/*.zig`,
`src/db.zig`, `src/assets.zig`, `src/client.js`, and `../zforest-examples/src/apps/**`
(todo, board, mon, car, zmeta_demo) including checked-in `gen/*.zig`. Method: full
`@import` audit of both repos, targeted reads of every lifecycle/memory/loop path,
and cross-checks of the claims in `ARCHITECTURE.md` against current code. No source
was modified; no tests were run (static review only — build/test status unverified
in this pass).

## Critical

### C1. Unauthenticated remote crash: session-key buffer overflow panic

- **What**: `SessionStore.keyInto` builds the `(token, route)` lookup key into a
  fixed 320-byte stack buffer and `@panic`s when it doesn't fit
  (`src/server/http.zig:111-118`, `if (buf.len < n) @panic("session key buf too small")`).
  Both components are attacker-controlled: the cookie token is whatever the client
  puts in the `zfxs`/`zfxb` cookie (`cookieValue`, `http.zig:170-180`), and the route
  comes from the `x-zforest-route` header (`http.zig:289,301`), the `r` query param of
  `/events` (`http.zig:486`), or the request path (`http.zig:397-408`). The request
  head buffer is 8 KiB (`head_buf_len`, `http.zig:21`), so a ~300-byte cookie value or
  route string is ample.
- **Where reachable**: `SessionStore.lookup` (`http.zig:120-124`) is called from the
  POST `/action` precheck (`http.zig:306-312`), the POST main section
  (`http.zig:327-328`), every page GET (`http.zig:406-408`), and every SSE poll
  (`http.zig:509`). A request like
  `GET /` with `Cookie: zfxb=<300 chars>` reaches `lookup` after `validPath("/")`
  passes — no session need exist, no auth needed.
- **Why it matters**: `@panic` in any `std.Io.Group.concurrent` worker aborts the
  whole process — one packet kills the server for all sessions. This is a remote,
  unauthenticated, trivially scriptable DoS.
- **Fix direction**: bound the inputs before lookup — reject (400/403) cookie tokens
  and routes longer than a sane cap (e.g. token ≤ 64, route ≤ 256) — or make
  `keyInto`/`lookup` fall back to a heap-allocated key instead of panicking. Add a
  regression test posting an oversized `x-zforest-route`.

## High

### H1. Unbounded settle loop: `Engine.flush()` can spin forever while holding the server mutex

- **What**: `Engine.flush` drains `pure_queue` → dirty-store propagation →
  `sample_queue` → store notifications + `effect_queue` in a `while (true)` loop
  that only exits when *all four* queues are empty (`src/zefx/engine.zig:137-179`).
  There is no iteration cap. `drainQueue` (`engine.zig:94-100`) likewise processes
  thunks appended during the drain in the same pass, so a thunk that re-schedules
  itself never terminates either. Watchers that re-dirty a store re-queue it by
  design — a cyclic watcher/effect pair (or a store with `eq = null` that always
  "changes") produces an infinite flush.
- **Why it matters**: every flush runs inside `srv.mutex` — inside `dispatch`
  (`http.zig:325-360`), inside `syncPull`/`publishPending` on the SSE poll
  (`http.zig:507-570`), and inside page GET rendering (`http.zig:400-449`). One
  session whose graph cycles wedges the mutex: every other session's actions, page
  loads, and SSE polls block indefinitely. Accept-loop admission still works, so
  the failure is a silent full-server stall, not a crash.
- **Fix direction**: add a flush budget (e.g. N outer iterations / M thunk
  invocations per tick) and fail loudly — panic in debug, or surface an error and
  disable the offending session — rather than looping without bound. At minimum
  document that app reducers/watchers must be acyclic and convergence-bounded.

## Medium

### M1. Attributes and `.text` that *disappear* from the view never propagate — snapshot is not a full state dump

- **What**: `diffNode` only iterates the attrs present in the current view
  (`src/forest/view.zig:797-798`) and only calls `setText` when the resolved value
  is non-null (`view.zig:799-801`). `snapshotOps` has the same shape
  (`view.zig:892-903`). `Dom` therefore keeps tracking an attr/text forever once
  set, and `client.js`'s `applySnapshot` applies ops to the live DOM without
  clearing anything (`src/client.js:183-193`). An attribute or text binding that
  leaves the view entirely — instead of resolving to `null`/empty — emits no op on
  diff *and* no op on snapshot, so the client keeps it permanently.
- **Why it matters**: the documented contract is "every fresh SSE connection gets a
  full snapshot, which always resyncs the DOM" (`client.js:233-234`,
  `http.zig:463-466`). That is only true for attrs/text that still resolve — the
  dump is not actually complete. Today every app happens to declare attrs
  unconditionally with `null` for absent values, so this is a latent framework
  footgun rather than a live bug: two `el()` call sites producing different attr
  sets under the same `.id`/`.lid` silently diverge.
- **Fix direction**: either (a) diff attrs against the previous attr *set* and emit
  removals for vanished names (requires tracking attr-name sets per node, not just
  `id\0name` keys), or (b) document and enforce the "always declare, null to
  remove" rule — e.g. a comptime assertion or lint — and make `snapshotOps` emit
  explicit removals for attrs the Dom tracks but the view lacks.

### M2. `srv.mutex` is held across full page renders, SQLite access, and reactive flushes — not just bookkeeping

- **What**: the contract comment says the mutex is "NEVER held while doing network
  I/O" (`http.zig:154-157`), which is true — but it *is* held across arbitrary CPU
  and DB work: `s.dispatch(...)` runs the whole action → zefx flush → after-flush
  render → diff (`http.zig:345`); GET page handling runs `setQuery` +
  `serveApi`/`servePage` including `prepare`, view build, SSR write, diff-seed
  (`http.zig:400-449`); and every SSE poll runs `syncPull` → possible group
  render+publish (`http.zig:507-570`). Board page views read the shared model and
  group `seed()`/`render()` diff whole trees; `SessionStore.create` eviction runs
  `Session.deinit` (engine/dom/history teardown) inline (`http.zig:129-135`).
- **Why it matters**: latency and liveness are global — one expensive render or one
  pathological view stalls every session's requests and every SSE worker's poll.
  Combined with H1, the failure mode is a full stop. For a 32-session demo this is
  acceptable; it is not production-safe under load or adversarial view cost.
- **Fix direction**: shorten critical sections (lookup under lock, render outside
  where possible — e.g. compute view nodes under lock but serialize outside), or
  move to per-session locks plus a model lock for shared state. At minimum,
  document the global-stall property.

### M3. `keyStringInto`/`keyInto`-style fixed buffers panic on overflow — safe today only by an implicit length invariant

- **What**: `groups.keyStringInto` formats the render-group key into a 256-byte
  buffer and `@panic`s on overflow (`src/apps/board/groups.zig:234-251`); the
  session-key path has the same shape (C1). `anchorId` asserts ids contain no `--`
  (`src/forest/view.zig:640-644`). For board the name component is bounded by
  `max_account_name_len` (`entities/accounts.zig`, tested at
  `accounts.zig:263-264`) and anon names are server-generated, so 256 bytes is
  currently unreachable — but nothing in `keyStringInto`'s contract enforces that;
  a future app or a longer account name turns it into the same crash as C1.
- **Why it matters**: same panic-under-mutex failure mode as C1, currently masked
  by an invariant that lives in a different file.
- **Fix direction**: size the buffer from the actual maxima or return an error;
  document the name-length precondition on `Key.name`.

## Low

- **L1 — Live mode does not track keyed-list structure.** `bindTree`/
  `bindIslands` subscribe leaves inside `.keyed` children
  (`src/forest/view.zig:1239-1242`, `1444-1447`) but row create/remove/move emits
  nothing — a live-bound `eachOf` silently goes stale on structural change. zmon
  avoids `eachOf` in live subtrees today; document the restriction or reject
  `.keyed` under live binding.
- **L2 — `Dom.orders` entries survive `removeTracked`.** `removeTracked`
  (`src/forest/dom.zig:310-357`) cleans texts/attrs/when_states/bindings but not
  `orders`, so a nested keyed list inside a removed subtree leaves a stale order
  record. Harmless while row ids are never reused (board/todo ids are monotonic);
  id reuse would diff against phantom order → wrong ops → DOM desync until the
  next snapshot. Fix: prefix-scan `orders` in `removeTracked`.
- **L3 — `db.zig` null/close semantics.** `columnText` returns `""` for SQL NULL
  (`src/db.zig:133-138`) — indistinguishable from empty string; `sqlite3_close`'s
  result is ignored (`db.zig:166-171`), so unfinalized statements fail the close
  silently; `Stmt.finalize` is manual (`defer` discipline in apps is currently
  correct — verified in `todo/store.zig` and `board/entities/model.zig`). Consider
  `columnIsNull` and checking the close rc.
- **L4 — Session cookie hardening.** The session cookie is
  `HttpOnly; SameSite=Strict; Path=/` with no `Secure` and no rotation on
  "login" (`http.zig:445`). Fine for the localhost demos; flag before any
  non-local deployment. `sameOrigin` compares host only, ignoring scheme
  (`http.zig:189-194`).
- **L5 — `statusOf` masks errors.** Unknown dispatch errors (including OOM)
  map to 400 (`http.zig:236-241`) — acceptable for a demo, confusing in
  production logs.
- **L6 — `applyPatch("create")` keeps only `firstElementChild`**
  (`src/client.js:55-58`). Server `create` ops are always single-root today;
  a multi-root or text-leading payload would be silently truncated.
- **L7 — `zmeta` api env staleness.** `serveApi` runs before `servePage`, so
  `Env.route` still holds the previous page route during api dispatch
  (`http.zig:423-434`, `session.zig:305-308`). Api handlers that read
  `env.route` see stale data.
- **L8 — `trackGraphAlloc` is append-only for engine lifetime**
  (`src/zefx/engine.zig:191-193`). Graph units created mid-session accumulate
  until `Engine.deinit`; fine for build-once graphs, unbounded for dynamic ones.
- **L9 — Algorithmic bounds.** `Dom.findBinding` is O(#bindings) per leaf per
  render; `syncKeyedList`'s displacement scan is O(n²) worst-case
  (`dom.zig:408-433`); `diff`/`writeNode`/`seedNode`/`snapshotOps` recursion depth
  equals view-tree depth (app-controlled). All fine at demo scale; note before
  deep/large views.
- **L10 — Live→non-live route switch retains `live_arena`.** `servePage` resets
  `live_arena` only on the live path (`session.zig:328-346`); switching to a
  diff page leaves the old tree allocated until next live visit or deinit.
  Bounded, cosmetic.

## Verified-OK areas

- **Module/type identity (diamond problem): clean.** Audited every `@import` in
  both repos. All framework crossings are named modules (`zefx`, `forest`,
  `zserver`, `zmeta`, `zdb`, `zassets`); every relative import stays inside its
  own module root (`zefx/*` siblings, `forest/*` siblings, `server/*` siblings,
  `zmeta/*` siblings) or inside the app dir. Generated `gen/routes.zig` uses
  named `forest` + the app-local `zmeta.zig` shim, which itself re-exports the
  named `zmeta` module (`src/apps/*/zmeta.zig`) — one type instance. Framework
  `build.zig` exposes each framework type via `addModule` + `imports`; examples
  `build.zig` consumes the *same* `*Module` objects via `dep.module(...)`, so
  `History`/`Dom`/zefx/forest cannot compile twice. `zdb`'s `sqlite3.c` is
  attached once to the `zdb` module (`build.zig` `addSqlite`), imported only by
  the sqlite exes — no double C linkage. `gen`/`new-app` tool modules root at
  `dep.path("src/zmeta/*.zig")` but are std-only (verified: `gen.zig`/`scaffold.zig`
  import only `std`), so they instantiate no shared types. `zmeta/root.zig`'s
  named-import claim holds: `session.zig:154` takes `History` from `@import("zserver")`.
- **Memory/lifecycle:** `PatchLog` dupes every op string into its own arena
  (`patch.zig:101-112`) — render-arena scratch can reset freely. `Dom` owns all
  tracked keys/values on `gpa` and frees them in `deinit`/`removeTracked`
  (`dom.zig:54-82,310-357`). Live islands deep-copy subtrees into binding-owned
  arenas (`view.zig:1272-1308`); binder `destroy` unsubscribes + frees
  (`view.zig:1115-1128`); `Session.deinit` orders `Deps.deinit` → `dom.deinit`
  (drops bindings while the engine is alive) → arenas → `app.deinit`
  (`session.zig:236-248`). `History` entries are gpa-owned, fetches are per-
  subscriber dupes, `cloneDeep` is a true deep copy (`history.zig:34-112`).
  Route/query strings are session-owned dupes (`session.zig:262-285`).
- **zefx lifecycle:** generational `Subscription{index,generation}` handles make
  stale unwatch a no-op; notifier iteration snapshots slot arrays so callbacks
  may watch/unwatch mid-dispatch; `assertSameEngine` blocks cross-engine edges;
  `trackGraphAlloc` dtors run at `Engine.deinit`; `flushing`/`batch_depth` guards
  make reentrant `flush()`/`batchEnd()` correct.
- **Server transport:** mutex is never held across socket writes or sleeps —
  `writeChunk`/`std.Io.sleep` run outside the lock (`http.zig:575-584`); POST body
  is read before the lock (`http.zig:314-321`); SSE workers retain no session
  pointer across polls, detect evict+recreate via `incarnation`
  (`http.zig:510-516`), and force a snapshot on `membershipEpoch` change
  (`http.zig:538-547`); `History.fetch` returns `.gap` → snapshot rather than
  silently skipping batches; session cap 32 FIFO + conn cap 128 pre-header are
  enforced (`http.zig:658-662`).
- **SQLite:** every app `prepare` is paired with `defer st.finalize()`
  (verified across `todo/store.zig`, `board/entities/model.zig`); `SQLITE_TRANSIENT`
  is correct (`db.zig:23-24`); `SQLITE_OPEN_FULLMUTEX` + `THREADSAFE=1` serializes
  C-level access; `zdb` is linked only into the sqlite exes.
- **Render groups:** `join`/`fork`/`leave` are member-counted and mutex-serialized;
  `fork` clones Dom+history verbatim and continues rev lineage so the forking
  client's cursor stays valid (`groups.zig:322-337`); `seed()` diffs against an
  empty Dom and discards ops so tracked state matches without publishing;
  `membership_epoch` bumps only on stream-incompatible transitions
  (`app.zig:779-804`); group key encoding is injective and tested
  (`groups.zig:363-381`).
- **Codegen:** `parseRoute` gives static segments precedence over dynamics,
  bounds the segment buffer while still counting deep tails for catch-alls, and
  404s on int-parse failure (`gen.zig:1030-1111`); the action manifest produces a
  comptime-checked whitelist (`gen.zig:1259-1284`); middleware runs
  outermost-first before page `prepare`; `pages/api/` dispatches separately with
  no layouts/middleware.

## Verified-safe summary

- **Diamond problem / module identity: VERIFIED CLEAN.** No Zig type can compile
  as two instances in any exe — named-module wiring is consistent across
  framework build, examples build, generated code, and app shims.
- **Arena discipline: SOUND.** All cross-arena hazards checked (PatchLog strings,
  Dom tracked state, island copies, binder captures, live vs render arenas,
  history entries, route/query ownership) are correctly owned or duped. Two
  bounded exceptions noted as Low (L2 stale `orders`, L10 retained `live_arena`).
- **Loop/termination: MOSTLY BOUNDED, ONE REAL GAP.** Transport loops are bounded
  (history 64/2 MiB, sessions 32, conns 128, SSE poll 50 ms + heartbeat, FIFO
  eviction). The reactive settle loop (`Engine.flush`) and self-appending
  `drainQueue` thunks are **unbounded** — H1 is the one finding that can hang the
  entire process without any bound.
