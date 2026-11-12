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
