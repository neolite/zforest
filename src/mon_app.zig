//! zmon — live ops dashboard on fine-grained bindings: the view tree is
//! built ONCE per session into `deps.view_arena`, `seedDom` subscribes
//! every bound leaf (`.text`/attrs/`variant` keys) to its zefx store via
//! `forest.bindTree`, and store notifications emit patch ops directly
//! into `s.log` — no per-tick rebuild+diff. Derived stores (`map`) feed
//! `computed` bindings and `variant` pills.
//!
//! zmeta migration: `Session` is the `.live_shared` archetype on the
//! `zmeta.Session(Deps)` skeleton — `MonDeps` carries the per-session
//! stores/arenas/view cache plus the `ping` event and `seen_seq`
//! cursor, while the skeleton owns the transport contract
//! (app/seq/dom/log/history/render_arena/CSRF/route). The shared
//! `MonModel` stays module-global (app-owned), exactly as before.
//!
//! Unlike the diff apps, the skeleton's default after-flush render does
//! NOT apply: `Deps.render` only stamps `log.revision` — live binders
//! already pushed their ops during the notify phase — and the
//! page/snapshot/seed pipelines are overridden to reuse the cached
//! once-built tree (see the render-path overrides on `MonDeps`).

const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const zmeta = @import("zmeta/root.zig");
const MonModel = @import("mon_model.zig").MonModel;

/// The shared model, installed by mon_main before serve(). The ticker
/// thread mutates under the model mutex; sessions read snapshots under
/// the same lock.
pub var model: MonModel = undefined;

fn m() *MonModel {
    return &model;
}

/// Flush trigger: `refreshAndPing` emits it once per model refresh; the
/// `onPing` reducer (registered by `MonDeps.wire`) bumps the patch
/// revision in the pure phase.
const Ping = struct {};

