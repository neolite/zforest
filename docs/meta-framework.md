# Meta-framework layer ("zmeta") — proposal

Status: **proposal, not scheduled.** This document maps the developer-
experience concepts of Next.js/Nuxt/Astro onto zforest's existing
transport, records which ones fit and which do not, and sketches a
minimal v0. It exists so the discussion has a concrete target; per
AGENTS.md, any outcome gets summarized in ARCHITECTURE.md.

> **Repo note (post-split):** the framework lives in `neolite/zforest`;
> the apps described below live in `neolite/zforest-examples`. Every
> `src/apps/<name>/` path in this document refers to the examples repo —
> the layout convention itself is unchanged. `zig build gen` /
> `new-app` run there (tool sources stay in this repo under
> `src/zmeta/`).

## Stack recap (for readers without the code open)

zforest is server-authoritative UI in Zig 0.17.1:

- `src/zefx/` — per-session reactive graph (events, stores, derived
  stores, effects, `sample`/`attach`, batching, equality-aware writes).
- `src/forest/` — declarative view trees (`el`/`text`/`each`/`eachOf`/
  `fragment`/`variant`/`when`/`computed`, `src/forest/view.zig`) driving
  three outputs from one tree: SSR HTML (`writeHtml`), full-state
  snapshot ops (`writeSnapshotOps`), and minimal DOM patches
  (`diff` → `Dom`/`PatchLog`, `src/forest/dom.zig`, `patch.zig`).
  `bindTree` (view.zig:1024) is the opt-in live mode: bound leaves
  subscribe to stores and emit patch ops with no rebuild (zmon).
- `src/server/http.zig` — generic `std.http` server, compiled as the
  named module `zserver` (re-exports `History`/`writeSnapshotJson`).
  Cookie sessions keyed `(token, route)` (`SessionStore.keyInto`,
  http.zig:98); `GET /events` = SSE (`snapshot` then revisioned `patch`
  events, `serveEvents` http.zig:440); `POST /action` = whitelisted
  `Session.dispatch` returning ACK `{rev}` only (http.zig:286-359);
  every other GET is a page via `Session.servePage`.
- `src/client.js` — ~200-line framework-free op applier + delegated
  `data-on-*` event → action POST plumbing. No app knowledge, no
  hydration, no router (embedded via the `zassets` module).
- Apps (now in the zforest-examples repo): `src/apps/todo/` +
  `src/apps/car/` (per-session models, diff
  path, file-based routing), `src/apps/board/` (shared SQLite-backed
  `BoardModel` in `model.zig`, `global_seq` fan-out, render groups
  sharing one Dom/History/revision across N sessions, file routes for
  `/`, `/b/<slug>`, `/t/<post>`, `/t/<post>/c/<comment>`),
  `src/apps/mon/` (shared model + per-session live-bound
  stores, `.live_shared`), `src/apps/zmeta_demo/` (this convention's
  showcase). All five apps run on the `zmeta.Session` skeleton and
  the `src/apps/<name>/` file-based routing convention (`pages/` +
  `actions.zig` + `main.zig` + `zmeta.zig` shim + checked-in `gen/`).
  Framework↔app imports cross only through the named modules `zefx`,
  `forest`, `zserver`, `zmeta` (+ `zdb` for the sqlite exes).

The transport invariants a meta-framework must preserve: sessions are
`(cookie token, route)` — route IS part of session identity; every
mutation is serialized under `Server.mutex`; patches are computed
against server-tracked `Dom` state and are only valid for a client
whose DOM matches that tracking; revision numbers are per-stream-
namespace (per-session `seq` or per-render-group `rev`) and never
imply baseline equality across namespaces (membership epoch →
snapshot, ARCHITECTURE.md "Render groups v2").

## 1. Concept mapping — summary table

