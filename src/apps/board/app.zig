//! zboard — anonymous board app on the zmeta `Session(Deps)` skeleton:
//! static boards, threads, and nested tree comments over the shared
//! BoardModel, with file-based routing (`pages/`) and render groups.
//!
//! Fan-out design: every session has its own zefx graph + DOM state, but
//! the model is global. Mutations bump `model.global_seq`; each session's
//! SSE worker calls `syncPull()` every 50 ms and re-renders (a no-op diff
//! for sessions whose route doesn't show the change), then publishes the
//! batch to that session's history — so one POST reaches every open tab.
//!
//! zmeta app dir: `app.zig` holds `BoardDeps` (the Deps contract) + the
//! hand-declared `Session` (groups.zig needs `scopeForRoute`/
//! `scopeVersion` as statics — see the comment above `Session`),
//! `model.zig` the shared BoardModel, `boardview.zig` the domain Route/
//! ViewEnv + components, `groups.zig` the render-group registry,
//! `pages/` the file routes, `actions.zig` the manifest, `gen/` the
//! checked-in codegen.
//!
//! Routing split: `gen/routes.zig` owns path parsing + typed params;
//! `pageOf` maps the generated `routes.Route` onto the domain
//! `boardview.Route` the view/group layers key on (slug → board index).
const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const zmeta = @import("zmeta.zig");
const model = @import("model.zig");
const groups = @import("groups.zig");
const boardview = @import("view.zig");
const routes = @import("gen/routes.zig");
const actions = @import("gen/actions.zig");
const History = @import("../../server/history.zig").History;

/// Flush-trigger payload — every mutation emits it; the `onPing`
/// reducer (registered by `BoardDeps.wire`) bumps the patch revision in
/// the pure phase and the skeleton's after-flush hook renders.
const Ping = struct {};

/// `zfxu` anonymous-identity cookie — picked up by `Deps.readCookies`
/// and minted into `Session.out_cookie` on first POST.
pub const user_cookie_name = "zfxu";

/// Generated route → domain route: `/b/:slug` resolves to the board
/// index (unknown slug → null → 404); post/comment ids pass through —
/// existence is the page `prepare` gate. The comment permalink keeps
/// only the comment id (it is authoritative; `post` derives from it).
fn pageOf(r: routes.Route) ?boardview.Route {
    return switch (r) {
        .index => .home,
        .b => |p| if (model.boardIndex(p.slug)) |i| .{ .board = i } else null,
        .t => |p| .{ .thread = p.post },
        .t_c => |p| .{ .comment = p.comment },
    };
}

