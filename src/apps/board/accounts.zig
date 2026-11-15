//! Account auth for the shared board model (ADR-0001 phase 2): the
//! `accounts` table rows, PBKDF2-HMAC-SHA256 password hashing,
//! register/verify, and the single live `zfxa` auth token per account
//! (attach/detach/resolve). Extracted from model.zig — the functions
//! here are the account operations on `BoardModel`; model.zig keeps
//! thin `m.<op>` delegates so existing call sites (`model.get().
//! registerAccount`, `components`' `accountName`, ...) are unchanged.
//!
//! The `accounts` table DDL stays in model.zig's `schema` blob (one
//! CREATE TABLE IF NOT EXISTS per table — splitting DDL across files
//! would be messier than the single schema const is worth); likewise
//! the `acct` columns on posts/comments are post CONTENT handled by
//! the post/comment paths. What lives here is everything that reads
//! or writes account rows: load/deinit, register/verify, and the
//! auth-token lifecycle.
const std = @import("std");
const model = @import("model.zig");

const ModelError = model.ModelError;

/// Account name cap (chars) — the `[a-zA-Z0-9_-]` charset keeps names
/// URL/cookie/HTML safe and unambiguous next to "Anon#N"/"@name".
pub const max_account_name_len = 32;
/// Minimum password length (bytes) — demo-grade floor, not a policy.
pub const min_password_len = 8;
/// PBKDF2-HMAC-SHA256 cost — demo trade-off per ADR-0001 (~100 ms-class
/// on modern hw is overkill here; stored format keeps `iterations`
/// tunable per hash).
const pbkdf2_iterations: u32 = 100_000;
/// Salt width for `registerAccount` callers (app.zig mints it from
/// `io.random`) — pub so the session can size its stack buffer.
pub const password_salt_len = 16;
const password_hash_len = 32; // SHA-256 output

/// One row of the `accounts` table. `id` is implicit: accounts are
/// append-only (no delete path), so `id == index + 1` in `accounts`.
/// `pass_hash` is "salt_hex$iterations$hash_hex" — the plaintext
/// password is never stored. `auth_token` is the live `zfxa` cookie
/// value (NULL = logged out); the by-token map borrows this slice.
pub const Account = struct {
    name: []u8,
    pass_hash: []u8,
    auth_token: ?[]u8 = null,
    created: i64,
};

/// Account name charset: 1–`max_account_name_len` chars of
/// `[a-zA-Z0-9_-]`. The "@" display prefix plus this charset keeps
/// account names disjoint from "Anon#N"/"anon" in render-group keys.
fn validAccountName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_account_name_len) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

fn validPassword(password: []const u8) bool {
    return password.len >= min_password_len;
}

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// PBKDF2-HMAC-SHA256 via std.crypto — std's implementation IS the
/// RFC 2898 loop over `HmacSha256` (same construction the ADR sketched
/// by hand); `iterations`/`salt` come from the stored hash so verify
/// recomputes identically.
fn pbkdf2Hash(password: []const u8, salt: []const u8, iterations: u32, out: *[password_hash_len]u8) void {
    std.crypto.pwhash.pbkdf2(out, password, salt, iterations, HmacSha256) catch unreachable;
}

/// `pass_hash` column format: "<salt_hex>$<iterations>$<hash_hex>".
fn hashPassword(a: std.mem.Allocator, password: []const u8, salt: *const [password_salt_len]u8) error{OutOfMemory}![]u8 {
    var dk: [password_hash_len]u8 = undefined;
    pbkdf2Hash(password, salt, pbkdf2_iterations, &dk);
    const shex = std.fmt.bytesToHex(salt, .lower);
    const dhex = std.fmt.bytesToHex(dk, .lower);
    return std.fmt.allocPrint(a, "{s}${d}${s}", .{ shex[0..], pbkdf2_iterations, dhex[0..] }) catch error.OutOfMemory;
}

