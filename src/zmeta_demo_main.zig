//! zmeta-demo executable entry point: `zmeta-demo [port] [bind-ip]`.
//! The app itself lives under `src/apps/zmeta_demo/` (pages/, app.zig,
//! actions.zig manifest, generated gen/) — this flat `*_main.zig`
//! matches the board/car/mon entry-point convention and keeps every
//! relative import inside `src/` (the module path boundary).
const std = @import("std");
const server = @import("server/http.zig");
const app = @import("apps/zmeta_demo/app.zig");

/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or loopback
/// for anything unparsable (safe default for a demo server).
fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {
    const s = arg orelse return .loopback(0);
    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
}

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const port: u16 = if (argv.len < 2) 8084 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8084;
    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
    bind.port = port;

    try server.serve(init.gpa, init.io, bind, app.Session);
}

test {
    // Pull app + generated modules into the test binary so their
    // colocated test blocks are discovered by `zig build test`.
    _ = @import("apps/zmeta_demo/app.zig");
    _ = @import("apps/zmeta_demo/gen/routes.zig");
    _ = @import("apps/zmeta_demo/gen/actions.zig");
}
