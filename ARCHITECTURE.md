# Architecture decisions

Durable record of design discussions and their outcomes. Update this file
whenever an architecture question is debated — context windows are lossy,
this file is not. Rule: **any discussion about reactivity granularity,
state ownership, lifecycle, or transport semantics gets summarized here.**

## What this is (honest naming)

Server-authoritative UI: the server owns model + view, the browser is a
thin generic patch renderer (`client.js`) plus delegated `data-on-*`
events. Transport: SSR HTML → SSE `snapshot` → `patch` batches `{rev,ops}`
→ POST `/action` ACKs. Sessions are random-cookie keyed, capped at 32.

**Two rendering modes, one view description.** The default is
VDOM-style reconciliation: `buildView` rebuilds a full declarative
`Node` tree per flush; `forest.diff` compares it against `Dom` tracked
state and emits minimal DOM ops (todo, board). The opt-in **live mode**
(`forest.bindTree`, used by zmon) builds the tree ONCE per session and
subscribes every bound leaf (`.text`, attrs, `variant`/`when` keys)
directly to its store: a store notification re-resolves the `Bound`
thunk and emits the matching patch op — no rebuild, no tree walk.
Both modes share SSR (`writeHtml`) and snapshot (`writeSnapshotOps`)
output, so there is no hydration mismatch either way.

Live mode scope: leaf bindings and boolean `when` branches. Keyed lists
and multi-key variants remain structural — the tree is walked as
built, so live sessions need a stable structure. Sessions that need
structural reactivity stay on the diff path (or hybrid: diff for
structure, live for leaves — not yet combined).

## Reactivity model (zefx)

- One reactive graph **per session**, not per item. Events/stores/effects
  with pure-phase reducers → derived settle loop → watchers → after-flush
  hooks (which run the DOM diff into `PatchLog`).
- Per-item reactive cells were analyzed and **deferred**: `trackGraphAlloc`
  is append-only (no untrack), `registerStore` keeps raw pointers forever,
  event reducer edges outlive reducer contexts, queued thunks can't be
  canceled. Safe detachable graphs need engine surgery first.
- **Sparse `ui_state`** is the chosen per-item mechanism: an
  `AutoHashMapUnmanaged(id, ItemUi)` where *absence = default state*.
  Entries exist only for active items (e.g. a todo being edited). No
  reactive objects, no subscriptions, O(active) memory. Mutations go
  through the normal action → `ping` → flush → diff pipeline.

## Live-update invariant

**Every dynamic value must be bound** — `.id`/`.lid` on the element plus
`.text`, an attr, `.value`, `computed(...)`, or membership in a keyed
(`each`/`eachOf`) or conditional (`variant`/`when`) structure. Unbound
content is invisible to `diff`: it renders once and silently goes stale
until the next snapshot. When adding a feature, ask: "if this changes on
the server, does it have a bound id?" Regression coverage:
`board_app` test "syncPull re-renders only when global_seq moved" plus
the live counter patch (`post-N/go` text op) verified end-to-end.

Cross-session fan-out (board): mutations bump `BoardModel.global_seq`;
each SSE worker's `syncPull()` re-renders when it moved. `seen_seq` is
synced inside `buildView` — every shipped view (SSR, snapshot, diff)
marks the session caught up.

## Keyed lists

`Dom.syncKeyedList(log, arena, parent_id, ids, htmlFor, ctx, created)`:
- `htmlFor` is a lazy callback invoked **only for real creates** —
  existing rows never serialize HTML.
- Remove pass uses a wanted-id set (O(N)); move/create pass is a
  single left-to-right scan emitting `create`/`remove`/`move` ops.
- Newly created rows are seeded (`seedNode`) so the next diff emits only
  real changes; snapshots ship full keyed-parent `html` ops.

## Optimization passes (done)

- `cc0f653`: skip row HTML serialization for existing keyed children.
- `0134ca8`: getPtr-first Dom mutations (no dupe/free churn on unchanged
  bindings), lazy `htmlFor` + O(N) wanted-set in `syncKeyedList`,
  memcpy `resolvedId`, per-row shared id strings in both apps.

## Session model: route-keyed (done)

**Problem:** one browser = one session cookie, but tabs can sit on
different routes (`/b/meta`, `/t/36`). A single session had ONE
`route`/`dom`/`history`, so the last page load won and every tab
received patches for that one view — the other tab's DOM lacked the
target ids (`comments` missing on `/b/meta`) and silently never updated.

**Fix:** sessions are keyed `(cookie token, route)` in
`SessionStore.by_key` (`token\x01route`). Route arrives via
`?r=<path>` on `GET /events` and `x-zforest-route` header on
`POST /action`; page GETs key by the request path. The cookie token
itself stays stable per browser (minted once). Each route-session has
its own graph/dom/history/reply_to — which also fixed `reply_to`
leaking across threads.

