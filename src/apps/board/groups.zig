//! Board-owned render groups (see ARCHITECTURE.md "Astra review: render
//! groups — verdict + corrected design"). Sessions whose view inputs are
//! identical — canonical route, inline-reply target, resolved display
//! name — share ONE Dom/PatchLog/History and a group-local revision
//! instead of each session rendering the shared BoardModel privately.
//!
//! Contracts implemented here:
//!   - The group key is immutable; membership changes are signalled to
//!     the SSE stream via the session's `membership_epoch` and ALWAYS
//!     entered via snapshot — revision numbers are group-local and never
//!     imply baseline equality across groups (cursor 40 vs group latest
//!     7 would return empty, not a gap).
//!   - A group is created seeded from current state (Dom synced by a
//!     discarded diff) with a FRESH history; members attach via snapshot.
//!     No Dom/history cloning in v1.
//!   - `render` dedups on `last_rendered_seq` vs `BoardModel.global_seq`:
//!     any member's ping/syncPull may trigger the single group render;
//!     `publish` ships it exactly once (rev == history.latest_rev after).
//!   - Empty groups are destroyed on last leave; the map frees its
//!     storage when it empties so tests/servers never leak it.
const std = @import("std");
const forest = @import("forest");
const History = @import("../../server/history.zig").History;
const zmeta = @import("zmeta.zig");
const app = @import("app.zig");
const model = @import("entities/model.zig");
const components = @import("shared/components.zig");
const routes = @import("gen/routes.zig");

/// Immutable group-key inputs. `name` is borrowed only for the duration
/// of `join`/`keyStringInto`; the group stores its own copy as a suffix
/// of `key_string`. `account_id` is the auth dimension (ADR-0001
/// phase 2): null = anonymous viewer, else the account id — it gates
/// own-content delete buttons in the view, so it MUST be a key input
/// (two accounts rendering the same page still diverge on deletes).
pub const Key = struct {
    route: components.Route,
    reply_to: ?u64,
    /// Resolved auth display name ("@<account>" / "Anon#N" / "anon") —
    /// NOT the user token: sessions with identical rendered identity
    /// share a group. Account names are unique+immutable, so "@name"
    /// is bijective with `account_id` (both carried anyway: the view
    /// needs the numeric id for ownership checks).
    name: []const u8,
    /// Top-level comment sort — per-session view input like reply_to.
    sort: components.Sort = .new,
    /// Viewer account id (null = anonymous) — auth group dimension.
    account_id: ?u64 = null,
};

/// The deps a render group hands the generated view dispatch: the
/// session-shaped stand-in `routes.viewNodes` needs (`s.deps.route`
/// for the switch, `s.deps.viewEnv()` for pages/layouts). Carries the
/// group key's view inputs verbatim — the group's `ViewEnv` IS the
/// key minus the wire-route dispatch detail. `seen` points at the
/// group's `last_rendered_seq`: `viewEnv` stamps it exactly like
/// `BoardDeps.viewEnv` stamps the session's `seen_seq`, preserving
/// the §4.4 cursor split (group builds write ONLY the group cursor).
const GroupDeps = struct {
    /// Wire route for `routes.viewNodes` dispatch — derived from the
    /// domain key route (`wireRoute` below).
    route: routes.Route,
    /// Domain route — what `ViewEnv.route`/nav state key on.
    page: components.Route,
    reply_to: ?u64,
    sort: components.Sort,
    name: []const u8,
    account_id: ?u64,
    /// `&RenderGroup.last_rendered_seq` — the group's render cursor.
    seen: *u64,

    /// The group's `ViewEnv` — same fields `BoardDeps.viewEnv`
    /// produces, sourced from the immutable key instead of session
    /// state. Stamps `seen` because every call IS a view build.
    pub fn viewEnv(self: *GroupDeps) components.ViewEnv {
        self.seen.* = model.get().global_seq.load(.seq_cst);
        return .{
            .route = self.page,
            .reply_to = self.reply_to,
            .sort = self.sort,
            .name = self.name,
            .account_id = self.account_id,
            .seen = self.seen,
        };
    }
};

/// Minimal session stand-in for `routes.viewNodes(a, s, env)` — the
/// generated dispatch only reads `s.deps`.
const GroupSession = struct {
    deps: GroupDeps,
};