/// Board domain state + graph handles — the zmeta `Deps` for the
/// `.shared_model` archetype (docs/meta-framework.md §4.1/§5.3). The
/// `Session` skeleton owns the transport contract (app/seq/dom/log/
/// history/arena/CSRF/route path); everything domain-specific — the
/// parsed route, inline-reply target, sort preference, `zfxu` identity,
/// seen cursor, render-group membership, and the `ping` event — lives
/// here on `s.deps`. The shared `BoardModel` (model.zig) and the
/// `groups.zig` registry stay module-global (app-owned).
pub const BoardDeps = struct {
    /// §4.1 archetype — module-global model + per-session view state.
    pub const archetype: zmeta.Archetype = .shared_model;
    /// Page <title> / <main> class / session cookie — forwarded to the
    /// server contract through `Session`.
    pub const page_title = "zboard";
    pub const page_class = "app app-board";
    pub const cookie_name = "zfxb";

    /// Wire route — the generated `routes.Route` written by
    /// `Deps.setRoute`; the generated `prepare`/`viewNodes` dispatch
    /// switches on it. The raw path string lives on `Session.route`
    /// (skeleton-owned, feeds `Env.route`).
    route: routes.Route = .{ .index = .{} },
    /// Domain route — `pageOf`'s mapping of `route` onto the
    /// `boardview.Route` the view/render-group layers key on
    /// (slug → board index, comment permalink → comment id).
    page: boardview.Route = .home,
    /// Comment id the inline reply form is mounted under (per-session).
    reply_to: ?u64 = null,
    /// Top-level comment sort preference (per-session, group-key input).
    sort: boardview.Sort = .new,
    /// zfxu cookie value — the anonymous poster identity ("" = anonymous).
    user_token: []u8 = &.{},
    /// Scratch for the Set-Cookie value emitted on the minting POST —
    /// `Session.out_cookie` points into it (one-shot per response).
    out_cookie_buf: [600]u8 = undefined,
    /// Last `model.global_seq` this session rendered — syncPull's cursor
    /// for UNGROUPED (never page-served) sessions; grouped sessions dedup
    /// on their group's `last_rendered_seq` instead.
    seen_seq: u64 = 0,
    /// Set by the first successful servePage — gates render grouping so
    /// sessions that never served a page keep the solo diff path.
    attached: bool = false,
    /// Render-group membership (groups.zig): sessions with equal
    /// (route, reply_to, resolved name, sort) share one Dom/history/rev.
    group: ?*groups.RenderGroup = null,
    /// Bumped on every stream-INCOMPATIBLE group transition — join of a
    /// foreign namespace, first attach, group recreation — the SSE
    /// stream compares it per poll; ANY change forces a snapshot +
    /// revision adopt because group-local revision numbers don't imply
    /// baseline equality (this also covers A→B→A between polls).
    /// Clone-on-fork transitions preserve the lineage and do NOT bump
    /// (Render groups v2).
    membership_epoch: u64 = 0,

    /// Flush trigger: every mutation emits it; `onPing` bumps `seq` in
    /// the pure phase and the skeleton's after-flush hook renders.
    ping: *zefx.Event(Ping),

    /// `Deps.init` — create the graph handles on the session's engine.
    /// `seq` already exists (skeleton-owned); `wire` registers the
    /// reducer next.
    pub fn init(s: *Session) BoardDeps {
        return .{ .ping = s.app.createEvent(Ping) };
    }

    /// `Deps.deinit` — release render-group membership, then free the
    /// minted identity. Runs before the skeleton tears down
    /// dom/log/history/arena/app (original ordering preserved).
    pub fn deinit(s: *Session) void {
        // Release group membership first — the last leaver destroys the
        // group; eviction must not corrupt shared group state.
        if (s.deps.group) |g| groups.leave(s.gpa, g);
        s.deps.group = null;
        if (s.deps.user_token.len != 0) s.gpa.free(s.deps.user_token);
    }

    /// `Deps.wire` — pure-phase reducers ONLY. The skeleton installs the
    /// render after-flush hook itself after this returns, so board must
    /// not re-register it (the hand-rolled Session used to).
    pub fn wire(s: *Session) void {
        s.deps.ping.onReducer(s, &onPing);
    }

    /// `Deps.setRoute` — parse via the generated table, map to the
    /// domain route (slug → board index), store it and clear the
    /// inline-reply target. Dangling-id checks live in the page
    /// `prepare` gate (servePage), not here. The skeleton stores the
    /// raw path for `Env.route` itself.
    pub fn setRoute(s: *Session, path: []const u8) bool {
        const r = routes.parseRoute(path) orelse return false;
        const page = pageOf(r) orelse return false;
        s.deps.route = r;
        s.deps.page = page;
        s.deps.reply_to = null;
        return true;
    }

    /// `Deps.validPath` — static route pre-check run before a session is
    /// minted: parseable shape AND resolvable slug (model boards are a
    /// static list, so `/b/nope` fails here without minting a session).
    /// Dangling post/comment ids still 404 inside servePage's prepare.
    pub fn validPath(path: []const u8) bool {
        const r = routes.parseRoute(path) orelse return false;
        return pageOf(r) != null;
    }

    /// `Deps.readCookies` — pick up the `zfxu` user cookie before
    /// dispatch/page render (the server calls it with the raw Cookie
    /// header on every /action POST and page GET).
    pub fn readCookies(s: *Session, cookie_hdr: ?[]const u8) void {
        const h = cookie_hdr orelse return;
        var it = std.mem.splitScalar(u8, h, ';');
        while (it.next()) |part| {
            const kv = std.mem.trim(u8, part, " \t");
            const prefix = user_cookie_name ++ "=";
            if (std.mem.startsWith(u8, kv, prefix)) {
                const v = kv[prefix.len..];
                if (v.len != 0 and s.deps.user_token.len == 0) {
                    s.deps.user_token = s.gpa.dupe(u8, v) catch @panic("OOM");
                }
                return;
            }
        }
    }

    /// `Deps.servePage` — the grouped page pipeline: setRoute →
    /// page `prepare` gate (dangling ids → 404) → render-group
    /// membership sync → ensure-group-current → writeView. NO
    /// dom.reset/seedDom — the shared Dom lives in the render group;
    /// a fresh group was seeded privately at join and an existing
    /// group's Dom already matches the view this page ships.
    pub fn servePage(s: *Session, path: []const u8, writer: anytype) !bool {
        if (!s.setRoute(path)) return false;
        const env = zmeta.Env{ .route = s.route };
        routes.prepare(s, &env) catch return false;
        s.deps.attached = true;
        syncMembership(s);
        ensureGroupCurrent(s);
        try s.writeView(writer);
        return true;
    }

    /// `Deps.syncPull` — SSE-worker hook: when the shared model moved
    /// past what the session (or its group) last rendered, ping → flush
    /// → render. Grouped sessions dedup on the GROUP's
    /// `last_rendered_seq`, so N members on one group cost one
    /// buildView+diff per model version.
    pub fn syncPull(s: *Session) void {
        if (s.deps.group) |g| {
            // Dirty-only dispatch: ping only when a scope this group's
            // route reads actually bumped (or a fork forced a render).
            if (g.isCurrent()) return;
            s.deps.ping.emit(.{});
            return;
        }
        const rendered = s.deps.seen_seq;
        if (model.get().global_seq.load(.seq_cst) == rendered) return;
        s.deps.ping.emit(.{});
    }

    // ── render-group stream hooks (all-or-nothing set) ──────────
    // Declared on Deps → the skeleton emits them on the grouped
    // Session variant, which is what flips server/http.zig's
    // @hasDecl probes onto the grouped publish/fetch path.

    /// Drain the pending rendered batch into retained history. Grouped
    /// sessions publish through their group (the render hook already
    /// did — this is the safety net); unattached sessions keep the
    /// inline log→history path the generic server used before grouping.
    pub fn publishPending(s: *Session) void {
        if (s.deps.group) |g| {
            g.publish();
            return;
        }
        if (s.seq.get() <= s.history.latest_rev) {
            s.log.clear();
            return;
        }
        var jaw: std.Io.Writer.Allocating = .init(s.gpa);
        defer jaw.deinit();
        s.log.writeJson(&jaw.writer) catch @panic("OOM");
        s.history.publish(s.seq.get(), jaw.toOwnedSlice() catch @panic("OOM"));
        s.log.clear();
    }

    /// Revision subscribers (SSE cursor, snapshot `rev`, ACK) should
    /// track — the group's local revision when grouped, else `seq`.
    pub fn streamRev(s: *Session) u64 {
        return if (s.deps.group) |g| g.rev else s.seq.get();
    }

    /// History ring subscribers fetch from — the group's when grouped.
    pub fn streamHistory(s: *Session) *History {
        return if (s.deps.group) |g| &g.history else &s.history;
    }

    /// Membership epoch for the SSE stream: bumped on stream-incompatible
    /// group transitions; any change forces a snapshot + revision adopt.
    /// Clone-fork transitions keep the epoch — the forked group continues
    /// the same rev/history lineage, so the cursor stays valid.
    pub fn membershipEpoch(s: *Session) u64 {
        return s.deps.membership_epoch;
    }

    /// `Deps.dispatch` — whitelisted action entry point: the DOM event
    /// protocol (`action`, `arg`, `value`, `fields`). The generated
    /// `actions.dispatch` fans out to the `on_<name>` handlers below;
    /// this wrapper owns the two pieces EVERY action shares — the
    /// one-shot `out_cookie` reset and first-contact identity minting
    /// (even a rejected action establishes `zfxu`, matching the old
    /// inline dispatch).
    pub fn dispatch(
        s: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        // `out_cookie` is a one-shot: the server emits it on this response
        // only — later POSTs must not re-send the Set-Cookie header.
        s.out_cookie = "";
        // Every POST establishes identity on first contact.
        try ensureUser(s);
        return actions.dispatch(s, action, arg, value, fields);
    }

    /// `post` — fields {board, text} → addPost on the shared model.
    pub fn on_post(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        const f = fields orelse return error.InvalidAction;
        const slug = fieldStr(f, "board") orelse return error.InvalidAction;
        const text = fieldStr(f, "text") orelse return error.InvalidAction;
        _ = try model.get().addPost(slug, s.deps.user_token, text);
        s.deps.ping.emit(.{});
    }

    /// `comment` — fields {post, parent?, text} → addComment; clears
    /// the inline-reply target.
    pub fn on_comment(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        const f = fields orelse return error.InvalidAction;
        const post_id = fieldU64(f, "post") orelse return error.InvalidAction;
        const parent = fieldU64(f, "parent");
        const text = fieldStr(f, "text") orelse return error.InvalidAction;
        _ = try model.get().addComment(post_id, parent, s.deps.user_token, text);
        s.deps.reply_to = null;
        s.deps.ping.emit(.{});
    }

    /// `reply` — arg = comment id → mount the inline reply form under it.
    pub fn on_reply(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = value;
        _ = fields;
        const a = arg orelse return error.InvalidAction;
        const cid = std.fmt.parseInt(u64, a, 10) catch return error.InvalidAction;
        if (model.get().comment(cid) == null) return error.CommentNotFound;
        s.deps.reply_to = cid;
        s.deps.ping.emit(.{});
    }

    /// `cancel_reply` — unmount the inline reply form.
    pub fn on_cancel_reply(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = arg;
        _ = value;
        _ = fields;
        s.deps.reply_to = null;
        s.deps.ping.emit(.{});
    }

    /// `sort` — arg "new"|"top" → top-level comment ordering.
    pub fn on_sort(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = value;
        _ = fields;
        const a = arg orelse return error.InvalidAction;
        if (std.mem.eql(u8, a, "top")) {
            s.deps.sort = .top;
        } else if (std.mem.eql(u8, a, "new")) {
            s.deps.sort = .new;
        } else return error.InvalidAction;
        s.deps.ping.emit(.{});
    }

    /// `like` — arg "p<id>"|"c<id>" → toggleLike for this user.
    pub fn on_like(s: *Session, arg: ?[]const u8, value: ?[]const u8, fields: ?*const std.json.ObjectMap) !void {
        _ = value;
        _ = fields;
        const a = arg orelse return error.InvalidAction;
        if (a.len < 2) return error.InvalidAction;
        const kind: model.LikeKind = switch (a[0]) {
            'p' => .post,
            'c' => .comment,
            else => return error.InvalidAction,
        };
        const target = std.fmt.parseInt(u64, a[1..], 10) catch return error.InvalidAction;
        _ = try model.get().toggleLike(kind, target, s.deps.user_token);
        s.deps.ping.emit(.{});
    }

    // ── render-path overrides ────────────────────────────────────
    // Grouped sessions replace the whole page pipeline AND the flush
    // render; writeView/buildViewNodes/seedDom are overridden too so no
    // skeleton default branch — which would resolve the skeleton's
    // PRIVATE viewEnv/render decls on this foreign self type — is ever
    // analyzed through an alias.

    /// `Deps.render` — the after-flush render, reached through the
    /// skeleton-installed hook. Grouped path: re-key first (reply_to/
    /// identity may have changed inside dispatch), then render+publish
    /// through the group — deduped on `last_rendered_seq`, so member
    /// pings after the first see the group already current. Solo path:
    /// sessions that never served a page (tests, dead routes) keep the
    /// original per-session diff.
    pub fn render(s: *Session) void {
        if (s.deps.attached) {
            syncMembership(s);
            if (s.deps.group) |g| {
                g.render();
                g.publish();
                return;
            }
        }
        _ = s.render_arena.reset(.retain_capacity);
        const a = s.render_arena.allocator();
        forest.diff(a, boardview.buildView(a, viewEnv(s)), &s.dom, &s.log);
        s.log.revision = s.seq.get();
    }

    /// `Deps.writeView` — render the `<main>` inner content for the
    /// initial page.
    pub fn writeView(s: *Session, writer: anytype) !void {
        _ = s.render_arena.reset(.retain_capacity);
        const a = s.render_arena.allocator();
        try forest.writeHtml(a, boardview.buildView(a, viewEnv(s)), writer);
    }

    /// `Deps.buildViewNodes` — the session's current view nodes for the
    /// SSE snapshot writer (`forest.writeSnapshotOps` serializes them).
    /// Stamps `seen_seq` through `viewEnv().seen` exactly like the
    /// hand-rolled version — the §4.4 cursor split is preserved:
    /// session-side builds write the SESSION cursor, and only the
    /// render group's own seed/render builds (which call
    /// `boardview.buildView` with the GROUP's ViewEnv,
    /// `seen = &g.last_rendered_seq`) write the group cursor. Session
    /// builds never touch `last_rendered_seq`.
    pub fn buildViewNodes(s: *Session, a: std.mem.Allocator) []const forest.Node {
        return boardview.buildView(a, viewEnv(s));
    }

    /// `Deps.seedDom` — solo-path helper: render + drop the patch log.
    /// Grouped sessions never reach this through the pipeline (their
    /// servePage override skips it and the group's Dom is seeded at
    /// join); tests call it on unattached sessions only.
    pub fn seedDom(s: *Session) void {
        BoardDeps.render(s);
        s.log.clear();
    }

    /// `Deps.view` — the contract view entry. Board overrides every
    /// skeleton default that would call it, so this is the canonical
    /// wrapper kept for contract completeness (and any future default
    /// path): rebuild the board `ViewEnv` from `s.deps` — `Env` stays
    /// the thin `{route}` v0 slice and is ignored here.
    pub fn view(a: std.mem.Allocator, s: *Session, env: *const zmeta.Env) []const forest.Node {
        _ = env;
        return boardview.buildView(a, viewEnv(s));
    }
};