**Cross-route fan-out unchanged:** the board `BoardModel` is shared;
every route-session's `syncPull()` sees `global_seq` move and re-renders
its OWN route's view, so a comment posted on `/t/36` still patches the
counter on every `/b/*` tab. Verified: two SSE streams, same cookie,
different `?r=` — thread stream got the `create` op, board stream got
the counter `text` op.

**Cost:** session cap counts (token, route) pairs — one browser with N
open route-tabs holds N sessions. Cap is 32 (FIFO evict →
`session_expired` → client reloads).

## Live bindings (done — zmon)

`Bound.live` is populated by `bindGet`/`computed` whenever the source
store exposes the watch contract (`watchCtx`/`unwatch`/`Value` — zefx
`Store` qualifies; plain `get()`-only fakes get `live = null` and stay
diff-resolved). `forest.bindTree` walks the built tree once and, per
bound leaf, allocates a `Binder` (Dom-owned, gpa) that calls
`store.watchCtx`. On notify — which runs in the engine's effects phase
after derived stores settle — the binder re-runs the Bound thunk and
emits `dom.setText`/`setAttr`/`setWhen` straight into the session
`PatchLog`; the existing publish path ships the batch unchanged.

- `variant`/`when` keys bind too: a key change emits one `when` op with
  re-serialized branch markup, `removeTracked(anchor, keep=self)`
  unsubscribes inner bindings while preserving the key binder, then the
  branch is re-seeded and re-bound — mount/unmount is live.