| Framework concept | What it buys the developer | zforest analogue today | Verdict |
|---|---|---|---|
| File-based routing | URL ↔ module map, typed params | `Route` union + `parseRoute`/`setRoute`/`validPath` per app; session key `(cookie, route)` | Maps cleanly via codegen; params become typed structs — better than today's flat unions |
| SSR | First paint without JS | `servePage` → `writeView` → `forest.writeHtml` on every GET | Already there; see §2.2 for why "SSG" is mostly meaningless here |
| Islands / hydration | Partial client JS per region | None needed — SSR + snapshot ops IS the state transfer; `when`/`variant` anchors + `bindTree` leaves + keyed lists are the region primitives | Patch protocol subsumes hydration; true islands = optional client widget registry (§2.3) |
| Nested layouts | Shared chrome per segment | Manual fn composition (`navView` + `.bmain` wrapper in `buildView`) | Works today; first-class layout chains are codegen sugar (§2.4) |
| Loaders | Server data before render | Synchronous in-process model reads inside `buildView`/`dispatch`; `readCookies` for request data | No fetch layer needed; `prepare` hook + env injection only (§2.5) |
| Client-side navigation | SPA-feel transitions | Full page load → new route-session → SSR + snapshot | MPA stays default; soft-nav is a defined v1 path (§2.6) |
| Streaming SSR / Suspense | Progressive page delivery | Single-shot `servePage`; SSE patches already stream post-load | Reject HTTP streaming; suspense analogue = `when` anchor + async completion (§2.7) |
| Middleware | Pre-routing logic | `pages/**/_middleware.zig` file convention (dir-scoped, runs in generated `prepare` before the page's `prepare`) + `Deps.beforeAction` pre-dispatch hook | Landed (§2.8); transport-level `beforeRequest` still deferred |
| Server actions / API routes | Typed server endpoints | `POST /action` → whitelisted `dispatch` → ACK `{rev}` | Already the mechanism; formalize via a typed action table (§2.9) |

## 2. Concept-by-concept

### 2.1 File-based routing

> **Update:** zboard has since migrated to this convention
> (`src/apps/board/`). Its routing is now two-layer: the generated
> `routes.Route` (wire params) lives in `Deps.route` for the
> generated `prepare`/`viewNodes` dispatch, while `Deps.page` holds
> the domain `view.Route` (`home`/`board`/`thread`/`comment`) that
> views and render-group keys use — `pageOf` in `app.zig` maps one
> to the other (slug → board index; dangling-id 404s moved from
> `setRoute` into the page `prepare` gate). The analysis below
> describes the pre-migration hand-rolled version.

Before the migration each app hand-rolled routing. zboard was the
fullest example:
`Route` union (`board_app.zig:30-35`), `parseRoute` (:62-82),
`Session.setRoute` (:207-219) which also rejects dangling ids for a
real 404, and `validPath` (:203-205) so bogus paths never mint a
session. Sessions are already keyed `(cookie token, route)` — one
browser gets an independent graph/Dom/history/CSRF per route it
visits (`SessionStore.keyInto`, http.zig:98-105; `?r=` on `/events`,
`x-zforest-route` on `/action`, http.zig:288,450). Route changes are
therefore already "new session" events, not in-place mutations.

What codegen adds:

- **Route table from files.** `pages/b/[slug].zig` → a `Route` member
  with typed params; `pages/t/[post]/index.zig` and
  `pages/t/[post]/c/[comment].zig` nest naturally. The page file
  declares `pub const params = struct { post: u64, comment: u64 };`
  and the generator uses the field types to emit the parser — the
  filename gives shape, the decl gives types. This is strictly better
  than today's flat union where `.comment` discards `post_id`
  (`_ = post_id; // the comment id is authoritative`,
  board_app.zig:75) — typed params keep both and let the page decide.
- **Type-safe hrefs.** Generated `routes.href(.{ .thread = .{ .post =
  7 } })` replaces stringly helpers like `boardHref`/`threadHref`/
  `commentHref` (board_app.zig:547-557). Links in views become
  comptime-checked; a renamed route breaks the build, not the link.
- **`validPath`/`setRoute`/`servePage` dispatch** generated from the
  same table — the three functions can never disagree about what a
  route is.

Costs/notes: the generator is a small Zig tool run as a `zig build`
step (or `zig run`) scanning `src/apps/<name>/pages/`; output is a
`gen/routes.zig` module. Dynamic segments are `[name]` (int or
`[]const u8` params); catch-all `[...rest]` and optional catch-all
`[[...rest]]` (last segment only, empty tail allowed),
non-empty remainder) is supported; route groups `(name)` remain
deferred (§7). String params slice the session-owned route path —
`skeleton.setRoute` dupes the request path before `Deps.setRoute`
sees it, so stored routes outlive the request buffer. Sessions
cap at 32 **(token, route) pairs** — soft-nav (§2.6) multiplies pair
count exactly like extra tabs do today; no new accounting needed.

Rejected alternative: runtime reflection or a route DSL parsed at
startup — Zig has no reflection; comptime codegen from the file tree
is the only honest option, and it makes routes compile-time data.

### 2.2 SSR / SSG

Every GET already SSRs: `handle()`'s GET branch (http.zig:375-414)
looks up/creates the `(token, route)` session and calls
`Session.servePage`, which resolves the route, syncs render-group
membership, brings the group current with the model, and writes the
`<main>` body via `writeView` → `forest.writeHtml`. Per-session
output differences are confined to `<head>` — the CSRF and rev meta
tags (`renderHead`, http.zig:230-254); the body is deterministic
given the view inputs (the render-groups review's field audit,
`docs/astra-reviews/2026-11-13-render-groups.md` §1).

What would "static" even mean when the model is live?

- **Build-time prerender: rejected.** A zboard page is a function of
  current `BoardModel` contents; a build artifact is stale on arrival
  and still needs the live patch layer to become correct — at which
  point it was never static, just a worse SSR. Per-session apps
  (todo/car) have no shared data to prerender anyway.
- **Runtime body cache: already half-exists.** Render groups dedupe
  the expensive part — N sessions with equal view inputs share one
  Dom/diff/history (`board_groups.zig`); `servePage` still runs
  `writeView` per request but that's one buildView+serialize, cheap
  next to a diff. A serialized-body cache per group is a possible
  optimization, not a semantic feature.
- **Truly static leaf pages** (no bound state, e.g. an `/about`):
  could be served as constant bytes; the snapshot/patch layer still
  works because ops only touch bound ids. Allowed, marginal — not a
  framework feature.

Verdict: zforest's answer to SSG is "render at request time, stay
current by patches." The costs SSG pays (staleness, revalidation,
ISR) don't exist here; there is nothing to reject beyond not
pretending build-time HTML is meaningful for live models.

### 2.3 Islands / partial hydration

**There is no hydration to island-ify.** `client.js` is a stateless
op applier; the first SSE `snapshot` event is a full-state ops dump
(`writeSnapshotOps`, view.zig:341) that reconciles whatever the SSR
page shipped. There is no client-side component tree, no props
payload, no selective-hydration boundary — "hydration" as a concept
is already deleted by the architecture, not merely simplified.

The region primitives that DO exist, and already give per-region
update granularity:

- `when`/`variant` comment anchors (view.zig:138-148, 202-229) —
  mount/unmount a subtree between `<!--z-when:ID-->` markers with one
  idempotent op;
- `bindTree` live leaves (view.zig:1024-1123) — store → patch op with
  no rebuild, used by zmon;
- keyed lists (`each`/`eachOf` → `Dom.syncKeyedList`, dom.zig:363) —
  membership/order diffs.

A "partial page update" is just a diff that happens to touch one
region — fine-grained patches already are islands at DOM granularity.

**True islands (client-side widgets) are the only real gap.** Today
the client has zero app knowledge by design; a chart or map widget
cannot exist. A viable shape that doesn't break the model:

- Server emits `data-island="<name>"` on a `when`/element (attr goes
  through the normal attr path; add the name to `ATTR_WHITELIST`,
  client.js:10-19).
- `client.js` gains a small island registry `{mount, unmount}`; the
  patch stream keeps flowing into the island's bound ids — an island
  is just a DOM subtree the server still owns.
- Lifecycle: `applyPatch`'s `when`/`create`/`remove` paths must
  trigger island mount/unmount — client.js diffs island presence
  around op application (~100-200 lines).

Rejected alternative: per-island JS bundles + hydration props — that
is rebuilding Next inside `client.js`; the server already ships
everything an island needs as ops. Deferred to v1 (§7); v0 ships no
islands.


**LANDED (page-level live islands).** A page file may declare
`pub const live = true;` — generated `routes.isLive` reports it,
`Deps.pageLive` forwards it, and the session skeleton switches that
route to the live pipeline: `servePage` builds the view ONCE
(`buildViewNodes` → `writeHtml` for SSR → `diff` to seed Dom →
`bindTree` to subscribe every `Bound.live` leaf), then `render()`
only stamps `log.revision` — store notifications push leaf ops
straight into the patch log, no rebuild, no diff. `dom.reset()` on
the next `servePage` drops the subscriptions, so live↔diff
transitions are clean. Constraint (same as zmon): ALL dynamic
content on a live page must be store-bound — structural/keyed
content is built once and goes stale. Mutations still `bumpSeq()` so
the batch carries a fresh revision. Client-side widget islands
(§2.3 "true islands") are still open.

**LANDED (per-leaf islands).** `forest.island(a, .{ .id = "…" },
children)` — `h.island` passthrough — marks a transparent subtree
inside a normal diff-mode page (no markup of its own; `.id`/`.lid`
required, panic otherwise). SSR, `diff`, `seedNode` and snapshots all
treat it like a `fragment` — children resolve `.lid`s under the
island's id path — but once the session skeleton's `bindIslands` pass
(run after every `forest.diff` in `render`) registers the island in
`Dom`, `diff`/`seedNode` skip the subtree entirely and every
`Bound.live` leaf inside gets a store subscription: notifications
push patch ops with no view rebuild while the rest of the page keeps
diffing. The island's subtree is deep-copied into a binding-owned
arena so `when_key` binder captures outlive the per-render arena.
Removing the subtree (`removeTracked` on the island id or an
ancestor — keyed-row removal, `when` unmount, `dom.reset` on route
change) drops the marker and unsubscribes every leaf; a re-added
island re-seeds and re-binds. Constraint: ALL dynamic content inside
must be store-bound — unbound structural content and unbound
`when` keys/keyed lists freeze at first bind; bound `variant`/`when`
keys keep working through `when_key` binders. Apps that never call
`bindIslands` get plain diff behavior — the island degrades to a
`fragment`.

### 2.4 Nested layouts

Today layout composition is plain function calls. zboard's
`buildView` returns `{navView(a, env), el(.div.bmain, content)}`
(board_app.zig:938-952); todo splits `headerView`/`emptyView`/
`filtersView`/`listView`/`footerView` (todo_app.zig:385-442);
`forest.fragment` (view.zig:185-189) lets a component cover several
roots without wrapper markup. There is no layout *mechanism* — just
composition, which already works.

What a meta-framework adds:

- **Segment layout chains.** `layouts/root.zig` applies to every
  page; `layouts/b.zig` wraps only `/b/*` pages; codegen composes
  them outermost→innermost around the page fn. A layout is
  `fn(a, env, slot: forest.Node) forest.Node` — ordinary Zig, no new
  forest primitive.
- **Layout-scoped env.** Today `ViewEnv` threads route/reply_to/
  resolved name/sort/seen-cursor by hand (board_app.zig:47-60). The
  framework `Env` (§5.2) formalizes what layouts and pages may read.
- **Slot convention.** Zig has no children-prop idiom; the single
  `slot: forest.Node` parameter IS the outlet. Pages return one Node
  (fragment for multi-root), so nesting is just nested calls.

Recorded caveat: layout content is not patch-isolated — a layout-level
change diffs like any other node. That's fine: ops are id-scoped and
there is no layout boundary in the DOM protocol, nor is one needed.

Rejected alternative: layouts as separate render passes or separate
Dom subtrees — would require new op scoping for zero benefit.

### 2.5 Data loading / loaders

There is no loader layer today because there is no async data source
in the render path: `buildView` reads the shared `BoardModel`
synchronously under the server mutex (`m()`, board_app.zig:20-22,
938+); `dispatch` validates and mutates inline. Request-scoped inputs
arrive via the `readCookies` hook and land in session/env fields.

What "loader" maps to, concretely:

- **Route-param validation → `prepare`.** Formalizes what
  `setRoute`'s switch does today (board_app.zig:207-219):
  `pub fn prepare(p: params, env: *Env) !void` returning
  `error.NotFound` → 404 before any view work.
- **Request data → Env fields.** Cookies (via `readCookies`), and
  whatever else the server learns to expose (headers, client IP —
  not plumbed today, §7).
- **Async/external data → effects, not loaders.** The async-effects
  protocol already designed (ARCHITECTURE.md "model layer + async",
  `docs/astra-reviews/2026-11-13-model-layer-async.md`): owned job
  admitted outside the mutex → serialized completion → `ping` →
  re-render. A page needing external data renders a `when`-anchored
  pending branch and lets the completion patch it in. That IS the
  loader+suspense story — no separate mechanism.

Rejected alternative: Next-style per-request `getServerSideProps`
fetch functions — there is no network fetch in-process; introducing
one means adopting the async protocol anyway, at which point it's an
effect, not a loader. v0 loaders = typed `prepare` + env injection.

### 2.6 Client-side navigation — LANDED (client.js `softNav`)

