<!-- Astra (gpt-6-astra) review: render groups design attack Session: 01a1d4cc-745c-7ba3-a7bb-c7dbad5ec0f3. Summary recorded in ARCHITECTURE.md "Astra review: render groups — verdict + corrected design". Implemented in commit 54a479c.  -->

The design is viable, but **“join an existing group free” is incorrect with the current protocol**. Equal view inputs establish equal rendered content; they do not establish a common revision history or synchronize a joining browser.

I would keep render groups, remove cloning from the first implementation, and make every membership change an explicit stream reset followed by a snapshot. There are also two existing lifecycle problems the implementation must address: identity changes without `global_seq` advancing, and session recreation under the same cookie.

This is a static, read-only review. No files changed, including `ARCHITECTURE.md`; no tests or benchmarks run.

**1. The rendering claim is substantially true, but “pure” and “identical batches” need qualification**

The complete session dependency audit for the board view is:

| Field | Effect on output |
|---|---|
| `route` | Selects page content and sidebar highlighting. |
| `reply_to` | Controls inline reply branches. |
| `user_token` | Used only to resolve the displayed `#who` name. |
| `seen_seq` | Written by `buildView`; never read to construct content. |
| `seq` | Not part of the view; supplies patch/snapshot revisions and SSR head metadata. |
| `ping`, `app` | Trigger rendering; not view inputs. |
| `csrf_token` | Not in the board view; appears in the outer HTML head. |
| `out_cookie`, buffer | Response metadata only. |
| `dom`, `log`, `history` | Not read by `buildView`; `dom` determines the resulting diff. |
| `render_arena`, `gpa`, `io` | Allocation/lifecycle machinery; no rendered entropy. |

The actual session reads are sidebar route/name, reply selection, and route dispatch: [board_app.zig:346](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:346), [board_app.zig:479](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:479), [board_app.zig:640](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:640).

Consequently:

- **Equal route, reply target, resolved display name, and model contents produce equal board HTML.**
- `buildView` is not strictly pure: it updates `seen_seq`. Extract that bookkeeping before caching or sharing it.
- Equal views produce equal **diffs only against equivalent previous DOM state**.
- Equal diffs do not guarantee byte-identical batches: `render()` assigns the session’s `seq`, and serialization includes it. Two sessions can have identical views after different numbers of `cancel_reply` actions and different revisions. [board_app.zig:266](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:266), [patch.zig:159](/Users/rafkat/Apps/tmp/zforest/src/forest/patch.zig:159)
- Entire SSR documents remain session-specific because the head contains CSRF and revision metadata. Share the body, not the complete response. [http.zig:204](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:204)

There is a significant **invalidation hole**: `BoardModel.ensureUser()` changes `users` without calling `bump()`. `Session.dispatch()` invokes it before validating the action. An invalid first POST can therefore establish identity, then return without `ping`; `syncPull()` sees unchanged `global_seq` and does nothing. Group membership cannot be checked only when `global_seq` changes. [board.zig:242](/Users/rafkat/Apps/tmp/zforest/src/board.zig:242), [board_app.zig:195](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:195), [board_app.zig:176](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:176)

**Hashmap order is not a problem on these view paths.** Also, the premise about randomized Zig hashing does not match the installed Zig 0.17.1: default auto/string hashing uses Wyhash seed zero. Iteration still should not be treated as a semantic ordering guarantee. [hash_map.zig:23](/opt/homebrew/Cellar/zig/0.17.1/lib/zig/std/hash_map.zig:23), [hash_map.zig:89](/opt/homebrew/Cellar/zig/0.17.1/lib/zig/std/hash_map.zig:89)

More importantly, in this checkout:

- `posts_by_board` and `comments_by_post` do **not exist**.
- Post/comment ordering comes from array scans, reversal, and explicit ancestor-chain reversal.
- `users` is queried with `get`; its iterator is used during destruction.
- `post_counts` is queried with `get`.
- DOM hashmaps are used for lookup and cleanup; patch ordering follows node arrays and stored child-order arrays.

