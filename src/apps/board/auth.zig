//! Account auth for zboard sessions (ADR-0001 phase 2): the
//! register/login/logout + own-content delete action handlers, the
//! `zfxa` cookie resolution, and the session-auth helpers. Extracted
//! from app.zig — `BoardDeps` keeps thin `on_<name>` forwards because
//! the generated `gen/actions.zig` dispatch calls `Deps.on_<name>`
//! decls on the Deps type, and `Deps.readCookies` delegates the
//! account half here (the `zfxu` anonymous half stays in app.zig).
//!
//! What stays in app.zig: the `account_id`/`out_cookie_buf2`/`name_buf`
//! deps fields (viewEnv + render-group keys read them), the `zfxa`
//! cookie NAME constant, and `Session.out_cookie2` — the second
//! Set-Cookie channel `server/http.zig` probes via `@hasDecl`.
const std = @import("std");
const app = @import("app.zig");
const model = @import("model.zig");
const components = @import("components.zig");
const groups = @import("groups.zig");

/// Mint a `zfxa` auth token: 16 io-random bytes as 32 lowercase hex
/// chars — cookie-safe, unguessable, and the model stores it verbatim
/// (the by-token map makes lookups O(1)). Caller owns the result.
fn mintAuthToken(s: *app.Session) []u8 {
    var rb: [16]u8 = undefined;
    s.io.random(&rb);
    const hex = std.fmt.bytesToHex(rb, .lower);
    return s.gpa.dupe(u8, &hex) catch @panic("OOM");
}

/// Mark `s` logged in as account `id` with live token `token` (the
/// caller's copy — the model already stored its own): sets the
/// session's account id and stages the `zfxa` Set-Cookie on
/// `out_cookie2` for THIS response only.
fn setSessionAuth(s: *app.Session, id: u64, token: []const u8) void {
    s.deps.account_id = id;
    s.out_cookie2 = std.fmt.bufPrint(&s.deps.out_cookie_buf2, "{s}={s}; Path=/; HttpOnly; SameSite=Strict", .{ app.auth_cookie_name, token }) catch @panic("cookie buf too small");
}

/// The viewer's auth display name — "@<account>" when logged in,
/// else the resolved anonymous name ("Anon#N" / "anon"). Written
/// into `buf` (caller-owned scratch; the result is consumed by the
/// immediately-following view build or group join, never retained).
/// Used by app.zig's `viewEnv` and `groupKey`.
pub fn authNameInto(d: *app.BoardDeps, buf: []u8) []const u8 {
    if (d.account_id) |id| {
        if (model.get().accountName(id)) |n| {
            return std.fmt.bufPrint(buf, "@{s}", .{n}) catch "anon";
        }
    }
    return components.nameOf(d.user_token);
}

/// Resolve a raw `zfxa` cookie value into `s.deps.account_id` —
/// present+valid → account id; absent, empty, or detached →
/// anonymous. `Deps.readCookies` calls this on every /action POST and
/// page GET (NOT /events), so an open stream keeps its last-resolved
/// auth until the next request or render re-key; the render-group
/// re-key on the next render migrates the session out of the account
/// group. `accountByAuthToken` is a map hit — cheap per request.
pub fn resolveAuth(s: *app.Session, token: ?[]const u8) void {
    s.deps.account_id = if (token) |t| model.get().accountByAuthToken(t) else null;
}

/// `register` — fields {name, password, confirm} → create the
/// account AND log in (register == auto-login): PBKDF2 hash +
/// fresh auth token land in one model call, `zfxa` rides
/// `out_cookie2` on this response. `confirm` must match `password`
/// — it's the only client-side check the server repeats.
pub fn onRegister(s: *app.Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
    _ = arg;
    _ = value;
    const f = fields orelse return error.InvalidAction;
    const name = app.fieldStr(f, "name") orelse return error.InvalidAction;
    const password = app.fieldStr(f, "password") orelse return error.InvalidAction;
    const confirm = app.fieldStr(f, "confirm") orelse return error.InvalidAction;
    if (!std.mem.eql(u8, password, confirm)) return error.InvalidPassword;
    var salt: [model.password_salt_len]u8 = undefined;
    s.io.random(&salt);
    const token = mintAuthToken(s);
    const id = model.get().registerAccount(name, password, &salt, token) catch |e| {
        s.gpa.free(token);
        return e;
    };
    setSessionAuth(s, id, token); // copies token into out_cookie2
    s.gpa.free(token);
    s.deps.ping.emit(.{});
}

