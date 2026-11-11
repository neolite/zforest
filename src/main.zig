const std = @import("std");
const server = @import("server/http.zig");

pub fn main(init: std.process.Init) !void {
    const port: u16 = blk: {
        const argv = init.minimal.args.vector;
        if (argv.len < 2) break :blk 8080;
        break :blk std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8080;
    };

    try server.serve(init.gpa, init.io, port);
}

test {
    // Pull server/session modules into the test binary so their colocated
    // test blocks are discovered by `zig build test` (the modules are only
    // reachable through serve(), which alone does not pull test decls).
    _ = @import("server/http.zig");
    _ = @import("todo_app.zig");
}
