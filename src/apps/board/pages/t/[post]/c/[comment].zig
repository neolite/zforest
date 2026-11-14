//! "/t/:post/c/:comment" — comment permalink: breadcrumbs + the
//! focused comment's subtree. The comment id is authoritative (its
//! `post` derives the thread); `post` stays in params for the URL
//! shape. Dangling comments 404 in `prepare`.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../../../../zmeta.zig");
const app = @import("../../../../app.zig");
const boardview = @import("../../../../view.zig");
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
    _ = p;
    _ = env;
    return boardview.page(a, app.viewEnv(s));
}
