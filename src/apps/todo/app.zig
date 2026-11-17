//! todo — the TodoMVC demo on the zmeta `Session(Deps)` skeleton
//! (docs/meta-framework.md §5): file-based routing (single "/" page),
//! comptime action table, per-session model. The view lives in
//! `pages/index.zig`; this file holds the domain model, the mutation
//! graph, action handlers, and the session tests.
//!
//! Persistence: when `store.shared` is installed (main.zig opens the
//! sqlite db before serve), todos are write-through persisted keyed by
//! the `ztd` client cookie — NOT the session, which is evicted and
//! recreated. First contact mints the cookie on the first POST;
//! `readCookies` picks it up on later GETs/POSTs and lazy-loads the
//! client's rows into the same in-memory model the view already uses.
const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const zserver = @import("zserver");
const zmeta = @import("zmeta.zig");
const routes = @import("gen/routes.zig");
const actions = @import("gen/actions.zig");
const store = @import("store.zig");

pub const Route = routes.Route;
pub const act = actions.act;

pub const Filter = enum {
    all,
    active,
    completed,

    pub fn name(f: Filter) []const u8 {
        return switch (f) {
            .all => "all",
            .active => "active",
            .completed => "completed",
        };
    }

    pub fn parse(s: []const u8) ?Filter {
        if (std.mem.eql(u8, s, "all")) return .all;
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        return null;
    }
};

pub const Todo = struct { id: u32, title: []u8, done: bool };

/// Sparse per-item UI state: an entry exists only while the todo is in
/// an interactive mode (inline editing). Presence in `ui_state` IS the
/// mode flag — a missing key means all defaults, so idle rows cost zero
/// allocations. `draft` owns its bytes and is freed with the entry.
pub const ItemUi = struct {
    draft: []u8,
};

const Mutation = union(enum) {
    add: []const u8,
    toggle: u32,
    set_checked: struct { id: u32, done: bool },
    delete: u32,
    filter: Filter,
    edit_start: u32,
    edit_save: struct { id: u32, text: []const u8 },
    edit_cancel: u32,
};

pub const max_title_len = 500;
pub const max_todos = 1000;

pub const ActionError = error{ InvalidAction, InvalidTitle, TodoNotFound, TooManyTodos };

