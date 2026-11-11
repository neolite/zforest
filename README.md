# zforest

Server-driven Todo UI in Zig: the `zefx` reactive graph core plus `forest`, a
fine-grained DOM patch layer, served by a minimal `std.http` server with a
~150-line vanilla JS patch client. No database, no framework, no build step.

## Run

```sh
zig build        # produces zig-out/bin/zforest
zig build run    # serves http://127.0.0.1:8080
./zig-out/bin/zforest 8081  # custom port
zig build test   # engine, forest, and session tests
```

## How it works

1. `GET /` creates a per-browser-session model (random `zfxs` cookie,
   `HttpOnly; SameSite=Strict`) and returns fully rendered HTML plus a
   per-session CSRF token in a `<meta>` tag.
2. The client opens `GET /events` (Server-Sent Events, cookie auth) and
   waits for the first `event: snapshot` before enabling any
   `data-on-submit` controls. Each snapshot is `{"rev","ops"}` — the
   declarative view serialized as a full-state ops array
   (`forest.writeSnapshotOps`): keyed parents as `html` ops, bound nodes
   as `attr`/`text` ops. Each `event: patch` (with `id: rev`) is
   `{"rev","patches"}`.
3. Interactions are declared in the view: `.on = .{ .click = "delete" }`
   emits `data-on-click="delete"` and `.arg` emits `data-arg`. Delegated
   document listeners in `client.js` (which has zero app knowledge) turn
   them into `POST /action` JSON — `{action, arg?, value?, fields?}`
   with an `X-Zforest-CSRF` header; `fields` carries a submitted form's
   named inputs. The server replies with an ACK `{"rev":N}` only —
   patches are never in the response body.
4. `Session.dispatch` validates the whitelisted action and emits a zefx
   event; reducers mutate the model in the **pure
   phase**, a settle loop propagates derived stores (`seq` → `remaining`),
   and an after-flush hook rebuilds the declarative view tree
   (`src/forest/view.zig`: `el`/`text`/`eachOf`/`computed` nodes, with
   store-pointer bindings resolved lazily) and diffs it against
   the tracked DOM into a `PatchLog`. The same tree also renders the SSR
   page and the snapshot `ops` — one description, all outputs.
   Under the
   model mutex the batch is serialized once, published into the session's
   bounded history (64 batches / 2 MiB, oldest evicted), and every SSE
   subscriber of that session receives its own copy.
5. The client applies ops (`create`/`remove`/`move`/`text`/`attr`/`html`)
   with `<template>` parsing + `insertBefore` for creates (trusted
   server-generated HTML with escaped data), `textContent` for text,
   `innerHTML` for `html` state dumps, and an
   attribute whitelist for `attr` ops. Patch batches with `rev <= lastRev`
   are ignored; a `snapshot` event resets state wholesale.

## Scope notes (deliberate)

- SSE resync: `EventSource` auto-reconnects on any drop; every fresh
  `/events` connection starts with a full `snapshot`, which always
  resyncs the DOM (simpler than Last-Event-ID replay). If a subscriber's
  cursor fell behind the retained history, the server sends a snapshot
  instead of patches. A `session_expired` event means the cookie's session
  is gone — the client stashes the draft and reloads once (loop-guarded).
- CSRF: `POST /action` requires either a matching `X-Zforest-CSRF` token or a
  same-origin `Origin`/`Host` pair; everything else is 403. No CORS headers
  are ever emitted, and the SSE token never appears in a URL.
- Concurrency: one task per connection via `std.Io.Group.concurrent`
  (a thread per connection — simple, not an event loop; bounded at 128 concurrent
  connections; admissions beyond the cap are closed before any HTTP
  headers are read). All session/model state is serialized by a
  `std.Io.Mutex` that is never held across network I/O or sleeps; the
  request body is read before the lock is taken. SSE workers poll the
  history every 50 ms in-process and emit a heartbeat comment ~every 10 s.
- Idle connections are not timed out (demo limitation); sessions cap at 32
  with FIFO eviction of the oldest — eviction while streaming produces
  `session_expired`.
- Queues and the patch arena can grow; there is no hard allocation bound —
  this is not a zero-allocation design.
- `zefx` core: two-phase flush (pure → effects) with generational
  subscription slots, `watchCtx`, cursor-drained queues, and after-flush
  hooks. See `src/zefx/root.zig` tests for semantics.
