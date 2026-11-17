const std = @import("std");
const server = @import("zserver");
const todo = @import("app.zig");
const todo_store = @import("store.zig");

/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or loopback
/// for anything unparsable (safe default for a demo server).
fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {
    const s = arg orelse return .loopback(0);
    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
}

/// `zforest [port] [bind-ip] [db-path]` — defaults 8080 / 127.0.0.1 /
/// "zforest-todos.db". The db path is a sqlite file holding todos keyed
/// by the `ztd` client cookie; ":memory:" is ephemeral (per-process).
pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const port: u16 = if (argv.len < 2) 8080 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8080;
    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
    bind.port = port;
    const db_path: []const u8 = if (argv.len < 4) "zforest-todos.db" else std.mem.span(argv[3]);

    const st = try todo_store.TodoStore.init(init.gpa, db_path);
    todo_store.shared = st;
    std.debug.print("zforest: todo persistence db={s}\n", .{db_path});

    try server.serve(init.gpa, init.io, bind, todo.Session);
}

test {
    // Pull app + persistence modules into the test binary so their
    // colocated test blocks are discovered by `zig build test`.
    // Framework modules (zefx/forest/zserver/zmeta) and the zdb sqlite
    // wrapper run under their own named-module test targets in
    // build.zig; zdb is only imported by the sqlite-linked exes.
    _ = @import("app.zig");
    _ = @import("store.zig");
    _ = @import("zdb");
}
