const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");

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
pub const Session = struct {
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
    /// Per-session CSRF token rendered into the page and verified on POST.
    /// Owned by the session; set by the server at creation.
    csrf_token: []u8 = &.{},

    pub fn deinit(self: *Session) void {
        if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
        for (self.todos.items) |t| self.gpa.free(t.title);
        self.todos.deinit(self.gpa);
        self.dom.deinit();
        self.log.deinit();
        self.app.deinit();
        self.gpa.destroy(self);
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

    /// Whitelisted action entry point. Emits into the graph; the flush applies
    /// the mutation (pure phase), settles derived stores, and the after-flush
    /// hook renders DOM patches into `self.log`.
    pub fn apply(self: *Session, action: []const u8, id: ?u32, value: ?[]const u8) ActionError!void {
        if (std.mem.eql(u8, action, "add")) {
            const raw = value orelse return error.InvalidAction;
            const title = std.mem.trim(u8, raw, " \t\r\n");
            if (title.len == 0 or title.len > max_title_len) return error.InvalidTitle;
            if (self.todos.items.len >= max_todos) return error.TooManyTodos;
            self.mutate.emit(.{ .add = title });
        } else if (std.mem.eql(u8, action, "toggle")) {
            const tid = id orelse return error.InvalidAction;
            if (self.findIdx(tid) == null) return error.TodoNotFound;
            self.mutate.emit(.{ .toggle = tid });
        } else if (std.mem.eql(u8, action, "set_checked")) {
            const tid = id orelse return error.InvalidAction;
            if (self.findIdx(tid) == null) return error.TodoNotFound;
            const v = value orelse return error.InvalidAction;
            const done = if (std.mem.eql(u8, v, "true")) true else if (std.mem.eql(u8, v, "false")) false else return error.InvalidAction;
            self.mutate.emit(.{ .set_checked = .{ .id = tid, .done = done } });
        } else if (std.mem.eql(u8, action, "delete")) {
            const tid = id orelse return error.InvalidAction;
            if (self.findIdx(tid) == null) return error.TodoNotFound;
            self.mutate.emit(.{ .delete = tid });
        } else if (std.mem.eql(u8, action, "filter")) {
            const v = value orelse return error.InvalidAction;
            const f = Filter.parse(v) orelse return error.InvalidAction;
            self.mutate.emit(.{ .filter = f });
        } else {
            return error.InvalidAction;
        }
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

    fn writeRowHtml(self: *Session, writer: anytype, t: Todo) !void {
        _ = self;
        try writer.print("<li id=\"row-{d}\" class=\"todo{s}\"><input id=\"row-{d}/cb\" type=\"checkbox\" data-toggle=\"{d}\"{s}><span class=\"title\">", .{
            t.id, if (t.done) " done" else "", t.id, t.id, if (t.done) " checked" else "",
        });
        try forest.escapeHtmlInto(writer, t.title);
        try writer.print("</span><button class=\"del\" data-delete=\"{d}\" aria-label=\"delete\">×</button></li>", .{t.id});
    }

    /// Write the current row markup (used for the initial page).
    pub fn writeRowsHtml(self: *Session, writer: anytype) !void {
        for (self.todos.items) |t| {
            if (self.visible(t)) try self.writeRowHtml(writer, t);
        }
    }

    /// Diff current model into DOM patches. Runs post-settle (after-flush).
    fn render(self: *Session) void {
        var rows: std.ArrayListUnmanaged(forest.Row) = .empty;
        defer rows.deinit(self.gpa);
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();

        for (self.todos.items) |t| {
            if (!self.visible(t)) continue;
            _ = aw.writer.consumeAll();
            self.writeRowHtml(&aw.writer, t) catch @panic("OOM");
            rows.append(self.gpa, .{
                .id = std.fmt.allocPrint(self.gpa, "row-{d}", .{t.id}) catch @panic("OOM"),
                .html = self.gpa.dupe(u8, aw.writer.buffered()) catch @panic("OOM"),
            }) catch @panic("OOM");
        }
        defer for (rows.items) |r| {
            self.gpa.free(@constCast(r.id));
            self.gpa.free(@constCast(r.html));
        };

        var created: std.ArrayListUnmanaged([]const u8) = .empty;
        defer created.deinit(self.gpa);
        self.dom.syncKeyedList(&self.log, "list", rows.items, &created);

        // Row bindings: tracked state survives across renders; rows created
        // this pass are seeded to match their markup (no patch).
        for (self.todos.items) |t| {
            if (!self.visible(t)) continue;
            var row_buf: [32]u8 = undefined;
            const row_id = std.fmt.bufPrint(&row_buf, "row-{d}", .{t.id}) catch unreachable;
            var cb_buf: [40]u8 = undefined;
            const cb_id = std.fmt.bufPrint(&cb_buf, "{s}/cb", .{row_id}) catch unreachable;
            const class: []const u8 = if (t.done) "todo done" else "todo";
            var was_created = false;
            for (created.items) |cid| {
                if (std.mem.eql(u8, cid, row_id)) was_created = true;
            }
            if (was_created) {
                self.dom.seedAttr(cb_id, "checked", if (t.done) "" else null);
                self.dom.seedAttr(row_id, "class", class);
            } else {
                self.dom.setChecked(&self.log, cb_id, t.done);
                self.dom.setAttr(&self.log, row_id, "class", class);
            }
        }

        var buf: [64]u8 = undefined;
        const rem = self.remaining.get();
        const count_txt = std.fmt.bufPrint(&buf, "{d} item{s} left", .{ rem, if (rem == 1) "" else "s" }) catch unreachable;
        self.dom.setText(&self.log, "count", count_txt);

        inline for (.{ Filter.all, Filter.active, Filter.completed }) |f| {
            self.dom.setAttr(&self.log, comptime "flt-" ++ f.name(), "data-active", if (self.filter == f) "1" else null);
        }

        self.log.revision = self.seq.get();
    }

    /// Seed tracked DOM state to match markup already emitted in the page,
    /// so the first diff renders only real changes.
    pub fn seedDom(self: *Session) void {
        var dummy = forest.PatchLog.init(self.gpa);
        defer dummy.deinit();
        self.render();
        // Keep tracked state, drop the patches — the page ships full HTML.
        self.log.clear();
    }
};

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

test "session add/toggle/delete/filter produces patches" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();
    s.seedDom();

    try s.apply("add", null, "write <b>docs</b>");
    const j1 = patchJson(s, alloc);
    defer alloc.free(j1);
    try std.testing.expect(std.mem.indexOf(u8, j1, "\"op\":\"create\"") != null);
    // title is HTML-escaped in the patch, then JSON-escaped in the batch
    try std.testing.expect(std.mem.indexOf(u8, j1, "\\u0026lt;b\\u0026gt;docs\\u0026lt;/b\\u0026gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, j1, "1 item left") != null);

    try s.apply("add", null, "second");
    alloc.free(patchJson(s, alloc));

    try s.apply("toggle", s.todos.items[0].id, null);
    const j2 = patchJson(s, alloc);
    defer alloc.free(j2);
    try std.testing.expectEqual(@as(usize, 1), s.remaining.get());
    try std.testing.expect(s.todos.items[0].done);
    // toggle emits authoritative checked + class patches
    try std.testing.expect(std.mem.indexOf(u8, j2, "\"name\":\"checked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j2, "\"name\":\"class\",\"value\":\"todo done\"") != null);

    // filter to active: done row removed
    try s.apply("filter", null, "active");
    const j3 = patchJson(s, alloc);
    defer alloc.free(j3);
    try std.testing.expect(std.mem.indexOf(u8, j3, "\"op\":\"remove\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j3, "data-active") != null);

    // delete visible row
    try s.apply("delete", s.todos.items[1].id, null);
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

    try a.apply("add", null, "only in A");
    alloc.free(patchJson(a, alloc));

    try std.testing.expectEqual(@as(usize, 0), b.todos.items.len);
    try std.testing.expectEqual(@as(usize, 1), a.todos.items.len);
    // stable ids: both sessions start at 1 but stay independent
    try b.apply("add", null, "only in B");
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

    try std.testing.expectError(error.InvalidAction, s.apply("hack", null, null));
    try std.testing.expectError(error.InvalidAction, s.apply("add", null, null));
    try std.testing.expectError(error.InvalidTitle, s.apply("add", null, "   "));
    try std.testing.expectError(error.TodoNotFound, s.apply("toggle", 999, null));
    try std.testing.expectError(error.TodoNotFound, s.apply("delete", 999, null));
    try std.testing.expectError(error.InvalidAction, s.apply("filter", null, "bogus"));

    const long = try alloc.alloc(u8, max_title_len + 1);
    defer alloc.free(long);
    @memset(long, 'x');
    try std.testing.expectError(error.InvalidTitle, s.apply("add", null, long));

    // nothing leaked into the model
    try std.testing.expectEqual(@as(usize, 0), s.todos.items.len);
}