/// zmon domain state + graph handles — the zmeta `Deps` for the
/// `.live_shared` archetype (docs/meta-framework.md §4.1/§5.3). The
/// `Session` skeleton owns the transport contract (app/seq/dom/log/
/// history/render_arena/CSRF/route); everything dashboard-specific —
/// the store set, the format/view arenas, the once-built view cache,
/// the shared-model cursor, and the `ping` event — lives here on
/// `s.deps`. The shared `MonModel` stays module-global.
pub const MonDeps = struct {
    /// §4.1 archetype — shared model + per-session live-bound stores.
    pub const archetype: zmeta.Archetype = .live_shared;
    /// Page <title> / <main> class / session cookie — forwarded to the
    /// server contract through `Session`.
    pub const page_title = "zmon";
    pub const page_class = "app app-mon";
    pub const cookie_name = "zfxm";

    // Dashboard stores — strings formatted in refreshStores, slices into
    // fmt_arena (valid until the next refresh; every consumer refreshes
    // or renders synchronously after one).
    st_rps_s: *zefx.Store([]const u8),
    st_lat_s: *zefx.Store([]const u8),
    st_total_s: *zefx.Store([]const u8),
    st_up_s: *zefx.Store([]const u8),
    st_feed: *zefx.Store([]const u8),
    /// Firehose log text — one leaf, rewritten whole each refresh.
    st_log: *zefx.Store([]const u8),
    /// Sparkline `points` payloads — attr-bound leaves on SVG polylines.
    st_sp_rps: *zefx.Store([]const u8),
    st_sp_err: *zefx.Store([]const u8),
    st_sp_lat: *zefx.Store([]const u8),
    /// Traffic-control readouts ("100%", "10.00%", "100%") — `.text`
    /// bound on the ctl sliders' value chips.
    st_p_rate: *zefx.Store([]const u8),
    st_p_err: *zefx.Store([]const u8),
    st_p_lat: *zefx.Store([]const u8),
    /// Error rate in basis points (0..10000) — feeds `computed` bindings.
    st_err_bp: *zefx.Store(u64),
    /// Derived health flags — drive the `variant` status pills.
    st_ok: *zefx.Store(bool),
    st_bad: *zefx.Store(bool),

    /// Last `model.global_seq` this session rendered — syncPull's
    /// cursor for the shared-model fan-out.
    seen_seq: u64 = 0,

    /// Dual-purpose scratch: formatted store strings in refreshStores
    /// AND the emit-time arena stored in every live Binder (bound-leaf
    /// resolution + `when` branch re-serialization). Reset only at the
    /// top of refreshStores — synchronous, before any emit can observe
    /// it — and retained for the session's lifetime otherwise.
    fmt_arena: std.heap.ArenaAllocator,
    /// Session-lifetime arena for the view tree — built once, never
    /// reset (bindings capture its slices; rebuilding would orphan
    /// subscriptions).
    view_arena: std.heap.ArenaAllocator,
    view_nodes: ?[]const forest.Node = null,

    /// Flush trigger — every refreshAndPing emits it; `onPing` bumps
    /// `seq` in the pure phase.
    ping: *zefx.Event(Ping),

    /// `Deps.init` — create the graph handles on the session's engine.
    /// `seq` already exists (skeleton-owned); `wire` registers the
    /// reducer next.
    pub fn init(s: *Session) MonDeps {
        const err_bp = s.app.createStore(u64, 0);
        return .{
            .st_rps_s = s.app.createStore([]const u8, ""),
            .st_lat_s = s.app.createStore([]const u8, ""),
            .st_total_s = s.app.createStore([]const u8, ""),
            .st_up_s = s.app.createStore([]const u8, ""),
            .st_feed = s.app.createStore([]const u8, ""),
            .st_log = s.app.createStore([]const u8, ""),
            .st_sp_rps = s.app.createStore([]const u8, ""),
            .st_sp_err = s.app.createStore([]const u8, ""),
            .st_sp_lat = s.app.createStore([]const u8, ""),
            .st_p_rate = s.app.createStore([]const u8, "100%"),
            .st_p_err = s.app.createStore([]const u8, "10.00%"),
            .st_p_lat = s.app.createStore([]const u8, "100%"),
            .st_err_bp = err_bp,
            .st_ok = err_bp.map(bool, isOk),
            .st_bad = err_bp.map(bool, isBad),
            .fmt_arena = std.heap.ArenaAllocator.init(s.gpa),
            .view_arena = std.heap.ArenaAllocator.init(s.gpa),
            .ping = s.app.createEvent(Ping),
        };
    }

    /// `Deps.deinit` — free the two session arenas. Runs before the
    /// skeleton tears down dom/log/history/render_arena/app: live
    /// binders are destroyed by `dom.deinit` (unsubscribing from stores
    /// `app.deinit` still owns) and never emit during teardown, so
    /// freeing the emit/format scratch first is safe.
    pub fn deinit(s: *Session) void {
        s.deps.fmt_arena.deinit();
        s.deps.view_arena.deinit();
    }

    /// `Deps.wire` — pure-phase reducers ONLY. The skeleton installs the
    /// render after-flush hook itself after this returns; it delegates
    /// to `Deps.render`, which for live mode only stamps the batch
    /// revision (binders already emitted during the notify phase).
    pub fn wire(s: *Session) void {
        s.deps.ping.onReducer(s, &onPing);
    }

    /// `Deps.validPath` — single-page app: only "/" is a page route.
    pub fn validPath(path: []const u8) bool {
        return std.mem.eql(u8, path, "/");
    }

    /// `Deps.syncPull` — SSE-worker hook: when the shared model moved,
    /// refresh stores and ping — one batched flush emits this session's
    /// live-binding ops.
    pub fn syncPull(s: *Session) void {
        const seq_now = m().global_seq.load(.seq_cst);
        if (seq_now == s.deps.seen_seq) return;
        s.deps.seen_seq = seq_now;
        refreshAndPing(s);
    }

    /// `Deps.dispatch` — whitelisted action entry — inject synthetic
    /// requests so the dashboard moves without waiting for the ticker.
    pub fn dispatch(
        s: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        _ = arg;
        _ = fields;
        s.out_cookie = "";
        var rb: [16]u8 = undefined;
        s.io.random(&rb);
        const roll = std.mem.readInt(u32, rb[0..4], .little);
        if (std.mem.eql(u8, action, "inject_ok")) {
            m().record(.{ .ok = true, .lat_ms = 6.0 + @as(f64, @floatFromInt(roll % 30)), .method = "POST", .path = "/inject/ok", .status = 200 });
        } else if (std.mem.eql(u8, action, "inject_err")) {
            m().record(.{ .ok = false, .lat_ms = 250.0 + @as(f64, @floatFromInt(roll % 500)), .method = "POST", .path = "/inject/err", .status = 500 });
        } else if (std.mem.eql(u8, action, "inject_slow")) {
            m().record(.{ .ok = true, .lat_ms = 700.0 + @as(f64, @floatFromInt(roll % 400)), .method = "POST", .path = "/inject/slow", .status = 200 });
        } else if (std.mem.eql(u8, action, "inject_storm")) {
            m().storm(400);
        } else if (std.mem.eql(u8, action, "ctl_rate") or
            std.mem.eql(u8, action, "ctl_err") or
            std.mem.eql(u8, action, "ctl_lat"))
        {
            const v = value orelse return error.InvalidAction;
            const n = std.fmt.parseInt(u32, v, 10) catch return error.InvalidAction;
            const kind: MonModel.ParamKind = if (std.mem.eql(u8, action, "ctl_rate"))
                .rate
            else if (std.mem.eql(u8, action, "ctl_err"))
                .err
            else
                .lat;
            m().setParam(kind, n);
        } else {
            return error.InvalidAction;
        }
        refreshAndPing(s);
    }

    // ── render-path overrides ────────────────────────────────────
    // Live mode replaces the whole render pipeline: the view is built
    // once (viewNodes), bindTree subscriptions push ops into s.log
    // during the notify phase, and Deps.render only stamps the batch
    // revision. Every skeleton default that would rebuild+diff
    // `Deps.view` per flush is overridden.

    /// `Deps.servePage` — the live page pipeline: setRoute →
    /// refreshStores → dom.reset → writeView → seedDom (diff-seed +
    /// bindTree subscribe). The skeleton default lacks the
    /// refreshStores step, so the whole pipeline is replaced — same
    /// ordering as the hand-rolled version.
    pub fn servePage(s: *Session, path: []const u8, writer: anytype) !bool {
        if (!s.setRoute(path)) return false;
        refreshStores(s);
        s.dom.reset();
        try s.writeView(writer);
        s.seedDom();
        return true;
    }

    /// `Deps.render` — reached through the skeleton-installed after-
    /// flush hook. Live bindings already emitted their ops into `s.log`
    /// during the notify phase; the hook only stamps the batch rev.
    pub fn render(s: *Session) void {
        s.log.revision = s.seq.get();
    }

    /// `Deps.writeView` — render the `<main>` inner content for the
    /// initial page (the cached once-built tree).
    pub fn writeView(s: *Session, writer: anytype) !void {
        _ = s.render_arena.reset(.retain_capacity);
        const a = s.render_arena.allocator();
        try forest.writeHtml(a, viewNodes(s), writer);
    }

    /// `Deps.buildViewNodes` — the session's current view nodes for the
    /// SSE snapshot writer (`forest.writeSnapshotOps` serializes them).
    /// Refreshes stores first so the dump reflects the shared model —
    /// same as the hand-rolled version (the passed arena is unused: the
    /// tree lives in `deps.view_arena`).
    pub fn buildViewNodes(s: *Session, _: std.mem.Allocator) []const forest.Node {
        refreshStores(s);
        return viewNodes(s);
    }

    /// `Deps.seedDom` — seed tracked DOM state to match the shipped
    /// page, then subscribe every live-capable leaf — from here on,
    /// store notifications emit patches directly (no rebuild, no diff).
    pub fn seedDom(s: *Session) void {
        _ = s.render_arena.reset(.retain_capacity);
        const a = s.render_arena.allocator();
        const nodes = viewNodes(s);
        forest.diff(a, nodes, &s.dom, &s.log);
        s.log.clear();
        forest.bindTree(s.deps.fmt_arena.allocator(), nodes, &s.dom, &s.log);
    }

    /// `Deps.view` — contract completeness: every render path above is
    /// overridden, so the skeleton defaults that would call this are
    /// dead. Returns the session's cached once-built tree.
    pub fn view(_: std.mem.Allocator, s: *Session, _: *const zmeta.Env) []const forest.Node {
        return viewNodes(s);
    }
};

