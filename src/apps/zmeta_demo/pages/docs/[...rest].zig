//! "/docs/*" — catch-all page: `[...rest]` (last segment only)
//! captures the raw remainder "a/b/c" as `rest: []const u8`.
//! Requires a non-empty tail — "/docs" and "/docs/" 404.
const std = @import("std");
const zmeta = @import("../../zmeta.zig");
const h = zmeta.h;
const routes = @import("../../gen/routes.zig");

/// Route params — `[...rest]` → `rest: []const u8` (raw remainder).
pub const params = struct { rest: []const u8 };

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) h.Node {
    _ = s;
    _ = env;
    return h.fragment(a, .{
        h.h1(a).child("docs").node(),
        h.p(a).id("rest").child(p.rest).node(),
        h.p(a)
            .id("rest-href")
            .child(h.f(a, "self href: {s}", .{routes.href(a, .{ .docs_rest = .{ .rest = p.rest } })}))
            .node(),
        h.p(a).child(h.a(a).href(routes.href(a, .{ .index = .{} })).child("← home")).node(),
    });
}
