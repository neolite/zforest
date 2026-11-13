//! Shared anonymous-board model: static board list, posts/comments/users
//! held in memory as struct-of-arrays, write-through to SQLite. All
//! mutation happens under the server's session mutex; `global_seq` is the
//! atomic fan-out counter sessions poll via `syncPull`.
const std = @import("std");
const db = @import("db.zig");

pub const max_text_len = 2000;
pub const latest_home_count = 10;

pub const Board = struct { slug: []const u8, title: []const u8 };

/// Static board whitelist — slugs are URL path segments.
pub const boards = [_]Board{
    .{ .slug = "b", .title = "/b/ — random" },
    .{ .slug = "emp", .title = "/emp/ — эмпатия и Мерсер" },
    .{ .slug = "sheep", .title = "/sheep/ — электроживотные" },
    .{ .slug = "nexus", .title = "/nexus/ — железо и прошивки" },
    .{ .slug = "meta", .title = "/meta/ — о борде" },
    .{ .slug = "tech", .title = "/tech/ — технологии" },
};

pub fn boardIndex(slug: []const u8) ?usize {
    for (boards, 0..) |b, i| {
        if (std.mem.eql(u8, b.slug, slug)) return i;
    }
    return null;
}

/// `user` fields hold the zfxu token; display names resolve via
/// `userName`/`ensureUser` ("Anon#<base36(rownum)>").
pub const Post = struct {
    id: u64,
    board: []u8,
    user: []u8,
    text: []u8,
    ts: i64,
};

pub const Comment = struct {
    id: u64,
    post: u64,
    parent: ?u64,
    user: []u8,
    text: []u8,
    ts: i64,
};

pub const ModelError = error{
    InvalidText,
    UnknownBoard,
    PostNotFound,
    CommentNotFound,
    ParentNotFound,
    Sqlite,
    OutOfMemory,
    Closed,
};

/// Wall-clock seconds since the unix epoch — libc `time(3)`, already
/// linked via the sqlite amalgamation (Zig 0.17 needs an `Io` for
/// `Clock.Timestamp`, which the model deliberately doesn't carry).
extern "c" fn time(t: ?*i64) i64;

fn nowSeconds() i64 {
    return time(null);
}

