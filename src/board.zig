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

/// Like target kind — persisted as 'p'/'c' in the likes table. Ids are
/// unique across posts+comments (shared `next_id`), so `like_counts`
/// keys on the raw id while `liked_by` keys carry the kind prefix.
pub const LikeKind = enum { post, comment };

fn likeKindChar(k: LikeKind) u8 {
    return switch (k) {
        .post => 'p',
        .comment => 'c',
    };
}

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
    \\CREATE TABLE IF NOT EXISTS likes (
    \\    kind TEXT NOT NULL,
    \\    target INTEGER NOT NULL,
    \\    user TEXT NOT NULL,
    \\    ts INTEGER NOT NULL,
    \\    PRIMARY KEY (kind, target, user)
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
    /// Maintained indexes (load + addPost/addComment — there is no
    /// delete path) so view lookups are O(matches), not O(all rows):
    /// `post_by_id`/`comment_by_id` map ids to `items` indices;
    /// `posts_by_board` maps a board slug to ascending post indices
    /// (keys borrow `Post.board` slices — deinit order matters);
    /// `tops_by_post`/`children_by_parent` map a post id / parent
    /// comment id to ascending comment indices. All lists keep
    /// `items` insertion order, identical to the old full scans.
    post_by_id: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    comment_by_id: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    posts_by_board: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty,
    tops_by_post: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(usize)) = .empty,
    children_by_parent: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(usize)) = .empty,
    /// Like state: `like_counts` maps a post/comment id (shared id
    /// space) to its like total; `liked_by` holds one owned
    /// `"<kind><id>:<token>"` key per (target, user) pair for the
    /// one-like-per-account toggle check. Both rebuilt on load.
    like_counts: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    liked_by: std.StringHashMapUnmanaged(void) = .empty,
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
        // Index teardown first: `posts_by_board` keys borrow
        // `Post.board` slices, so the maps must go before the post
        // strings they point into are freed.
        var pbit = self.posts_by_board.iterator();
        while (pbit.next()) |e| e.value_ptr.deinit(self.gpa);
        self.posts_by_board.deinit(self.gpa);
        var tbit = self.tops_by_post.iterator();
        while (tbit.next()) |e| e.value_ptr.deinit(self.gpa);
        self.tops_by_post.deinit(self.gpa);
        var cbit = self.children_by_parent.iterator();
        while (cbit.next()) |e| e.value_ptr.deinit(self.gpa);
        self.children_by_parent.deinit(self.gpa);
        self.post_by_id.deinit(self.gpa);
        self.comment_by_id.deinit(self.gpa);
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
        var lit = self.liked_by.iterator();
        while (lit.next()) |e| self.gpa.free(e.key_ptr.*);
        self.liked_by.deinit(self.gpa);
        self.like_counts.deinit(self.gpa);
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
                self.indexPost(self.posts.items.len - 1);
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
                self.indexComment(self.comments.items.len - 1);
                self.next_id = @max(self.next_id, c.id + 1);
            }
        }
        {
            var st = try self.db.prepare(self.gpa, "SELECT kind, target, user FROM likes");
            defer st.finalize();
            while (try st.step()) {
                const kind_ch = st.columnText(0)[0];
                const target: u64 = @intCast(st.columnInt(1));
                const token = st.columnText(2);
                const gop = self.like_counts.getOrPut(self.gpa, target) catch @panic("OOM");
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
                var kbuf: [320]u8 = undefined;
                const key = std.fmt.bufPrint(&kbuf, "{c}{d}:{s}", .{ kind_ch, target, token }) catch @panic("key too long");
                const owned = self.gpa.dupe(u8, key) catch @panic("OOM");
                self.liked_by.put(self.gpa, owned, {}) catch @panic("OOM");
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
        return self.post_by_id.get(id);
    }

    fn findComment(self: *const BoardModel, id: u64) ?usize {
        return self.comment_by_id.get(id);
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
    /// Reads the `posts_by_board` index (ascending) backward instead of
    /// scanning every post.
    pub fn boardPostIdx(self: *const BoardModel, a: std.mem.Allocator, board: []const u8) ![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        if (self.posts_by_board.get(board)) |l| {
            var i = l.items.len;
            while (i > 0) {
                i -= 1;
                try out.append(a, l.items[i]);
            }
        }
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

    /// Top-level comments of a post (parent == null), ascending id —
    /// served by the `tops_by_post` index.
    pub fn topCommentIdx(self: *const BoardModel, a: std.mem.Allocator, post_id: u64) ![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        if (self.tops_by_post.get(post_id)) |l| try out.appendSlice(a, l.items);
        return out.toOwnedSlice(a);
    }

    /// Children of a comment (parent == id), ascending id — the recursive
    /// tree walk used by the view layer, served by `children_by_parent`.
    pub fn childIdx(self: *const BoardModel, a: std.mem.Allocator, parent_id: u64) ![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        if (self.children_by_parent.get(parent_id)) |l| try out.appendSlice(a, l.items);
        return out.toOwnedSlice(a);
    }

    /// Maintain every index derived from `posts.items[idx]` — called
    /// right after the append in `load`/`addPost`, the only mutation
    /// paths (there is no delete).
    fn indexPost(self: *BoardModel, idx: usize) void {
        const p = &self.posts.items[idx];
        self.post_by_id.put(self.gpa, p.id, idx) catch @panic("OOM");
        const gop = self.posts_by_board.getOrPut(self.gpa, p.board) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.*.append(self.gpa, idx) catch @panic("OOM");
    }

    /// Maintain every index derived from `comments.items[idx]` — the
    /// comment counterpart of `indexPost`; also folds in the old
    /// `noteComment` post-count update. `tops_by_post` and
    /// `children_by_parent` partition the comments exactly like the
    /// old scans: parent == null goes to the post's top list, anything
    /// else to the parent's child list.
    fn indexComment(self: *BoardModel, idx: usize) void {
        const c = &self.comments.items[idx];
        self.comment_by_id.put(self.gpa, c.id, idx) catch @panic("OOM");
        if (c.parent) |pid| {
            const gop = self.children_by_parent.getOrPut(self.gpa, pid) catch @panic("OOM");
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.*.append(self.gpa, idx) catch @panic("OOM");
        } else {
            const gop = self.tops_by_post.getOrPut(self.gpa, c.post) catch @panic("OOM");
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.*.append(self.gpa, idx) catch @panic("OOM");
        }
        const gop = self.post_counts.getOrPut(self.gpa, c.post) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    pub fn commentCount(self: *const BoardModel, post_id: u64) usize {
        return self.post_counts.get(post_id) orelse 0;
    }

    /// Total likes on a post/comment id (shared id space).
    pub fn likeCount(self: *const BoardModel, id: u64) u32 {
        return self.like_counts.get(id) orelse 0;
    }

    /// Toggle the caller's like on `kind`/`target`. One like per
    /// account: the (kind, target, user) PK plus the `liked_by` set
    /// make a second like from the same token impossible — re-liking
    /// unlikes instead. Returns the NEW liked state. Write-through
    /// INSERT/DELETE + `global_seq` bump so every open session
    /// re-renders the count.
    pub fn toggleLike(self: *BoardModel, kind: LikeKind, target: u64, user_token: []const u8) ModelError!bool {
        switch (kind) {
            .post => if (self.findPost(target) == null) return error.PostNotFound,
            .comment => if (self.findComment(target) == null) return error.CommentNotFound,
        }
        var kbuf: [320]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{c}{d}:{s}", .{ likeKindChar(kind), target, user_token }) catch @panic("key too long");
        var kbuf2: [2]u8 = undefined;
        const ks = kbuf2[0..1];
        ks[0] = likeKindChar(kind);
        if (self.liked_by.get(key) != null) {
            var st = self.db.prepare(self.gpa, "DELETE FROM likes WHERE kind = ? AND target = ? AND user = ?") catch |e| return dbErr(e);
            defer st.finalize();
            st.bindText(1, ks) catch |e| return dbErr(e);
            st.bindInt(2, @intCast(target)) catch |e| return dbErr(e);
            st.bindText(3, user_token) catch |e| return dbErr(e);
            _ = st.step() catch |e| return dbErr(e);
            if (self.liked_by.fetchRemove(key)) |kv| self.gpa.free(kv.key);
            const gop = self.like_counts.getPtr(target) orelse return error.Sqlite;
            std.debug.assert(gop.* > 0);
            gop.* -= 1;
            self.bump();
            return false;
        }
        var st = self.db.prepare(self.gpa, "INSERT INTO likes (kind, target, user, ts) VALUES (?, ?, ?, ?)") catch |e| return dbErr(e);
        defer st.finalize();
        st.bindText(1, ks) catch |e| return dbErr(e);
        st.bindInt(2, @intCast(target)) catch |e| return dbErr(e);
        st.bindText(3, user_token) catch |e| return dbErr(e);
        st.bindInt(4, nowSeconds()) catch |e| return dbErr(e);
        _ = st.step() catch |e| return dbErr(e);
        const owned = self.gpa.dupe(u8, key) catch @panic("OOM");
        self.liked_by.put(self.gpa, owned, {}) catch @panic("OOM");
        const gop = self.like_counts.getOrPut(self.gpa, target) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        self.bump();
        return true;
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
        self.indexPost(self.posts.items.len - 1);
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
        self.indexComment(self.comments.items.len - 1);
        self.next_id += 1;
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

test "board indexes reproduce the old scan semantics and track addComment" {
    const alloc = std.testing.allocator;
    var m = try BoardModel.init(alloc, ":memory:");
    defer m.deinit();

    _ = try m.ensureUser("tok-idx");
    const p1 = try m.addPost("b", "tok-idx", "alpha");
    const p2 = try m.addPost("tech", "tok-idx", "beta");
    const p3 = try m.addPost("b", "tok-idx", "gamma");
    const c1 = try m.addComment(p1.id, null, "tok-idx", "t1");
    const c2 = try m.addComment(p1.id, c1.id, "tok-idx", "r1");
    const c3 = try m.addComment(p2.id, null, "tok-idx", "other post");
    const c4 = try m.addComment(p1.id, null, "tok-idx", "t2");
    const c5 = try m.addComment(p1.id, c2.id, "tok-idx", "r2");
    _ = c3;
    _ = c5;

    // Reference copies of the pre-index scans — the contract the
    // indexes must reproduce exactly (order + contents).
    const RefScan = struct {
        fn tops(mm: *const BoardModel, post_id: u64, a: std.mem.Allocator) ![]usize {
            var out: std.ArrayListUnmanaged(usize) = .empty;
            for (mm.comments.items, 0..) |c, i| {
                if (c.post == post_id and c.parent == null) try out.append(a, i);
            }
            return out.toOwnedSlice(a);
        }
        fn kids(mm: *const BoardModel, parent_id: u64, a: std.mem.Allocator) ![]usize {
            var out: std.ArrayListUnmanaged(usize) = .empty;
            for (mm.comments.items, 0..) |c, i| {
                if (c.parent != null and c.parent.? == parent_id) try out.append(a, i);
            }
            return out.toOwnedSlice(a);
        }
        fn boardPosts(mm: *const BoardModel, slug: []const u8, a: std.mem.Allocator) ![]usize {
            var out: std.ArrayListUnmanaged(usize) = .empty;
            for (mm.posts.items, 0..) |p, i| {
                if (std.mem.eql(u8, p.board, slug)) try out.append(a, i);
            }
            std.mem.reverse(usize, out.items);
            return out.toOwnedSlice(a);
        }
    };

    const expectSame = struct {
        fn f(a: std.mem.Allocator, got: []usize, want: []usize) !void {
            defer a.free(got);
            defer a.free(want);
            try std.testing.expectEqual(want.len, got.len);
            for (want, got) |w, g| try std.testing.expectEqual(w, g);
        }
    }.f;

    // Every query shape agrees with the scans, for present and absent keys.
    for ([_]u64{ p1.id, p2.id, p3.id, 999 }) |pid| {
        try expectSame(alloc, try m.topCommentIdx(alloc, pid), try RefScan.tops(m, pid, alloc));
    }
    for (m.comments.items) |c| {
        try expectSame(alloc, try m.childIdx(alloc, c.id), try RefScan.kids(m, c.id, alloc));
    }
    for (boards) |b| {
        try expectSame(alloc, try m.boardPostIdx(alloc, b.slug), try RefScan.boardPosts(m, b.slug, alloc));
    }

    // Id lookups resolve to the same rows a scan would have found.
    for (m.posts.items, 0..) |p, i| {
        try std.testing.expectEqual(i, m.findPost(p.id).?);
        try std.testing.expect(m.post(p.id).? == &m.posts.items[i]);
    }
    for (m.comments.items, 0..) |c, i| {
        try std.testing.expectEqual(i, m.findComment(c.id).?);
        try std.testing.expect(m.comment(c.id).? == &m.comments.items[i]);
    }

    // addComment updates the indexes immediately, preserving order.
    const c6 = try m.addComment(p1.id, c4.id, "tok-idx", "late reply");
    const c7 = try m.addComment(p1.id, c1.id, "tok-idx", "second reply");
    const kids1 = try m.childIdx(alloc, c1.id);
    defer alloc.free(kids1);
    try std.testing.expectEqual(@as(usize, 2), kids1.len);
    try std.testing.expectEqual(c2.id, m.comments.items[kids1[0]].id);
    try std.testing.expectEqual(c7.id, m.comments.items[kids1[1]].id);
    const kids4 = try m.childIdx(alloc, c4.id);
    defer alloc.free(kids4);
    try std.testing.expectEqual(@as(usize, 1), kids4.len);
    try std.testing.expectEqual(c6.id, m.comments.items[kids4[0]].id);
    const tops = try m.topCommentIdx(alloc, p1.id);
    defer alloc.free(tops);
    try std.testing.expectEqual(@as(usize, 2), tops.len);
    try std.testing.expectEqual(c1.id, m.comments.items[tops[0]].id);
    try std.testing.expectEqual(c4.id, m.comments.items[tops[1]].id);
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
        const c = try m.addComment(1, null, "tok-persist", "persisted comment");
        _ = try m.addComment(1, c.id, "tok-persist", "persisted reply");
        m.deinit();
    }
    {
        var m = try BoardModel.init(alloc, path);
        defer m.deinit();
        try std.testing.expectEqual(@as(usize, 1), m.posts.items.len);
        try std.testing.expectEqualStrings("survives restart", m.posts.items[0].text);
        try std.testing.expectEqualStrings("Anon#1", m.userName("tok-persist").?);
        // Indexes were rebuilt by load(): tops/kids resolve without scans.
        const tops = try m.topCommentIdx(alloc, 1);
        defer alloc.free(tops);
        try std.testing.expectEqual(@as(usize, 1), tops.len);
        const kids = try m.childIdx(alloc, m.comments.items[tops[0]].id);
        defer alloc.free(kids);
        try std.testing.expectEqual(@as(usize, 1), kids.len);
        // next_id continues the shared sequence.
        const p = try m.addPost("b", "tok-persist", "second life");
        try std.testing.expect(p.id > 1);
    }
}

test "board model: likes toggle once per account, counts, kind isolation" {
    const alloc = std.testing.allocator;
    var m = try BoardModel.init(alloc, ":memory:");
    defer m.deinit();
    _ = try m.ensureUser("tok-a");
    _ = try m.ensureUser("tok-b");
    const p = try m.addPost("tech", "tok-a", "liked post");
    const c = try m.addComment(p.id, null, "tok-a", "liked comment");

    // First toggle inserts, second removes — the same token can never
    // hold two votes on one target.
    try std.testing.expect(try m.toggleLike(.post, p.id, "tok-a"));
    try std.testing.expectEqual(@as(u32, 1), m.likeCount(p.id));
    try std.testing.expect(!(try m.toggleLike(.post, p.id, "tok-a")));
    try std.testing.expectEqual(@as(u32, 0), m.likeCount(p.id));

    // A different account likes independently; re-liking by tok-a adds
    // a second vote.
    try std.testing.expect(try m.toggleLike(.post, p.id, "tok-b"));
    try std.testing.expect(try m.toggleLike(.post, p.id, "tok-a"));
    try std.testing.expectEqual(@as(u32, 2), m.likeCount(p.id));

    // Same numeric id space, different kind — no cross-talk.
    try std.testing.expect(try m.toggleLike(.comment, c.id, "tok-a"));
    try std.testing.expectEqual(@as(u32, 1), m.likeCount(c.id));
    try std.testing.expectEqual(@as(u32, 2), m.likeCount(p.id));

    // Missing/wrong-kind targets rejected before any mutation.
    try std.testing.expectError(error.PostNotFound, m.toggleLike(.post, 999, "tok-a"));
    try std.testing.expectError(error.CommentNotFound, m.toggleLike(.comment, 999, "tok-a"));
    try std.testing.expectError(error.CommentNotFound, m.toggleLike(.comment, p.id, "tok-a"));
}

test "board model: likes survive reload from a file db" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/zboard-test-likes.db";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, path ++ "-wal") catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path ++ "-wal") catch {};
    std.Io.Dir.deleteFileAbsolute(io, path ++ "-shm") catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, path ++ "-shm") catch {};

    {
        var m = try BoardModel.init(alloc, path);
        _ = try m.ensureUser("tok-like");
        const p = try m.addPost("tech", "tok-like", "persisted likes");
        _ = try m.toggleLike(.post, p.id, "tok-like");
        _ = try m.toggleLike(.post, p.id, "tok-like"); // toggles back off
        _ = try m.toggleLike(.post, p.id, "tok-like"); // and on again
        const c = try m.addComment(p.id, null, "tok-like", "liked reply");
        _ = try m.toggleLike(.comment, c.id, "tok-like");
        m.deinit();
    }
    {
        var m = try BoardModel.init(alloc, path);
        defer m.deinit();
        try std.testing.expectEqual(@as(u32, 1), m.likeCount(1));
        // Reloaded liked_by set lets the same account toggle OFF.
        try std.testing.expect(!(try m.toggleLike(.post, 1, "tok-like")));
        try std.testing.expectEqual(@as(u32, 0), m.likeCount(1));
        try std.testing.expectEqual(@as(u32, 1), m.likeCount(2));
    }
}
