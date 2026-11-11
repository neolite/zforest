const std = @import("std");
const patch_mod = @import("patch.zig");
const PatchLog = patch_mod.PatchLog;

/// One row of a keyed list: `id` is the stable node id, `html` the trusted
/// server-generated markup used when the row is (re)created.
pub const Row = struct { id: []const u8, html: []const u8 };

/// Client-visible DOM state tracked server-side so `render` passes only emit
/// patches for actual changes. All keys/values are owned copies.
pub const Dom = struct {
    gpa: std.mem.Allocator,
    /// node id -> last text content
    texts: std.StringHashMapUnmanaged([]u8) = .empty,
    /// "id\x00name" -> last attribute value (null value = attribute absent)
    attrs: std.StringHashMapUnmanaged(?[]u8) = .empty,
    /// parent id -> last known child order
    orders: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]u8)) = .empty,
    /// `z-when` anchor id -> last mounted branch key (null value = empty branch)
    when_states: std.StringHashMapUnmanaged(?[]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Dom {
        return .{ .gpa = gpa };
    }

    /// Drop all tracked state (keys/values owned strings freed) and leave
    /// the Dom empty and usable — for SSR paths that ship a fresh page and
    /// then reseed, e.g. a navigating client on a multi-route app.
    pub fn reset(self: *Dom) void {
        const gpa = self.gpa;
        self.deinit();
        self.* = Dom.init(gpa);
    }

    pub fn deinit(self: *Dom) void {
        var ti = self.texts.iterator();
        while (ti.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.texts.deinit(self.gpa);
        var ai = self.attrs.iterator();
        while (ai.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |v| self.gpa.free(v);
        }
        self.attrs.deinit(self.gpa);
        var oi = self.orders.iterator();
        while (oi.next()) |e| {
            for (e.value_ptr.items) |id| self.gpa.free(id);
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.orders.deinit(self.gpa);
        var wi = self.when_states.iterator();
        while (wi.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |v| self.gpa.free(v);
        }
        self.when_states.deinit(self.gpa);
    }

    /// Emit a text patch only when the tracked value differs.
    pub fn setText(self: *Dom, log: *PatchLog, id: []const u8, value: []const u8) void {
        const new_key = self.gpa.dupe(u8, id) catch @panic("OOM");
        const gop = self.texts.getOrPut(self.gpa, new_key) catch @panic("OOM");
        if (gop.found_existing) {
            self.gpa.free(new_key);
            if (std.mem.eql(u8, gop.value_ptr.*, value)) return;
            self.gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = self.gpa.dupe(u8, value) catch @panic("OOM");
        log.setText(id, value);
    }

    /// Record an attribute value without emitting — for seeding tracked
    /// state that matches markup already shipped in a create patch.
    pub fn seedAttr(self: *Dom, id: []const u8, name: []const u8, value: ?[]const u8) void {
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ id, name }) catch @panic("attr key too long");
        const new_key = self.gpa.dupe(u8, key) catch @panic("OOM");
        const gop = self.attrs.getOrPut(self.gpa, new_key) catch @panic("OOM");
        if (gop.found_existing) {
            self.gpa.free(new_key);
            if (gop.value_ptr.*) |v| self.gpa.free(v);
        }
        gop.value_ptr.* = if (value) |v| self.gpa.dupe(u8, v) catch @panic("OOM") else null;
    }

    /// Record a text binding without emitting — for seeding tracked state
    /// that matches markup already shipped in a create patch or SSR page.
    pub fn seedText(self: *Dom, id: []const u8, value: []const u8) void {
        const new_key = self.gpa.dupe(u8, id) catch @panic("OOM");
        const gop = self.texts.getOrPut(self.gpa, new_key) catch @panic("OOM");
        if (gop.found_existing) {
            self.gpa.free(new_key);
            self.gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = self.gpa.dupe(u8, value) catch @panic("OOM");
    }

    /// Record the child order for `parent_id` without emitting — used when
    /// a keyed list's markup was already shipped inside a create patch.
    pub fn seedOrder(self: *Dom, parent_id: []const u8, ids: []const []const u8) void {
        const new_key = self.gpa.dupe(u8, parent_id) catch @panic("OOM");
        const gop = self.orders.getOrPut(self.gpa, new_key) catch @panic("OOM");
        if (gop.found_existing) {
            self.gpa.free(new_key);
            for (gop.value_ptr.items) |id| self.gpa.free(id);
            gop.value_ptr.clearRetainingCapacity();
        } else {
            gop.value_ptr.* = .empty;
        }
        for (ids) |id| {
            gop.value_ptr.append(self.gpa, self.gpa.dupe(u8, id) catch @panic("OOM")) catch @panic("OOM");
        }
    }

    /// Emit an attribute patch only when the tracked value differs.
    /// `value == null` removes the attribute.
    pub fn setAttr(self: *Dom, log: *PatchLog, id: []const u8, name: []const u8, value: ?[]const u8) void {
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ id, name }) catch @panic("attr key too long");
        const new_key = self.gpa.dupe(u8, key) catch @panic("OOM");
        const gop = self.attrs.getOrPut(self.gpa, new_key) catch @panic("OOM");
        if (gop.found_existing) {
            self.gpa.free(new_key);
            const old = gop.value_ptr.*;
            const same = (old == null and value == null) or
                (old != null and value != null and std.mem.eql(u8, old.?, value.?));
            if (same) return;
            if (old) |v| self.gpa.free(v);
        }
        gop.value_ptr.* = if (value) |v| self.gpa.dupe(u8, v) catch @panic("OOM") else null;
        log.setAttr(id, name, value);
    }

    /// Convenience for boolean attributes like `checked`.
    pub fn setChecked(self: *Dom, log: *PatchLog, id: []const u8, checked: bool) void {
        self.setAttr(log, id, "checked", if (checked) "" else null);
    }

    /// Compare `key` (the active branch of the `z-when` anchor `id`) against
    /// tracked state and store it; returns true when the branch changed —
    /// the caller then emits a `when` op carrying the new branch markup.
    /// `key == null` is the empty branch.
    pub fn setWhen(self: *Dom, id: []const u8, key: ?[]const u8) bool {
        const new_key = self.gpa.dupe(u8, id) catch @panic("OOM");
        const gop = self.when_states.getOrPut(self.gpa, new_key) catch @panic("OOM");
        if (gop.found_existing) {
            self.gpa.free(new_key);
            const old = gop.value_ptr.*;
            const same = (old == null and key == null) or
                (old != null and key != null and std.mem.eql(u8, old.?, key.?));
            if (same) return false;
            if (old) |v| self.gpa.free(v);
        }
        gop.value_ptr.* = if (key) |k| self.gpa.dupe(u8, k) catch @panic("OOM") else null;
        return true;
    }

    /// Record an anchor's branch key without comparing — for seeding state
    /// that matches markup already shipped (SSR, create patch, when-op html).
    pub fn seedWhen(self: *Dom, id: []const u8, key: ?[]const u8) void {
        const new_key = self.gpa.dupe(u8, id) catch @panic("OOM");
        const gop = self.when_states.getOrPut(self.gpa, new_key) catch @panic("OOM");
        if (gop.found_existing) {
            self.gpa.free(new_key);
            if (gop.value_ptr.*) |v| self.gpa.free(v);
        }
        gop.value_ptr.* = if (key) |k| self.gpa.dupe(u8, k) catch @panic("OOM") else null;
    }

    /// Drop tracked state for `id` and any child bindings ("<id>/...").
    pub fn removeTracked(self: *Dom, id: []const u8) void {
        var prefix_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}/", .{id}) catch @panic("id too long");

        var tdel: std.ArrayListUnmanaged([]const u8) = .empty;
        defer tdel.deinit(self.gpa);
        var ti = self.texts.iterator();
        while (ti.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, id) or std.mem.startsWith(u8, e.key_ptr.*, prefix)) {
                tdel.append(self.gpa, e.key_ptr.*) catch @panic("OOM");
            }
        }
        for (tdel.items) |k| {
            const kv = self.texts.fetchRemove(k).?;
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }

        var adel: std.ArrayListUnmanaged([]const u8) = .empty;
        defer adel.deinit(self.gpa);
        var ai = self.attrs.iterator();
        while (ai.next()) |e| {
            const id_part = std.mem.sliceTo(e.key_ptr.*, 0);
            if (std.mem.eql(u8, id_part, id) or std.mem.startsWith(u8, id_part, prefix)) {
                adel.append(self.gpa, e.key_ptr.*) catch @panic("OOM");
            }
        }
        for (adel.items) |k| {
            const kv = self.attrs.fetchRemove(k).?;
            self.gpa.free(kv.key);
            if (kv.value) |v| self.gpa.free(v);
        }

        var wdel: std.ArrayListUnmanaged([]const u8) = .empty;
        defer wdel.deinit(self.gpa);
        var wi = self.when_states.iterator();
        while (wi.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, id) or std.mem.startsWith(u8, e.key_ptr.*, prefix)) {
                wdel.append(self.gpa, e.key_ptr.*) catch @panic("OOM");
            }
        }
        for (wdel.items) |k| {
            const kv = self.when_states.fetchRemove(k).?;
            self.gpa.free(kv.key);
            if (kv.value) |v| self.gpa.free(v);
        }
    }

    /// Diff `rows` (desired order) against the last known order for
    /// `parent_id`; emit create/remove/move patches and binding updates.
    /// If `created` is non-null it is filled with the ids of rows created
    /// this pass (slices borrowed from `rows`, not owned).
    pub fn syncKeyedList(self: *Dom, log: *PatchLog, parent_id: []const u8, rows: []const Row, created: ?*std.ArrayListUnmanaged([]const u8)) void {
        const new_key = self.gpa.dupe(u8, parent_id) catch @panic("OOM");
        const gop = self.orders.getOrPut(self.gpa, new_key) catch @panic("OOM");
        if (gop.found_existing) {
            self.gpa.free(new_key);
        } else {
            gop.value_ptr.* = .empty;
        }
        const cur = gop.value_ptr;

        // Remove nodes no longer present.
        var i: usize = 0;
        outer: while (i < cur.items.len) {
            const id = cur.items[i];
            for (rows) |r| {
                if (std.mem.eql(u8, r.id, id)) {
                    i += 1;
                    continue :outer;
                }
            }
            log.remove(id);
            self.removeTracked(id);
            self.gpa.free(id);
            _ = cur.orderedRemove(i);
        }

        // Single left-to-right pass: at each desired position, move the
        // matching existing node before the element it currently displaces,
        // or create it there. `cur` is kept in lockstep with the real DOM.
        i = 0;
        while (i < rows.len) : (i += 1) {
            const want = rows[i].id;
            if (i < cur.items.len and std.mem.eql(u8, cur.items[i], want)) continue;

            var j = i;
            while (j < cur.items.len) : (j += 1) {
                if (std.mem.eql(u8, cur.items[j], want)) break;
            }
            if (j < cur.items.len) {
                // Existing node further right: move it before the node it
                // displaces (old cur[i]), not before the next desired row.
                const before = cur.items[i]; // j > i guaranteed here
                const moved = cur.orderedRemove(j);
                cur.insert(self.gpa, i, moved) catch @panic("OOM");
                log.move(parent_id, want, before);
            } else {
                // New node: insert before whatever currently occupies this
                // position (or append at the end).
                const before: ?[]const u8 = if (i < cur.items.len) cur.items[i] else null;
                log.create(parent_id, before, want, rows[i].html);
                cur.insert(self.gpa, i, self.gpa.dupe(u8, want) catch @panic("OOM")) catch @panic("OOM");
                if (created) |c| c.append(self.gpa, want) catch @panic("OOM");
            }
        }
    }
};

