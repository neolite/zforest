const std = @import("std");
const board = @import("board.zig");

// The zboard session/view layer lands in the app commit; for now this
// entry point proves the model + sqlite wiring end to end.
pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const db_path: []const u8 = if (argv.len < 2) ":memory:" else std.mem.span(argv[1]);
    const m = try board.BoardModel.init(init.gpa, db_path);
    defer m.deinit();
    std.debug.print("zboard model ready: {d} posts, {d} comments, {d} users (db={s})\n", .{
        m.posts.items.len, m.comments.items.len, m.users.count(), db_path,
    });
}

test {
    _ = @import("db.zig");
    _ = @import("board.zig");
}
