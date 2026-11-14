const std = @import("std");
const patch_mod = @import("patch.zig");
const PatchLog = patch_mod.PatchLog;

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
    /// Live leaf bindings subscribed to reactive stores (see view.bindTree).
    /// `node_id` is the owned resolved id used for prefix drops; `ctx` is
    /// an opaque binder record whose `destroy` unsubscribes and frees it.
    bindings: std.ArrayListUnmanaged(Binding) = .empty,

    /// One live binding registration. `kind`/`name` disambiguate leaves
    /// sharing an element id (its `.text` vs each bound attr vs a `when`
    /// anchor on the same id). `.island` marks a binder-owned subtree
    /// (view.island): its ctx is a view-side IslandCtx owning the stable
    /// subtree copy, not a Binder — presence alone is the diff-skip flag.
    pub const Binding = struct {
        pub const Kind = enum { text, attr, when_key, island };
        kind: Kind,
        /// Owned resolved node/anchor id — matched against removeTracked's
        /// `id`/`id/…` prefix rule.
        node_id: []u8,
        /// Owned attribute name for `.attr` bindings, "" otherwise.
        name: []u8 = "",
        ctx: *anyopaque,
        /// Unsubscribes the store watcher and frees `ctx` (and `node_id`/
        /// `name` stay owned by the Dom — freed by the drop helpers).
        destroy: *const fn (*anyopaque) void,
    };

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
        self.dropAllBindings();
        self.bindings.deinit(self.gpa);
    }

    /// Deep-copy all tracked state into a fresh Dom on the same
    /// allocator — render-group clone-on-fork relies on the clone
    /// tracking EXACTLY what the source tracked, so diffing the same
    /// view against either produces identical ops. Live `bindings`
    /// cannot be copied (each ctx owns store subscriptions or an
    /// island subtree copy), so a Dom that has them must never be
    /// cloned — board sessions never call bindTree/bindIslands,
    /// making the assert a real invariant, not a hope.
    pub fn cloneDeep(self: *const Dom) Dom {
        std.debug.assert(self.bindings.items.len == 0);
        var out = Dom.init(self.gpa);
        var ti = self.texts.iterator();
        while (ti.next()) |e| {
            const k = self.gpa.dupe(u8, e.key_ptr.*) catch @panic("OOM");
            const v = self.gpa.dupe(u8, e.value_ptr.*) catch @panic("OOM");
            out.texts.put(self.gpa, k, v) catch @panic("OOM");
        }
        var ai = self.attrs.iterator();
        while (ai.next()) |e| {
            const k = self.gpa.dupe(u8, e.key_ptr.*) catch @panic("OOM");
            const v: ?[]u8 = if (e.value_ptr.*) |s| self.gpa.dupe(u8, s) catch @panic("OOM") else null;
            out.attrs.put(self.gpa, k, v) catch @panic("OOM");
        }
        var oi = self.orders.iterator();
        while (oi.next()) |e| {
            const k = self.gpa.dupe(u8, e.key_ptr.*) catch @panic("OOM");
            var ids: std.ArrayListUnmanaged([]u8) = .empty;
            for (e.value_ptr.items) |id| {
                ids.append(self.gpa, self.gpa.dupe(u8, id) catch @panic("OOM")) catch @panic("OOM");
            }
            out.orders.put(self.gpa, k, ids) catch @panic("OOM");
        }
        var wi = self.when_states.iterator();
        while (wi.next()) |e| {
            const k = self.gpa.dupe(u8, e.key_ptr.*) catch @panic("OOM");
            const v: ?[]u8 = if (e.value_ptr.*) |s| self.gpa.dupe(u8, s) catch @panic("OOM") else null;
            out.when_states.put(self.gpa, k, v) catch @panic("OOM");
        }
        return out;
    }

    /// Whether a live binding for `(kind, node_id, name)` is already
    /// registered — bindTree uses this to stay idempotent.
    pub fn findBinding(self: *Dom, kind: Binding.Kind, node_id: []const u8, name: []const u8) bool {
        for (self.bindings.items) |b| {
            if (b.kind == kind and std.mem.eql(u8, b.node_id, node_id) and std.mem.eql(u8, b.name, name)) return true;
        }
        return false;
    }

    /// Register a live binding. `node_id`/`name` are copied; `ctx` ownership
    /// transfers to the Dom (destroyed on drop/deinit).
    pub fn addBinding(self: *Dom, kind: Binding.Kind, node_id: []const u8, name: []const u8, ctx: *anyopaque, destroy: *const fn (*anyopaque) void) void {
        self.bindings.append(self.gpa, .{
            .kind = kind,
            .node_id = self.gpa.dupe(u8, node_id) catch @panic("OOM"),
            .name = self.gpa.dupe(u8, name) catch @panic("OOM"),
            .ctx = ctx,
            .destroy = destroy,
        }) catch @panic("OOM");
    }

    fn dropBindingAt(self: *Dom, i: usize) void {
        const b = self.bindings.orderedRemove(i);
        b.destroy(b.ctx);
        self.gpa.free(b.node_id);
        self.gpa.free(b.name);
    }

    /// Unsubscribe + free every binding whose node id is `id` or under
    /// `id/…` — mirrors the texts/attrs/when_states prefix rule. `keep`
    /// exempts one binder ctx (a `when_key` binder dropping its own
    /// anchor's tracked state during a branch swap must survive).
    pub fn dropBindings(self: *Dom, id: []const u8, keep: ?*anyopaque) void {
        var prefix_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}/", .{id}) catch @panic("id too long");
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            const b = &self.bindings.items[i];
            const kept = keep != null and b.ctx == keep.?;
            if (!kept and (std.mem.eql(u8, b.node_id, id) or std.mem.startsWith(u8, b.node_id, prefix))) {
                self.dropBindingAt(i);
            } else {
                i += 1;
            }
        }
    }

    fn dropAllBindings(self: *Dom) void {
        while (self.bindings.items.len > 0) self.dropBindingAt(self.bindings.items.len - 1);
    }

    /// Emit a text patch only when the tracked value differs.
    pub fn setText(self: *Dom, log: *PatchLog, id: []const u8, value: []const u8) void {
        // Lookup first: the common case (unchanged binding) then costs a
        // single hash probe instead of dupe+free churn on every render.
        if (self.texts.getPtr(id)) |slot| {
            if (std.mem.eql(u8, slot.*, value)) return;
            self.gpa.free(slot.*);
            slot.* = self.gpa.dupe(u8, value) catch @panic("OOM");
            log.setText(id, value);
            return;
        }
        const new_key = self.gpa.dupe(u8, id) catch @panic("OOM");
        const gop = self.texts.getOrPut(self.gpa, new_key) catch @panic("OOM");
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = self.gpa.dupe(u8, value) catch @panic("OOM");
        log.setText(id, value);
    }

    /// Record an attribute value without emitting — for seeding tracked
    /// state that matches markup already shipped in a create patch.
    pub fn seedAttr(self: *Dom, id: []const u8, name: []const u8, value: ?[]const u8) void {
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ id, name }) catch @panic("attr key too long");
        if (self.attrs.getPtr(key)) |slot| {
            if (slot.*) |v| self.gpa.free(v);
            slot.* = if (value) |v| self.gpa.dupe(u8, v) catch @panic("OOM") else null;
            return;
        }
        const new_key = self.gpa.dupe(u8, key) catch @panic("OOM");
        const gop = self.attrs.getOrPut(self.gpa, new_key) catch @panic("OOM");
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = if (value) |v| self.gpa.dupe(u8, v) catch @panic("OOM") else null;
    }

    /// Record a text binding without emitting — for seeding tracked state
    /// that matches markup already shipped in a create patch or SSR page.
    pub fn seedText(self: *Dom, id: []const u8, value: []const u8) void {
        if (self.texts.getPtr(id)) |slot| {
            self.gpa.free(slot.*);
            slot.* = self.gpa.dupe(u8, value) catch @panic("OOM");
            return;
        }
        const new_key = self.gpa.dupe(u8, id) catch @panic("OOM");
        const gop = self.texts.getOrPut(self.gpa, new_key) catch @panic("OOM");
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = self.gpa.dupe(u8, value) catch @panic("OOM");
    }

    /// Record the child order for `parent_id` without emitting — used when
    /// a keyed list's markup was already shipped inside a create patch.
    pub fn seedOrder(self: *Dom, parent_id: []const u8, ids: []const []const u8) void {
        const list: *std.ArrayListUnmanaged([]u8) = blk: {
            if (self.orders.getPtr(parent_id)) |gop| {
                for (gop.items) |id| self.gpa.free(id);
                gop.clearRetainingCapacity();
                break :blk gop;
            }
            const new_key = self.gpa.dupe(u8, parent_id) catch @panic("OOM");
            const gop = self.orders.getOrPut(self.gpa, new_key) catch @panic("OOM");
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = .empty;
            break :blk gop.value_ptr;
        };
        for (ids) |id| {
            list.append(self.gpa, self.gpa.dupe(u8, id) catch @panic("OOM")) catch @panic("OOM");
        }
    }

    /// Emit an attribute patch only when the tracked value differs.
    /// `value == null` removes the attribute.
    pub fn setAttr(self: *Dom, log: *PatchLog, id: []const u8, name: []const u8, value: ?[]const u8) void {
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ id, name }) catch @panic("attr key too long");
        if (self.attrs.getPtr(key)) |slot| {
            const old = slot.*;
            const same = (old == null and value == null) or
                (old != null and value != null and std.mem.eql(u8, old.?, value.?));
            if (same) return;
            if (old) |v| self.gpa.free(v);
            slot.* = if (value) |v| self.gpa.dupe(u8, v) catch @panic("OOM") else null;
            log.setAttr(id, name, value);
            return;
        }
        const new_key = self.gpa.dupe(u8, key) catch @panic("OOM");
        const gop = self.attrs.getOrPut(self.gpa, new_key) catch @panic("OOM");
        std.debug.assert(!gop.found_existing);
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
        if (self.when_states.getPtr(id)) |slot| {
            const old = slot.*;
            const same = (old == null and key == null) or
                (old != null and key != null and std.mem.eql(u8, old.?, key.?));
            if (same) return false;
            if (old) |v| self.gpa.free(v);
            slot.* = if (key) |k| self.gpa.dupe(u8, k) catch @panic("OOM") else null;
            return true;
        }
        const new_key = self.gpa.dupe(u8, id) catch @panic("OOM");
        const gop = self.when_states.getOrPut(self.gpa, new_key) catch @panic("OOM");
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = if (key) |k| self.gpa.dupe(u8, k) catch @panic("OOM") else null;
        return true;
    }

    /// Record an anchor's branch key without comparing — for seeding state
    /// that matches markup already shipped (SSR, create patch, when-op html).
    pub fn seedWhen(self: *Dom, id: []const u8, key: ?[]const u8) void {
        if (self.when_states.getPtr(id)) |slot| {
            if (slot.*) |v| self.gpa.free(v);
            slot.* = if (key) |k| self.gpa.dupe(u8, k) catch @panic("OOM") else null;
            return;
        }
        const new_key = self.gpa.dupe(u8, id) catch @panic("OOM");
        const gop = self.when_states.getOrPut(self.gpa, new_key) catch @panic("OOM");
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = if (key) |k| self.gpa.dupe(u8, k) catch @panic("OOM") else null;
    }

    /// Drop tracked state for `id` and any child bindings ("<id>/...").
    /// `keep_binding` exempts one live binder from the drop (see
    /// dropBindings) — used by `when_key` emitters re-seeding their own
    /// anchor.
    pub fn removeTracked(self: *Dom, id: []const u8, keep_binding: ?*anyopaque) void {
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
        self.dropBindings(id, keep_binding);
    }

    /// Diff `ids` (desired order) against the last known order for
    /// `parent_id`; emit create/remove/move patches and binding updates.
    /// `htmlFor(ctx, i)` is invoked ONLY for rows that need a create patch
    /// — existing rows never pay for markup serialization. `a` is scratch
    /// space (the render arena) for the membership set. If `created` is
    /// non-null it is filled with the ids of rows created this pass
    /// (slices borrowed from `ids`, not owned).
    pub fn syncKeyedList(
        self: *Dom,
        log: *PatchLog,
        a: std.mem.Allocator,
        parent_id: []const u8,
        ids: []const []const u8,
        htmlFor: anytype,
        htmlCtx: anytype,
        created: ?*std.ArrayListUnmanaged([]const u8),
    ) void {
        const cur: *std.ArrayListUnmanaged([]u8) = blk: {
            if (self.orders.getPtr(parent_id)) |gop| break :blk gop;
            const new_key = self.gpa.dupe(u8, parent_id) catch @panic("OOM");
            const gop = self.orders.getOrPut(self.gpa, new_key) catch @panic("OOM");
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = .empty;
            break :blk gop.value_ptr;
        };

        // Desired-id set: the remove pass below is then O(N) lookups
        // instead of an O(N²) scan of `ids` per tracked child.
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        defer wanted.deinit(a);
        for (ids) |id| wanted.put(a, id, {}) catch @panic("OOM");

        // Remove nodes no longer present.
        var i: usize = 0;
        while (i < cur.items.len) {
            const id = cur.items[i];
            if (wanted.contains(id)) {
                i += 1;
                continue;
            }
            log.remove(id);
            self.removeTracked(id, null);
            self.gpa.free(id);
            _ = cur.orderedRemove(i);
        }

        // Single left-to-right pass: at each desired position, move the
        // matching existing node before the element it currently displaces,
        // or create it there. `cur` is kept in lockstep with the real DOM.
        i = 0;
        while (i < ids.len) : (i += 1) {
            const want = ids[i];
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
                // position (or append at the end). htmlFor runs lazily —
                // only real creates serialize markup.
                const before: ?[]const u8 = if (i < cur.items.len) cur.items[i] else null;
                log.create(parent_id, before, want, htmlFor(htmlCtx, i));
                cur.insert(self.gpa, i, self.gpa.dupe(u8, want) catch @panic("OOM")) catch @panic("OOM");
                if (created) |c| c.append(self.gpa, want) catch @panic("OOM");
            }
        }
    }
};

