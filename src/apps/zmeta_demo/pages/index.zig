//! "/" — demo home: generated hrefs to item pages + a ping action.
const std = @import("std");
const zmeta = @import("../zmeta.zig");
const h = zmeta.h;
const routes = @import("../gen/routes.zig");
const actions = @import("../gen/actions.zig");
const app = @import("../app.zig");

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

/// One item link row for the keyed list.
fn itemRow(a: std.mem.Allocator, ctx: anytype, it: app.Item) ?h.Node {
    _ = ctx;
    return h.li(a)
        .id(h.f(a, "item-{d}", .{it.id}))
        .children(.{
            h.a(a).href(routes.href(a, .{ .item = .{ .id = it.id } })).child(it.name),
            " — ",
            it.blurb,
        })
        .node();
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) h.Node {
    _ = p;
    _ = env;
    const pings = h.f(a, "pings: {d}", .{s.deps.pings});
    const likes = h.f(a, "likes: {d}", .{app.totalLikes(s.deps)});
    return h.fragment(a, .{
        h.h1(a).id("title").child("zmeta demo").node(),
        h.p(a).id("blurb").child("file-based routes · typed params · comptime actions").node(),
        h.button(a).id("ping-btn").on(.click, actions.act.ping).child("ping").node(),
        h.p(a).id("pings").text(pings).node(),
        // Per-leaf island: this subtree is binder-owned after the first
        // bindIslands pass — store notifications push the ticks op with
        // no view rebuild, while the rest of the page keeps diffing.
        h.island(a, .{ .id = "tick-island" }, .{
            h.button(a).id("tick-btn").on(.click, actions.act.tick).child("tick").node(),
            h.p(a).id("ticks").text(s.deps.ticks).node(),
        }),
        h.ul(a).id("items").child(h.eachOf(a, app.items, s, itemRow)).node(),
        h.p(a).id("likes").text(likes).node(),
    });
}