/// One browser session — the full `server/http.zig` contract, provided
/// by the zmeta skeleton (`.live_shared` declares no render-group hooks,
/// so this is the plain per-session variant: own Dom/log/history).
pub const Session = zmeta.Session(MonDeps);

// ── session-state helpers (file scope, take *Session) ─────────

/// ping reducer — bumps the revision in the pure phase.
fn onPing(s: *Session, _: Ping) void {
    s.bumpSeq();
}

/// Store refresh + ping under ONE batch boundary: ~14 individual
/// auto-flushes collapse into a single flush (and live-binding emit
/// pass) per refresh. refreshStores' own inner batch nests harmlessly.
fn refreshAndPing(s: *Session) void {
    const eng = &s.app.eng;
    eng.batchBegin();
    defer eng.batchEnd();
    refreshStores(s);
    s.deps.ping.emit(.{});
}

/// Pull the shared model snapshot into this session's stores. String
/// slices live in fmt_arena until the next refresh. The batch makes
/// the ~13 `.set()` calls cost one flush even when called alone
/// (servePage / buildViewNodes). Slice stores deliberately keep
/// `eq = null`: fmt_arena is reset BEFORE the sets, so the old slice
/// would point into recycled memory — content comparison is unsafe
/// here (the Dom layer already dedupes unchanged text ops).
fn refreshStores(s: *Session) void {
    const eng = &s.app.eng;
    eng.batchBegin();
    defer eng.batchEnd();
    _ = s.deps.fmt_arena.reset(.retain_capacity);
    const a = s.deps.fmt_arena.allocator();
    const snap = m().snapshot();
    const feed = m().feed(a.alloc(u8, 1400) catch a.alloc(u8, 0) catch return);
    s.deps.st_feed.set(feed);
    const log = m().logText(a.alloc(u8, 24576) catch a.alloc(u8, 0) catch return);
    s.deps.st_log.set(log);
    s.deps.st_sp_rps.set(m().sparkline(.rps, a.alloc(u8, 1400) catch a.alloc(u8, 0) catch return));
    s.deps.st_sp_err.set(m().sparkline(.err, a.alloc(u8, 1400) catch a.alloc(u8, 0) catch return));
    s.deps.st_sp_lat.set(m().sparkline(.lat, a.alloc(u8, 1400) catch a.alloc(u8, 0) catch return));
    const p = m().params();
    s.deps.st_p_rate.set(std.fmt.allocPrint(a, "{d}%", .{p.rate_pct}) catch "");
    s.deps.st_p_err.set(std.fmt.allocPrint(a, "{d}.{d:0>2}%", .{ p.err_bp / 100, p.err_bp % 100 }) catch "");
    s.deps.st_p_lat.set(std.fmt.allocPrint(a, "{d}%", .{p.lat_pct}) catch "");
    s.deps.st_err_bp.set(@as(u64, @intFromFloat(@round(snap.err_pct * 100))));
    s.deps.st_rps_s.set(std.fmt.allocPrint(a, "{d}", .{@as(u64, @intFromFloat(@round(snap.rps)))}) catch "");
    s.deps.st_lat_s.set(std.fmt.allocPrint(a, "{d}", .{@as(u64, @intFromFloat(@round(snap.avg_lat_ms)))}) catch "");
    s.deps.st_total_s.set(std.fmt.allocPrint(a, "{d}", .{snap.total}) catch "");
    s.deps.st_up_s.set(std.fmt.allocPrint(a, "{d}h {d}m", .{ snap.uptime_s / 3600, (snap.uptime_s % 3600) / 60 }) catch "");
}