See [board.zig:110](/Users/rafkat/Apps/tmp/zforest/src/board.zig:110), [board.zig:287](/Users/rafkat/Apps/tmp/zforest/src/board.zig:287), [board.zig:319](/Users/rafkat/Apps/tmp/zforest/src/board.zig:319), [dom.zig:342](/Users/rafkat/Apps/tmp/zforest/src/forest/dom.zig:342).

**2. DOM IDs are deterministic**

IDs use constants, persisted post/comment IDs, or parent-path concatenation:

- `post-{id}`, `cm-{id}`, `w-rep-{id}`;
- local IDs such as `go` and `kids`;
- `resolvedId()` returns the explicit ID or concatenates `parent/lid`.

No session tokens, addresses, random numbers, render counters, or current timestamps enter ID generation. Displayed timestamps come from stored records, not the render clock. [board_app.zig:320](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:320), [board_app.zig:391](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:391), [board_app.zig:479](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:479), [view.zig:549](/Users/rafkat/Apps/tmp/zforest/src/forest/view.zig:549)

`view.zig` permits arbitrary deferred bindings, so this is a conclusion about **the present board tree**, not a purity guarantee supplied by the view library. [view.zig:364](/Users/rafkat/Apps/tmp/zforest/src/forest/view.zig:364)

**3. Shared History works within one stream lineage; switching lineages breaks it**

Within a group, multiple cursors work correctly:

- Fetching does not consume entries.
- Each fetch duplicates bytes, so eviction after unlocking cannot invalidate an outgoing response.
- Falling behind retained history triggers a snapshot.
- Oversized batches can empty the ring while preserving `latest_rev`, correctly producing a gap.
- A fresh SSE connection always snapshots; the implementation does not resume from `Last-Event-ID`.

[history.zig:34](/Users/rafkat/Apps/tmp/zforest/src/server/history.zig:34), [history.zig:58](/Users/rafkat/Apps/tmp/zforest/src/server/history.zig:58), [http.zig:447](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:447)

But consider a live connection moving from group A to existing group B:

| State | Value |
|---|---|
| Browser’s cursor in A | 40 |
| B’s latest revision | 7 |
| Browser’s DOM | A’s view |
| Server’s new DOM reference | B’s view |

`B.history.fetch(40)` returns **empty**, not a gap. The browser never receives the transition. If B is instead at revision 50, fetching its revisions 41–50 applies changes based on B’s unrelated past. Equal revision numbers do not imply equal baselines. [history.zig:60](/Users/rafkat/Apps/tmp/zforest/src/server/history.zig:60)

Resetting only the server cursor is insufficient: the browser drops patches whose revision is not greater than `lastRev`. A snapshot already resets browser `lastRev` unconditionally, so it is a suitable transition mechanism. [client.js:183](/Users/rafkat/Apps/tmp/zforest/src/client.js:183), [client.js:217](/Users/rafkat/Apps/tmp/zforest/src/client.js:217)

A cloned DOM **plus an exact deep copy of its matching published history and revision** can preserve lineage. That requires an atomic checkpoint with no unpublished log omitted. Copying just DOM, or independently renumbering the destination, cannot.

The simpler invariant is:

> Before fetching, compare the connection’s session incarnation and membership epoch. Membership changed → synchronize destination group → snapshot → adopt its revision.

Use a membership epoch, not merely a group pointer: A→B→A can happen between polls.

**4. Sharing DOM requires changing lifecycle operations**

Several concrete counterexamples invalidate simply replacing `Session.dom` with a shared pointer.

- **Late page load consumes existing members’ transition.** `servePage()` resets DOM, renders current model HTML, then seeds and clears the log. If a group has not yet processed a model change, a newcomer can advance its shared DOM without publishing that change to existing subscribers. Group synchronization must happen before SSR; attaching a member must never reset/reseed an existing group. [board_app.zig:166](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:166), [board_app.zig:288](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:288)