/// Recompute + constant-time compare against a stored `pass_hash`.
/// Malformed stored values simply fail — they can only come from a
/// hand-edited db.
fn verifyPassword(stored: []const u8, password: []const u8) bool {
    var it = std.mem.splitScalar(u8, stored, '$');
    const salt_hex = it.next() orelse return false;
    const iter_s = it.next() orelse return false;
    const hash_hex = it.next() orelse return false;
    if (it.next() != null) return false;
    const iterations = std.fmt.parseInt(u32, iter_s, 10) catch return false;
    if (iterations == 0) return false;
    if (salt_hex.len != password_salt_len * 2 or hash_hex.len != password_hash_len * 2) return false;
    var salt: [password_salt_len]u8 = undefined;
    _ = std.fmt.hexToBytes(salt[0..], salt_hex) catch return false;
    var want: [password_hash_len]u8 = undefined;
    _ = std.fmt.hexToBytes(want[0..], hash_hex) catch return false;
    var got: [password_hash_len]u8 = undefined;
    pbkdf2Hash(password, &salt, iterations, &got);
    return std.crypto.timing_safe.eql([password_hash_len]u8, got, want);
}

/// Load the `accounts` rows into `m.accounts` + the by-name/by-token
/// index maps — the accounts half of `BoardModel.load`. Account ids
/// are contiguous rowids — `accounts.items[i]` is account `i + 1`.
/// Index maps key on the Account's owned slices (borrowed — freed via
/// the Account, never via the maps).
pub fn loadAccounts(m: *model.BoardModel) !void {
    var st = try m.db.prepare(m.gpa, "SELECT id, name, pass_hash, auth_token, created FROM accounts ORDER BY id");
    defer st.finalize();
    while (try st.step()) {
        const tok_col = st.columnText(3);
        const acct = Account{
            .name = try m.gpa.dupe(u8, st.columnText(1)),
            .pass_hash = try m.gpa.dupe(u8, st.columnText(2)),
            .auth_token = if (tok_col.len == 0) null else try m.gpa.dupe(u8, tok_col),
            .created = st.columnInt(4),
        };
        errdefer {
            m.gpa.free(acct.name);
            m.gpa.free(acct.pass_hash);
            if (acct.auth_token) |t| m.gpa.free(t);
        }
        const idx = m.accounts.items.len;
        try m.accounts.append(m.gpa, acct);
        // Index maps key on the Account's owned slices (borrowed).
        m.account_by_name.put(m.gpa, acct.name, idx) catch @panic("OOM");
        if (acct.auth_token) |t| m.account_by_token.put(m.gpa, t, idx) catch @panic("OOM");
        std.debug.assert(st.columnInt(0) == @as(i64, @intCast(idx + 1)));
    }
}

/// Free every account row's owned strings + the row list and both
/// index maps — the accounts half of `BoardModel.deinit`. The maps
/// hold BORROWED keys, so they deinit after the Account slices are
/// freed (map storage only — never the keys).
pub fn deinitAccounts(m: *model.BoardModel) void {
    for (m.accounts.items) |acct| {
        m.gpa.free(acct.name);
        m.gpa.free(acct.pass_hash);
        if (acct.auth_token) |t| m.gpa.free(t);
    }
    m.accounts.deinit(m.gpa);
    // account_by_name/account_by_token keys borrow Account slices —
    // deinit frees map storage only, never the keys.
    m.account_by_name.deinit(m.gpa);
    m.account_by_token.deinit(m.gpa);
}

/// Display name for an account id ("alice" — the view adds "@").
pub fn accountName(m: *const model.BoardModel, id: u64) ?[]const u8 {
    if (id == 0 or id > m.accounts.items.len) return null;
    return m.accounts.items[id - 1].name;
}

/// Account id holding `auth_token` (the zfxa cookie value), or null.
pub fn accountByAuthToken(m: *const model.BoardModel, token: []const u8) ?u64 {
    if (token.len == 0) return null;
    const idx = m.account_by_token.get(token) orelse return null;
    return idx + 1;
}

