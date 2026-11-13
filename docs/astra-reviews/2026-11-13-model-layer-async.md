<!-- Astra (gpt-6-astra) review: model layer + async effects Session: 01a1d474-31f5-7022-acea-a4ca195f7827. Summary recorded in ARCHITECTURE.md "Astra review: model layer + async".  -->

**I recommend application-level model factories, without adding a new model/domain runtime to zefx. For async, choose (a): host-owned execution outside the mutex, with owned completions entering the serialized model path. Keep synchronous effects as an explicitly limited execution mode.**

That refines the earlier recommendations in [ARCHITECTURE.md](/Users/rafkat/Apps/tmp/zforest/ARCHITECTURE.md:254): application composition is useful now; a generic factory framework, thread pool inside zefx, and debounced persistence still are not.

One correction to the premise: Todo currently stores `todos` in a plain `ArrayListUnmanaged`, with plain `filter` and `ui_state`; its stores are `seq` and `remaining`. See [todo_app.zig](/Users/rafkat/Apps/tmp/zforest/src/todo_app.zig:64).

**1. Model ownership and stores**

`Session` is the right lifetime owner for session-local state. It is becoming too broad an implementation module: domain rules, HTTP decoding, graph wiring, rendering, and resource cleanup all live together.

Extract a `CarModel` that can run with an engine and no HTTP or Forest. Let `Session` own:

- The engine and model instance.
- DOM tracking, patch log, history, and rendering arenas.
- Cookies, CSRF, and transport routing.
- Translation from wire actions into typed model events.

The model owns selection invariants, cart calculations, booking validation, and booking outcomes. Its public interface exposes input events and observable outputs; effect handlers are injected dependencies, not something the view calls.

A normal Zig constructor returning a model struct is enough. `Domain` currently aliases `App`, and `BoundDomain` mostly forwards constructors and operators to its engine; neither provides an independent lifecycle or isolation mechanism. Adding another wrapper would not solve the real problems. See [root.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/root.zig:18).

Keep model instances alive for their engine’s lifetime for now. Factory-created models must not imply independent disposal: the engine retains store pointers, reducer contexts, and cleanup entries until teardown. Also keep the engine and any captured model contexts at stable addresses. See [engine.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/engine.zig:26).

The decision rule for stores should be:

> Use stores for values whose changes participate in reactive decisions or observable projections. Keep resources and bulk storage under explicit ownership, with a defined notification path.

“Visible in the UI” alone does not mean “must be a store.” The diff renderer can correctly render plain model state after explicit invalidation. But a `computed` getter over plain fields does not establish reactive dependencies.

| State | Recommended representation |
|---|---|
| Vehicle selection, selected services, operation status | Source stores |
| Available models/years, vehicle validity, totals, discounts, suggestions | Derived stores or pure projections of store values |
| Static catalogue | Plain immutable data |
| Allocators, SQLite connections, queues, DOM/history, subscription handles | Plain infrastructure |
| Large entity collections | Owned model storage with explicit committed revisions/projections; avoid one store per entity |
| Browser-only unsubmitted input | Keep local until submission unless server-side draft behavior is needed |

Applied to the other apps:

- **Todo:** its plain collection and sparse editing map remain reasonable on the diff path. Put them behind a model interface and explicit change notification; do not mechanically wrap a mutable list in `Store(ArrayList)`.
- **Board:** shared posts/comments belong to `BoardModel`, independently of session lifetimes. A session graph should hold its reply selection, operation status, and projections. `global_seq` is a valid coarse invalidation mechanism; bypassing a session graph for shared ownership is not inherently wrong. See [board_app.zig](/Users/rafkat/Apps/tmp/zforest/src/board_app.zig:176).
- **zmon:** its shared accumulator and rings can remain plain, synchronized storage; session-facing metrics deserve stores because live bindings subscribe to them. Import one coherent snapshot through one event/batch. Currently `refreshStores()` performs separate reads and separate store writes, while those reads acquire the model mutex independently. Batching notifications alone would not make the source snapshot coherent. See [mon_app.zig](/Users/rafkat/Apps/tmp/zforest/src/mon_app.zig:214) and [mon_model.zig](/Users/rafkat/Apps/tmp/zforest/src/mon_model.zig:254).

For **zcar specifically**, I would use this model shape:

| Part | Concrete recommendation |
|---|---|
| Input events | `brandSelected`, `modelSelected`, `yearSelected`, `serviceToggled`, `serviceAdded`, `bookingSubmitted` |
| `$vehicle` | One value containing optional brand/model/year |
| `$selectedServices` | A value bitset indexed by the static catalogue |
| `$vehicleOptions` | Derived available models and year range |
| `$vehicleSpec` / `$vehicleComplete` | Derived from `$vehicle` and catalogue |
| `$quote` | One derived value containing subtotal, discount entries, and total |
| `$suggestions` | Derived service IDs and reason codes from vehicle + cart |
| Booking state | Confirmed records, current operation/error, and later async lifecycle stores |
| Plain dependencies | Static catalogue, storage ownership, injected booking executor |

The catalogue currently has 23 sequential service IDs, so a value bitset is simpler than a heap-owning hash map and gives straightforward immutable updates. See [car_data.zig](/Users/rafkat/Apps/tmp/zforest/src/car_data.zig:147).

**The selected model and year are user choices, not derivations of the brand.** The available options are derived. The reset rules are state transitions:

- Selecting a brand replaces `$vehicle` with `{brand, null, null}`.
- Selecting a model validates it against the current brand and replaces the model/year together.
- Selecting a year validates it against the current model.

One aggregate vehicle store makes those invariants atomic without relying on three independently writable stores settling in the right order. It preserves the current cascade in [car_app.zig](/Users/rafkat/Apps/tmp/zforest/src/car_app.zig:344).

Move semantic validation into the model so direct model callers cannot create invalid combinations. `Session.dispatch` should parse the wire shape and emit typed events. For model choices, prefer a stable identity or include the parent brand: today a delayed model index can be valid under a different brand and silently identify a different car.

On `bookingSubmitted`, sample the vehicle, cart, quote, and submission payload into one validated booking input. Contact fields can remain browser-local until then; the current app has no need for server-side per-keystroke contact stores.

Keep numeric prices and structured suggestion reasons in the model. Format strings in the view. Avoid storing slices into `render_arena`, and do not copy heap-owning maps/lists into stores while continuing to mutate their backing memory.

This model still uses rebuild+diff rendering: keyed options, cart rows, and booking history are structural. Moving business state into stores does not require adopting live rendering.

There is a prerequisite: **the proposed `event → sample → effect` flow needs the existing `sample` defects fixed first.** `MakeWire.run` currently discards the clock payload, and non-store targets receive `.emit`, which effects do not expose. Sampling also occurs as ordinary reducers rather than a guaranteed post-settle step. A model wrapper cannot repair those semantics. See [sample.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/sample.zig:79).

**2. Async execution and completion semantics**

Today “effects phase” means a scheduling phase, not asynchronous execution. `Effect.run` invokes the handler during `flush`; its context lives in the tick arena. HTTP dispatch holds the server-wide mutex through mutation, rendering, and publication. One blocking handler therefore stalls unrelated sessions served by that server. See [effect.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/effect.zig:30), [engine.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/engine.zig:91), and [http.zig](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:285).

My assessment:

| Option | Verdict |
|---|---|
| **(a) Host executor + serialized completions** | Recommended for blocking I/O and expensive work |
| **(b) Synchronous effects, documented** | Valid for short bounded work and current demos; insufficient as the general async story |
| **(c) Async engine/thread per effect** | Avoid. Keep graph evaluation synchronous; use workers or an event loop in the host |

Initially, introduce a distinct asynchronous effect interface rather than silently changing existing `Effect.run` behavior.

The execution protocol should be:

1. **Under serialization:** process the input event, sample current state, validate, allocate a request ID, and construct an owned job.
2. **Admit without waiting:** reserve bounded execution/completion capacity. On rejection, produce an explicit overload outcome. Never wait for worker capacity while holding the model mutex.
3. **Finish the graph turn:** publish pending state and release the mutex.
4. **Outside serialization:** the host executes the job. Workers receive immutable input and permitted resource handles, never `Session*`, `Store*`, or tick-arena contexts.
5. **Return an owned completion:** a host dispatcher looks up the owner and delivers a typed outcome through its serialized path.
6. **Process a new graph turn:** update lifecycle and domain state, settle, render, publish history, then release completion memory.

The completion dispatcher must work even with no SSE subscriber. SSE polling should transport results, not determine whether business work finishes.

The interface needs these explicit contracts:

| Concern | Required contract |
|---|---|
| **Request identity** | Unique invocation ID within an owner incarnation; separate from DOM revision and business idempotency key |
| **Session identity** | Opaque session handle plus generation/incarnation; `(cookie, route)` alone can be recreated |
| **Ownership** | Deep-owned input/output bytes; exactly one cleanup path for success, failure, rejection, cancellation, and stale delivery |
| **Capacity** | Bounds on queued jobs, running jobs, completion backlog, and bytes; per-owner fairness |
| **Terminal delivery** | Exactly one recognized terminal transition per admitted invocation; duplicate/late messages are ignored and freed |
| **Shutdown** | Stop admission, drain or cancel with defined outcomes, join workers before destroying resources they use |