Every internal `<a href="/...">` click is intercepted (no modifier
keys, no `target`/`download`/`data-reload`, same-origin only) and
navigates without a document reload:

1. `fetch(href)` — a normal page GET: the server mints/looks up the
   `(token, route)` session, runs `servePage`, returns SSR HTML.
   Nothing new server-side; non-2xx falls back to `location.href`.
2. `DOMParser` lifts `<main>` innerHTML, `<title>`, and the
   `zforest-csrf` meta out of the response; `history.pushState`
   records the URL; `route`/`lastRev`/`csrfToken`/`ready` update.
3. `connect()` closes the old EventSource and opens
   `/events?r=<new path>` — the fresh `snapshot` (full-state ops
   dump) reconciles the swapped `<main>`, re-gates submit controls,
   and restores `lastRev` ordering for the new session's revisions.

Same-path query changes (`?q=`) soft-nav too: the session key is
the path, so the route-session is reused and the snapshot simply
re-asserts the re-rendered state. Back/forward is NOT intercepted —
`popstate` falls through to a full document load (correct, just not
instant). Draft stash (`sessionStorage`) runs before nav exactly as
on session-loss reload.

Rejected alternative (kept for the record): a dedicated nav payload
`{route, rev, ops, csrf}` — unnecessary; the page GET already
produces everything and keeps `servePage` as the single render
entry. Mutating a session's route key in place remains impossible by
construction (Dom/history/graph/rev/CSRF are per-`(token, route)`).

### 2.7 Streaming SSR / Suspense

`servePage` renders the whole `<main>` into an arena-buffered body,
then `req.respond` sends it whole (http.zig:400-413, 587-591) — no
HTTP streaming today, and none is worth adding: body render is
synchronous and fast under the mutex; flushing `<head>` early buys
nothing when the body is ready moments later. (`writeChunk`,
http.zig:419, exists for the SSE stream only.)

The Suspense analogue already exists in two pieces:

- `when`/`variant` anchors give "region appears later" semantics —
  mount a loading/empty branch, flip the key when data lands;
- async completions (once the async-effects protocol lands) deliver
  "shell now, data patches in" — the completion re-renders and the
  diff emits only the region's ops.

SSE itself is progressive enhancement: `data-on-submit` controls
stay gated until the first snapshot confirms the stream
(client.js:173-192, `ready` flag). Rejected: React-style streaming
SSR with per-boundary resolution order — the transport has no such
scheduling, and the patch stream IS the resolution mechanism.

### 2.8 Middleware — LANDED (file convention + action hook)

Two pieces landed; the transport-level hook sketched below stays
deferred.

**`pages/**/_middleware.zig`** — the Next `middleware.ts` file
convention, scoped exactly like `_layout.zig`: `pages/_middleware.zig`
gates every page route, `pages/item/_middleware.zig` adds an inner
gate for that subtree, multiple middleware run outermost-first. The
generated `prepare` dispatch calls each applicable
`pub fn middleware(s, env: *const zmeta.Env) !void` BEFORE the page's
own `prepare`; any error → `servePage` 404s, identical to prepare
errors (same catch site, same semantics). `env` is immutable —
middleware passes data through app-owned `s.deps` fields, matching
how `prepare` works today. v1 scope is PAGES only: `pages/api/`
endpoints dispatch through `api()` and never see middleware — revisit
if an endpoint needs the same gate. This covers the demonstrated
need (per-directory request gates) without touching `handle()`.

**`Deps.beforeAction`** — optional session-skeleton hook called
before `Deps.dispatch` on every `POST /action` with the same
`(action, arg, value, fields)` payload; `@hasDecl`-probed, absent =
no-op. Errors propagate exactly like dispatch errors → `statusOf`
(`NotFound` → 404, else 400). The seam for rate limiting, logging,
and auth prechecks on the action channel. Deliberately no
`afterAction`: `publishPending` already covers post-dispatch work.