/// `login` — fields {name, password} → verify, mint a FRESH
/// `zfxa` (one live token per account — a second login invalidates
/// the first cookie), set session auth + `out_cookie2`.
/// BadLogin covers unknown name AND wrong password alike.
pub fn onLogin(s: *app.Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
    _ = arg;
    _ = value;
    const f = fields orelse return error.InvalidAction;
    const name = app.fieldStr(f, "name") orelse return error.InvalidAction;
    const password = app.fieldStr(f, "password") orelse return error.InvalidAction;
    const id = try model.get().verifyAccount(name, password);
    const token = mintAuthToken(s);
    model.get().attachAuthToken(id, token) catch |e| {
        s.gpa.free(token);
        return e;
    };
    setSessionAuth(s, id, token);
    s.gpa.free(token);
    s.deps.ping.emit(.{});
}

/// `logout` — drop the stored auth token (a replayed `zfxa` stops
/// resolving), clear session auth, expire the cookie client-side.
pub fn onLogout(s: *app.Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
    _ = arg;
    _ = value;
    _ = fields;
    const was = s.deps.account_id != null;
    if (s.deps.account_id) |id| {
        model.get().detachAuthToken(id) catch {};
        s.deps.account_id = null;
    }
    s.out_cookie2 = std.fmt.bufPrint(&s.deps.out_cookie_buf2, "{s}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0", .{app.auth_cookie_name}) catch @panic("cookie buf too small");
    if (was) s.deps.ping.emit(.{});
}

/// `delete_post` — arg = post id → model.deletePost gated on the
/// session's account owning the row (anonymous posts: never).
/// Cascades comments + likes; bumps global_seq like addPost.
pub fn onDeletePost(s: *app.Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
    _ = value;
    _ = fields;
    const a = arg orelse return error.InvalidAction;
    const id = std.fmt.parseInt(u64, a, 10) catch return error.InvalidAction;
    try model.get().deletePost(id, s.deps.account_id);
    s.deps.ping.emit(.{});
}