/// The skeleton type `BoardDeps` instantiates — `SessionGrouped`
/// because BoardDeps declares all four render-group stream hooks (the
/// all-or-nothing set `server/http.zig`'s @hasDecl probes look for).
const Skel = zmeta.Session(BoardDeps);

/// One browser session — the full `server/http.zig` contract.
///
/// Why hand-declared instead of `pub const Session =
/// zmeta.Session(BoardDeps)`: `groups.zig` (board-owned) calls
/// `Session.scopeForRoute`/`Session.scopeVersion` as STATIC decls on
/// this type, and Zig cannot extend a type's namespace — the skeleton's
/// SessionGrouped has a fixed decl list. So `Session` replicates the
/// skeleton's exact field list and aliases every contract method from
/// `Skel`: the method bodies live ONCE in `zmeta/session.zig`'s
/// `SessionMethods` as generic `self: anytype` fns, so
/// `pub const dispatch = Skel.dispatch` etc. instantiate against
/// `*Session` exactly like they do against `*SessionGrouped`. The only
/// additions are the two board-owned statics `groups` needs and the
/// `viewEnv`/`render` compat decls (the skeleton keeps those private —
/// provided here so no aliased default branch can resolve a missing
/// decl). `create` mirrors the skeleton's `createSessionImpl`: contract
/// fields → `Deps.init`/`Deps.wire` → the render after-flush hook LAST.
pub const Session = struct {
    // ── contract fields owned by the skeleton ─────────────────
    // IDENTICAL to SessionGrouped's field list — the aliased
    // SessionMethods bodies access them by name; `create` below
    // initializes by field name like createSessionImpl does.
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Per-session reactive graph — events/stores created by
    /// `BoardDeps.init`/`wire` live here.
    app: zefx.App,
    /// Patch revision — the server's `seq.get()` contract field.
    seq: *zefx.Store(u64),
    /// App-owned model state + graph handles (the Deps contract).
    deps: BoardDeps,

    dom: forest.Dom,
    log: forest.PatchLog,
    /// Retained patch batches for SSE replay (see server/history.zig).
    history: History,
    /// Scratch space for the per-render view tree; reset each render.
    render_arena: std.heap.ArenaAllocator,
    /// Per-session CSRF token rendered into the page and verified on
    /// POST. Owned by the session; set by the server at creation.
    csrf_token: []u8 = &.{},
    /// Store-stamped incarnation (see the Session contract in
    /// server/http.zig): distinguishes this session from a previous
    /// one evicted+recreated under the same (cookie token, route).
    incarnation: u64 = 0,
    /// Extra `Set-Cookie` header emitted on /action responses
    /// ("" = none). For board this points into `deps.out_cookie_buf`.
    out_cookie: []const u8 = &.{},
    /// Last route path accepted by `setRoute` — the `Env.route` source.
    /// Owned copy: request buffers die with the request.
    route: []const u8 = "/",
    route_owned: bool = false,
    /// Raw query string of the last page GET — the `Env.query` source.
    query: []const u8 = "",
    query_owned: bool = false,

    /// Page shell metadata — forwarded from BoardDeps (the skeleton
    /// applies the same defaults when Deps doesn't declare them).
    pub const page_title = BoardDeps.page_title;
    pub const page_class = BoardDeps.page_class;
    pub const cookie_name = BoardDeps.cookie_name;
    /// §4.1 archetype — `.shared_model`.
    pub const archetype = BoardDeps.archetype;

    /// Wired session constructor (`io` is for entropy — `ensureUser`
    /// mints the `zfxu` token from it).
    pub fn create(gpa: std.mem.Allocator, io: std.Io) *Session {
        const s = gpa.create(Session) catch @panic("OOM");
        s.* = .{
            .gpa = gpa,
            .io = io,
            .app = zefx.createApp(gpa),
            .seq = undefined,
            .deps = undefined,
            .dom = forest.Dom.init(gpa),
            .log = forest.PatchLog.init(gpa),
            .history = History.init(gpa),
            .render_arena = std.heap.ArenaAllocator.init(gpa),
        };
        s.seq = s.app.createStore(u64, 0);
        s.deps = BoardDeps.init(s);
        BoardDeps.wire(s);
        // After every flush the graph is fully settled → BoardDeps.render
        // (the skeleton installs this same hook for its own variants;
        // board installs it directly because `Session` is hand-declared).
        s.app.eng.onAfterFlush(.{
            .ctx = @ptrCast(s),
            .call = &struct {
                fn render(raw: *anyopaque) void {
                    const self: *Session = @ptrCast(@alignCast(raw));
                    BoardDeps.render(self);
                }
            }.render,
        });
        return s;
    }

    /// The model scope a route's view reads — render groups gate
    /// buildView+diff on this version (dirty-only dispatch). Comment
    /// permalinks read their whole post's scope: a reply anywhere in
    /// the thread re-renders them (over-broad but correct).
    /// Static: `groups.zig` calls it as `Session.scopeForRoute`.
    pub fn scopeForRoute(route: boardview.Route) u64 {
        return switch (route) {
            .home => model.SCOPE_HOME,
            .board => |i| model.scopeBoard(i),
            .thread => |pid| model.scopePost(pid),
            .comment => |cid| blk: {
                const c = model.get().comment(cid) orelse break :blk model.scopePost(0);
                break :blk model.scopePost(c.post);
            },
        };
    }

    /// Current version of a scope key — groups compare it against
    /// their `scope_seen` cursor. Static like `scopeForRoute`.
    pub fn scopeVersion(key: u64) u64 {
        return model.get().scopeVersion(key);
    }

    /// Skeleton-compat decls — the skeleton's SessionMethods bodies
    /// resolve `self.viewEnv()`/`self.render()` on whatever self type
    /// they're instantiated with; the real decls on SessionGrouped are
    /// private, so provide pub equivalents here. Every Deps override is
    /// declared, so the default branches that would call these are dead
    /// — they exist only so a future skeleton change can't produce a
    /// "no field or member named viewEnv" error through an alias.
    pub fn viewEnv(self: *Session) zmeta.Env {
        return .{ .route = self.route, .query = self.query };
    }

    pub fn render(self: *Session) void {
        BoardDeps.render(self);
    }

    // ── contract methods — aliases into the skeleton ────────────
    // Bodies written once in zmeta/session.zig's SessionMethods as
    // `self: anytype` generics; each resolves the Deps.* hooks on
    // BoardDeps and the contract fields on *Session.

    pub const deinit = Skel.deinit;
    pub const setCsrf = Skel.setCsrf;
    pub const setRoute = Skel.setRoute;
    pub const setQuery = Skel.setQuery;
    pub const validPath = Skel.validPath;
    pub const readCookies = Skel.readCookies;
    pub const servePage = Skel.servePage;
    pub const syncPull = Skel.syncPull;
    pub const bumpSeq = Skel.bumpSeq;
    pub const dispatch = Skel.dispatch;
    pub const writeView = Skel.writeView;
    pub const buildViewNodes = Skel.buildViewNodes;
    pub const seedDom = Skel.seedDom;
    /// Render-group stream hooks — present because Skel is the grouped
    /// variant; this is what flips http.zig's @hasDecl probes.
    pub const publishPending = Skel.publishPending;
    pub const streamRev = Skel.streamRev;
    pub const streamHistory = Skel.streamHistory;
    pub const membershipEpoch = Skel.membershipEpoch;
};