Still deferred: the transport-level `beforeRequest` hook below —
pre-routing decisions (redirect/rewrite/headers) evaluated in
`handle` before session lookup. `validPath` covers route gating and
the prepare chain covers per-page gates; add `beforeRequest` only
when an app needs a decision BEFORE a `(token, route)` session is
minted (e.g. a global auth redirect that shouldn't create sessions).

Rejected (unchanged): edge-runtime semantics, response-header
middleware chains, per-route middleware *config* — the directory-
scoped file convention covers the demonstrated need at the same
cost as layouts.

### 2.9 API routes / server actions

`POST /action` IS the server-action mechanism: whitelisted
`Session.dispatch(action, arg, value, fields)` (contract,
http.zig:30-31), ACK `{rev}` only, patches via SSE. It already has
things Next server actions lack: CSRF (per-session token or
same-origin `Origin`/`Host`, http.zig:315-321), bounded body
(`max_body_len` 4096, :303-307), serialized mutation under the mutex,
and revisioned fan-out to every subscriber.

The formalization gap is **typing, not transport**: `action` is a
string matched by if-chains; `fields` is untyped
`std.json.ObjectMap` dug per handler (`fieldStr`/`fieldU64`,
board_app.zig:512-528). Two levels:

- **v0 — comptime name table.** The app manifest declares action
  names once; codegen emits `pub const act = struct { pub const like
  = "like"; ... }` used by BOTH the view side
  (`.on = .{ .click = act.like }`-style attrs — the `.on` field
  already comptime-whitelists event names, view.zig:485-492) and the
  generated `dispatch` skeleton. Typos fail at compile time; the wire
  stays strings (JSON has no enums).
- **v1 — typed payloads.** A small schema per action (field names +
  kinds) generating a payload struct + parser, so handlers stop
  hand-digging `ObjectMap`. Needs a mini-DSL; flagged as open
  question (§7) — the name table alone removes most of the risk.

API routes (non-UI JSON endpoints) LANDED as `pages/api/<name>.zig`
files exporting `pub fn api(a, s, params, env) ![]const u8` — the
generated `parseApi`/`api`/`apiPath` dispatch lives next to
`parseRoute`, `Deps.serveApi` is the session hook, and responses
skip the HTML shell with a JSON content type. `/api/*` responses
bypass the patch/ACK model — they're plain req/resp; mutations through
them get SSE fan-out only if they go through the same
dispatch/publish path (document, don't special-case). Raw
(non-JSON) endpoints and per-endpoint content types are covered in
§2.10.

### 2.10 SEO head + raw endpoints — LANDED

Per-page `<head>` overrides and file-based raw endpoints (RSS,
robots.txt, sitemap.xml) landed together — both ride the same
codegen seam: typed dispatch resolved AFTER `prepare`, emitted only
for apps that opt in.

**Head spec.** A page file may declare:

```zig
pub fn head(
    a: std.mem.Allocator,
    s: anytype,
    p: params,
    env: *const zmeta.Env,
) ?zmeta.HeadSpec
```

returning `zmeta.HeadSpec{ .title, .extra, .lang }` — every field
optional, `null` keeps the default:

- `title` overrides `Deps.page_title` (the `<title>` text);
- `extra` is RAW HTML emitted verbatim before `</head>` — meta
  description, Open Graph/Twitter cards, canonical links, JSON-LD,
  extra stylesheets. It is NOT escaped — the page owns correctness;
- `lang` overrides `Deps.page_lang` (the `<html lang>`; `page_lang`
  itself defaults to `"en"`).

Pages without `head` keep the shell defaults — SSR output is
byte-identical. The generated `routes.headSpec` dispatches on the
resolved typed route (`s.deps.route`), so `head` runs AFTER
`prepare` — params are validated and `prepare`'s `s.deps` writes are
visible. `a` is the session's render arena: head strings only need
to outlive the synchronous response write. `head` is INFALLIBLE by
contract (returns `?HeadSpec`, not an error union) — allocate with
`catch @panic("OOM")`, or `return null` to decline overrides for a
request.

The server renders the page BODY before the head for exactly this
reason: `handle` runs `servePage` (route resolve + prepare) into an
arena buffer, then `renderHead` asks the session for the spec, then
appends head+body+tail — the emitted document order is unchanged,
and a route that 404s in `prepare` never reaches head rendering.

**Raw endpoints.** A `pages/**` file whose FINAL segment contains a
dot is a raw endpoint: `pages/rss.xml.zig` → `GET /rss.xml`,
`pages/blog/feed.atom.zig` → `GET /blog/feed.atom`. The dotted
segment is always a literal static — `[id].xml` is rejected at gen
time (`BadSegment`); parent segments may still be `[name]`
dynamics (`pages/blog/[id]/feed.xml.zig` → `/blog/:id/feed.xml`).
Endpoint files use the api handler shape — `pub const params` +
`pub fn api(a, s, p, env) ![]const u8` — and bypass the HTML shell,
views, layouts, and middleware entirely, dispatched through the
generated `RawRoute` union + `parseRaw`/`raw`/`rawPath`. The session
hook is `Deps.serveRaw`; the server tries it after `serveApi` and
before page rendering, so a literal dotted route beats a dynamic
page segment ("/feed.xml" over "/[slug]"). Conflict rules: identical
segment shapes across page/raw lists are a gen-time
`DuplicateRoute` (`pages/rss.xml.zig` vs `pages/rss.xml/index.zig`);
different shapes are legal — dispatch order decides.

**Content types.** Api and raw endpoint files may declare
`pub const content_type = "application/rss+xml";` — a comptime
string forwarded by the generated `routes.contentType` through
`Deps.endpointContentType` (the server dupes it into the request
arena). Absent → per-kind defaults: `application/json` for
`/api/*`, `text/plain` for raw endpoints. Per-request content types
are not supported — the decl is static by design.

**Opt-in emission.** `headSpec`, `RawRoute`/`raw`, and
`contentType` are emitted ONLY when some page/endpoint declares the
hook, so existing apps regenerate byte-identical `gen/routes.zig`.
App-side glue (app.zig `Deps`) mirrors the api pattern:

```zig
pub fn serveRaw(s: *Session, path: []const u8, writer: anytype) !bool {
    // arena + env, then: routes.raw(a, s, path, &env)
}
pub fn endpointContentType(s: *Session, path: []const u8) ?[]const u8 {
    return routes.contentType(path);
}
pub fn headSpec(s: *Session, a: std.mem.Allocator, env: *const zmeta.Env) ?zmeta.HeadSpec {
    return routes.headSpec(s, a, env);
}
// plus `pub const page_lang = "...";` for the app-wide <html lang>.
```

The app `zmeta.zig` shim must also re-export `HeadSpec`
(`pub const HeadSpec = @import("zmeta").HeadSpec;`) for page files
to name the type.

## 3. What zforest already gives for free

Things mainstream frameworks charge real complexity for:

- **No hydration mismatch, by construction.** One view tree produces
  SSR HTML, the snapshot ops, and every diff. There is no second
  render implementation to drift — the bug class that forces
  Suspense boundaries, `useEffect` resync, and hydration-error
  telemetry in React-land does not exist here.
- **Realtime is built in.** Every session has a revisioned SSE patch
  stream with snapshot-on-gap recovery (`serveEvents`,
  `History.fetch` gap→snapshot, history.zig:58-79). Next.js needs
  Pusher/Ably/SSE plumbing bolted on; zforest's IS the transport.
- **Multi-tab consistency + render dedup.** Render groups let N
  sessions with equal view inputs share one Dom/PatchLog/History/
  revision (`board_groups.zig`), with clone-on-fork preserving stream
  lineage across membership changes. Nothing comparable exists in
  mainstream frameworks — each client there fetches independently.
- **Tiny client.** ~200 lines, no framework runtime, no virtual DOM
  on the client — patches touch only changed nodes. React ships tens
  of KB of reconciler to answer a question zforest never asks.
- **The unglamorous 80%.** CSRF (token-or-Origin), session
  incarnation/eviction correctness, bounded history rings, session
  caps, cookie identity — all solved and tested. Frameworks spend
  years on exactly this plumbing.
- **Server-authoritative = deleted problem space.** No client cache
  invalidation, no optimistic-UI rollback protocol, no state-sync
  bugs: the client never owns domain truth.

## 4. Hard problems specific to this stack

### 4.1 Per-session vs shared models

Three session archetypes coexist today and a framework must let an
app declare which without copy-paste:

- **Per-session state** — todo/car: model fields live on `Session`,
  `syncPull` is a no-op.
- **Shared model + per-session view state** — board: module-global
  `board_app.model`, `syncPull` re-renders when a scope its route
  reads moved (`scope_seq` counters + `RenderGroup.isCurrent()`,
  §4.4), `ViewEnv` carries per-session inputs (reply_to, sort,
  resolved name), optional render-group hooks (`publishPending`/
  `streamRev`/`streamHistory`/`membershipEpoch`, http.zig:47-59).
- **Shared model + per-session live stores** — zmon: `MonModel`
  global, per-session stores refreshed under `batch`, `bindTree`
  subscriptions (`apps/mon/app.zig` `refreshStores`/`seedDom`).

v0 answer: the generated `Session` skeleton takes the archetype as a
manifest field and emits the right stubs (`syncPull` no-op vs
`global_seq` poll vs store refresh); shared-model apps keep their
model module global exactly like `board_app.model` today. **Do not**
generalize `board_groups.zig` into the framework yet — the Astra
verdict put the registry in board-owned code deliberately
("RenderGroupRegistry lives in a BOARD-OWNED runtime module", not
the generic server); a second shared-model app is the trigger to
revisit. The group key is inherently app-specific (route + reply_to
+ resolved name + sort today) — the app must supply `group_key(env)`,
the framework can't invent it.

### 4.2 Type safety across the Zig↔browser boundary

`client.js` is untyped; `data-on-click="like"` + `data-arg="c12"` +
JSON `fields` are strings end-to-end. Realistic levels:

- **Achieved in Zig (v0):** comptime action-name table shared by view
  attrs and dispatch skeleton (§2.9); generated typed route params +
  hrefs (§2.1); typed `params`/`prepare` per page. The entire
  DOM-event surface becomes compile-checked on the server side.
- **JS-side callers stay stringly** unless we generate stubs: a
  `zactions.js`/`.d.ts` manifest emitted alongside the action table
  lets hand-written island code call actions with checked names.
  Cheap to add when islands land; meaningless before.
- **Rejected:** schema'd end-to-end types (Zig struct ↔ TS type
  codegen) — real work, serves only the JS-island case, defer.

### 4.3 View composition ergonomics

`forest.el` is verbose: `ArrayListUnmanaged(Node)` append-per-child,
`allocPrint` per dynamic id, tuple children help but dynamic lists
need manual lists. zboard's view code is roughly half of
`board_app.zig`'s 1685 lines. Options weighed:

- **Status quo + helpers:** `eachOf` already maps items→nodes;
  adding a varargs `kids(...)` collector and id-format helpers shaves
  real boilerplate. Lowest risk.
- **Comptime builder DSL** (`h.div(.{...}, .{...})`): marginal gain
  over `forest.el` — same information, slightly less noise.
- **Template/HTML-ish codegen → Zig:** rejected — loses comptime
  checking of tags/attrs/events (the `Tag` enum + `assertDomEvent`
  whitelist, view.zig:485-492, are real safety), adds a parser,
  complicates arena lifetimes. *(Revisited by the zsx spike —
  `docs/zsx-spike.md`: a bounded transpiler that lowers to
  `forest.el` measured −36% LOC, but a hostile review rejected
  adoption on diagnostics/maintenance costs; kept as a tagged
  experiment, removed from the build — see ARCHITECTURE.md
  "zsx spike".)*
- **JSX parity: not a goal.** Zig has no JSX and won't grow one;
  comptime gives type safety, not brevity. Honest expectation: a
  helper layer cuts ~30-40% of view boilerplate; the rest is the
  price of explicitness.

### 4.4 Dirty-only dispatch — landed, and a framework lesson

zboard just shipped scope-level dirty tracking (ARCHITECTURE.md
"zboard: dirty-only dispatch (done)"): `BoardModel.scope_seq` keeps
per-scope u64 counters (`SCOPE_HOME`, `scopeBoard(i)`,
`scopePost(id)` — board.zig:80-88,182), mutations declare their
footprint via `scopeBump`, `Session.scopeForRoute` (board_app.zig:255)
maps a route to the single scope its view reads, and
`RenderGroup.isCurrent()` (board_groups.zig:90) gates both
`syncPull` (board_app.zig:242) and `render` — a comment on /t/6 no
longer re-renders home or other boards: zero pings, zero diffs, zero
SSE events. This is the "dep-regions" idea from the render-groups
review realized one level up: **the route declares its data
footprint**, not the view tree.

What it does NOT cover: per-session apps (todo/car) still pay a full
buildView+diff per ping — there is no shared scope to skip against;
zmon pays per refresh. The landed version is app-owned bookkeeping,
not engine-level per-scope dispatch — that remains future work.

Framework implications:

- **Footprint declaration is a routing concern.** A meta-framework
  route should declare which model scopes it reads — the generated
  `scopeForRoute` equivalent. zboard hand-wrote it; codegen could
  derive it from a per-page `reads` decl or a route→scope
  convention. This is the strongest argument for keeping "what data
  does this page touch" explicit in the page contract.
- Page views must stay **pure functions of (params, env,
  model@scope)** — the `seen` cursor write inside `buildView`
  (board_app.zig:939) is a side effect that already bit render groups
  once; the generated skeleton should own the cursor internally so
  page code can't accidentally read or write it.
- Don't design v0 around "render is free". For shared-model apps the
  scope gate makes unrelated mutations nearly free; for per-session
  apps every ping still rebuilds and diffs the whole view.

Related known limits to respect (from the Astra reviews, unchanged):
live mode covers leaf bindings + boolean `when` keys only — keyed
lists and multi-key variants stay structural; hybrid live+diff has
unresolved binding-lifecycle issues (`findBinding` matches
kind+id+attr only; `Binder.variant_nodes` arena lifetime;
`removeTracked` prefix gaps — two-tier review §3). zmeta must pick
**diff vs live per app, not per page**, in v0.

## 5. v0 proposal

### 5.1 Directory conventions

Landed layout (this proposal's `apps/` is `src/apps/`; the exe entry
point `main.zig` and the `zmeta.zig` shim live inside the app dir —
`layouts/` landed as `pages/**/_layout.zig` instead):

```
src/apps/<name>/             # every app incl. its exe entry point
  main.zig                   # z<name> exe: zserver.serve + app.Session
  zmeta.zig                  # shim re-exporting the `zmeta` named module
  app.zig                    # manifest: archetype, cookie name, actions, client assets
  actions.zig                # action-name manifest
  pages/
    index.zig                # route "/"
    b/[slug].zig             # route "/b/:slug"
    t/[post]/index.zig       # route "/t/:post"
    t/[post]/c/[comment].zig # route "/t/:post/c/:comment"
    rss.xml.zig             # raw endpoint "/rss.xml" (dotted final seg, §2.10)
    _layout.zig              # optional; wraps pages in its dir + below
    _middleware.zig          # optional; pre-prepare gate, same dir scoping
  entities/                  # optional FSD slice — domain state leaf (§5.6)
  features/                  # optional FSD slice — session-bound features
  shared/                    # optional FSD slice — shared view components
  gen/routes.zig             # GENERATED: Route union, parse, href, dispatch
  gen/actions.zig            # GENERATED: comptime names + dispatch skeleton
```

The generator is `src/zmeta/gen.zig`, run as a `zig build` step
(`zig build gen`). Output is checked in — reviewable and it sidesteps
Zig module-path issues with generated files in `.zig-cache`.

### 5.2 The page contract

```zig
// apps/shop/pages/product/[id].zig
const zmeta = @import("zmeta");
const forest = @import("forest");

/// Route params — field types drive the generated parser.
pub const params = struct { id: u64 };

/// Optional: dangling params → 404 before any view work.
pub fn prepare(p: params, env: *zmeta.Env) !void {
    if (catalog.product(p.id) == null) return error.NotFound;
}

/// The page body — same shape family as today's view fns.
pub fn view(a: std.mem.Allocator, p: params, env: *zmeta.Env) forest.Node {
    return forest.el(a, .div, .{ .id = "product" }, .{
        forest.el(a, .h1, .{ .id = "pname" }, catalog.name(p.id)),
        // ...
    });
}
```

Layouts are ordinary fns with a slot:

```zig
// apps/shop/layouts/root.zig — applies to every page
pub fn layout(a: std.mem.Allocator, env: *zmeta.Env, slot: forest.Node) forest.Node {
    return forest.fragment(a, .{ headerView(a, env), slot, footerView(a, env) });
}
```

`zmeta.Env` is the framework-owned context pages/layouts read:
resolved route, per-session identity helpers, session UI-state
accessors, and the render cursor (internal — pages can't touch it,
§4.4). Model access stays via the app's own module functions (the
`m()` pattern, board_app.zig:20) — Env deliberately does NOT
abstract the model; the manifest declares the archetype instead.