/// Todo app state + graph handles — the zmeta `Deps` (docs/meta-framework.md
/// §5.2-5.3). The `zmeta.Session` skeleton owns the transport contract
/// (Dom/log/history/arena/CSRF/seq/render hook); everything domain-
/// specific — model fields, the mutation event, derived stores, action
/// validation — lives here. Session contract for the generic server is
/// provided by the skeleton (see zmeta/session.zig).
pub const TodoDeps = struct {
    /// Page <title> and <main> class rendered by the server's page shell.
    pub const page_title = "zforest todos";
    pub const page_class = "app";
    /// Session cookie name — "zfxb" on the board app to avoid clobbering
    /// this app's session on the same host.
    pub const cookie_name = "zfxs";
    /// `ztd` client-identity cookie — the persistence key (NOT the
    /// session): minted into `Session.out_cookie` on first POST,
    /// picked up by `Deps.readCookies`. Todos are stored per client_id
    /// so they survive session eviction AND server restarts; two tabs
    /// of one browser share them.
    pub const client_cookie_name = "ztd";

    /// Current typed route — written by the generated `routes.setRoute`
    /// glue; read by `routes.prepare`/`routes.viewNodes` dispatch.
    route: routes.Route = .{ .index = .{} },

    todos: std.ArrayListUnmanaged(Todo) = .empty,
    next_id: u32 = 1,
    filter: Filter = .all,
    /// Sparse per-item UI state keyed by todo id (see ItemUi).
    ui_state: std.AutoHashMapUnmanaged(u32, ItemUi) = .empty,
    /// `ztd` cookie value — the persistence key. Owned copy ("" =
    /// anonymous: no store installed, or first contact not yet POSTed).
    client_id: []u8 = &.{},
    /// Scratch for the one-shot `ztd` Set-Cookie staged on the
    /// minting POST — `Session.out_cookie` points into it.
    out_cookie_buf: [128]u8 = undefined,
    /// True once this session's persisted todos have been loaded (or
    /// there was nothing to load) — guards the lazy SELECT in
    /// `ensureLoaded`.
    loaded: bool = false,

    mutate: *zefx.Event(Mutation),
    remaining: *zefx.Store(usize),

    /// `Deps.init` — create the graph handles on the session's engine.
    /// `seq` already exists; `wire` registers the reducers next.
    pub fn init(s: *Session) TodoDeps {
        return .{
            .mutate = s.app.createEvent(Mutation),
            .remaining = s.app.createStore(usize, 0),
        };
    }

    /// `Deps.deinit` — free domain allocations. Runs before the
    /// skeleton tears down dom/log/history/arena/app.
    pub fn deinit(s: *Session) void {
        for (s.deps.todos.items) |t| s.gpa.free(t.title);
        s.deps.todos.deinit(s.gpa);
        var uiit = s.deps.ui_state.valueIterator();
        while (uiit.next()) |ui| s.gpa.free(ui.draft);
        s.deps.ui_state.deinit(s.gpa);
        if (s.deps.client_id.len != 0) s.gpa.free(s.deps.client_id);
    }

    /// `Deps.wire` — pure-phase reducers. The skeleton installs the
    /// render after-flush hook after this returns.
    pub fn wire(s: *Session) void {
        s.deps.mutate.onReducer(s, &applyMutation);
        // Derived store: remaining count recomputes from seq updates and
        // settles in the pure phase, before any view work.
        s.seq.updates().onReducer(s, &updateRemaining);
    }

    /// Route validation + typed-route storage — generated glue.
    pub fn setRoute(s: *Session, path: []const u8) bool {
        return routes.setRoute(s, path);
    }

    /// Pure route pre-check — generated glue.
    pub fn validPath(path: []const u8) bool {
        return routes.validPath(path);
    }

    /// `Deps.readCookies` — pick up the `ztd` client cookie before
    /// dispatch/page render (the server calls it with the raw Cookie
    /// header on every /action POST and page GET). First contact wins:
    /// a session that minted its own token never re-reads the cookie,
    /// matching board's `zfxu` semantics.
    pub fn readCookies(s: *Session, cookie_hdr: ?[]const u8) void {
        const h = cookie_hdr orelse return;
        if (s.deps.client_id.len != 0) return;
        var it = std.mem.splitScalar(u8, h, ';');
        while (it.next()) |part| {
            const kv = std.mem.trim(u8, part, " \t");
            const p = client_cookie_name ++ "=";
            if (!std.mem.startsWith(u8, kv, p)) continue;
            const v = kv[p.len..];
            if (v.len == 0) return;
            s.deps.client_id = s.gpa.dupe(u8, v) catch @panic("OOM");
            ensureLoaded(s);
            return;
        }
    }

    /// Route-param gate — generated dispatch to page `prepare`s.
    pub fn prepare(s: *Session, env: *const zmeta.Env) !void {
        try routes.prepare(s, env);
    }

    /// The `<main>` body — generated dispatch to the active page's view.
    pub fn view(a: std.mem.Allocator, s: *Session, env: *const zmeta.Env) []const forest.Node {
        return routes.viewNodes(a, s, env);
    }

    /// Whitelisted action entry — generated dispatch to `on_<name>`.
    /// This wrapper owns the pieces EVERY action shares: the one-shot
    /// `out_cookie` reset, first-contact `ztd` minting, and the lazy
    /// persisted-state load (board's dispatch does the same for `zfxu`).
    pub fn dispatch(
        s: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
        // `out_cookie` is a one-shot: the server emits it on this
        // response only — later POSTs must not re-send Set-Cookie.
        s.out_cookie = "";
        ensureIdentity(s);
        ensureLoaded(s);
        return actions.dispatch(s, action, arg, value, fields);
    }

    /// act.add — new todo; `fields.title` required, trimmed, length- and
    /// count-capped. Empty/whitespace submit is a silent no-op (TodoMVC).
    pub fn on_add(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = arg;
        _ = value;
        const m = fields orelse return error.InvalidAction;
        const fv = m.get("title") orelse return error.InvalidAction;
        const raw = switch (fv) {
            .string => |t| t,
            else => return error.InvalidAction,
        };
        const title = std.mem.trim(u8, raw, " \t\r\n");
        if (title.len == 0) return;
        if (title.len > max_title_len) return error.InvalidTitle;
        if (s.deps.todos.items.len >= max_todos) return error.TooManyTodos;
        s.deps.mutate.emit(.{ .add = title });
    }

    /// act.toggle — flip done on the `arg` todo id.
    pub fn on_toggle(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = value;
        _ = fields;
        const tid = try argId(s, arg);
        s.deps.mutate.emit(.{ .toggle = tid });
    }

    /// act.set_checked — checkbox change; `arg` id + `value` true/false.
    pub fn on_set_checked(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = fields;
        const tid = try argId(s, arg);
        const v = value orelse return error.InvalidAction;
        const done = if (std.mem.eql(u8, v, "true")) true else if (std.mem.eql(u8, v, "false")) false else return error.InvalidAction;
        s.deps.mutate.emit(.{ .set_checked = .{ .id = tid, .done = done } });
    }

    /// act.delete — remove the `arg` todo.
    pub fn on_delete(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = value;
        _ = fields;
        const tid = try argId(s, arg);
        s.deps.mutate.emit(.{ .delete = tid });
    }

    /// act.filter — `arg` is the filter name (all/active/completed).
    pub fn on_filter(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = value;
        _ = fields;
        const v = arg orelse return error.InvalidAction;
        const f = Filter.parse(v) orelse return error.InvalidAction;
        s.deps.mutate.emit(.{ .filter = f });
    }

    /// act.edit — enter inline-edit mode for the `arg` todo.
    pub fn on_edit(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = value;
        _ = fields;
        const tid = try argId(s, arg);
        s.deps.mutate.emit(.{ .edit_start = tid });
    }

    /// act.edit_save — `fields.id` + `fields.text`; empty text deletes
    /// the todo (TodoMVC behaviour), non-empty is length-checked.
    pub fn on_edit_save(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = arg;
        _ = value;
        const f = fields orelse return error.InvalidAction;
        const idv = f.get("id") orelse return error.InvalidAction;
        const id_raw = switch (idv) {
            .string => |x| x,
            else => return error.InvalidAction,
        };
        const tid = std.fmt.parseInt(u32, id_raw, 10) catch return error.InvalidAction;
        if (findIdx(s, tid) == null) return error.TodoNotFound;
        const tv = f.get("text") orelse return error.InvalidAction;
        const raw = switch (tv) {
            .string => |t| t,
            else => return error.InvalidAction,
        };
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len > max_title_len) return error.InvalidTitle;
        s.deps.mutate.emit(.{ .edit_save = .{ .id = tid, .text = text } });
    }

    /// act.edit_cancel — leave inline-edit mode, keep the title.
    pub fn on_edit_cancel(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = value;
        _ = fields;
        const tid = try argId(s, arg);
        s.deps.mutate.emit(.{ .edit_cancel = tid });
    }
};

