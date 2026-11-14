//! "/b/:slug" — one board's post list + post form. `slug` is a string
//! param; `app.pageOf` resolves it to the board index at setRoute
//! (unknown slug → 404 before this page ever renders).
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../../zmeta.zig");
const app = @import("../../app.zig");
const boardview = @import("../../view.zig");

/// Route params — `[slug]` segment → `slug: []const u8`.
pub const params = struct { slug: []const u8 };

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    return boardview.page(a, app.viewEnv(s));
}
