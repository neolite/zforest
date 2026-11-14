//! Generated-session skeleton (docs/meta-framework.md §5.3): a generic
//! `Session(Deps)` implementing the FULL `server/http.zig` contract so
//! app code declares only model state, action handlers, and the view —
//! not the ~150 lines of Dom/log/history/arena/CSRF plumbing every app
//! currently repeats.
//!
//! Archetypes (§4.1): `Deps` declares `pub const archetype:
//! zmeta.Archetype = .per_session | .shared_model | .live_shared;`
//! (default `.per_session`) to document which session shape it is.
//! `.per_session` (todo/car) keeps model fields on the session and
//! `syncPull` is a no-op unless `Deps` overrides it. `.shared_model`
//! (board) keeps the model module-global: `Deps.syncPull` polls the
//! shared revision and — when the app uses render groups — `Deps`
//! declares the four stream hooks below so `server/http.zig`'s
//! `@hasDecl` probes engage the grouped publish/fetch path. `.live_shared`
//! (zmon) is reserved: live `bindTree` wiring stays Deps-owned until the
//! skeleton grows a live render mode.
//!
//! Render-group stream hooks: Zig has no conditional declarations (no
//! `usingnamespace`, no container-level `if` for named decls), so the
//! skeleton cannot emit "only the hooks Deps happens to declare" — the
//! four hooks are meaningless in isolation anyway (a custom `streamRev`
//! without `streamHistory` breaks `History.fetch` contiguity; grouped
//! sessions need the epoch to force snapshots). `Session(Deps)` therefore
//! selects between two session types at comptime:
//!
//!   - `Deps` declares NONE of `publishPending`/`streamRev`/
//!     `streamHistory`/`membershipEpoch` → the plain session: none of
//!     the four methods exist on the type, `@hasDecl` probes fail, and
//!     the server keeps its per-session defaults exactly as before.
//!   - `Deps` declares ALL FOUR → the grouped session: each method is a
//!     pass-through to the matching `Deps` fn. The render-group
//!     registry/key/group pointer stay app-owned — the hooks receive
//!     `s: *Session` and reach them through `s.deps` (the skeleton owns
//!     no group state, §4.1 "do not generalize board_groups").
//!   - `Deps` declares SOME → `@compileError` at instantiation: partial
//!     hook sets are a contract violation, never a silent fallback.
//!
//! Deps contract (all fns take `s: *Session` first — the instantiated
//! type, so deps reaches `s.app`/`s.seq`/`s.gpa`/`s.deps` freely; decls
//! must be `pub` — the skeleton calls them across file boundaries):
//!
//!   required:
//!     `fn init(s: *Session) Deps` — build model fields + graph handles
//!       (`s.app.createEvent`/`createStore`); runs after `seq` exists.
//!     `fn dispatch(s, action, arg, value, fields) !void` — the
//!       whitelisted DOM-event action entry; errors map via
//!       `server.statusOf`.
//!     `fn view(a, s, env: *const Env) []const forest.Node` — the whole
//!       `<main>` body for SSR, diff and snapshot (one tree, three
//!       outputs). `a` is the per-render arena.
//!   optional (absent = skeleton default):
//!     `fn deinit(s) void` — frees domain allocations (item titles, ui
//!       drafts); runs before dom/log/history/arena/app teardown.
//!     `fn wire(s) void` — registers pure-phase reducers
//!       (`event.onReducer`, `store.updates().onReducer`); runs BEFORE
//!       the skeleton's render after-flush hook installs.
//!     `fn prepare(s, env: *const Env) !void` — route gate run by
//!       servePage after setRoute; any error → 404 (servePage cannot
//!       propagate: the server panics on error). Params arrive with
//!       codegen — v0 routes are raw paths only.
//!     `fn setRoute(s, path) bool` — default accepts "/" only.
//!       Multi-route apps validate AND store route state here.
//!     `fn validPath(path) bool` — static route pre-check; default
//!       accepts everything (bogus paths still 404 in servePage,
//!       exactly like a hand-rolled single-page app).
//!     `fn syncPull(s) void` — shared-model fan-out hook; default
//!       no-op (per_session: nothing external can change). Orthogonal
//!       to the group hooks: a shared-model app with no render groups
//!       declares only this (the zmon shape).
//!     `fn readCookies(s, cookie_hdr: ?[]const u8) void` — auxiliary-
//!       cookie pickup before dispatch/page render (board's `zfxu`).
//!     `page_title` / `page_class` / `cookie_name` — consts forwarded
//!       to the server contract (defaults match http.zig's).
//!     `archetype` — `zmeta.Archetype` const documenting the §4.1
//!       session shape (metadata only; hook emission is driven by the
//!       hook decls themselves, see above).
//!   grouped sessions (all-or-nothing — see the top comment):
//!     `fn publishPending(s) void` — drain the pending rendered batch
//!       into retained history (through the app's render group).
//!     `fn streamRev(s) u64` — revision subscribers track.
//!     `fn streamHistory(s) *History` — history ring subscribers fetch.
//!     `fn membershipEpoch(s) u64` — bumped on stream-incompatible
//!       group transitions; any change forces a snapshot.
//!
//! Revision model: `seq` is a plain `*zefx.Store(u64)` owned by the
//! skeleton. Deps reducers advance it via `s.bumpSeq()`; the
//! skeleton-installed after-flush hook diffs `Deps.view` into `log`
//! and stamps `log.revision = seq.get()` — one batch per flush.
//!
//! Implementation note: Zig 0.17 has no `usingnamespace` and no
//! conditional named declarations, so the two session shapes are two
//! thin structs (`SessionPlain`/`SessionGrouped`) that alias every
//! method from `SessionMethods` — the method bodies are written ONCE
//! with `self: anytype` (the same duck-typed style as
//! `server/stream.zig`'s `writeSnapshotJson`). Only the field list is
//! duplicated; keep the two lists identical (`createSessionImpl`
//! initializes by field name). Grouped sessions additionally alias the
//! four hook pass-throughs, which is what flips `server/http.zig`'s
//! `@hasDecl` probes.