/// One browser session: an isolated zefx graph + todo model + DOM patch
/// state, provided by the zmeta skeleton (see zmeta/session.zig).
pub const Session = zmeta.Session(TodoDeps);

/// Wired session constructor for tests — the server mints sessions via
/// `Session.create(gpa, io)`; todo mints no tokens so `io` is unused.
pub fn createSession(gpa: std.mem.Allocator) *Session {
    return Session.create(gpa, std.testing.io);
}

// ── model helpers ────────────────────────────────────────────────

fn findIdx(s: *Session, id: u32) ?usize {
    for (s.deps.todos.items, 0..) |t, i| {
        if (t.id == id) return i;
    }
    return null;
}

/// The item's UI entry, or null when idle — presence means editing.
pub fn uiEntry(s: *Session, id: u32) ?*ItemUi {
    return s.deps.ui_state.getPtr(id);
}

/// Drop a todo's sparse UI entry, freeing its draft. No-op for idle
/// items — the common case is a single hash lookup.
fn clearUi(s: *Session, id: u32) void {
    if (s.deps.ui_state.fetchRemove(id)) |kv| s.gpa.free(kv.value.draft);
}

/// Filter predicate shared by the list view and row rendering.
pub fn visible(s: *Session, t: Todo) bool {
    return switch (s.deps.filter) {
        .all => true,
        .active => !t.done,
        .completed => t.done,
    };
}

/// Parse a `data-arg` todo id: missing/invalid → InvalidAction,
/// unknown → TodoNotFound.
fn argId(s: *Session, arg: ?[]const u8) ActionError!u32 {
    const a = arg orelse return error.InvalidAction;
    const tid = std.fmt.parseInt(u32, a, 10) catch return error.InvalidAction;
    if (findIdx(s, tid) == null) return error.TodoNotFound;
    return tid;
}

/// seq.updates reducer — recounts unfinished todos in the pure phase.
fn updateRemaining(s: *Session, _: u64) void {
    var n: usize = 0;
    for (s.deps.todos.items) |t| {
        if (!t.done) n += 1;
    }
    s.deps.remaining.set(n);
}

// ── persistence (ztd client-keyed SQLite, store.zig) ─────────────
// All helpers no-op when `store.shared` is null (in-memory demo) or
// the session has no client identity yet. Db errors panic — a broken
// store is a broken server, matching the @panic("OOM") style.

/// First POST establishes client identity: mint a `ztd` token (16
/// io-random bytes as 32 lowercase hex chars — unguessable,
/// cookie-safe) and stage the one-shot Set-Cookie. No store installed
/// → persistence disabled → behave exactly like the old demo.
fn ensureIdentity(s: *Session) void {
    if (store.shared == null) return;
    if (s.deps.client_id.len != 0) return;
    var rb: [16]u8 = undefined;
    s.io.random(&rb);
    const hex = std.fmt.bytesToHex(rb, .lower);
    s.deps.client_id = s.gpa.dupe(u8, &hex) catch @panic("OOM");
    s.out_cookie = std.fmt.bufPrint(&s.deps.out_cookie_buf, "{s}={s}; Path=/; HttpOnly; SameSite=Strict", .{ TodoDeps.client_cookie_name, s.deps.client_id }) catch @panic("cookie buf too small");
}

/// Lazy load: the first time a session knows its `client_id` (cookie
/// pickup in `readCookies`, or the mint in `dispatch`) SELECT the
/// client's rows into the in-memory model — the same ArrayList the
/// view/diff already uses. Runs once per session; write-through keeps
/// db and memory in sync afterwards, so reloads only happen on
/// session (re)creation — eviction, restart, or a second tab sharing
/// the `ztd` cookie (last-writer-wins per row).
fn ensureLoaded(s: *Session) void {
    if (s.deps.loaded) return;
    const st = store.shared orelse return;
    if (s.deps.client_id.len == 0) return;
    var rows = st.load(s.gpa, s.deps.client_id) catch @panic("todo load failed");
    defer {
        for (rows.items) |r| s.gpa.free(r.text);
        rows.deinit(s.gpa);
    }
    for (rows.items) |r| {
        const id: u32 = @intCast(r.id);
        const owned = s.gpa.dupe(u8, r.text) catch @panic("OOM");
        s.deps.todos.append(s.gpa, .{ .id = id, .title = owned, .done = r.done }) catch @panic("OOM");
        s.deps.next_id = @max(s.deps.next_id, id +% 1);
    }
    s.deps.loaded = true;
    // `remaining` only recomputes on seq updates — recount now so the
    // footer count is right in the SSR page / first render after load.
    updateRemaining(s, 0);
}

fn persistAdd(s: *Session, id: u32, title: []const u8) void {
    const st = store.shared orelse return;
    if (s.deps.client_id.len == 0) return;
    st.insert(s.gpa, s.deps.client_id, id, title, false) catch @panic("todo persist insert failed");
}

fn persistDone(s: *Session, id: u32, done: bool) void {
    const st = store.shared orelse return;
    if (s.deps.client_id.len == 0) return;
    st.setDone(s.gpa, s.deps.client_id, id, done) catch @panic("todo persist done failed");
}

fn persistText(s: *Session, id: u32, text: []const u8) void {
    const st = store.shared orelse return;
    if (s.deps.client_id.len == 0) return;
    st.setText(s.gpa, s.deps.client_id, id, text) catch @panic("todo persist text failed");
}

fn persistDelete(s: *Session, id: u32) void {
    const st = store.shared orelse return;
    if (s.deps.client_id.len == 0) return;
    st.remove(s.gpa, s.deps.client_id, id) catch @panic("todo persist delete failed");
}

