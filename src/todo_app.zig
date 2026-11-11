const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const History = @import("server/history.zig").History;

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

const Mutation = union(enum) {
    add: []const u8,
    toggle: u32,
    set_checked: struct { id: u32, done: bool },
    delete: u32,
    filter: Filter,
};

pub const max_title_len = 500;
pub const max_todos = 1000;

pub const ActionError = error{ InvalidAction, InvalidTitle, TodoNotFound, TooManyTodos };

/// One browser session: an isolated zefx graph + todo model + DOM patch state.
/// Server is the single owner — all methods assume serialized access.
///
/// Session contract for the generic server (see server/http.zig):
/// `create`, `deinit`, `csrf_token`/`setCsrf`, `history`, `seq.get()`,
/// `dispatch`, `writeView`, `buildViewNodes`, `setRoute`, `servePage`,
/// `syncPull`, `out_cookie`, `page_title`, `page_class`, `cookie_name`.
pub const Session = struct {
    /// Page <title> and <main> class rendered by the server's page shell.
    pub const page_title = "zforest todos";
    pub const page_class = "app";
    /// Session cookie name — "zfxb" on the board app to avoid clobbering
    /// this app's session on the same host.
    pub const cookie_name = "zfxs";

    gpa: std.mem.Allocator,
    app: zefx.App,
    todos: std.ArrayListUnmanaged(Todo) = .empty,
    next_id: u32 = 1,
    filter: Filter = .all,

    mutate: *zefx.Event(Mutation),
    seq: *zefx.Store(u64),
    remaining: *zefx.Store(usize),

    dom: forest.Dom,
    log: forest.PatchLog,
    /// Retained patch batches for SSE replay (see server/history.zig).
    history: History,
    /// Scratch space for the per-render view tree; reset each render.
    render_arena: std.heap.ArenaAllocator,
    /// Per-session CSRF token rendered into the page and verified on POST.
    /// Owned by the session; set by the server at creation.
    csrf_token: []u8 = &.{},
    /// Extra `Set-Cookie` header emitted on /action responses ("" = none).
    /// Set by dispatch when minting the session user; owned by the server.
    out_cookie: []const u8 = &.{},

    /// Session contract ctor — `io` is unused (todo mints no user tokens).
    pub fn create(gpa: std.mem.Allocator, io: std.Io) *Session {
        _ = io;
        return createSession(gpa);
    }

    pub fn deinit(self: *Session) void {
        if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
        for (self.todos.items) |t| self.gpa.free(t.title);
        self.todos.deinit(self.gpa);
        self.dom.deinit();
        self.log.deinit();
        self.history.deinit();
        self.render_arena.deinit();
        self.app.deinit();
        self.gpa.destroy(self);
    }

    /// Install the server-minted session token (owned by the session).
    pub fn setCsrf(self: *Session, token: []u8) void {
        if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
        self.csrf_token = token;
    }

    /// Request-route hook: the todo app serves exactly one page.
    pub fn setRoute(self: *Session, path: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, path, "/");
    }

    /// Full-page render for a navigating client: resolve the route, drop
    /// tracked DOM state, write the page body, then reseed so subsequent
    /// diffs emit only real changes.
    pub fn servePage(self: *Session, path: []const u8, writer: anytype) !bool {
        if (!self.setRoute(path)) return false;
        self.dom.reset();
        try self.writeView(writer);
        self.seedDom();
        return true;
    }

    /// Cross-session model fan-out hook — todo state is per-session, so
    /// nothing external can change between polls.
    pub fn syncPull(self: *Session) void {
        _ = self;
    }

    fn bumpSeq(self: *Session) void {
        self.seq.set(self.seq.get() + 1);
    }

    fn findIdx(self: *Session, id: u32) ?usize {
        for (self.todos.items, 0..) |t, i| {
            if (t.id == id) return i;
        }
        return null;
    }

    fn visible(self: *Session, t: Todo) bool {
        return switch (self.filter) {
            .all => true,
            .active => !t.done,
            .completed => t.done,
        };
    }

    /// Whitelisted action entry point — the DOM event protocol: `action`
    /// is the `data-on-<event>` value, `arg` the `data-arg` payload,
    /// `value` a change event's new value, and `fields` the named inputs
    /// of a submitted form. Maps to a Mutation and emits into the graph;
    /// the flush applies it (pure phase), settles derived stores, and the
    /// after-flush hook renders DOM patches into `self.log`.
    pub fn dispatch(
        self: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        if (std.mem.eql(u8, action, "add")) {
            const m = fields orelse return error.InvalidAction;
            const fv = m.get("title") orelse return error.InvalidAction;
            const raw = switch (fv) {
                .string => |t| t,
                else => return error.InvalidAction,
            };
            const title = std.mem.trim(u8, raw, " \t\r\n");
            if (title.len == 0 or title.len > max_title_len) return error.InvalidTitle;
            if (self.todos.items.len >= max_todos) return error.TooManyTodos;
            self.mutate.emit(.{ .add = title });
        } else if (std.mem.eql(u8, action, "toggle")) {
            const tid = try self.argId(arg);
            self.mutate.emit(.{ .toggle = tid });
        } else if (std.mem.eql(u8, action, "set_checked")) {
            const tid = try self.argId(arg);
            const v = value orelse return error.InvalidAction;
            const done = if (std.mem.eql(u8, v, "true")) true else if (std.mem.eql(u8, v, "false")) false else return error.InvalidAction;
            self.mutate.emit(.{ .set_checked = .{ .id = tid, .done = done } });
        } else if (std.mem.eql(u8, action, "delete")) {
            const tid = try self.argId(arg);
            self.mutate.emit(.{ .delete = tid });
        } else if (std.mem.eql(u8, action, "filter")) {
            const v = arg orelse return error.InvalidAction;
            const f = Filter.parse(v) orelse return error.InvalidAction;
            self.mutate.emit(.{ .filter = f });
        } else {
            return error.InvalidAction;
        }
    }

    /// Parse a `data-arg` todo id: missing/invalid → InvalidAction,
    /// unknown → TodoNotFound.
    fn argId(self: *Session, arg: ?[]const u8) ActionError!u32 {
        const a = arg orelse return error.InvalidAction;
        const tid = std.fmt.parseInt(u32, a, 10) catch return error.InvalidAction;
        if (self.findIdx(tid) == null) return error.TodoNotFound;
        return tid;
    }

    // ── graph wiring (called once per session) ──────────────────────

    fn wire(self: *Session) void {
        const eng = &self.app.eng;

        // Pure-phase mutation reducer: model change, then bump seq.
        const MutCtx = struct { s: *Session };
        const mctx = self.gpa.create(MutCtx) catch @panic("OOM");
        mctx.* = .{ .s = self };
        self.mutate.reducers.append(eng.allocator, .{
            .ctx = @ptrCast(mctx),
            .trigger = &struct {
                fn trig(raw: *anyopaque, pp: *const anyopaque) void {
                    const c: *MutCtx = @ptrCast(@alignCast(raw));
                    const m: *const Mutation = @ptrCast(@alignCast(pp));
                    c.s.applyMutation(m.*);
                }
            }.trig,
        }) catch @panic("OOM");
        eng.trackGraphAlloc(@ptrCast(mctx), &struct {
            fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                a.destroy(@as(*MutCtx, @ptrCast(@alignCast(p))));
            }
        }.dtor);

        // Derived store: remaining count recomputes from seq updates and
        // settles in the pure phase, before any view work.
        const RemCtx = struct { s: *Session };
        const rctx = self.gpa.create(RemCtx) catch @panic("OOM");
        rctx.* = .{ .s = self };
        self.seq.updates().reducers.append(eng.allocator, .{
            .ctx = @ptrCast(rctx),
            .trigger = &struct {
                fn trig(raw: *anyopaque, _: *const anyopaque) void {
                    const c: *RemCtx = @ptrCast(@alignCast(raw));
                    var n: usize = 0;
                    for (c.s.todos.items) |t| {
                        if (!t.done) n += 1;
                    }
                    c.s.remaining.set(n);
                }
            }.trig,
        }) catch @panic("OOM");
        eng.trackGraphAlloc(@ptrCast(rctx), &struct {
            fn dtor(a: std.mem.Allocator, p: *anyopaque) void {
                a.destroy(@as(*RemCtx, @ptrCast(@alignCast(p))));
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

    fn applyMutation(self: *Session, m: Mutation) void {
        switch (m) {
            .add => |title| {
                const owned = self.gpa.dupe(u8, title) catch @panic("OOM");
                self.todos.append(self.gpa, .{ .id = self.next_id, .title = owned, .done = false }) catch @panic("OOM");
                self.next_id += 1;
            },
            .toggle => |id| {
                const i = self.findIdx(id).?;
                self.todos.items[i].done = !self.todos.items[i].done;
            },
            .set_checked => |sc| {
                const i = self.findIdx(sc.id).?;
                self.todos.items[i].done = sc.done;
            },
            .delete => |id| {
                const i = self.findIdx(id).?;
                self.gpa.free(self.todos.items[i].title);
                _ = self.todos.orderedRemove(i);
            },
            .filter => |f| {
                self.filter = f;
            },
        }
        self.bumpSeq();
    }

    // ── rendering ───────────────────────────────────────────────────
    // One declarative tree drives both SSR (`writeHtml`) and the
    // post-flush DOM-patch diff (`forest.diff`). The view lives in
    // `render_arena`, reset at the top of every render.

    /// Diff the view into DOM patches. Runs post-settle (after-flush).
    fn render(self: *Session) void {
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        forest.diff(a, buildView(a, self), &self.dom, &self.log);
        self.log.revision = self.seq.get();
    }

    /// Render the `<main>` inner content — used by the initial page.
    pub fn writeView(self: *Session, writer: anytype) !void {
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        try forest.writeHtml(a, buildView(a, self), writer);
    }

    /// The session's current view nodes, built into `a` — the SSE
    /// snapshot writer serializes them via `forest.writeSnapshotOps`.
    pub fn buildViewNodes(self: *Session, a: std.mem.Allocator) []const forest.Node {
        return buildView(a, self);
    }

    /// Seed tracked DOM state to match markup already emitted in the page,
    /// so the first diff renders only real changes.
    pub fn seedDom(self: *Session) void {
        self.render();
        // Keep tracked state, drop the patches — the page ships full HTML.
        self.log.clear();
    }
};

fn countText(a: std.mem.Allocator, rem: usize) []const u8 {
    return std.fmt.allocPrint(a, "{d} item{s} left", .{ rem, if (rem == 1) "" else "s" }) catch @panic("OOM");
}

// ── view components ─────────────────────────────────────────────
// A component is a plain fn returning a forest.Node. `buildView`
// composes them; `forest.fragment` groups several roots into one Node
// without emitting wrapper markup.

/// Static chrome: the title and the add form — no bound state.
fn headerView(a: std.mem.Allocator) forest.Node {
    return forest.fragment(a, .{
        forest.el(a, .h1, .{}, .{
            forest.text("zforest "),
            forest.el(a, .span, .{}, "todos"),
        }),
        forest.el(a, .form, .{
            .id = "add-form",
            .autocomplete = "off",
            .on = .{ .submit = "add" },
        }, .{
            forest.el(a, .input, .{
                .name = "title",
                .placeholder = "What needs to be done?",
                .maxlength = max_title_len,
                .autofocus = true,
            }, .{}),
            forest.el(a, .button, .{ .type = "submit" }, "Add"),
        }),
    });
}

/// The empty-state note: mounted via the `w-empty` anchor only while the
/// list has no todos at all — real mount/unmount instead of `hidden`.
fn emptyView(a: std.mem.Allocator, s: *Session) forest.Node {
    return forest.when(a, .{ .id = "w-empty" }, s.todos.items.len == 0, forest.el(a, .p, .{ .id = "empty-msg" }, "Nothing yet"));
}

/// The filter button row: mounted via the `w-flt` anchor while the list
/// is non-empty. The div itself is static branch markup; the `flt-*`
/// buttons keep absolute ids so `data-active` still diffs in place.
fn filtersView(a: std.mem.Allocator, s: *Session) forest.Node {
    var btns: std.ArrayListUnmanaged(forest.Node) = .empty;
    inline for (.{ Filter.all, Filter.active, Filter.completed }) |f| {
        btns.append(a, forest.el(a, .button, .{
            .id = comptime "flt-" ++ f.name(),
            .@"data-active" = if (s.filter == f) "1" else null,
            .on = .{ .click = "filter" },
            .arg = f.name(),
        }, f.name())) catch @panic("OOM");
    }
    return forest.when(a, .{ .id = "w-flt" }, s.todos.items.len != 0, forest.el(a, .div, .{ .class = "filters" }, btns.toOwnedSlice(a) catch @panic("OOM")));
}

/// The keyed todo list — `eachOf` renders every todo through rowOrNull.
fn listView(a: std.mem.Allocator, s: *Session) forest.Node {
    return forest.el(a, .ul, .{ .id = "list" }, forest.eachOf(a, s.todos.items, s, rowOrNull));
}

/// The footer: mounted via the `w-foot` anchor while the list is
/// non-empty. `count` keeps its absolute id inside the branch and stays
/// bound via `computed` — `countText` maps the `remaining` store.
fn footerView(a: std.mem.Allocator, s: *Session) forest.Node {
    return forest.when(a, .{ .id = "w-foot" }, s.todos.items.len != 0, forest.el(a, .footer, .{}, .{
        forest.el(a, .span, .{ .id = "count", .text = forest.computed(s.remaining, countText) }, .{}),
    }));
}

fn buildRow(a: std.mem.Allocator, t: Todo) forest.Node {
    return forest.el(a, .li, .{
        .id = std.fmt.allocPrint(a, "row-{d}", .{t.id}) catch @panic("OOM"),
        .class = if (t.done) "todo done" else "todo",
    }, .{
        forest.el(a, .input, .{
            .lid = "cb",
            .type = "checkbox",
            .checked = t.done,
            .on = .{ .change = "set_checked" },
            .arg = t.id,
        }, .{}),
        forest.el(a, .span, .{ .class = "title" }, t.title),
        forest.el(a, .button, .{
            .class = "del",
            .@"aria-label" = "delete",
            .on = .{ .click = "delete" },
            .arg = t.id,
        }, "×"),
    });
}

/// `eachOf` render fn: the active filter hides rows by returning null;
/// every survivor is an element carrying `.id`.
fn rowOrNull(a: std.mem.Allocator, s: *Session, t: Todo) ?forest.Node {
    if (!s.visible(t)) return null;
    return buildRow(a, t);
}

/// The `<main>` inner content: static chrome (h1, form), the `w-empty` /
/// `w-flt` / `w-foot` conditional anchors around the empty-state note,
/// filter buttons (`flt-*` / `data-active`), and bound `count`, plus the
/// permanently mounted keyed todo list.
fn buildView(a: std.mem.Allocator, s: *Session) []const forest.Node {
    const nodes = a.alloc(forest.Node, 5) catch @panic("OOM");
    nodes[0] = headerView(a);
    nodes[1] = emptyView(a, s);
    nodes[2] = filtersView(a, s);
    nodes[3] = listView(a, s);
    nodes[4] = footerView(a, s);
    return nodes;
}

/// Wired session constructor (separate so `wire` can reference self).
pub fn createSession(gpa: std.mem.Allocator) *Session {
    const s = gpa.create(Session) catch @panic("OOM");
    s.* = .{
        .gpa = gpa,
        .app = zefx.createApp(gpa),
        .mutate = undefined,
        .seq = undefined,
        .remaining = undefined,
        .dom = forest.Dom.init(gpa),
        .log = forest.PatchLog.init(gpa),
        .history = History.init(gpa),
        .render_arena = std.heap.ArenaAllocator.init(gpa),
        .filter = .all,
    };
    s.mutate = s.app.createEvent(Mutation);
    s.seq = s.app.createStore(u64, 0);
    s.remaining = s.app.createStore(usize, 0);
    s.wire();
    return s;
}

// ─────────────────────────────────────────────
// Session tests
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
    try s.dispatch("toggle", std.fmt.bufPrint(&idbuf, "{d}", .{s.todos.items[0].id}) catch unreachable, null, null);
    const j2 = patchJson(s, alloc);
    defer alloc.free(j2);
    try std.testing.expectEqual(@as(usize, 1), s.remaining.get());
    try std.testing.expect(s.todos.items[0].done);
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
    try s.dispatch("delete", std.fmt.bufPrint(&idbuf, "{d}", .{s.todos.items[1].id}) catch unreachable, null, null);
    const j4 = patchJson(s, alloc);
    defer alloc.free(j4);
    try std.testing.expectEqual(@as(usize, 1), s.todos.items.len);
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

    try std.testing.expectEqual(@as(usize, 0), b.todos.items.len);
    try std.testing.expectEqual(@as(usize, 1), a.todos.items.len);
    // stable ids: both sessions start at 1 but stay independent
    var fb = titleFields(alloc, "only in B");
    defer fb.deinit(alloc);
    try b.dispatch("add", null, null, &fb);
    try std.testing.expectEqual(@as(usize, 1), b.todos.items.len);
    try std.testing.expectEqualStrings("only in A", a.todos.items[0].title);
    try std.testing.expectEqualStrings("only in B", b.todos.items[0].title);
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
    try std.testing.expectError(error.InvalidTitle, s.dispatch("add", null, null, &spaces));

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
    try std.testing.expectEqual(@as(usize, 0), s.todos.items.len);
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
    while (s.todos.items.len > 0) {
        const arg = std.fmt.bufPrint(&idbuf, "{d}", .{s.todos.items[0].id}) catch unreachable;
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