- **Fresh destination DOM followed by ordinary diff is unsafe for an existing browser.** Diffing from empty tracking generates creates for rows the browser already has. Client `create` inserts without deduplicating IDs. A fresh group must be seeded privately and entered through a snapshot. [dom.zig:381](/Users/rafkat/Apps/tmp/zforest/src/forest/dom.zig:381), [client.js:51](/Users/rafkat/Apps/tmp/zforest/src/client.js:51)

- **Identity minting changes membership before rendering.** Recompute the resolved identity before choosing the group; do not render the new identity into the old anonymous group. This applies to `readCookies`, successful actions, and actions that partially mutate identity before failing. [board_app.zig:110](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:110)

- **Eviction followed by recreation can fool an existing stream today.** SSE relooks up `(cookie, route)` every poll, retaining its old cursor. If eviction and recreation happen between polls, it finds a new session rather than observing absence. With a lower new revision, it can stall indefinitely. Capture a session incarnation and expire the old connection when it changes. [http.zig:92](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:92), [http.zig:423](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:423)

- **Route changes require a new page scaffold.** Current snapshots patch bound nodes, keyed containers, and conditional anchors; they do not reconstruct arbitrary unbound structure. A thread snapshot cannot turn a board page into a thread page. Keep full-page route navigation, or add a true root replacement operation. [view.zig:766](/Users/rafkat/Apps/tmp/zforest/src/forest/view.zig:766)

For the **same route**, snapshots cover the presently dynamic board content, including identity and reply forms. However, thread snapshots replace the whole `comments` subtree. Using one on every reply/cancel transition can erase another inline draft or focus state. This is a product cost, not just serialization overhead. [view.zig:805](/Users/rafkat/Apps/tmp/zforest/src/forest/view.zig:805)

One correction to the architecture note: two tabs with the **same cookie and same route currently share one Session and `reply_to`**. Only differing routes get separate sessions. Render groups will not create per-tab independence. A new page GET on the same route also clears that shared reply target. [http.zig:45](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:45), [board_app.zig:158](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:158)

**5. Shared scratch allocation is safe on current server paths, with a lifetime restriction**

All current production rendering paths hold `srv.mutex`:

| Path | Lock evidence |
|---|---|
| POST dispatch → after-flush render → publish | [http.zig:286](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:286) |
| GET → `servePage` → `writeView`/`seedDom` | [http.zig:348](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:348) |
| SSE → `syncPull` → snapshot serialization | [http.zig:430](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:430) |

A board-runtime scratch arena can therefore serve successive renders. DOM owns copied values, PatchLog owns copied strings, and History owns serialized bytes. The outgoing payload must remain independently owned after unlock. [dom.zig:5](/Users/rafkat/Apps/tmp/zforest/src/forest/dom.zig:5), [patch.zig:74](/Users/rafkat/Apps/tmp/zforest/src/forest/patch.zig:74)

Two qualifications:

- Mutex serialization does not prevent nested rendering on the same thread. After-flush hooks run with the engine phase already `idle`. The present board builder does not emit events, so I found no actual recursive render path; preserve that restriction. [engine.zig:129](/Users/rafkat/Apps/tmp/zforest/src/zefx/engine.zig:129)
- Cached trees cannot live in scratch that the next render or snapshot resets. `writeSnapshotJson` currently resets the session arena itself; that ownership must move behind the rendering interface. [stream.zig:12](/Users/rafkat/Apps/tmp/zforest/src/server/stream.zig:12)

Also, “once per group per flush” is misleading: flushes belong to individual session engines. Deduplicate by **group’s rendered model version**, checked under the mutex.

**6. Alternatives and where I would spend complexity**