/// The session's view tree — built once into `deps.view_arena` and
/// reused for SSR, snapshots and live bindings.
fn viewNodes(s: *Session) []const forest.Node {
    if (s.deps.view_nodes) |n| return n;
    const a = s.deps.view_arena.allocator();
    s.deps.view_nodes = buildView(a, s);
    return s.deps.view_nodes.?;
}

// ── view ──────────────────────────────────────────────────────────

fn card(a: std.mem.Allocator, id: []const u8, label: []const u8, val: anytype) forest.Node {
    return forest.el(a, .div, .{ .class = "card" }, .{
        forest.el(a, .div, .{ .class = "clabel" }, label),
        forest.el(a, .div, .{ .class = "cval", .id = id, .text = val }, .{}),
    });
}

fn btn(a: std.mem.Allocator, action: []const u8, label: []const u8) forest.Node {
    return forest.el(a, .button, .{ .class = "btn", .on = .{ .click = action } }, label);
}

/// Range slider bound to a model param via `change` → POST /action.
fn ctl(
    a: std.mem.Allocator,
    label: []const u8,
    action: []const u8,
    min: u32,
    max: u32,
    step: u32,
    val: anytype,
) forest.Node {
    return forest.el(a, .div, .{ .class = "ctl" }, .{
        forest.el(a, .span, .{ .class = "ctl-name" }, label),
        forest.el(a, .input, .{
            .type = "range",
            .min = min,
            .max = max,
            .step = step,
            .on = .{ .change = action },
        }, .{}),
        forest.el(a, .span, .{ .class = "ctl-val", .text = val }, .{}),
    });
}

