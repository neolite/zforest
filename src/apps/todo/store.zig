//! Todo persistence store — SQLite write-through keyed by the `ztd`
//! client cookie, NOT the session: sessions are evicted (32-cap FIFO)
//! and the process restarts, but a browser's todos survive both.
//! Mirrors board/entities/model.zig conventions (schema exec + a prepared
//! statement per call) at demo scale — one row per todo, no debounce.
//!
//! `shared` is the installed store (main.zig sets it before serve(),
//! tests set it per case); `null` means persistence is disabled and
//! the app runs exactly like the old in-memory demo.
const std = @import("std");
const db = @import("zdb");

/// One persisted todo. `text` is owned — dupe it out of the column and
/// free it together with the row list returned by `load`.
pub const Row = struct {
    id: u64,
    ord: i64,
    text: []u8,
    done: bool,
};

const schema =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
    \\CREATE TABLE IF NOT EXISTS todos (
    \\    client_id TEXT NOT NULL,
    \\    id INTEGER NOT NULL,
    \\    ord INTEGER NOT NULL,
    \\    text TEXT NOT NULL,
    \\    done INTEGER NOT NULL DEFAULT 0,
    \\    PRIMARY KEY (client_id, id)
    \\);
    \\
;

/// The installed store, or null when persistence is off. All access is
/// serialized by the server's session mutex (same contract as
/// board/entities/model.zig's `shared`).
pub var shared: ?*TodoStore = null;

pub const TodoStore = struct {
    gpa: std.mem.Allocator,
    db: db.Db,

    /// Open (and create if needed) `path` — ":memory:" for ephemeral.
    pub fn init(gpa: std.mem.Allocator, path: []const u8) !*TodoStore {
        const st = try gpa.create(TodoStore);
        errdefer gpa.destroy(st);
        st.* = .{ .gpa = gpa, .db = undefined };
        st.db = try db.Db.open(gpa, path);
        errdefer st.db.close();
        try st.db.exec(gpa, schema);
        return st;
    }

    pub fn deinit(self: *TodoStore) void {
        self.db.close();
        self.gpa.destroy(self);
    }

    /// All todos for `client_id` in list order (`ord`, then `id` —
    /// equivalent today since ord mirrors id). Returned rows own their
    /// `text`: free each one plus the list itself.
    pub fn load(self: *TodoStore, alloc: std.mem.Allocator, client_id: []const u8) !std.ArrayListUnmanaged(Row) {
        var out: std.ArrayListUnmanaged(Row) = .empty;
        errdefer {
            for (out.items) |r| alloc.free(r.text);
            out.deinit(alloc);
        }
        var st = try self.db.prepare(alloc, "SELECT id, ord, text, done FROM todos WHERE client_id = ? ORDER BY ord, id");
        defer st.finalize();
        try st.bindText(1, client_id);
        while (try st.step()) {
            const text = try alloc.dupe(u8, st.columnText(2));
            errdefer alloc.free(text);
            try out.append(alloc, .{
                .id = @intCast(st.columnInt(0)),
                .ord = st.columnInt(1),
                .text = text,
                .done = st.columnInt(3) != 0,
            });
        }
        return out;
    }

    /// INSERT a new todo. `ord` mirrors `id` — the model has no reorder
    /// operation, so id order IS list order; the column stays for
    /// schema forward-compat (drag&drop would finally use it).
    pub fn insert(self: *TodoStore, alloc: std.mem.Allocator, client_id: []const u8, id: u64, text: []const u8, done: bool) !void {
        var st = try self.db.prepare(alloc, "INSERT INTO todos (client_id, id, ord, text, done) VALUES (?, ?, ?, ?, ?)");
        defer st.finalize();
        try st.bindText(1, client_id);
        try st.bindInt(2, @as(i64, @intCast(id)));
        try st.bindInt(3, @as(i64, @intCast(id)));
        try st.bindText(4, text);
        try st.bindInt(5, if (done) @as(i64, 1) else 0);
        _ = try st.step();
    }

    /// Flip/persist the done flag.
    pub fn setDone(self: *TodoStore, alloc: std.mem.Allocator, client_id: []const u8, id: u64, done: bool) !void {
        var st = try self.db.prepare(alloc, "UPDATE todos SET done = ? WHERE client_id = ? AND id = ?");
        defer st.finalize();
        try st.bindInt(1, if (done) @as(i64, 1) else 0);
        try st.bindText(2, client_id);
        try st.bindInt(3, @as(i64, @intCast(id)));
        _ = try st.step();
    }

    /// Persist an edited title (edit_save with non-empty text).
    pub fn setText(self: *TodoStore, alloc: std.mem.Allocator, client_id: []const u8, id: u64, text: []const u8) !void {
        var st = try self.db.prepare(alloc, "UPDATE todos SET text = ? WHERE client_id = ? AND id = ?");
        defer st.finalize();
        try st.bindText(1, text);
        try st.bindText(2, client_id);
        try st.bindInt(3, @as(i64, @intCast(id)));
        _ = try st.step();
    }

    /// Delete the row (delete action, or edit_save emptied the title).
    pub fn remove(self: *TodoStore, alloc: std.mem.Allocator, client_id: []const u8, id: u64) !void {
        var st = try self.db.prepare(alloc, "DELETE FROM todos WHERE client_id = ? AND id = ?");
        defer st.finalize();
        try st.bindText(1, client_id);
        try st.bindInt(2, @as(i64, @intCast(id)));
        _ = try st.step();
    }
};

