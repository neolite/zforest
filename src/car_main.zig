const std = @import("std");
const server = @import("server/http.zig");
const car_app = @import("apps/car/app.zig");

/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or loopback
/// for anything unparsable (safe default for a demo server).
fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {
    const s = arg orelse return .loopback(0);
    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
}

/// `zcar [port] [bind-ip]` — defaults 8083 / 127.0.0.1.
pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const port: u16 = if (argv.len < 2) 8083 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8083;
    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
    bind.port = port;

    try server.serve(init.gpa, init.io, bind, car_app.Session);
}

test {
    _ = @import("apps/car/car_data.zig");
    _ = @import("apps/car/app.zig");
}
