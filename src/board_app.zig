//! zboard — anonymous board app on the generic server: static boards,
//! threads, and nested tree comments over the shared BoardModel.
//!
//! Fan-out design: every session has its own zefx graph + DOM state, but
//! the model is global. Mutations bump `model.global_seq`; each session's
//! SSE worker calls `syncPull()` every 50 ms and re-renders (a no-op diff
//! for sessions whose route doesn't show the change), then publishes the
//! batch to that session's history — so one POST reaches every open tab.
const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const board = @import("board.zig");
const board_groups = @import("board_groups.zig");
const History = @import("server/history.zig").History;

/// The shared model, installed by board_main before serve(). All access
/// is serialized by the server's session mutex.
pub var model: ?*board.BoardModel = null;

fn m() *board.BoardModel {
    return model orelse @panic("board model not initialized");
}

/// Shared-model mutation counter — the render groups' dedup cursor.
pub fn globalSeq() u64 {
    return m().global_seq.load(.seq_cst);
}

/// Request routes: "/" home, "/b/<slug>", "/t/<post>", "/t/<post>/c/<comment>".
pub const Route = union(enum) {
    home,
    board: usize,
    thread: u64,
    comment: u64,
};

/// Everything the view tree reads from session/group state: route,
/// inline-reply target, the resolved `#who` display name, and the cursor
/// `buildView` marks caught-up — the session's `seen_seq` or the render
/// group's `last_rendered_seq`. Group members share one env's worth of
/// inputs; that identity IS the render-group key (see board_groups.zig).
pub const ViewEnv = struct {
    route: Route,
    reply_to: ?u64 = null,
    /// Resolved display name for the `#who` chip ("Anon#N" / "anon") —
    /// post/comment authors still resolve their own tokens via `nameOf`.
    name: []const u8 = "anon",
    /// Cursor `buildView` stamps with `global_seq` — written only by view
    /// builds that actually sync tracked Dom state (diff/seed), never by
    /// incidental SSR/snapshot serialization of an already-current group.
    seen: ?*u64 = null,
};

pub fn parseRoute(path: []const u8) ?Route {
    if (std.mem.eql(u8, path, "/")) return .home;
    if (std.mem.startsWith(u8, path, "/b/")) {
        const idx = board.boardIndex(path[3..]) orelse return null;
        return .{ .board = idx };
    }
    if (std.mem.startsWith(u8, path, "/t/")) {
        const rest = path[3..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const mid = rest[slash + 1 ..];
            if (!std.mem.startsWith(u8, mid, "c/")) return null;
            const post_id = std.fmt.parseInt(u64, rest[0..slash], 10) catch return null;
            const cid = std.fmt.parseInt(u64, mid[2..], 10) catch return null;
            _ = post_id; // the comment id is authoritative; post is derived
            return .{ .comment = cid };
        }
        const id = std.fmt.parseInt(u64, rest, 10) catch return null;
        return .{ .thread = id };
    }
    return null;
}

