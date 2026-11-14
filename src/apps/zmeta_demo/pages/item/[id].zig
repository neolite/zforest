//! "/item/:id" — typed-param page: prepare 404s unknown ids, the view
//! shows the item + a like action carrying the id as `data-arg`.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../../zmeta.zig");
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

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = env;
    const it = app.item(p.id) orelse unreachable; // prepare already 404'd
    const likes = s.deps.likes.get(p.id) orelse 0;
    const likes_text = std.fmt.allocPrint(a, "likes: {d}", .{likes}) catch @panic("OOM");
    const arg = std.fmt.allocPrint(a, "{d}", .{p.id}) catch @panic("OOM");
    return forest.fragment(a, .{
        forest.el(a, .h1, .{ .id = "iname" }, it.name),
        forest.el(a, .p, .{ .id = "iblurb" }, it.blurb),
        forest.el(a, .p, .{ .id = "iid" }, std.fmt.allocPrint(a, "item #{d}", .{p.id}) catch @panic("OOM")),
        forest.el(a, .button, .{
            .id = "like-btn",
            .on = .{ .click = actions.act.like },
            .arg = arg,
        }, "like"),
        forest.el(a, .p, .{ .id = "likes", .text = likes_text }, .{}),
        forest.el(a, .p, .{}, forest.el(a, .a, .{
            .href = routes.href(a, .{ .index = .{} }),
        }, "← home")),
    });
}