test "store: insert/load round-trip, per-client isolation, update/delete" {
    const alloc = std.testing.allocator;
    const st = try TodoStore.init(alloc, ":memory:");
    defer st.deinit();

    try st.insert(alloc, "client-a", 1, "first", false);
    try st.insert(alloc, "client-a", 2, "second", true);
    try st.insert(alloc, "client-b", 1, "other browser", false);

    {
        var rows = try st.load(alloc, "client-a");
        defer {
            for (rows.items) |r| alloc.free(r.text);
            rows.deinit(alloc);
        }
        try std.testing.expectEqual(@as(usize, 2), rows.items.len);
        try std.testing.expectEqual(@as(u64, 1), rows.items[0].id);
        try std.testing.expectEqualStrings("first", rows.items[0].text);
        try std.testing.expect(!rows.items[0].done);
        try std.testing.expectEqual(@as(u64, 2), rows.items[1].id);
        try std.testing.expect(rows.items[1].done);
    }
    {
        // Client isolation: same todo id under another client is distinct.
        var rows = try st.load(alloc, "client-b");
        defer {
            for (rows.items) |r| alloc.free(r.text);
            rows.deinit(alloc);
        }
        try std.testing.expectEqual(@as(usize, 1), rows.items.len);
        try std.testing.expectEqualStrings("other browser", rows.items[0].text);
    }
    {
        var rows = try st.load(alloc, "nobody");
        defer {
            for (rows.items) |r| alloc.free(r.text);
            rows.deinit(alloc);
        }
        try std.testing.expectEqual(@as(usize, 0), rows.items.len);
    }

    try st.setDone(alloc, "client-a", 1, true);
    try st.setText(alloc, "client-a", 2, "second (edited)");
    try st.remove(alloc, "client-a", 1);
    {
        var rows = try st.load(alloc, "client-a");
        defer {
            for (rows.items) |r| alloc.free(r.text);
            rows.deinit(alloc);
        }
        try std.testing.expectEqual(@as(usize, 1), rows.items.len);
        try std.testing.expectEqual(@as(u64, 2), rows.items[0].id);
        try std.testing.expectEqualStrings("second (edited)", rows.items[0].text);
        try std.testing.expect(rows.items[0].done);
    }
}