/// One browser session: route + reply target + user identity on top of an
/// isolated zefx graph and DOM patch state (same skeleton as todo.Session).
pub const Session = struct {
    /// Session contract for the generic server (see server/http.zig).
    pub const page_title = "zboard";
    pub const page_class = "app app-board";
    pub const cookie_name = "zfxb";
    pub const user_cookie_name = "zfxu";

    gpa: std.mem.Allocator,
    io: std.Io,
    app: zefx.App,

    route: Route = .home,
    /// Comment id the inline reply form is mounted under (per-session).
    reply_to: ?u64 = null,
    /// zfxu cookie value — the anonymous poster identity ("" = anonymous).
    user_token: []u8 = &.{},
    /// Scratch for the Set-Cookie value emitted on the minting POST.
    out_cookie_buf: [600]u8 = undefined,
    out_cookie: []const u8 = &.{},
    /// Last `model.global_seq` this session rendered — syncPull's cursor
    /// for UNGROUPED (never page-served) sessions; grouped sessions dedup
    /// on their group's `last_rendered_seq` instead.
    seen_seq: u64 = 0,
    /// Set by the first successful servePage — gates render grouping so
    /// sessions that never served a page keep the solo diff path.
    attached: bool = false,
    /// Render-group membership (board_groups.zig): sessions with equal
    /// (route, reply_to, resolved name) share one Dom/history/revision.
    group: ?*board_groups.RenderGroup = null,
    /// Bumped on every group join/leave/re-key — the SSE stream compares
    /// it per poll; ANY change forces a snapshot + revision adopt because
    /// group-local revision numbers don't imply baseline equality (this
    /// also covers A→B→A between polls).
    membership_epoch: u64 = 0,

    ping: *zefx.Event(Ping),
    seq: *zefx.Store(u64),

    dom: forest.Dom,
    log: forest.PatchLog,
    history: History,
    render_arena: std.heap.ArenaAllocator,
    csrf_token: []u8 = &.{},
    /// Store-stamped incarnation (see the Session contract in
    /// server/http.zig): distinguishes this session from a previous one
    /// evicted+recreated under the same (cookie token, route) key.
    incarnation: u64 = 0,

    const Ping = struct {};

    pub fn create(gpa: std.mem.Allocator, io: std.Io) *Session {
        return createSession(gpa, io);
    }

    pub fn deinit(self: *Session) void {
        // Release group membership first — the last leaver destroys the
        // group; eviction must not corrupt shared group state.
        if (self.group) |g| board_groups.leave(self.gpa, g);
        self.group = null;
        if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
        if (self.user_token.len != 0) self.gpa.free(self.user_token);
        self.dom.deinit();
        self.log.deinit();
        self.history.deinit();
        self.render_arena.deinit();
        self.app.deinit();
        self.gpa.destroy(self);
    }

    pub fn setCsrf(self: *Session, token: []u8) void {
        if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
        self.csrf_token = token;
    }

    /// Pick up the `zfxu` user cookie before dispatch (called by the
    /// server with the raw Cookie header on every /action POST).
    pub fn readCookies(self: *Session, cookie_hdr: ?[]const u8) void {
        const h = cookie_hdr orelse return;
        var it = std.mem.splitScalar(u8, h, ';');
        while (it.next()) |part| {
            const kv = std.mem.trim(u8, part, " \t");
            const prefix = user_cookie_name ++ "=";
            if (std.mem.startsWith(u8, kv, prefix)) {
                const v = kv[prefix.len..];
                if (v.len != 0 and self.user_token.len == 0) {
                    self.user_token = self.gpa.dupe(u8, v) catch @panic("OOM");
                }
                return;
            }
        }
    }

    /// Every POST needs a resolvable identity: mint on first contact, or
    /// heal a cookie token that has no users row (db reset / forged).
    fn ensureUser(self: *Session) !void {
        if (self.user_token.len == 0) {
            var rb: [16]u8 = undefined;
            self.io.random(&rb);
            const tok = std.fmt.allocPrint(self.gpa, "{x}", .{std.mem.readInt(u64, rb[0..8], .little)}) catch @panic("OOM");
            errdefer self.gpa.free(tok);
            _ = try m().ensureUser(tok);
            self.out_cookie = std.fmt.bufPrint(&self.out_cookie_buf, "{s}={s}; Path=/; SameSite=Lax", .{ user_cookie_name, tok }) catch @panic("cookie buf too small");
            self.user_token = tok;
            return;
        }
        if (m().userName(self.user_token) == null) {
            _ = try m().ensureUser(self.user_token);
        }
    }

    // ── routing ────────────────────────────────────────────────────

    pub fn validPath(path: []const u8) bool {
        return parseRoute(path) != null;
    }

    pub fn setRoute(self: *Session, path: []const u8) bool {
        const r = parseRoute(path) orelse return false;
        // Well-formed but dangling ids get a real 404, not an empty page.
        switch (r) {
            .thread => |pid| if (m().post(pid) == null) return false,
            .comment => |cid| if (m().comment(cid) == null) return false,
            else => {},
        }
        self.route = r;
        self.reply_to = null;
        return true;
    }

    /// Full-page render for a navigating client: resolve the route, sync
    /// render-group membership, bring the group current with the model,
    /// then write the page body. The shared group Dom is NEVER reset or
    /// reseeded here — a fresh group was seeded privately at join, and an
    /// existing group's Dom already matches the view this page ships.
    pub fn servePage(self: *Session, path: []const u8, writer: anytype) !bool {
        if (!self.setRoute(path)) return false;
        self.attached = true;
        self.syncMembership();
        self.ensureGroupCurrent();
        try self.writeView(writer);
        return true;
    }

    /// SSE-worker hook: when the shared model moved past what the session
    /// (or its group) last rendered, ping → flush → render. Grouped
    /// sessions dedup on the GROUP's `last_rendered_seq`, so N members on
    /// one group cost one buildView+diff per model version.
    pub fn syncPull(self: *Session) void {
        const rendered = if (self.group) |g| g.last_rendered_seq else self.seen_seq;
        if (m().global_seq.load(.seq_cst) == rendered) return;
        self.ping.emit(.{});
    }

    // ── render groups ──────────────────────────────────────────────

    /// The session's current group-key inputs — recomputed on every
    /// render so an identity minted by a (possibly failed) dispatch is
    /// picked up BEFORE the group is chosen/rendered.
    fn groupKey(self: *Session) board_groups.Key {
        return .{ .route = self.route, .reply_to = self.reply_to, .name = nameOf(self.user_token) };
    }

    /// Join/migrate the render group when the key changed. Bumps
    /// `membership_epoch` on every actual transition — the SSE stream
    /// treats any bump as "send a snapshot and adopt the new revision",
    /// since patch revisions are group-local.
    fn syncMembership(self: *Session) void {
        if (!self.attached) return;
        const key = self.groupKey();
        var kbuf: [256]u8 = undefined;
        const ks = board_groups.keyStringInto(&kbuf, key.route, key.reply_to, key.name);
        if (self.group) |g| {
            if (std.mem.eql(u8, g.key_string, ks)) return;
            board_groups.leave(self.gpa, g);
            self.group = null;
        }
        self.group = board_groups.join(self.gpa, key);
        self.membership_epoch +%= 1;
    }

    /// Bring the group current with the shared model — render+publish
    /// when `global_seq` moved. servePage calls this BEFORE writing SSR
    /// so the group's tracked Dom always matches the shipped page.
    fn ensureGroupCurrent(self: *Session) void {
        const g = self.group orelse return;
        g.render(); // no-op when last_rendered_seq == global_seq
        g.publish(); // no-op when nothing pending
    }

    fn viewEnv(self: *Session) ViewEnv {
        return .{
            .route = self.route,
            .reply_to = self.reply_to,
            .name = nameOf(self.user_token),
            .seen = &self.seen_seq,
        };
    }

    // ── optional server contract (grouped sessions) ────────────────
    // See the Session contract in server/http.zig: sessions WITHOUT
    // these decls keep the legacy per-session publish/fetch path.

    /// Drain the pending rendered batch into retained history. Grouped
    /// sessions publish through their group (the render hook already did
    /// — this is the safety net); unattached sessions keep the inline
    /// log→history path the generic server used before grouping.
    pub fn publishPending(self: *Session) void {
        if (self.group) |g| {
            g.publish();
            return;
        }
        if (self.seq.get() <= self.history.latest_rev) {
            self.log.clear();
            return;
        }
        var jaw: std.Io.Writer.Allocating = .init(self.gpa);
        defer jaw.deinit();
        self.log.writeJson(&jaw.writer) catch @panic("OOM");
        self.history.publish(self.seq.get(), jaw.toOwnedSlice() catch @panic("OOM"));
        self.log.clear();
    }

    /// Revision subscribers (SSE cursor, snapshot `rev`, ACK) should
    /// track — the group's local revision when grouped, else `seq`.
    pub fn streamRev(self: *Session) u64 {
        return if (self.group) |g| g.rev else self.seq.get();
    }

    /// History ring subscribers fetch from — the group's when grouped.
    pub fn streamHistory(self: *Session) *History {
        return if (self.group) |g| &g.history else &self.history;
    }

    /// Membership epoch for the SSE stream: bumped on every group
    /// join/leave/re-key; any change forces a snapshot + revision adopt.
    pub fn membershipEpoch(self: *Session) u64 {
        return self.membership_epoch;
    }

    // ── actions ────────────────────────────────────────────────────

    /// Whitelisted action entry point — same DOM event protocol as the
    /// todo app: `action`, `arg`, `value`, `fields`.
    pub fn dispatch(
        self: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        _ = value;
        // `out_cookie` is a one-shot: the server emits it on this response
        // only — later POSTs must not re-send the Set-Cookie header.
        self.out_cookie = "";
        // Every POST establishes identity on first contact.
        try self.ensureUser();

        if (std.mem.eql(u8, action, "post")) {
            const f = fields orelse return error.InvalidAction;
            const slug = fieldStr(f, "board") orelse return error.InvalidAction;
            const text = fieldStr(f, "text") orelse return error.InvalidAction;
            _ = try m().addPost(slug, self.user_token, text);
            self.ping.emit(.{});
        } else if (std.mem.eql(u8, action, "comment")) {
            const f = fields orelse return error.InvalidAction;
            const post_id = fieldU64(f, "post") orelse return error.InvalidAction;
            const parent = fieldU64(f, "parent");
            const text = fieldStr(f, "text") orelse return error.InvalidAction;
            _ = try m().addComment(post_id, parent, self.user_token, text);
            self.reply_to = null;
            self.ping.emit(.{});
        } else if (std.mem.eql(u8, action, "reply")) {
            const a = arg orelse return error.InvalidAction;
            const cid = std.fmt.parseInt(u64, a, 10) catch return error.InvalidAction;
            if (m().comment(cid) == null) return error.CommentNotFound;
            self.reply_to = cid;
            self.ping.emit(.{});
        } else if (std.mem.eql(u8, action, "cancel_reply")) {
            self.reply_to = null;
            self.ping.emit(.{});
        } else {
            return error.InvalidAction;
        }
    }

    // ── graph wiring (called once per session) ──────────────────────

    fn wire(self: *Session) void {
        const eng = &self.app.eng;

        // Pure-phase reducer: any ping bumps the revision; the after-flush
        // hook then renders the DOM diff into `self.log`.
        const PingCtx = struct { s: *Session };
        const pctx = self.gpa.create(PingCtx) catch @panic("OOM");
        pctx.* = .{ .s = self };
        self.ping.reducers.append(eng.allocator, .{
            .ctx = @ptrCast(pctx),
            .trigger = &struct {
                fn trig(raw: *anyopaque, _: *const anyopaque) void {
                    const c: *PingCtx = @ptrCast(@alignCast(raw));
                    c.s.seq.set(c.s.seq.get() + 1);
                }
            }.trig,
        }) catch @panic("OOM");
        eng.trackGraphAlloc(@ptrCast(pctx), &struct {
            fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                a.destroy(@as(*PingCtx, @ptrCast(@alignCast(p))));
            }
        }.dtor);

        // After every flush the graph is fully settled → render DOM diff.
        eng.onAfterFlush(.{
            .ctx = @ptrCast(self),
            .call = &struct {
                fn render(raw: *anyopaque) void {
                    const s: *Session = @ptrCast(@alignCast(raw));
                    s.render();
                }
            }.render,
        });
    }

    // ── rendering ───────────────────────────────────────────────────

    fn render(self: *Session) void {
        if (self.attached) {
            // Grouped path: re-key first (reply_to/identity may have
            // changed inside dispatch), then render+publish through the
            // group — deduped on `last_rendered_seq`, so member pings
            // after the first see the group already current.
            self.syncMembership();
            if (self.group) |g| {
                g.render();
                g.publish();
                return;
            }
        }
        // Solo path: sessions that never served a page (tests, dead
        // routes) keep the original per-session diff.
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        forest.diff(a, buildView(a, self.viewEnv()), &self.dom, &self.log);
        self.log.revision = self.seq.get();
    }

    /// Render the `<main>` inner content — used by the initial page.
    pub fn writeView(self: *Session, writer: anytype) !void {
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        try forest.writeHtml(a, buildView(a, self.viewEnv()), writer);
    }

    /// The session's current view nodes — the SSE snapshot writer
    /// serializes them via `forest.writeSnapshotOps`.
    pub fn buildViewNodes(self: *Session, a: std.mem.Allocator) []const forest.Node {
        return buildView(a, self.viewEnv());
    }

    /// Seed tracked DOM state to match markup already emitted in the page,
    /// so the first diff renders only real changes. Solo-path helper —
    /// grouped sessions never call this (the group's Dom is seeded at
    /// join and synced by render, never reset).
    pub fn seedDom(self: *Session) void {
        self.render();
        self.log.clear();
    }
};

