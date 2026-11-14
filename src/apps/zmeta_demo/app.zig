//! zmeta_demo — minimal multi-route app proving the codegen layer
//! (docs/meta-framework.md §5): file-based routing with typed params,
//! type-safe hrefs, prepare→404, and the comptime action table.
//!
//! Routes (generated into gen/routes.zig from pages/):
//!   "/"               pages/index.zig
//!   "/item/:id"       pages/item/[id].zig   (prepare 404s unknown ids)
//!   "/live"           pages/live.zig        (live island: bindTree, no diff)
const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const zmeta = @import("zmeta.zig");
const routes = @import("gen/routes.zig");
const actions = @import("gen/actions.zig");

pub const Route = routes.Route;
pub const act = actions.act;

/// Static item catalogue — item/[id].zig's prepare() 404s unknown ids.
pub const Item = struct { id: u64, name: []const u8, blurb: []const u8 };
pub const items = [_]Item{
    .{ .id = 1, .name = "cog", .blurb = "a small brass gear" },
    .{ .id = 2, .name = "spring", .blurb = "never loses tension" },
    .{ .id = 3, .name = "lens", .blurb = "focuses light and opinions" },
};

pub fn item(id: u64) ?Item {
    for (items) |it| {
        if (it.id == id) return it;
    }
    return null;
}

/// Total likes across all items — the index page's counter.
pub fn totalLikes(deps: anytype) u64 {
    var n: u64 = 0;
    var it = deps.likes.valueIterator();
    while (it.next()) |v| n += v.*;
    return n;
}

/// The app's `zmeta.Session` Deps: model fields + the generated
/// routing/action glue. Everything domain-specific lives here; the
/// skeleton owns the transport contract.
pub const DemoDeps = struct {
    pub const page_title = "zmeta demo";
    pub const page_class = "app";
    pub const cookie_name = "zqmd";

    /// Current typed route — written by the generated `routes.setRoute`
    /// glue; read by `routes.prepare`/`routes.viewNodes` dispatch.
    route: routes.Route = .{ .index = .{} },

    /// Per-session model state.
    pings: u64 = 0,
    /// Per-item like counts (item id → count).
    likes: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Live-island counter — a real zefx Store so `.text(ticks)`
    /// binds with `Bound.live` hooks (bindTree pushes ops, no rebuild).
    ticks: *zefx.Store(u64) = undefined,

    /// `Deps.init` — graph handles beyond the skeleton's seq.
    pub fn init(s: *Session) DemoDeps {
        var d: DemoDeps = .{};
        d.ticks = s.app.createStore(u64, 0);
        return d;
    }

    /// `Deps.deinit` — free domain allocations before skeleton teardown.
    pub fn deinit(s: *Session) void {
        s.deps.likes.deinit(s.gpa);
    }

    /// Route validation + typed-route storage — generated glue.
    pub fn setRoute(s: *Session, path: []const u8) bool {
        return routes.setRoute(s, path);
    }

    /// Pure route pre-check — generated glue.
    pub fn validPath(path: []const u8) bool {
        return routes.validPath(path);
    }

    /// Route-param gate — generated dispatch to page `prepare`s.
    pub fn prepare(s: *Session, env: *const zmeta.Env) !void {
        try routes.prepare(s, env);
    }

    /// The `<main>` body — generated dispatch to the active page's view.
    pub fn view(a: std.mem.Allocator, s: *Session, env: *const zmeta.Env) []const forest.Node {
        return routes.viewNodes(a, s, env);
    }

    /// Live-island routes — generated `routes.isLive` over the typed
    /// route; pages opt in with `pub const live = true`.
    pub fn pageLive(s: *Session) bool {
        return routes.isLive(s.deps.route);
    }

    /// GET /api/* — generated dispatch to `pages/api/` handlers; a
    /// per-request arena owns the JSON body (freed on return).
    /// false → not an api path → normal page handling.
    pub fn serveApi(s: *Session, path: []const u8, writer: anytype) !bool {
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const env = zmeta.Env{ .route = path, .query = s.query };
        const body = routes.api(a, s, path, &env) catch return error.ApiFailed;
        const b = body orelse return false;
        try writer.writeAll(b);
        return true;
    }

    /// Whitelisted action entry — generated dispatch to `on_<name>`.
    pub fn dispatch(
        s: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        return actions.dispatch(s, action, arg, value, fields);
    }

    /// act.ping — index page button; bumps the per-session counter.
    pub fn on_ping(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        _ = arg;
        _ = value;
        _ = fields;
        s.deps.pings += 1;
        s.bumpSeq();
    }

    /// act.tick — live page button; store.set flushes watchers, the
    /// bindTree binder emits the text op, render() only stamps rev.
    pub fn on_tick(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        _ = arg;
        _ = value;
        _ = fields;
        s.bumpSeq();
        s.deps.ticks.set(s.deps.ticks.get() + 1);
    }

    /// act.like — item page button; `arg` carries the item id.
    pub fn on_like(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        _ = value;
        _ = fields;
        const a = arg orelse return error.InvalidAction;
        const id = std.fmt.parseInt(u64, a, 10) catch return error.InvalidAction;
        const gop = try s.deps.likes.getOrPut(s.gpa, id);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        s.bumpSeq();
    }
};

/// One browser session: an isolated zefx graph + demo model + DOM patch
/// state, provided by the zmeta skeleton (see zmeta/session.zig).
pub const Session = zmeta.Session(DemoDeps);

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "generated routes: parse, href, servePage 404, act dispatch" {
    const alloc = std.testing.allocator;

    // parseRoute: typed params + rejection cases.
    const r1 = routes.parseRoute("/item/7").?;
    try std.testing.expect(r1.item.id == 7);
    try std.testing.expect(std.meta.activeTag(routes.parseRoute("/").?) == .index);
    try std.testing.expect(routes.parseRoute("/item/x") == null);
    try std.testing.expect(routes.parseRoute("/item/1/2") == null);
    try std.testing.expect(routes.parseRoute("/nope") == null);
    try std.testing.expect(routes.parseRoute("") == null);
    try std.testing.expect(Session.validPath("/item/3"));
    try std.testing.expect(!Session.validPath("/bogus"));

    // href: dynamic routes allocate into `a`; static routes return a
    // comptime literal (nothing to free).
    const h = routes.href(alloc, .{ .item = .{ .id = 7 } });
    defer alloc.free(h);
    try std.testing.expectEqualStrings("/item/7", h);
    try std.testing.expectEqualStrings("/", routes.href(alloc, .{ .index = .{} }));

    // Session-level: unknown item → servePage false (404); known → HTML.
    const s = Session.create(alloc, std.testing.io);
    defer s.deinit();
    var bw: std.Io.Writer.Allocating = .init(alloc);
    defer bw.deinit();
    try std.testing.expect(!(try s.servePage("/item/99", &bw.writer)));
    var cw: std.Io.Writer.Allocating = .init(alloc);
    defer cw.deinit();
    try std.testing.expect(try s.servePage("/item/1", &cw.writer));
    try std.testing.expect(std.mem.indexOf(u8, cw.writer.buffered(), "cog") != null);

    // act table: like bumps the per-item count; unknown action rejected.
    try s.dispatch(actions.act.like, "1", null, null);
    try std.testing.expectEqual(@as(u64, 1), s.deps.likes.get(1).?);
    try s.dispatch(actions.act.ping, null, null, null);
    try std.testing.expectEqual(@as(u64, 1), s.deps.pings);
    try std.testing.expectError(error.InvalidAction, s.dispatch("bogus", null, null, null));
}