/// Domain route → generated wire route, for the group's viewNodes
/// dispatch. `/b/:slug` re-resolves the board INDEX back to its slug
/// through the static board table; the comment permalink's `post`
/// param is view-irrelevant (the comment id is authoritative) so a
/// deleted comment's post falls back to 0.
fn wireRoute(route: components.Route) routes.Route {
    return switch (route) {
        .home => .{ .index = .{} },
        .board => |i| .{ .b = .{ .slug = model.boards[i].slug } },
        .thread => |pid| .{ .t = .{ .post = pid } },
        .comment => |cid| blk: {
            const post: u64 = if (model.get().comment(cid)) |c| c.post else 0;
            break :blk .{ .t_c = .{ .post = post, .comment = cid } };
        },
        .login => .{ .login = .{} },
        .register => .{ .register = .{} },
    };
}

/// One render group: shared tracked DOM state, patch log, revisioned
/// history ring, scratch arena, member count, and the dedup cursors.
pub const RenderGroup = struct {
    gpa: std.mem.Allocator,
    /// Canonical key encoding — the registry map key AND the owned
    /// storage backing `key.name` (a suffix slice of it).
    key_string: []u8,
    key: Key,
    /// Unique incarnation — distinguishes a recreated group instance
    /// from a destroyed one under the same key.
    incarnation: u64,
    members: usize = 0,
    dom: forest.Dom,
    log: forest.PatchLog,
    history: History,
    /// Scratch arena for view builds + diff row html (the per-session
    /// `render_arena` role, now per-group).
    arena: std.heap.ArenaAllocator,
    /// Latest published batch revision — invariant: `rev ==
    /// history.latest_rev` because render+publish are atomic under the
    /// server mutex and every render publishes immediately.
    rev: u64 = 0,
    /// `BoardModel.global_seq` the Dom last diffed against — the dedup
    /// cursor. Written only by view builds that actually sync the Dom
    /// (seed/render), never by SSR/snapshot serialization.
    last_rendered_seq: u64 = 0,
    /// Forces one render even when scopes are current — set by
    /// `fork`, whose view inputs differ from the cloned Dom's while
    /// the model may not have moved.
    needs_render: bool = false,
    /// The single model scope this group's route reads (dirty-only
    /// dispatch): `scope_seq[scope]` vs `scope_seen` decides whether
    /// buildView+diff runs at all.
    scope: u64 = 0,
    /// Scope version the Dom last diffed against.
    scope_seen: u64 = 0,

    /// The group's current view through the GENERATED dispatch — the
    /// same `routes.viewNodes` pipeline sessions use (page view +
    /// `_layout.zig` chrome), with a `GroupSession` stand-in carrying
    /// the key's view inputs. The fabricated `zmeta.Env.route` is the
    /// canonical href — groups have no request path, and pages read
    /// view state from `s.deps`, not the env.
    fn viewNodes(self: *RenderGroup, a: std.mem.Allocator) []const forest.Node {
        var fake: GroupSession = .{ .deps = .{
            .route = wireRoute(self.key.route),
            .page = self.key.route,
            .reply_to = self.key.reply_to,
            .sort = self.key.sort,
            .name = self.key.name,
            .account_id = self.key.account_id,
            .seen = &self.last_rendered_seq,
        } };
        var zenv = zmeta.Env{ .route = routes.href(a, fake.deps.route) };
        return routes.viewNodes(a, &fake, &zenv);
    }

    /// Whether the group needs no render pass: not fork-forced and the
    /// scope its route reads is at the version the Dom last diffed.
    /// A mutation on an unrelated route leaves this true — no ping, no
    /// buildView, no rev bump, no SSE traffic.
    pub fn isCurrent(self: *const RenderGroup) bool {
        return !self.needs_render and self.scope_seen == app.Session.scopeVersion(self.scope);
    }

    /// Seed a fresh group's Dom to the current view WITHOUT publishing:
    /// diffing against an empty Dom emits creates that are discarded —
    /// tracked state only. `viewNodes` stamps `last_rendered_seq`.
    fn seed(self: *RenderGroup) void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        forest.diff(a, self.viewNodes(a), &self.dom, &self.log);
        self.log.clear();
        self.scope_seen = app.Session.scopeVersion(self.scope);
    }

    /// Reconcile Dom against the shared model when a scope this group's
    /// route reads moved — THE dedup point, now per-scope: a comment on
    /// /t/6 doesn't re-render home or /t/1. Stamps the next group
    /// revision into the log; `publish` ships it.
    pub fn render(self: *RenderGroup) void {
        if (self.isCurrent()) return;
        self.needs_render = false;
        const seen = app.Session.scopeVersion(self.scope);
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        forest.diff(a, self.viewNodes(a), &self.dom, &self.log);
        self.rev += 1;
        self.log.revision = self.rev;
        self.scope_seen = seen;
    }

    /// Serialize + publish the pending batch into the group history — at
    /// most once per render (`rev <= latest_rev` means already shipped).
    pub fn publish(self: *RenderGroup) void {
        if (self.rev <= self.history.latest_rev) {
            self.log.clear();
            return;
        }
        var jaw: std.Io.Writer.Allocating = .init(self.gpa);
        defer jaw.deinit();
        self.log.writeJson(&jaw.writer) catch @panic("OOM");
        self.history.publish(self.rev, jaw.toOwnedSlice() catch @panic("OOM"));
        self.log.clear();
    }
};