// ── field helpers ─────────────────────────────────────────────────

fn fieldStr(f: *const std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = f.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn fieldU64(f: *const std.json.ObjectMap, name: []const u8) ?u64 {
    const v = f.get(name) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

// ── view helpers ──────────────────────────────────────────────────

fn nameOf(token: []const u8) []const u8 {
    if (token.len == 0) return "anon";
    return m().userName(token) orelse "anon";
}

fn fmtTs(a: std.mem.Allocator, ts: i64) []const u8 {
    const secs = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = secs.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = secs.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>2}.{d:0>2} {d:0>2}:{d:0>2}", .{
        md.day_index + 1, md.month.numeric(), ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch @panic("OOM");
}

fn boardHref(a: std.mem.Allocator, slug: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "/b/{s}", .{slug}) catch @panic("OOM");
}

fn threadHref(a: std.mem.Allocator, post_id: u64) []const u8 {
    return std.fmt.allocPrint(a, "/t/{d}", .{post_id}) catch @panic("OOM");
}

fn commentHref(a: std.mem.Allocator, post_id: u64, cid: u64) []const u8 {
    return std.fmt.allocPrint(a, "/t/{d}/c/{d}", .{ post_id, cid }) catch @panic("OOM");
}

// ── view components ───────────────────────────────────────────────

/// Sidebar: real links (full navigation) + the poster identity chip.
fn navView(a: std.mem.Allocator, env: ViewEnv) forest.Node {
    var links: std.ArrayListUnmanaged(forest.Node) = .empty;
    const home_on = env.route == .home;
    links.append(a, forest.el(a, .a, .{ .href = "/", .class = if (home_on) "on" else null }, "⌂")) catch @panic("OOM");
    for (board.boards, 0..) |b, i| {
        const on = switch (env.route) {
            .board => |bi| bi == i,
            else => false,
        };
        links.append(a, forest.el(a, .a, .{
            .href = boardHref(a, b.slug),
            .class = if (on) "on" else null,
        }, b.title)) catch @panic("OOM");
    }
    // Identity chip is bound (`#who` + .text) so the first POST's minted
    // "Anon#N" name patches in live. `env.name` is the RESOLVED display
    // name — identical for every member of a render group.
    links.append(a, forest.el(a, .span, .{ .id = "who", .class = "who", .text = env.name }, .{})) catch @panic("OOM");
    return forest.el(a, .div, .{ .class = "bnav" }, links.toOwnedSlice(a) catch @panic("OOM"));
}

/// Post card: #id, board, Anon, time, pre-wrap text, thread link with a
/// live comment count (diffed in place via `lid`).
fn postCard(a: std.mem.Allocator, p: *const board.Post, show_link: bool) forest.Node {
    const mm = m();
    const count = mm.commentCount(p.id);
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .div, .{ .class = "meta" }, .{
        forest.el(a, .span, .{ .class = "pid" }, std.fmt.allocPrint(a, "#{d}", .{p.id}) catch @panic("OOM")),
        forest.text(" · "),
        forest.el(a, .a, .{ .href = boardHref(a, p.board), .class = "bref" }, p.board),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "who" }, nameOf(p.user)),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "ts" }, fmtTs(a, p.ts)),
    })) catch @panic("OOM");
    kids.append(a, forest.el(a, .div, .{ .class = "ptext" }, p.text)) catch @panic("OOM");
    if (show_link) {
        kids.append(a, forest.el(a, .div, .{ .class = "actions" }, .{
            forest.el(a, .a, .{
                .lid = "go",
                .href = threadHref(a, p.id),
                .text = std.fmt.allocPrint(a, "→ тред ({d})", .{count}) catch @panic("OOM"),
            }, .{}),
        })) catch @panic("OOM");
    }
    return forest.el(a, .div, .{
        .id = std.fmt.allocPrint(a, "post-{d}", .{p.id}) catch @panic("OOM"),
        .class = "post",
    }, kids.toOwnedSlice(a) catch @panic("OOM"));
}