The manifest:

```zig
// apps/shop/app.zig
pub const app = zmeta.App(.{
    .name = "shop",
    .cookie_name = "zfxh",
    .session = .per_session,   // or .shared(Model) — §4.1
    .page_title = "shop",
    .actions = @import("gen/actions.zig"),
});
```

### 5.3 Generated session skeleton

`zmeta.Session(Deps)` is a generic struct implementing the full
`server/http.zig` contract — `create`/`deinit`/`csrf_token`/
`setCsrf`/`incarnation`/`history`/`seq`/`dom`/`log`/arenas/
`out_cookie`/`setRoute`/`servePage`/`writeView`/`buildViewNodes`/
`seedDom`/`syncPull` stubs — so app code declares only: model fields,
action handlers, page/layout fns, and optional group/live hooks.
Render-path methods (`servePage`/`render`/`writeView`/
`buildViewNodes`/`seedDom`) are additionally per-method
`Deps`-overridable so grouped apps can replace the per-session
pipeline (membership sync + group render instead of `dom.reset` +
`seedDom`) — landed on `feat/zmeta-grouped`, see ARCHITECTURE.md
"zmeta: render-path overrides for grouped apps".
This kills the ~150 lines of contract boilerplate every current app
repeats (compare `apps/todo/app.zig` vs `apps/board/app.zig` — the board
app still hand-rolls what the skeleton now provides).
It is the single biggest DX win and the lowest-risk piece: the
contract is already stable and compile-enforced.

