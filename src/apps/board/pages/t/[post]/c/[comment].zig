//! "/t/:post/c/:comment" — comment permalink: breadcrumbs + the
//! focused comment's subtree. The comment id is authoritative (its
//! `post` derives the thread); `post` stays in params for the URL
//! shape. Dangling comments 404 in `prepare`.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../../../../zmeta.zig");
const components = @import("../../../../components.zig");
const model = @import("../../../../model.zig");

/// Route params — `[post]` + `[comment]` segments → two u64 fields.
pub const params = struct { post: u64, comment: u64 };

/// Well-formed but dangling ids get a real 404, not an empty page.
pub fn prepare(s: anytype, p: params, env: *const zmeta.Env) !void {
    _ = s;
    _ = env;
    _ = p.post; // comment id is authoritative; post derives from it
    if (model.get().comment(p.comment) == null) return error.NotFound;
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p.post; // comment id is authoritative; post derives from it
    _ = env;
    const venv = s.deps.viewEnv();
    const mm = model.get();
    const c = mm.comment(p.comment) orelse {
        return components.notFoundView(a, "Комментарий не найден.");
    };
    const post = mm.post(c.post) orelse {
        return components.notFoundView(a, "Тред не найден.");
    };
    // Ancestor chain root→…→c (excluding c itself — it renders as root).
    var chain_rev: std.ArrayListUnmanaged(u64) = .empty;
    var cur: ?u64 = c.parent;
    while (cur) |pid| {
        const pc = mm.comment(pid) orelse break;
        chain_rev.append(a, pid) catch @panic("OOM");
        cur = pc.parent;
    }
    std.mem.reverse(u64, chain_rev.items);
    // The focused comment closes the crumb trail as a plain label.
    chain_rev.append(a, p.comment) catch @panic("OOM");

    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, components.crumbsView(a, post, chain_rev.items)) catch @panic("OOM");
    kids.append(a, components.commentForm(a, venv, post.id, null)) catch @panic("OOM");
    // Arena-allocate the single-row slice — a `&.{…}` temporary would
    // dangle once the statement ends (the keyed list outlives it).
    const only = a.alloc(forest.Node, 1) catch @panic("OOM");
    only[0] = components.commentNode(a, venv, c, components.u64str(a, post.id));
    kids.append(a, forest.el(a, .ul, .{ .id = "comments", .class = "comments" }, forest.each(only))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}