/// New-post form: hidden `board` field + textarea; `post` action.
fn postForm(a: std.mem.Allocator, slug: []const u8) forest.Node {
    return forest.el(a, .form, .{
        .id = "post-form",
        .class = "post-form",
        .autocomplete = "off",
        .on = .{ .submit = "post" },
    }, .{
        forest.el(a, .input, .{ .type = "hidden", .name = "board", .value = slug }, .{}),
        forest.el(a, .textarea, .{
            .name = "text",
            .placeholder = "Текст поста…",
            .rows = "4",
            .maxlength = board.max_text_len,
            .autofocus = true,
        }, .{}),
        forest.el(a, .button, .{ .type = "submit" }, "Запостить"),
    });
}

/// Format a u64 id once per use site — shared by `data-arg`, hidden
/// `value`s and `#N` labels instead of a `{d}` fmt per binding per render.
fn u64str(a: std.mem.Allocator, v: u64) []const u8 {
    var buf: [24]u8 = undefined;
    return a.dupe(u8, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable) catch @panic("OOM");
}

/// Comment form: hidden `post` (+ optional `parent`) + text input.
fn commentFormNodes(a: std.mem.Allocator, post_str: []const u8, parent_str: ?[]const u8, is_inline: bool) []const forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .input, .{ .type = "hidden", .name = "post", .value = post_str }, .{})) catch @panic("OOM");
    if (parent_str) |ps| {
        kids.append(a, forest.el(a, .input, .{ .type = "hidden", .name = "parent", .value = ps }, .{})) catch @panic("OOM");
    }
    if (is_inline) {
        kids.append(a, forest.el(a, .input, .{
            .name = "text",
            .placeholder = "Ответить…",
            .maxlength = board.max_text_len,
            .autofocus = true,
        }, .{})) catch @panic("OOM");
        kids.append(a, forest.el(a, .button, .{ .type = "submit", .class = "mini" }, "→")) catch @panic("OOM");
        kids.append(a, forest.el(a, .button, .{
            .type = "button",
            .class = "mini cancel",
            .on = .{ .click = "cancel_reply" },
        }, "×")) catch @panic("OOM");
    } else {
        kids.append(a, forest.el(a, .textarea, .{
            .name = "text",
            .placeholder = "Комментарий…",
            .rows = "3",
            .maxlength = board.max_text_len,
            .autofocus = true,
        }, .{})) catch @panic("OOM");
        kids.append(a, forest.el(a, .button, .{ .type = "submit" }, "Комментировать")) catch @panic("OOM");
    }
    return kids.toOwnedSlice(a) catch @panic("OOM");
}

fn commentForm(a: std.mem.Allocator, post_id: u64, parent_id: ?u64) forest.Node {
    const post_str = u64str(a, post_id);
    const parent_str = if (parent_id) |pid| u64str(a, pid) else null;
    return forest.el(a, .form, .{
        .class = "comment-form",
        .autocomplete = "off",
        .on = .{ .submit = "comment" },
    }, commentFormNodes(a, post_str, parent_str, false));
}

/// Inline reply form mounted under comment `c` via the `w-rep-N` anchor.
fn replyForm(a: std.mem.Allocator, post_str: []const u8, parent_str: []const u8) forest.Node {
    return forest.el(a, .form, .{
        .class = "reply-form",
        .autocomplete = "off",
        .on = .{ .submit = "comment" },
    }, commentFormNodes(a, post_str, parent_str, true));
}

/// One comment node: meta (id, Anon, time, «ответить»), text, the inline
/// reply `when` anchor, and a nested keyed `<ul>` of children.
/// `post_str` is the thread's post id pre-formatted once per view.
fn commentNode(a: std.mem.Allocator, env: ViewEnv, c: *const board.Comment, post_str: []const u8) forest.Node {
    const mm = m();
    const id_str = std.fmt.allocPrint(a, "cm-{d}", .{c.id}) catch @panic("OOM");
    const rep_id = std.fmt.allocPrint(a, "w-rep-{d}", .{c.id}) catch @panic("OOM");
    const replying = env.reply_to != null and env.reply_to.? == c.id;
    const num = u64str(a, c.id);
    const hash = std.fmt.allocPrint(a, "#{d}", .{c.id}) catch @panic("OOM");

    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .div, .{ .class = "cmeta" }, .{
        // #id doubles as the permalink to the comment page.
        forest.el(a, .a, .{
            .class = "plink",
            .href = commentHref(a, c.post, c.id),
        }, hash),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "who" }, nameOf(c.user)),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "ts" }, fmtTs(a, c.ts)),
        forest.text(" "),
        forest.el(a, .button, .{
            .class = "reply-btn",
            .on = .{ .click = "reply" },
            .arg = num,
        }, "ответить"),
    })) catch @panic("OOM");
    kids.append(a, forest.el(a, .div, .{ .class = "ctext" }, c.text)) catch @panic("OOM");
    // Inline reply form mounts between the text and the children list.
    kids.append(a, forest.when(a, .{ .id = rep_id }, replying, replyForm(a, post_str, num))) catch @panic("OOM");

    const kid_idx = mm.childIdx(a, c.id) catch @panic("OOM");
    var ck: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (kid_idx) |ci| {
        ck.append(a, commentNode(a, env, &mm.comments.items[ci], post_str)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .ul, .{ .lid = "kids", .class = "kids" }, forest.each(ck.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");

    return forest.el(a, .li, .{ .id = id_str, .class = "comment" }, kids.toOwnedSlice(a) catch @panic("OOM"));
}

fn crumbsView(a: std.mem.Allocator, post: *const board.Post, chain: []const u64) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .a, .{ .href = boardHref(a, post.board), .class = "bref" }, post.board)) catch @panic("OOM");
    kids.append(a, forest.text(" › ")) catch @panic("OOM");
    kids.append(a, forest.el(a, .a, .{ .href = threadHref(a, post.id) }, std.fmt.allocPrint(a, "#{d}", .{post.id}) catch @panic("OOM"))) catch @panic("OOM");
    for (chain, 0..) |cid, i| {
        kids.append(a, forest.text(" › ")) catch @panic("OOM");
        const is_last = i + 1 == chain.len;
        const label = std.fmt.allocPrint(a, "#{d}", .{cid}) catch @panic("OOM");
        if (is_last) {
            kids.append(a, forest.el(a, .span, .{ .class = "cid" }, label)) catch @panic("OOM");
        } else {
            kids.append(a, forest.el(a, .a, .{ .href = commentHref(a, post.id, cid) }, label)) catch @panic("OOM");
        }
    }
    return forest.el(a, .div, .{ .class = "crumbs" }, kids.toOwnedSlice(a) catch @panic("OOM"));
}