### 5.4 Request lifecycle (what the framework owns)

1. `GET path` → generated `validPath` (`parseRoute` + `apiPath` +
   `rawPath`, no session on 404) → `(token, route)` session lookup/create
   → `serveApi` (JSON, `/api/*`) → `serveRaw` (raw body, dotted
   endpoints) → `servePage`: `setRoute` → generated dispatch
   (applicable `_middleware.zig` files, outermost-first, then the
   page's) `prepare(params)` (404 on error) → [shared-model:
   `syncMembership` + `ensureGroupCurrent`] → `writeView` =
   layouts∘page into a buffer → `renderHead` (page `head` spec via
   `Deps.headSpec` — route already resolved) → head+body+tail →
   `seedDom`.
2. Browser: controls gated → `EventSource ?r=route` → `snapshot`
   (full-state ops) → live `patch` events.
3. `POST /action` → CSRF → `readCookies` → generated action-name
   dispatch → typed handler → `ping` → flush → after-flush render →
   publish → ACK `{rev}` → SSE fan-out (incl. cross-session via
   `syncPull`/`global_seq` and render groups where declared).

### 5.5 Zig vs JS companion — honest split

- **Zig (typed, comptime):** routing + params, pages, layouts,
  actions table, session skeleton, models, transport hooks. All app
  logic lives here.
