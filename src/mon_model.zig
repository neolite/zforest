//! zmon shared model: synthetic request stream + windowed stats.
//! The ticker thread mutates under `mutex`; sessions read snapshots
//! under the same lock. `global_seq` (atomic) is the cheap fan-out gate
//! every route-session polls in `syncPull`.

const std = @import("std");

pub const Snapshot = struct {
    /// requests in the last tick window, per second (tick = 500 ms)
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

fn nowSeconds() i64 {
    return time(null);
}

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

    events: [8][48]u8 = undefined,
    event_len: [8]u8 = @splat(0),
    event_head: usize = 0,
    event_count: usize = 0,

    start_s: i64 = 0,

    global_seq: std.atomic.Value(u64) = .init(0),

    pub fn init(io: std.Io, gpa: std.mem.Allocator) MonModel {
        return .{ .io = io, .gpa = gpa, .start_s = nowSeconds() };
    }

    fn bump(self: *MonModel) void {
        _ = self.global_seq.fetchAdd(1, .seq_cst);
    }

    fn recordLocked(self: *MonModel, ok: bool, lat_ms: f64) void {
        self.total += 1;
        self.lat_ms_sum += lat_ms;
        self.win_total += 1;
        self.win_lat_sum += lat_ms;
        if (!ok) {
            self.errors += 1;
            self.win_errors += 1;
        }
        var rb: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&rb, "{s} #{d} {d}ms", .{
            if (ok) "ok " else "ERR",
            self.total,
            @as(u64, @intFromFloat(@round(lat_ms))),
        }) catch return;
        const idx = self.event_head;
        @memcpy(self.events[idx][0..line.len], line);
        self.event_len[idx] = @as(u8, @intCast(line.len));
        self.event_head = (self.event_head + 1) % self.events.len;
        if (self.event_count < self.events.len) self.event_count += 1;
    }

    /// Record one request from an action (outside the ticker).
    pub fn record(self: *MonModel, ok: bool, lat_ms: f64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.recordLocked(ok, lat_ms);
        self.bump();
    }

    /// Ticker: rotate the window, synthesize a burst of fake requests.
    pub fn tick(self: *MonModel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.win_total = 0;
        self.win_errors = 0;
        self.win_lat_sum = 0;
        var rb: [16]u8 = undefined;
        self.io.random(&rb);
        const n = 4 + (std.mem.readInt(u32, rb[0..4], .little) % 12);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const roll = std.mem.readInt(u32, rb[4..8], .little) +% i *% 2654435761;
            const ok = roll % 100 < 92;
            const lat = if (ok)
                4.0 + @as(f64, @floatFromInt(roll % 40))
            else
                180.0 + @as(f64, @floatFromInt((roll / 7) % 700));
            self.recordLocked(ok, lat);
        }
        self.bump();
    }

    pub fn snapshot(self: *MonModel) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const wt = @as(f64, @floatFromInt(self.win_total));
        return .{
            .rps = if (self.win_total == 0) 0 else wt / 0.5,
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
};