fn notFoundView(a: std.mem.Allocator, what: []const u8) forest.Node {
    return forest.el(a, .p, .{ .class = "empty", .id = "not-found" }, what);
}

// ── routes ────────────────────────────────────────────────────────

fn homeView(a: std.mem.Allocator) forest.Node {
    const mm = m();
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .h1, .{}, .{
        forest.text("z"),
        forest.el(a, .span, .{}, "board"),
    })) catch @panic("OOM");
    kids.append(a, forest.el(a, .p, .{ .class = "boards-label" }, "Доски:")) catch @panic("OOM");
    var bl: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (board.boards) |b| {
        bl.append(a, forest.el(a, .li, .{}, forest.el(a, .a, .{ .href = boardHref(a, b.slug) }, b.title))) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .ul, .{ .class = "board-list" }, bl.toOwnedSlice(a) catch @panic("OOM"))) catch @panic("OOM");
    kids.append(a, forest.el(a, .h2, .{}, "Последнее:")) catch @panic("OOM");

    const latest_idx = mm.latestPostIdx(a, board.latest_home_count) catch @panic("OOM");
    var lp: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (latest_idx) |pi| {
        lp.append(a, postCard(a, &mm.posts.items[pi], true)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .div, .{ .id = "latest", .class = "posts" }, forest.each(lp.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    kids.append(a, forest.when(a, .{ .id = "w-latest-empty" }, latest_idx.len == 0, forest.el(a, .p, .{ .class = "empty" }, "Пока пусто — напиши первым пост."))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}

fn boardView(a: std.mem.Allocator, idx: usize) forest.Node {
    const b = board.boards[idx];
    const mm = m();
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .h1, .{}, b.title)) catch @panic("OOM");
    kids.append(a, postForm(a, b.slug)) catch @panic("OOM");

    const pidx = mm.boardPostIdx(a, b.slug) catch @panic("OOM");
    var pk: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (pidx) |pi| {
        pk.append(a, postCard(a, &mm.posts.items[pi], true)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .div, .{ .id = "posts", .class = "posts" }, forest.each(pk.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    kids.append(a, forest.when(a, .{ .id = "w-board-empty" }, pidx.len == 0, forest.el(a, .p, .{ .class = "empty", .id = "empty-posts" }, "Пока пусто — напиши первым пост."))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}

fn threadView(a: std.mem.Allocator, env: ViewEnv, post_id: u64) forest.Node {
    const mm = m();
    const p = mm.post(post_id) orelse {
        return notFoundView(a, "Тред не найден.");
    };
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, crumbsView(a, p, &[_]u64{})) catch @panic("OOM");
    kids.append(a, postCard(a, p, false)) catch @panic("OOM");
    kids.append(a, commentForm(a, post_id, null)) catch @panic("OOM");

    const tops = mm.topCommentIdx(a, post_id) catch @panic("OOM");
    const post_str = u64str(a, post_id);
    var ck: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (tops) |ci| {
        ck.append(a, commentNode(a, env, &mm.comments.items[ci], post_str)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .ul, .{ .id = "comments", .class = "comments" }, forest.each(ck.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    kids.append(a, forest.when(a, .{ .id = "w-comments-empty" }, tops.len == 0, forest.el(a, .p, .{ .class = "empty" }, "Нет комментариев — будь первым."))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}

fn commentView(a: std.mem.Allocator, env: ViewEnv, cid: u64) forest.Node {
    const mm = m();
    const c = mm.comment(cid) orelse {
        return notFoundView(a, "Комментарий не найден.");
    };
    const p = mm.post(c.post) orelse {
        return notFoundView(a, "Тред не найден.");
    };
    // Ancestor chain root→…→c (excluding c itself — it renders as root).
    var chain_rev: std.ArrayListUnmanaged(u64) = .empty;
    var cur: ?u64 = c.parent;
    while (cur) |pid| {
        const pc = mm.comment(pid) orelse break;
        chain_rev.append(a, pid) catch @panic("OOM");
        cur = pc.parent;
    }
    std.mem.reverse(u64, chain_rev.items);
    // The focused comment closes the crumb trail as a plain label.
    chain_rev.append(a, cid) catch @panic("OOM");

    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, crumbsView(a, p, chain_rev.items)) catch @panic("OOM");
    kids.append(a, commentForm(a, p.id, null)) catch @panic("OOM");
    // Arena-allocate the single-row slice — a `&.{…}` temporary would
    // dangle once the statement ends (the keyed list outlives it).
    const only = a.alloc(forest.Node, 1) catch @panic("OOM");
    only[0] = commentNode(a, env, c, u64str(a, p.id));
    kids.append(a, forest.el(a, .ul, .{ .id = "comments", .class = "comments" }, forest.each(only))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}

/// The `<main>` inner content: sidebar + the active route's page.
/// `env.seen` is the caught-up cursor — every shipped view marks it
/// synced to the shared model's mutation counter (the session's
/// `seen_seq`, or a render group's `last_rendered_seq` on group
/// seed/render builds only).
pub fn buildView(a: std.mem.Allocator, env: ViewEnv) []const forest.Node {
    if (env.seen) |p| p.* = m().global_seq.load(.seq_cst);
    const content = switch (env.route) {
        .home => homeView(a),
        .board => |i| boardView(a, i),
        .thread => |pid| threadView(a, env, pid),
        .comment => |cid| commentView(a, env, cid),
    };
    const nodes = a.alloc(forest.Node, 2) catch @panic("OOM");
    nodes[0] = navView(a, env);
    nodes[1] = forest.el(a, .div, .{ .class = "bmain" }, content);
    return nodes;
}

/// Wired session constructor.
pub fn createSession(gpa: std.mem.Allocator, io: std.Io) *Session {
    const s = gpa.create(Session) catch @panic("OOM");
    s.* = .{
        .gpa = gpa,
        .io = io,
        .app = zefx.createApp(gpa),
        .ping = undefined,
        .seq = undefined,
        .dom = forest.Dom.init(gpa),
        .log = forest.PatchLog.init(gpa),
        .history = History.init(gpa),
        .render_arena = std.heap.ArenaAllocator.init(gpa),
    };
    s.ping = s.app.createEvent(Session.Ping);
    s.seq = s.app.createStore(u64, 0);
    s.wire();
    return s;
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

fn testModel(alloc: std.mem.Allocator) *board.BoardModel {
    const mm = board.BoardModel.init(alloc, ":memory:") catch @panic("model init failed");
    return mm;
}

fn patchJson(s: *Session, alloc: std.mem.Allocator) []u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    s.log.writeJson(&aw.writer) catch @panic("OOM");
    s.log.clear();
    return aw.toOwnedSlice() catch @panic("OOM");
}

fn fieldsOf(alloc: std.mem.Allocator, kvs: []const struct { []const u8, []const u8 }) std.json.ObjectMap {
    var f: std.json.ObjectMap = .empty;
    for (kvs) |kv| {
        f.put(alloc, kv[0], .{ .string = kv[1] }) catch @panic("OOM");
    }
    return f;
}

fn viewStr(s: *Session, alloc: std.mem.Allocator) []u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    s.writeView(&aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

test "route parsing covers home/board/thread/comment and rejects junk" {
    const home = parseRoute("/") orelse return error.TestUnexpectedResult;
    try std.testing.expect(home == .home);

    const bd = parseRoute("/b/b") orelse return error.TestUnexpectedResult;
    switch (bd) {
        .board => |i| try std.testing.expectEqual(@as(usize, 0), i),
        else => return error.TestUnexpectedResult,
    }
    const tt = parseRoute("/b/tech") orelse return error.TestUnexpectedResult;
    switch (tt) {
        .board => |i| try std.testing.expectEqual(board.boardIndex("tech").?, i),
        else => return error.TestUnexpectedResult,
    }
    const th = parseRoute("/t/7") orelse return error.TestUnexpectedResult;
    switch (th) {
        .thread => |id| try std.testing.expectEqual(@as(u64, 7), id),
        else => return error.TestUnexpectedResult,
    }
    const cm = parseRoute("/t/7/c/9") orelse return error.TestUnexpectedResult;
    switch (cm) {
        .comment => |id| try std.testing.expectEqual(@as(u64, 9), id),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(parseRoute("/b/nope") == null);
    try std.testing.expect(parseRoute("/t/abc") == null);
    try std.testing.expect(parseRoute("/t/1/x/2") == null);
    try std.testing.expect(parseRoute("/nope") == null);
    try std.testing.expect(parseRoute("/t/") == null);
    try std.testing.expect(parseRoute("") == null);
}

test "setRoute/servePage reset dom, SSR per route, and 404 dangling ids" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;
    _ = try mm.addPost("b", "tok1", "a post");

    const s = createSession(alloc, std.testing.io);
    defer s.deinit();

    // Home SSR: board list + empty-state anchor markers.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.testing.expect(try s.servePage("/", &aw.writer));
    const page = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, page, "z-when:w-latest-empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "/b/tech") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"post-1\"") != null);

    // Unknown path and dangling thread id both rejected.
    try std.testing.expect(!s.setRoute("/bogus"));
    try std.testing.expect(!s.setRoute("/t/999"));
    try std.testing.expect(!s.setRoute("/t/1/c/999"));
    try std.testing.expect(s.setRoute("/t/1"));

    // servePage on the board route ships the post form.
    _ = aw.writer.consumeAll();
    try std.testing.expect(try s.servePage("/b/b", &aw.writer));
    const bpage = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bpage, "data-on-submit=\"post\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bpage, "name=\"board\" value=\"b\"") != null);
}

test "post/comment actions mutate the shared model; reply_to is per-session" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    const a = createSession(alloc, std.testing.io);
    defer a.deinit();
    const b = createSession(alloc, std.testing.io);
    defer b.deinit();

    // First POST mints a user + a one-shot out_cookie; the next POST
    // neither remints a user nor re-sends the cookie.
    var f: std.json.ObjectMap = .empty;
    defer f.deinit(alloc);
    try f.put(alloc, "board", .{ .string = "b" });
    try f.put(alloc, "text", .{ .string = "hello <b>board</b>" });
    try a.dispatch("post", null, null, &f);
    try std.testing.expect(a.user_token.len != 0);
    try std.testing.expect(std.mem.startsWith(u8, a.out_cookie, "zfxu="));
    try std.testing.expectEqualStrings("Anon#1", mm.userName(a.user_token).?);
    try a.dispatch("post", null, null, &f);
    try std.testing.expectEqual(@as(usize, 0), a.out_cookie.len);
    try std.testing.expectEqual(@as(usize, 1), mm.users.count());
    try std.testing.expectEqual(@as(usize, 2), mm.posts.items.len);

    // reply_to is per-session.
    var cf: std.json.ObjectMap = .empty;
    defer cf.deinit(alloc);
    try cf.put(alloc, "post", .{ .string = "1" });
    try cf.put(alloc, "text", .{ .string = "top comment" });
    try b.dispatch("comment", null, null, &cf);
    const c1 = mm.comments.items[0].id;
    var idbuf: [24]u8 = undefined;
    const arg = std.fmt.bufPrint(&idbuf, "{d}", .{c1}) catch unreachable;
    try a.dispatch("reply", arg, null, null);
    try std.testing.expectEqual(@as(?u64, c1), a.reply_to);
    try std.testing.expect(b.reply_to == null);
    try a.dispatch("cancel_reply", null, null, null);
    try std.testing.expect(a.reply_to == null);

    // Nested reply via the parent field.
    var rf: std.json.ObjectMap = .empty;
    defer rf.deinit(alloc);
    try rf.put(alloc, "post", .{ .string = "1" });
    try rf.put(alloc, "parent", .{ .string = arg });
    try rf.put(alloc, "text", .{ .string = "nested!" });
    try a.dispatch("comment", null, null, &rf);
    try std.testing.expectEqual(@as(usize, 2), mm.comments.items.len);
    try std.testing.expectEqual(c1, mm.comments.items[1].parent.?);

    // Invalid input rejected.
    try std.testing.expectError(error.InvalidAction, a.dispatch("hack", null, null, null));
    try std.testing.expectError(error.InvalidAction, a.dispatch("post", null, null, null));
    var bad: std.json.ObjectMap = .empty;
    defer bad.deinit(alloc);
    try bad.put(alloc, "board", .{ .string = "nope" });
    try bad.put(alloc, "text", .{ .string = "x" });
    try std.testing.expectError(error.UnknownBoard, a.dispatch("post", null, null, &bad));
    var cf2: std.json.ObjectMap = .empty;
    defer cf2.deinit(alloc);
    try cf2.put(alloc, "post", .{ .string = "999" });
    try cf2.put(alloc, "text", .{ .string = "x" });
    try std.testing.expectError(error.PostNotFound, a.dispatch("comment", null, null, &cf2));
}

test "thread SSR emits nested keyed comment trees and reply anchors" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    _ = try mm.addPost("b", "tok1", "root post");
    const c1 = try mm.addComment(1, null, "tok1", "first");
    const c2 = try mm.addComment(1, c1.id, "tok1", "child of first");
    _ = try mm.addComment(1, c2.id, "tok1", "grandchild");

    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    try std.testing.expect(s.setRoute("/t/1"));
    const page = viewStr(s, alloc);
    defer alloc.free(page);

    // Nested keyed parents: comments > cm-N/kids > cm-M/kids.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"comments\"") != null);
    var want: [32]u8 = undefined;
    const kids_id = std.fmt.bufPrint(&want, "id=\"cm-{d}/kids\"", .{c1.id}) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, page, kids_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\"cm-") != null);
    // Reply anchors present but unmounted; no reply form in SSR.
    try std.testing.expect(std.mem.indexOf(u8, page, "z-when:w-rep-") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "reply-form") == null);
    // Permalink hrefs to comment pages exist.
    try std.testing.expect(std.mem.indexOf(u8, page, "/t/1/c/") != null);

    // Mount the reply form via the action → a `when` op ships markup.
    var idbuf: [24]u8 = undefined;
    const arg = std.fmt.bufPrint(&idbuf, "{d}", .{c1.id}) catch unreachable;
    try s.dispatch("reply", arg, null, null);
    const j = patchJson(s, alloc);
    defer alloc.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"op\":\"when\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "reply-form") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "parent") != null);
    // Reply state is per-session: a second session sees no when op.
    const s2 = createSession(alloc, std.testing.io);
    defer s2.deinit();
    s2.seedDom();
    s2.syncPull(); // seedDom already synced seen_seq → no render at all
    try std.testing.expectEqual(@as(usize, 0), s2.log.patches.items.len);
}