const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const History = @import("../server/history.zig").History;
const Env = @import("env.zig").Env;

/// Session archetypes (docs/meta-framework.md §4.1). Declare on `Deps`
/// as `pub const archetype: zmeta.Archetype = .shared_model;` — it is
/// metadata for the manifest/docs; the grouped stream hooks are driven
/// by their own decls (see the file header).
pub const Archetype = enum {
    /// Model state lives on the session (todo/car).
    per_session,
    /// Module-global model + per-session view state (board).
    shared_model,
    /// Shared model + per-session live-bound stores (zmon) — reserved.
    live_shared,
};

/// Which of the four render-group stream hooks `Deps` declares.
const HookCoverage = enum { none, partial, all };

fn groupHookCoverage(comptime Deps: type) HookCoverage {
    const n = @as(u4, @intFromBool(@hasDecl(Deps, "publishPending"))) +
        @intFromBool(@hasDecl(Deps, "streamRev")) +
        @intFromBool(@hasDecl(Deps, "streamHistory")) +
        @intFromBool(@hasDecl(Deps, "membershipEpoch"));
    return switch (n) {
        0 => .none,
        4 => .all,
        else => .partial,
    };
}

/// Comma-separated names of the stream hooks `Deps` is missing — used
/// only in the partial-set `@compileError` message.
fn missingGroupHooks(comptime Deps: type) []const u8 {
    var out: []const u8 = &.{};
    inline for ([_][]const u8{ "publishPending", "streamRev", "streamHistory", "membershipEpoch" }) |name| {
        if (!@hasDecl(Deps, name)) {
            out = if (out.len == 0) name else out ++ ", " ++ name;
        }
    }
    return out;
}

/// The session type for `Deps` — the full `server/http.zig` contract.
/// Selects the plain vs grouped variant on the render-group hook set
/// (see the file header); a partial set is a compile error.
pub fn Session(comptime Deps: type) type {
    return switch (groupHookCoverage(Deps)) {
        .none => SessionPlain(Deps),
        .all => SessionGrouped(Deps),
        .partial => @compileError(
            "zmeta Session: the render-group stream hooks are all-or-nothing — " ++
                "Deps is missing " ++ missingGroupHooks(Deps) ++
                "; declare publishPending, streamRev, streamHistory and membershipEpoch together, or none",
        ),
    };
}