/// `delete_comment` — arg = comment id → model.deleteComment with
/// the same ownership gate + descendant/like cascade.
pub fn onDeleteComment(s: *app.Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
    _ = value;
    _ = fields;
    const a = arg orelse return error.InvalidAction;
    const id = std.fmt.parseInt(u64, a, 10) catch return error.InvalidAction;
    try model.get().deleteComment(id, s.deps.account_id);
    s.deps.ping.emit(.{});
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "auth actions: register/login/logout set session auth + zfxa cookie" {
    const alloc = std.testing.allocator;
    const mm = app.testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;

    const s = app.createSession(alloc, std.testing.io);
    defer s.deinit();

    // register == auto-login: session gains account_id and the zfxa
    // Set-Cookie rides out_cookie2 on THIS response only.
    var rf = app.fieldsOf(alloc, &.{
        .{ "name", "alice" },
        .{ "password", "password1" },
        .{ "confirm", "password1" },
    });
    defer rf.deinit(alloc);
    try s.dispatch("register", null, null, &rf);
    try std.testing.expectEqual(@as(?u64, 1), s.deps.account_id);
    try std.testing.expect(std.mem.startsWith(u8, s.out_cookie2, "zfxa="));
    const tok1 = mm.accounts.items[0].auth_token.?;
    try std.testing.expect(std.mem.indexOf(u8, s.out_cookie2, tok1) != null);

    // One-shot: the next dispatch clears it — no re-send on later POSTs.
    try s.dispatch("cancel_reply", null, null, null);
    try std.testing.expectEqual(@as(usize, 0), s.out_cookie2.len);

    // readCookies resolves zfxa → account id on another session; a
    // bogus/absent token resolves to anonymous.
    const s2 = app.createSession(alloc, std.testing.io);
    defer s2.deinit();
    var hdr_buf: [96]u8 = undefined;
    const hdr1 = std.fmt.bufPrint(&hdr_buf, "zfxa={s}", .{tok1}) catch unreachable;
    s2.readCookies(hdr1);
    try std.testing.expectEqual(@as(?u64, 1), s2.deps.account_id);
    s2.readCookies("zfxa=bogus-token");
    try std.testing.expect(s2.deps.account_id == null);
    s2.readCookies(null);
    try std.testing.expect(s2.deps.account_id == null);

    // Validation: confirm mismatch → InvalidPassword; wrong password
    // → BadLogin; unknown name → BadLogin.
    var bad = app.fieldsOf(alloc, &.{
        .{ "name", "bob" },
        .{ "password", "password1" },
        .{ "confirm", "password2" },
    });
    defer bad.deinit(alloc);
    try std.testing.expectError(error.InvalidPassword, s.dispatch("register", null, null, &bad));
    var lf = app.fieldsOf(alloc, &.{
        .{ "name", "alice" },
        .{ "password", "wrong-pass" },
    });
    defer lf.deinit(alloc);
    try std.testing.expectError(error.BadLogin, s.dispatch("login", null, null, &lf));
    var lf2 = app.fieldsOf(alloc, &.{
        .{ "name", "ghost" },
        .{ "password", "password1" },
    });
    defer lf2.deinit(alloc);
    try std.testing.expectError(error.BadLogin, s.dispatch("login", null, null, &lf2));

    // login mints a FRESH token: the previous zfxa stops resolving
    // everywhere (one live token per account).
    var ok = app.fieldsOf(alloc, &.{
        .{ "name", "alice" },
        .{ "password", "password1" },
    });
    defer ok.deinit(alloc);
    try s.dispatch("login", null, null, &ok);
    try std.testing.expectEqual(@as(?u64, 1), s.deps.account_id);
    const tok2 = mm.accounts.items[0].auth_token.?;
    try std.testing.expect(!std.mem.eql(u8, tok1, tok2));
    try std.testing.expect(mm.accountByAuthToken(tok1) == null);
    try std.testing.expectEqual(@as(?u64, 1), mm.accountByAuthToken(tok2));
    // s2's cookie still carries the dead tok1 → drops back to anon.
    s2.readCookies(hdr1);
    try std.testing.expect(s2.deps.account_id == null);

    // logout: session auth cleared, cookie expired, stored token
    // dropped — replaying tok2 resolves nothing.
    try s.dispatch("logout", null, null, null);
    try std.testing.expect(s.deps.account_id == null);
    try std.testing.expect(std.mem.indexOf(u8, s.out_cookie2, "Max-Age=0") != null);
    try std.testing.expect(mm.accounts.items[0].auth_token == null);
    const hdr2 = std.fmt.bufPrint(&hdr_buf, "zfxa={s}", .{tok2}) catch unreachable;
    s2.readCookies(hdr2);
    try std.testing.expect(s2.deps.account_id == null);
}

test "render groups: account auth splits the key; login forks, logout rejoins" {
    const alloc = std.testing.allocator;
    const mm = app.testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;

    _ = try mm.addPost("b", "tok1", "p", null, null);
    const a = app.createSession(alloc, std.testing.io);
    defer a.deinit();
    const b = app.createSession(alloc, std.testing.io);
    defer b.deinit();
    try app.serveBoth(alloc, a, b, "/b/b");
    const anon_group = a.deps.group.?;
    try std.testing.expectEqual(@as(usize, 2), anon_group.members);
    const e0 = a.membershipEpoch();

    // a registers → auto-login → the auth dimension re-keys the
    // session. "@alice"/acct:1 is absent → clone-fork: epoch stays,
    // the forked group continues the anon stream lineage.
    var rf = app.fieldsOf(alloc, &.{
        .{ "name", "alice" },
        .{ "password", "password1" },
        .{ "confirm", "password1" },
    });
    defer rf.deinit(alloc);
    try a.dispatch("register", null, null, &rf);
    const acct_group = a.deps.group.?;
    try std.testing.expect(acct_group != anon_group);
    try std.testing.expect(b.deps.group.? == anon_group);
    try std.testing.expectEqual(@as(?u64, 1), acct_group.key.account_id);
    try std.testing.expectEqualStrings("@alice", acct_group.key.name);
    try std.testing.expect(a.membershipEpoch() == e0);
    try std.testing.expectEqual(@as(usize, 2), groups.registryCount());

    // The auth chrome actually renders: session SSR shows "@alice" +
    // the logout button; the anon session still shows login/register.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try a.writeView(&aw.writer);
    const ahtml = aw.toOwnedSlice() catch @panic("OOM");
    defer alloc.free(ahtml);
    try std.testing.expect(std.mem.indexOf(u8, ahtml, "@alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, ahtml, "logout") != null);
    try std.testing.expect(std.mem.indexOf(u8, ahtml, "posting as") != null);
    var bw: std.Io.Writer.Allocating = .init(alloc);
    defer bw.deinit();
    try b.writeView(&bw.writer);
    const bhtml = bw.toOwnedSlice() catch @panic("OOM");
    defer alloc.free(bhtml);
    try std.testing.expect(std.mem.indexOf(u8, bhtml, "login") != null);
    try std.testing.expect(std.mem.indexOf(u8, bhtml, "register") != null);
    try std.testing.expect(std.mem.indexOf(u8, bhtml, "@alice") == null);

    // logout → account_id null → the name falls back to the session's
    // MINTED anonymous identity ("Anon#1" — the register POST's
    // ensureUser already created it), NOT b's unresolved "anon".
    // That key is absent → clone-fork again: epoch still unchanged,
    // the single-member acct group is destroyed on leave.
    try a.dispatch("logout", null, null, null);
    const back = a.deps.group.?;
    try std.testing.expect(back != anon_group);
    try std.testing.expect(back.key.account_id == null);
    try std.testing.expectEqualStrings("Anon#1", back.key.name);
    try std.testing.expect(a.membershipEpoch() == e0);
    try std.testing.expectEqual(@as(usize, 1), anon_group.members);
    try std.testing.expectEqual(@as(usize, 2), groups.registryCount());
}

test "delete actions: own-content delete end-to-end; foreign/anon rejected" {
    const alloc = std.testing.allocator;
    const mm = app.testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;

    const a = app.createSession(alloc, std.testing.io);
    defer a.deinit();
    const anon = app.createSession(alloc, std.testing.io);
    defer anon.deinit();

    // a registers → posts carry acct=1.
    var rf = app.fieldsOf(alloc, &.{
        .{ "name", "alice" },
        .{ "password", "password1" },
        .{ "confirm", "password1" },
    });
    defer rf.deinit(alloc);
    try a.dispatch("register", null, null, &rf);

    var pf = app.fieldsOf(alloc, &.{
        .{ "board", "b" },
        .{ "text", "owned post" },
    });
    defer pf.deinit(alloc);
    try a.dispatch("post", null, null, &pf);
    try std.testing.expectEqual(@as(?u64, 1), mm.posts.items[0].acct);
    const pid = mm.posts.items[0].id;

    var pf2 = app.fieldsOf(alloc, &.{
        .{ "board", "b" },
        .{ "text", "anon post" },
    });
    defer pf2.deinit(alloc);
    try anon.dispatch("post", null, null, &pf2);
    try std.testing.expect(mm.posts.items[1].acct == null);

    var idbuf: [24]u8 = undefined;
    const parg = std.fmt.bufPrint(&idbuf, "{d}", .{pid}) catch unreachable;

    // Anonymous session cannot delete the account's post.
    try std.testing.expectError(error.NotFound, anon.dispatch("delete_post", parg, null, null));
    // Malformed arg rejected before any model call.
    try std.testing.expectError(error.InvalidAction, a.dispatch("delete_post", "abc", null, null));
    try std.testing.expectError(error.InvalidAction, a.dispatch("delete_comment", null, null, null));

    // Owner deletes: post + its cascade path exercised model-side.
    try a.dispatch("delete_post", parg, null, null);
    try std.testing.expect(mm.post(pid) == null);
    try std.testing.expectEqual(@as(usize, 1), mm.posts.items.len);

    // Comment path: a comments on the anon post, then deletes it.
    var cf = app.fieldsOf(alloc, &.{
        .{ "post", "2" },
        .{ "text", "owned comment" },
    });
    defer cf.deinit(alloc);
    try a.dispatch("comment", null, null, &cf);
    const cid = mm.comments.items[0].id;
    try std.testing.expectEqual(@as(?u64, 1), mm.comments.items[0].acct);
    const carg = std.fmt.bufPrint(&idbuf, "{d}", .{cid}) catch unreachable;
    // The anon post's author can't delete a comments row they don't own
    // (and anon rows can't be deleted at all — model gate).
    try std.testing.expectError(error.NotFound, anon.dispatch("delete_comment", carg, null, null));
    try a.dispatch("delete_comment", carg, null, null);
    try std.testing.expect(mm.comment(cid) == null);
    try std.testing.expectEqual(@as(usize, 0), mm.comments.items.len);
}