const TestRow = struct { id: []const u8, html: []const u8 };

fn testHtml(rows: []const TestRow, i: usize) []const u8 {
    return rows[i].html;
}

/// Test shim keeping the old `{id, html}` row literal ergonomics over the
/// lazy `ids` + `htmlFor` syncKeyedList signature.
fn syncRows(
    dom: *Dom,
    log: *PatchLog,
    a: std.mem.Allocator,
    parent_id: []const u8,
    rows: []const TestRow,
    created: ?*std.ArrayListUnmanaged([]const u8),
) void {
    const ids = a.alloc([]const u8, rows.len) catch @panic("OOM");
    defer a.free(ids);
    for (rows, 0..) |r, i| ids[i] = r.id;
    dom.syncKeyedList(log, a, parent_id, ids, testHtml, rows, created);
}

test "keyed list lifecycle emits exact patches" {
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    // Initial render: three creates.
    syncRows(&dom, &log, std.testing.allocator, "list", &.{
        .{ .id = "row-1", .html = "<li>one</li>" },
        .{ .id = "row-2", .html = "<li>two</li>" },
        .{ .id = "row-3", .html = "<li>three</li>" },
    }, null);
    try std.testing.expectEqual(@as(usize, 3), log.patches.items.len);
    try std.testing.expect(log.patches.items[0] == .create);
    log.clear();

    // Remove row-2 and add row-4 at the end: remove + create.
    syncRows(&dom, &log, std.testing.allocator, "list", &.{
        .{ .id = "row-1", .html = "<li>one</li>" },
        .{ .id = "row-3", .html = "<li>three</li>" },
        .{ .id = "row-4", .html = "<li>four</li>" },
    }, null);
    try std.testing.expectEqual(@as(usize, 2), log.patches.items.len);
    try std.testing.expectEqualStrings("row-2", log.patches.items[0].remove.id);
    try std.testing.expectEqualStrings("row-4", log.patches.items[1].create.id);
    log.clear();

    // Reorder row-4 before row-1: single move patch.
    syncRows(&dom, &log, std.testing.allocator, "list", &.{
        .{ .id = "row-4", .html = "<li>four</li>" },
        .{ .id = "row-1", .html = "<li>one</li>" },
        .{ .id = "row-3", .html = "<li>three</li>" },
    }, null);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try std.testing.expectEqualStrings("row-4", log.patches.items[0].move.id);
    try std.testing.expectEqualStrings("row-1", log.patches.items[0].move.before_id.?);
    log.clear();

    // Identical render emits nothing.
    syncRows(&dom, &log, std.testing.allocator, "list", &.{
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

    syncRows(&dom, &log, std.testing.allocator, "list", &.{
        .{ .id = "A", .html = "<li/>" },
        .{ .id = "B", .html = "<li/>" },
        .{ .id = "C", .html = "<li/>" },
    }, null);
    log.clear();

    // ABC -> CAB
    syncRows(&dom, &log, std.testing.allocator, "list", &.{
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
    syncRows(&dom, &log, std.testing.allocator, "list", &.{
        .{ .id = "C", .html = "<li/>" },
        .{ .id = "B", .html = "<li/>" },
        .{ .id = "A", .html = "<li/>" },
    }, null);
    const order2 = try replayOrder(alloc, &.{ "C", "A", "B" }, &log);
    defer alloc.free(order2);
    try expectOrder(order2, &.{ "C", "B", "A" });
    log.clear();

    // CBA -> DBC: remove A, insert D first, move B
    syncRows(&dom, &log, std.testing.allocator, "list", &.{
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

    syncRows(&dom, &log, std.testing.allocator, "list", &.{.{ .id = "row-1", .html = "<li/>" }}, null);
    dom.setText(&log, "row-1/title", "hello");
    log.clear();

    syncRows(&dom, &log, std.testing.allocator, "list", &.{}, null);
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
    dom.removeTracked("row-1", null);
    try std.testing.expect(dom.when_states.get("row-1/sw") == null);
    try std.testing.expect(dom.when_states.get("row-1/deep/nest") == null);
    try std.testing.expect(dom.when_states.get("w-top") != null);
    // Purged anchors report changed again on next diff.
    try std.testing.expect(dom.setWhen("row-1/sw", "on"));
}

test "cloneDeep copies all tracked state and stays independent" {
    const alloc = std.testing.allocator;
    var dom = Dom.init(alloc);
    defer dom.deinit();
    var log = PatchLog.init(alloc);
    defer log.deinit();

    dom.setText(&log, "n1", "hello");
    dom.setAttr(&log, "n1", "class", "x");
    dom.setAttr(&log, "n1", "hidden", null);
    dom.seedOrder("list", &.{ "i1", "i2" });
    dom.seedWhen("w1", "on");
    log.clear();

    var clone = dom.cloneDeep();
    defer clone.deinit();

    // Same tracked state → same-value writes are no-ops on BOTH.
    clone.setText(&log, "n1", "hello");
    clone.setAttr(&log, "n1", "class", "x");
    try std.testing.expectEqual(@as(usize, 0), log.patches.items.len);
    try std.testing.expect(!clone.setWhen("w1", "on"));

    // Divergence is independent: mutating the source doesn't leak into
    // the clone, and the clone still diffs against its own baseline.
    dom.setText(&log, "n1", "bye");
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    log.clear();
    clone.setText(&log, "n1", "yo");
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try std.testing.expectEqualStrings("yo", log.patches.items[0].text.text);

    // Orders and when_states cloned too.
    try std.testing.expectEqual(@as(usize, 1), clone.orders.count());
    try std.testing.expectEqual(@as(usize, 1), clone.when_states.count());
    try std.testing.expect(clone.setWhen("w1", "off"));
}