- `Dom.bindings` is a flat list dropped by the same `id`/`id/…` prefix
  rule as texts/attrs/when_states, so `removeTracked`, `Dom.reset` and
  `deinit` unsubscribe everything (dom.deinit MUST run before the
  stores' engine deinit — session order already guarantees this).
- Revision stamping stays in an engine `onAfterFlush` hook
  (`log.revision = seq.get()`); live emits happen during notify, before
  the hook — one batch per flush, `rev` always current.
- `computed(store, f)` propagates `live` from the source store; the
  watcher re-runs `f` on every notification, so derived formatting is
  live for free. zefx `Store.map` derived stores feed `variant` keys.

Verified live: one SSE patch batch carried `text` ops for every changed
card plus `when` ops swapping the HEALTHY/DEGRADED pill — zero view
rebuilds after the initial bind.

zmon also exercises attr bindings and two-way control: SVG sparkline
`points` attrs are live leaves (`attr` ops, `points` added to the
client whitelist), and range sliders POST `ctl_*` actions that mutate
shared model params (`rate_pct`/`err_bp`/`lat_pct`) — the next tick
reads them, so UI controls steer the synthetic traffic itself.

## Deferred / future

- Per-item reactive cells — blocked on detachable graph lifecycle
  (untrack, unregisterable notifiers, queued-work cancellation).
- Dependency-tagged subtree skip (skip unchanged branches of the view
  rebuild) — needs explicit dep maps; manual deps are a bug source.
- Live-mode structural reactivity — keyed lists (`eachOf` bound to a
  store → per-subtree `syncKeyedList`) and multi-key variants; needs
  bind/unbind on row mount/unmount plus ordering guarantees.
- Hybrid mode — diff for structure + live leaves in one session.
- Client-local derived primitives (`data-chars` counter) — generic only,
  server stays source of truth.
- Persistence effects (debounced/batched SQLite writes) — needs
  durability/ACK/retry/shutdown semantics designed first.
- Todo drag&drop reorder — model needs an order field; `move` patches
  already exist.

## Where the reactive graph earns its keep (discussion)

Direct render-on-mutate suffices for todo/board today; the zefx graph
pays off for: optimistic actions with rollback (pending→confirmed/
failed via events+effects), live dashboards with derived aggregates
(only changed branches recompute), high-frequency streams
(sample/throttle before render), complex multi-field forms
(combine-derived validity), and future per-item reactive cells.
Caveat (updated): the win is now at BOTH layers — zmon's live bindings
skip the rebuild+diff entirely for leaf updates; the diff path remains
for structural changes and for apps that haven't opted into live mode.

## Cross-project: server UI over a shared document (kulman probe)

Prototype `kulman-gui/packages/kulman-bim-model/tools/bim-ui-stand.ts`
(validated the pattern, not committed upstream): a standalone Node/tsx
server holding one immutable `KulmanBimModel` + revision, synthetic
domain mutations every ~900 ms (`section-group/update` transactions +
patch-level renames), per-session cookie selection, and server-rendered
HTML regions pushed over SSE. Client is ~60 lines: `innerHTML` swaps per
region id — no framework, no WS, no client state.

Mapping to our stack: `KulmanBimModel.revision` ≈ `model.seq`;
`BimModelPatchTransaction` ≈ mutation event; region-HTML-over-SSE ≈
Turbo-Streams-style fragments (coarser than our DOM ops — a real port
would diff the view tree like `forest.diff` does). kulman-gui's real
`bim-model-sync` WS gateway already does document sync with CAS +
write-behind Postgres + presence; the missing piece it does NOT have is
server-rendered UI — React owns all rendering there. If server-driven
panels (properties/history/ops log) are ever wanted inside kulman, this
stand shows the shape: subscribe `BimSyncCommittedListener`, keep a
per-session view state, render regions, push on commit.

## Astra review: two-tier graph + snapshot catch-up bug (2026-11)

Consulted gpt-6-astra on the "global stores + per-session projections"
design. Verdict: **sound, but not as direct cross-engine edges** — two
independently scheduled graphs joined by a *revisioned subscription
module*; global commits enqueue session work, never render synchronously.
`sample`/`combine` edges must stay inside one engine (they install
reducer contexts without ownership checks — mixed-engine wiring leaves
dangling contexts / skipped flushes).

Key contracts she defined:
- Two revisions: global (committed shared state) and session (contiguous
  published batches). Relax "one batch per global rev" to "one coherent
  batch per session update incorporating one complete global revision" —
  coalescing 40→45 must not mix fields from different revisions.
- Back-pressure: one pending-work record per session (latest rev +
  accumulated invalidations); coalesce before DOM binding execution —
  `Engine.flush` scans every registered store and `Store.set` does not
  suppress equal values, so M×K leaf subscriptions would tax commits.
- Lifecycle: detachable *subscriptions* are fine before detachable
  graphs (generational watcher handles exist); queued deliveries must
  own payloads — `Event.emit` copies values, not slice backing memory.
- Session = (cookie, route), NOT tab — two tabs on one route share
  reply_to/DOM/history today.

### Bug found and fixed

`serveEvents` wrote the initial SSE snapshot WITHOUT `syncPull`: the
snapshot reads the current shared model and `buildView` advances
`seen_seq`, but session DOM/history stay behind — the transition is
skipped forever and later diffs compute against stale tracking (wrong
ops for `when`/keyed/remove; client logs errors, rev still advances).
Fixed: `syncPull` + history publish now run before the snapshot branch,
under the same mutex — "catch up, reconcile, publish, then capture
snapshot and cursor".

### Other findings (not yet addressed)

- Attr protocol parity: server emits arbitrary attrs, client.js
  whitelists a small set — live `data-x` test attrs are ignored by
  browsers; client patch failures log but revision still advances.
- Hybrid live+diff invariants: `Dom.findBinding` matches only
  kind+id+attr (store A→B rebinding leaves stale subscription);
  `Binder.variant_nodes` borrows render-arena branch trees (lifetime
  bug on arena reset); `removeTracked` misses nested keyed-list orders
  and absolute descendant IDs escape prefix cleanup; `when()` eagerly
  evaluates — it is NOT a live condition binding (only `variant` is).
- Board projection costs: `childIdx` scans all comments per node —
  parent/post indexes beat notification-mechanism changes.
- `Effect.run` executes synchronously inside flush; `Store.set` does
  not dedupe equal values.
- Client-local primitives: worthwhile but fixed vocabulary only, explicit
  ownership (local counter owns its text; server never patches it).

Priority order she gave: (1) snapshot/revision correctness + protocol
parity, (2) engine ownership/transaction semantics, (3) binding
lifecycle, (4) projection delivery, (5) package interfaces. First
milestone: correct snapshots + revisioned dependency-aware projections
while KEEPING diff rendering — before hybrid rendering.

## Astra review: what to add to zefx (2026-11)

Top-3 ranked: (1) make `sample` a trustworthy boundary, (2) explicit
synchronous batching, (3) equality-aware store writes. `attach` next;
async effects and detachable edges deferred until a real requirement.

Concrete defects she found in current zefx:
- `sample` is advertised but incomplete: `MakeWire.run` discards the
  clock payload; event sources yield `undefined`; clock-only forwarding
  has no value path; source-only shapes get no subscriptions; effect
  targets receive `.emit` though `Effect` exposes `.run`; source reads
  happen as ordinary clock reducers → may observe unsettled derived
  state (settle guarantee covers watchers only).
- zmon `refreshStores()` does 13 `.set()` + `ping.emit()` per refresh —
  each auto-flushes → ~14 flushes/hooks per tick.
- `Store.set` not deduping is only half the story: `.on`/`.reset`/`.map`/
  `combine` write value + markDirty directly — equality policy must live
  at the common write boundary. String values need care: zmon resets
  fmt_arena before replacing slices, so old-vs-new comparison can read
  reused storage.

Design contracts for batching: nested batches flush at outer boundary
only; events keep order/multiplicity; no watcher/after-flush mid-batch;
borrowed payloads valid until outer flush; reentrant flush() cannot
recursively drain; after-flush emissions need explicit policy. It is
notification batching, NOT rollback/transaction.

Sampling contract she wants: clock-only forwards payload; store/shape
sources combine with clock in transform+predicate; targets typed
(store/event/effect); unsupported configs fail at COMPILE time;
same-engine validation on every input. Event-source "latest value"
semantics either implemented properly or rejected initially.

Also recommended: engine-ownership validation shipped WITH operator
work; typed reducer-registration API (all 4 apps currently
`.reducers.append` by hand); dirty-only watcher dispatch + instrumentation
before scheduling optimization.

Explicitly NOT to build: Effector compat/aliases/factories, cross-engine
sample/combine edges, per-item cells before disposal semantics,
built-in thread pools/timer threads, debounced SQLite writes without
durability+ACK, HTTP/SSE/persistence inside zefx, automatic deep
equality.

## Astra review: model layer + async (2026-11)

**Models: application-level factories, NO new runtime in zefx.**
`Session` stays lifetime owner but is too broad — extract `CarModel`
(engine + model, no HTTP/Forest). Model owns invariants/calculations/
validation; effect handlers are injected deps; Session owns engine,
DOM/history/arenas, cookies/CSRF, wire→event translation. Plain Zig
constructor suffices — `Domain`/`BoundDomain` add no lifecycle value.
Correction to our assumption: todo items are ALSO plain
ArrayListUnmanaged — only seq/remaining are stores. Rule: "stores for
values in reactive decisions/projections; explicit ownership + defined
notification path for the rest; visible-in-UI alone ≠ must-be-store".

zcar target shape: events brand/model/year/serviceToggled/serviceAdded/
bookingSubmitted; `$vehicle` = ONE aggregate {brand?,model?,year?}
(selection is user choice, options are derived — atomic cascade
invariant, no 3-store settle ordering); `$selectedServices` = value
bitset over the 23 static service IDs (simpler than heap map);
`$vehicleOptions`/`$vehicleSpec`/`$vehicleComplete`/`$quote`/
`$suggestions` derived; booking state = records + op status.
Model-choice events should carry stable identity or parent brand — a
delayed model index can silently identify a different car under another
brand. `bookingSubmitted` → sample vehicle+cart+quote+payload into one
validated input (needs sample fixes first).

**Async: host executor + serialized completions (option a).**
Keep graph evaluation synchronous; NEVER threads/engines inside zefx.
Protocol: under serialization validate+allocate request ID+build owned
job → admit without waiting (bounded capacity, explicit overload) →
finish graph turn, release mutex → host executes outside → owned
completion → serialized new graph turn → cleanup. Completion
dispatcher must work with NO SSE subscriber (SSE transports, doesn't
drive). Contracts: request ID per owner incarnation, opaque session
handle + generation (cookie+route can be recreated; eviction destroys
immediately — generation check BEFORE resolving effect pointer),
deep-owned payloads, one cleanup path, bounded queues/bytes/fairness,
exactly-one terminal transition, shutdown drain semantics.
`inFlight` is source of truth; `pending = inFlight > 0` derived —
current impl sets pending=false on ANY done/fail (breaks overlap).
Stale results still complete lifecycle. Ordering is app policy:
latest-wins for queries, per-resource serialization for conflicting
writes, idempotency keys for retried writes (timeout ≠ not-happened).

zcar draft-version rule: capture draft version at submit; clear cart
only if version still matches — else async booking A erases cart work
done after submit.

**Board persistence: keep commit-before-success.** Preserve
validate→INSERT→append→bump ordering, move DB work outside mutex via
ONE bounded writer module owning the SQLite connection; IDs allocated
in writer order; committed records applied in commit order by the
serialized path. Don't run existing addPost on a worker (it mutates
shared arrays assuming the mutex). ACK semantics: POST waits outside
mutex for commit+apply (success = committed); bound waiters too.
`202 Accepted` later — but client.js clears fields on any 2xx today.
Committed write survives session eviction; only notification is
generation-gated. No debounce for posts/comments (distinct commands),
no default write-behind. Note: WAL+synchronous=NORMAL — name the
durability guarantee in the ACK contract.

Order: fix sample+batching → extract CarModel → owned async
invocation/completion with controllable test executor → ordered board
writer. HTTP/SQLite/workers/timers stay outside zefx.