/// Sparkline card: label + SVG polyline whose `points` attr is a live
/// leaf bound to a store (attr op per refresh — no rebuild).
fn spark(a: std.mem.Allocator, id: []const u8, label: []const u8, pts: anytype) forest.Node {
    return forest.el(a, .div, .{ .class = "spark" }, .{
        forest.el(a, .div, .{ .class = "clabel" }, label),
        forest.el(a, .svg, .{ .class = "spark-svg", .viewBox = "0 0 120 28" }, .{
            forest.el(a, .polyline, .{ .id = id, .class = "spark-line", .points = pts, .fill = "none" }, .{}),
        }),
    });
}

fn errPctText(a: std.mem.Allocator, bp: u64) []const u8 {
    return std.fmt.allocPrint(a, "{d}.{d}%", .{ bp / 100, bp % 100 }) catch "—";
}

fn statusText(_: std.mem.Allocator, bp: u64) []const u8 {
    return if (bp > 500) "DEGRADED" else "HEALTHY";
}

fn isOk(bp: u64) bool {
    return bp <= 500;
}

fn isBad(bp: u64) bool {
    return bp > 500;
}

fn buildView(a: std.mem.Allocator, s: *Session) []const forest.Node {
    const d = &s.deps;
    const nodes = a.alloc(forest.Node, 1) catch @panic("OOM");
    nodes[0] = forest.el(a, .div, .{ .class = "mon" }, .{
        forest.el(a, .div, .{ .class = "mon-head" }, .{
            forest.el(a, .span, .{ .class = "mon-title" }, "zmon — live ops"),
            // Structural fine-graining: the pill mounts/unmounts live via
            // a `variant` key bound to derived stores — no rebuild.
            forest.variant(a, .{ .id = "mon-pill-ok" }, d.st_ok, .{
                forest.el(a, .span, .{ .class = "mon-pill ok" }, "HEALTHY"),
            }),
            forest.variant(a, .{ .id = "mon-pill-bad" }, d.st_bad, .{
                forest.el(a, .span, .{ .class = "mon-pill bad" }, "DEGRADED"),
            }),
        }),
        forest.el(a, .div, .{ .class = "mon-grid" }, .{
            card(a, "mon-rps", "req/s", d.st_rps_s),
            card(a, "mon-err", "error rate", forest.computed(d.st_err_bp, errPctText)),
            card(a, "mon-lat", "avg latency", d.st_lat_s),
            card(a, "mon-total", "total reqs", d.st_total_s),
            card(a, "mon-up", "uptime", d.st_up_s),
            card(a, "mon-status", "status", forest.computed(d.st_err_bp, statusText)),
        }),
        forest.el(a, .div, .{ .class = "mon-controls" }, .{
            ctl(a, "traffic", "ctl_rate", 0, 500, 10, d.st_p_rate),
            ctl(a, "errors", "ctl_err", 0, 3000, 50, d.st_p_err),
            ctl(a, "latency", "ctl_lat", 0, 400, 10, d.st_p_lat),
        }),
        forest.el(a, .div, .{ .class = "mon-sparks" }, .{
            spark(a, "sp-rps", "req/s", d.st_sp_rps),
            spark(a, "sp-err", "errors %", d.st_sp_err),
            spark(a, "sp-lat", "latency ms", d.st_sp_lat),
        }),
        forest.el(a, .div, .{ .id = "feed", .class = "feed", .text = d.st_feed }, .{}),
        forest.el(a, .div, .{ .class = "mon-logwrap" }, .{
            forest.el(a, .div, .{ .class = "clabel" }, "request log"),
            forest.el(a, .div, .{ .id = "mon-log", .class = "mon-log", .text = d.st_log }, .{}),
        }),
        forest.el(a, .div, .{ .class = "mon-actions" }, .{
            btn(a, "inject_ok", "ok req"),
            btn(a, "inject_err", "err req"),
            btn(a, "inject_slow", "slow req"),
            btn(a, "inject_storm", "storm ×400"),
        }),
    });
    return nodes;
}