const schema =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
    \\CREATE TABLE IF NOT EXISTS users (
    \\    token TEXT PRIMARY KEY,
    \\    created INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS posts (
    \\    id INTEGER PRIMARY KEY,
    \\    board TEXT NOT NULL,
    \\    user TEXT NOT NULL,
    \\    text TEXT NOT NULL,
    \\    ts INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS comments (
    \\    id INTEGER PRIMARY KEY,
    \\    post INTEGER NOT NULL,
    \\    parent INTEGER,
    \\    user TEXT NOT NULL,
    \\    text TEXT NOT NULL,
    \\    ts INTEGER NOT NULL
    \\);
    \\
;

fn base36(alloc: std.mem.Allocator, n: u64) ![]u8 {
    if (n == 0) return alloc.dupe(u8, "0");
    var buf: [16]u8 = undefined;
    var i: usize = buf.len;
    var v = n;
    while (v > 0) {
        i -= 1;
        const d: u8 = @intCast(v % 36);
        buf[i] = if (d < 10) '0' + d else 'a' + d - 10;
        v /= 36;
    }
    return alloc.dupe(u8, buf[i..]);
}

/// The shared model. `init` opens the db, applies the schema, and loads
/// every row into memory; mutations are write-through INSERT + append.
pub const BoardModel = struct {
    gpa: std.mem.Allocator,
    db: db.Db,
    /// Insertion order (id ascending) — views reverse for newest-first.
    posts: std.ArrayListUnmanaged(Post) = .empty,
    comments: std.ArrayListUnmanaged(Comment) = .empty,
    /// zfxu token -> display name ("Anon#<base36(rownum)>").
    users: std.StringHashMapUnmanaged([]u8) = .empty,
    /// post id -> comment count, maintained on load/addComment so
    /// `commentCount` is O(1) instead of a full scan per post card.
    post_counts: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Shared id space across posts+comments: display "#N".
    next_id: u64 = 1,
    /// Bumped on every mutation; sessions poll it for cross-session fan-out.
    global_seq: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: std.mem.Allocator, db_path: []const u8) !*BoardModel {
        const m = try gpa.create(BoardModel);
        errdefer gpa.destroy(m);
        m.* = .{
            .gpa = gpa,
            .db = undefined,
        };
        m.db = try db.Db.open(gpa, db_path);
        errdefer m.db.close();
        try m.db.exec(gpa, schema);
        try m.load();
        return m;
    }

    pub fn deinit(self: *BoardModel) void {
        for (self.posts.items) |p| {
            self.gpa.free(p.board);
            self.gpa.free(p.user);
            self.gpa.free(p.text);
        }
        self.posts.deinit(self.gpa);
        for (self.comments.items) |c| {
            self.gpa.free(c.user);
            self.gpa.free(c.text);
        }
        self.comments.deinit(self.gpa);
        var it = self.users.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.users.deinit(self.gpa);
        self.post_counts.deinit(self.gpa);
        self.db.close();
        self.gpa.destroy(self);
    }

    fn bump(self: *BoardModel) void {
        _ = self.global_seq.fetchAdd(1, .seq_cst);
    }

    fn validText(text: []const u8) bool {
        return text.len >= 1 and text.len <= max_text_len;
    }

    fn anonName(self: *BoardModel, rownum: u64) ![]u8 {
        const n = try base36(self.gpa, rownum);
        defer self.gpa.free(n);
        return std.fmt.allocPrint(self.gpa, "Anon#{s}", .{n}) catch @panic("OOM");
    }

    /// Load all rows; names are assigned by user row order so they are
    /// stable across restarts (Anon#1, Anon#2, ...).
    fn load(self: *BoardModel) !void {
        {
            var st = try self.db.prepare(self.gpa, "SELECT token FROM users ORDER BY rowid");
            defer st.finalize();
            var rownum: u64 = 0;
            while (try st.step()) : (rownum += 1) {
                const token = try self.gpa.dupe(u8, st.columnText(0));
                errdefer self.gpa.free(token);
                const name = try self.anonName(rownum + 1);
                try self.users.put(self.gpa, token, name);
            }
        }
        {
            var st = try self.db.prepare(self.gpa, "SELECT id, board, user, text, ts FROM posts ORDER BY id");
            defer st.finalize();
            while (try st.step()) {
                const p = Post{
                    .id = @intCast(st.columnInt(0)),
                    .board = try self.gpa.dupe(u8, st.columnText(1)),
                    .user = try self.gpa.dupe(u8, st.columnText(2)),
                    .text = try self.gpa.dupe(u8, st.columnText(3)),
                    .ts = st.columnInt(4),
                };
                errdefer {
                    self.gpa.free(p.board);
                    self.gpa.free(p.user);
                    self.gpa.free(p.text);
                }
                try self.posts.append(self.gpa, p);
                self.next_id = @max(self.next_id, p.id + 1);
            }
        }
        {
            var st = try self.db.prepare(self.gpa, "SELECT id, post, parent, user, text, ts FROM comments ORDER BY id");
            defer st.finalize();
            while (try st.step()) {
                const parent_col = st.columnInt(2);
                const c = Comment{
                    .id = @intCast(st.columnInt(0)),
                    .post = @intCast(st.columnInt(1)),
                    .parent = if (parent_col == 0) null else @as(?u64, @intCast(parent_col)),
                    .user = try self.gpa.dupe(u8, st.columnText(3)),
                    .text = try self.gpa.dupe(u8, st.columnText(4)),
                    .ts = st.columnInt(5),
                };
                errdefer {
                    self.gpa.free(c.user);
                    self.gpa.free(c.text);
                }
                try self.comments.append(self.gpa, c);
                self.next_id = @max(self.next_id, c.id + 1);
                self.noteComment(c.post);
            }
        }
    }

    /// Display name for a token, or null when the user row doesn't exist.
    pub fn userName(self: *const BoardModel, token: []const u8) ?[]const u8 {
        return self.users.get(token);
    }

    /// Get-or-create the user row for `token`; returns the display name.
    /// New users get "Anon#<base36(rownum)>". An actual insert bumps
    /// `global_seq` like any other mutation — the resolved name is
    /// rendered output (#who chip, post/comment authors), so identity
    /// changes must fan out even when the triggering action fails. A
    /// no-op lookup must NOT bump: every POST would re-render all
    /// sessions for nothing. (Any future field-update path must bump
    /// too.)
    pub fn ensureUser(self: *BoardModel, token: []const u8) ModelError![]const u8 {
        if (self.users.get(token)) |name| return name;
        var st = self.db.prepare(self.gpa, "INSERT INTO users (token, created) VALUES (?, ?)") catch |e| return dbErr(e);
        defer st.finalize();
        st.bindText(1, token) catch |e| return dbErr(e);
        st.bindInt(2, nowSeconds()) catch |e| return dbErr(e);
        _ = st.step() catch |e| return dbErr(e);
        const name = self.anonName(@intCast(self.users.count() + 1)) catch @panic("OOM");
        const tkey = self.gpa.dupe(u8, token) catch @panic("OOM");
        self.users.put(self.gpa, tkey, name) catch @panic("OOM");
        self.bump();
        return name;
    }

    fn dbErr(e: db.Error) ModelError {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Sqlite,
        };
    }

    fn findPost(self: *const BoardModel, id: u64) ?usize {
        for (self.posts.items, 0..) |p, i| {
            if (p.id == id) return i;
        }
        return null;
    }

    fn findComment(self: *const BoardModel, id: u64) ?usize {
        for (self.comments.items, 0..) |c, i| {
            if (c.id == id) return i;
        }
        return null;
    }

    pub fn post(self: *const BoardModel, id: u64) ?*const Post {
        const i = self.findPost(id) orelse return null;
        return &self.posts.items[i];
    }

    pub fn comment(self: *const BoardModel, id: u64) ?*const Comment {
        const i = self.findComment(id) orelse return null;
        return &self.comments.items[i];
    }

    /// Newest-first post indices for a board — allocated in `a`.
    pub fn boardPostIdx(self: *const BoardModel, a: std.mem.Allocator, board: []const u8) ![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        for (self.posts.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.board, board)) try out.append(a, i);
        }
        // Reverse into newest-first.
        std.mem.reverse(usize, out.items);
        return out.toOwnedSlice(a);
    }

    /// Newest `n` posts across all boards — allocated in `a`.
    pub fn latestPostIdx(self: *const BoardModel, a: std.mem.Allocator, n: usize) ![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        var i = self.posts.items.len;
        while (i > 0 and out.items.len < n) {
            i -= 1;
            try out.append(a, i);
        }
        return out.toOwnedSlice(a);
    }

    /// Top-level comments of a post (parent == null), ascending id.
    pub fn topCommentIdx(self: *const BoardModel, a: std.mem.Allocator, post_id: u64) ![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        for (self.comments.items, 0..) |c, i| {
            if (c.post == post_id and c.parent == null) try out.append(a, i);
        }
        return out.toOwnedSlice(a);
    }

    /// Children of a comment (parent == id), ascending id — the recursive
    /// tree walk used by the view layer.
    pub fn childIdx(self: *const BoardModel, a: std.mem.Allocator, parent_id: u64) ![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        for (self.comments.items, 0..) |c, i| {
            if (c.parent != null and c.parent.? == parent_id) try out.append(a, i);
        }
        return out.toOwnedSlice(a);
    }

    fn noteComment(self: *BoardModel, post_id: u64) void {
        const gop = self.post_counts.getOrPut(self.gpa, post_id) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    pub fn commentCount(self: *const BoardModel, post_id: u64) usize {
        return self.post_counts.get(post_id) orelse 0;
    }

    /// Insert a post: validate, write-through INSERT, append, bump seq.
    pub fn addPost(self: *BoardModel, board_slug: []const u8, user_token: []const u8, text_in: []const u8) ModelError!Post {
        if (!validText(text_in)) return error.InvalidText;
        if (boardIndex(board_slug) == null) return error.UnknownBoard;
        const id = self.next_id;
        const ts = nowSeconds();
        var st = self.db.prepare(self.gpa, "INSERT INTO posts (id, board, user, text, ts) VALUES (?, ?, ?, ?, ?)") catch |e| return dbErr(e);
        defer st.finalize();
        st.bindInt(1, @intCast(id)) catch |e| return dbErr(e);
        st.bindText(2, board_slug) catch |e| return dbErr(e);
        st.bindText(3, user_token) catch |e| return dbErr(e);
        st.bindText(4, text_in) catch |e| return dbErr(e);
        st.bindInt(5, ts) catch |e| return dbErr(e);
        _ = st.step() catch |e| return dbErr(e);

        const p = Post{
            .id = id,
            .board = self.gpa.dupe(u8, board_slug) catch @panic("OOM"),
            .user = self.gpa.dupe(u8, user_token) catch @panic("OOM"),
            .text = self.gpa.dupe(u8, text_in) catch @panic("OOM"),
            .ts = ts,
        };
        self.posts.append(self.gpa, p) catch @panic("OOM");
        self.next_id += 1;
        self.bump();
        return p;
    }

    /// Insert a comment under `post_id`, optionally replying to `parent_id`
    /// (must be a comment of the same post). Write-through + append.
    pub fn addComment(self: *BoardModel, post_id: u64, parent_id: ?u64, user_token: []const u8, text_in: []const u8) ModelError!Comment {
        if (!validText(text_in)) return error.InvalidText;
        if (self.findPost(post_id) == null) return error.PostNotFound;
        if (parent_id) |pid| {
            const pi = self.findComment(pid) orelse return error.ParentNotFound;
            if (self.comments.items[pi].post != post_id) return error.ParentNotFound;
        }
        const id = self.next_id;
        const ts = nowSeconds();
        var st = self.db.prepare(self.gpa, "INSERT INTO comments (id, post, parent, user, text, ts) VALUES (?, ?, ?, ?, ?, ?)") catch |e| return dbErr(e);
        defer st.finalize();
        st.bindInt(1, @intCast(id)) catch |e| return dbErr(e);
        st.bindInt(2, @intCast(post_id)) catch |e| return dbErr(e);
        st.bindInt(3, if (parent_id) |p| @as(i64, @intCast(p)) else null) catch |e| return dbErr(e);
        st.bindText(4, user_token) catch |e| return dbErr(e);
        st.bindText(5, text_in) catch |e| return dbErr(e);
        st.bindInt(6, ts) catch |e| return dbErr(e);
        _ = st.step() catch |e| return dbErr(e);

        const c = Comment{
            .id = id,
            .post = post_id,
            .parent = parent_id,
            .user = self.gpa.dupe(u8, user_token) catch @panic("OOM"),
            .text = self.gpa.dupe(u8, text_in) catch @panic("OOM"),
            .ts = ts,
        };
        self.comments.append(self.gpa, c) catch @panic("OOM");
        self.next_id += 1;
        self.noteComment(post_id);
        self.bump();
        return c;
    }
};

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "board model: add/load, ordering, ids, validation" {
    const alloc = std.testing.allocator;
    var m = try BoardModel.init(alloc, ":memory:");
    defer m.deinit();

    const tok1 = "tok-alpha";
    const tok2 = "tok-beta";
    try std.testing.expectEqualStrings("Anon#1", try m.ensureUser(tok1));
    try std.testing.expectEqualStrings("Anon#2", try m.ensureUser(tok2));
    try std.testing.expectEqualStrings("Anon#1", try m.ensureUser(tok1));

    const p1 = try m.addPost("b", tok1, "first post");
    const p2 = try m.addPost("tech", tok2, "second post");
    try std.testing.expectEqual(@as(u64, 1), p1.id);
    try std.testing.expectEqual(@as(u64, 2), p2.id);
    try std.testing.expectEqual(@as(usize, 2), m.posts.items.len);

    const c1 = try m.addComment(p1.id, null, tok2, "first comment");
    const c2 = try m.addComment(p1.id, c1.id, tok1, "nested reply");
    const c3 = try m.addComment(p2.id, null, tok1, "on post 2");
    try std.testing.expectEqual(@as(u64, 3), c1.id);
    try std.testing.expectEqual(@as(?u64, c1.id), c2.parent);
    // Shared id space across posts+comments: 1,2 posts → 3,4,5 comments.
    try std.testing.expectEqual(@as(u64, 5), c3.id);

    // Query shapes: board posts newest-first, comments ascending, tree.
    const bidx = try m.boardPostIdx(alloc, "b");
    defer alloc.free(bidx);
    try std.testing.expectEqual(@as(usize, 1), bidx.len);
    try std.testing.expectEqual(p1.id, m.posts.items[bidx[0]].id);

    const tops = try m.topCommentIdx(alloc, p1.id);
    defer alloc.free(tops);
    try std.testing.expectEqual(@as(usize, 1), tops.len);
    try std.testing.expectEqual(c1.id, m.comments.items[tops[0]].id);

    const kids = try m.childIdx(alloc, c1.id);
    defer alloc.free(kids);
    try std.testing.expectEqual(@as(usize, 1), kids.len);
    try std.testing.expectEqual(c2.id, m.comments.items[kids[0]].id);

    try std.testing.expectEqual(@as(usize, 2), m.commentCount(p1.id));
    try std.testing.expectEqual(@as(usize, 1), m.commentCount(p2.id));
    try std.testing.expect(m.post(999) == null);
    try std.testing.expect(m.comment(999) == null);

    // Validation.
    try std.testing.expectError(error.InvalidText, m.addPost("b", tok1, ""));
    try std.testing.expectError(error.InvalidText, m.addComment(p1.id, null, tok1, ""));
    try std.testing.expectError(error.UnknownBoard, m.addPost("nope", tok1, "x"));
    try std.testing.expectError(error.PostNotFound, m.addComment(999, null, tok1, "x"));
    try std.testing.expectError(error.ParentNotFound, m.addComment(p2.id, c1.id, tok1, "wrong post"));

    const seq = m.global_seq.load(.seq_cst);
    try std.testing.expect(seq >= 5); // 2 posts + 3 comments
}