// ── session-state helpers (file scope, take *Session) ─────────

/// Every POST needs a resolvable identity: mint on first contact, or
/// heal a cookie token that has no users row (db reset / forged).
fn ensureUser(s: *Session) !void {
    if (s.deps.user_token.len == 0) {
        var rb: [16]u8 = undefined;
        s.io.random(&rb);
        const tok = std.fmt.allocPrint(s.gpa, "{x}", .{std.mem.readInt(u64, rb[0..8], .little)}) catch @panic("OOM");
        errdefer s.gpa.free(tok);
        _ = try model.get().ensureUser(tok);
        s.out_cookie = std.fmt.bufPrint(&s.deps.out_cookie_buf, "{s}={s}; Path=/; SameSite=Lax", .{ user_cookie_name, tok }) catch @panic("cookie buf too small");
        s.deps.user_token = tok;
        return;
    }
    if (model.get().userName(s.deps.user_token) == null) {
        _ = try model.get().ensureUser(s.deps.user_token);
    }
}

/// The session's current group-key inputs — recomputed on every render
/// so an identity minted by a (possibly failed) dispatch is picked up
/// BEFORE the group is chosen/rendered.
fn groupKey(s: *Session) groups.Key {
    return .{ .route = s.deps.page, .reply_to = s.deps.reply_to, .name = boardview.nameOf(s.deps.user_token), .sort = s.deps.sort };
}

