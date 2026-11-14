const std = @import("std");
const server = @import("server/http.zig");
const mon_model = @import("apps/mon/mon_model.zig");
const mon_app = @import("apps/mon/app.zig");

/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or loopback
/// for anything unparsable (safe default for a demo server).
fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {
    const s = arg orelse return .loopback(0);
    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
}

/// Synthetic traffic generator: every 100 ms rotate the stats window and
/// record a burst of fake requests so every open dashboard moves. The
/// SSE workers poll `global_seq` every 50 ms, so ~10 refreshes/sec is
/// the per-session ceiling — the ticker runs at half that rate.
fn ticker(model: *mon_model.MonModel, io: std.Io) void {
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch return;
        model.tick();
    }
}

/// `zmon [port] [bind-ip]` — defaults 8082 / 127.0.0.1.
pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const port: u16 = if (argv.len < 2) 8082 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8082;
    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
    bind.port = port;

    mon_app.model = mon_model.MonModel.init(init.io, init.gpa);
    const t = try std.Thread.spawn(.{}, ticker, .{ &mon_app.model, init.io });
    t.detach();

    try server.serve(init.gpa, init.io, bind, mon_app.Session);
}

test {
    _ = @import("apps/mon/mon_model.zig");
    _ = @import("apps/mon/app.zig");
}