// ── registry ──────────────────────────────────────────────────────
// Module-global like `model.shared`: all access is serialized by the
// server's session mutex, and groups never outlive their members (the
// last `leave` destroys the group; the map frees its storage at empty).

var groups: std.StringHashMapUnmanaged(*RenderGroup) = .empty;
var next_incarnation: u64 = 1;

/// Canonical key encoding: "\x01"-separated route code, reply marker,
/// sort, account class and display name. Components are server-generated
/// (fixed route codes, u64 ids, "acct:<id>"/"anon", "@name"/"Anon#<base36>"/
/// "anon" names) so the separator cannot appear inside a field — the
/// encoding is injective for every reachable key. `buf` must hold
/// ~224 bytes; the result borrows `buf`.
pub fn keyStringInto(buf: []u8, route: components.Route, reply_to: ?u64, name: []const u8, sort: components.Sort, account_id: ?u64) []const u8 {
    var rbuf: [48]u8 = undefined;
    const rpart = switch (route) {
        .home => "home",
        .board => |i| std.fmt.bufPrint(&rbuf, "board:{d}", .{i}) catch unreachable,
        .thread => |id| std.fmt.bufPrint(&rbuf, "thread:{d}", .{id}) catch unreachable,
        .comment => |id| std.fmt.bufPrint(&rbuf, "comment:{d}", .{id}) catch unreachable,
        .login => "login",
        .register => "register",
    };
    var pbuf: [24]u8 = undefined;
    const ppart = if (reply_to) |r| std.fmt.bufPrint(&pbuf, "reply:{d}", .{r}) catch unreachable else "reply:-";
    const spart = if (sort == .top) "top" else "new";
    var abuf: [24]u8 = undefined;
    const apart = if (account_id) |id| std.fmt.bufPrint(&abuf, "acct:{d}", .{id}) catch unreachable else "anon";
    // name stays LAST: createGroup borrows it as the key_string suffix.
    return std.fmt.bufPrint(buf, "{s}\x01{s}\x01{s}\x01{s}\x01{s}", .{ rpart, ppart, spart, apart, name }) catch @panic("group key buf too small");
}

/// Live group count — test/diagnostic helper.
pub fn registryCount() usize {
    return groups.count();
}

/// Whether a group is registered under `key`'s canonical encoding —
/// syncMembership forks (clone-on-fork) only for ABSENT keys; a present
/// key means joining a foreign stream namespace → snapshot.
pub fn contains(key: Key) bool {
    var kbuf: [256]u8 = undefined;
    const ks = keyStringInto(&kbuf, key.route, key.reply_to, key.name, key.sort, key.account_id);
    return groups.get(ks) != null;
}