/// Join/migrate the render group when the key changed. Bumps
/// `membership_epoch` on every STREAM-INCOMPATIBLE transition —
/// the SSE stream treats a bump as "send a snapshot and adopt the
/// new revision". Clone-on-fork transitions (new key absent from
/// the registry) do NOT bump: the forked group continues this
/// session's rev/history lineage, so patches keep flowing and
/// drafts survive (ARCHITECTURE.md "Render groups v2").
fn syncMembership(s: *Session) void {
    if (!s.deps.attached) return;
    const key = groupKey(s);
    var kbuf: [256]u8 = undefined;
    const ks = groups.keyStringInto(&kbuf, key.route, key.reply_to, key.name, key.sort);
    if (s.deps.group) |g| {
        if (std.mem.eql(u8, g.key_string, ks)) return;
        if (!groups.contains(key)) {
            // Absent key → clone-fork: new group inherits g's stream
            // lineage (rev + history + tracked Dom). Epoch stays —
            // the client's cursor remains valid on the new group.
            s.deps.group = groups.fork(s.gpa, g, key);
            groups.leave(s.gpa, g);
            return;
        }
        groups.leave(s.gpa, g);
        s.deps.group = null;
    }
    s.deps.group = groups.join(s.gpa, key);
    s.deps.membership_epoch +%= 1;
}

/// Bring the group current with the shared model — render+publish
/// when `global_seq` moved. servePage calls this BEFORE writing SSR
/// so the group's tracked Dom always matches the shipped page.
fn ensureGroupCurrent(s: *Session) void {
    const g = s.deps.group orelse return;
    g.render(); // no-op when last_rendered_seq == global_seq
    g.publish(); // no-op when nothing pending
}

/// The board `ViewEnv` for session-side builds — `seen` is the
/// session's own `seen_seq` cursor. The §4.4 split: only Dom-syncing
/// builds stamp a cursor, and the render group's own seed/render builds
/// go through `boardview.buildView` with the GROUP's ViewEnv
/// (`seen = &g.last_rendered_seq`) instead — session builds never touch
/// the group cursor. `pub`: page files delegate their `view` here.
pub fn viewEnv(s: *Session) boardview.ViewEnv {
    return .{
        .route = s.deps.page,
        .reply_to = s.deps.reply_to,
        .sort = s.deps.sort,
        .name = boardview.nameOf(s.deps.user_token),
        .seen = &s.deps.seen_seq,
    };
}

/// ping reducer — bumps the revision in the pure phase (registered by
/// `BoardDeps.wire`; the skeleton's after-flush hook renders after).
fn onPing(s: *Session, _: Ping) void {
    s.bumpSeq();
}

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