// ─────────────────────────────────────────────
// shared method implementations
// ─────────────────────────────────────────────
// Every method body lives here exactly once, taking `self: anytype` —
// the concrete `*SessionPlain(Deps)`/`*SessionGrouped(Deps)` is only
// known at each call site, which is fine: the variants expose identical
// fields and (aliased) methods, and `Deps.*(self)` receives the exact
// `*Session` type the app declared. The four group-hook bodies reference
// `Deps.<hook>` unconditionally but are only analyzed when a variant
// aliases them — i.e. only for Deps that declared all four.

fn SessionMethods(comptime Deps: type) type {
    return struct {
        /// Page shell metadata — forwarded from Deps when declared,
        /// otherwise the same defaults `server/http.zig` applies.
        pub const page_title = if (@hasDecl(Deps, "page_title")) Deps.page_title else "zforest";
        pub const page_class = if (@hasDecl(Deps, "page_class")) Deps.page_class else "app";
        pub const cookie_name = if (@hasDecl(Deps, "cookie_name")) Deps.cookie_name else "zfxs";
        /// §4.1 archetype — `Deps.archetype` or `.per_session`.
        pub const archetype = if (@hasDecl(Deps, "archetype")) Deps.archetype else Archetype.per_session;

        /// Free session-owned strings, then domain allocations via
        /// `Deps.deinit`, then let the skeleton tear down
        /// dom/log/history/arena/app (original ordering preserved).
        pub fn deinit(self: anytype) void {
            if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
            if (self.route_owned) self.gpa.free(self.route);
            if (@hasDecl(Deps, "deinit")) Deps.deinit(self);
            self.dom.deinit();
            self.log.deinit();
            self.history.deinit();
            self.render_arena.deinit();
            self.app.deinit();
            self.gpa.destroy(self);
        }

        /// Install the server-minted session token (owned by the session).
        pub fn setCsrf(self: anytype, token: []u8) void {
            if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
            self.csrf_token = token;
        }

        /// Request-route hook: `Deps.setRoute` validates (and stores
        /// app route state); the default accepts "/" only. On success
        /// the path is remembered for `Env.route`.
        pub fn setRoute(self: anytype, path: []const u8) bool {
            const ok = if (@hasDecl(Deps, "setRoute"))
                Deps.setRoute(self, path)
            else
                std.mem.eql(u8, path, "/");
            if (!ok) return false;
            if (!std.mem.eql(u8, self.route, path)) {
                if (self.route_owned) self.gpa.free(self.route);
                self.route = self.gpa.dupe(u8, path) catch @panic("OOM");
                self.route_owned = true;
            }
            return true;
        }

        /// Pure route check run before a session is minted — forwarded
        /// to `Deps.validPath` when declared, else accept everything.
        /// Static (no `self`) like the server contract expects.
        pub fn validPath(path: []const u8) bool {
            if (@hasDecl(Deps, "validPath")) return Deps.validPath(path);
            return true;
        }

        /// Auxiliary-cookie pickup (board's `zfxu` pattern) — forwarded
        /// to `Deps.readCookies` when declared.
        pub fn readCookies(self: anytype, cookie_hdr: ?[]const u8) void {
            if (@hasDecl(Deps, "readCookies")) Deps.readCookies(self, cookie_hdr);
        }

        /// Full-page render for a navigating client: resolve the route,
        /// run the optional prepare gate, drop tracked DOM state, write
        /// the page body, then reseed so subsequent diffs emit only real
        /// changes.
        pub fn servePage(self: anytype, path: []const u8, writer: anytype) !bool {
            if (!self.setRoute(path)) return false;
            if (@hasDecl(Deps, "prepare")) {
                const env = self.viewEnv();
                Deps.prepare(self, &env) catch return false;
            }
            self.dom.reset();
            try self.writeView(writer);
            self.seedDom();
            return true;
        }

        /// SSE-worker hook. Per-session models can't change between
        /// polls — the default is a no-op. Shared-model apps declare
        /// `Deps.syncPull` (global_seq poll etc.).
        pub fn syncPull(self: anytype) void {
            if (@hasDecl(Deps, "syncPull")) Deps.syncPull(self);
        }

        /// Advance the patch revision — call from pure-phase reducers
        /// after mutating model state; the after-flush hook renders.
        pub fn bumpSeq(self: anytype) void {
            self.seq.set(self.seq.get() + 1);
        }

        /// Whitelisted action entry — the DOM event protocol (`action`
        /// is the `data-on-<event>` value, `arg` the `data-arg` payload,
        /// `value` a change event's new value, `fields` a submitted
        /// form's named inputs). Delegates to `Deps.dispatch`.
        pub fn dispatch(
            self: anytype,
            action: []const u8,
            arg: ?[]const u8,
            value: ?[]const u8,
            fields: ?*const std.json.ObjectMap,
        ) !void {
            return Deps.dispatch(self, action, arg, value, fields);
        }

        /// The `Env` handed to `Deps.view`/`Deps.prepare` this render.
        fn viewEnv(self: anytype) Env {
            return .{ .route = self.route };
        }

        /// Diff the view into DOM patches. Runs post-settle (after-flush).
        fn render(self: anytype) void {
            _ = self.render_arena.reset(.retain_capacity);
            const a = self.render_arena.allocator();
            const env = self.viewEnv();
            forest.diff(a, Deps.view(a, self, &env), &self.dom, &self.log);
            self.log.revision = self.seq.get();
        }

        /// Render the `<main>` inner content — used by the initial page.
        pub fn writeView(self: anytype, writer: anytype) !void {
            _ = self.render_arena.reset(.retain_capacity);
            const a = self.render_arena.allocator();
            const env = self.viewEnv();
            try forest.writeHtml(a, Deps.view(a, self, &env), writer);
        }

        /// The session's current view nodes, built into `a` — the SSE
        /// snapshot writer serializes them via `forest.writeSnapshotOps`.
        pub fn buildViewNodes(self: anytype, a: std.mem.Allocator) []const forest.Node {
            const env = self.viewEnv();
            return Deps.view(a, self, &env);
        }

        /// Seed tracked DOM state to match markup already emitted in the
        /// page, so the first diff renders only real changes.
        pub fn seedDom(self: anytype) void {
            self.render();
            // Keep tracked state, drop the patches — the page ships full HTML.
            self.log.clear();
        }

        // ── render-group stream hooks (grouped variant only) ────────
        // Pure pass-throughs: `SessionGrouped` is only instantiated when
        // `Deps` declares all four, so these bodies are only analyzed
        // for Deps that provide them. The registry/group pointer live in
        // `s.deps` — the skeleton forwards, it does not own (§4.1).

        /// Drain the pending rendered batch into retained history —
        /// through the app's render group when grouped.
        pub fn publishPending(self: anytype) void {
            Deps.publishPending(self);
        }

        /// Revision subscribers (SSE cursor, snapshot `rev`, ACK)
        /// track — the group's local revision when grouped.
        pub fn streamRev(self: anytype) u64 {
            return Deps.streamRev(self);
        }

        /// History ring subscribers fetch from — the group's when
        /// grouped.
        pub fn streamHistory(self: anytype) *History {
            return Deps.streamHistory(self);
        }

        /// Membership epoch for the SSE stream: any change forces a
        /// snapshot + revision adopt (group-local revisions never imply
        /// baseline equality across groups).
        pub fn membershipEpoch(self: anytype) u64 {
            return Deps.membershipEpoch(self);
        }
    };
}