test "keyed list lifecycle emits exact patches" {
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    // Initial render: three creates.
    dom.syncKeyedList(&log, "list", &.{
        .{ .id = "row-1", .html = "<li>one</li>" },
        .{ .id = "row-2", .html = "<li>two</li>" },
        .{ .id = "row-3", .html = "<li>three</li>" },
    }, null);
    try std.testing.expectEqual(@as(usize, 3), log.patches.items.len);
    try std.testing.expect(log.patches.items[0] == .create);
    log.clear();

    // Remove row-2 and add row-4 at the end: remove + create.
    dom.syncKeyedList(&log, "list", &.{
        .{ .id = "row-1", .html = "<li>one</li>" },
        .{ .id = "row-3", .html = "<li>three</li>" },
        .{ .id = "row-4", .html = "<li>four</li>" },
    }, null);
    try std.testing.expectEqual(@as(usize, 2), log.patches.items.len);
    try std.testing.expectEqualStrings("row-2", log.patches.items[0].remove.id);
    try std.testing.expectEqualStrings("row-4", log.patches.items[1].create.id);
    log.clear();

    // Reorder row-4 before row-1: single move patch.
    dom.syncKeyedList(&log, "list", &.{
        .{ .id = "row-4", .html = "<li>four</li>" },
        .{ .id = "row-1", .html = "<li>one</li>" },
        .{ .id = "row-3", .html = "<li>three</li>" },
    }, null);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try std.testing.expectEqualStrings("row-4", log.patches.items[0].move.id);
    try std.testing.expectEqualStrings("row-1", log.patches.items[0].move.before_id.?);
    log.clear();

    // Identical render emits nothing.
    dom.syncKeyedList(&log, "list", &.{
        .{ .id = "row-4", .html = "<li>four</li>" },
        .{ .id = "row-1", .html = "<li>one</li>" },
        .{ .id = "row-3", .html = "<li>three</li>" },
    }, null);
    try std.testing.expectEqual(@as(usize, 0), log.patches.items.len);
}

