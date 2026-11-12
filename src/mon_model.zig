//! zmon shared model: synthetic request stream + windowed stats.
//! The ticker thread mutates under `mutex`; sessions read snapshots
//! under the same lock. `global_seq` (atomic) is the cheap fan-out gate
//! every route-session polls in `syncPull`.

const std = @import("std");

pub const Snapshot = struct {
    /// requests in the current tick window, per second
    rps: f64,
    /// error percentage in the window (0..100)
    err_pct: f64,
    avg_lat_ms: f64,
    total: u64,
    errors: u64,
    uptime_s: u64,
};

/// Wall-clock seconds since the unix epoch — libc `time(3)` (zmon links
/// libc; the Io clock API would also work but this matches board.zig).
extern "c" fn time(t: ?*i64) i64;

const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk: i32, ts: *Timespec) i32;

fn nowSeconds() i64 {
    return time(null);
}

/// CLOCK_REALTIME is 0 on macOS and Linux.
fn nowMillis() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(0, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

const LogCap = 384;
const LineCap = 96;

pub const MonModel = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    total: u64 = 0,
    errors: u64 = 0,
    lat_ms_sum: f64 = 0,

    // per-tick window (rotated by tick())
    win_total: u64 = 0,
    win_errors: u64 = 0,
    win_lat_sum: f64 = 0,
    /// millis timestamp of the last window rotation — rps denominator.
    win_start_ms: i64 = 0,

    /// Model birth (millis) — log lines are `T+S.mmm` uptime-relative.
    start_ms: i64 = 0,

    events: [8][48]u8 = undefined,
    event_len: [8]u8 = @splat(0),
    event_head: usize = 0,
    event_count: usize = 0,

    /// Firehose log ring: full request lines, newest-first on read.
    log_lines: [LogCap][LineCap]u8 = undefined,
    log_len: [LogCap]u8 = @splat(0),
    log_head: usize = 0,
    log_count: usize = 0,

    start_s: i64 = 0,

    global_seq: std.atomic.Value(u64) = .init(0),

    pub fn init(io: std.Io, gpa: std.mem.Allocator) MonModel {
        const ms = nowMillis();
        return .{ .io = io, .gpa = gpa, .start_s = nowSeconds(), .start_ms = ms, .win_start_ms = ms };
    }

    fn bump(self: *MonModel) void {
        _ = self.global_seq.fetchAdd(1, .seq_cst);
    }

    pub const Req = struct {
        ok: bool,
        lat_ms: f64,
        method: []const u8,
        path: []const u8,
        status: u16,
    };

    const methods = [_][]const u8{ "GET", "GET", "GET", "POST", "PUT", "DELETE", "PATCH" };
    const paths = [_][]const u8{
        "/v1/metrics", "/api/orders", "/health",        "/v1/users",
        "/api/pay",    "/v1/search",  "/static/app.js", "/v1/events",
        "/api/auth",   "/v1/billing",
    };
    const ok_status = [_]u16{ 200, 200, 200, 201, 204, 301 };
    const err_status = [_]u16{ 400, 404, 429, 500, 502, 503 };

    /// Roll one synthetic request descriptor.
    fn rollReq(self: *MonModel, seed: u32) Req {
        _ = self;
        const ok = seed % 100 < 90;
        const method = methods[seed % methods.len];
        const path = paths[(seed / 7) % paths.len];
        const lat = if (ok)
            2.0 + @as(f64, @floatFromInt(seed % 90))
        else
            150.0 + @as(f64, @floatFromInt((seed / 13) % 1100));
        const status = if (ok)
            ok_status[(seed / 11) % ok_status.len]
        else
            err_status[(seed / 17) % err_status.len];
        return .{ .ok = ok, .lat_ms = lat, .method = method, .path = path, .status = status };
    }

    fn recordLocked(self: *MonModel, r: Req) void {
        self.total += 1;
        self.lat_ms_sum += r.lat_ms;
        self.win_total += 1;
        self.win_lat_sum += r.lat_ms;
        if (!r.ok) {
            self.errors += 1;
            self.win_errors += 1;
        }

        var rb: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&rb, "{s} #{d} {d}ms", .{
            if (r.ok) "ok " else "ERR",
            self.total,
            @as(u64, @intFromFloat(@round(r.lat_ms))),
        }) catch return;
        const idx = self.event_head;
        @memcpy(self.events[idx][0..line.len], line);
        self.event_len[idx] = @as(u8, @intCast(line.len));
        self.event_head = (self.event_head + 1) % self.events.len;
        if (self.event_count < self.events.len) self.event_count += 1;

        const up_ms = @max(@as(i64, 0), nowMillis() - self.start_ms);
        var lb: [LineCap]u8 = undefined;
        const lline = std.fmt.bufPrint(&lb, "T+{d}.{d:0>3} #{d} {s} {s} {d} {d}ms", .{
            up_ms / 1000,
            @as(u32, @intCast(up_ms % 1000)),
            self.total,
            r.method,
            r.path,
            r.status,
            @as(u64, @intFromFloat(@round(r.lat_ms))),
        }) catch return;
        const lidx = self.log_head;
        @memcpy(self.log_lines[lidx][0..lline.len], lline);
        self.log_len[lidx] = @as(u8, @intCast(lline.len));
        self.log_head = (self.log_head + 1) % LogCap;
        if (self.log_count < LogCap) self.log_count += 1;
    }

    /// Record one request from an action (outside the ticker).
    pub fn record(self: *MonModel, r: Req) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.recordLocked(r);
        self.bump();
    }

    /// Firehose: record `n` synthetic requests under one lock + one seq
    /// bump — sessions see a single flush carrying a big log patch.
    pub fn storm(self: *MonModel, n: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var seed_buf: [16]u8 = undefined;
        self.io.random(&seed_buf);
        var seed = std.mem.readInt(u32, seed_buf[0..4], .little);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            seed +%= 2654435761;
            self.recordLocked(self.rollReq(seed));
        }
        self.bump();
    }

    /// Ticker: rotate the window, synthesize a burst of fake requests.
    pub fn tick(self: *MonModel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now = nowMillis();
        self.win_total = 0;
        self.win_errors = 0;
        self.win_lat_sum = 0;
        self.win_start_ms = now;
        var rb: [16]u8 = undefined;
        self.io.random(&rb);
        const n = 15 + (std.mem.readInt(u32, rb[0..4], .little) % 25);
        var i: usize = 0;
        var seed = std.mem.readInt(u32, rb[4..8], .little);
        while (i < n) : (i += 1) {
            seed +%= 2654435761;
            self.recordLocked(self.rollReq(seed));
        }
        self.bump();
    }

    pub fn snapshot(self: *MonModel) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const wt = @as(f64, @floatFromInt(self.win_total));
        const elapsed_s = @max(0.001, @as(f64, @floatFromInt(nowMillis() - self.win_start_ms)) / 1000.0);
        return .{
            .rps = wt / elapsed_s,
            .err_pct = if (self.win_total == 0) 0 else @as(f64, @floatFromInt(self.win_errors)) * 100.0 / wt,
            .avg_lat_ms = if (self.win_total == 0) 0 else self.win_lat_sum / wt,
            .total = self.total,
            .errors = self.errors,
            .uptime_s = @intCast(@max(@as(i64, 0), nowSeconds() - self.start_s)),
        };
    }

    /// Newest-first event lines joined with '\n', written into `buf`.
    pub fn feed(self: *MonModel, buf: []u8) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.feedLocked(buf);
    }

    fn feedLocked(self: *MonModel, buf: []u8) []const u8 {
        var fbs = std.heap.FixedBufferAllocator.init(buf);
        const fa = fbs.allocator();
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < self.event_count) : (i += 1) {
            const idx = (self.event_head + self.events.len - 1 - i) % self.events.len;
            const len = self.event_len[idx];
            if (len == 0) continue;
            out.appendSlice(fa, self.events[idx][0..len]) catch break;
            out.append(fa, '\n') catch break;
        }
        return out.items;
    }

    /// Newest-first firehose lines joined with '\n', written into `buf`.
    pub fn logText(self: *MonModel, buf: []u8) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.logTextLocked(buf);
    }

    fn logTextLocked(self: *MonModel, buf: []u8) []const u8 {
        var fbs = std.heap.FixedBufferAllocator.init(buf);
        const fa = fbs.allocator();
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < self.log_count) : (i += 1) {
            const idx = (self.log_head + LogCap - 1 - i) % LogCap;
            const len = self.log_len[idx];
            if (len == 0) continue;
            out.appendSlice(fa, self.log_lines[idx][0..len]) catch break;
            out.append(fa, '\n') catch break;
        }
        return out.items;
    }
};

test "log ring keeps newest-first order and caps at LogCap" {
    var m = MonModel{ .io = undefined, .gpa = std.testing.allocator, .start_ms = 0 };
    var i: usize = 0;
    while (i < LogCap + 10) : (i += 1) {
        m.recordLocked(.{
            .ok = true,
            .lat_ms = 5,
            .method = "GET",
            .path = "/x",
            .status = 200,
        });
    }
    try std.testing.expectEqual(LogCap, m.log_count);
    var buf: [LogCap * (LineCap + 1)]u8 = undefined;
    const text = m.logTextLocked(&buf);
    // 394 recorded, ring keeps the newest 384 → #11..#394.
    try std.testing.expect(std.mem.indexOf(u8, text, "#394") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "#10 ") == null);
    // Lines are newline-joined.
    var lines: usize = 1;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }
    try std.testing.expectEqual(LogCap, lines -| 1);
}
