//! "/" — demo home: generated hrefs to item pages + a ping action.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const routes = @import("../gen/routes.zig");
const actions = @import("../gen/actions.zig");
const app = @import("../app.zig");

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

/// One item link row for the keyed list.
fn itemRow(a: std.mem.Allocator, ctx: anytype, it: app.Item) ?forest.Node {
    _ = ctx;
    return forest.el(a, .li, .{
        .id = std.fmt.allocPrint(a, "item-{d}", .{it.id}) catch @panic("OOM"),
    }, .{
        forest.el(a, .a, .{
            .href = routes.href(a, .{ .item = .{ .id = it.id } }),
        }, it.name),
        forest.text(" — "),
        forest.text(it.blurb),
    });
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    const pings = std.fmt.allocPrint(a, "pings: {d}", .{s.deps.pings}) catch @panic("OOM");
    const likes = std.fmt.allocPrint(a, "likes: {d}", .{app.totalLikes(s.deps)}) catch @panic("OOM");
    return forest.fragment(a, .{
        forest.el(a, .h1, .{ .id = "title" }, "zmeta demo"),
        forest.el(a, .p, .{ .id = "blurb" }, "file-based routes · typed params · comptime actions"),
        forest.el(a, .button, .{
            .id = "ping-btn",
            .on = .{ .click = actions.act.ping },
        }, "ping"),
        forest.el(a, .p, .{ .id = "pings", .text = pings }, .{}),
        forest.el(a, .ul, .{ .id = "items" }, forest.eachOf(a, app.items, s, itemRow)),
        forest.el(a, .p, .{ .id = "likes", .text = likes }, .{}),
    });
}
