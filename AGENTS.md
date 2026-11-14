# Repository Guidelines

## Project Structure & Module Organization
`zforest` hosts four server-driven apps on one transport: the `zefx`
reactive core plus a `forest` fine-grained DOM patch layer and a minimal
generic `std.http` server. `zforest` is the Todo demo (per-session
model); `zboard` is an anonymous board (shared SQLite-backed model);
`zmon` is a live ops dashboard on fine-grained live bindings; `zcar` is
a service-booking demo (vehicle cascade, service catalogue, upsells,
combo discounts, booking history).

- `src/zefx/root.zig`: public API surface exported as module `zefx`.
- `src/zefx/engine.zig`, `event.zig`, `store.zig`, `sample.zig`, `shape.zig`, `effect.zig`: reactive graph primitives and operators.
- `src/forest/patch.zig`: HTML escaping + `Patch`/`PatchLog` (owned strings, JSON batch; `writeOpJson` serializes one op).
- `src/forest/dom.zig`: server-side DOM state tracking, text/attr bindings, keyed list diff, `when_states` branch keys for `z-when` anchors.
- `src/forest/view.zig`: declarative view tree (`el`/`text`/`raw`/`eachOf`/`fragment`/`computed`/`variant`/`when`) — one tree drives SSR (`writeHtml`), the DOM-patch `diff`, and the full-state snapshot (`writeSnapshotOps`). Attrs and `.text` accept duck-typed `*T.get()` store pointers and `computed` wrappers resolved lazily; `.on`/`.arg` emit `data-on-<event>`/`data-arg` DOM-event attrs; `variant`/`when` mount/unmount subtrees between `<!--z-when:ID-->` comment pairs via idempotent `when` ops. `bindTree` is the live mode: subscribes bound leaves (`Bound.live`, populated when the store exposes `watchCtx`/`unwatch`/`Value`) so store notifications emit patch ops with no rebuild — used by zmon; see ARCHITECTURE.md "Live bindings".
- `src/apps/todo/`: the TodoMVC app on the zmeta convention — `app.zig` holds the per-session model (`TodoDeps`: todos/filter/sparse edit state, `mutate` event, `remaining` derived store, `on_<action>` handlers), `pages/index.zig` the single "/" view, `actions.zig` the manifest, `gen/` the checked-in codegen output. `Session.dispatch` is the whitelisted action entry (`{action, arg?, value?, fields?}`).
- `src/board.zig`: shared `BoardModel` — static board whitelist, in-memory posts/comments/users, write-through SQLite, one shared `next_id` (`#N` display ids), and the `global_seq` atomic every session polls for fan-out.
- `src/db.zig`: typed wrapper over the vendored sqlite3 amalgamation (`vendor/sqlite3`, official 3.54.1; flags `-DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION`). Linked only into `zboard` and test binaries — never the `zforest` exe.
- `src/board_app.zig`: zboard session/view — routes (`/`, `/b/<slug>`, `/t/<post>`, `/t/<post>/c/<comment>`), sidebar nav, post/comment forms, nested keyed comment trees, `w-rep-N` inline reply anchors, `zfxu` anonymous identity cookie, per-session `reply_to`.
- `src/board_main.zig`: `zboard` executable entry point (`zboard [port] [bind-ip] [db-path]`).
- `src/apps/car/`: the zcar booking app on the zmeta convention — `app.zig` holds the per-session model (`CarDeps`: vehicle cascade, service cart `AutoHashMapUnmanaged`, upsell suggestions, bookings, `mutate` event, `on_<action>` handlers, cart math/discounts/suggestions), `car_data.zig` the static catalogue (brands/models/years with specs, service list by `Cat`, combo rules), `pages/index.zig` the single "/" view, `actions.zig` the manifest, `gen/` the checked-in codegen. `discounts` writes into a caller buffer (no stack-slice escape).
- `src/apps/mon/`: the zmon live ops dashboard on the zmeta convention — `app.zig` holds `MonDeps` (per-session stores/arenas/view cache/`ping`, `.live_shared` archetype, the live render-path overrides `servePage`/`render`/`writeView`/`buildViewNodes`/`seedDom`), `mon_model.zig` the module-global shared `MonModel` (ticker thread mutates under its mutex), `pages/index.zig` the once-built dashboard view (live `Bound` leaves), `actions.zig` the manifest, `gen/` the checked-in codegen.
- `src/car_main.zig`: `zcar` executable entry point (`zcar [port] [bind-ip]`).
- `src/mon_main.zig`: `zmon` executable entry point (`zmon [port] [bind-ip]`; spawns the model ticker thread).
- `src/zmeta/`: plain-source meta-framework layer (NOT a named module — relative imports preserve `History`/`Dom`/`zefx`/`forest` type identity). `session.zig` is the generic `Session(Deps)` skeleton, `env.zig` the render context, `root.zig` the plain-source export surface, `gen.zig` the routing/action codegen (`zig build gen`).
- `src/apps/<name>/`: zmeta app dirs — `pages/**/*.zig` (file-based routes; `[name]` segments → typed `params` fields), `actions.zig` (action-name manifest), generated `gen/routes.zig` + `gen/actions.zig` (checked in).
- `src/zmeta_demo_main.zig`: `zmeta-demo` executable entry point (`zmeta-demo [port] [bind-ip]`); flat `src/` placement keeps every relative import inside the module path.
- `src/server/http.zig`: generic-over-`Session` HTTP/SSE server (cookie sessions, POST /action → ACK, GET /events → SSE stream, `Ip4Address` bind, `setRoute`/`servePage`/`syncPull`/`out_cookie`/`readCookies` hooks, per-action `Set-Cookie`).
- `src/server/history.zig`: bounded per-session ring of serialized patch batches for SSE subscribers.
- `src/server/stream.zig`: `{rev,ops}` snapshot serialization for SSE snapshot events.
- `src/client.js`: app-agnostic DOM patch renderer + delegated `data-on-*` event → action POST plumbing; `src/style.css`: app styling.
- `src/main.zig`: executable entry point.
- `build.zig`: build graph, run step, and test step definitions.
- `build.zig.zon`: package metadata (`minimum_zig_version = 0.17.1`).

