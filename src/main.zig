const std = @import("std");
const server = @import("server/http.zig");
const todo = @import("todo_app.zig");

/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or loopback
/// for anything unparsable (safe default for a demo server).
fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {
    const s = arg orelse return .loopback(0);
    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
}

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const port: u16 = if (argv.len < 2) 8080 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8080;
    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
    bind.port = port;

    try server.serve(init.gpa, init.io, bind, todo.Session);
}

test {
    // Pull server/session/model modules into the test binary so their
    // colocated test blocks are discovered by `zig build test` (the
    // modules are only reachable through serve(), which alone does not
    // pull test decls). db.zig/board.zig pull the sqlite amalgamation —
    // compiled into this test binary only, never the zforest exe.
    _ = @import("server/http.zig");
    _ = @import("todo_app.zig");
    _ = @import("db.zig");
    _ = @import("board.zig");
}