/// mutate reducer — pure-phase model change, then bump the revision.
fn applyMutation(s: *Session, m: Mutation) void {
    switch (m) {
        .add => |title| {
            const owned = s.gpa.dupe(u8, title) catch @panic("OOM");
            const id = s.deps.next_id;
            s.deps.todos.append(s.gpa, .{ .id = id, .title = owned, .done = false }) catch @panic("OOM");
            s.deps.next_id += 1;
            persistAdd(s, id, owned);
        },
        .toggle => |id| {
            const i = findIdx(s, id).?;
            s.deps.todos.items[i].done = !s.deps.todos.items[i].done;
            persistDone(s, id, s.deps.todos.items[i].done);
        },
        .set_checked => |sc| {
            const i = findIdx(s, sc.id).?;
            s.deps.todos.items[i].done = sc.done;
            persistDone(s, sc.id, sc.done);
        },
        .delete => |id| {
            clearUi(s, id);
            const i = findIdx(s, id).?;
            s.gpa.free(s.deps.todos.items[i].title);
            _ = s.deps.todos.orderedRemove(i);
            persistDelete(s, id);
        },
        .filter => |f| {
            s.deps.filter = f;
        },
        .edit_start => |id| {
            const i = findIdx(s, id).?;
            if (s.deps.ui_state.contains(id)) return;
            const draft = s.gpa.dupe(u8, s.deps.todos.items[i].title) catch @panic("OOM");
            s.deps.ui_state.put(s.gpa, id, .{ .draft = draft }) catch {
                s.gpa.free(draft);
                @panic("OOM");
            };
        },
        .edit_save => |es| {
            clearUi(s, es.id);
            const i = findIdx(s, es.id) orelse return;
            const text = std.mem.trim(u8, es.text, " \t\r\n");
            if (text.len == 0) {
                s.gpa.free(s.deps.todos.items[i].title);
                _ = s.deps.todos.orderedRemove(i);
                persistDelete(s, es.id);
                return;
            }
            const owned = s.gpa.dupe(u8, text) catch @panic("OOM");
            s.gpa.free(s.deps.todos.items[i].title);
            s.deps.todos.items[i].title = owned;
            persistText(s, es.id, s.deps.todos.items[i].title);
        },
        .edit_cancel => |id| clearUi(s, id),
    }
    s.bumpSeq();
}