test "board model: ensureUser bumps global_seq only on real mutation" {
    const alloc = std.testing.allocator;
    var m = try BoardModel.init(alloc, ":memory:");
    defer m.deinit();

    const s0 = m.global_seq.load(.seq_cst);
    _ = try m.ensureUser("tok-a");
    try std.testing.expectEqual(s0 + 1, m.global_seq.load(.seq_cst));
    // Repeat lookups are no-ops — no fan-out for unchanged identity.
    _ = try m.ensureUser("tok-a");
    try std.testing.expectEqual(s0 + 1, m.global_seq.load(.seq_cst));
    _ = try m.ensureUser("tok-b");
    try std.testing.expectEqual(s0 + 2, m.global_seq.load(.seq_cst));
}

test "board model persists and reloads from a file db" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/zboard-test-rt.db";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, path ++ "-wal") catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path ++ "-wal") catch {};
    std.Io.Dir.deleteFileAbsolute(io, path ++ "-shm") catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path ++ "-shm") catch {};

    {
        var m = try BoardModel.init(alloc, path);
        _ = try m.ensureUser("tok-persist");
        _ = try m.addPost("tech", "tok-persist", "survives restart");
        m.deinit();
    }
    {
        var m = try BoardModel.init(alloc, path);
        defer m.deinit();
        try std.testing.expectEqual(@as(usize, 1), m.posts.items.len);
        try std.testing.expectEqualStrings("survives restart", m.posts.items[0].text);
        try std.testing.expectEqualStrings("Anon#1", m.userName("tok-persist").?);
        // next_id continues the shared sequence.
        const p = try m.addPost("b", "tok-persist", "second life");
        try std.testing.expect(p.id > 1);
    }
}