fn replayOrder(
    alloc: std.mem.Allocator,
    initial: []const []const u8,
    log: *const PatchLog,
) ![]const []const u8 {
    // Simulate the client's DOM ops and return resulting child order.
    var dom_order: std.ArrayListUnmanaged([]const u8) = .empty;
    defer dom_order.deinit(alloc);
    for (initial) |id| try dom_order.append(alloc, id);
    for (log.patches.items) |p| {
        switch (p) {
            .create => |c| {
                const idx: usize = if (c.before_id) |b| blk: {
                    for (dom_order.items, 0..) |id, k| {
                        if (std.mem.eql(u8, id, b)) break :blk k;
                    }
                    break :blk dom_order.items.len;
                } else dom_order.items.len;
                try dom_order.insert(alloc, idx, c.id);
            },
            .remove => |r| {
                for (dom_order.items, 0..) |id, k| {
                    if (std.mem.eql(u8, id, r.id)) {
                        _ = dom_order.orderedRemove(k);
                        break;
                    }
                }
            },
            .move => |m| {
                var from: usize = 0;
                for (dom_order.items, 0..) |id, k| {
                    if (std.mem.eql(u8, id, m.id)) {
                        from = k;
                        break;
                    }
                }
                const id = dom_order.orderedRemove(from);
                const idx: usize = if (m.before_id) |b| blk: {
                    for (dom_order.items, 0..) |x, k| {
                        if (std.mem.eql(u8, x, b)) break :blk k;
                    }
                    break :blk dom_order.items.len;
                } else dom_order.items.len;
                try dom_order.insert(alloc, idx, id);
            },
            else => {},
        }
    }
    return alloc.dupe([]const u8, dom_order.items);
}

