//! zmon — live ops dashboard. The reactive graph genuinely drives the
//! view here: `syncPull`/injects refresh session stores from the shared
//! `MonModel`, store.set flushes settle, and the after-flush hook diffs
//! the declarative view — only changed bindings ship as SSE patches.

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
    /// Error rate in basis points (0..10000) — feeds `computed` bindings.
    st_err_bp: *zefx.Store(u64) = undefined,

    dom: forest.Dom,
    log: forest.PatchLog,
    history: History,
    render_arena: std.heap.ArenaAllocator,
    fmt_arena: std.heap.ArenaAllocator,
    csrf_token: []u8 = &.{},

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
        _ = value;
        _ = fields;
        self.out_cookie = "";
        var rb: [16]u8 = undefined;
        self.io.random(&rb);
        const roll = std.mem.readInt(u32, rb[0..4], .little);
        if (std.mem.eql(u8, action, "inject_ok")) {
            m().record(true, 6.0 + @as(f64, @floatFromInt(roll % 30)));
        } else if (std.mem.eql(u8, action, "inject_err")) {
            m().record(false, 250.0 + @as(f64, @floatFromInt(roll % 500)));
        } else if (std.mem.eql(u8, action, "inject_slow")) {
            m().record(true, 700.0 + @as(f64, @floatFromInt(roll % 400)));
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
                fn render(raw: *anyopaque) void {
                    const s: *Session = @ptrCast(@alignCast(raw));
                    s.render();
                }
            }.render,
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
        self.st_err_bp.set(@as(u64, @intFromFloat(@round(s.err_pct * 100))));
        self.st_rps_s.set(std.fmt.allocPrint(a, "{d}", .{@as(u64, @intFromFloat(@round(s.rps)))}) catch "");
        self.st_lat_s.set(std.fmt.allocPrint(a, "{d}", .{@as(u64, @intFromFloat(@round(s.avg_lat_ms)))}) catch "");
        self.st_total_s.set(std.fmt.allocPrint(a, "{d}", .{s.total}) catch "");
        self.st_up_s.set(std.fmt.allocPrint(a, "{d}h {d}m", .{ s.uptime_s / 3600, (s.uptime_s % 3600) / 60 }) catch "");
    }

    // ── rendering ──────────────────────────────────────────────────

    fn render(self: *Session) void {
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        forest.diff(a, buildView(a, self), &self.dom, &self.log);
        self.log.revision = self.seq.get();
    }

    /// Render the `<main>` inner content — used by the initial page.
    pub fn writeView(self: *Session, writer: anytype) !void {
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        try forest.writeHtml(a, buildView(a, self), writer);
    }

    /// The session's current view nodes — the SSE snapshot writer
    /// serializes them via `forest.writeSnapshotOps`.
    pub fn buildViewNodes(self: *Session, a: std.mem.Allocator) []const forest.Node {
        self.refreshStores();
        return buildView(a, self);
    }

    /// Seed tracked DOM state to match markup already emitted in the page.
    pub fn seedDom(self: *Session) void {
        self.render();
        self.log.clear();
    }
};

// ── view ──────────────────────────────────────────────────────────

fn card(a: std.mem.Allocator, label: []const u8, val: anytype) forest.Node {
    return forest.el(a, .div, .{ .class = "card" }, .{
        forest.el(a, .div, .{ .class = "clabel" }, label),
        forest.el(a, .div, .{ .class = "cval", .text = val }, .{}),
    });
}

fn btn(a: std.mem.Allocator, action: []const u8, label: []const u8) forest.Node {
    return forest.el(a, .button, .{ .class = "btn", .on = .{ .click = action } }, label);
}

fn errPctText(a: std.mem.Allocator, bp: u64) []const u8 {
    return std.fmt.allocPrint(a, "{d}.{d}%", .{ bp / 100, bp % 100 }) catch "—";
}

fn statusText(_: std.mem.Allocator, bp: u64) []const u8 {
    return if (bp > 500) "DEGRADED" else "HEALTHY";
}

fn buildView(a: std.mem.Allocator, s: *Session) []const forest.Node {
    const nodes = a.alloc(forest.Node, 1) catch @panic("OOM");
    nodes[0] = forest.el(a, .div, .{ .class = "mon" }, .{
        forest.el(a, .div, .{ .class = "mon-head" }, .{
            forest.el(a, .span, .{ .class = "mon-title" }, "zmon — live ops"),
            forest.el(a, .span, .{ .class = "mon-status", .text = forest.computed(s.st_err_bp, statusText) }, .{}),
        }),
        forest.el(a, .div, .{ .class = "mon-grid" }, .{
            card(a, "req/s", s.st_rps_s),
            card(a, "error rate", forest.computed(s.st_err_bp, errPctText)),
            card(a, "avg latency", s.st_lat_s),
            card(a, "total reqs", s.st_total_s),
            card(a, "uptime", s.st_up_s),
            card(a, "status", forest.computed(s.st_err_bp, statusText)),
        }),
        forest.el(a, .div, .{ .id = "feed", .class = "feed", .text = s.st_feed }, .{}),
        forest.el(a, .div, .{ .class = "mon-actions" }, .{
            btn(a, "inject_ok", "ok req"),
            btn(a, "inject_err", "err req"),
            btn(a, "inject_slow", "slow req"),
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
    };
    s.ping = s.app.createEvent(Session.Ping);
    s.seq = s.app.createStore(u64, 0);
    s.st_rps_s = s.app.createStore([]const u8, "");
    s.st_lat_s = s.app.createStore([]const u8, "");
    s.st_total_s = s.app.createStore([]const u8, "");
    s.st_up_s = s.app.createStore([]const u8, "");
    s.st_feed = s.app.createStore([]const u8, "");
    s.st_err_bp = s.app.createStore(u64, 0);
    s.wire();
    return s;
}
