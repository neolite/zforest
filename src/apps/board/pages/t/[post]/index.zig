//! "/t/:post" — thread page: post card, comment form, sortable
//! top-level comment tree. Dangling post ids 404 in `prepare`.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../../../zmeta.zig");
const components = @import("../../../shared/components.zig");
const model = @import("../../../entities/model.zig");

/// Route params — `[post]` segment → `post: u64`.
pub const params = struct { post: u64 };

/// Well-formed but dangling ids get a real 404, not an empty page.
pub fn prepare(s: anytype, p: params, env: *const zmeta.Env) !void {
    _ = s;
    _ = env;
    if (model.get().post(p.post) == null) return error.NotFound;
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = env;
    const venv = s.deps.viewEnv();
    const mm = model.get();
    const post = mm.post(p.post) orelse {
        return components.notFoundView(a, "Тред не найден.");
    };
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, components.crumbsView(a, post, &[_]u64{})) catch @panic("OOM");
    kids.append(a, components.postCard(a, venv, post, false)) catch @panic("OOM");
    kids.append(a, components.commentForm(a, venv, p.post, null)) catch @panic("OOM");

    const tops = mm.topCommentIdx(a, p.post) catch @panic("OOM");
    const ordered = components.sortTops(a, mm, tops, venv.sort);
    const post_str = components.u64str(a, p.post);
    var ck: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (ordered) |ci| {
        ck.append(a, components.commentNode(a, venv, &mm.comments.items[ci], post_str)) catch @panic("OOM");
    }
    kids.append(a, components.sortBar(a, venv.sort)) catch @panic("OOM");
    kids.append(a, forest.el(a, .ul, .{ .id = "comments", .class = "comments" }, forest.each(ck.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    kids.append(a, forest.when(a, .{ .id = "w-comments-empty" }, tops.len == 0, forest.el(a, .p, .{ .class = "empty" }, "Нет комментариев — будь первым."))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}