/// Wired session constructor — test/server entry point (the real
/// wiring lives in `Session.create`, mirroring the skeleton's
/// `createSessionImpl`).
pub fn createSession(gpa: std.mem.Allocator, io: std.Io) *Session {
    return Session.create(gpa, io);
}
// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

fn testModel(alloc: std.mem.Allocator) *model.BoardModel {
    const mm = model.BoardModel.init(alloc, ":memory:") catch @panic("model init failed");
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
    // Generated layer: path → typed params.
    const home = routes.parseRoute("/") orelse return error.TestUnexpectedResult;
    try std.testing.expect(home == .index);

    const bd = routes.parseRoute("/b/b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b", bd.b.slug);
    const tt = routes.parseRoute("/b/tech") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("tech", tt.b.slug);
    const th = routes.parseRoute("/t/7") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), th.t.post);
    const cm = routes.parseRoute("/t/7/c/9") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 7), cm.t_c.post);
    try std.testing.expectEqual(@as(u64, 9), cm.t_c.comment);

    // Domain layer: generated → boardview.Route (slug → board index).
    const home_d = pageOf(home).?;
    try std.testing.expect(home_d == .home);
    const bd_d = pageOf(bd).?;
    switch (bd_d) {
        .board => |i| try std.testing.expectEqual(@as(usize, 0), i),
        else => return error.TestUnexpectedResult,
    }
    const tech_d = pageOf(tt).?;
    switch (tech_d) {
        .board => |i| try std.testing.expectEqual(model.boardIndex("tech").?, i),
        else => return error.TestUnexpectedResult,
    }
    const th_d = pageOf(th).?;
    switch (th_d) {
        .thread => |id| try std.testing.expectEqual(@as(u64, 7), id),
        else => return error.TestUnexpectedResult,
    }
    const cm_d = pageOf(cm).?;
    switch (cm_d) {
        .comment => |id| try std.testing.expectEqual(@as(u64, 9), id),
        else => return error.TestUnexpectedResult,
    }

    // Junk rejected at the generated layer; a well-formed but unknown
    // slug parses fine and fails at pageOf instead.
    const nope = routes.parseRoute("/b/nope") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pageOf(nope) == null);
    try std.testing.expect(routes.parseRoute("/t/abc") == null);
    try std.testing.expect(routes.parseRoute("/t/1/x/2") == null);
    try std.testing.expect(routes.parseRoute("/nope") == null);
    try std.testing.expect(routes.parseRoute("/t/") == null);
    try std.testing.expect(routes.parseRoute("") == null);
}

test "setRoute/servePage reset dom, SSR per route, and 404 dangling ids" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;
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

    // Unknown path and unknown slug rejected at setRoute; dangling
    // ids are well-formed routes — they 404 at servePage's prepare.
    try std.testing.expect(!s.setRoute("/bogus"));
    try std.testing.expect(!s.setRoute("/b/nope"));
    try std.testing.expect(s.setRoute("/t/999"));
    try std.testing.expect(s.setRoute("/t/1/c/999"));
    try std.testing.expect(s.setRoute("/t/1"));
    var dead: std.Io.Writer.Allocating = .init(alloc);
    defer dead.deinit();
    try std.testing.expect(!try s.servePage("/t/999", &dead.writer));
    try std.testing.expect(!try s.servePage("/t/1/c/999", &dead.writer));

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
    model.shared = mm;
    defer model.shared = null;

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
    try std.testing.expect(a.deps.user_token.len != 0);
    try std.testing.expect(std.mem.startsWith(u8, a.out_cookie, "zfxu="));
    try std.testing.expectEqualStrings("Anon#1", mm.userName(a.deps.user_token).?);
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
    try std.testing.expectEqual(@as(?u64, c1), a.deps.reply_to);
    try std.testing.expect(b.deps.reply_to == null);
    try a.dispatch("cancel_reply", null, null, null);
    try std.testing.expect(a.deps.reply_to == null);

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
    model.shared = mm;
    defer model.shared = null;

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
    model.shared = mm;
    defer model.shared = null;

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
    model.shared = mm;
    defer model.shared = null;

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
    try std.testing.expect(s.deps.seen_seq == mm.global_seq.load(.seq_cst));
    // The home latest list picked up the new post.
    try std.testing.expect(std.mem.indexOf(u8, j, "post-") != null);
}

test "comment on another session patches the board counter live" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;

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
    model.shared = mm;
    defer model.shared = null;

    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    s.seedDom(); // #who renders "anon" for the empty user_token

    // First contact is an INVALID action: ensureUser still mints the
    // zfxu identity (a model mutation → global_seq bump) before the
    // action itself is rejected without ping.emit.
    try std.testing.expectError(error.InvalidAction, s.dispatch("hack", null, null, null));
    try std.testing.expect(s.deps.user_token.len != 0);
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
    model.shared = mm;
    defer model.shared = null;

    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    s.seedDom();

    // Simulate a stale/forged zfxu cookie: token present, no users row.
    s.deps.user_token = try alloc.dupe(u8, "tok-forged");
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
    model.shared = mm;
    defer model.shared = null;

    const a = createSession(alloc, std.testing.io);
    defer a.deinit();
    const b = createSession(alloc, std.testing.io);
    defer b.deinit();
    try serveBoth(alloc, a, b, "/");

    // Same (route, reply_to=null, name="anon") → same group, 2 members.
    const g = a.deps.group.?;
    try std.testing.expect(a.deps.group.? == b.deps.group.?);
    try std.testing.expectEqual(@as(usize, 2), g.members);
    try std.testing.expectEqual(@as(u64, 0), g.rev); // seeded, nothing published
    try std.testing.expectEqual(@as(usize, 1), groups.registryCount());

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

