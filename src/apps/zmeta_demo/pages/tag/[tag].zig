//! "/tag/:tag" — string-param page: `[tag]` slices one path segment
//! verbatim (no integer parsing). The slice points into the
//! session-owned route path, so it stays valid for the session.
const std = @import("std");
const zmeta = @import("../../zmeta.zig");
const h = zmeta.h;
const routes = @import("../../gen/routes.zig");

/// Route params — `[tag]` segment → `tag: []const u8`.
pub const params = struct { tag: []const u8 };

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) h.Node {
    _ = s;
    _ = env;
    return h.fragment(a, .{
        h.h1(a).child("tag").node(),
        h.p(a).id("tag-name").child(p.tag).node(),
        h.p(a)
            .id("tag-href")
            .child(h.f(a, "self href: {s}", .{routes.href(a, .{ .tag = .{ .tag = p.tag } })}))
            .node(),
        h.p(a).child(h.a(a).href(routes.href(a, .{ .index = .{} })).child("← home")).node(),
    });
}
