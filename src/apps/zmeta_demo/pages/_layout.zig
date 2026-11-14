//! Root `_layout.zig` — wraps EVERY page of this app: the generated
//! `viewNodes` calls `layout(a, s, env, page.view(...))` per route.
//! Convention: `pages/**/_layout.zig` applies to pages in its
//! directory and below; `pages/_layout.zig` is the root shell.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const h = zmeta.h;
const routes = @import("../gen/routes.zig");

pub fn layout(
    a: std.mem.Allocator,
    s: anytype,
    env: *const zmeta.Env,
    inner: forest.Node,
) forest.Node {
    _ = s;
    _ = env;
    return h.div(a)
        .class("demo-shell")
        .children(.{
            h.div(a)
                .class("demo-nav")
                .children(.{
                    h.a(a).href(routes.href(a, .{ .index = .{} })).child("home").node(),
                    " · ",
                    h.a(a).href(routes.href(a, .{ .structure = .{} })).child("structure").node(),
                    " · ",
                    h.a(a).href(routes.href(a, .{ .search = .{} })).child("search").node(),
                })
                .node(),
            inner,
        })
        .node();
}