/// Register `name`/`password` and attach `auth_token` in one step
/// (register == auto-login). `salt` is caller-minted randomness —
/// the model stays io-free like `ensureUser`. Returns the new id.
/// Auth writes do NOT bump `global_seq`: nothing any other session
/// renders depends on the accounts table.
pub fn registerAccount(m: *model.BoardModel, name_in: []const u8, password: []const u8, salt: *const [password_salt_len]u8, auth_token: []const u8) ModelError!u64 {
    if (!validAccountName(name_in)) return error.InvalidName;
    if (!validPassword(password)) return error.InvalidPassword;
    if (m.account_by_name.contains(name_in)) return error.NameTaken;
    const pass_hash = hashPassword(m.gpa, password, salt) catch return error.OutOfMemory;
    errdefer m.gpa.free(pass_hash);
    const created = model.nowSeconds();
    var st = m.db.prepare(m.gpa, "INSERT INTO accounts (name, pass_hash, auth_token, created) VALUES (?, ?, ?, ?)") catch |e| return model.BoardModel.dbErr(e);
    defer st.finalize();
    st.bindText(1, name_in) catch |e| return model.BoardModel.dbErr(e);
    st.bindText(2, pass_hash) catch |e| return model.BoardModel.dbErr(e);
    st.bindText(3, auth_token) catch |e| return model.BoardModel.dbErr(e);
    st.bindInt(4, created) catch |e| return model.BoardModel.dbErr(e);
    _ = st.step() catch |e| return model.BoardModel.dbErr(e);

    const idx = m.accounts.items.len;
    const acct = Account{
        .name = m.gpa.dupe(u8, name_in) catch @panic("OOM"),
        .pass_hash = pass_hash,
        .auth_token = m.gpa.dupe(u8, auth_token) catch @panic("OOM"),
        .created = created,
    };
    try m.accounts.append(m.gpa, acct);
    m.account_by_name.put(m.gpa, acct.name, idx) catch @panic("OOM");
    m.account_by_token.put(m.gpa, acct.auth_token.?, idx) catch @panic("OOM");
    return idx + 1;
}

/// Verify `name`/`password`; returns the account id. Unknown name
/// and wrong password share `error.BadLogin` — no user enumeration.
pub fn verifyAccount(m: *const model.BoardModel, name: []const u8, password: []const u8) ModelError!u64 {
    const idx = m.account_by_name.get(name) orelse return error.BadLogin;
    if (!verifyPassword(m.accounts.items[idx].pass_hash, password)) return error.BadLogin;
    return idx + 1;
}

/// (Re)bind account `id`'s live auth token — login mints a fresh
/// zfxa per sign-in; one token per account, so attaching replaces
/// any previous one (a second login invalidates the first cookie).
pub fn attachAuthToken(m: *model.BoardModel, id: u64, token: []const u8) ModelError!void {
    if (id == 0 or id > m.accounts.items.len) return error.NotFound;
    const acct = &m.accounts.items[id - 1];
    if (acct.auth_token) |old| {
        _ = m.account_by_token.fetchRemove(old);
        m.gpa.free(old);
    }
    var st = m.db.prepare(m.gpa, "UPDATE accounts SET auth_token = ? WHERE id = ?") catch |e| return model.BoardModel.dbErr(e);
    defer st.finalize();
    st.bindText(1, token) catch |e| return model.BoardModel.dbErr(e);
    st.bindInt(2, @intCast(id)) catch |e| return model.BoardModel.dbErr(e);
    _ = st.step() catch |e| return model.BoardModel.dbErr(e);
    const owned = m.gpa.dupe(u8, token) catch @panic("OOM");
    acct.auth_token = owned;
    m.account_by_token.put(m.gpa, owned, id - 1) catch @panic("OOM");
}