/// Wired session constructor shared by both variants: allocate, init
/// contract fields, run `Deps.init`/`Deps.wire`, install the render
/// after-flush hook LAST so after-flush hooks a Deps registers in
/// `wire()` run before the DOM diff. `S` is the concrete variant type —
/// `Deps.init`/`wire` receive `*S`, which IS the app's `*Session`.
fn createSessionImpl(comptime S: type, comptime Deps: type, gpa: std.mem.Allocator, io: std.Io) *S {
    const s = gpa.create(S) catch @panic("OOM");
    s.* = .{
        .gpa = gpa,
        .io = io,
        .app = zefx.createApp(gpa),
        .seq = undefined,
        .deps = undefined,
        .dom = forest.Dom.init(gpa),
        .log = forest.PatchLog.init(gpa),
        .history = History.init(gpa),
        .render_arena = std.heap.ArenaAllocator.init(gpa),
    };
    s.seq = s.app.createStore(u64, 0);
    s.deps = Deps.init(s);
    if (@hasDecl(Deps, "wire")) Deps.wire(s);
    s.app.eng.onAfterFlush(.{
        .ctx = @ptrCast(s),
        .call = &struct {
            fn render(raw: *anyopaque) void {
                const self: *S = @ptrCast(@alignCast(raw));
                self.render();
            }
        }.render,
    });
    return s;
}

