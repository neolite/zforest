# Getting started with zmeta

zmeta is the meta-framework layer of zforest: file-based routes, typed
params, generated action dispatch, and a `Session(Deps)` skeleton —
server-rendered HTML plus SSE patches, no client runtime, no hydration.

> **Repo note:** the framework lives in `neolite/zforest`; apps (and all
> commands below) live in `neolite/zforest-examples`. `src/apps/` paths
> in this guide refer to the examples repo — check it out as a sibling
> of the framework repo (`../zforest` relative to examples).

This guide mirrors the shape of a Next.js "getting started" page:
install, project layout, core concepts, first page.

## Install

Prerequisite: Zig **0.17.1** (`zig version`).

```sh
git clone https://github.com/neolite/zforest
git clone https://github.com/neolite/zforest-examples
cd zforest-examples   # sibling of ../zforest — the path dependency
zig build        # produces zig-out/bin/{zforest,zboard,zmon,zcar,zmeta-demo}
zig build test   # app test targets (framework tests: cd ../zforest && zig build test)
zig build run-demo   # serves the zmeta demo on http://127.0.0.1:8084
```

The demo is the reference app: open `/`, click around, then read
`src/apps/zmeta_demo/` (in zforest-examples) — every concept below
lives there.

### Scaffolding a new app

```sh
zig build new-app -- my_app
```

creates `src/apps/my_app/` (`app.zig`, `pages/index.zig`,
`actions.zig`, `zmeta.zig`, `main.zig` — the exe entry point lives
inside the app dir), and regenerates `gen/` — then prints the ~15
`build.zig` lines needed to register the executable. Unregistered
apps are inert: nothing imports them, so `zig build`/`zig build test`
stay green.

## Project layout

```
src/apps/<name>/
├── main.zig         executable entry point (zserver.serve + app.Session)
├── zmeta.zig        shim re-exporting the `zmeta` named module
├── pages/            file-based routes — one .zig per page
│   ├── index.zig     "/"
│   ├── about.zig     "/about"
│   ├── _layout.zig   optional layout wrapping pages in its dir + below
│   ├── _middleware.zig optional pre-prepare gate, same dir scoping
│   ├── item/
│   │   └── [id].zig  "/item/:id" — typed int segment
│   ├── tag/
│   │   └── [tag].zig "/tag/:tag" — string segment (`[]const u8`)
│   └── docs/
│       ├── [...rest].zig  "/docs/*" — catch-all remainder (last only)
│       ├── [[...rest]].zig "/wiki/*" — OPTIONAL catch-all: also "/wiki"
│       └── api/ping.zig   "/api/ping" — JSON endpoint, no view
├── actions.zig       action-name manifest (one per line-ish list)
├── app.zig           Deps: model, on_<action> handlers, prepare/view glue
├── entities/         optional FSD slice — domain state leaf (zboard ref)
├── features/         optional FSD slice — session-bound features
├── shared/           optional FSD slice — shared view components/helpers
└── gen/              GENERATED — routes.zig + actions.zig (checked in)
```

(zforest-examples repo; the framework modules — `src/zefx/`,
`src/forest/`, `src/zmeta/`, `src/server/`, `src/db.zig`,
`src/client.js`, `src/style.css` — live in the sibling `../zforest`
repo and are consumed as named Zig modules.)

Layer dirs are created on demand as the app grows — `entities/`
holds domain state, `features/` session-bound behavior, `shared/`
reusable view pieces (meta-framework.md §5.6 has the import rules;
zboard is the reference). Codegen only scans `pages/`, so slices
never affect `gen/` output.

## Core concepts (Next.js → zmeta)