test "comment page breadcrumbs walk the parent chain; focused subtree only" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    _ = try mm.addPost("tech", "tok1", "p");
    const c1 = try mm.addComment(1, null, "tok1", "root c");
    const c2 = try mm.addComment(1, c1.id, "tok1", "mid c");
    const c3 = try mm.addComment(1, c2.id, "tok1", "leaf c");

    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    var pathbuf: [48]u8 = undefined;
    const cpath = std.fmt.bufPrint(&pathbuf, "/t/1/c/{d}", .{c3.id}) catch unreachable;
    try std.testing.expect(s.setRoute(cpath));
    const page = viewStr(s, alloc);
    defer alloc.free(page);

    // Crumbs: board › #post › #c1 › #c2 › #c3(last, plain label).
    try std.testing.expect(std.mem.indexOf(u8, page, "class=\"crumbs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"/b/tech\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "href=\"/t/1\"") != null);
    var want: [48]u8 = undefined;
    const h1 = std.fmt.bufPrint(&want, "href=\"/t/1/c/{d}\"", .{c1.id}) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, page, h1) != null);
    const h2 = std.fmt.bufPrint(&want, "href=\"/t/1/c/{d}\"", .{c2.id}) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, page, h2) != null);
    // Only the focused comment renders as a tree node.
    const fkid = std.fmt.bufPrint(&want, "id=\"cm-{d}\"", .{c3.id}) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, page, fkid) != null);
    const other = std.fmt.bufPrint(&want, "id=\"cm-{d}\"", .{c1.id}) catch unreachable;
    try std.testing.expect(std.mem.indexOf(u8, page, other) == null);
}