// ─────────────────────────────────────────────
// session variants
// ─────────────────────────────────────────────
// Both variants declare the SAME field list (createSessionImpl
// initializes by name — keep them identical) and alias every method
// from SessionMethods. SessionGrouped adds the four stream-hook
// aliases; that presence is exactly what `server/http.zig`'s
// `@hasDecl(Session, ...)` probes detect.

fn SessionPlain(comptime Deps: type) type {
    const M = SessionMethods(Deps);
    return struct {
        const Self = @This();

        // ── contract fields owned by the skeleton ─────────────────
        gpa: std.mem.Allocator,
        io: std.Io,
        /// Per-session reactive graph — events/stores/effects created by
        /// `Deps.init`/`Deps.wire` live here.
        app: zefx.App,
        /// Patch revision — the server's `seq.get()` contract field.
        seq: *zefx.Store(u64),
        /// App-owned model state + graph handles (the Deps contract).
        deps: Deps,

        dom: forest.Dom,
        log: forest.PatchLog,
        /// Retained patch batches for SSE replay (see server/history.zig).
        history: History,
        /// Scratch space for the per-render view tree; reset each render.
        render_arena: std.heap.ArenaAllocator,
        /// Per-session CSRF token rendered into the page and verified on
        /// POST. Owned by the session; set by the server at creation.
        csrf_token: []u8 = &.{},
        /// Store-stamped incarnation (see the Session contract in
        /// server/http.zig): distinguishes this session from a previous
        /// one evicted+recreated under the same (cookie token, route).
        incarnation: u64 = 0,
        /// Extra `Set-Cookie` header emitted on /action responses
        /// ("" = none). Owned by the session when set.
        out_cookie: []const u8 = &.{},
        /// Last route path accepted by `setRoute` — the `Env.route`
        /// source. Owned copy: request buffers die with the request.
        route: []const u8 = "/",
        route_owned: bool = false,

        /// Page shell metadata — forwarded from Deps when declared,
        /// otherwise the same defaults `server/http.zig` applies.
        pub const page_title = M.page_title;
        pub const page_class = M.page_class;
        pub const cookie_name = M.cookie_name;
        /// §4.1 archetype — `Deps.archetype` or `.per_session`.
        pub const archetype = M.archetype;

        /// Wired session constructor (`io` is for entropy — deps that
        /// mint tokens read `s.io`; todo-style apps ignore it).
        pub fn create(gpa: std.mem.Allocator, io: std.Io) *Self {
            return createSessionImpl(Self, Deps, gpa, io);
        }

        // Contract methods — aliases into SessionMethods (bodies written
        // once; `self: anytype` resolves to *Self at each call site).
        pub const deinit = M.deinit;
        pub const setCsrf = M.setCsrf;
        pub const setRoute = M.setRoute;
        pub const validPath = M.validPath;
        pub const readCookies = M.readCookies;
        pub const servePage = M.servePage;
        pub const syncPull = M.syncPull;
        pub const bumpSeq = M.bumpSeq;
        pub const dispatch = M.dispatch;
        pub const writeView = M.writeView;
        pub const buildViewNodes = M.buildViewNodes;
        pub const seedDom = M.seedDom;
        const viewEnv = M.viewEnv;
        const render = M.render;
    };
}