test "render groups v2: reply_to fork clones the stream; A→B→A still snapshots" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;

    _ = try mm.addPost("b", "tok1", "p");
    const c1 = try mm.addComment(1, null, "tok1", "c");

    const a = createSession(alloc, std.testing.io);
    defer a.deinit();
    const b = createSession(alloc, std.testing.io);
    defer b.deinit();
    try serveBoth(alloc, a, b, "/t/1");
    const base = a.deps.group.?;
    try std.testing.expect(a.deps.group.? == b.deps.group.?);
    const e0 = a.membershipEpoch();

    // Give the base group a published batch so its ring is non-empty —
    // the fork must carry it verbatim for lagging cursors.
    _ = try mm.addComment(1, null, "tok2", "c2");
    a.syncPull();
    try std.testing.expectEqual(@as(u64, 1), base.rev);

    // reply_to is a group-key input: setting it + ping migrates `a`.
    // The new key is ABSENT → clone-on-fork: epoch NOT bumped, the forked
    // group continues base's rev/history lineage → patches, no snapshot.
    a.deps.reply_to = c1.id;
    a.deps.ping.emit(.{});
    try std.testing.expect(a.membershipEpoch() == e0);
    const forked = a.deps.group.?;
    try std.testing.expect(forked != base);
    try std.testing.expect(b.deps.group.? == base);
    try std.testing.expectEqual(@as(usize, 2), groups.registryCount());

    // needs_render forced one diff even though global_seq didn't move
    // for the re-key itself: rev continues base's numbering, and the
    // ring holds base's batch plus the incremental transition.
    try std.testing.expectEqual(base.rev + 1, forked.rev);
    try std.testing.expectEqual(forked.rev, forked.history.latest_rev);
    const fc = try forked.history.fetch(0, alloc);
    defer History.freeFetch(alloc, fc);
    try std.testing.expectEqual(@as(usize, 2), fc.batches.len);
    try std.testing.expect(std.mem.indexOf(u8, fc.batches[1].data, "\"op\":\"when\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fc.batches[1].data, "\"op\":\"create\"") == null);

    // A→B→A: the base key EXISTS (b holds it) → join path → epoch bump
    // → snapshot; the single-member fork is destroyed on leave.
    a.deps.reply_to = null;
    a.deps.ping.emit(.{});
    try std.testing.expect(a.membershipEpoch() == e0 + 1);
    try std.testing.expect(a.deps.group.? == base);
    try std.testing.expectEqual(@as(usize, 1), groups.registryCount());
}

test "render groups: minted identity re-keys the session out of the anon group" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;

    _ = try mm.addPost("b", "tok1", "p");
    const a = createSession(alloc, std.testing.io);
    defer a.deinit();
    const d = createSession(alloc, std.testing.io);
    defer d.deinit();
    try serveBoth(alloc, a, d, "/t/1");
    const anon_group = a.deps.group.?;
    const e0 = d.membershipEpoch();

    // First POST mints "Anon#1" — the resolved name is part of the group
    // key, so d migrates out of the shared anon group even though
    // reply_to/route are unchanged.
    var f: std.json.ObjectMap = .empty;
    defer f.deinit(alloc);
    try f.put(alloc, "post", .{ .string = "1" });
    try f.put(alloc, "text", .{ .string = "hi" });
    try d.dispatch("comment", null, null, &f);
    // Absent key → clone-fork: the stream lineage continues, so the
    // epoch does NOT bump — the open SSE gets patches, not a snapshot.
    try std.testing.expect(d.membershipEpoch() == e0);
    try std.testing.expect(d.deps.group.? != anon_group);
    try std.testing.expectEqualStrings("Anon#1", d.deps.group.?.key.name);
    try std.testing.expect(a.deps.group.? == anon_group); // a unaffected
    try std.testing.expectEqual(@as(usize, 2), groups.registryCount());
}

test "render groups: last leave destroys the group; recreate gets a new incarnation" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    const a = createSession(alloc, std.testing.io);
    try std.testing.expect(try a.servePage("/", &aw.writer));
    const g1 = a.deps.group.?;
    const inc1 = g1.incarnation;
    try std.testing.expectEqual(@as(usize, 1), groups.registryCount());
    a.deinit(); // manual — no defer, exercises release-on-deinit
    try std.testing.expectEqual(@as(usize, 0), groups.registryCount());

    const b = createSession(alloc, std.testing.io);
    defer b.deinit();
    _ = aw.writer.consumeAll();
    try std.testing.expect(try b.servePage("/", &aw.writer));
    try std.testing.expect(b.deps.group.?.incarnation != inc1);
    try std.testing.expectEqual(@as(usize, 1), groups.registryCount());
}

test "render groups: unattached sessions keep the solo diff path" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;

    // Never served a page → no group → dispatch renders into the
    // session's own log exactly like before grouping existed.
    const s = createSession(alloc, std.testing.io);
    defer s.deinit();
    s.seedDom();
    alloc.free(patchJson(s, alloc));
    try std.testing.expect(s.deps.group == null);
    try std.testing.expect(!s.deps.attached);

    var f: std.json.ObjectMap = .empty;
    defer f.deinit(alloc);
    try f.put(alloc, "board", .{ .string = "b" });
    try f.put(alloc, "text", .{ .string = "solo" });
    try s.dispatch("post", null, null, &f);
    const j = patchJson(s, alloc);
    defer alloc.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"op\":") != null);
    try std.testing.expectEqual(@as(usize, 0), groups.registryCount());
}

test "sortTops: newest-first default, top orders by likes then recency" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;
    _ = try mm.addPost("b", "tok", "post");
    _ = try mm.addComment(1, null, "tok", "oldest");
    _ = try mm.addComment(1, null, "tok", "middle");
    _ = try mm.addComment(1, null, "tok", "newest");
    const c_old = mm.comments.items[0].id;
    const c_mid = mm.comments.items[1].id;
    const c_new = mm.comments.items[2].id;

    const tops = try mm.topCommentIdx(alloc, 1);
    defer alloc.free(tops);
    try std.testing.expectEqual(@as(usize, 3), tops.len);

    // .new reverses the ascending index order → newest id first.
    const newest = boardview.sortTops(alloc, mm, tops, .new);
    defer alloc.free(newest);
    try std.testing.expectEqual(@as(usize, 3), newest.len);
    try std.testing.expectEqual(c_new, mm.comments.items[newest[0]].id);
    try std.testing.expectEqual(c_mid, mm.comments.items[newest[1]].id);
    try std.testing.expectEqual(c_old, mm.comments.items[newest[2]].id);

    // .top: two accounts like the OLDEST comment → it leads; the rest
    // keep newest-first order.
    _ = try mm.toggleLike(.comment, c_old, "u1");
    _ = try mm.toggleLike(.comment, c_old, "u2");
    const top = boardview.sortTops(alloc, mm, tops, .top);
    defer alloc.free(top);
    try std.testing.expectEqual(c_old, mm.comments.items[top[0]].id);
    try std.testing.expectEqual(c_new, mm.comments.items[top[1]].id);
    try std.testing.expectEqual(c_mid, mm.comments.items[top[2]].id);
}