test "syncPull re-renders only when global_seq moved" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    s.seedDom();

    // No mutation → syncPull is a no-op (seq unchanged, no patches).
    s.syncPull();
    try std.testing.expectEqual(@as(usize, 0), s.log.patches.items.len);
    try std.testing.expectEqual(@as(u64, 0), s.seq.get());

    // Another session's post bumps global_seq → syncPull renders patches.
    const other = createSession(alloc, std.testing.io);
    defer other.deinit();
    var f: std.json.ObjectMap = .empty;
    defer f.deinit(alloc);
    try f.put(alloc, "board", .{ .string = "b" });
    try f.put(alloc, "text", .{ .string = "fanout" });
    try other.dispatch("post", null, null, &f);
    alloc.free(patchJson(other, alloc)); // discard other's batch

    s.syncPull();
    const j = patchJson(s, alloc);
    defer alloc.free(j);
    try std.testing.expect(s.seq.get() > 0);
    try std.testing.expect(s.seen_seq == mm.global_seq.load(.seq_cst));
    // The home latest list picked up the new post.
    try std.testing.expect(std.mem.indexOf(u8, j, "post-") != null);
}

test "comment on another session patches the board counter live" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    _ = try mm.addPost("b", "tok1", "thread post");
    // Board-index session already rendered (SSR-equivalent seed).
    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    try std.testing.expect(s.setRoute("/b/b"));
    s.seedDom();
    alloc.free(patchJson(s, alloc)); // discard the seed batch

    // Another session comments on the thread → global_seq bumps.
    const other = createSession(alloc, std.testing.io);
    defer other.deinit();
    var f: std.json.ObjectMap = .empty;
    defer f.deinit(alloc);
    try f.put(alloc, "post", .{ .string = "1" });
    try f.put(alloc, "text", .{ .string = "hi" });
    try other.dispatch("comment", null, null, &f);
    alloc.free(patchJson(other, alloc));

    s.syncPull();
    const j = patchJson(s, alloc);
    defer alloc.free(j);
    // The live counter "→ тред (N)" is a bound text op on post-1/go —
    // any dynamic value must reach the diff, unbound content goes stale.
    try std.testing.expect(std.mem.indexOf(u8, j, "\"op\":\"text\",\"id\":\"post-1/go\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "тред (1)") != null);
}

test "identity minted by a failed POST fans out via global_seq" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    s.seedDom(); // #who renders "anon" for the empty user_token

    // First contact is an INVALID action: ensureUser still mints the
    // zfxu identity (a model mutation → global_seq bump) before the
    // action itself is rejected without ping.emit.
    try std.testing.expectError(error.InvalidAction, s.dispatch("hack", null, null, null));
    try std.testing.expect(s.user_token.len != 0);
    const seq1 = mm.global_seq.load(.seq_cst);
    try std.testing.expect(seq1 != 0);

    // The SSE path must pick the identity change up even though the
    // failed POST published no batch of its own — #who patches live.
    s.syncPull();
    const j = patchJson(s, alloc);
    defer alloc.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"op\":\"text\",\"id\":\"who\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "Anon#1") != null);

    // A second failed POST is an ensureUser no-op → no bump → no render.
    try std.testing.expectError(error.InvalidAction, s.dispatch("hack", null, null, null));
    try std.testing.expectEqual(seq1, mm.global_seq.load(.seq_cst));
    s.syncPull();
    try std.testing.expectEqual(@as(usize, 0), s.log.patches.items.len);
}