fn SessionGrouped(comptime Deps: type) type {
    const M = SessionMethods(Deps);
    return struct {
        const Self = @This();

        // ── contract fields owned by the skeleton ─────────────────
        // IDENTICAL to SessionPlain — createSessionImpl initializes by
        // field name; keep the two lists in sync.
        gpa: std.mem.Allocator,
        io: std.Io,
        /// Per-session reactive graph — events/stores/effects created by
        /// `Deps.init`/`Deps.wire` live here.
        app: zefx.App,
        /// Patch revision — the server's `seq.get()` contract field.
        seq: *zefx.Store(u64),
        /// App-owned model state + graph handles (the Deps contract) —
        /// for shared_model apps this is where the render-group
        /// membership pointer / registry access lives.
        deps: Deps,

        dom: forest.Dom,
        log: forest.PatchLog,
        /// Retained patch batches for SSE replay (see server/history.zig).
        history: History,
        /// Scratch space for the per-render view tree; reset each render.
        render_arena: std.heap.ArenaAllocator,
        /// Per-session CSRF token rendered into the page and verified on
        /// POST. Owned by the session; set by the server at creation.
        csrf_token: []u8 = &.{},
        /// Store-stamped incarnation (see the Session contract in
        /// server/http.zig): distinguishes this session from a previous
        /// one evicted+recreated under the same (cookie token, route).
        incarnation: u64 = 0,
        /// Extra `Set-Cookie` header emitted on /action responses
        /// ("" = none). Owned by the session when set.
        out_cookie: []const u8 = &.{},
        /// Last route path accepted by `setRoute` — the `Env.route`
        /// source. Owned copy: request buffers die with the request.
        route: []const u8 = "/",
        route_owned: bool = false,

        /// Page shell metadata — forwarded from Deps when declared,
        /// otherwise the same defaults `server/http.zig` applies.
        pub const page_title = M.page_title;
        pub const page_class = M.page_class;
        pub const cookie_name = M.cookie_name;
        /// §4.1 archetype — `Deps.archetype` or `.per_session`.
        pub const archetype = M.archetype;

        /// Wired session constructor (`io` is for entropy — deps that
        /// mint tokens read `s.io`; todo-style apps ignore it).
        pub fn create(gpa: std.mem.Allocator, io: std.Io) *Self {
            return createSessionImpl(Self, Deps, gpa, io);
        }

        // Contract methods — aliases into SessionMethods (bodies written
        // once; `self: anytype` resolves to *Self at each call site).
        pub const deinit = M.deinit;
        pub const setCsrf = M.setCsrf;
        pub const setRoute = M.setRoute;
        pub const validPath = M.validPath;
        pub const readCookies = M.readCookies;
        pub const servePage = M.servePage;
        pub const syncPull = M.syncPull;
        pub const bumpSeq = M.bumpSeq;
        pub const dispatch = M.dispatch;
        pub const writeView = M.writeView;
        pub const buildViewNodes = M.buildViewNodes;
        pub const seedDom = M.seedDom;
        const viewEnv = M.viewEnv;
        const render = M.render;

        // ── render-group stream hooks ──────────────────────────────
        // Present ONLY here — this is what flips http.zig's @hasDecl
        // probes onto the grouped publish/fetch path. Pure pass-throughs
        // to Deps; the app owns the registry/group state via `s.deps`.
        pub const publishPending = M.publishPending;
        pub const streamRev = M.streamRev;
        pub const streamHistory = M.streamHistory;
        pub const membershipEpoch = M.membershipEpoch;
    };
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

/// Minimal Deps proving the skeleton end-to-end at the contract level:
/// init/wire/dispatch/view only — no setRoute/prepare/validPath, so the
/// defaults ("/" only, no pre-filter, no gate) apply.
const TestSession = Session(TestDeps);

const TestDeps = struct {
    count: *zefx.Store(u32),
    bump: *zefx.Event(u32),

    pub const page_title = "zmeta test";
    pub const page_class = "app";
    pub const cookie_name = "zq";

    pub fn init(s: *TestSession) TestDeps {
        return .{
            .count = s.app.createStore(u32, 0),
            .bump = s.app.createEvent(u32),
        };
    }

    pub fn wire(s: *TestSession) void {
        s.deps.bump.onReducer(s, &onBump);
    }

    fn onBump(s: *TestSession, n: u32) void {
        s.deps.count.set(n);
        s.bumpSeq();
    }

    pub fn dispatch(
        s: *TestSession,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        _ = arg;
        _ = fields;
        if (std.mem.eql(u8, action, "set")) {
            const n = value orelse return error.InvalidAction;
            s.deps.bump.emit(std.fmt.parseInt(u32, n, 10) catch return error.InvalidAction);
        } else {
            return error.InvalidAction;
        }
    }

    pub fn view(a: std.mem.Allocator, s: *TestSession, env: *const Env) []const forest.Node {
        _ = env;
        const nodes = a.alloc(forest.Node, 1) catch @panic("OOM");
        nodes[0] = forest.el(a, .div, .{ .id = "n", .text = forest.computed(s.deps.count, countText) }, .{});
        return nodes;
    }

    fn countText(a: std.mem.Allocator, n: u32) []const u8 {
        return std.fmt.allocPrint(a, "count={d}", .{n}) catch @panic("OOM");
    }
};

test "skeleton session: servePage emits HTML, dispatch+flush emits patch ops" {
    const alloc = std.testing.allocator;
    const s = TestSession.create(alloc, std.testing.io);
    defer s.deinit();

    // Contract surface the server relies on.
    try std.testing.expectEqualStrings("zmeta test", TestSession.page_title);
    try std.testing.expectEqualStrings("zq", TestSession.cookie_name);
    try std.testing.expectEqual(Archetype.per_session, TestSession.archetype);
    try std.testing.expect(s.seq.get() == 0);
    try std.testing.expect(TestSession.validPath("/"));
    try std.testing.expect(TestSession.validPath("/anything")); // no Deps.validPath → accept all

    // No render-group hook decls → the server keeps its per-session
    // defaults (http.zig's @hasDecl probes all fail on this type).
    try std.testing.expect(!@hasDecl(TestSession, "publishPending"));
    try std.testing.expect(!@hasDecl(TestSession, "streamRev"));
    try std.testing.expect(!@hasDecl(TestSession, "streamHistory"));
    try std.testing.expect(!@hasDecl(TestSession, "membershipEpoch"));

    // servePage: "/" accepted, bogus path 404s via the default setRoute.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.testing.expect(try s.servePage("/", &aw.writer));
    const page = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, page, "count=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"n\"") != null);

    var bw: std.Io.Writer.Allocating = .init(alloc);
    defer bw.deinit();
    try std.testing.expect(!(try s.servePage("/bogus", &bw.writer)));

    // syncPull is the per_session no-op; Env.route reflects setRoute.
    s.syncPull();

    // dispatch → emit → reducer bumps seq → after-flush render diffs.
    try s.dispatch("set", null, "42", null);
    try std.testing.expectEqual(@as(u64, 1), s.seq.get());
    try std.testing.expectEqual(@as(u32, 42), s.deps.count.get());

    var jw: std.Io.Writer.Allocating = .init(alloc);
    defer jw.deinit();
    s.log.writeJson(&jw.writer) catch @panic("OOM");
    const batch = jw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, batch, "\"rev\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, batch, "\"op\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, batch, "count=42") != null);

    // Snapshot path: buildViewNodes serializes the same tree.
    _ = s.render_arena.reset(.retain_capacity);
    const a = s.render_arena.allocator();
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    try forest.writeSnapshotOps(a, s.buildViewNodes(a), &sw.writer);
    try std.testing.expect(std.mem.indexOf(u8, sw.writer.buffered(), "count=42") != null);

    // csrf round-trip like SessionStore.create/setCsrf.
    s.setCsrf(try alloc.dupe(u8, "token"));
    try std.testing.expectEqualStrings("token", s.csrf_token);
}

