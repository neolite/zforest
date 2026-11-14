//! "/api/ping" — api endpoint: JSON body, no view/layout. Handlers
//! get the same `(a, s, params, env)` shape as page views; `a` is a
//! per-request arena. `env.query` carries the raw query string.
const std = @import("std");
const zmeta = @import("../../zmeta.zig");

pub const params = struct {};

pub fn api(
    a: std.mem.Allocator,
    s: anytype,
    p: params,
    env: *const zmeta.Env,
) ![]const u8 {
    _ = s;
    _ = p;
    return std.fmt.allocPrint(
        a,
        "{{\"ok\":true,\"route\":\"{s}\",\"query\":\"{s}\"}}",
        .{ env.route, env.query },
    ) catch return error.OutOfMemory;
}
