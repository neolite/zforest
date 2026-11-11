const std = @import("std");

pub const Entry = struct { rev: u64, data: []u8 };

/// Bounded per-session ring of serialized patch batches. Every subscriber
/// polls with its own cursor; entries are owned by the history until
/// evicted and are duplicated for each fetch, so subscribers can never
/// consume each other's data.
///
/// `latest_rev` tracks the newest published revision even when the batch
/// itself was evicted, so `fetch` can always distinguish "nothing new"
/// (empty) from "fell behind" (gap → snapshot).
pub const History = struct {
    pub const max_entries = 64;
    pub const max_bytes = 2 * 1024 * 1024;

    gpa: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    total_bytes: usize = 0,
    latest_rev: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) History {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.gpa.free(e.data);
        self.entries.deinit(self.gpa);
    }

    /// Takes ownership of `json` (a gpa-owned serialized batch).
    /// Older entries are discarded once the bounds are exceeded — including
    /// the new batch itself if it alone exceeds `max_bytes`.
    pub fn publish(self: *History, rev: u64, json: []u8) void {
        self.entries.append(self.gpa, .{ .rev = rev, .data = json }) catch @panic("OOM");
        self.total_bytes += json.len;
        while (self.entries.items.len > max_entries or self.total_bytes > max_bytes) {
            const oldest = self.entries.orderedRemove(0);
            self.total_bytes -= oldest.data.len;
            self.gpa.free(oldest.data);
        }
        self.latest_rev = @max(self.latest_rev, rev);
    }

    pub const Fetch = union(enum) {
        /// The cursor fell behind retained history — caller must snapshot.
        gap,
        /// Owned duplicates of every retained batch with rev > cursor.
        /// Empty when the cursor is already at `latest_rev`.
        batches: []Entry,
    };

    /// `cursor` = last revision the subscriber applied.
    /// Returns `.gap` whenever the cursor cannot be advanced contiguously
    /// to `latest_rev` from retained history — including cursor 0 after
    /// early batches were evicted — so no batch is ever silently lost.
    /// Each call returns freshly duplicated strings; free with `freeFetch`.
    pub fn fetch(self: *const History, cursor: u64, gpa: std.mem.Allocator) !Fetch {
        const items = self.entries.items;
        if (cursor >= self.latest_rev) return .{ .batches = &.{} };
        if (items.len == 0 or items[0].rev > cursor + 1) return .gap;
        var count: usize = 0;
        for (items) |e| {
            if (e.rev > cursor) count += 1;
        }
        const out = try gpa.alloc(Entry, count);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |e| gpa.free(e.data);
            gpa.free(out);
        }
        for (items) |e| {
            if (e.rev > cursor) {
                out[filled] = .{ .rev = e.rev, .data = try gpa.dupe(u8, e.data) };
                filled += 1;
            }
        }
        return .{ .batches = out };
    }

    pub fn firstRetainedRev(self: *const History) ?u64 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[0].rev;
    }

    pub fn freeFetch(gpa: std.mem.Allocator, f: Fetch) void {
        switch (f) {
            .gap => {},
            .batches => |bs| {
                for (bs) |e| gpa.free(e.data);
                if (bs.len > 0) gpa.free(bs);
            },
        }
    }
};

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "ring publishes rev1/rev2 and two cursors fetch independently" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    h.publish(1, try alloc.dupe(u8, "{\"rev\":1}"));
    h.publish(2, try alloc.dupe(u8, "{\"rev\":2}"));

    const f1 = try h.fetch(0, alloc);
    defer History.freeFetch(alloc, f1);
    try std.testing.expectEqual(@as(usize, 2), f1.batches.len);
    try std.testing.expectEqualStrings("{\"rev\":1}", f1.batches[0].data);
    try std.testing.expectEqualStrings("{\"rev\":2}", f1.batches[1].data);

    // Second subscriber with its own cursor gets an independent copy.
    const f2 = try h.fetch(1, alloc);
    defer History.freeFetch(alloc, f2);
    try std.testing.expectEqual(@as(usize, 1), f2.batches.len);
    try std.testing.expectEqualStrings("{\"rev\":2}", f2.batches[0].data);

    // Mutating one subscriber's copy cannot corrupt the other or history.
    f2.batches[0].data[0] = 'X';
    try std.testing.expectEqualStrings("{\"rev\":2}", f1.batches[1].data);
    const f3 = try h.fetch(1, alloc);
    defer History.freeFetch(alloc, f3);
    try std.testing.expectEqualStrings("{\"rev\":2}", f3.batches[0].data);
}

test "cursor at latest_rev returns empty, not gap" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    // Empty history, nothing published: cursor 0 == latest 0 -> empty.
    const f0 = try h.fetch(0, alloc);
    try std.testing.expect(f0 == .batches);
    try std.testing.expectEqual(@as(usize, 0), f0.batches.len);

    h.publish(1, try alloc.dupe(u8, "{}"));
    const f1 = try h.fetch(1, alloc);
    try std.testing.expect(f1 == .batches);
    try std.testing.expectEqual(@as(usize, 0), f1.batches.len);
}

test "cursor 0 sees gap after early batches evicted" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    var i: u64 = 1;
    while (i <= History.max_entries + 5) : (i += 1) {
        const j = try std.fmt.allocPrint(alloc, "{{\"rev\":{d}}}", .{i});
        h.publish(i, j);
    }
    try std.testing.expectEqual(@as(usize, History.max_entries), h.entries.items.len);
    try std.testing.expectEqual(@as(u64, 6), h.firstRetainedRev().?);

    // A subscriber that connects now takes the snapshot path; a stale
    // cursor 0 must get gap, not silently the last 64 batches.
    const stale = try h.fetch(0, alloc);
    defer History.freeFetch(alloc, stale);
    try std.testing.expect(stale == .gap);

    // Cursor 3 fell behind retained history (oldest is 6) -> gap.
    const stale3 = try h.fetch(3, alloc);
    defer History.freeFetch(alloc, stale3);
    try std.testing.expect(stale3 == .gap);

    // Cursor at the retained boundary still gets the whole backlog.
    const ok = try h.fetch(5, alloc);
    defer History.freeFetch(alloc, ok);
    try std.testing.expectEqual(@as(usize, History.max_entries), ok.batches.len);
}

test "single oversized batch empties retained history but yields gap" {
    const alloc = std.testing.allocator;
    var h = History.init(alloc);
    defer h.deinit();

    h.publish(1, try alloc.dupe(u8, "{\"rev\":1}"));
    const big = try alloc.alloc(u8, History.max_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'a');
    h.publish(2, try alloc.dupe(u8, big));

    // The >max_bytes batch evicted everything, including itself — but
    // latest_rev advanced, so an old cursor gets gap (snapshot), not
    // an empty result that would hide the lost batches forever.
    try std.testing.expectEqual(@as(usize, 0), h.entries.items.len);
    const f = try h.fetch(1, alloc);
    defer History.freeFetch(alloc, f);
    try std.testing.expect(f == .gap);

    // And the newest cursor still reports "nothing pending".
    const f2 = try h.fetch(2, alloc);
    defer History.freeFetch(alloc, f2);
    try std.testing.expect(f2 == .batches);
    try std.testing.expectEqual(@as(usize, 0), f2.batches.len);
}