fn expectOrder(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try std.testing.expectEqualStrings(e, a);
}

test "keyed list reorder replays to exact DOM order" {
    const alloc = std.testing.allocator;
    var dom = Dom.init(alloc);
    defer dom.deinit();
    var log = PatchLog.init(alloc);
    defer log.deinit();

    dom.syncKeyedList(&log, "list", &.{
        .{ .id = "A", .html = "<li/>" },
        .{ .id = "B", .html = "<li/>" },
        .{ .id = "C", .html = "<li/>" },
    }, null);
    log.clear();

    // ABC -> CAB
    dom.syncKeyedList(&log, "list", &.{
        .{ .id = "C", .html = "<li/>" },
        .{ .id = "A", .html = "<li/>" },
        .{ .id = "B", .html = "<li/>" },
    }, null);
    const order1 = try replayOrder(alloc, &.{ "A", "B", "C" }, &log);
    defer alloc.free(order1);
    try expectOrder(order1, &.{ "C", "A", "B" });
    try std.testing.expectEqualStrings("A", log.patches.items[0].move.before_id.?);
    log.clear();

    // CAB -> CBA (swap tail)
    dom.syncKeyedList(&log, "list", &.{
        .{ .id = "C", .html = "<li/>" },
        .{ .id = "B", .html = "<li/>" },
        .{ .id = "A", .html = "<li/>" },
    }, null);
    const order2 = try replayOrder(alloc, &.{ "C", "A", "B" }, &log);
    defer alloc.free(order2);
    try expectOrder(order2, &.{ "C", "B", "A" });
    log.clear();

    // CBA -> DBC: remove A, insert D first, move B
    dom.syncKeyedList(&log, "list", &.{
        .{ .id = "D", .html = "<li/>" },
        .{ .id = "B", .html = "<li/>" },
        .{ .id = "C", .html = "<li/>" },
    }, null);
    const order3 = try replayOrder(alloc, &.{ "C", "B", "A" }, &log);
    defer alloc.free(order3);
    try expectOrder(order3, &.{ "D", "B", "C" });
    log.clear();
}

