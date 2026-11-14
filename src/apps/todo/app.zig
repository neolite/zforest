//! todo — the TodoMVC demo on the zmeta `Session(Deps)` skeleton
//! (docs/meta-framework.md §5): file-based routing (single "/" page),
//! comptime action table, per-session model. The view lives in
//! `pages/index.zig`; this file holds the domain model, the mutation
//! graph, action handlers, and the session tests.
const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const zmeta = @import("zmeta.zig");
const routes = @import("gen/routes.zig");
const actions = @import("gen/actions.zig");

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

    /// Current typed route — written by the generated `routes.setRoute`
    /// glue; read by `routes.prepare`/`routes.viewNodes` dispatch.
    route: routes.Route = .{ .index = .{} },

    todos: std.ArrayListUnmanaged(Todo) = .empty,
    next_id: u32 = 1,
    filter: Filter = .all,
    /// Sparse per-item UI state keyed by todo id (see ItemUi).
    ui_state: std.AutoHashMapUnmanaged(u32, ItemUi) = .empty,

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

    /// Route-param gate — generated dispatch to page `prepare`s.
    pub fn prepare(s: *Session, env: *const zmeta.Env) !void {
        try routes.prepare(s, env);
    }

    /// The `<main>` body — generated dispatch to the active page's view.
    pub fn view(a: std.mem.Allocator, s: *Session, env: *const zmeta.Env) []const forest.Node {
        return routes.viewNodes(a, s, env);
    }

    /// Whitelisted action entry — generated dispatch to `on_<name>`.
    pub fn dispatch(
        s: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) !void {
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

/// mutate reducer — pure-phase model change, then bump the revision.
fn applyMutation(s: *Session, m: Mutation) void {
    switch (m) {
        .add => |title| {
            const owned = s.gpa.dupe(u8, title) catch @panic("OOM");
            s.deps.todos.append(s.gpa, .{ .id = s.deps.next_id, .title = owned, .done = false }) catch @panic("OOM");
            s.deps.next_id += 1;
        },
        .toggle => |id| {
            const i = findIdx(s, id).?;
            s.deps.todos.items[i].done = !s.deps.todos.items[i].done;
        },
        .set_checked => |sc| {
            const i = findIdx(s, sc.id).?;
            s.deps.todos.items[i].done = sc.done;
        },
        .delete => |id| {
            clearUi(s, id);
            const i = findIdx(s, id).?;
            s.gpa.free(s.deps.todos.items[i].title);
            _ = s.deps.todos.orderedRemove(i);
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
                return;
            }
            const owned = s.gpa.dupe(u8, text) catch @panic("OOM");
            s.gpa.free(s.deps.todos.items[i].title);
            s.deps.todos.items[i].title = owned;
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
