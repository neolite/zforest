# Getting started with zmeta

zmeta is the meta-framework layer of zforest: file-based routes, typed
params, generated action dispatch, and a `Session(Deps)` skeleton —
server-rendered HTML plus SSE patches, no client runtime, no hydration.

This guide mirrors the shape of a Next.js "getting started" page:
install, project layout, core concepts, first page.

## Install

Prerequisite: Zig **0.17.1** (`zig version`).

```sh
git clone https://github.com/neolite/zforest
cd zforest
zig build        # produces zig-out/bin/{zforest,zboard,zmon,zcar,zmeta-demo}
zig build test   # engine, forest, session, app, and codegen tests
zig build run-demo   # serves the zmeta demo on http://127.0.0.1:8084
```

The demo is the reference app: open `/`, click around, then read
`src/apps/zmeta_demo/` — every concept below lives there.

## Project layout

```
src/apps/<name>/
├── pages/            file-based routes — one .zig per page
│   ├── index.zig     "/"
│   ├── about.zig     "/about"
│   └── item/
│       └── [id].zig  "/item/:id" — typed dynamic segment
├── actions.zig       action-name manifest (one per line-ish list)
├── app.zig           Deps: model, on_<action> handlers, prepare/view glue
└── gen/              GENERATED — routes.zig + actions.zig (checked in)
src/zmeta/            the framework: session.zig, h.zig, gen.zig, env.zig
src/zmeta_demo_main.zig  executable entry point (flat src/ placement)
```

## Core concepts (Next.js → zmeta)

| Next.js | zmeta | Notes |
|---|---|---|
| `app/` or `pages/` dir | `src/apps/<name>/pages/` | file = route, `[id].zig` = dynamic segment |
| dynamic route params | `pub const params = struct { id: u64 }` | typed at compile time; parse failures → 404 |
| `getServerSideProps` / middleware gate | `pub fn prepare(...) !void` | runs before view; `error.NotFound` → 404 |
| server component | `pub fn view(a, s, p, env) h.Node` | returns a `forest.Node` tree via `h.*` |
| server actions / API routes | `actions.zig` manifest + `on_<name>` in app.zig | POST `/action` → ACK `{rev}`; SSE carries the patch |
| hydration / RSC payload | **none** | SSR HTML + `client.js` applies serialized ops; no client tree exists |
| layouts / nested routes | — | not yet; page bodies compose via `h.fragment` |
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
