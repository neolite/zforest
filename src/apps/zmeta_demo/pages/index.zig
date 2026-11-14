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
        .id(std.fmt.allocPrint(a, "item-{d}", .{it.id}) catch @panic("OOM"))
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
    const pings = std.fmt.allocPrint(a, "pings: {d}", .{s.deps.pings}) catch @panic("OOM");
    const likes = std.fmt.allocPrint(a, "likes: {d}", .{app.totalLikes(s.deps)}) catch @panic("OOM");
    return h.fragment(a, .{
        h.h1(a).id("title").child("zmeta demo").node(),
        h.p(a).id("blurb").child("file-based routes · typed params · comptime actions").node(),
        h.button(a).id("ping-btn").on(.click, actions.act.ping).child("ping").node(),
        h.p(a).id("pings").text(pings).node(),
        h.ul(a).id("items").child(h.eachOf(a, app.items, s, itemRow)).node(),
        h.p(a).id("likes").text(likes).node(),
    });
}
