//! "/b/:slug" — one board's post list + post form. `slug` is a string
//! param; `app.pageOf` resolves it to the board index at setRoute
//! (unknown slug → 404 before this page ever renders).
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../../zmeta.zig");
const components = @import("../../shared/components.zig");
const model = @import("../../entities/model.zig");

/// Route params — `[slug]` segment → `slug: []const u8`.
pub const params = struct { slug: []const u8 };

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = env;
    const venv = s.deps.viewEnv();
    // setRoute/pageOf already rejected unknown slugs — unreachable here.
    const idx = model.boardIndex(p.slug) orelse unreachable;
    const b = model.boards[idx];
    const mm = model.get();
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .h1, .{}, b.title)) catch @panic("OOM");
    kids.append(a, components.postForm(a, venv, b.slug)) catch @panic("OOM");

    const pidx = mm.boardPostIdx(a, b.slug) catch @panic("OOM");
    var pk: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (pidx) |pi| {
        pk.append(a, components.postCard(a, venv, &mm.posts.items[pi], true)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .div, .{ .id = "posts", .class = "posts" }, forest.each(pk.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    kids.append(a, forest.when(a, .{ .id = "w-board-empty" }, pidx.len == 0, forest.el(a, .p, .{ .class = "empty", .id = "empty-posts" }, "Пока пусто — напиши первым пост."))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}