Session eviction currently immediately destroys the session. The proposed generation check must happen before resolving an effect pointer, and workers must not capture that pointer in the first place. See [http.zig](/Users/rafkat/Apps/tmp/zforest/src/server/http.zig:99).

Reserve completion capacity when admitting work, or retain a bounded completion record per outstanding request. Dropping a completion because a queue is full can leave `pending` stuck forever.

**`inFlight` must be the source; `pending` must be derived as `inFlight > 0`.** Count admitted, unfinished invocations, including queued work. Decrement only when a matching outstanding request reaches its terminal transition. The current implementation sets `pending=false` on any `done` or `fail`; that cannot represent overlapping invocations. See [root.zig](/Users/rafkat/Apps/tmp/zforest/src/zefx/root.zig:126).

Stale-result filtering must not suppress lifecycle cleanup. An obsolete quote result still finishes its invocation even if its value is rejected.

Ordering needs an application policy:

- **Queries/quotes:** latest-request-wins, checked using request ID and relevant input version.
- **Independent writes:** apply every successful result by operation identity.
- **Conflicting writes:** serialize per resource or use expected-version checks.
- **Cancellation:** best effort; it does not undo a completed external write.

The serialized completion turn establishes when a result affects current state. Starting a job does not reserve its position ahead of all subsequent actions.

For zcar, capture a draft version with the booking input. If booking A completes after the user changes the cart, append A’s confirmed booking, but clear the cart only if its draft version still matches A’s captured version. Otherwise the current synchronous `services.clearRetainingCapacity()` behavior would erase newer work. See [car_app.zig](/Users/rafkat/Apps/tmp/zforest/src/car_app.zig:368).

Timeouts on writes may mean **outcome unknown**, not “nothing happened.” Retrying those operations requires a stable business idempotency key and reconciliation.

**Board persistence should remain commit-before-success**

The current ordering is sensible: validate → SQLite INSERT → append to memory → bump `global_seq`. Preserve that logical ordering while moving database work outside the server mutex. See [board.zig](/Users/rafkat/Apps/tmp/zforest/src/board.zig:336).

I would use one bounded board writer module that owns the SQLite connection and orders write commands. It produces owned committed records. The serialized shared-model path applies those records in commit order, updates indexes, and bumps `global_seq`; session projections then catch up normally.

Do not merely run the existing `addPost()` on a worker: it also mutates shared arrays and allocates `next_id` under assumptions about the server mutex.

Allocate IDs in one authoritative writer order, retain the shared post/comment ID namespace, and validate dependent operations against that ordering. Group identity creation and content insertion transactionally when they form one logical command.

For ACKs, my first implementation would **preserve the existing success semantics**:

- The POST waits outside the model mutex for commit and shared-model application.
- HTTP success means the command committed and was applied; SSE rendering can arrive separately.
- The wait retains an operation handle, not a session pointer.
- Admission failure returns immediately; ambiguous completion uses operation identity for reconciliation.

This costs a waiting connection, so bound waiters as well as jobs.

A later `202 Accepted` protocol can return an operation ID and expose pending/confirmed/failed state. It requires a deliberate client change: [client.js](/Users/rafkat/Apps/tmp/zforest/src/client.js:309) currently clears submitted fields after successful HTTP completion. Returning “queued” through that path would clear drafts before persistence succeeds.

Crucially, **a committed board write survives the originating session’s eviction**. Apply its shared result regardless; only session-specific notification is generation-gated. Session lifetime is not business-operation lifetime.

For persistence policy:

- **No debounce for posts/comments.** They are distinct commands that must all survive.
- **No default write-behind.** Publishing success before persistence introduces a separate recovery protocol.
- **Optional bounded transaction batching:** preserve every command and acknowledge only after its transaction commits.
- **Retries:** classify errors, use bounded backoff outside locks, and persist idempotency information where duplicate writes matter.

Also distinguish database commit from a promised crash-durability level: the current schema explicitly chooses WAL with `synchronous=NORMAL`; the ACK contract should name its durability guarantee rather than imply one. See [board.zig](/Users/rafkat/Apps/tmp/zforest/src/board.zig:75).

I would implement this in order: repair sampling and batching semantics; extract zcar’s model; add owned async invocation/completion handling with a controllable test executor; then move board persistence to the ordered writer. Keep HTTP, SQLite, worker scheduling, and timers outside zefx.

This was a static source review; I did not run tests or change files. The required architecture-log update remains outstanding because this session’s filesystem is read-only.