/// Shared-model Deps declaring the full render-group hook set — the
/// board archetype (§4.1) in miniature: a module-global "model" (here a
/// file-scope counter standing in for `global_seq`), a deps-owned
/// history ring standing in for the render group, and the four stream
/// hooks as pass-throughs. Proves the grouped variant compiles the
/// contract and delegates each hook to Deps.
const SharedSession = Session(SharedDeps);

var shared_model_seq: u64 = 0;

const SharedDeps = struct {
    pub const archetype: Archetype = .shared_model;

    count: *zefx.Store(u32),
    /// Deps-owned "group" state the hooks read — the skeleton owns none.
    group_rev: u64 = 0,
    group_epoch: u64 = 0,
    published: usize = 0,
    /// Stands in for the render group's retained history ring.
    group_history: History,

    pub fn init(s: *SharedSession) SharedDeps {
        return .{
            .count = s.app.createStore(u32, 0),
            .group_history = History.init(s.gpa),
        };
    }

    pub fn deinit(s: *SharedSession) void {
        s.deps.group_history.deinit();
    }

    pub fn dispatch(
        s: *SharedSession,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        _ = arg;
        _ = fields;
        _ = value;
        if (std.mem.eql(u8, action, "bump")) {
            // Shared-model mutation: bump the global counter, then ping
            // this session's graph so the after-flush render runs.
            shared_model_seq +%= 1;
            s.deps.group_rev = shared_model_seq;
            s.bumpSeq();
        } else {
            return error.InvalidAction;
        }
    }

    pub fn view(a: std.mem.Allocator, s: *SharedSession, env: *const Env) []const forest.Node {
        _ = env;
        const nodes = a.alloc(forest.Node, 1) catch @panic("OOM");
        nodes[0] = forest.el(a, .div, .{ .id = "n", .text = forest.computed(s.deps.count, sharedText) }, .{});
        return nodes;
    }

    fn sharedText(a: std.mem.Allocator, n: u32) []const u8 {
        return std.fmt.allocPrint(a, "shared={d}", .{n}) catch @panic("OOM");
    }

    // ── the four render-group stream hooks (all-or-nothing set) ────

    pub fn publishPending(s: *SharedSession) void {
        s.deps.published += 1;
        const batch = s.gpa.dupe(u8, "{\"rev\":1,\"ops\":[]}") catch @panic("OOM");
        s.deps.group_history.publish(s.deps.group_rev, batch);
    }

    pub fn streamRev(s: *SharedSession) u64 {
        return s.deps.group_rev;
    }

    pub fn streamHistory(s: *SharedSession) *History {
        return &s.deps.group_history;
    }

    pub fn membershipEpoch(s: *SharedSession) u64 {
        return s.deps.group_epoch;
    }
};

