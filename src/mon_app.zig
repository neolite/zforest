//! zmon — live ops dashboard on fine-grained bindings: the view tree is
//! built ONCE per session, `bindTree` subscribes every bound leaf
//! (`.text`/attrs/`variant` keys) to its zefx store, and store
//! notifications emit patch ops directly — no per-tick rebuild+diff.
//! Derived stores (`map`) feed `computed` bindings and `variant` pills.

const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const History = @import("server/history.zig").History;
const MonModel = @import("mon_model.zig").MonModel;

/// Shared model instance, assigned by mon_main before serve().
pub var model: MonModel = undefined;

fn m() *MonModel {
    return &model;
}

/// One browser session on the single "/" route: isolated graph + DOM
/// state, stores refreshed from the shared model.
pub const Session = struct {
    /// Session contract for the generic server (see server/http.zig).
    pub const page_title = "zmon";
    pub const page_class = "app app-mon";
    pub const cookie_name = "zfxm";

    gpa: std.mem.Allocator,
    io: std.Io,
    app: zefx.App,

    /// Scratch for the Set-Cookie value emitted on the minting POST.
    out_cookie_buf: [600]u8 = undefined,
    out_cookie: []const u8 = &.{},
    /// Last `model.global_seq` this session rendered — syncPull's cursor.
    seen_seq: u64 = 0,

    ping: *zefx.Event(Ping) = undefined,
    seq: *zefx.Store(u64) = undefined,

    // Dashboard stores — strings formatted in refreshStores, slices into
    // fmt_arena (valid until the next refresh; every consumer refreshes
    // or renders synchronously after one).
    st_rps_s: *zefx.Store([]const u8) = undefined,
    st_lat_s: *zefx.Store([]const u8) = undefined,
    st_total_s: *zefx.Store([]const u8) = undefined,
    st_up_s: *zefx.Store([]const u8) = undefined,
    st_feed: *zefx.Store([]const u8) = undefined,
    /// Firehose log text — one leaf, rewritten whole each refresh.
    st_log: *zefx.Store([]const u8) = undefined,
    /// Sparkline `points` payloads — attr-bound leaves on SVG polylines.
    st_sp_rps: *zefx.Store([]const u8) = undefined,
    st_sp_err: *zefx.Store([]const u8) = undefined,
    st_sp_lat: *zefx.Store([]const u8) = undefined,
    /// Traffic-control readouts ("100%", "10.00%", "100%").
    st_p_rate: *zefx.Store([]const u8) = undefined,
    st_p_err: *zefx.Store([]const u8) = undefined,
    st_p_lat: *zefx.Store([]const u8) = undefined,
    /// Error rate in basis points (0..10000) — feeds `computed` bindings.
    st_err_bp: *zefx.Store(u64) = undefined,
    /// Derived health flags — drive the `variant` status pills.
    st_ok: *zefx.Store(bool) = undefined,
    st_bad: *zefx.Store(bool) = undefined,

    dom: forest.Dom,
    log: forest.PatchLog,
    history: History,
    render_arena: std.heap.ArenaAllocator,
    fmt_arena: std.heap.ArenaAllocator,
    /// Session-lifetime arena for the view tree — built once, never reset
    /// (bindings capture its slices; rebuilding would orphan subscriptions).
    view_arena: std.heap.ArenaAllocator,
    view_nodes: ?[]const forest.Node = null,
    csrf_token: []u8 = &.{},
    /// Store-stamped incarnation (see the Session contract in
    /// server/http.zig): distinguishes this session from a previous one
    /// evicted+recreated under the same (cookie token, route) key.
    incarnation: u64 = 0,

    const Ping = struct {};

    pub fn create(gpa: std.mem.Allocator, io: std.Io) *Session {
        return createSession(gpa, io);
    }

    pub fn deinit(self: *Session) void {
        if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
        self.dom.deinit();
        self.log.deinit();
        self.history.deinit();
        self.render_arena.deinit();
        self.fmt_arena.deinit();
        self.view_arena.deinit();
        self.app.deinit();
        self.gpa.destroy(self);
    }

    pub fn setCsrf(self: *Session, token: []u8) void {
        if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
        self.csrf_token = token;
    }

    // ── routing (single page) ─────────────────────────────────────

    pub fn validPath(path: []const u8) bool {
        return std.mem.eql(u8, path, "/");
    }

    pub fn setRoute(_: *Session, path: []const u8) bool {
        return std.mem.eql(u8, path, "/");
    }

    /// Full-page render for a navigating client.
    pub fn servePage(self: *Session, path: []const u8, writer: anytype) !bool {
        if (!self.setRoute(path)) return false;
        self.refreshStores();
        self.dom.reset();
        try self.writeView(writer);
        self.seedDom();
        return true;
    }

    /// SSE-worker hook: when the shared model moved, refresh stores and
    /// ping — the flush renders this session's diff.
    pub fn syncPull(self: *Session) void {
        const seq_now = m().global_seq.load(.seq_cst);
        if (seq_now == self.seen_seq) return;
        self.seen_seq = seq_now;
        self.refreshStores();
        self.ping.emit(.{});
    }

    // ── actions ────────────────────────────────────────────────────

    /// Whitelisted action entry — inject synthetic requests so the
    /// dashboard moves without waiting for the ticker.
    pub fn dispatch(
        self: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        _ = arg;
        _ = fields;
        self.out_cookie = "";
        var rb: [16]u8 = undefined;
        self.io.random(&rb);
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
        self.refreshStores();
        self.ping.emit(.{});
    }

    // ── graph wiring ───────────────────────────────────────────────

    fn wire(self: *Session) void {
        const eng = &self.app.eng;

        const PingCtx = struct { s: *Session };
        const pctx = self.gpa.create(PingCtx) catch @panic("OOM");
        pctx.* = .{ .s = self };
        self.ping.reducers.append(eng.allocator, .{
            .ctx = @ptrCast(pctx),
            .trigger = &struct {
                fn trig(raw: *anyopaque, _: *const anyopaque) void {
                    const c: *PingCtx = @ptrCast(@alignCast(raw));
                    c.s.seq.set(c.s.seq.get() + 1);
                }
            }.trig,
        }) catch @panic("OOM");
        eng.trackGraphAlloc(@ptrCast(pctx), &struct {
            fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                a.destroy(@as(*PingCtx, @ptrCast(@alignCast(p))));
            }
        }.dtor);

        eng.onAfterFlush(.{
            .ctx = @ptrCast(self),
            .call = &struct {
                fn commit(raw: *anyopaque) void {
                    const s: *Session = @ptrCast(@alignCast(raw));
                    // Live bindings already emitted their ops during the
                    // notify phase; the hook only stamps the batch rev.
                    s.log.revision = s.seq.get();
                }
            }.commit,
        });
    }

    // ── stores ← model ─────────────────────────────────────────────

    /// Pull the shared model snapshot into this session's stores. String
    /// slices live in fmt_arena until the next refresh.
    fn refreshStores(self: *Session) void {
        _ = self.fmt_arena.reset(.retain_capacity);
        const a = self.fmt_arena.allocator();
        const s = m().snapshot();
        const feed = m().feed(a.alloc(u8, 1400) catch a.alloc(u8, 0) catch return);
        self.st_feed.set(feed);
        const log = m().logText(a.alloc(u8, 24576) catch a.alloc(u8, 0) catch return);
        self.st_log.set(log);
        self.st_sp_rps.set(m().sparkline(.rps, a.alloc(u8, 1400) catch a.alloc(u8, 0) catch return));
        self.st_sp_err.set(m().sparkline(.err, a.alloc(u8, 1400) catch a.alloc(u8, 0) catch return));
        self.st_sp_lat.set(m().sparkline(.lat, a.alloc(u8, 1400) catch a.alloc(u8, 0) catch return));
        const p = m().params();
        self.st_p_rate.set(std.fmt.allocPrint(a, "{d}%", .{p.rate_pct}) catch "");
        self.st_p_err.set(std.fmt.allocPrint(a, "{d}.{d:0>2}%", .{ p.err_bp / 100, p.err_bp % 100 }) catch "");
        self.st_p_lat.set(std.fmt.allocPrint(a, "{d}%", .{p.lat_pct}) catch "");
        self.st_err_bp.set(@as(u64, @intFromFloat(@round(s.err_pct * 100))));
        self.st_rps_s.set(std.fmt.allocPrint(a, "{d}", .{@as(u64, @intFromFloat(@round(s.rps)))}) catch "");
        self.st_lat_s.set(std.fmt.allocPrint(a, "{d}", .{@as(u64, @intFromFloat(@round(s.avg_lat_ms)))}) catch "");
        self.st_total_s.set(std.fmt.allocPrint(a, "{d}", .{s.total}) catch "");
        self.st_up_s.set(std.fmt.allocPrint(a, "{d}h {d}m", .{ s.uptime_s / 3600, (s.uptime_s % 3600) / 60 }) catch "");
    }

    // ── rendering ──────────────────────────────────────────────────

    /// The session's view tree — built once into `view_arena` and reused
    /// for SSR, snapshots and live bindings.
    fn viewNodes(self: *Session) []const forest.Node {
        if (self.view_nodes) |n| return n;
        const a = self.view_arena.allocator();
        self.view_nodes = buildView(a, self);
        return self.view_nodes.?;
    }

    /// Render the `<main>` inner content — used by the initial page.
    pub fn writeView(self: *Session, writer: anytype) !void {
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        try forest.writeHtml(a, self.viewNodes(), writer);
    }

    /// The session's current view nodes — the SSE snapshot writer
    /// serializes them via `forest.writeSnapshotOps`.
    pub fn buildViewNodes(self: *Session, _: std.mem.Allocator) []const forest.Node {
        self.refreshStores();
        return self.viewNodes();
    }

    /// Seed tracked DOM state to match the shipped page, then subscribe
    /// every live-capable leaf — from here on, store notifications emit
    /// patches directly (no rebuild, no diff).
    pub fn seedDom(self: *Session) void {
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        const nodes = self.viewNodes();
        forest.diff(a, nodes, &self.dom, &self.log);
        self.log.clear();
        forest.bindTree(self.fmt_arena.allocator(), nodes, &self.dom, &self.log);
    }
};

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
    const nodes = a.alloc(forest.Node, 1) catch @panic("OOM");
    nodes[0] = forest.el(a, .div, .{ .class = "mon" }, .{
        forest.el(a, .div, .{ .class = "mon-head" }, .{
            forest.el(a, .span, .{ .class = "mon-title" }, "zmon — live ops"),
            // Structural fine-graining: the pill mounts/unmounts live via
            // a `variant` key bound to derived stores — no rebuild.
            forest.variant(a, .{ .id = "mon-pill-ok" }, s.st_ok, .{
                forest.el(a, .span, .{ .class = "mon-pill ok" }, "HEALTHY"),
            }),
            forest.variant(a, .{ .id = "mon-pill-bad" }, s.st_bad, .{
                forest.el(a, .span, .{ .class = "mon-pill bad" }, "DEGRADED"),
            }),
        }),
        forest.el(a, .div, .{ .class = "mon-grid" }, .{
            card(a, "mon-rps", "req/s", s.st_rps_s),
            card(a, "mon-err", "error rate", forest.computed(s.st_err_bp, errPctText)),
            card(a, "mon-lat", "avg latency", s.st_lat_s),
            card(a, "mon-total", "total reqs", s.st_total_s),
            card(a, "mon-up", "uptime", s.st_up_s),
            card(a, "mon-status", "status", forest.computed(s.st_err_bp, statusText)),
        }),
        forest.el(a, .div, .{ .class = "mon-controls" }, .{
            ctl(a, "traffic", "ctl_rate", 0, 500, 10, s.st_p_rate),
            ctl(a, "errors", "ctl_err", 0, 3000, 50, s.st_p_err),
            ctl(a, "latency", "ctl_lat", 0, 400, 10, s.st_p_lat),
        }),
        forest.el(a, .div, .{ .class = "mon-sparks" }, .{
            spark(a, "sp-rps", "req/s", s.st_sp_rps),
            spark(a, "sp-err", "errors %", s.st_sp_err),
            spark(a, "sp-lat", "latency ms", s.st_sp_lat),
        }),
        forest.el(a, .div, .{ .id = "feed", .class = "feed", .text = s.st_feed }, .{}),
        forest.el(a, .div, .{ .class = "mon-logwrap" }, .{
            forest.el(a, .div, .{ .class = "clabel" }, "request log"),
            forest.el(a, .div, .{ .id = "mon-log", .class = "mon-log", .text = s.st_log }, .{}),
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

// ── session factory ───────────────────────────────────────────────

pub fn createSession(gpa: std.mem.Allocator, io: std.Io) *Session {
    const s = gpa.create(Session) catch @panic("OOM");
    s.* = .{
        .gpa = gpa,
        .io = io,
        .app = zefx.createApp(gpa),
        .dom = forest.Dom.init(gpa),
        .log = forest.PatchLog.init(gpa),
        .history = History.init(gpa),
        .render_arena = std.heap.ArenaAllocator.init(gpa),
        .fmt_arena = std.heap.ArenaAllocator.init(gpa),
        .view_arena = std.heap.ArenaAllocator.init(gpa),
    };
    s.ping = s.app.createEvent(Session.Ping);
    s.seq = s.app.createStore(u64, 0);
    s.st_rps_s = s.app.createStore([]const u8, "");
    s.st_lat_s = s.app.createStore([]const u8, "");
    s.st_total_s = s.app.createStore([]const u8, "");
    s.st_up_s = s.app.createStore([]const u8, "");
    s.st_feed = s.app.createStore([]const u8, "");
    s.st_log = s.app.createStore([]const u8, "");
    s.st_sp_rps = s.app.createStore([]const u8, "");
    s.st_sp_err = s.app.createStore([]const u8, "");
    s.st_sp_lat = s.app.createStore([]const u8, "");
    s.st_p_rate = s.app.createStore([]const u8, "100%");
    s.st_p_err = s.app.createStore([]const u8, "10.00%");
    s.st_p_lat = s.app.createStore([]const u8, "100%");
    s.st_err_bp = s.app.createStore(u64, 0);
    s.st_ok = s.st_err_bp.map(bool, isOk);
    s.st_bad = s.st_err_bp.map(bool, isBad);
    s.wire();
    return s;
}
