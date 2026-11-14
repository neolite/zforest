//! "/" — home: board list + latest posts. The view itself is shared
//! (`view.zig`); this file owns the route contract — params + view.
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
