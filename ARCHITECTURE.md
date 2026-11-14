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

## Astra review: two-tier graph + snapshot catch-up bug (2026-11) (full text: `docs/astra-reviews/2026-11-13-two-tier-graph.md`)

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

## Astra review: what to add to zefx (2026-11) (full text: `docs/astra-reviews/2026-11-13-zefx-roadmap.md`)

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

## Astra review: model layer + async (2026-11) (full text: `docs/astra-reviews/2026-11-13-model-layer-async.md`)

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

## Per-session state cost → render groups (2026-11)

Inventory: per-session cost is NOT the engine graph (tiny for board:
ping+seq+after-flush hook) but `Dom` (full client-DOM mirror:
texts/attrs/when_states/keyed hashmaps), `History` (64 batches/2MB),
`render_arena`, and — the real multiplier — **work**: every
`global_seq++` makes EVERY session run buildView (full tree + string
formatting) + diff + serialize + publish, all serialized on
`srv.mutex`. N sessions → N full renders per mutation.

Key fact: `buildView` is a pure function of `(route, reply_to,
user identity, live BoardModel)`; `seen_seq` is a dirty flag, not an
input (updated inside buildView). DOM ids are deterministic. Two
sessions with equal inputs produce byte-identical trees → identical
diffs → identical ops → identical batches, and their `Dom`s stay
equivalent forever (same view sequence). `History.fetch` already
supports multiple cursors on one ring.

**Render groups**: `Session.group: *RenderGroup{key=(route,reply_to,
user_name), dom, history, view_sig}`. One buildView+diff+serialize per
group per flush; shared History serves all SSE cursors. Memory:
Dom+history per group not per session (32 lurker sessions → ~1-3
mirrors). Fork on divergence: join existing group free (Dom already
matches), or clone Dom O(nodes)+copy ring once — rare (reply click).
Everything stays under `srv.mutex`; shared frame arena for buildView
is safe. Caveat: distinct names/reply_to fragment groups; lurkers
share 1-2 groups per route.

