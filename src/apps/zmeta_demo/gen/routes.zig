//! GENERATED FILE — do not edit. Regenerate with `zig build gen`
//! (or `zig run src/zmeta/gen.zig -- <app-dir>`).
//! Source: pages/ files + actions.zig manifest.

const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../../../zmeta/root.zig");

const index_page = @import("../pages/index.zig");
const docs_rest_page = @import("../pages/docs/[...rest].zig");
const item_page = @import("../pages/item/[id].zig");
const search_page = @import("../pages/search.zig");
const structure_page = @import("../pages/structure.zig");
const tag_page = @import("../pages/tag/[tag].zig");
const wiki_rest_page = @import("../pages/wiki/[[...rest]].zig");
const ping_api = @import("../pages/api/ping.zig");
const lay_root = @import("../pages/_layout.zig");

/// Typed route — one tag per page file. Dynamic `[name]`
/// segments carry the page's `params` struct as payload.
pub const Route = union(enum) {
    index: index_page.params,
    docs_rest: docs_rest_page.params,
    item: item_page.params,
    search: search_page.params,
    structure: structure_page.params,
    tag: tag_page.params,
    wiki_rest: wiki_rest_page.params,
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
    var segs: [2][]const u8 = undefined;
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
        if (n >= 2 and std.mem.eql(u8, segs[0], "docs")) {
            var ca_off: usize = 1;
            for (segs[0..1]) |sg| ca_off += sg.len + 1;
            const rest = path[ca_off..];
            if (rest.len == 0) break :result null;
            break :result Route{ .docs_rest = .{ .rest = rest } };
        }
        if (n == 2 and std.mem.eql(u8, segs[0], "item")) {
            const id = std.fmt.parseInt(u64, segs[1], 10) catch break :result null;
            break :result Route{ .item = .{ .id = id } };
        }
        if (n == 1 and std.mem.eql(u8, segs[0], "search")) {
            break :result Route{ .search = .{} };
        }
        if (n == 1 and std.mem.eql(u8, segs[0], "structure")) {
            break :result Route{ .structure = .{} };
        }
        if (n == 2 and std.mem.eql(u8, segs[0], "tag")) {
            const tag = segs[1];
            break :result Route{ .tag = .{ .tag = tag } };
        }
        if (n >= 1 and std.mem.eql(u8, segs[0], "wiki")) {
            var ca_off: usize = 1;
            for (segs[0..1]) |sg| ca_off += sg.len + 1;
            const rest = if (n > 1) path[ca_off..] else "";
            break :result Route{ .wiki_rest = .{ .rest = rest } };
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

/// Pure route pre-check for the server's validPath hook —
/// accepts api paths too when the app has pages/api/.
pub fn validPath(path: []const u8) bool {
    return parseRoute(path) != null or apiPath(path);
}

/// Type-safe href: `href(a, .{ .item = .{ .id = 3 } })` allocates
/// the path in `a` (the render arena in views). Static routes
/// return comptime literals.
pub fn href(a: std.mem.Allocator, r: Route) []const u8 {
    return switch (r) {
        .index => "/",
        .docs_rest => |p| std.fmt.allocPrint(a, "/docs/{s}", .{p.rest}) catch @panic("OOM"),
        .item => |p| std.fmt.allocPrint(a, "/item/{d}", .{p.id}) catch @panic("OOM"),
        .search => "/search",
        .structure => "/structure",
        .tag => |p| std.fmt.allocPrint(a, "/tag/{s}", .{p.tag}) catch @panic("OOM"),
        .wiki_rest => |p| if (p.rest.len == 0) "/wiki" else std.fmt.allocPrint(a, "/wiki/{s}", .{p.rest}) catch @panic("OOM"),
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
        .docs_rest => |p| try preparePage(docs_rest_page, s, p, env),
        .item => |p| try preparePage(item_page, s, p, env),
        .search => |p| try preparePage(search_page, s, p, env),
        .structure => |p| try preparePage(structure_page, s, p, env),
        .tag => |p| try preparePage(tag_page, s, p, env),
        .wiki_rest => |p| try preparePage(wiki_rest_page, s, p, env),
    }
}

/// View dispatch: Deps.view delegates here. Each page's
/// `view(a, s, params, env) forest.Node` becomes one node,
/// wrapped by every applicable `_layout.zig` (outermost
/// first — `pages/_layout.zig` wraps all pages).
pub fn viewNodes(a: std.mem.Allocator, s: anytype, env: *const zmeta.Env) []const forest.Node {
    const nodes = a.alloc(forest.Node, 1) catch @panic("OOM");
    nodes[0] = switch (s.deps.route) {
        .index => |p| lay_root.layout(a, s, env, index_page.view(a, s, p, env)),
        .docs_rest => |p| lay_root.layout(a, s, env, docs_rest_page.view(a, s, p, env)),
        .item => |p| lay_root.layout(a, s, env, item_page.view(a, s, p, env)),
        .search => |p| lay_root.layout(a, s, env, search_page.view(a, s, p, env)),
        .structure => |p| lay_root.layout(a, s, env, structure_page.view(a, s, p, env)),
        .tag => |p| lay_root.layout(a, s, env, tag_page.view(a, s, p, env)),
        .wiki_rest => |p| lay_root.layout(a, s, env, wiki_rest_page.view(a, s, p, env)),
    };
    return nodes;
}
/// Typed api route — one tag per `pages/api/` file.
/// Endpoint handlers return a JSON body; they never
/// produce forest nodes.
pub const ApiRoute = union(enum) {
    ping: ping_api.params,
};

/// Parse an api endpoint path ("/api/..." — "/api" and
/// "/api/" both mean the index endpoint). Same segment
/// rules and precedence as parseRoute.
pub fn parseApi(target: []const u8) ?ApiRoute {
    if (std.mem.eql(u8, target, "/api") or std.mem.eql(u8, target, "/api/")) {
        return null;
    }
    if (!std.mem.startsWith(u8, target, "/api/")) return null;
    const path = target[4..];
    var segs: [1][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |seg| {
        if (n < segs.len) segs[n] = seg;
        n += 1;
    }
    return result: {
        if (n == 1 and std.mem.eql(u8, segs[0], "ping")) {
            break :result ApiRoute{ .ping = .{} };
        }
        break :result null;
    };
}

/// Pure api-route pre-check — pairs with `validPath`.
pub fn apiPath(path: []const u8) bool {
    return parseApi(path) != null;
}

/// Endpoint dispatch: returns the handler's JSON body,
/// or null when `path` isn't an api route. `a` is the
/// caller's arena; `env` carries route+query.
pub fn api(a: std.mem.Allocator, s: anytype, path: []const u8, env: *const zmeta.Env) !?[]const u8 {
    const r = parseApi(path) orelse return null;
    const body = switch (r) {
        .ping => |p| try ping_api.api(a, s, p, env),
    };
    return body;
}
