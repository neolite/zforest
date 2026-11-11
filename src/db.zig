//! Thin typed wrapper over the vendored sqlite3 amalgamation
//! (vendor/sqlite3, SQLite 3.54.1). Zig 0.17 has no `@cImport`, so the
//! small C API surface we use is declared here by hand. Only linked into
//! the `zboard` exe and its test target — the todo exe never touches C.
const std = @import("std");

// ── sqlite3 C API subset (from vendor/sqlite3/sqlite3.h) ────────────

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_OPEN_READWRITE: c_int = 0x2;
const SQLITE_OPEN_CREATE: c_int = 0x4;
const SQLITE_OPEN_FULLMUTEX: c_int = 0x10000;

/// sqlite3_destructor_type — SQLITE_TRANSIENT ((void*)-1) tells sqlite to
/// copy bound text itself. Non-optional like the C typedef.
const sqlite3_destructor_type = *align(1) const fn (?*anyopaque) callconv(.c) void;
const SQLITE_TRANSIENT: sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

extern "c" fn sqlite3_open_v2(
    filename: [*:0]const u8,
    ppDb: *?*sqlite3,
    flags: c_int,
    zVfs: ?[*:0]const u8,
) c_int;
extern "c" fn sqlite3_close(db: *sqlite3) c_int;
extern "c" fn sqlite3_exec(
    db: *sqlite3,
    sql: [*:0]const u8,
    callback: ?*const fn (?*anyopaque, c_int, ?[*]u8, ?[*]u8) callconv(.c) c_int,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;
extern "c" fn sqlite3_prepare_v2(
    db: *sqlite3,
    zSql: [*:0]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*[*:0]const u8,
) c_int;
extern "c" fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_bind_text(
    stmt: *sqlite3_stmt,
    i: c_int,
    text: ?[*]const u8,
    n: c_int,
    destructor: sqlite3_destructor_type,
) c_int;
extern "c" fn sqlite3_bind_int64(stmt: *sqlite3_stmt, i: c_int, v: i64) c_int;
extern "c" fn sqlite3_bind_null(stmt: *sqlite3_stmt, i: c_int) c_int;
extern "c" fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_column_text(stmt: *sqlite3_stmt, i: c_int) ?[*]const u8;
extern "c" fn sqlite3_column_bytes(stmt: *sqlite3_stmt, i: c_int) c_int;
extern "c" fn sqlite3_column_int64(stmt: *sqlite3_stmt, i: c_int) i64;
extern "c" fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
extern "c" fn sqlite3_db_handle(stmt: *sqlite3_stmt) *sqlite3;

pub const Error = error{
    Sqlite,
    OutOfMemory,
    Closed,
};

fn sqliteErr(dbh: *sqlite3, comptime what: []const u8) Error {
    const msg = std.mem.span(sqlite3_errmsg(dbh));
    std.debug.print("sqlite {s}: {s}\n", .{ what, msg });
    return error.Sqlite;
}

/// NUL-terminated copy for the sqlite C API.
fn dupeZ(alloc: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const z = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(z, s);
    return z;
}

/// Owned prepared-statement wrapper. `finalize` is idempotent; column
/// slices are borrowed and invalid after the next `step`/`finalize` —
/// dupe before storing.
pub const Stmt = struct {
    h: ?*sqlite3_stmt = null,

    pub fn finalize(self: *Stmt) void {
        if (self.h) |p| {
            _ = sqlite3_finalize(p);
            self.h = null;
        }
    }

    fn raw(self: *Stmt) Error!*sqlite3_stmt {
        return self.h orelse error.Closed;
    }

    /// `i` is 1-based (sqlite convention).
    pub fn bindText(self: *Stmt, i: c_int, s: []const u8) Error!void {
        const st = try self.raw();
        const rc = sqlite3_bind_text(st, i, s.ptr, @intCast(s.len), SQLITE_TRANSIENT);
        if (rc != SQLITE_OK) return sqliteErr(sqlite3_db_handle(st), "bind_text");
    }

    /// `i` is 1-based; `v == null` binds NULL.
    pub fn bindInt(self: *Stmt, i: c_int, v: ?i64) Error!void {
        const st = try self.raw();
        const rc = if (v) |x| sqlite3_bind_int64(st, i, x) else sqlite3_bind_null(st, i);
        if (rc != SQLITE_OK) return sqliteErr(sqlite3_db_handle(st), "bind_int");
    }

    /// Advance: true = row available (read columns), false = DONE.
    pub fn step(self: *Stmt) Error!bool {
        const st = try self.raw();
        const rc = sqlite3_step(st);
        if (rc == SQLITE_ROW) return true;
        if (rc == SQLITE_DONE) return false;
        return sqliteErr(sqlite3_db_handle(st), "step");
    }

    /// Borrowed column text — valid until next step/finalize; dupe it.
    pub fn columnText(self: *Stmt, i: c_int) []const u8 {
        const st = self.h orelse return "";
        const p = sqlite3_column_text(st, i) orelse return "";
        const n = sqlite3_column_bytes(st, i);
        return p[0..@intCast(n)];
    }

    pub fn columnInt(self: *Stmt, i: c_int) i64 {
        const st = self.h orelse return 0;
        return sqlite3_column_int64(st, i);
    }
};

/// Owned database handle. `exec` runs DDL/DML without results; `prepare`
/// yields a typed statement wrapper.
pub const Db = struct {
    h: ?*sqlite3 = null,

    /// Open (and create if needed) `path` — ":memory:" for ephemeral.
    pub fn open(alloc: std.mem.Allocator, path: []const u8) !Db {
        const zpath = try dupeZ(alloc, path);
        defer alloc.free(zpath);
        var h: ?*sqlite3 = null;
        const rc = sqlite3_open_v2(zpath, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, null);
        if (rc != SQLITE_OK) {
            const msg = if (h) |p| std.mem.span(sqlite3_errmsg(p)) else "open failed";
            std.debug.print("sqlite open({s}): {s}\n", .{ path, msg });
            if (h) |p| _ = sqlite3_close(p);
            return error.Sqlite;
        }
        return .{ .h = h };
    }

    pub fn close(self: *Db) void {
        if (self.h) |p| {
            _ = sqlite3_close(p);
            self.h = null;
        }
    }

    fn raw(self: *Db) Error!*sqlite3 {
        return self.h orelse error.Closed;
    }

    /// Execute `sql` (no result rows). `sql` need not be NUL-terminated —
    /// a bounded copy is made.
    pub fn exec(self: *Db, alloc: std.mem.Allocator, sql: []const u8) Error!void {
        const zsql = try dupeZ(alloc, sql);
        defer alloc.free(zsql);
        const dbh = try self.raw();
        const rc = sqlite3_exec(dbh, zsql, null, null, null);
        if (rc != SQLITE_OK) return sqliteErr(dbh, "exec");
    }

    /// Prepare `sql` for binding/stepping. The returned Stmt borrows the
    /// db handle — keep the Db alive until finalize.
    pub fn prepare(self: *Db, alloc: std.mem.Allocator, sql: []const u8) Error!Stmt {
        const zsql = try dupeZ(alloc, sql);
        defer alloc.free(zsql);
        const dbh = try self.raw();
        var st: ?*sqlite3_stmt = null;
        const rc = sqlite3_prepare_v2(dbh, zsql, -1, &st, null);
        if (rc != SQLITE_OK) return sqliteErr(dbh, "prepare");
        return .{ .h = st };
    }
};

test "db round-trip: exec/prepare/bind/step/column" {
    const alloc = std.testing.allocator;
    var d = try Db.open(alloc, ":memory:");
    defer d.close();

    try d.exec(alloc, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, n INTEGER)");

    var ins = try d.prepare(alloc, "INSERT INTO t (name, n) VALUES (?, ?)");
    defer ins.finalize();
    try ins.bindText(1, "alice");
    try ins.bindInt(2, 42);
    _ = try ins.step();

    var ins2 = try d.prepare(alloc, "INSERT INTO t (name, n) VALUES ('bob', NULL)");
    defer ins2.finalize();
    _ = try ins2.step();

    var q = try d.prepare(alloc, "SELECT id, name, n FROM t ORDER BY id");
    defer q.finalize();
    try std.testing.expect(try q.step());
    try std.testing.expectEqual(@as(i64, 1), q.columnInt(0));
    try std.testing.expectEqualStrings("alice", q.columnText(1));
    try std.testing.expectEqual(@as(i64, 42), q.columnInt(2));
    try std.testing.expect(try q.step());
    try std.testing.expectEqualStrings("bob", q.columnText(1));
    try std.testing.expect(!try q.step());
}
