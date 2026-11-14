//! "/t/:post" — thread page: post card, comment form, sortable
//! top-level comment tree. Dangling post ids 404 in `prepare`.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../../../zmeta.zig");
const app = @import("../../../app.zig");
const boardview = @import("../../../view.zig");
const model = @import("../../../model.zig");

/// Route params — `[post]` segment → `post: u64`.
pub const params = struct { post: u64 };

/// Well-formed but dangling ids get a real 404, not an empty page.
pub fn prepare(s: anytype, p: params, env: *const zmeta.Env) !void {
    _ = s;
    _ = env;
    if (model.get().post(p.post) == null) return error.NotFound;
}

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    return boardview.page(a, app.viewEnv(s));
}