| Option | Judgment |
|---|---|
| Memoized `buildView` | Good incremental step. Retains per-session DOM/history semantics; saves construction and formatting, not diffing. Requires explicit cached-tree lifetime and removal of `seen_seq` side effects. “Half the win” is unmeasured. |
| Two-tier global projections | Strong candidate here. `childIdx` scans all comments for each rendered comment; shared ordered adjacency indexes eliminate repeated scans before touching transport. |
| Dependency regions | Useful next step for common thread/post content versus identity/reply UI, but dependency invalidation and composition add real complexity. |
| Numeric DOM IDs | Reduces string/hash costs; does not remove the per-session render multiplier. |
| Shared serialized bytes only | Helps storage/serialization only after proving an identical transition. Deduplicating after every session renders saves no build/diff work. Existing History takes exclusive ownership, so shared blobs require ownership changes. |
| Shared DOM + History | The cleanest removal of repeated full rendering for large identical cohorts, provided stream switching is explicit. |

Projection evidence: [board.zig:309](/Users/rafkat/Apps/tmp/zforest/src/board.zig:309), [board.zig:319](/Users/rafkat/Apps/tmp/zforest/src/board.zig:319). History ownership: [history.zig:26](/Users/rafkat/Apps/tmp/zforest/src/server/history.zig:26).

The motivation also needs a narrower statement: dormant sessions without SSE do not eagerly render on every bump, and multiple mutations can coalesce before a poll. The current multiplier is primarily **active sessions that observe a new model version**, not every stored session on every mutation.

**7. Concrete implementation I would accept**

Put a `RenderGroupRegistry` in a **board-owned runtime module**, alongside its `BoardModel` reference. Keep board route/name/reply keys out of the generic HTTP server. Inject that runtime through session construction/context; avoid adding another process-global singleton.

A group owns:

- Immutable key: canonical route, reply target, resolved display name.
- Unique group incarnation, member count.
- DOM, log, History, group-local revision.
- Last rendered model version.

Model version is a freshness marker, not a permanent registry-key component. Keep actual user tokens and authorization state in Session.

A session owns its existing identity/CSRF/route state, plus a group reference, session incarnation, and membership epoch.

The lifecycle changes are:

| Contract area | Required change |
|---|---|
| `deinit` | Release membership; only the registry destroys shared state. |
| `setRoute` | Update inputs and invalidate membership; retain full-page navigation semantics. |
| `dispatch` | Resolve identity/key changes before rendering, including mutation-before-error cases. |
| `syncPull` | Reconcile membership first, then ensure the group is current; do not gate everything on session `seen_seq`. |
| `servePage` | Synchronize group, write body; never reset shared DOM. Prepare group revision before writing head metadata. |
| `serveEvents` | Track incarnation/epoch/revision; snapshot on membership changes, expire on session replacement. |
| Publishing | Centralize render + revision + serialization + publish; remove duplicate POST/SSE publication logic. |
| Snapshot | Serialize the same group state/revision reached by synchronization. |

The current generic server directly manipulates `seq`, `log`, `history`, and snapshot arena ownership. A narrow interface such as “prepare current view”, “current revision”, “write snapshot”, and “fetch stream update” would hide these invariants and support both shared-board and private-session implementations. [http.zig:16](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:16)

**For a missing destination group, build and seed it from current state; start a new history; snapshot the joining connection. Do not clone DOM or copy the ring initially.** That trades a transition snapshot for substantially simpler ownership and replay correctness. If draft preservation makes that unacceptable, retain a private stream after divergence or implement a measured transition-preserving fork later.

My rough estimate is **400–800 production lines changed/added across 5–8 files, plus 300–600 lines of regression coverage**. Deep-copy forks, lineage-preserving merges, and draft-preserving transitions push it materially beyond that. This is not a small pointer-sharing patch.

The essential acceptance cases are two unequal cursors, late join with unpublished model changes, destination revision lower/equal/higher, A→B→A between polls, identity minting on failed dispatch, eviction/recreation, and same-route second-tab GET.

**Verdict:** deterministic rendering supports groups. The fatal flaw in the proposal as written is treating view equality as replay compatibility. Explicit membership epochs and snapshot transitions make the simpler version correct; cloning histories is an optimization to justify later.
