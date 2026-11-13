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
const History = @import("server/history.zig").History;
const board_app = @import("board_app.zig");

/// Immutable group-key inputs. `name` is borrowed only for the duration
/// of `join`/`keyStringInto`; the group stores its own copy as a suffix
/// of `key_string`.
pub const Key = struct {
    route: board_app.Route,
    reply_to: ?u64,
    /// Resolved display name ("Anon#N" / "anon") — NOT the user token:
    /// two tokens resolving to the same name render identically.
    name: []const u8,
};

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
    /// Forces one render even when `global_seq` is unchanged — set by
    /// `fork`, whose view inputs differ from the cloned Dom's while the
    /// model may not have moved.
    needs_render: bool = false,

    fn viewEnv(self: *RenderGroup) board_app.ViewEnv {
        return .{
            .route = self.key.route,
            .reply_to = self.key.reply_to,
            .name = self.key.name,
            .seen = &self.last_rendered_seq,
        };
    }

    /// Seed a fresh group's Dom to the current view WITHOUT publishing:
    /// diffing against an empty Dom emits creates that are discarded —
    /// tracked state only. `buildView` stamps `last_rendered_seq`.
    fn seed(self: *RenderGroup) void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        forest.diff(a, board_app.buildView(a, self.viewEnv()), &self.dom, &self.log);
        self.log.clear();
    }

    /// Reconcile Dom against the current shared model when `global_seq`
    /// moved — THE dedup point: any member may trigger it, the rest see
    /// `last_rendered_seq` already current and skip. Stamps the next
    /// group revision into the log; `publish` ships it.
    pub fn render(self: *RenderGroup) void {
        const seq = board_app.globalSeq();
        if (!self.needs_render and self.last_rendered_seq == seq) return;
        self.needs_render = false;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        forest.diff(a, board_app.buildView(a, self.viewEnv()), &self.dom, &self.log);
        self.rev += 1;
        self.log.revision = self.rev;
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
// Module-global like `board_app.model`: all access is serialized by the
// server's session mutex, and groups never outlive their members (the
// last `leave` destroys the group; the map frees its storage at empty).

var groups: std.StringHashMapUnmanaged(*RenderGroup) = .empty;
var next_incarnation: u64 = 1;

/// Canonical key encoding: "\x01"-separated route code, reply marker and
/// display name. Components are server-generated (fixed route codes,
/// u64 ids, "Anon#<base36>"/"anon" names) so the separator cannot appear
/// inside a field — the encoding is injective for every reachable key.
/// `buf` must hold ~192 bytes; the result borrows `buf`.
pub fn keyStringInto(buf: []u8, route: board_app.Route, reply_to: ?u64, name: []const u8) []const u8 {
    var rbuf: [48]u8 = undefined;
    const rpart = switch (route) {
        .home => "home",
        .board => |i| std.fmt.bufPrint(&rbuf, "board:{d}", .{i}) catch unreachable,
        .thread => |id| std.fmt.bufPrint(&rbuf, "thread:{d}", .{id}) catch unreachable,
        .comment => |id| std.fmt.bufPrint(&rbuf, "comment:{d}", .{id}) catch unreachable,
    };
    var pbuf: [24]u8 = undefined;
    const ppart = if (reply_to) |r| std.fmt.bufPrint(&pbuf, "reply:{d}", .{r}) catch unreachable else "reply:-";
    return std.fmt.bufPrint(buf, "{s}\x01{s}\x01{s}", .{ rpart, ppart, name }) catch @panic("group key buf too small");
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
    const ks = keyStringInto(&kbuf, key.route, key.reply_to, key.name);
    return groups.get(ks) != null;
}

/// Allocate a registered-candidate group shell: fresh empty Dom/log/
/// history/arena, unique incarnation, owned key string. Callers then
/// either `seed()` (join) or overwrite dom/history/rev (fork) before
/// `groups.put` + `members = 1`.
fn createGroup(gpa: std.mem.Allocator, ks: []const u8, route: board_app.Route, reply_to: ?u64) *RenderGroup {
    const g = gpa.create(RenderGroup) catch @panic("OOM");
    g.* = .{
        .gpa = gpa,
        .key_string = undefined,
        .key = .{ .route = route, .reply_to = reply_to, .name = &.{} },
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
    const ks = keyStringInto(&kbuf, key.route, key.reply_to, key.name);
    if (groups.get(ks)) |g| {
        g.members += 1;
        return g;
    }
    const g = createGroup(gpa, ks, key.route, key.reply_to);
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
    const ks = keyStringInto(&kbuf, key.route, key.reply_to, key.name);
    std.debug.assert(groups.get(ks) == null);
    const g = createGroup(gpa, ks, key.route, key.reply_to);
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

test "key encoding is injective across route/reply/name" {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const a = keyStringInto(&b1, .home, null, "anon");
    const b = keyStringInto(&b2, .home, null, "Anon#1");
    try std.testing.expect(!std.mem.eql(u8, a, b));
    const c = keyStringInto(&b2, .home, @as(?u64, 7), "anon");
    try std.testing.expect(!std.mem.eql(u8, a, c));
    const d = keyStringInto(&b2, .{ .thread = 7 }, null, "anon");
    try std.testing.expect(!std.mem.eql(u8, a, d));
    const e = keyStringInto(&b2, .home, null, "anon");
    try std.testing.expect(std.mem.eql(u8, a, e));
}