/// Allocate a registered-candidate group shell: fresh empty Dom/log/
/// history/arena, unique incarnation, owned key string. Callers then
/// either `seed()` (join) or overwrite dom/history/rev (fork) before
/// `groups.put` + `members = 1`.
fn createGroup(gpa: std.mem.Allocator, ks: []const u8, key: Key) *RenderGroup {
    const g = gpa.create(RenderGroup) catch @panic("OOM");
    g.* = .{
        .gpa = gpa,
        .key_string = undefined,
        .key = .{ .route = key.route, .reply_to = key.reply_to, .name = &.{}, .sort = key.sort, .account_id = key.account_id },
        .scope = app.Session.scopeForRoute(key.route),
        .incarnation = next_incarnation,
        .dom = forest.Dom.init(gpa),
        .log = forest.PatchLog.init(gpa),
        .history = History.init(gpa),
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    next_incarnation += 1;
    g.key_string = gpa.dupe(u8, ks) catch @panic("OOM");
    // The name is the last \x01-separated field — borrow the owned copy.
    const name_at = std.mem.lastIndexOfScalar(u8, g.key_string, 1).? + 1;
    g.key.name = g.key_string[name_at..];
    return g;
}

/// Find or create the group for `key`; a new group is seeded from current
/// state with a fresh (empty) history — its first publish is rev 1.
/// `members` is incremented on every call; pair with `leave`.
pub fn join(gpa: std.mem.Allocator, key: Key) *RenderGroup {
    var kbuf: [256]u8 = undefined;
    const ks = keyStringInto(&kbuf, key.route, key.reply_to, key.name, key.sort, key.account_id);
    if (groups.get(ks)) |g| {
        g.members += 1;
        return g;
    }
    const g = createGroup(gpa, ks, key);
    g.seed();
    groups.put(gpa, g.key_string, g) catch @panic("OOM");
    g.members = 1;
    return g;
}

/// Clone-on-fork (ARCHITECTURE.md "Render groups v2"): create a group
/// under `key` that CONTINUES `src`'s stream lineage — same `rev`
/// numbering, a verbatim copy of the retained history ring, and a Dom
/// tracking exactly what src's clients were patched to. The next
/// render diffs the NEW view inputs against the cloned Dom and emits
/// only the transition ops, so the forking client's SSE cursor stays
/// valid and no snapshot is needed (the session must NOT bump
/// `membership_epoch` for this transition).
///
/// Preconditions: `key` absent from the registry (checked by the
/// caller via `contains`); `src.members > 0`; all under the server
/// mutex. The caller still owes `leave(src)` — the fork shares nothing
/// mutable with src afterwards.
pub fn fork(gpa: std.mem.Allocator, src: *RenderGroup, key: Key) *RenderGroup {
    src.publish(); // defensive: render+publish are atomic under the mutex, never clone a pending log
    var kbuf: [256]u8 = undefined;
    const ks = keyStringInto(&kbuf, key.route, key.reply_to, key.name, key.sort, key.account_id);
    std.debug.assert(groups.get(ks) == null);
    const g = createGroup(gpa, ks, key);
    // The fresh dom/history shells hold no allocations — overwrite.
    g.dom = src.dom.cloneDeep();
    g.history = src.history.cloneDeep();
    g.rev = src.rev;
    g.last_rendered_seq = src.last_rendered_seq;
    g.needs_render = true;
    groups.put(gpa, g.key_string, g) catch @panic("OOM");
    g.members = 1;
    return g;
}

/// Release one membership. The group is destroyed when its last member
/// leaves — Dom/log/history/arena/key freed, and the map's storage is
/// released too once it empties (keeps test allocators leak-clean).
pub fn leave(gpa: std.mem.Allocator, g: *RenderGroup) void {
    std.debug.assert(g.members > 0);
    g.members -= 1;
    if (g.members != 0) return;
    _ = groups.fetchRemove(g.key_string);
    if (groups.count() == 0) {
        groups.deinit(gpa);
        groups = .empty;
    }
    g.dom.deinit();
    g.log.deinit();
    g.history.deinit();
    g.arena.deinit();
    g.gpa.free(g.key_string);
    g.gpa.destroy(g);
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "key encoding is injective across route/reply/name/account" {
    var bufs: [4][256]u8 = undefined;
    const a = keyStringInto(&bufs[0], .home, null, "anon", .new, null);
    const b = keyStringInto(&bufs[1], .home, null, "Anon#1", .new, null);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    const c = keyStringInto(&bufs[1], .home, @as(?u64, 7), "anon", .new, null);
    try std.testing.expect(!std.mem.eql(u8, a, c));
    const d = keyStringInto(&bufs[1], .{ .thread = 7 }, null, "anon", .new, null);
    try std.testing.expect(!std.mem.eql(u8, a, d));
    const e = keyStringInto(&bufs[1], .home, null, "anon", .new, null);
    try std.testing.expect(std.mem.eql(u8, a, e));
    // Auth dimension: same route/name/sort, different account class.
    const f = keyStringInto(&bufs[2], .home, null, "@alice", .new, @as(?u64, 7));
    try std.testing.expect(!std.mem.eql(u8, a, f));
    const g = keyStringInto(&bufs[3], .home, null, "@alice", .new, @as(?u64, 8));
    try std.testing.expect(!std.mem.eql(u8, f, g));
    const h = keyStringInto(&bufs[2], .home, null, "@alice", .new, @as(?u64, 7));
    try std.testing.expect(std.mem.eql(u8, f, h));
}
