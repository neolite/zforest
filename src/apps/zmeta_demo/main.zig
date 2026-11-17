//! zmeta-demo executable entry point: `zmeta-demo [port] [bind-ip]`.
//! The app itself lives alongside this file under `src/apps/zmeta_demo/`
//! (pages/, app.zig, actions.zig manifest, generated gen/) — the exe
//! entry point lives INSIDE the app dir like every other app; only
//! framework code stays at the `src/` root.
const std = @import("std");
const server = @import("zserver");
const app = @import("app.zig");

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
    _ = @import("app.zig");
    _ = @import("gen/routes.zig");
    _ = @import("gen/actions.zig");
}