// ── tests ───────────────────────────────────────────────────────

fn testModel(gpa: std.mem.Allocator) void {
    model = MonModel.init(std.testing.io, gpa);
}

test "live_shared session: contract surface, servePage, live patch ops" {
    const alloc = std.testing.allocator;
    testModel(alloc);
    defer model = undefined;

    const s = Session.create(alloc, std.testing.io);
    defer s.deinit();

    // Contract surface the server relies on.
    try std.testing.expectEqualStrings("zmon", Session.page_title);
    try std.testing.expectEqualStrings("app app-mon", Session.page_class);
    try std.testing.expectEqualStrings("zfxm", Session.cookie_name);
    try std.testing.expectEqual(zmeta.Archetype.live_shared, Session.archetype);
    // Plain variant — live_shared declares no render-group hooks, so
    // http.zig's @hasDecl probes keep the per-session publish/fetch path.
    try std.testing.expect(!@hasDecl(Session, "publishPending"));
    try std.testing.expect(!@hasDecl(Session, "streamRev"));
    try std.testing.expect(!@hasDecl(Session, "streamHistory"));
    try std.testing.expect(!@hasDecl(Session, "membershipEpoch"));
    try std.testing.expect(Session.validPath("/"));
    try std.testing.expect(!Session.validPath("/bogus"));

    // servePage: "/" ships the dashboard; bogus paths 404.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.testing.expect(try s.servePage("/", &aw.writer));
    const page = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, page, "zmon — live ops") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"mon-log\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"sp-rps\"") != null);
    try std.testing.expect(!(try s.servePage("/bogus", &aw.writer)));

    // dispatch → model record + refreshAndPing → live binders emit ops
    // into s.log during the notify phase; Deps.render stamps the rev.
    const rev_before = s.seq.get();
    try s.dispatch("inject_ok", null, null, null);
    try std.testing.expect(s.seq.get() == rev_before + 1);
    try std.testing.expect(s.log.revision == s.seq.get());
    try std.testing.expect(s.log.patches.items.len > 0);
    var jw: std.Io.Writer.Allocating = .init(alloc);
    defer jw.deinit();
    s.log.writeJson(&jw.writer) catch @panic("OOM");
    const batch = jw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, batch, "\"op\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, batch, "id\":\"mon-log\"") != null);

    // syncPull picks up shared-model movement: the record above bumped
    // global_seq, so the next pull refreshes+ping (another revision).
    m().record(.{ .ok = true, .lat_ms = 5, .method = "GET", .path = "/x", .status = 200 });
    s.syncPull();
    try std.testing.expect(s.deps.seen_seq == m().global_seq.load(.seq_cst));
    try std.testing.expect(s.seq.get() == rev_before + 2);

    // ctl_* actions validate + clamp through the model params.
    try s.dispatch("ctl_rate", null, "250", null);
    try std.testing.expectEqual(@as(u32, 250), m().params().rate_pct);
    try std.testing.expectError(error.InvalidAction, s.dispatch("bogus", null, null, null));
    try std.testing.expectError(error.InvalidAction, s.dispatch("ctl_rate", null, "nan", null));
}

test "live_shared session: snapshot path refreshes stores and serializes the cached tree" {
    const alloc = std.testing.allocator;
    testModel(alloc);
    defer model = undefined;

    const s = Session.create(alloc, std.testing.io);
    defer s.deinit();

    // No servePage/seedDom — the snapshot path must still produce the
    // full view with live store values (refreshStores inside
    // buildViewNodes).
    _ = s.render_arena.reset(.retain_capacity);
    const a = s.render_arena.allocator();
    var sw: std.Io.Writer.Allocating = .init(alloc);
    defer sw.deinit();
    try forest.writeSnapshotOps(a, s.buildViewNodes(a), &sw.writer);
    const json = sw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json, "mon-log") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sp-rps") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "mon-pill-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "feed") != null);
    // The once-built tree is cached — a second call returns the same nodes.
    _ = s.render_arena.reset(.retain_capacity);
    const a2 = s.render_arena.allocator();
    try std.testing.expect(s.buildViewNodes(a2).ptr == viewNodes(s).ptr);
}
