//! "/" — home: board list + latest posts.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const components = @import("../shared/components.zig");
const model = @import("../entities/model.zig");

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    const venv = s.deps.viewEnv();
    const mm = model.get();
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .h1, .{}, .{
        forest.text("z"),
        forest.el(a, .span, .{}, "board"),
    })) catch @panic("OOM");
    kids.append(a, forest.el(a, .p, .{ .class = "boards-label" }, "Доски:")) catch @panic("OOM");
    var bl: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (model.boards) |b| {
        bl.append(a, forest.el(a, .li, .{}, forest.el(a, .a, .{ .href = components.boardHref(a, b.slug) }, b.title))) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .ul, .{ .class = "board-list" }, bl.toOwnedSlice(a) catch @panic("OOM"))) catch @panic("OOM");
    kids.append(a, forest.el(a, .h2, .{}, "Последнее:")) catch @panic("OOM");

    const latest_idx = mm.latestPostIdx(a, model.latest_home_count) catch @panic("OOM");
    var lp: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (latest_idx) |pi| {
        lp.append(a, components.postCard(a, venv, &mm.posts.items[pi], true)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .div, .{ .id = "latest", .class = "posts" }, forest.each(lp.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    kids.append(a, forest.when(a, .{ .id = "w-latest-empty" }, latest_idx.len == 0, forest.el(a, .p, .{ .class = "empty" }, "Пока пусто — напиши первым пост."))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}