test "heal path: cookie token with no users row bumps global_seq on POST" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    s.seedDom();

    // Simulate a stale/forged zfxu cookie: token present, no users row.
    s.user_token = try alloc.dupe(u8, "tok-forged");
    const seq0 = mm.global_seq.load(.seq_cst);
    try std.testing.expectError(error.InvalidAction, s.dispatch("hack", null, null, null));
    try std.testing.expectEqualStrings("Anon#1", mm.userName("tok-forged").?);
    try std.testing.expect(mm.global_seq.load(.seq_cst) > seq0);
}

// ── render groups ─────────────────────────────────────────────────

fn serveBoth(alloc: std.mem.Allocator, a: *Session, b: *Session, path: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.testing.expect(try a.servePage(path, &aw.writer));
    _ = aw.writer.consumeAll();
    try std.testing.expect(try b.servePage(path, &aw.writer));
}

test "render groups: equal keys share one group; one render per model bump" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    const a = createSession(alloc, std.testing.io);
    defer a.deinit();
    const b = createSession(alloc, std.testing.io);
    defer b.deinit();
    try serveBoth(alloc, a, b, "/");

    // Same (route, reply_to=null, name="anon") → same group, 2 members.
    const g = a.group.?;
    try std.testing.expect(a.group.? == b.group.?);
    try std.testing.expectEqual(@as(usize, 2), g.members);
    try std.testing.expectEqual(@as(u64, 0), g.rev); // seeded, nothing published
    try std.testing.expectEqual(@as(usize, 1), board_groups.registryCount());

    // Model bump → the FIRST member's syncPull renders+publishes once;
    // the second sees last_rendered_seq already current — dedup proof:
    // rev (one per render) advances by exactly 1 for two sessions.
    _ = try mm.addPost("b", "tok1", "grouped post");
    a.syncPull();
    try std.testing.expectEqual(@as(u64, 1), g.rev);
    try std.testing.expectEqual(g.rev, g.history.latest_rev);
    b.syncPull();
    try std.testing.expectEqual(@as(u64, 1), g.rev);

    // Both members track the group's revision + history ring.
    try std.testing.expectEqual(g.rev, a.streamRev());
    try std.testing.expectEqual(g.rev, b.streamRev());
    try std.testing.expect(a.streamHistory() == b.streamHistory());
    // publishPending is a no-op — the render already shipped the batch.
    a.publishPending();
    b.publishPending();
    try std.testing.expectEqual(@as(u64, 1), g.rev);

    // The shared history serves both cursors independently.
    const f = try g.history.fetch(0, alloc);
    defer History.freeFetch(alloc, f);
    try std.testing.expectEqual(@as(usize, 1), f.batches.len);
}

test "render groups: reply_to re-key forks and A→B→A rejoins the same group" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    _ = try mm.addPost("b", "tok1", "p");
    const c1 = try mm.addComment(1, null, "tok1", "c");

    const a = createSession(alloc, std.testing.io);
    defer a.deinit();
    const b = createSession(alloc, std.testing.io);
    defer b.deinit();
    try serveBoth(alloc, a, b, "/t/1");
    const base = a.group.?;
    try std.testing.expect(a.group.? == b.group.?);
    const e0 = a.membershipEpoch();

    // reply_to is a group-key input: setting it + ping migrates `a` to a
    // forked group while `b` stays on the base group.
    a.reply_to = c1.id;
    a.ping.emit(.{});
    try std.testing.expect(a.membershipEpoch() == e0 + 1);
    try std.testing.expect(a.group.? != base);
    try std.testing.expect(b.group.? == base);
    try std.testing.expectEqual(@as(usize, 2), board_groups.registryCount());

    // A→B→A between renders: cancel returns to the SAME still-alive base
    // group instance (b keeps it alive); epoch bumped twice total.
    a.reply_to = null;
    a.ping.emit(.{});
    try std.testing.expect(a.membershipEpoch() == e0 + 2);
    try std.testing.expect(a.group.? == base);
    try std.testing.expectEqual(@as(usize, 1), board_groups.registryCount()); // fork destroyed
}

test "render groups: minted identity re-keys the session out of the anon group" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    _ = try mm.addPost("b", "tok1", "p");
    const a = createSession(alloc, std.testing.io);
    defer a.deinit();
    const d = createSession(alloc, std.testing.io);
    defer d.deinit();
    try serveBoth(alloc, a, d, "/t/1");
    const anon_group = a.group.?;
    const e0 = d.membershipEpoch();

    // First POST mints "Anon#1" — the resolved name is part of the group
    // key, so d migrates out of the shared anon group even though
    // reply_to/route are unchanged.
    var f: std.json.ObjectMap = .empty;
    defer f.deinit(alloc);
    try f.put(alloc, "post", .{ .string = "1" });
    try f.put(alloc, "text", .{ .string = "hi" });
    try d.dispatch("comment", null, null, &f);
    try std.testing.expect(d.membershipEpoch() > e0);
    try std.testing.expect(d.group.? != anon_group);
    try std.testing.expectEqualStrings("Anon#1", d.group.?.key.name);
    try std.testing.expect(a.group.? == anon_group); // a unaffected
    try std.testing.expectEqual(@as(usize, 2), board_groups.registryCount());
}

test "render groups: last leave destroys the group; recreate gets a new incarnation" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const a = createSession(alloc, std.testing.io);
    try std.testing.expect(try a.servePage("/", &aw.writer));
    const g1 = a.group.?;
    const inc1 = g1.incarnation;
    try std.testing.expectEqual(@as(usize, 1), board_groups.registryCount());
    a.deinit(); // manual — no defer, exercises release-on-deinit
    try std.testing.expectEqual(@as(usize, 0), board_groups.registryCount());

    const b = createSession(alloc, std.testing.io);
    defer b.deinit();
    _ = aw.writer.consumeAll();
    try std.testing.expect(try b.servePage("/", &aw.writer));
    try std.testing.expect(b.group.?.incarnation != inc1);
    try std.testing.expectEqual(@as(usize, 1), board_groups.registryCount());
}

test "render groups: unattached sessions keep the solo diff path" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model = mm;
    defer model = null;

    // Never served a page → no group → dispatch renders into the
    // session's own log exactly like before grouping existed.
    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    s.seedDom();
    alloc.free(patchJson(s, alloc));
    try std.testing.expect(s.group == null);
    try std.testing.expect(!s.attached);

    var f: std.json.ObjectMap = .empty;
    defer f.deinit(alloc);
    try f.put(alloc, "board", .{ .string = "b" });
    try f.put(alloc, "text", .{ .string = "solo" });
    try s.dispatch("post", null, null, &f);
    const j = patchJson(s, alloc);
    defer alloc.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"op\":") != null);
    try std.testing.expectEqual(@as(usize, 0), board_groups.registryCount());
}
