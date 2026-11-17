# Repository Guidelines

## Project Structure & Module Organization
`zforest` is the FRAMEWORK repo: the `zefx` reactive core plus a
`forest` fine-grained DOM patch layer, a `zmeta` session/meta-framework,
and a minimal generic `std.http` server — all under `src/`, exposed as
named Zig modules: `zefx`, `forest`, `zserver` (`server/http.zig`),
`zmeta` (`zmeta/root.zig`), plus `zdb` (the sqlite wrapper) and
`zassets` (embedded `client.js`/`style.css`). The example apps that
consume these modules — `zforest` (todo), `zboard`, `zmon`, `zcar`,
`zmeta-demo` — live in the sibling repo
[neolite/zforest-examples](https://github.com/neolite/zforest-examples),
checked out as `../zforest-examples` relative to this repo (or consumed
via `.path = "../zforest"` from that side). `History`/`Dom`/`zefx`/
`forest` type identity is enforced by the module graph (one type per
program): consumers pull the SAME `*Module` objects via
`dep.module(name)`, and no framework file may import app code — the
dependency arrow only ever points app → framework.

- `src/zefx/root.zig`: public API surface exported as module `zefx`.
- `src/zefx/engine.zig`, `event.zig`, `store.zig`, `sample.zig`, `shape.zig`, `effect.zig`: reactive graph primitives and operators.
- `src/forest/patch.zig`: HTML escaping + `Patch`/`PatchLog` (owned strings, JSON batch; `writeOpJson` serializes one op).
- `src/forest/dom.zig`: server-side DOM state tracking, text/attr bindings, keyed list diff, `when_states` branch keys for `z-when` anchors.
- `src/forest/view.zig`: declarative view tree (`el`/`text`/`raw`/`eachOf`/`fragment`/`computed`/`variant`/`when`) — one tree drives SSR (`writeHtml`), the DOM-patch `diff`, and the full-state snapshot (`writeSnapshotOps`). Attrs and `.text` accept duck-typed `*T.get()` store pointers and `computed` wrappers resolved lazily; `.on`/`.arg` emit `data-on-<event>`/`data-arg` DOM-event attrs; `variant`/`when` mount/unmount subtrees between `<!--z-when:ID-->` comment pairs via idempotent `when` ops; `island` marks a transparent binder-owned subtree (`bindIslands` subscribes its `Bound.live` leaves while `diff` skips it). `bindTree` is the live mode: subscribes bound leaves (`Bound.live`, populated when the store exposes `watchCtx`/`unwatch`/`Value`) so store notifications emit patch ops with no rebuild; see ARCHITECTURE.md "Live bindings".
- `src/zmeta/`: the meta-framework layer as NAMED module `zmeta` (root `root.zig` export surface; imports `{zefx, forest, zserver}` so `History`/`Dom`/`zefx`/`forest` types stay identical to what the server and apps see). `session.zig` is the generic `Session(Deps)` skeleton (incl. the optional `Deps.beforeAction` pre-dispatch hook), `env.zig` the render context. `gen.zig` (routing/action codegen) and `scaffold.zig` (`new-app` scaffolder) are std-only CLI tools SHIPPED with the framework but EXECUTED by the examples repo — apps reach zmeta through a per-app `zmeta.zig` shim re-exporting the named module; here gen/scaffold exist only as test targets.
- `src/server/http.zig`: generic-over-`Session` HTTP/SSE server — named module `zserver` (cookie sessions, POST /action → ACK, GET /events → SSE stream, `Ip4Address` bind, `setRoute`/`servePage`/`syncPull`/`out_cookie`/`readCookies` hooks, per-action `Set-Cookie`). Re-exports `History` and `writeSnapshotJson` as the public type surface.
- `src/server/history.zig`: bounded per-session ring of serialized patch batches for SSE subscribers.
- `src/server/stream.zig`: `{rev,ops}` snapshot serialization for SSE snapshot events.
- `src/db.zig`: typed wrapper over the vendored sqlite3 amalgamation (`vendor/sqlite3`, official 3.54.1; flags `-DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION`). Compiled as named module `zdb` with the C sources/flags on the module itself — whichever app exe imports it links sqlite exactly once; the framework never imports it.
- `src/assets.zig`: named module `zassets` — the only file whose package path (`src/`) can `@embedFile` `client.js`/`style.css`; imported by `zserver` only.
- `src/client.js`: app-agnostic DOM patch renderer + delegated `data-on-*` event → action POST plumbing; `src/style.css`: app styling.
- `vendor/sqlite3/`: the sqlite3 amalgamation — listed in `build.zig.zon` `paths` so it ships to dependency consumers.
- `build.zig`: module graph + test step definitions (no executables — apps live in zforest-examples).
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
- Shared-model fan-out is an app-side pattern: each session keeps its
  own graph/DOM state while mutations bump a model-global sequence
  counter; each SSE worker's `syncPull()` re-renders (publishing the
  batch) when the counter moved — cross-tab fan-out through the normal
  patch pipeline (see the zboard app in zforest-examples).
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
- `zig build`: configure the module graph — this repo ships NO executables (apps live in zforest-examples).
- `zig build test`: run all framework module + tool test targets (zefx, forest, zserver, zmeta, zdb, gen, scaffold).
- `zig build -Doptimize=ReleaseFast`: release-optimized test binaries.
- `zig fmt src/**/*.zig build.zig`: format code before committing.
- App-side commands (`run*`, `gen`, `new-app`) live in the zforest-examples repo — its `build.zig` roots tool modules at this repo's `src/zmeta/{gen,scaffold}.zig` via `dep.path(...)` with cwd pinned there, so `src/apps/` resolves in the examples repo.

## Coding Style & Naming Conventions
- Use `zig fmt` as the source of truth (4-space indentation, consistent wrapping).
- Keep filenames lowercase snake-style (`engine.zig`, `sample.zig`).
- Use `PascalCase` for types (`Engine`, `Event`, `Store`) and `camelCase` for functions (`createEvent`, `createStore`, `trackGraphAlloc`).
- Keep public API in `src/root.zig` / module roots; keep implementation details in focused modules.
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