## Architecture decisions
- `ARCHITECTURE.md` records every architecture discussion and its
  outcome (reactivity granularity, state ownership, lifecycle,
  transport). **Any design discussion must be summarized there before
  the session ends** — conversation context is lossy, the file is not.
  Read it before proposing or reviewing architectural changes.

## Architecture notes

- Transport: `GET /events` is a Server-Sent Events stream (initial
  `snapshot`, then `patch` events with `id: rev`); `POST /action` mutates
  the model and returns only an ACK `{rev}`. Sessions are keyed by a
  random `HttpOnly; SameSite=Strict` cookie; EventSource auto-reconnect
  always gets a fresh snapshot, which resyncs the DOM.
- Store updates happen in the pure phase; derived stores (`map`/`sample`/
  `combine`) propagate via a settle loop that runs before view watchers.
  Watchers that re-dirty a store re-queue it for the same tick.
- Rendering happens in an engine after-flush hook: `buildView` produces a
  `view.zig` tree that is diffed via `Dom` into `PatchLog`; the same tree
  renders the SSR page (`writeView`) and the snapshot `ops`
  (`buildViewNodes` → `writeSnapshotOps`).
- zboard's model is shared across sessions while each session keeps its
  own graph/DOM state: mutations bump `BoardModel.global_seq`, and each
  SSE worker's `syncPull()` re-renders (publishing the batch) when the
  counter moved — cross-tab fan-out through the normal patch pipeline.
- The server spawns one worker task per accepted connection
  (`std.Io.Group.concurrent`, thread-per-connection; beyond 128 concurrent
  connections the socket is closed before any headers are read — no inline
  fallback, since a long-lived SSE stream would freeze the accept loop).
  Sessions/model/history are serialized by `std.Io.Mutex`, never held
  across network I/O; the POST body is read before the lock. SSE workers
  poll session history every 50 ms in-process. Demo session cap: 32
  (FIFO evict → `session_expired` event).
- Generated artifacts: `.zig-cache/` and `zig-out/` (do not edit manually).

## Build, Test, and Development Commands
- `zig build`: compile and install the executables (`zforest`, `zboard`, `zmon`, `zcar`, `zmeta-demo`).
- `zig build run`: run the todo server on 127.0.0.1:8080 (port arg optional).
- `zig build run-board`: run the board server (`zboard [port] [bind-ip] [db-path]`).
- `zig build run-mon`: run the dashboard (`zmon [port] [bind-ip]`).
- `zig build run-car`: run the booking demo (`zcar [port] [bind-ip]`).
- `zig build run-demo`: run the zmeta codegen demo (`zmeta-demo [port] [bind-ip]`).
- `zig build gen`: regenerate `src/apps/*/gen/*.zig` from pages/ + actions.zig manifests.
- `zig build test`: run module + executable test targets for all apps.
- `zig build -Doptimize=ReleaseFast`: build with release optimization.
- `zig fmt src/**/*.zig build.zig`: format code before committing.

## Coding Style & Naming Conventions
- Use `zig fmt` as the source of truth (4-space indentation, consistent wrapping).
- Keep filenames lowercase snake-style (`engine.zig`, `sample.zig`).
- Use `PascalCase` for types (`Engine`, `Event`, `Store`) and `camelCase` for functions (`createEvent`, `createStore`, `trackGraphAlloc`).
- Keep public API in `src/root.zig`; keep implementation details in focused modules.
- Prefer explicit, typed helpers over broad `anytype` unless API flexibility requires it.

## Testing Guidelines
- Use Zig built-in tests with `test "..." { ... }` blocks, colocated in the relevant module file.
- Test names should describe behavior, e.g. `test "sample updates target store on clock"`.
- Run `zig build test` locally before opening a PR.
- Cover reducer ordering, watcher phase behavior, and edge cases in `sample`/`guard` flows.

## Commit & Pull Request Guidelines
- Follow concise, imperative commit subjects, as seen in history:
  - `Add README with API docs and usage examples`
  - `Initial release: zefx v0.1.0`
- Keep subject lines focused; add a body when changing API or execution semantics.
- PRs should include: problem statement, design/behavior summary, test evidence (`zig build test` output), and updated docs/examples when public API changes.
