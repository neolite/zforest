const std = @import("std");
const server = @import("server/http.zig");
const board = @import("board.zig");
const board_app = @import("board_app.zig");
const board_seed = @import("board_seed.zig");

/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or loopback
/// for anything unparsable (safe default for a demo server).
fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {
    const s = arg orelse return .loopback(0);
    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
}

/// `zboard seed <db-path>` — populate an empty db with the themed seed
/// content (androids on an anonymous board). Refuses when posts exist.
fn runSeed(init: std.process.Init, db_path: []const u8) !void {
    const m = try board.BoardModel.init(init.gpa, db_path);
    defer m.deinit();
    const r = board_seed.apply(m) catch |e| {
        std.debug.print("seed: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("seeded {d} posts + {d} comments into {s}\n", .{ r.posts, r.comments, db_path });
}

/// `zboard [port] [bind-ip] [db-path]` — defaults 8080 / 127.0.0.1 /
/// ":memory:". The db path is a sqlite file; ":memory:" is ephemeral.
pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "seed")) {
        const db_path: []const u8 = if (argv.len < 3) "board.db" else std.mem.span(argv[2]);
        return runSeed(init, db_path);
    }
    const port: u16 = if (argv.len < 2) 8080 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8080;
    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
    bind.port = port;
    const db_path: []const u8 = if (argv.len < 4) ":memory:" else std.mem.span(argv[3]);

    const m = try board.BoardModel.init(init.gpa, db_path);
    board_app.model = m;
    std.debug.print("zboard: {d} posts, {d} comments, {d} users (db={s})\n", .{
        m.posts.items.len, m.comments.items.len, m.users.count(), db_path,
    });

    try server.serve(init.gpa, init.io, bind, board_app.Session);
}

test {
    _ = @import("db.zig");
    _ = @import("board.zig");
    _ = @import("board_app.zig");
    _ = @import("board_seed.zig");
}