/// Footer counter text — `computed` binding target for the `count` span.
pub fn countText(a: std.mem.Allocator, rem: usize) []const u8 {
    return std.fmt.allocPrint(a, "{d} item{s} left", .{ rem, if (rem == 1) "" else "s" }) catch @panic("OOM");
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

fn patchJson(s: *Session, alloc: std.mem.Allocator) []u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    s.log.writeJson(&aw.writer) catch @panic("OOM");
    s.log.clear();
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// A form-fields map as POSTed by the client for an "add" action.
fn titleFields(alloc: std.mem.Allocator, title: []const u8) std.json.ObjectMap {
    var m: std.json.ObjectMap = .empty;
    m.put(alloc, "title", .{ .string = title }) catch @panic("OOM");
    return m;
}

/// A form-fields map as POSTed by the edit form: hidden `id` + `text`.
fn editFields(alloc: std.mem.Allocator, id: []const u8, text: []const u8) std.json.ObjectMap {
    var m: std.json.ObjectMap = .empty;
    m.put(alloc, "id", .{ .string = id }) catch @panic("OOM");
    m.put(alloc, "text", .{ .string = text }) catch @panic("OOM");
    return m;
}

/// Install a TodoStore as `store.shared` for the rest of the test.
fn installStore(alloc: std.mem.Allocator, path: []const u8) *store.TodoStore {
    const st = store.TodoStore.init(alloc, path) catch @panic("store init failed");
    store.shared = st;
    return st;
}

/// Simulate a browser presenting its `ztd` cookie on the next request.
fn presentClient(s: *Session, alloc: std.mem.Allocator, client_id: []const u8) void {
    const hdr = std.fmt.allocPrint(alloc, "zfxs=x; {s}={s}", .{ TodoDeps.client_cookie_name, client_id }) catch @panic("OOM");
    defer alloc.free(hdr);
    s.readCookies(hdr);
}

/// Scratch file-db paths, unique per test PROCESS (same rationale as
/// board/entities/model.zig's tmpDbPaths — test binaries run concurrently).
const TmpDb = struct {
    path: []u8,
    wal: []u8,
    shm: []u8,

    fn deinit(self: TmpDb, a: std.mem.Allocator) void {
        a.free(self.path);
        a.free(self.wal);
        a.free(self.shm);
    }
};

fn tmpDbPaths(a: std.mem.Allocator, comptime tag: []const u8) !TmpDb {
    const base = try std.fmt.allocPrint(a, "/tmp/zforest-todo-test-{s}-{d}", .{ tag, std.c.getpid() });
    errdefer a.free(base);
    const wal = try std.fmt.allocPrint(a, "{s}-wal", .{base});
    errdefer a.free(wal);
    const shm = try std.fmt.allocPrint(a, "{s}-shm", .{base});
    errdefer a.free(shm);
    return .{ .path = base, .wal = wal, .shm = shm };
}

/// Delete the db + WAL sidecars before and after a file-db test.
fn cleanTmpDb(io: std.Io, t: TmpDb) void {
    std.Io.Dir.deleteFileAbsolute(io, t.path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, t.wal) catch {};
    std.Io.Dir.deleteFileAbsolute(io, t.shm) catch {};
}

test "generated routes: parse, href, servePage, act dispatch" {
    const alloc = std.testing.allocator;

    // Single static route: "/" parses, everything else 404s.
    try std.testing.expect(std.meta.activeTag(routes.parseRoute("/").?) == .index);
    try std.testing.expect(routes.parseRoute("/foo") == null);
    try std.testing.expect(Session.validPath("/"));
    try std.testing.expect(!Session.validPath("/foo"));
    try std.testing.expectEqualStrings("/", routes.href(alloc, .{ .index = .{} }));

    // servePage accepts "/" and rejects bogus paths.
    const s = createSession(alloc);
    defer s.deinit();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try std.testing.expect(try s.servePage("/", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "add-form") != null);
    var bw: std.Io.Writer.Allocating = .init(alloc);
    defer bw.deinit();
    try std.testing.expect(!try s.servePage("/foo", &bw.writer));
}

test "session add/toggle/delete/filter produces patches" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();
    s.seedDom();

    var f1 = titleFields(alloc, "write <b>docs</b>");
    defer f1.deinit(alloc);
    try s.dispatch("add", null, null, &f1);
    const j1 = patchJson(s, alloc);
    defer alloc.free(j1);
    try std.testing.expect(std.mem.indexOf(u8, j1, "\"op\":\"create\"") != null);
    // title is HTML-escaped in the patch, then JSON-escaped in the batch
    try std.testing.expect(std.mem.indexOf(u8, j1, "\\u0026lt;b\\u0026gt;docs\\u0026lt;/b\\u0026gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, j1, "1 item left") != null);

    var f2 = titleFields(alloc, "second");
    defer f2.deinit(alloc);
    try s.dispatch("add", null, null, &f2);
    alloc.free(patchJson(s, alloc));

    var idbuf: [16]u8 = undefined;
    try s.dispatch("toggle", std.fmt.bufPrint(&idbuf, "{d}", .{s.deps.todos.items[0].id}) catch unreachable, null, null);
    const j2 = patchJson(s, alloc);
    defer alloc.free(j2);
    try std.testing.expectEqual(@as(usize, 1), s.deps.remaining.get());
    try std.testing.expect(s.deps.todos.items[0].done);
    // toggle emits authoritative checked + class patches
    try std.testing.expect(std.mem.indexOf(u8, j2, "\"name\":\"checked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j2, "\"name\":\"class\",\"value\":\"todo done\"") != null);

    // filter to active: done row removed
    try s.dispatch("filter", "active", null, null);
    const j3 = patchJson(s, alloc);
    defer alloc.free(j3);
    try std.testing.expect(std.mem.indexOf(u8, j3, "\"op\":\"remove\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j3, "data-active") != null);

    // delete visible row
    try s.dispatch("delete", std.fmt.bufPrint(&idbuf, "{d}", .{s.deps.todos.items[1].id}) catch unreachable, null, null);
    const j4 = patchJson(s, alloc);
    defer alloc.free(j4);
    try std.testing.expectEqual(@as(usize, 1), s.deps.todos.items.len);
}

test "two sessions are isolated" {
    const alloc = std.testing.allocator;
    const a = createSession(alloc);
    defer a.deinit();
    const b = createSession(alloc);
    defer b.deinit();
    a.seedDom();
    b.seedDom();

    var fa = titleFields(alloc, "only in A");
    defer fa.deinit(alloc);
    try a.dispatch("add", null, null, &fa);
    alloc.free(patchJson(a, alloc));

    try std.testing.expectEqual(@as(usize, 0), b.deps.todos.items.len);
    try std.testing.expectEqual(@as(usize, 1), a.deps.todos.items.len);
    // stable ids: both sessions start at 1 but stay independent
    var fb = titleFields(alloc, "only in B");
    defer fb.deinit(alloc);
    try b.dispatch("add", null, null, &fb);
    try std.testing.expectEqual(@as(usize, 1), b.deps.todos.items.len);
    try std.testing.expectEqualStrings("only in A", a.deps.todos.items[0].title);
    try std.testing.expectEqualStrings("only in B", b.deps.todos.items[0].title);
    alloc.free(patchJson(b, alloc));
}

test "action validation rejects bad input" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();
    s.seedDom();

    try std.testing.expectError(error.InvalidAction, s.dispatch("hack", null, null, null));
    try std.testing.expectError(error.InvalidAction, s.dispatch("add", null, null, null)); // no fields

    var no_title: std.json.ObjectMap = .empty;
    defer no_title.deinit(alloc);
    try std.testing.expectError(error.InvalidAction, s.dispatch("add", null, null, &no_title));

    var nonstring = titleFields(alloc, "x");
    defer nonstring.deinit(alloc);
    _ = nonstring.swapRemove("title");
    nonstring.put(alloc, "title", .{ .integer = 3 }) catch @panic("OOM");
    try std.testing.expectError(error.InvalidAction, s.dispatch("add", null, null, &nonstring));

    var spaces = titleFields(alloc, "   ");
    defer spaces.deinit(alloc);
    // Empty/whitespace submit is a silent no-op, not an error.
    try s.dispatch("add", null, null, &spaces);
    try std.testing.expectEqual(@as(usize, 0), s.deps.todos.items.len);

    try std.testing.expectError(error.InvalidAction, s.dispatch("toggle", "abc", null, null));
    try std.testing.expectError(error.InvalidAction, s.dispatch("toggle", null, null, null));
    try std.testing.expectError(error.TodoNotFound, s.dispatch("toggle", "999", null, null));
    try std.testing.expectError(error.TodoNotFound, s.dispatch("delete", "999", null, null));
    try std.testing.expectError(error.InvalidAction, s.dispatch("filter", "bogus", null, null));
    try std.testing.expectError(error.InvalidAction, s.dispatch("filter", null, null, null));

    const long = try alloc.alloc(u8, max_title_len + 1);
    defer alloc.free(long);
    @memset(long, 'x');
    var too_long = titleFields(alloc, long);
    defer too_long.deinit(alloc);
    try std.testing.expectError(error.InvalidTitle, s.dispatch("add", null, null, &too_long));

    // nothing leaked into the model
    try std.testing.expectEqual(@as(usize, 0), s.deps.todos.items.len);
}

test "inline edit swaps title for a form and back" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();
    s.seedDom();

    var f1 = titleFields(alloc, "edit me");
    defer f1.deinit(alloc);
    try s.dispatch("add", null, null, &f1);
    alloc.free(patchJson(s, alloc));

    const id = s.deps.todos.items[0].id;
    var idbuf: [16]u8 = undefined;
    const arg = std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch unreachable;

    // Enter edit mode: sparse entry appears, one when op mounts the form.
    try s.dispatch("edit", arg, null, null);
    const j1 = patchJson(s, alloc);
    defer alloc.free(j1);
    try std.testing.expect(s.deps.ui_state.contains(id));
    try std.testing.expect(std.mem.indexOf(u8, j1, "\"op\":\"when\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j1, "edit-form") != null);
    try std.testing.expect(std.mem.indexOf(u8, j1, "edit_save") != null);

    // Save with new text: title updated, entry freed, branch swaps back.
    var fields = editFields(alloc, arg, "edited title");
    defer fields.deinit(alloc);
    try s.dispatch("edit_save", null, null, &fields);
    const j2 = patchJson(s, alloc);
    defer alloc.free(j2);
    try std.testing.expectEqualStrings("edited title", s.deps.todos.items[0].title);
    try std.testing.expect(!s.deps.ui_state.contains(id));
    try std.testing.expect(std.mem.indexOf(u8, j2, "\"op\":\"when\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j2, "data-on-dblclick") != null);

    // Re-enter, then cancel: entry gone, title branch restored.
    try s.dispatch("edit", arg, null, null);
    try std.testing.expect(s.deps.ui_state.contains(id));
    alloc.free(patchJson(s, alloc));
    try s.dispatch("edit_cancel", arg, null, null);
    const j3 = patchJson(s, alloc);
    defer alloc.free(j3);
    try std.testing.expect(!s.deps.ui_state.contains(id));
    try std.testing.expect(std.mem.indexOf(u8, j3, "\"op\":\"when\"") != null);

    // Edit on unknown id is rejected like any other action.
    try std.testing.expectError(error.TodoNotFound, s.dispatch("edit", "999", null, null));
}

test "empty edit save deletes the todo and cleans ui state" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();
    s.seedDom();

    var f1 = titleFields(alloc, "doomed");
    defer f1.deinit(alloc);
    try s.dispatch("add", null, null, &f1);
    alloc.free(patchJson(s, alloc));

    const id = s.deps.todos.items[0].id;
    var idbuf: [16]u8 = undefined;
    const arg = std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch unreachable;
    try s.dispatch("edit", arg, null, null);
    alloc.free(patchJson(s, alloc));
    try std.testing.expect(s.deps.ui_state.contains(id));

    var fields = editFields(alloc, arg, "   ");
    defer fields.deinit(alloc);
    try s.dispatch("edit_save", null, null, &fields);
    const j = patchJson(s, alloc);
    defer alloc.free(j);
    try std.testing.expectEqual(@as(usize, 0), s.deps.todos.items.len);
    try std.testing.expectEqual(@as(usize, 0), s.deps.ui_state.count());
    try std.testing.expect(std.mem.indexOf(u8, j, "\"op\":\"remove\"") != null);
}

test "chrome mounts and unmounts through when anchors" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();

    // SSR: all three anchor pairs present; only the empty note is mounted.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try s.writeView(&aw.writer);
    const page = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, page, "<!--z-when:w-empty--><p id=\"empty-msg\">Nothing yet</p><!--/z-when:w-empty-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<!--z-when:w-flt--><!--/z-when:w-flt-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<!--z-when:w-foot--><!--/z-when:w-foot-->") != null);
    s.seedDom();

    // First todo: the chrome branches swap in and the note out — one
    // when op per anchor plus the row create.
    var f1 = titleFields(alloc, "one");
    defer f1.deinit(alloc);
    try s.dispatch("add", null, null, &f1);
    const j1 = patchJson(s, alloc);
    defer alloc.free(j1);
    try std.testing.expect(std.mem.indexOf(u8, j1, "\"op\":\"when\",\"id\":\"w-empty\",\"html\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j1, "\"op\":\"when\",\"id\":\"w-flt\",\"html\":\"\\u003cdiv class=\\\"filters\\\"\\u003e") != null);
    try std.testing.expect(std.mem.indexOf(u8, j1, "\"op\":\"when\",\"id\":\"w-foot\",\"html\":\"\\u003cfooter\\u003e") != null);
    try std.testing.expect(std.mem.indexOf(u8, j1, "id=\\\"count\\\"") != null);

    // Seeded: a second add doesn't touch the anchors at all.
    var f2 = titleFields(alloc, "two");
    defer f2.deinit(alloc);
    try s.dispatch("add", null, null, &f2);
    const j2 = patchJson(s, alloc);
    defer alloc.free(j2);
    try std.testing.expect(std.mem.indexOf(u8, j2, "\"op\":\"when\"") == null);

    // Back to zero: note remounts, chrome unmounts, row leaves. The
    // final delete's batch carries the three when ops.
    var idbuf: [16]u8 = undefined;
    var last: ?[]u8 = null;
    while (s.deps.todos.items.len > 0) {
        const arg = std.fmt.bufPrint(&idbuf, "{d}", .{s.deps.todos.items[0].id}) catch unreachable;
        try s.dispatch("delete", arg, null, null);
        if (last) |l| alloc.free(l);
        last = patchJson(s, alloc);
    }
    const j3 = last.?;
    defer alloc.free(j3);
    try std.testing.expect(std.mem.indexOf(u8, j3, "\"op\":\"when\",\"id\":\"w-empty\",\"html\":\"\\u003cp id=\\\"empty-msg\\\"\\u003e") != null);
    try std.testing.expect(std.mem.indexOf(u8, j3, "\"op\":\"when\",\"id\":\"w-flt\",\"html\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j3, "\"op\":\"when\",\"id\":\"w-foot\",\"html\":\"\"") != null);
}

// ── persistence tests (ztd client-keyed SQLite) ──────────────────

test "persistence: first POST mints ztd, new session reloads rows" {
    const alloc = std.testing.allocator;
    const st = installStore(alloc, ":memory:");
    defer st.deinit();
    defer store.shared = null;

    const a = createSession(alloc);
    defer a.deinit();
    a.seedDom();

    // First contact: no cookie → the add POST mints client_id and
    // stages the one-shot Set-Cookie on THIS response only.
    var f1 = titleFields(alloc, "persisted one");
    defer f1.deinit(alloc);
    try a.dispatch("add", null, null, &f1);
    try std.testing.expect(a.deps.client_id.len != 0);
    try std.testing.expect(std.mem.startsWith(u8, a.out_cookie, "ztd="));
    try std.testing.expect(a.deps.loaded);

    var f2 = titleFields(alloc, "persisted two");
    defer f2.deinit(alloc);
    try a.dispatch("add", null, null, &f2);
    // One-shot: the second POST must not re-send Set-Cookie.
    try std.testing.expectEqual(@as(usize, 0), a.out_cookie.len);
    alloc.free(patchJson(a, alloc));

    var idbuf: [16]u8 = undefined;
    const arg = std.fmt.bufPrint(&idbuf, "{d}", .{a.deps.todos.items[0].id}) catch unreachable;
    try a.dispatch("toggle", arg, null, null);
    alloc.free(patchJson(a, alloc));

    // A NEW session (post-eviction) presenting the same ztd cookie
    // lazy-loads the rows — order, ids, done flags, next_id restored.
    const b = createSession(alloc);
    defer b.deinit();
    presentClient(b, alloc, a.deps.client_id);
    try std.testing.expect(b.deps.loaded);
    try std.testing.expectEqualStrings(a.deps.client_id, b.deps.client_id);
    try std.testing.expectEqual(@as(usize, 2), b.deps.todos.items.len);
    try std.testing.expectEqualStrings("persisted one", b.deps.todos.items[0].title);
    try std.testing.expect(b.deps.todos.items[0].done);
    try std.testing.expectEqualStrings("persisted two", b.deps.todos.items[1].title);
    try std.testing.expect(!b.deps.todos.items[1].done);
    try std.testing.expectEqual(a.deps.next_id, b.deps.next_id);
    // The recount ran at load: footer count reflects persisted state.
    try std.testing.expectEqual(@as(usize, 1), b.deps.remaining.get());
}

test "persistence: delete, edit_save and set_checked write through" {
    const alloc = std.testing.allocator;
    const st = installStore(alloc, ":memory:");
    defer st.deinit();
    defer store.shared = null;

    const a = createSession(alloc);
    defer a.deinit();
    a.seedDom();

    for ([_][]const u8{ "doomed", "editable", "keep" }) |t| {
        var f = titleFields(alloc, t);
        defer f.deinit(alloc);
        try a.dispatch("add", null, null, &f);
        alloc.free(patchJson(a, alloc));
    }

    // delete id 1, rename id 2 via edit_save, check id 3 via set_checked.
    var idbuf: [16]u8 = undefined;
    const del_arg = std.fmt.bufPrint(&idbuf, "{d}", .{a.deps.todos.items[0].id}) catch unreachable;
    try a.dispatch("delete", del_arg, null, null);
    alloc.free(patchJson(a, alloc));

    const edit_id = a.deps.todos.items[0].id;
    const edit_arg = std.fmt.bufPrint(&idbuf, "{d}", .{edit_id}) catch unreachable;
    var ef = editFields(alloc, edit_arg, "edited text");
    defer ef.deinit(alloc);
    try a.dispatch("edit_save", null, null, &ef);
    alloc.free(patchJson(a, alloc));

    const keep_id = a.deps.todos.items[1].id;
    const keep_arg = std.fmt.bufPrint(&idbuf, "{d}", .{keep_id}) catch unreachable;
    try a.dispatch("set_checked", keep_arg, "true", null);
    alloc.free(patchJson(a, alloc));

    const b = createSession(alloc);
    defer b.deinit();
    presentClient(b, alloc, a.deps.client_id);
    try std.testing.expectEqual(@as(usize, 2), b.deps.todos.items.len);
    // List order preserved; deleted row stays gone; edits persisted.
    try std.testing.expectEqual(edit_id, b.deps.todos.items[0].id);
    try std.testing.expectEqualStrings("edited text", b.deps.todos.items[0].title);
    try std.testing.expect(!b.deps.todos.items[0].done);
    try std.testing.expectEqual(keep_id, b.deps.todos.items[1].id);
    try std.testing.expectEqualStrings("keep", b.deps.todos.items[1].title);
    try std.testing.expect(b.deps.todos.items[1].done);
    try std.testing.expectEqual(a.deps.next_id, b.deps.next_id);
}

test "persistence: client ids are isolated" {
    const alloc = std.testing.allocator;
    const st = installStore(alloc, ":memory:");
    defer st.deinit();
    defer store.shared = null;

    const a = createSession(alloc);
    defer a.deinit();
    a.seedDom();
    var fa = titleFields(alloc, "a-todo");
    defer fa.deinit(alloc);
    try a.dispatch("add", null, null, &fa);
    alloc.free(patchJson(a, alloc));
    const cid_a = a.deps.client_id;

    // Same client_id in a fresh session sees a's todo.
    const b1 = createSession(alloc);
    defer b1.deinit();
    presentClient(b1, alloc, cid_a);
    try std.testing.expectEqual(@as(usize, 1), b1.deps.todos.items.len);
    try std.testing.expectEqualStrings("a-todo", b1.deps.todos.items[0].title);

    // A different client (own minted cookie) is isolated — and its
    // first POST mints a DIFFERENT ztd.
    const c = createSession(alloc);
    defer c.deinit();
    c.seedDom();
    var fc = titleFields(alloc, "c-todo");
    defer fc.deinit(alloc);
    try c.dispatch("add", null, null, &fc);
    alloc.free(patchJson(c, alloc));
    try std.testing.expect(c.deps.client_id.len != 0);
    try std.testing.expect(!std.mem.eql(u8, cid_a, c.deps.client_id));
    try std.testing.expectEqual(@as(usize, 1), c.deps.todos.items.len);
    try std.testing.expectEqualStrings("c-todo", c.deps.todos.items[0].title);

    // c's cookie resolves to c's rows only — a's todo stays invisible.
    const b2 = createSession(alloc);
    defer b2.deinit();
    presentClient(b2, alloc, c.deps.client_id);
    try std.testing.expectEqual(@as(usize, 1), b2.deps.todos.items.len);
    try std.testing.expectEqualStrings("c-todo", b2.deps.todos.items[0].title);
}

test "persistence: file db survives store close/reopen (restart)" {
    const alloc = std.testing.allocator;
    const t = try tmpDbPaths(alloc, "restart");
    defer t.deinit(alloc);
    cleanTmpDb(std.testing.io, t);
    defer cleanTmpDb(std.testing.io, t);

    var cid: ?[]u8 = null;
    defer if (cid) |c| alloc.free(c);
    {
        const st = installStore(alloc, t.path);
        defer st.deinit();
        defer store.shared = null;
        const a = createSession(alloc);
        defer a.deinit();
        a.seedDom();
        var f = titleFields(alloc, "restart me");
        defer f.deinit(alloc);
        try a.dispatch("add", null, null, &f);
        alloc.free(patchJson(a, alloc));
        // Dupe before a.deinit frees the session-owned client_id.
        cid = try alloc.dupe(u8, a.deps.client_id);
    }

    // "Restart": a fresh store on the same file + a fresh session
    // presenting the same ztd cookie sees the todo again.
    {
        const st = installStore(alloc, t.path);
        defer st.deinit();
        defer store.shared = null;
        const b = createSession(alloc);
        defer b.deinit();
        presentClient(b, alloc, cid.?);
        try std.testing.expectEqual(@as(usize, 1), b.deps.todos.items.len);
        try std.testing.expectEqualStrings("restart me", b.deps.todos.items[0].title);
        try std.testing.expectEqual(@as(u32, 2), b.deps.next_id);
    }
}

// Moved here from `src/server/stream.zig` when the framework/app split
// made zserver framework-only: the snapshot serializer is framework
// code (`zserver.writeSnapshotJson`), but its coverage needs a real
// session+view, which is app territory.
test "snapshot serializes the view as a full-state ops array" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();
    s.seedDom();

    var fields = titleFields(alloc, "say \"<b>hi</b>\"");
    defer fields.deinit(alloc);
    try s.dispatch("add", null, null, &fields);
    s.log.clear(); // simulate publish consuming the batch

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try zserver.writeSnapshotJson(s, s.seq.get(), &aw.writer);
    const json = aw.writer.buffered();

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("rev").?.integer > 0);
    const ops = root.get("ops").?.array.items;

    // The keyed list ships as one html op carrying the row markup —
    // HTML-escaped inside, JSON-escaped outside. Conditional chrome
    // ships as `when` ops whose html covers the whole branch.
    var html_op: ?[]const u8 = null;
    var flt_op: ?[]const u8 = null;
    var foot_op: ?[]const u8 = null;
    var empty_op: ?[]const u8 = null;
    for (ops) |op| {
        const o = op.object;
        const kind = o.get("op").?.string;
        if (std.mem.eql(u8, kind, "html")) {
            html_op = o.get("html").?.string;
            try std.testing.expectEqualStrings("list", o.get("id").?.string);
        } else if (std.mem.eql(u8, kind, "when")) {
            const id = o.get("id").?.string;
            if (std.mem.eql(u8, id, "w-flt")) flt_op = o.get("html").?.string;
            if (std.mem.eql(u8, id, "w-foot")) foot_op = o.get("html").?.string;
            if (std.mem.eql(u8, id, "w-empty")) empty_op = o.get("html").?.string;
        } else {
            // Covered subtrees emit no inner ops — flt-*/count live
            // inside their anchors' html.
            const id = o.get("id").?.string;
            try std.testing.expect(!std.mem.startsWith(u8, id, "flt-"));
            try std.testing.expect(!std.mem.eql(u8, id, "count"));
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, html_op.?, "&lt;b&gt;hi&lt;/b&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, flt_op.?, "id=\"flt-all\" data-active=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, foot_op.?, "id=\"count\">1 item left") != null);
    try std.testing.expectEqualStrings("", empty_op.?);
}
