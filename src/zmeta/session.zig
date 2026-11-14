//! Generated-session skeleton (docs/meta-framework.md §5.3): a generic
//! `Session(Deps)` implementing the FULL `server/http.zig` contract so
//! app code declares only model state, action handlers, and the view —
//! not the ~150 lines of Dom/log/history/arena/CSRF plumbing every app
//! currently repeats.
//!
//! v0 supports the `.per_session` archetype (§4.1): model fields and
//! graph handles live in `Deps`, `syncPull` is a no-op unless `Deps`
//! overrides it. `.shared_model` (global_seq poll, render groups,
//! publishPending/streamRev/streamHistory/membershipEpoch) is NOT yet
//! supported — those hooks stay undeclared here so the server keeps its
//! per-session defaults; a second archetype gets its own skeleton or
//! Deps-provided hooks once a second shared-model app exists (§4.1).
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
//!       no-op (per_session: nothing external can change).
//!     `fn readCookies(s, cookie_hdr: ?[]const u8) void` — auxiliary-
//!       cookie pickup before dispatch/page render (board's `zfxu`).
//!     `page_title` / `page_class` / `cookie_name` — consts forwarded
//!       to the server contract (defaults match http.zig's).
//!
//! Revision model: `seq` is a plain `*zefx.Store(u64)` owned by the
//! skeleton. Deps reducers advance it via `s.bumpSeq()`; the
//! skeleton-installed after-flush hook diffs `Deps.view` into `log`
//! and stamps `log.revision = seq.get()` — one batch per flush.

const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const History = @import("../server/history.zig").History;
const Env = @import("env.zig").Env;

pub fn Session(comptime Deps: type) type {
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
        pub const page_title = if (@hasDecl(Deps, "page_title")) Deps.page_title else "zforest";
        pub const page_class = if (@hasDecl(Deps, "page_class")) Deps.page_class else "app";
        pub const cookie_name = if (@hasDecl(Deps, "cookie_name")) Deps.cookie_name else "zfxs";

        /// Wired session constructor (`io` is for entropy — deps that
        /// mint tokens read `s.io`; todo-style apps ignore it).
        pub fn create(gpa: std.mem.Allocator, io: std.Io) *Self {
            const s = gpa.create(Self) catch @panic("OOM");
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
            // The render hook installs LAST so after-flush hooks a Deps
            // registers in wire() run before the DOM diff.
            s.app.eng.onAfterFlush(.{
                .ctx = @ptrCast(s),
                .call = &struct {
                    fn render(raw: *anyopaque) void {
                        const self: *Self = @ptrCast(@alignCast(raw));
                        self.render();
                    }
                }.render,
            });
            return s;
        }

        pub fn deinit(self: *Self) void {
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
        pub fn setCsrf(self: *Self, token: []u8) void {
            if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
            self.csrf_token = token;
        }

        /// Request-route hook: `Deps.setRoute` validates (and stores
        /// app route state); the default accepts "/" only. On success
        /// the path is remembered for `Env.route`.
        pub fn setRoute(self: *Self, path: []const u8) bool {
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
        pub fn validPath(path: []const u8) bool {
            if (@hasDecl(Deps, "validPath")) return Deps.validPath(path);
            return true;
        }

        /// Auxiliary-cookie pickup (board's `zfxu` pattern) — forwarded
        /// to `Deps.readCookies` when declared.
        pub fn readCookies(self: *Self, cookie_hdr: ?[]const u8) void {
            if (@hasDecl(Deps, "readCookies")) Deps.readCookies(self, cookie_hdr);
        }

        /// Full-page render for a navigating client: resolve the route,
        /// run the optional prepare gate, drop tracked DOM state, write
        /// the page body, then reseed so subsequent diffs emit only real
        /// changes.
        pub fn servePage(self: *Self, path: []const u8, writer: anytype) !bool {
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
        pub fn syncPull(self: *Self) void {
            if (@hasDecl(Deps, "syncPull")) Deps.syncPull(self);
        }

        /// Advance the patch revision — call from pure-phase reducers
        /// after mutating model state; the after-flush hook renders.
        pub fn bumpSeq(self: *Self) void {
            self.seq.set(self.seq.get() + 1);
        }

        /// Whitelisted action entry — the DOM event protocol (`action`
        /// is the `data-on-<event>` value, `arg` the `data-arg` payload,
        /// `value` a change event's new value, `fields` a submitted
        /// form's named inputs). Delegates to `Deps.dispatch`.
        pub fn dispatch(
            self: *Self,
            action: []const u8,
            arg: ?[]const u8,
            value: ?[]const u8,
            fields: ?*const std.json.ObjectMap,
        ) !void {
            return Deps.dispatch(self, action, arg, value, fields);
        }

        // ── rendering ───────────────────────────────────────────────
        // One declarative tree (`Deps.view`) drives SSR (`writeHtml`),
        // the post-flush DOM-patch diff, and the SSE snapshot ops.

        fn viewEnv(self: *Self) Env {
            return .{ .route = self.route };
        }

        /// Diff the view into DOM patches. Runs post-settle (after-flush).
        fn render(self: *Self) void {
            _ = self.render_arena.reset(.retain_capacity);
            const a = self.render_arena.allocator();
            const env = self.viewEnv();
            forest.diff(a, Deps.view(a, self, &env), &self.dom, &self.log);
            self.log.revision = self.seq.get();
        }

        /// Render the `<main>` inner content — used by the initial page.
        pub fn writeView(self: *Self, writer: anytype) !void {
            _ = self.render_arena.reset(.retain_capacity);
            const a = self.render_arena.allocator();
            const env = self.viewEnv();
            try forest.writeHtml(a, Deps.view(a, self, &env), writer);
        }

        /// The session's current view nodes, built into `a` — the SSE
        /// snapshot writer serializes them via `forest.writeSnapshotOps`.
        pub fn buildViewNodes(self: *Self, a: std.mem.Allocator) []const forest.Node {
            const env = self.viewEnv();
            return Deps.view(a, self, &env);
        }

        /// Seed tracked DOM state to match markup already emitted in the
        /// page, so the first diff renders only real changes.
        pub fn seedDom(self: *Self) void {
            self.render();
            // Keep tracked state, drop the patches — the page ships full HTML.
            self.log.clear();
        }
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
    try std.testing.expect(s.seq.get() == 0);
    try std.testing.expect(TestSession.validPath("/"));
    try std.testing.expect(TestSession.validPath("/anything")); // no Deps.validPath → accept all

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