test "text and attr bindings diff against tracked state" {
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    dom.setText(&log, "count", "1 left");
    dom.setText(&log, "count", "1 left"); // no dup
    dom.setText(&log, "count", "2 left");
    try std.testing.expectEqual(@as(usize, 2), log.patches.items.len);
    try std.testing.expectEqualStrings("2 left", log.patches.items[1].text.text);
    log.clear();

    dom.setChecked(&log, "cb-1", true);
    dom.setChecked(&log, "cb-1", true); // no dup
    dom.setChecked(&log, "cb-1", false);
    try std.testing.expectEqual(@as(usize, 2), log.patches.items.len);
    try std.testing.expectEqualStrings("", log.patches.items[0].attr.value.?);
    try std.testing.expect(log.patches.items[1].attr.value == null);
}

test "removed rows drop tracked bindings" {
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    dom.syncKeyedList(&log, "list", &.{.{ .id = "row-1", .html = "<li/>" }}, null);
    dom.setText(&log, "row-1/title", "hello");
    log.clear();

    dom.syncKeyedList(&log, "list", &.{}, null);
    try std.testing.expectEqual(@as(usize, 0), dom.texts.count());
    try std.testing.expectEqual(@as(usize, 0), dom.attrs.count());
}

test "when anchors track branch keys and purge with their row" {
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();

    // First set records and reports a change; same key is a no-op.
    try std.testing.expect(dom.setWhen("w-x", "on"));
    try std.testing.expect(!dom.setWhen("w-x", "on"));
    // Branch swap and unmount are changes too; null compares equal to null.
    try std.testing.expect(dom.setWhen("w-x", "other"));
    try std.testing.expect(dom.setWhen("w-x", null));
    try std.testing.expect(!dom.setWhen("w-x", null));

    // seedWhen records without diffing.
    dom.seedWhen("row-1/sw", "on");
    dom.seedWhen("row-1/deep/nest", "on");
    dom.seedWhen("w-top", "on");
    try std.testing.expect(!dom.setWhen("row-1/sw", "on"));

    // Removing the row drops only prefix-matched anchor state.
    dom.removeTracked("row-1");
    try std.testing.expect(dom.when_states.get("row-1/sw") == null);
    try std.testing.expect(dom.when_states.get("row-1/deep/nest") == null);
    try std.testing.expect(dom.when_states.get("w-top") != null);
    // Purged anchors report changed again on next diff.
    try std.testing.expect(dom.setWhen("row-1/sw", "on"));
}