/// Clear account `id`'s auth token (logout) — the zfxa cookie is
/// expired client-side AND the stored token dropped, so a replayed
/// cookie stops resolving.
pub fn detachAuthToken(m: *model.BoardModel, id: u64) ModelError!void {
    if (id == 0 or id > m.accounts.items.len) return error.NotFound;
    const acct = &m.accounts.items[id - 1];
    const old = acct.auth_token orelse return;
    _ = m.account_by_token.fetchRemove(old);
    m.gpa.free(old);
    acct.auth_token = null;
    var st = m.db.prepare(m.gpa, "UPDATE accounts SET auth_token = NULL WHERE id = ?") catch |e| return model.BoardModel.dbErr(e);
    defer st.finalize();
    st.bindInt(1, @intCast(id)) catch |e| return model.BoardModel.dbErr(e);
    _ = st.step() catch |e| return model.BoardModel.dbErr(e);
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "board model: accounts register, verify, and resolve auth tokens" {
    const alloc = std.testing.allocator;
    var m = try model.BoardModel.init(alloc, ":memory:");
    defer m.deinit();
    _ = try m.ensureUser("tok-acct");

    var salt: [password_salt_len]u8 = @splat(0x5a);
    const id = try m.registerAccount("alice", "correct horse", &salt, "tok-a1");
    try std.testing.expectEqual(@as(u64, 1), id);
    try std.testing.expectEqualStrings("alice", m.accountName(1).?);
    try std.testing.expect(m.accountName(2) == null);
    try std.testing.expectEqual(@as(?u64, 1), m.accountByAuthToken("tok-a1"));
    try std.testing.expect(m.accountByAuthToken("") == null);
    try std.testing.expect(m.accountByAuthToken("bogus") == null);

    // Validation + uniqueness: name charset/length, password length,
    // duplicate names.
    try std.testing.expectError(error.NameTaken, m.registerAccount("alice", "whatever1", &salt, "tok-a2"));
    try std.testing.expectError(error.InvalidName, m.registerAccount("bad name!", "whatever1", &salt, "tok-a2"));
    try std.testing.expectError(error.InvalidName, m.registerAccount("", "whatever1", &salt, "tok-a2"));
    var long_name_buf: [max_account_name_len + 1]u8 = @splat('n');
    try std.testing.expectError(error.InvalidName, m.registerAccount(&long_name_buf, "whatever1", &salt, "tok-a2"));
    try std.testing.expectError(error.InvalidPassword, m.registerAccount("bob", "short", &salt, "tok-a2"));
    // The failed registrations left no rows behind.
    try std.testing.expectEqual(@as(usize, 1), m.accounts.items.len);

    const id2 = try m.registerAccount("bob", "whatever1", &salt, "tok-b1");
    try std.testing.expectEqual(@as(u64, 2), id2);

    // verifyAccount: right password → id; wrong password AND unknown
    // name share BadLogin (no user enumeration).
    try std.testing.expectEqual(@as(u64, 1), try m.verifyAccount("alice", "correct horse"));
    try std.testing.expectEqual(@as(u64, 2), try m.verifyAccount("bob", "whatever1"));
    try std.testing.expectError(error.BadLogin, m.verifyAccount("alice", "wrong password"));
    try std.testing.expectError(error.BadLogin, m.verifyAccount("carol", "correct horse"));

    // attachAuthToken replaces the live token — one zfxa per account,
    // so a second login invalidates the first cookie.
    try m.attachAuthToken(1, "tok-a9");
    try std.testing.expect(m.accountByAuthToken("tok-a1") == null);
    try std.testing.expectEqual(@as(?u64, 1), m.accountByAuthToken("tok-a9"));
    try std.testing.expectError(error.NotFound, m.attachAuthToken(99, "tok-x"));

    // detachAuthToken clears it — a replayed cookie stops resolving.
    try m.detachAuthToken(1);
    try std.testing.expect(m.accountByAuthToken("tok-a9") == null);
    try std.testing.expect(m.accounts.items[0].auth_token == null);
    try std.testing.expectError(error.NotFound, m.detachAuthToken(99));
}

test "board model: accounts and acct ownership persist across reload" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const t = try model.tmpDbPaths(alloc, "acct");
    defer t.deinit(alloc);
    model.cleanTmpDb(io, t);
    defer model.cleanTmpDb(io, t);

    {
        var m = try model.BoardModel.init(alloc, t.path);
        _ = try m.ensureUser("tok-p");
        var salt: [password_salt_len]u8 = @splat(0x33);
        const aid = try m.registerAccount("carol", "s3cret-pass", &salt, "tok-c1");
        const p = try m.addPost("b", "tok-p", "owned post", null, aid);
        const c = try m.addComment(p.id, null, "tok-p", "owned comment", null, aid);
        const anon = try m.addPost("b", "tok-p", "anon post", null, null);
        _ = c;
        _ = anon;
        m.deinit();
    }
    {
        var m = try model.BoardModel.init(alloc, t.path);
        defer m.deinit();
        // Account + password hash + live token all round-tripped.
        try std.testing.expectEqual(@as(usize, 1), m.accounts.items.len);
        try std.testing.expectEqualStrings("carol", m.accountName(1).?);
        try std.testing.expectEqual(@as(u64, 1), try m.verifyAccount("carol", "s3cret-pass"));
        try std.testing.expectError(error.BadLogin, m.verifyAccount("carol", "wrong-pass1"));
        try std.testing.expectEqual(@as(?u64, 1), m.accountByAuthToken("tok-c1"));
        // acct columns survived: owned rows carry 1, anonymous NULL.
        try std.testing.expectEqual(@as(?u64, 1), m.posts.items[0].acct);
        try std.testing.expectEqual(@as(?u64, 1), m.comments.items[0].acct);
        try std.testing.expect(m.posts.items[1].acct == null);
        // next_id continues across posts+comments.
        const p = try m.addPost("b", "tok-p", "post-restart", null, null);
        try std.testing.expect(p.id > 3);
    }
}