Do NOT: clone engine graphs (pointer soup, and board's is tiny); share
mutable Dom across differing view-inputs; dedupe by cookie (two tabs
same user/route differ in reply_to → correctly different groups).

Cheaper independent layers: memoized buildView per flush (~half the
win, no COW); dep-regions (dirty regions by touched{post_id,parent_id}
— also shareable per region); numeric Dom ids instead of string paths;
two-tier global projections (global engine computes lists/counts once —
complements, doesn't replace, groups); lazy render when no SSE
subscriber. Todo/car are inherently per-session; zmon already on
live-bindings. Render groups are the board-specific fix for the main
multiplier.

## Astra review: render groups — verdict + corrected design (2026-11) (full text: `docs/astra-reviews/2026-11-13-render-groups.md`)

**Core claim VERIFIED with qualifications.** View = f(route, reply_to,
resolved display name, BoardModel contents). IDs deterministic (no
session data). Hashmap iteration is NOT a problem: view paths scan
ordered arrays (`posts.items`/`comments.items`), `users`/`post_counts`
are get-only; Zig 0.17.1 auto-hashing is Wyhash seed 0 anyway.
Qualifications: `buildView` writes `seen_seq` (not pure); equal views
≠ byte-identical batches (seq rev embedded in serialization); SSR head
carries per-session CSRF+rev — share body only.

**EXISTING BUGS found (independent of groups):**
- `BoardModel.ensureUser()` mutates `users` WITHOUT `bump()` — an
  invalid first POST can establish identity then return without ping;
  syncPull sees unchanged global_seq → `#who` name stays stale.
- SSE lookup `(cookie,route)` each poll + eviction/recreation between
  polls → new session found with lower rev → stream can stall forever.
  Needs a session incarnation check.
- Correction to earlier note: two tabs with SAME cookie+route share
  ONE Session (reply_to is shared, not per-tab). Route is the only
  session-split dimension.

**FATAL FLAW in naive "join free":** equal view inputs ≠ compatible
revision history. Live SSE switching groups: cursor 40 vs group B
latest 7 → `fetch` returns EMPTY (not gap) → transition silently lost;
B at 50 → applies unrelated patches. Revision numbers don't imply
baseline equality.

**Corrected design (Astra's accepted version):**
- RenderGroupRegistry lives in a BOARD-OWNED runtime module (not the
  generic http server); group key = (canonical route, reply_to,
  resolved display name); group owns incarnation, member count, Dom,
  log, History, group-local revision, last rendered model version.
- Session keeps identity/CSRF/route + group ref + session incarnation
  + membership epoch. Membership change (incl. A→B→A between polls) →
  sync destination → SNAPSHOT → adopt revision. Epoch, not pointer.
- NO Dom/history cloning in v1: new group seeded from current state +
  fresh history; joining connection gets snapshot. Clone+deep-copy
  ring only as later measured optimization.
- Centralize render+rev+serialize+publish (remove duplicate
  POST/SSE publish sites). servePage must sync group BEFORE SSR and
  never reset shared Dom. Fresh-group Dom + ordinary diff is unsafe
  (client `create` doesn't dedupe ids) → enter via snapshot.
- Identity minting recomputes key BEFORE render (covers failed
  dispatches that still minted identity).
- Route changes keep full-page navigation (sessions already keyed by
  route; snapshots can't rebuild page scaffold anyway).
- Thread-route snapshots replace whole comments subtree → reply/
  cancel transitions via snapshot erase other inline drafts/focus —
  product cost to note.
- Dedup key is group's rendered MODEL VERSION checked under mutex —
  "once per group per flush" is wrong (flushes are per session engine).
- Lazy-render correction: dormant sessions without SSE don't eagerly
  render; multiplier = ACTIVE SSE sessions per model version; polls
  coalesce multiple mutations.

**Estimate: 400–800 prod lines + 300–600 test lines, 5–8 files.** Not
a pointer-sharing patch. Acceptance cases: two unequal cursors, late
join with unpublished changes, dest rev lower/equal/higher, A→B→A
between polls, identity mint on failed dispatch, eviction/recreation,
same-route second-tab GET.

**Cheaper alternatives ranked:** two-tier global projections (kills
childIdx/boardPostIdx O(n) scans — strong); dep-regions; memoized
buildView (unmeasured "half"); numeric Dom ids; shared bytes only
after proving identical transitions (History takes exclusive
ownership — needs ownership change anyway).

---

## Bug fixes: identity fan-out + SSE session incarnation (2026-11)

Two defects from the render-groups review, both fixed:

- `BoardModel.ensureUser` now bumps `global_seq` when it actually
  inserts a users row (repeat lookups still don't bump — every POST
  would otherwise re-render all sessions). An invalid first POST that
  mints `zfxu` identity previously returned an error with no
  `ping.emit`, so `syncPull` saw an unchanged `global_seq` and `#who`
  stayed "anon" until an unrelated mutation. Caller audit: the only
  mutating callers are `Session.dispatch` (mint + heal paths, both
  covered) and `board_seed.apply` (init-time, harmless); GET/`servePage`
  never call `ensureUser` — `readCookies` only stashes the token, so
  page loads can't mutate the model. Note: a failed first POST still
  doesn't emit `Set-Cookie` (dispatch errors return before the
  `out_cookie` hook) — the in-memory token persists for the session's
  lifetime but the browser only gets `zfxu` on a successful POST;
  pre-existing quirk, unchanged.
- Sessions carry `incarnation: u64`, stamped by `SessionStore.create`
  from a per-store monotonic counter (compile-enforced contract field —
  all four apps declare it). `serveEvents` captures it on first
  lookup; a mismatch means the (token, route) session was evicted and
  recreated between polls — the new session's seq/history restarted
  near 0, so the old cursor could never be satisfied (silent stall).
  The stream now ends with `session_expired`; client.js already
  reloads on that event and the reconnect gets a fresh snapshot — no
  client change. A→B→A recreation can't alias: incarnations never
  repeat within a store.

---

## Board model indexes (2026-11)

`BoardModel` keeps maintained indexes so every view-path lookup is
O(matches), not O(all rows) — the `childIdx`-per-comment-node scan was
O(comments²) per thread render. Added: `post_by_id`/`comment_by_id`
(id → `items` index; `post`/`comment`/`findPost`/`findComment` and
addComment's post/parent validation, incl. the commentView ancestor
walk, are now O(1)); `posts_by_board` (slug →
`StringHashMapUnmanaged(ArrayListUnmanaged(usize))`, keys borrow
`Post.board` slices so index teardown must precede freeing post
strings); `tops_by_post` + `children_by_parent` (post id / parent
comment id → ascending comment indices — the `parent == null`
partition is identical to the old scan filters). All lists preserve
`items` insertion order; `boardPostIdx` walks its ascending list
backward for newest-first, same order as the old collect+reverse.
Maintenance: `indexPost`/`indexComment` run right after the append on
the only mutation paths (`load`, `addPost`, `addComment` — verified
no delete/reorder exists); `indexComment` subsumes the old
`noteComment`/`post_counts` update. Query signatures and the
`![]usize`-in-arena return contract are unchanged (result slices are
still arena-allocated copies — O(matches), never borrowed, so no
cross-mutation dangling). Memory O(posts+comments). Covered by a test
comparing all three idx fns + id lookups against copies of the old
scans, plus load-path checks in the persist/reload test.

---

## zefx core fixes — item 1: sample repair (2026-11)

`sample` rewritten (`src/zefx/sample.zig`):
- Wires now only SCHEDULE via a new `Engine.sample_queue`; the engine
  drains it in a post-settle phase (after pure reducers + derived
  propagation, before watchers/effects) — source reads always see
  settled state regardless of reducer registration order. Target writes
  re-enter the settle loop before effects run.
- `fn_`/`filter` arity follows inputs: `(source, clock)` when both,
  `(source)` source-only, `(clock)` clock-only. No `fn_` → result is the
  source snapshot, else the clock payload (clock-only forwarding fixed).
- Typed units: clock = `*Event`|`*Store` (store clocks fire on
  `updates()`, payload = new value); source = `*Store`|shape of `*Store`
  — **event sources rejected at compile time** (no defined latest-value
  semantics; `forward()` covers event piping and is now clock-only
  sample). Target = `*Store`/`*Event`/`*Effect` with payload-type checks;
  effect targets call `.run` (Effect gained `ParamT` decl).
- Ownership: `Engine.assertSameEngine` panics on cross-engine units —
  wired into sample, forward, `store.on`/`reset`, `merge`, `split`,
  `combine`.

## zefx core fixes — item 2: explicit batch (2026-11)

`Engine.batchBegin()`/`batchEnd()` (`src/zefx/engine.zig`): nested
batches flush only at the outermost end; events keep order/multiplicity;
no watcher/sample/after-flush work runs mid-batch; `flush()` inside a
batch is a no-op and a `flushing` guard makes reentrant `flush()`
mid-drain a no-op too. batchEnd skips the flush entirely when nothing
queued. **After-flush policy:** hooks run at most once per batch, after
the single outermost flush with settled state; a hook that emits
flushes immediately (it is outside the batch). Notification batching,
not rollback — mutations apply eagerly; borrowed payloads live in the
tick arena until the outer flush.

Adopted in `mon_app.refreshStores()` (inner batch) + new
`refreshAndPing()` (outer batch covering stores+ping): syncPull/dispatch
now cost ONE flush+render per refresh instead of ~14. servePage/
buildViewNodes get the inner batch for free.

## zefx core fixes — item 3: equality-aware writes (2026-11)

`Store.writeValue` is now the single write boundary for EVERY mutation
path — `.set`/`.setState`, `.on` reducers, `.reset`, `map`/`combine`
derived writes, and sample→store targets all funnel through it
(`src/zefx/store.zig`, `root.zig` combine trigger). New `eq` field
(`?*const fn(T,T) bool`): default is comptime scalar equality
(int/bool/enum/float via `==`); compound types default `null` =
always-write — NO automatic deep equality. Suppressed writes skip
prev/value update, markDirty, watchers AND settle propagation; a
suppressed `.set` doesn't even flush. Opt-in comparator:
`st.eq = sliceEq([]const u8)` (`zefx.sliceEq` factory) — runs at WRITE
time, so the old value's backing must still be valid: mon_app's
fmt_arena slice stores deliberately keep `eq = null` (arena resets
before the sets would recycle the old slices; Dom already dedupes
unchanged text ops). `st.eq = null` disables dedup entirely.
Audit: apps only `.set` seq(+1) (always changes) and mon's slice
stores — no app relied on equal-value writes for side effects;
scalar dedup additionally silences zmon's bool/u64 stores
(st_ok/st_bad pills, st_err_bp) between real changes.

---
<!-- zefx/api-sugar item 1 -->
## Typed reducer registration: `Event.onReducer` (2026-11)

`Event(T).onReducer(ctx, call)` (`src/zefx/event.zig`) is now the
supported way to hang pure-phase logic on an event — `call` is a
comptime `*const fn (@TypeOf(ctx), T) void`, so the payload type is
inferred and mismatches fail at compile time (incl. `void` payloads).
The helper stores `ctx` BY VALUE in a box allocated on
`eng.allocator` and freed via `trackGraphAlloc` at engine deinit —
callers pass e.g. `self` (`*Session`, borrowed; pointee must outlive
the engine, same contract as `watchCtx`) or a small value struct.
Reducers can't be unwatched; `.reducers.append` stays as the
low-level escape hatch. No `assertSameEngine` needed: the reducer
lives on the event's own engine, so no cross-engine edge exists.

Migrated EVERY former hand-rolled site: all four apps
(board/mon ping→seq bump, todo mutate+seq.updates→remaining,
car mutate→applyMutation — `applyMutation`'s existing signature fit
`fn(*Session, Mutation) void` directly), plus all zefx internals:
`Event.map`/`filter`, `Store.on`/`reset`/`map`, `merge`, `split`,
`combine`, and all three `sample` wire triggers. Net ~50 lines of
boilerplate deleted. Two semantic notes: (a) `Store.on`/`reset`
reducer ctxs moved cleanup from the store's `reducer_cleanups` list
(removed) to engine `graph_cleanups` — identical lifetime in
practice since stores only die at engine deinit; (b) sample's clock
payload now rides BY VALUE in the tick-arena `ClockBox` (was a
pointer into the reducer-call ctx) — one extra copy per clock fire,
same lifetime guarantees; shape-member triggers instantiate a
per-field call fn since `updates()` payload types differ.

---
<!-- zefx/api-sugar item 2 -->
## `attach()` — sample pipeline as a named unit (2026-11)

`attach(eng, opts)` (`src/zefx/sample.zig`, exported as `zefx.attach`
+ `App.attach`/`BoundDomain.attach`) accepts sample's options —
`source` (store|shape), `clock` (event|store), `filter`, `fn_`,
optional `target`, optional `name` — but ALWAYS returns the attached
unit: a real engine-owned `*Event(Result)` that fires the sampled
result on every trigger. It is an ordinary event: watch/map/filter,
use as `clock`/`target` in further sample/forward, or `onReducer`.

Key semantic choice: `.target` is ADDITIONAL fan-out, not the return
value (unlike `sample`, which returns its target). Implementation:
`AttachWireOpts` comptime-rebuilds the opts struct with `.target`
forced to the attached event, delegates the wire to `sample()`
(so post-settle scheduling, payload checks, and assertSameEngine all
inherited), then — when the caller passed `.target` — adds a second
clock-only `sample(attached → target)` for store/event/effect fan-out.
Both deliveries settle inside the same flush; the attached event's
own watchers observe post-target state.

Zig gotcha hit: `std.mem.eql` yields a runtime `bool` — inside
`inline for` BOTH branches get analyzed per field, so the target
slot assignment needs `if (comptime std.mem.eql(...))` for lazy
branch analysis.

Deferred (per Astra's ranking): effect-creating attach
(`attach({effect, source, mapParams})` — params merging into a new
effect), `batch` flag, clock arrays. Use case validated by test:
zcar booking shape — shape source {vehicle,cart,quote} + submit
clock + fn → BookingParams → effect target, with the attached event
itself observable.

---

## Render groups — implementation (2026-11)

The accepted design above is implemented on `perf/render-groups`:

- `src/board_groups.zig` (board-owned, per the verdict): `Key`
  (route, reply_to, resolved name), `RenderGroup` (incarnation,
  members, Dom, PatchLog, History, scratch arena, `rev`,
  `last_rendered_seq`), module registry `join`/`leave`, canonical
  `keyStringInto`, `registryCount`. Groups are seeded privately at join
  (diff against empty Dom, batch discarded) with a fresh history; the
  last `leave` destroys the group and frees the map at empty.
- `src/board_app.zig`: `ViewEnv` (route/reply_to/name/`seen` cursor)
  is now the single input bundle — `buildView` is `pub` and takes it,
  so group renders and session SSR/snapshot builds share one code path.
  `Session` gains `attached` (set by first servePage — ungated sessions
  keep the solo path), `group`, `membership_epoch`. `syncMembership`
  recomputes the key on EVERY render (covers identity minted by failed
  dispatches) and bumps the epoch on every join/leave/re-key.
  `render()` routes through `g.render()`+`g.publish()` when grouped —
  dedup is `last_rendered_seq` vs `global_seq`, so N members cost one
  buildView+diff per model version. `publishPending`/`streamRev`/
  `streamHistory`/`membershipEpoch` are the optional server contract.
- `src/server/http.zig`: generic hooks only — `@hasDecl` gates
  `publishPending` (POST + SSE poll), `streamRev`/`streamHistory`
  (ACK rev, snapshot rev, patch cursor), and `membershipEpoch` (any
  change between polls → snapshot path + adopt new group rev). Apps
  without the decls run the byte-identical legacy path.
- `src/server/stream.zig`: `writeSnapshotJson(s, rev, w)` takes the rev
  explicitly (group-local, ≠ `seq.get()`).

**Deviations from the accepted design:** none functional. Two notes:
- `servePage` calls `ensureGroupCurrent()` (render+publish if stale)
  before SSR — a joining member can trigger the pending group render,
  which also keeps dormant groups fresh; the group Dom is never reset.
- The meta `zforest-rev` still carries `seq.get()` (per-session ping
  count). Harmless: the first SSE event is always a snapshot that
  adopts the group rev unconditionally, and `applySnapshot` resets
  `lastRev` even when it moves backwards across groups.

**Verified live:** two anonymous sessions on `/` share one group —
one model bump produced a single `patch` rev on both streams; a
first-POST identity mint migrated the session and its open stream got
a mid-flight `snapshot` rev=0 (new group), exactly the epoch→snapshot
contract.

---

## Render groups v2 — clone-on-fork (2026-11, implemented)

**Motivation.** v1 forces a snapshot on EVERY membership change
(`membership_epoch` bump → SSE snapshot → full DOM rebuild). Astra's
review already flagged the product cost: reply/cancel transitions on
thread routes erase inline drafts and focus. The pre-groups solo path
never had this problem — a session's own `Dom` diffed the new view into
a minimal patch. v2 restores fine-grained transitions for the common
case without giving up group dedup.

**Core insight.** What the client trusts is not group identity but
STREAM LINEAGE: its `lastRev` cursor plus the assumption that
`history.fetch(cursor)` returns ops computed against the DOM it
already shows. A snapshot is only needed when the new group's
`(rev, history)` namespace is incompatible with that cursor. If the
new group literally continues the parent's revision numbering AND
history ring, patches keep flowing and the fine-grained diff touches
only what changed — drafts/focus in untouched regions survive.

**Design — `fork`, not `join`, for absent keys.**
`syncMembership` on key change:

- new key already in registry → `leave` + `join` + `membership_epoch++`
  (incompatible namespace → snapshot; unchanged v1 behavior);
- new key absent AND session has a live group → `fork(old, new_key)`;
  **no epoch bump** — the stream continues;
- no old group (first attach) → `join` (seed) + epoch++ as today.

`RenderGroup.fork(gpa, src, key)`:
- `Dom.cloneDeep()` — NEW method: deep-copy `texts`/`attrs`/
  `orders`/`when_states` (all owned strings/lists). `bindings` must be
  empty — board never calls `bindTree`; assert, don't silently copy
  (live-binding transfer is a separate problem).
- `History.cloneDeep()` — NEW method: deep-copy each `Entry.data`.
  Bounded by `max_entries`/`max_bytes` (64 / 2 MiB) — clone cost is
  capped.
- Copy `rev` and `last_rendered_seq`; set `needs_render = true` —
  view inputs differ (reply_to/name), so the group must diff ONCE even
  when `global_seq` is unchanged. `render()` skip condition becomes
  `!needs_render and last_rendered_seq == global_seq`.
- Fresh `PatchLog`, arena, `incarnation`, `members = 1`; registered
  under the new key. `src.publish()` first (defensive no-op — render
  and publish are already atomic under the server mutex).
- Clone BEFORE `leave(src)` so the source is alive; `leave` then just
  decrements — source survives for its other members.

**Why this is sufficient.** The cloned `Dom` equals the tracked state
the client's DOM was patched to (invariant: every render publishes
immediately, so Dom == latest published view). The next `render()`
diffs the NEW view against it → emits exactly the transition ops
(e.g. reply form appears, comment thread untouched). `rev` continues
at `src.rev`; the cloned ring serves lagging cursors — its prefix IS
the parent's history, so catch-up ops are valid for the client's
lineage. Fork-of-fork chains work: each clone carries the full
prefix.

**Epoch semantics refined.** `membership_epoch` now means "stream
namespace changed", not "membership changed": bump on join-existing,
first attach, and group recreation under a taken key; NOT on
clone-fork. `http.zig` needs ZERO changes — the existing contract
(bump → snapshot) already implements the right policy. Client needs
zero changes.

**Accepted v2 limit.** Fork-CANCEL (reply_to → null) rejoins the
existing base group → epoch bump → snapshot → drafts still lost on
cancel. Avoiding it needs either (a) a join fast-path when the client
cursor ≤ the group's clone-point rev (requires recording fork
provenance on groups), or (b) the v3 direction below.

**v3 direction (noted, not planned): decouple stream identity from
view identity.** A group's `Dom`+`history`+`rev` is a stream
namespace; its view inputs could change via transition-diff
(`diff(new_view, old_Dom)` always yields valid ops for that
namespace's clients). Sessions could then adopt ANY view without
snapshotting — at the cost of giving up render dedup for divergent
members. Groups become shared namespaces with opportunistic dedup,
not view-keyed cells. Bigger redesign; revisit only if v2's cancel
snapshot proves painful.

**Size estimate.** `Dom.cloneDeep` ~60 lines, `History.cloneDeep` ~15,
`fork` ~40, `syncMembership` branch ~15, `needs_render` ~5,
tests ~150 — ~300 lines across `dom.zig`, `history.zig`,
`board_groups.zig`, `board_app.zig`. Far smaller than v1.

**Test plan.** Unit: clone equivalence (diff clone vs original →
empty ops), history clone preserves `fetch(cursor)`. Integration:
fork produces `patch` (not `snapshot`) with contiguous revs; minimal
ops (reply region only); lagging cursor catch-up through cloned ring;
fork-of-fork; A→B→A still snapshots; identity mint mid-session no
longer snapshots; eviction/recreation unchanged.

**Implementation (done).** `Dom.cloneDeep` (dom.zig — deep-copies
texts/attrs/orders/when_states; asserts `bindings` empty since live
binders own store subscriptions and board never bindTree),
`History.cloneDeep` (history.zig — verbatim ring copy, bounded),
`RenderGroup.fork` + `needs_render` + `contains` (board_groups.zig;
`createGroup` helper shared with `join`), and the `syncMembership`
fork branch (board_app.zig — absent key + live group → fork, epoch
NOT bumped; present key → join + epoch++ as before). `http.zig` and
`client.js` unchanged — the epoch contract already expressed the
right policy.

**Verified live** (zboard :8899, /t/1): reply → `event: patch`
rev=2 with a single `when` op mounting the reply form (v1 sent a
full snapshot); cancel_reply → `event: patch` rev=3 unmounting it —
the intermediate single-member group had been destroyed, so cancel
forked again rather than joining. The join-existing→snapshot path
still fires when the destination group has other live members
(covered by the A→B→A test with `b` holding base alive).

## zboard: comment sorting + likes (done)

**Comments default to newest-first.** `topCommentIdx`/`childIdx`
return ascending insertion order (the old scan semantics preserved by
the adjacency indexes); the VIEW reverses top-level order — sorting is
a presentation concern, indexes stay canonical. `sortTops` produces
the ordered index slice per `env.sort`; children stay chronological.

**Sort is a group-key input.** `Session.sort ∈ {new, top}` joins
`ViewEnv` and `board_groups.Key` (encoded `new`/`top` in
`keyStringInto`, name kept last so `createGroup`'s suffix borrow
still works). Switching sort = key change → clone-fork when the
destination is absent (patch stream continues, drafts live) or join +
snapshot when another session already owns that sort's group. Reorder
surfaces as keyed-list `move` ops — no custom protocol.

**Likes: one vote per account.** SQLite `likes(kind, target, user, ts)`
with `PRIMARY KEY(kind, target, user)` — the PK alone enforces
one-like-per-token at the storage layer. In memory:
`like_counts: id → u32` (posts/comments share one id space; `kind`
disambiguates) and `liked_by: "{p|c}{id}:{token}" → void` for O(1)
toggle checks. `toggleLike` validates target+kind, write-through
INSERT/DELETE, bumps `global_seq` → normal render-group fan-out.
Toggle semantics: absent → insert+count+1; present → delete+count−1.
`ensureUser()` already runs at the top of every `dispatch`, so the
`zfxu` token is always minted before a like lands — anonymous lurkers
get a real account on first click.

**UI.** `▲ N` like buttons (`data-on-click="like"`, `data-arg="c12"`/
`"p3"`) on post cards and comment meta; sort bar `сортировка: новые |
топ` above the comments list with `sort-on` active styling. Delegated
events — no client.js changes.

**Tests.** Model: toggle/unlike, one-vote-per-token, cross-account
independence, kind isolation, missing-target rejection, file-db
reload (liked_by survives → same account toggles OFF after restart).
View: `sortTops` new/top ordering + tie-break; dispatch like/sort
incl. InvalidAction paths; sort re-key → clone-fork with NO epoch
bump, key_string carries the sort field.

## zboard: dirty-only dispatch (done)

`global_seq` bumped on EVERY mutation forced every render group through
buildView+diff — a comment on /t/6 re-rendered home, other boards and
other threads just to emit empty patches. Now `BoardModel.scope_seq`
keeps per-scope u64 counters and each `RenderGroup` records the single
scope its route reads (`scopeForRoute`: home→SCOPE_HOME, board→
scopeBoard(i), thread/comment→scopePost(post_id) — comment permalinks
read their whole post's subtree, over-broad but correct).

Mutations declare their footprint: addPost→home+board, addComment→
post scope + its board + home only when still in latest-N,
toggleLike(.post)→home(if latest)+board+post scope, toggleLike(.comment)
→post scope, ensureUser→none (names are immutable post-mint; the
session's own name change re-keys the group anyway). `RenderGroup.
isCurrent()` gates both `syncPull` (no ping → no flush → no SSE
traffic) and `render()`; `needs_render` still forces fork renders.
Scope keys are u64-tagged (home=0, boards=1..N, posts=2^40+id) — no
string allocs on the hot path.

## zmeta v0 spike: generated Session skeleton (done)

First slice of `docs/meta-framework.md` §5 landed on `feat/zmeta-v0`:
`src/zmeta/` holds plain source files (NOT a named build module — like
`server/`, they compile into whichever exe module imports them
relatively, so `History`/`Dom`/`zefx`/`forest` keep one type identity
per exe; a named `zmeta` module would fork `History` away from
`server/http.zig`'s copy).

- `session.zig` — `Session(Deps)` generic implementing the FULL
  http.zig contract: owns `app`/`seq`/`dom`/`log`/`history`/
  `render_arena`/`csrf_token`/`incarnation`/`out_cookie`, installs the
  after-flush `forest.diff` render hook itself, and delegates app
  specifics to `Deps`: required `init`/`dispatch`/`view`; optional
  `deinit`/`wire`/`prepare`/`setRoute`/`validPath`/`syncPull`/
  `readCookies` + `page_title`/`page_class`/`cookie_name` consts
  (defaults match http.zig's). Deps fns take `s: *Session` and must be
  `pub` (cross-file calls). Revision model: deps reducers call
  `s.bumpSeq()`; one batch per flush, `log.revision = seq.get()`.
- `env.zig` — `Env{ route }`: the v0 slice of §5.2's Env. Typed params,
  identity helpers and the render cursor are deferred to the routing
  codegen step; the §4.4 seen-cursor stays unreachable by construction
  (per-session apps have none — it is a render-group concern).
- Archetype: `.per_session` only. `.shared_model` hooks
  (publishPending/streamRev/streamHistory/membershipEpoch) stay
  undeclared → server keeps per-session defaults; revisit when a
  second shared-model app exists (§4.1).
- Pilot: `todo_app.zig` refactored — `TodoDeps` holds model fields +
  `mutate`/`remaining` handles + dispatch/view; `Session =
  zmeta.Session(TodoDeps)`. Behavior identical (same routes/actions/
  DOM; ~290 contract lines removed, view/tests unchanged modulo
  `s.deps.*` field access).
- Second pilot: `car_app.zig` refactored the same way — `CarDeps`
  holds brand/model/year + services cart + bookings + `next_booking`
  + the `mutate` event; `Session = zmeta.Session(CarDeps)`. The app
  uses only required Deps decls plus `deinit`/`wire`/`validPath`
  (kept so bogus paths still 404 before a session is minted — the
  skeleton default accepts every path and relies on servePage's
  setRoute gate, which would mint-then-404). Session methods became
  file-scope fns taking `*Session` (`hasSvc`/`discounts`/`cartIds`/
  `applyMutation`/…), `Session.Discount`/`Session.Suggestion` moved
  to file scope, `createSession` is the same one-liner as todo's.
  No skeleton gaps hit — car is single-route per-session like todo.
  Verified live: page SSR, action POSTs (set_brand→book), booking
  recorded, bogus route 404, `zig build test` green.
- Deferred: file-based routing codegen, typed action tables, typed
  route params, `/api/*`, soft-nav, islands — all per §5/§7.

## zmeta: `.shared_model` archetype + render-group stream hooks

`Session(Deps)` now supports the §4.1 `.shared_model` archetype on
`feat/zmeta-shared`. `Deps` may declare `pub const archetype:
zmeta.Archetype = .per_session | .shared_model | .live_shared`
(metadata only — exported via `zmeta/root.zig`).

The four http.zig stream hooks (`publishPending`/`streamRev`/
`streamHistory`/`membershipEpoch`) are emitted ALL-OR-NOTHING: Zig
0.17 has no `usingnamespace` and no conditional named declarations, so
the skeleton cannot emit "only the hooks Deps declares" — and the four
are meaningless in isolation anyway (custom `streamRev` without
`streamHistory` breaks `History.fetch` contiguity; grouped sessions
need the epoch to force snapshots). `Session(Deps)` comptime-selects
two thin session types:

- none declared → `SessionPlain`: the methods do not exist on the
  type, `@hasDecl` probes fail, server keeps per-session defaults;
- all four declared → `SessionGrouped`: each is a pure pass-through to
  the matching `Deps` fn (`fn(s: *Session) T`). The render-group
  registry/key/group pointer stay app-owned in `s.deps` — the
  skeleton forwards, it owns no group state (§4.1 verdict stands);
- some declared → `@compileError` naming the missing hooks.

Implementation shape (forced by the missing `usingnamespace`): all
method bodies live ONCE in `SessionMethods(Deps)` taking
`self: anytype` (the `stream.zig` duck-typing style); each variant
struct declares the identical field list and aliases every method via
`pub const name = M.name` — the post-`usingnamespace` idiom. Only the
field list is duplicated. `Deps.init`/`wire`/`view`/`dispatch` still
receive the exact `*Session` type per variant, so existing Deps code
is unaffected (`todo.Session` resolves to `SessionPlain` unchanged).

`syncPull` stays independently optional (shared-model fan-out without
groups = the zmon shape; `live_shared` is reserved — `bindTree` live
render mode is still Deps-owned future work). Env is unchanged: the
hooks take `*Session`, so group state is reached through `s.deps` —
no new Env accessors were needed.

The render-path overrides this deferred (grouped
`servePage`/`render`/`writeView`/`buildViewNodes`/`seedDom` —
board's grouped servePage syncs membership + ensures the group
current instead of `dom.reset`+`seedDom`, and its flush render goes
through the group) landed on `feat/zmeta-grouped` — see the next
section. No app migrated yet.

## zmeta: render-path overrides for grouped apps (done)

`feat/zmeta-grouped`: `Session(Deps)` now lets an app replace the
render pipeline per-method — the missing piece deferred from the
`.shared_model` work above. Five new OPTIONAL Deps decls, each
delegated via `@hasDecl` inside `SessionMethods` (same trick as
`deinit`/`wire`/`syncPull`/`prepare`):

- `fn servePage(s: *Session, path: []const u8, writer: anytype)
  !bool` — replaces the WHOLE page pipeline (setRoute gate →
  prepare → dom.reset → writeView → seedDom). Grouped apps need
  the whole-pipeline hook: board's is setRoute → `attached` →
  `syncMembership` → `ensureGroupCurrent` → `writeView`, with NO
  `dom.reset`/`seedDom` — the shared Dom lives in the render group.
- `fn render(s: *Session) void` — replaces the after-flush diff
  render (and the render step inside `seedDom`). Effectively
  REQUIRED for grouped sessions: without it every flush diffs into
  the session's unused `dom`/`log` while the group never renders.
- `fn writeView(s, writer) !void`, `fn buildViewNodes(s, a)
  []const forest.Node`, `fn seedDom(s) void` — per-method
  replacements; they compose (default servePage calls
  `self.writeView`/`self.seedDom`, resolving through the same
  overrides, so a Deps can override e.g. only `seedDom`).

Mechanism trade-off (recorded per AGENTS.md): per-method delegation
was chosen over a `render_pipeline = .per_session | .grouped_custom`
decl or more variant types. The four stream hooks needed
`SessionPlain`/`SessionGrouped` variants ONLY because http.zig probes
`@hasDecl(Session, ...)` on the session TYPE — their presence or
absence must be a type-level fact. servePage/writeView/
buildViewNodes/seedDom are unconditional contract methods (the
server calls them on every GET / SSE snapshot), so `@hasDecl(Deps)`
inside the body is sufficient and strictly more flexible: no new
variants, no all-or-nothing render set, and `todo.Session`/
`car.Session`/the demo are untouched (none declare the new names —
behavior byte-identical). A grouped Deps should treat `render` +
`servePage` as a pair: the first routes flushes into the group, the
second replaces the per-session page pipeline; `seedDom` stays
declared-but-unreached for them.

Test coverage: `PipelineDeps` in session.zig declares all four
stream hooks + all five render overrides; the test asserts marker
HTML from the custom servePage (and that "/" — accepted by the
default pipeline — returns false under the override), custom
writeView/buildViewNodes output, seedDom bypassing `self.render`,
and dispatch→bumpSeq→flush reaching `Deps.render` with `s.log`
left empty. `zig build test` and `zig build` (all 5 exes) green.

### zboard→zmeta migration path

Not done in this task — the mapping for the next step:

- `board_app.model`/`globalSeq()` stay module-global; `BoardModel`
  and the `board_groups` registry stay app-owned — the skeleton
  owns no group state (§4.1 verdict unchanged).
- Session fields → `Deps` fields on `s.deps`: parsed `route`,
  `reply_to`, `sort`, `user_token`, `out_cookie_buf`, `seen_seq`,
  `attached`, `group: ?*RenderGroup`, `membership_epoch`, `ping`
  handle. Skeleton-owned fields (`app`/`seq`/`dom`/`log`/`history`/
  `render_arena`/`csrf_token`/`incarnation`/`route` path/
  `out_cookie`) come free — note board's `out_cookie_buf` scratch
  vs the skeleton's `out_cookie` slice: Deps keeps the buffer and
  points the slice at it.
- `Deps.init` creates graph handles; `Deps.wire` registers ONLY
  `ping.onReducer` — the skeleton installs the after-flush render
  hook itself, so board's `wire` must not re-register it.
- `setRoute`/`validPath` → `Deps.setRoute`/`Deps.validPath`
  (parseRoute + dangling-id 404). The skeleton additionally stores
  the raw path for `Env.route`; `Deps.view` rebuilds `ViewEnv` from
  `s.deps` — `Env` stays the thin `{route}` v0 slice.
- `syncPull` → `Deps.syncPull` verbatim (group `isCurrent()` gate →
  ping; else `seen_seq` vs `global_seq`).
- `servePage`/`render` → `Deps.servePage`/`Deps.render` verbatim
  modulo `self.`→`s.`/`s.deps.` field access and skeleton calls.
- `publishPending`/`streamRev`/`streamHistory`/`membershipEpoch` →
  the four existing Deps hooks verbatim (group-vs-session fallback
  logic included — they already take `*Session`).
- `writeView`/`buildViewNodes`/`seedDom`: the DEFAULTS likely
  suffice — `Deps.view` adapts `ViewEnv`; override only if
  group-aware serialization is needed. Caveat: board's
  `buildViewNodes` stamps `seen_seq` through `viewEnv().seen`,
  and the §4.4 rule says the cursor is written only by Dom-syncing
  builds, never incidental serialization — today
  `session.buildViewNodes` passes `seen = &seen_seq`
  unconditionally; the migration should preserve that exact split
  or deliberately fix it.
- `dispatch`/`view`/`readCookies` (`zfxu`)/`page_title`/`page_class`/
  `cookie_name` → same names on Deps; `view` wraps
  `buildView(a, depsViewEnv(s))`.
- Open question for migration: `RenderGroup.seed`/`render` call
  `board_app.buildView` directly with the GROUP's `viewEnv`
  (`seen = &g.last_rendered_seq`), bypassing any session. Under
  zmeta either board_groups keeps calling a board-owned `buildView`
  shim (safest first cut — preserves the cursor split exactly) or
  grows a view-fn parameter; decide then — board_groups stays
  board-owned either way.

## zmeta codegen: file-based routes + action table (done)

Second slice of `docs/meta-framework.md` §5 landed on
`feat/zmeta-codegen`: `src/zmeta/gen.zig` is both a library and a CLI
(`zig run src/zmeta/gen.zig -- [app-dir ...]`, or `zig build gen` for
the default `src/apps/*/pages/` scan). It is plain source like the
rest of `zmeta/` — no named module, no build-time dependency: output
is deterministic and CHECKED IN under `src/apps/<name>/gen/`, so
`zig build` compiles generated files directly and a stale regen is a
reviewable diff, not a cache artefact.

Conventions (spec §5.1/§5.3 v0):

- `src/apps/<name>/pages/**/*.zig` — one file per route:
  `pages/index.zig` → `/`, `pages/about.zig` → `/about`,
  `pages/item/[id].zig` → `/item/:id`,
  `pages/t/[post]/c/[c].zig` → `/t/:post/c/:c`. Every page declares
  `pub const params = struct { ... };` (empty struct for static
  routes); `[name]` segments map 1:1 onto `params` fields, validated
  at gen time (ParamMismatch, DuplicateRoute, ambiguous shapes).
- Param types are integer-only in v0 (`u8`…`u128`, `i8`…`i128`,
  `usize`/`isize`) — string params need session-owned storage for the
  slice, deferred (§7). Static segments take precedence over dynamics
  at the same position; the emitted parser is a flat segment-count +
  literal-match chain, not a trie.
- Optional page decls: `pub const route_name`, `pub fn prepare(s, p,
  env) !void` (any error → servePage 404s before view work — the
  dangling-param gate, spec §2.5), `pub fn view(a, s, p, env)
  forest.Node`.
- `src/apps/<name>/actions.zig` — `pub const actions = .{ "ping",
  "like" };` manifest → comptime `act.ping`/`act.like` string consts
  (usable in `.on = .{ .click = act.like }`, compile-checked against
  the DOM-event whitelist; the wire stays strings) plus a `dispatch`
  skeleton calling `on_<name>` on the Deps type with the standard
  `(arg, value, fields)` payload. Unknown actions →
  `error.InvalidAction`.

Generated `gen/routes.zig` API: `Route` union (one tag per page,
payload = the page's `params` type), `parseRoute(path) ?Route`,
`validPath`, `setRoute(s, path) bool` (writes `s.deps.route`),
`href(a, route) []const u8` (static routes → comptime literals,
dynamic → `allocPrint` into the render arena), `prepare(s, env)` and
`viewNodes(a, s, env)` dispatch. `gen/actions.zig`: `act` table +
`dispatch(s, action, arg, value, fields)`.

Pilot: `src/apps/zmeta_demo/` (`pages/index.zig`,
`pages/item/[id].zig` — prepare 404s unknown ids, like button carries
`data-arg`) + flat entry `src/zmeta_demo_main.zig` (the `*_main.zig`
convention doubles as the module-path boundary: Zig refuses relative
imports escaping the module root's directory, so the exe root must
live in `src/` while the app dir holds pages/gen). Deps delegates
`setRoute`/`validPath`/`prepare`/`view`/`dispatch` to the generated
modules — ~40 lines of glue total. `zig build run-demo` (port 8084),
`zig build gen` regenerates. Verified: `/` 200, `/item/1` 200 with
generated hrefs, `/item/99` + `/item/x` + `/bogus` 404, action POST
`{"action":"like","arg":"1"}` → `{"rev":1}` → `likes: 1` on re-render,
SSE snapshot serializes bound nodes.

Deferred (per §5/§7): string/slice route params (need owned storage),
`route_name` currently only affects the union tag (no custom URL
override yet), catch-all `[...rest]` segments, route groups/layouts,
`/api/*` RPC routes, soft-nav/`history.pushState` integration,
islands, and migrating zboard/zcar/zmon (their manual routing stays —
the generator targets new zmeta apps).

## zboard on the zmeta Session skeleton (done)

`feat/zmeta-board`: zboard is the first real `.shared_model`/grouped
app on `zmeta.Session(Deps)` — the migration path sketched above,
landed. `src/board_app.zig` is the only file touched
(`board_groups.zig`/`board.zig`/`board_main.zig`/`server/http.zig`
byte-identical).

`pub const BoardDeps` carries every former session field — parsed
`route: Route`, `reply_to`, `sort`, `user_token` (zfxu),
`out_cookie_buf` scratch (the skeleton's `out_cookie` slice points
into it), `seen_seq`, `attached`, `group: ?*RenderGroup`,
`membership_epoch`, and the `ping` event handle — plus
`archetype = .shared_model` and the page-metadata consts
(`page_title`/`page_class`/`cookie_name`). `board_app.model` and the
`board_groups` registry stay module-global, app-owned.

One deliberate deviation from the pilots' one-liner: `Session` is
HAND-DECLARED rather than `pub const Session =
zmeta.Session(BoardDeps)`. `board_groups.zig` — board-owned and
frozen for this migration — calls `Session.scopeForRoute(route)` and
`Session.scopeVersion(key)` as STATIC decls, and Zig cannot extend a
type alias's namespace (the skeleton's SessionGrouped has a fixed
decl list). So `Session` replicates SessionGrouped's exact field
list and aliases every contract method (`deinit`/`setCsrf`/`setRoute`/
`validPath`/`readCookies`/`servePage`/`syncPull`/`bumpSeq`/`dispatch`/
`writeView`/`buildViewNodes`/`seedDom` + the four stream hooks) from
`Skel = zmeta.Session(BoardDeps)` — the method bodies still live once
in `SessionMethods` as `self: anytype` generics, so nothing is
duplicated semantically. `create` mirrors `createSessionImpl`
(contract fields → `Deps.init`/`Deps.wire` → the after-flush render
hook LAST). The two scope statics are the only board-owned additions;
`viewEnv`/`render` pub shims exist solely so no aliased default branch
can resolve the skeleton's private decls on this foreign self type.

Deps surface used:

- Required: `init` (creates `ping`), `wire` (registers ONLY
  `ping.onReducer` → `bumpSeq`; the skeleton installs the after-flush
  hook itself — no duplicate render registration), `dispatch`
  (verbatim action table: post/comment/reply/cancel_reply/sort/like),
  `view` (contract wrapper — every path that would call it is
  overridden, so it exists for completeness).
- Lifecycle/route: `deinit` (group leave → free user_token, original
  ordering), `setRoute` (parseRoute + dangling-id 404 gate),
  `validPath`, `readCookies` (zfxu pick-up).
- Fan-out: `syncPull` (group `isCurrent()` gate → ping; else
  `seen_seq` vs `global_seq`), and all four stream hooks
  (`publishPending`/`streamRev`/`streamHistory`/`membershipEpoch`)
  verbatim — declaring the complete set is what selects
  SessionGrouped and flips http.zig's `@hasDecl` probes.
- Render-path overrides (all five): `servePage` (setRoute →
  `attached` → `syncMembership` → `ensureGroupCurrent` → `writeView`,
  NO `dom.reset`/`seedDom`), `render` (attached → re-key →
  `g.render()`+`g.publish()`; unattached → original per-session
  diff), `writeView`, `buildViewNodes`, `seedDom` (solo-only helper).

The §4.4 seen-cursor split is preserved exactly: session-side builds
(`writeView`/`buildViewNodes`/solo render) stamp `s.deps.seen_seq`
through the file-scope `viewEnv(s)`; `board_groups.RenderGroup`
keeps calling the board-owned `buildView` shim with the GROUP's
`ViewEnv` (`seen = &g.last_rendered_seq`) — the open question above
resolved as "shim stays". Grouped `servePage`/`render` route through
`syncMembership`+`ensureGroupCurrent`, never the default
`dom.reset`+`seedDom` path.

Tests: the extensive board test suite now drives `s.deps.*` fields;
`zig build test` 17/17 green, `zig build` all 5 exes green. Live
smoke on `zboard 8899`: GET `/`, `/b/emp`, `/t/1` → 200,
`/bogus`/`/t/999` → 404; POST comment → `{"rev":1}`, POST like →
`{"rev":2}`, `zfxu` minted on first POST; SSE `/events?r=/t/1`
delivers a group-local `snapshot` (rev 2) then `patch` rev 3 with
the new comment's create op — grouped publish/fetch end to end.

Deferred: `src/apps/` codegen adoption (board keeps its manual
routing — the generator targets new zmeta apps), `zcar`/`zmon`
migrations, and any future move of the scope statics into the
skeleton (would need a Deps-declared hook or a board_groups-facing
API change — neither is warranted while board_groups stays
board-owned).

## zmon on the zmeta Session skeleton (done)

`feat/zmeta-mon`: zmon is the `.live_shared` archetype's first
inhabitant — the last hand-rolled `Session` migrated.
`src/mon_app.zig` is the only file touched (`mon_model.zig`,
`server/*`, `forest/*`, `zefx/*` byte-identical; `mon_main.zig`
needed no changes — `mon_app.Session`/`mon_app.model` kept their
names).

`pub const MonDeps` carries every former session field — the 15
dashboard stores (`st_*` incl. the `map`-derived `st_ok`/`st_bad`),
`seen_seq`, `fmt_arena` + `view_arena`, the `view_nodes` once-built
cache, and the `ping` event — plus `archetype = .live_shared` and
the page-metadata consts (`page_title`/`page_class`/`cookie_name`).
`mon_app.model` (the shared `MonModel`) stays module-global,
app-owned. `MonDeps` declares NO render-group hooks, so
`zmeta.Session(MonDeps)` selects the plain per-session variant —
correct: zmon keeps its own Dom/log/history per session.

Unlike board, `Session` is the one-liner `pub const Session =
zmeta.Session(MonDeps)` — nothing outside Deps calls statics on the
session type, so the hand-declared workaround wasn't needed.

The live render path maps onto the render-path overrides added for
grouped apps (`feat/zmeta-grouped`); the skeleton's default
after-flush diff is bypassed entirely:

- `Deps.render` = `s.log.revision = s.seq.get()` — the whole hook.
  Live `Binder`s (`forest.bindTree` subscriptions) emit their patch
  ops into `s.log` during the flush notify phase, BEFORE the
  after-flush hook runs; there is no rebuild+diff to do. This is
  exactly what the hand-rolled after-flush `commit` thunk did.
- `Deps.servePage` replaces the whole pipeline because the skeleton
  default lacks the `refreshStores` step: setRoute → refreshStores →
  `dom.reset` → `writeView` → `seedDom` (verbatim ordering).
- `Deps.writeView`/`Deps.buildViewNodes`/`Deps.seedDom` reuse the
  cached `view_arena` tree (`viewNodes`); `seedDom` keeps the
  diff-seed → `log.clear()` → `bindTree(fmt_arena)` sequence.
- `Deps.view` exists for contract completeness only — every path
  that would call it is overridden (same convention as board).
- `Deps.syncPull`/`Deps.dispatch`/`Deps.validPath`/`Deps.wire`/
  `Deps.deinit` are verbatim ports (`s.deps.*` instead of `self.*`;
  `onPing` → `s.bumpSeq()`).

Publish path unchanged: no group hooks → http.zig keeps the inline
`log.writeJson` → `history.publish(seq.get())` on POST and the
`seq.get() > history.latest_rev` drain on SSE poll. `log.revision`
(stamped by `Deps.render`) is what `writeJson` serializes as "rev" —
it always equals `seq.get()` at publish time because dispatch and
syncPull both end in a flush before the server reads the log.

Arenas: `fmt_arena` is dual-purpose (refreshStores format scratch +
every Binder's emit-time arena) — reset only at the top of
refreshStores, retained otherwise; `view_arena` is session-lifetime.
`Deps.deinit` frees both BEFORE the skeleton's `dom.deinit` destroys
binders — safe because binders never emit during teardown (destroy
only unwatches + frees via gpa).

Skeleton gaps for live mode (worked around Deps-side, skeleton
untouched):

- No first-class "live" render mode: `Deps.render` is a one-line
  revision stamp — works, but the contract still lists `view` as
  required even when every consumer of it is overridden.
- `Deps.servePage` had to be overridden wholesale only to insert
  `refreshStores` ahead of `writeView` (a `Deps.prepare` hook doing
  the refresh would also have worked through the default pipeline;
  the explicit override was kept for fidelity).
- `bindTree`'s emit arena must outlive the session — Deps-owned
  `fmt_arena` covers it; the skeleton owns no equivalent.

Tests: two new mon_app tests drive the skeleton session end-to-end
(servePage SSR + 404, dispatch → live patch ops with rev stamp,
syncPull fan-out, ctl_* validation, snapshot serialization + view
cache identity). `zig build test` 17/17 green, `zig build` all 5
exes green. Live smoke on `zmon 8898`: GET / → 200 with `zfxm`
cookie; POST inject_storm/ctl_rate/ctl_err → ACKs rev 1/2/…; SSE
snapshot carries live values (sparklines, feed, log, variant pill
state); patch stream ~10 rev/s from the ticker; ctl_err 3000→0
drove live `when` ops swapping `mon-pill-ok`/`mon-pill-bad`.

Deferred: `zcar` migration (the last hand-rolled Session), and any
future first-class live render mode in the skeleton (would let
`Deps.render`/`servePage` shrink to nothing — today they exist only
to bypass the diff pipeline).