test "grouped session: hook decls present and delegate to Deps" {
    const alloc = std.testing.allocator;
    shared_model_seq = 0;
    const s = SharedSession.create(alloc, std.testing.io);
    defer s.deinit();

    // Archetype metadata + the grouped variant's decl surface — exactly
    // what server/http.zig's @hasDecl probes look for.
    try std.testing.expectEqual(Archetype.shared_model, SharedSession.archetype);
    try std.testing.expect(@hasDecl(SharedSession, "publishPending"));
    try std.testing.expect(@hasDecl(SharedSession, "streamRev"));
    try std.testing.expect(@hasDecl(SharedSession, "streamHistory"));
    try std.testing.expect(@hasDecl(SharedSession, "membershipEpoch"));

    // Defaults before any hook ran.
    try std.testing.expectEqual(@as(u64, 0), s.streamRev());
    try std.testing.expectEqual(@as(u64, 0), s.membershipEpoch());
    try std.testing.expect(s.streamHistory() == &s.deps.group_history);
    try std.testing.expect(s.streamHistory() != &s.history);

    // dispatch → shared-model bump → seq advances → render diffs.
    try s.dispatch("bump", null, null, null);
    try std.testing.expectEqual(@as(u64, 1), s.seq.get());
    try std.testing.expectEqual(@as(u64, 1), shared_model_seq);

    // Each hook is a pure pass-through to Deps state.
    s.deps.group_epoch = 41;
    s.deps.group_rev = 77;
    try std.testing.expectEqual(@as(u64, 77), s.streamRev());
    try std.testing.expectEqual(@as(u64, 41), s.membershipEpoch());
    s.publishPending();
    try std.testing.expectEqual(@as(usize, 1), s.deps.published);
    try std.testing.expectEqual(@as(u64, 77), s.deps.group_history.latest_rev);
    // Cursor 76 → the rev-77 batch; cursor 0 would (correctly) gap —
    // History revisions must be contiguous from the first retained rev.
    const f = try s.streamHistory().fetch(76, alloc);
    defer History.freeFetch(alloc, f);
    try std.testing.expect(f == .batches);
    try std.testing.expectEqual(@as(usize, 1), f.batches.len);
    try std.testing.expectEqual(@as(u64, 77), f.batches[0].rev);

    // The rest of the contract still works on the grouped variant.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.testing.expect(try s.servePage("/", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "shared=0") != null);
}

/// Hook-coverage unit checks — a partial set can't instantiate
/// `Session` (it is a `@compileError`), but the coverage fn itself is
/// comptime-testable.
const TwoHooks = struct {
    pub fn streamRev(s: anytype) u64 {
        _ = s;
        return 0;
    }
    pub fn membershipEpoch(s: anytype) u64 {
        _ = s;
        return 0;
    }
};

test "group hook coverage: none/all/partial" {
    try std.testing.expect(groupHookCoverage(TestDeps) == .none);
    try std.testing.expect(groupHookCoverage(SharedDeps) == .all);
    try std.testing.expect(groupHookCoverage(TwoHooks) == .partial);
    try std.testing.expectEqualStrings("publishPending, streamHistory", comptime missingGroupHooks(TwoHooks));
}
