//! GENERATED FILE — do not edit. Regenerate with `zig build gen`
//! (or `zig run src/zmeta/gen.zig -- <app-dir>`).
//! Source: pages/ files + actions.zig manifest.

const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../../../zmeta/root.zig");

const index_page = @import("../pages/index.zig");
const b_page = @import("../pages/b/[slug].zig");
const t_page = @import("../pages/t/[post]/index.zig");
const t_c_page = @import("../pages/t/[post]/c/[comment].zig");

/// Typed route — one tag per page file. Dynamic `[name]`
/// segments carry the page's `params` struct as payload.
pub const Route = union(enum) {
    index: index_page.params,
    b: b_page.params,
    t: t_page.params,
    t_c: t_c_page.params,
};

/// Parse a request path into a typed Route. Static segments take
/// precedence over `[name]` dynamics at the same position;
/// `[...name]` catch-alls match any non-empty tail. Int params
/// parse as integers; `[]const u8` params slice the path —
/// callers storing the route must pass session-owned memory
/// (the skeleton's `setRoute` does). Returns null on any
/// mismatch — the caller maps that to 404.
pub fn parseRoute(path: []const u8) ?Route {
    if (std.mem.eql(u8, path, "/")) return Route{ .index = .{} };
    if (!std.mem.startsWith(u8, path, "/")) return null;
    var segs: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |seg| {
        // Store only what fits — catch-all routes match tails
        // deeper than the deepest static route, so `n` keeps
        // counting past the buffer instead of bailing out.
        if (n < segs.len) segs[n] = seg;
        n += 1;
    }
    return result: {
        if (n == 2 and std.mem.eql(u8, segs[0], "b")) {
            const slug = segs[1];
            break :result Route{ .b = .{ .slug = slug } };
        }
        if (n == 2 and std.mem.eql(u8, segs[0], "t")) {
            const post = std.fmt.parseInt(u64, segs[1], 10) catch break :result null;
            break :result Route{ .t = .{ .post = post } };
        }
        if (n == 4 and std.mem.eql(u8, segs[0], "t") and std.mem.eql(u8, segs[2], "c")) {
            const post = std.fmt.parseInt(u64, segs[1], 10) catch break :result null;
            const comment = std.fmt.parseInt(u64, segs[3], 10) catch break :result null;
            break :result Route{ .t_c = .{ .post = post, .comment = comment } };
        }
        break :result null;
    };
}

/// Session glue: parse + store the typed route. Deps.setRoute
/// delegates here; returns false → 404.
pub fn setRoute(s: anytype, path: []const u8) bool {
    const r = parseRoute(path) orelse return false;
    s.deps.route = r;
    return true;
}

/// Pure route pre-check for the server's validPath hook.
pub fn validPath(path: []const u8) bool {
    return parseRoute(path) != null;
}

/// Type-safe href: `href(a, .{ .item = .{ .id = 3 } })` allocates
/// the path in `a` (the render arena in views). Static routes
/// return comptime literals.
pub fn href(a: std.mem.Allocator, r: Route) []const u8 {
    return switch (r) {
        .index => "/",
        .b => |p| std.fmt.allocPrint(a, "/b/{s}", .{p.slug}) catch @panic("OOM"),
        .t => |p| std.fmt.allocPrint(a, "/t/{d}", .{p.post}) catch @panic("OOM"),
        .t_c => |p| std.fmt.allocPrint(a, "/t/{d}/c/{d}", .{p.post, p.comment}) catch @panic("OOM"),
    };
}

fn preparePage(comptime Page: type, s: anytype, p: anytype, env: *const zmeta.Env) !void {
    if (@hasDecl(Page, "prepare")) try Page.prepare(s, p, env);
}

/// Route-param gate: Deps.prepare delegates here. Any page
/// `prepare` error → servePage 404s before view work.
pub fn prepare(s: anytype, env: *const zmeta.Env) !void {
    switch (s.deps.route) {
        .index => |p| try preparePage(index_page, s, p, env),
        .b => |p| try preparePage(b_page, s, p, env),
        .t => |p| try preparePage(t_page, s, p, env),
        .t_c => |p| try preparePage(t_c_page, s, p, env),
    }
}

/// View dispatch: Deps.view delegates here. Each page's
/// `view(a, s, params, env) forest.Node` becomes one node,
/// wrapped by every applicable `_layout.zig` (outermost
/// first — `pages/_layout.zig` wraps all pages).
pub fn viewNodes(a: std.mem.Allocator, s: anytype, env: *const zmeta.Env) []const forest.Node {
    const nodes = a.alloc(forest.Node, 1) catch @panic("OOM");
    nodes[0] = switch (s.deps.route) {
        .index => |p| index_page.view(a, s, p, env),
        .b => |p| b_page.view(a, s, p, env),
        .t => |p| t_page.view(a, s, p, env),
        .t_c => |p| t_c_page.view(a, s, p, env),
    };
    return nodes;
}
