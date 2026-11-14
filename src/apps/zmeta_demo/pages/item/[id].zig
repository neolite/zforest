//! "/item/:id" — typed-param page: prepare 404s unknown ids, the view
//! shows the item + a like action carrying the id as `data-arg`.
const std = @import("std");
const zmeta = @import("../../zmeta.zig");
const h = zmeta.h;
const routes = @import("../../gen/routes.zig");
const actions = @import("../../gen/actions.zig");
const app = @import("../../app.zig");

/// Route params — `[id]` segment → `id: u64` (drives the parser).
pub const params = struct { id: u64 };

/// Dangling params → 404 before any view work (spec §2.5/§5.4).
pub fn prepare(s: anytype, p: params, env: *const zmeta.Env) !void {
    _ = s;
    _ = env;
    if (app.item(p.id) == null) return error.NotFound;
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) h.Node {
    _ = env;
    const it = app.item(p.id) orelse unreachable; // prepare already 404'd
    const likes = s.deps.likes.get(p.id) orelse 0;
    const likes_text = h.f(a, "likes: {d}", .{likes});
    const arg = h.f(a, "{d}", .{p.id});
    return h.fragment(a, .{
        h.h1(a).id("iname").child(it.name).node(),
        h.p(a).id("iblurb").child(it.blurb).node(),
        h.p(a).id("iid").child(h.f(a, "item #{d}", .{p.id})).node(),
        h.button(a).id("like-btn").on(.click, actions.act.like).arg(arg).child("like").node(),
        h.p(a).id("likes").text(likes_text).node(),
        h.p(a).child(h.a(a).href(routes.href(a, .{ .index = .{} })).child("← home")).node(),
    });
}
