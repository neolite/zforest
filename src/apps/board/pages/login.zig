//! "/login" — account sign-in (ADR-0001 phase 2). Static route, no
//! params, no prepare gate; the form posts the `login` action and the
//! view itself is shared (`view.zig` loginView via boardview.page).
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");
const boardview = @import("../view.zig");

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    return boardview.page(a, app.viewEnv(s));
}