test "like/sort actions: per-account votes, sort re-keys the group" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;

    const a = createSession(alloc, std.testing.io);
    defer a.deinit();
    const b = createSession(alloc, std.testing.io);
    defer b.deinit();

    var f: std.json.ObjectMap = .empty;
    defer f.deinit(alloc);
    try f.put(alloc, "board", .{ .string = "b" });
    try f.put(alloc, "text", .{ .string = "post" });
    try a.dispatch("post", null, null, &f);
    var cf: std.json.ObjectMap = .empty;
    defer cf.deinit(alloc);
    try cf.put(alloc, "post", .{ .string = "1" });
    try cf.put(alloc, "text", .{ .string = "first" });
    try b.dispatch("comment", null, null, &cf);
    var cf2: std.json.ObjectMap = .empty;
    defer cf2.deinit(alloc);
    try cf2.put(alloc, "post", .{ .string = "1" });
    try cf2.put(alloc, "text", .{ .string = "second" });
    try b.dispatch("comment", null, null, &cf2);
    const c2 = mm.comments.items[1].id;

    // Attach both sessions to the thread route (shared anon group).
    try serveBoth(alloc, a, b, "/t/1");

    // Like the newer comment: b's token gets the vote, a second toggle
    // from the same session removes it — one vote per account.
    var idbuf: [24]u8 = undefined;
    const carg = std.fmt.bufPrint(&idbuf, "c{d}", .{c2}) catch unreachable;
    try a.dispatch("like", carg, null, null);
    try std.testing.expectEqual(@as(u32, 1), mm.likeCount(c2));
    try a.dispatch("like", carg, null, null);
    try std.testing.expectEqual(@as(u32, 0), mm.likeCount(c2));
    // Bad targets rejected.
    try std.testing.expectError(error.InvalidAction, a.dispatch("like", "x1", null, null));
    const missing = std.fmt.bufPrint(&idbuf, "c{d}", .{@as(u64, 999)}) catch unreachable;
    try std.testing.expectError(error.CommentNotFound, a.dispatch("like", missing, null, null));

    // Sort action flips the per-session preference and re-keys the
    // render group: absent destination key → clone-fork, NO epoch bump.
    try std.testing.expect(a.deps.attached);
    const epoch_before = a.deps.membership_epoch;
    try a.dispatch("sort", "top", null, null);
    try std.testing.expectEqual(boardview.Sort.top, a.deps.sort);
    try std.testing.expectError(error.InvalidAction, a.dispatch("sort", "bogus", null, null));
    // syncMembership runs on render; force one via publishPending path
    // is implicit in tests that call render — call it directly.
    syncMembership(a);
    try std.testing.expectEqual(epoch_before, a.deps.membership_epoch);
    try std.testing.expect(a.deps.group != null);
    try std.testing.expect(std.mem.indexOf(u8, a.deps.group.?.key_string, "top") != null);
    // The stored Key (not just the string) must carry the sort — the
    // group's viewEnv renders from it.
    try std.testing.expectEqual(boardview.Sort.top, a.deps.group.?.key.sort);
    try a.dispatch("sort", "new", null, null);
    syncMembership(a);
    try std.testing.expectEqual(boardview.Sort.new, a.deps.sort);
    try std.testing.expectEqual(boardview.Sort.new, a.deps.group.?.key.sort);
    try std.testing.expect(std.mem.indexOf(u8, a.deps.group.?.key_string, "new") != null);
}

test "dirty-only dispatch: unrelated scope mutations skip group renders" {
    const alloc = std.testing.allocator;
    const mm = testModel(alloc);
    defer mm.deinit();
    model.shared = mm;
    defer model.shared = null;
    _ = try mm.addPost("b", "tok", "post one");
    _ = try mm.addPost("b", "tok", "post two");

    const a = createSession(alloc, std.testing.io);
    defer a.deinit();
    const b = createSession(alloc, std.testing.io);
    defer b.deinit();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.testing.expect(try a.servePage("/t/1", &aw.writer));
    _ = aw.writer.consumeAll();
    try std.testing.expect(try b.servePage("/t/2", &aw.writer));
    const ga = a.deps.group.?;
    const gb = b.deps.group.?;
    const rev_a = ga.rev;
    const rev_b = gb.rev;

    // Comment on post 2: only post-2's scope (plus board/home card
    // counts) bumps — /t/1's group must not re-render at all.
    var cf: std.json.ObjectMap = .empty;
    defer cf.deinit(alloc);
    try cf.put(alloc, "post", .{ .string = "2" });
    try cf.put(alloc, "text", .{ .string = "on two" });
    try b.dispatch("comment", null, null, &cf);
    a.syncPull();
    b.syncPull();
    try std.testing.expectEqual(rev_a, ga.rev); // skipped: scope untouched
    try std.testing.expect(gb.rev > rev_b); // rendered: its scope bumped

    // Comment on post 1 now renders /t/1's group.
    var cf2: std.json.ObjectMap = .empty;
    defer cf2.deinit(alloc);
    try cf2.put(alloc, "post", .{ .string = "1" });
    try cf2.put(alloc, "text", .{ .string = "on one" });
    try a.dispatch("comment", null, null, &cf2);
    a.syncPull();
    try std.testing.expect(ga.rev > rev_a);
}