| Next.js | zmeta | Notes |
|---|---|---|
| `app/` or `pages/` dir | `src/apps/<name>/pages/` | file = route, `[id].zig` = dynamic segment |
| dynamic route params | `pub const params = struct { id: u64 }` or `{ tag: []const u8 }` | typed at compile time; int segments parse, string segments slice; `[...rest]` catch-all (last only) takes the raw tail, `[[...rest]]` is the optional variant (matches the bare prefix too); failures → 404 |
| `getServerSideProps` / middleware gate | `pub fn prepare(...) !void` | runs before view; `error.NotFound` → 404 |
| API routes | `pages/api/<name>.zig` → `pub fn api(a, s, p, env) ![]const u8` | GET /api/* → JSON body, no HTML shell; `Deps.serveApi` dispatches |
| Live island page | `pub const live = true;` in a page file | view built once per servePage; `bindTree` pushes leaf ops, `render()` skips diff — all dynamic content must be store-bound |
| Per-leaf island | `h.island(a, .{ .id = "…" }, children)` in any view | transparent subtree; after first bind `diff` skips it and `Bound.live` leaves inside push ops — all dynamic content inside must be store-bound |
| server component | `pub fn view(a, s, p, env) h.Node` | returns a `forest.Node` tree via `h.*` |
| server actions / API routes | `actions.zig` manifest + `on_<name>` in app.zig | POST `/action` → ACK `{rev}`; SSE carries the patch |
| hydration / RSC payload | **none** | SSR HTML + `client.js` applies serialized ops; no client tree exists |
| `layout.tsx` | `pages/_layout.zig` | `pub fn layout(a, s, env, inner) Node`; wraps its dir + subdirs, root = `pages/_layout.zig` |
| `middleware.ts` | `pages/_middleware.zig` | `pub fn middleware(s, env) !void`; dir-scoped like layouts, runs in `prepare` before the page's own `prepare`; pages only (not `api/`); errors → 404 |
| action middleware | `Deps.beforeAction` in app.zig | optional pre-`dispatch` hook `(s, action, arg, value, fields) !void`; errors map like dispatch errors |
| `next dev` | `zig build run-demo` | no watch mode yet; rebuild + rerun |

## Your first page

1. **Add the file** — `src/apps/zmeta_demo/pages/about.zig`:

   ```zig
   const zmeta = @import("../zmeta.zig");
   const h = zmeta.h;

   pub const params = struct {};

   pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) h.Node {
       _ = s; _ = p; _ = env;
       return h.h1(a).id("about").child("About zmeta").node();
   }
   ```

2. **Regenerate** — `zig build gen` rewrites `gen/routes.zig` /
   `gen/actions.zig` (checked in, so CI sees drift).

3. **Run** — `zig build run-demo`, open `http://127.0.0.1:8084/about`.

That's the whole loop: page file → `zig build gen` → view function.
Routing, 404s, typed params, SSR and live patching are generated or
skeleton-provided.

### Layouts

Drop `pages/_layout.zig` next to your pages to wrap them all in a
shared shell — the demo's nav bar is exactly this
(`src/apps/zmeta_demo/pages/_layout.zig`):

```zig
pub fn layout(a: std.mem.Allocator, s: anytype, env: *const zmeta.Env, inner: forest.Node) forest.Node {
    return h.div(a).class("shell").children(.{ nav, inner }).node();
}
```

A `_layout.zig` in a subdirectory wraps only that subtree; layouts
nest outermost-first (`pages/_layout.zig` → `pages/item/_layout.zig`
→ page). `_`-prefixed files are reserved — other names are rejected
by `zig build gen`.

### Middleware

`pages/_middleware.zig` is the Next `middleware.ts` analogue: it runs
inside the generated `prepare` dispatch — after `setRoute`, before the
page's own `prepare` — once per page load. Directory scoping matches
layouts exactly: `pages/_middleware.zig` gates every page,
`pages/item/_middleware.zig` adds an inner gate for that subtree, and
multiple middleware run outermost-first. `env` is immutable — pass
data through app-owned `s.deps` fields; the demo counts page loads in
`DemoDeps.hits` (`src/apps/zmeta_demo/pages/_middleware.zig`). API
endpoints under `pages/api/` never run middleware. For action-level
prechecks (rate limits, auth), declare `Deps.beforeAction` in app.zig
instead — it runs before `Deps.dispatch` and its errors map like
dispatch errors.

## View ergonomics

Pages build trees with `zmeta.h` — a fluent builder over `forest`:

```zig
h.div(a).class("card")
    .child(h.span(a).class("title").text(title))
    .child(h.button(a).on(.click, actions.act.like).arg(id).child("like"))
    .node();
```

`.text()`/`.class()`/attrs accept stores and `computed(...)` — bound
leaves self-update over SSE without a rebuild. `h.f(a, "…{d}…", .{x})`
is the `allocPrint` shorthand. `forest.el` remains the canonical
low-level API; `h.*` is the ergonomic layer with identical semantics.

## Docs

- `ARCHITECTURE.md` — every design decision and its outcome.
- `docs/meta-framework.md` — the zmeta proposal and roadmap.
- `src/apps/zmeta_demo/pages/structure.zig` — live page explaining the
  request pipeline (also at `/structure` on the deployed demo).
- Deployed demo: https://zmeta.exe.xyz