- **JS companion (optional `app/client/*.js` + generated manifest):**
  island widgets (§2.3, v1), programmatic action calls (§4.2, when
  islands land), soft-nav client (§2.6, v1). `client.js` core stays
  app-agnostic; app JS loads via an extra script tag the framework
  emits only when declared.
- **Not feasible/desired in Zig:** JSX ergonomics (comptime gives
  typed tags/attrs — the `Tag` enum and event whitelist already —
  not brevity), runtime reflection (hence codegen), npm ecosystem.

### 5.6 Layer structure (FSD)

Apps may organize non-page code into Feature-Sliced Design layer
dirs inside `src/apps/<name>/`. **zboard is the reference
implementation**; slices are created on demand — small apps stay
flat (todo/car/mon/demo have no layer dirs). `zig build gen` scans
only `pages/`, so layer dirs are invisible to codegen and never
affect `gen/` output.

| FSD layer | zmeta location | contents |
|---|---|---|
| app | `app.zig`, `groups.zig`, `seed.zig`, `zmeta.zig`, `actions.zig`, `gen/` | session/`Deps` contract, render-group infra, action manifest, zmeta shim, checked-in codegen |
| pages | `pages/**/*.zig` (+ `_layout.zig`/`_middleware.zig`) | file routes |
| features | `features/*.zig` | session-bound slices — auth handlers, per-session workflows |
| shared | `shared/*.zig` | shared view components + pure helpers (markdown, formatters) |
| entities | `entities/*.zig` | domain state leaf — models, stores, account ops |

Import rules — dependencies point DOWN the table
(`app → pages → features → shared → entities → src/` infra):

- `entities/` imports nothing from any slice, `pages/`, or the app
  root — only `src/` infra (`db.zig`, …) and intra-entity siblings.
- `shared/` may import `entities/` — **documented deviation from
  strict FSD** (where shared is the lowest layer): zmeta shared
  components render entity rows (`model.Post`/`model.Comment`), so
  entities is the leaf instead. Shared still never imports
  features/pages/app.
- `shared/` may import `gen/routes.zig` **only for `routes.href`
  URL builders** — gen imports pages, so this closes a file-level
  cycle that Zig tolerates via lazy `@import`; keep the use to pure
  URL formatting, never page/dispatch symbols.
- `features/` may import `entities/` + `shared/` **plus the app
  root's session/render contract** (`app.zig` `Session`/`Deps`,
  `groups.zig`): zmeta features are session-bound — generated
  `actions.dispatch` calls `Deps.on_<name>` on `*Session`, so the
  upward edge is structural, not accidental. This makes
  `app.zig ↔ features/*.zig` and `groups.zig ↔ app.zig` import
  cycles; they predate FSD and Zig resolves them lazily.
- `pages/` may import everything.
- The app root may import everything.

`groups.zig`-style infra stays at the app root even though it looks
slice-ish: it is session/render plumbing (`Session.scopeForRoute`/
`scopeVersion` statics, Dom/history/rev sharing), not a domain
slice — putting it under `features/` would invert the dependency
(features must not be imported by the session skeleton).

When to create a slice: a file whose concern is a distinct domain
object or workflow. Domain state → `entities/`; behavior bound to a
session/action → `features/`; view pieces reused across pages →
`shared/`. Never scaffold empty dirs — flat files are fine until a
second concern appears.

## 6. Non-goals

- **No client-side router.** MPA stays the default; soft-nav (§2.6)
  is a v1 candidate, not v0.
- **No hydration runtime.** There is nothing to hydrate — SSR +
  snapshot ops is the state transfer.
- **No RSC/server-components analogue.** Every page already IS a
  server component; the concept doesn't transfer.
- **No npm/package ecosystem compat, no JSX, no React compat layer.**
- **No build-time SSG of live data.** Meaningless for shared live
  models (§2.2); static leaf pages need no framework support.
- **No edge/middleware runtime** beyond the in-process hook (§2.8).
- **No per-tab sessions.** Session = `(cookie, route)` is the
  contract; tab isolation needs view-instance identity — explicitly
  out per the two-tier review.
- **No HTTP-level streaming SSR** (§2.7).
- **No generalization of render groups into the framework** until a
  second shared-model app exists (§4.1).

## 7. Open questions

1. **Soft-nav: v1 or never?** Needs a real multi-route app to feel
   the cost; MPA may be good enough indefinitely.
2. **Render groups:** keep board-owned (Astra verdict) or extract a
   generic `group_key(env)` hook when app #2 arrives?
3. **Action payload typing:** comptime name table (v0) vs a schema'd
   typed-union DSL (v1) — how much DSL is worth the ergonomics?
4. **Codegen output:** checked-in `gen/` stubs vs build-step
   generation into the cache — Zig module paths favor checked-in.
5. **Diff vs live per page?** v0 picks per-app (matching today);
   per-page selection interacts with the session skeleton (view built
   once vs per flush) and the unresolved hybrid-binding issues.
6. **Env scope:** does the server need to expose client IP / extra
   headers for real apps (rate limiting, geo)? Not plumbed today.
7. **`/api/*` mutations:** allowed with documented fan-out caveats,
   or read-only in v0?
