# Repository Guidelines

## Project Structure & Module Organization
`zforest` is a server-driven Todo demo: the `zefx` reactive core plus a
`forest` fine-grained DOM patch layer and a minimal std.http server.

- `src/zefx/root.zig`: public API surface exported as module `zefx`.
- `src/zefx/engine.zig`, `event.zig`, `store.zig`, `sample.zig`, `shape.zig`, `effect.zig`: reactive graph primitives and operators.
- `src/forest/patch.zig`: HTML escaping + `Patch`/`PatchLog` (owned strings, JSON batch).
- `src/forest/dom.zig`: server-side DOM state tracking, text/attr bindings, keyed list diff.
- `src/todo_app.zig`: per-browser-session Todo model wired through the zefx graph.
- `src/server/http.zig`: loopback HTTP server (cookie sessions, POST /action → ACK, GET /events → SSE stream).
- `src/server/history.zig`: bounded per-session ring of serialized patch batches for SSE subscribers.
- `src/server/stream.zig`: snapshot JSON serialization for SSE snapshot events.
- `src/client.js`: minimal DOM patch renderer; `src/style.css`: app styling.
- `src/main.zig`: executable entry point.
- `build.zig`: build graph, run step, and test step definitions.
- `build.zig.zon`: package metadata (`minimum_zig_version = 0.17.1`).

## Architecture notes

- Transport: `GET /events` is a Server-Sent Events stream (initial
  `snapshot`, then `patch` events with `id: rev`); `POST /action` mutates
  the model and returns only an ACK `{rev}`. Sessions are keyed by a
  random `HttpOnly; SameSite=Strict` cookie; EventSource auto-reconnect
  always gets a fresh snapshot, which resyncs the DOM.
- Store updates happen in the pure phase; derived stores (`map`/`sample`/
  `combine`) propagate via a settle loop that runs before view watchers.
  Watchers that re-dirty a store re-queue it for the same tick.
- Rendering happens in an engine after-flush hook (`Dom` diff → `PatchLog`).
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
- `zig build`: compile and install the demo artifact.
- `zig build run`: run the todo server on 127.0.0.1:8080 (port arg optional).
- `zig build test`: run module + executable test targets (currently mostly compile/behavior checks; add `test` blocks as features grow).
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
