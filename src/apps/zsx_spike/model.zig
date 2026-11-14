//! Shared fixture for the zsx spike — domain types + helpers used by
//! ALL THREE view versions (zsx-generated, h.*, forest.el). This is
//! test scaffolding, NOT view code: it is excluded from the LOC
//! comparison in docs/zsx-spike.md.
//!
//! The view shape mirrors board_app.zig's commentNode/postForm: a
//! comment row with meta line, bound like-button `.text`, an inline
//! reply `when` anchor, and a nested keyed `<ul>` of child comments.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Watchable cell store — the duck-typed live-binding contract
/// (`get`/`watchCtx`/`unwatch`/`Value`), same shape as the fake in
/// view.zig's tests. `emit` plays zefx's notify phase.
pub fn Cell(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Value = T;
        pub const Sub = struct { index: u32 };
        const Entry = struct {
            ctx: *anyopaque,
            cb: ?*const fn (*anyopaque, T) void,
        };

        gpa: std.mem.Allocator,
        v: T,
        subs: std.ArrayListUnmanaged(Entry) = .empty,

        pub fn get(self: *const Self) T {
            return self.v;
        }

        pub fn watchCtx(self: *Self, ctx: anytype, comptime cb: *const fn (@TypeOf(ctx), T) void) Sub {
            const CtxT = @TypeOf(ctx);
            const S = struct {
                fn call(p: *anyopaque, val: T) void {
                    const c: CtxT = @ptrCast(@alignCast(p));
                    cb(c, val);
                }
            };
            const idx = self.subs.items.len;
            self.subs.append(self.gpa, .{ .ctx = @ptrCast(ctx), .cb = &S.call }) catch @panic("OOM");
            return .{ .index = @intCast(idx) };
        }

        pub fn unwatch(self: *Self, sub: Sub) void {
            if (sub.index >= self.subs.items.len) return;
            self.subs.items[sub.index].cb = null;
        }

        /// Test driver: set the value and fire every live watcher.
        pub fn emit(self: *Self, val: T) void {
            self.v = val;
            for (self.subs.items) |e| {
                if (e.cb) |cb| cb(e.ctx, val);
            }
        }

        pub fn watcherCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.subs.items) |e| {
                if (e.cb != null) n += 1;
            }
            return n;
        }
    };
}

/// One comment. `children` holds INDICES into `Env.pool` — the keyed
/// child list (`eachOf` items are `u32` pool indices).
pub const Comment = struct {
    id: u64,
    author: []const u8,
    text: []const u8,
    ts: i64 = 0,
    children: []const u32 = &.{},
};

/// Everything the three view versions need — the "model" side of the
/// comparison. `likes` is parallel to `pool`: `likes[i]` backs the
/// like-count `.text` binding of `pool[i]`'s row.
pub const Env = struct {
    pool: []Comment = &.{},
    /// Thread post id — permalinks/hrefs derive from it.
    post_id: u64 = 0,
    /// Pre-formatted post id for hidden form fields ("7").
    post_str: []const u8 = "",
    /// Board slug for the post form's hidden `board` field.
    slug: []const u8 = "general",
    /// Comment id currently being replied to (null = no inline form).
    reply_to: ?u64 = null,
    /// Draft text bound to the post form textarea's `value` attr.
    draft: ?*Cell(?[]const u8) = null,
    likes: []Cell(u32) = &.{},
    max_len: u16 = 2000,
    placeholder: []const u8 = "…",
    submit_label: []const u8 = "…",
    act_post: []const u8 = "post",
    act_comment: []const u8 = "comment",
    act_reply: []const u8 = "reply",
    act_like: []const u8 = "like",
    act_cancel: []const u8 = "cancel_reply",
};

/// "DD.MM HH:MM" — same formatting as board_app.fmtTs.
pub fn fmtTs(a: Allocator, ts: i64) []const u8 {
    const secs = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = secs.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = secs.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>2}.{d:0>2} {d:0>2}:{d:0>2}", .{
        md.day_index + 1, md.month.numeric(), ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch @panic("OOM");
}

pub fn u64str(a: Allocator, v: u64) []const u8 {
    var buf: [24]u8 = undefined;
    return a.dupe(u8, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable) catch @panic("OOM");
}

pub fn commentHref(a: Allocator, post_id: u64, cid: u64) []const u8 {
    return std.fmt.allocPrint(a, "/t/{d}/c/{d}", .{ post_id, cid }) catch @panic("OOM");
}

/// `computed` map fn: like count → "▲ N" label.
pub fn likeLabel(a: Allocator, n: u32) []const u8 {
    return std.fmt.allocPrint(a, "\u{25B2} {d}", .{n}) catch @panic("OOM");
}
