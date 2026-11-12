//! zcar — auto-service booking on the diff path: cascading vehicle
//! picker (brand → model → year → derived specs), a category-grouped
//! service menu, context-sensitive upsells and combo discounts, and a
//! booking form producing a per-session bookings list. Structure changes
//! constantly (chips swap, cart lines appear), so this app uses the
//! rebuild+diff renderer — the counterpart to zmon's live bindings.

const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const History = @import("server/history.zig").History;
const CarData = @import("car_data.zig");

const Booking = struct {
    id: u32,
    name: []u8,
    phone: []u8,
    car: []u8,
    items: u32,
    total: u32,
};

const Mutation = union(enum) {
    set_brand: usize,
    set_model: usize,
    set_year: u16,
    toggle_svc: u32,
    add_svc: u32,
    book: struct { name: []const u8, phone: []const u8 },
};

pub const ActionError = error{ InvalidAction, InvalidChoice, IncompleteVehicle, EmptyCart, BadContact };

/// One browser session: isolated graph + booking draft + DOM patch state.
pub const Session = struct {
    /// Session contract for the generic server (see server/http.zig).
    pub const page_title = "zcar — запись в сервис";
    pub const page_class = "app app-car";
    pub const cookie_name = "zfxc";

    gpa: std.mem.Allocator,
    app: zefx.App,

    brand: ?usize = null,
    model: ?usize = null,
    year: ?u16 = null,
    /// Selected service ids — presence is the state.
    services: std.AutoHashMapUnmanaged(u32, void) = .empty,
    bookings: std.ArrayListUnmanaged(Booking) = .empty,
    next_booking: u32 = 1,

    mutate: *zefx.Event(Mutation),
    seq: *zefx.Store(u64),

    dom: forest.Dom,
    log: forest.PatchLog,
    history: History,
    render_arena: std.heap.ArenaAllocator,
    csrf_token: []u8 = &.{},
    out_cookie: []const u8 = &.{},

    pub fn create(gpa: std.mem.Allocator, io: std.Io) *Session {
        _ = io;
        return createSession(gpa);
    }

    pub fn deinit(self: *Session) void {
        if (self.csrf_token.len != 0) self.gpa.free(self.csrf_token);
        self.services.deinit(self.gpa);
        for (self.bookings.items) |b| {
            self.gpa.free(b.name);
            self.gpa.free(b.phone);
            self.gpa.free(b.car);
        }
        self.bookings.deinit(self.gpa);
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

    pub fn validPath(path: []const u8) bool {
        return std.mem.eql(u8, path, "/");
    }

    pub fn setRoute(_: *Session, path: []const u8) bool {
        return std.mem.eql(u8, path, "/");
    }

    pub fn servePage(self: *Session, path: []const u8, writer: anytype) !bool {
        if (!self.setRoute(path)) return false;
        self.dom.reset();
        try self.writeView(writer);
        self.seedDom();
        return true;
    }

    /// Per-session model — nothing external changes between polls.
    pub fn syncPull(_: *Session) void {}

    // ── cart math ─────────────────────────────────────────────────

    fn hasSvc(self: *Session, id: u32) bool {
        return self.services.contains(id);
    }

    fn catCount(self: *Session, cat: CarData.Cat) u32 {
        var n: u32 = 0;
        var it = self.services.keyIterator();
        while (it.next()) |id| {
            if (CarData.serviceAt(id.*)) |sv| {
                if (sv.cat == cat) n += 1;
            }
        }
        return n;
    }

    fn catSubtotal(self: *Session, cat: CarData.Cat) u32 {
        var sum: u32 = 0;
        var it = self.services.keyIterator();
        while (it.next()) |id| {
            if (CarData.serviceAt(id.*)) |sv| {
                if (sv.cat == cat) sum += sv.price;
            }
        }
        return sum;
    }

    pub const Discount = struct { label: []const u8, amount: u32 };

    /// Active combo discounts, in display order — written into `buf`
    /// (max 3) so no slice to stack memory escapes.
    fn discounts(self: *Session, buf: []Discount) []const Discount {
        var n: usize = 0;
        const maint_n = self.catCount(.maintenance);
        if (maint_n >= 3) {
            buf[n] = .{ .label = "Лояльность: 3+ ТО — скидка 15% на ТО", .amount = self.catSubtotal(.maintenance) * 15 / 100 };
            n += 1;
        }
        if (self.hasSvc(16) and self.hasSvc(17)) {
            buf[n] = .{ .label = "Комбо: шиномонтаж + балансировка −20%", .amount = (CarData.serviceAt(16).?.price + CarData.serviceAt(17).?.price) * 20 / 100 };
            n += 1;
        }
        const sub = self.subtotal();
        if (sub >= 20000) {
            buf[n] = .{ .label = "Крупный заказ — скидка 10%", .amount = sub * 10 / 100 };
            n += 1;
        }
        return buf[0..n];
    }

    fn subtotal(self: *Session) u32 {
        var sum: u32 = 0;
        var it = self.services.keyIterator();
        while (it.next()) |id| {
            if (CarData.serviceAt(id.*)) |sv| sum += sv.price;
        }
        return sum;
    }

    fn total(self: *Session) u32 {
        var t = self.subtotal();
        var buf: [3]Discount = undefined;
        for (self.discounts(&buf)) |d| t -|= d.amount;
        return t;
    }

    /// Selected ids sorted ascending — stable order for the summary list.
    fn cartIds(self: *Session, a: std.mem.Allocator) []u32 {
        const ids = a.alloc(u32, self.services.count()) catch @panic("OOM");
        var n: usize = 0;
        var it = self.services.keyIterator();
        while (it.next()) |id| {
            ids[n] = id.*;
            n += 1;
        }
        // insertion sort — cart is tiny
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const v = ids[i];
            var j = i;
            while (j > 0 and ids[j - 1] > v) {
                ids[j] = ids[j - 1];
                j -= 1;
            }
            ids[j] = v;
        }
        return ids[0..n];
    }

    pub const Suggestion = struct { id: u32, reason: []const u8 };

    /// Context upsells: derived from the chosen vehicle and the current
    /// cart. Deduped by service id, in rule order.
    fn suggestions(self: *Session, a: std.mem.Allocator) []const Suggestion {
        var out: std.ArrayListUnmanaged(Suggestion) = .empty;
        const add = struct {
            fn f(list: *std.ArrayListUnmanaged(Suggestion), alloc: std.mem.Allocator, id: u32, reason: []const u8) void {
                for (list.items) |s| {
                    if (s.id == id) return;
                }
                list.append(alloc, .{ .id = id, .reason = reason }) catch @panic("OOM");
            }
        }.f;

        var it = self.services.keyIterator();
        var has_engine = false;
        var has_gearbox = false;
        while (it.next()) |id| {
            if (CarData.serviceAt(id.*)) |sv| {
                has_engine = has_engine or sv.cat == .engine;
                has_gearbox = has_gearbox or sv.cat == .gearbox;
            }
        }
        if (has_engine and !self.hasSvc(9)) add(&out, a, 9, "Вместе с работами по двигателю");
        if (has_gearbox and !self.hasSvc(10)) add(&out, a, 10, "Вместе с работами по коробке");
        if (self.hasSvc(16) and !self.hasSvc(17)) add(&out, a, 17, "В пару к шиномонтажу");
        if (self.hasSvc(13) and !self.hasSvc(14)) add(&out, a, 14, "Геометрия после амортизаторов");
        if (self.year) |y| {
            if (y <= 2014 and !self.hasSvc(6)) {
                const reason = std.fmt.allocPrint(a, "Авто {d} г.в. — износ цепи ГРМ", .{y}) catch unreachable;
                add(&out, a, 6, reason);
            }
        }
        if (self.services.count() >= 4) add(&out, a, 21, "Перед выдачей — проверить электрику");
        return out.items;
    }

    fn vehicleComplete(self: *Session) bool {
        return self.brand != null and self.model != null and self.year != null;
    }

    fn carDesc(self: *Session, a: std.mem.Allocator) []u8 {
        const b = CarData.brandAt(self.brand.?).?;
        const m = CarData.modelAt(self.brand.?, self.model.?).?;
        return std.fmt.allocPrint(a, "{s} {s} {d}", .{ b.name, m.name, self.year.? }) catch @panic("OOM");
    }

    // ── actions ────────────────────────────────────────────────────

    pub fn dispatch(
        self: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = value;
        if (std.mem.eql(u8, action, "set_brand")) {
            const i = try self.argIdx(arg, CarData.brands.len);
            self.mutate.emit(.{ .set_brand = i });
        } else if (std.mem.eql(u8, action, "set_model")) {
            const i = try self.argIdx(arg, if (self.brand) |b| CarData.brandAt(b).?.models.len else 0);
            self.mutate.emit(.{ .set_model = i });
        } else if (std.mem.eql(u8, action, "set_year")) {
            const a_str = arg orelse return error.InvalidAction;
            const y = std.fmt.parseInt(u16, a_str, 10) catch return error.InvalidChoice;
            const m = if (self.brand != null and self.model != null)
                CarData.modelAt(self.brand.?, self.model.?)
            else
                null;
            const md = m orelse return error.InvalidChoice;
            if (y < md.year_lo or y > md.year_hi) return error.InvalidChoice;
            self.mutate.emit(.{ .set_year = y });
        } else if (std.mem.eql(u8, action, "toggle_svc") or std.mem.eql(u8, action, "add_svc")) {
            const a_str = arg orelse return error.InvalidAction;
            const id = std.fmt.parseInt(u32, a_str, 10) catch return error.InvalidChoice;
            if (CarData.serviceAt(id) == null) return error.InvalidChoice;
            if (std.mem.eql(u8, action, "toggle_svc")) {
                self.mutate.emit(.{ .toggle_svc = id });
            } else {
                self.mutate.emit(.{ .add_svc = id });
            }
        } else if (std.mem.eql(u8, action, "book")) {
            const f = fields orelse return error.InvalidAction;
            const name = try fieldStr(f, "cust");
            const phone = try fieldStr(f, "phone");
            const n = std.mem.trim(u8, name, " \t\r\n");
            const p = std.mem.trim(u8, phone, " \t\r\n");
            if (n.len < 2 or p.len < 5) return error.BadContact;
            if (!self.vehicleComplete()) return error.IncompleteVehicle;
            if (self.services.count() == 0) return error.EmptyCart;
            self.mutate.emit(.{ .book = .{ .name = n, .phone = p } });
        } else {
            return error.InvalidAction;
        }
    }

    fn argIdx(_: *Session, arg: ?[]const u8, bound: usize) ActionError!usize {
        const a = arg orelse return error.InvalidAction;
        const i = std.fmt.parseInt(usize, a, 10) catch return error.InvalidChoice;
        if (i >= bound) return error.InvalidChoice;
        return i;
    }

    fn fieldStr(f: *const std.json.ObjectMap, key: []const u8) ActionError![]const u8 {
        const v = f.get(key) orelse return error.InvalidAction;
        return switch (v) {
            .string => |s| s,
            else => error.InvalidAction,
        };
    }

    // ── graph wiring ───────────────────────────────────────────────

    fn wire(self: *Session) void {
        const eng = &self.app.eng;
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
            .set_brand => |i| {
                self.brand = i;
                self.model = null;
                self.year = null;
            },
            .set_model => |i| {
                self.model = i;
                self.year = null;
            },
            .set_year => |y| self.year = y,
            .toggle_svc => |id| {
                if (self.services.fetchRemove(id)) |_| {
                    // removed
                } else {
                    self.services.put(self.gpa, id, {}) catch @panic("OOM");
                }
            },
            .add_svc => |id| {
                if (!self.services.contains(id)) {
                    self.services.put(self.gpa, id, {}) catch @panic("OOM");
                }
            },
            .book => |b| {
                const car = self.carDesc(self.gpa);
                self.bookings.append(self.gpa, .{
                    .id = self.next_booking,
                    .name = self.gpa.dupe(u8, b.name) catch @panic("OOM"),
                    .phone = self.gpa.dupe(u8, b.phone) catch @panic("OOM"),
                    .car = car,
                    .items = @intCast(self.services.count()),
                    .total = self.total(),
                }) catch @panic("OOM");
                self.next_booking += 1;
                self.services.clearRetainingCapacity();
            },
        }
        self.seq.set(self.seq.get() + 1);
    }

    // ── rendering ──────────────────────────────────────────────────

    fn render(self: *Session) void {
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        forest.diff(a, buildView(a, self), &self.dom, &self.log);
        self.log.revision = self.seq.get();
    }

    pub fn writeView(self: *Session, writer: anytype) !void {
        _ = self.render_arena.reset(.retain_capacity);
        const a = self.render_arena.allocator();
        try forest.writeHtml(a, buildView(a, self), writer);
    }

    pub fn buildViewNodes(self: *Session, a: std.mem.Allocator) []const forest.Node {
        return buildView(a, self);
    }

    pub fn seedDom(self: *Session) void {
        self.render();
        self.log.clear();
    }
};

// ── formatting helpers ────────────────────────────────────────────

/// "12345" → "12 345" — thin-space grouping for prices.
fn fmtPrice(a: std.mem.Allocator, price: u32) []const u8 {
    var digits: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&digits, "{d}", .{price}) catch unreachable;
    const n_groups = (s.len + 2) / 3;
    const out = a.alloc(u8, s.len + n_groups -| 1) catch @panic("OOM");
    var di: usize = s.len;
    var oi: usize = out.len;
    var group: usize = 0;
    while (di > 0) {
        if (group == 3) {
            oi -= 1;
            out[oi] = ' ';
            group = 0;
        }
        di -= 1;
        oi -= 1;
        out[oi] = s[di];
        group += 1;
    }
    return out[oi..];
}

fn idxSlice(a: std.mem.Allocator, n: usize) []usize {
    const ids = a.alloc(usize, n) catch @panic("OOM");
    for (ids, 0..) |*p, i| p.* = i;
    return ids;
}

// ── view components ───────────────────────────────────────────────

const ChipCtx = struct {
    s: *Session,
    sel: ?usize,
    action: []const u8,
    prefix: []const u8,
};

fn chip(a: std.mem.Allocator, prefix: []const u8, i: usize, sel: ?usize, action: []const u8, label: []const u8) forest.Node {
    const on = sel != null and sel.? == i;
    return forest.el(a, .button, .{
        .id = std.fmt.allocPrint(a, "chip-{s}-{d}", .{ prefix, i }) catch @panic("OOM"),
        .class = if (on) "chip on" else "chip",
        .on = .{ .click = action },
        .arg = std.fmt.allocPrint(a, "{d}", .{i}) catch @panic("OOM"),
    }, label);
}

fn brandChip(a: std.mem.Allocator, ctx: ChipCtx, i: usize) ?forest.Node {
    const b = CarData.brandAt(i) orelse return null;
    return chip(a, "brand", i, ctx.sel, ctx.action, b.name);
}

fn modelChip(a: std.mem.Allocator, ctx: ChipCtx, i: usize) ?forest.Node {
    const b = ctx.s.brand orelse return null;
    const m = CarData.modelAt(b, i) orelse return null;
    return chip(a, "model", i, ctx.sel, ctx.action, m.name);
}

fn yearChip(a: std.mem.Allocator, ctx: ChipCtx, i: usize) ?forest.Node {
    const b = ctx.s.brand orelse return null;
    const m = ctx.s.model orelse return null;
    const md = CarData.modelAt(b, m) orelse return null;
    const y = md.year_lo + @as(u16, @intCast(i));
    var ybuf: [8]u8 = undefined;
    const label = std.fmt.bufPrint(&ybuf, "{d}", .{y}) catch unreachable;
    // bufPrint result is stack memory — dupe into the render arena.
    return chip(a, "year", i, ctx.sel, ctx.action, a.dupe(u8, label) catch @panic("OOM"));
}

fn chipRow(a: std.mem.Allocator, id: []const u8, count: usize, render: anytype, ctx: anytype) forest.Node {
    return forest.el(a, .div, .{ .class = "chips", .id = id }, forest.eachOf(a, idxSlice(a, count), ctx, render));
}

fn vehicleView(a: std.mem.Allocator, s: *Session) forest.Node {
    const bcount = CarData.brands.len;
    const mcount = if (s.brand) |b| CarData.brandAt(b).?.models.len else 0;
    const ycount = if (s.brand != null and s.model != null) blk: {
        const md = CarData.modelAt(s.brand.?, s.model.?).?;
        break :blk @as(usize, md.year_hi - md.year_lo + 1);
    } else 0;

    var parts = std.ArrayListUnmanaged(forest.Node).empty;
    parts.append(a, forest.el(a, .h2, .{ .class = "sec" }, "1. Автомобиль")) catch @panic("OOM");
    parts.append(a, forest.el(a, .div, .{ .class = "fld" }, .{
        forest.el(a, .span, .{ .class = "flabel" }, "Марка"),
        chipRow(a, "veh-brand", bcount, brandChip, ChipCtx{ .s = s, .sel = s.brand, .action = "set_brand", .prefix = "brand" }),
    })) catch @panic("OOM");
    if (mcount > 0) {
        parts.append(a, forest.el(a, .div, .{ .class = "fld" }, .{
            forest.el(a, .span, .{ .class = "flabel" }, "Модель"),
            chipRow(a, "veh-model", mcount, modelChip, ChipCtx{ .s = s, .sel = s.model, .action = "set_model", .prefix = "model" }),
        })) catch @panic("OOM");
    }
    const year_sel: ?usize = if (s.year) |y| blk: {
        const md = CarData.modelAt(s.brand.?, s.model.?).?;
        break :blk @as(usize, y - md.year_lo);
    } else null;
    if (ycount > 0) {
        parts.append(a, forest.el(a, .div, .{ .class = "fld" }, .{
            forest.el(a, .span, .{ .class = "flabel" }, "Год"),
            chipRow(a, "veh-year", ycount, yearChip, ChipCtx{ .s = s, .sel = year_sel, .action = "set_year", .prefix = "year" }),
        })) catch @panic("OOM");
    }
    if (s.vehicleComplete()) {
        const b = CarData.brandAt(s.brand.?).?;
        const m = CarData.modelAt(s.brand.?, s.model.?).?;
        const spec = std.fmt.allocPrint(a, "{s} {s} · {d} г. · {s} · {s} · {s} привод", .{
            b.name, m.name, s.year.?, m.spec.engine, m.spec.gearbox, m.spec.drivetrain,
        }) catch @panic("OOM");
        parts.append(a, forest.el(a, .div, .{ .id = "car-spec", .class = "spec" }, spec)) catch @panic("OOM");
    }
    return forest.el(a, .section, .{ .class = "vsec" }, parts.items);
}

fn svcCard(a: std.mem.Allocator, s: *Session, sv: *const CarData.Service) forest.Node {
    const on = s.hasSvc(sv.id);
    var kids = std.ArrayListUnmanaged(forest.Node).empty;
    kids.append(a, forest.el(a, .span, .{ .class = "svc-name" }, sv.name)) catch @panic("OOM");
    kids.append(a, forest.el(a, .span, .{ .class = "svc-meta" }, forest.fragment(a, .{
        forest.el(a, .span, .{ .class = "svc-price" }, fmtPrice(a, sv.price)),
        if (sv.dur > 0)
            forest.el(a, .span, .{ .class = "svc-dur" }, std.fmt.allocPrint(a, "≈{d} мин", .{sv.dur}) catch @panic("OOM"))
        else
            forest.el(a, .span, .{ .class = "svc-dur" }, ""),
    }))) catch @panic("OOM");
    return forest.el(a, .div, .{
        .id = std.fmt.allocPrint(a, "svc-{d}", .{sv.id}) catch @panic("OOM"),
        .class = if (on) "svc on" else "svc",
        .on = .{ .click = "toggle_svc" },
        .arg = std.fmt.allocPrint(a, "{d}", .{sv.id}) catch @panic("OOM"),
    }, kids.items);
}

fn servicesView(a: std.mem.Allocator, s: *Session) forest.Node {
    var parts = std.ArrayListUnmanaged(forest.Node).empty;
    parts.append(a, forest.el(a, .h2, .{ .class = "sec" }, "2. Услуги")) catch @panic("OOM");
    // Per-cat id slices, then one eachOf grid per category header.
    for (CarData.cat_order, 0..) |cat, ci| {
        var list = std.ArrayListUnmanaged(u32).empty;
        for (CarData.services) |sv| {
            if (sv.cat == cat) list.append(a, sv.id) catch @panic("OOM");
        }
        const ids = list.items;
        if (ids.len == 0) continue;
        parts.append(a, forest.el(a, .h3, .{ .class = "cat" }, cat.name())) catch @panic("OOM");
        const CtxT = struct { s: *Session, ids: []u32 };
        parts.append(a, forest.el(a, .div, .{ .class = "svc-grid", .id = std.fmt.allocPrint(a, "cat-{d}", .{ci}) catch @panic("OOM") }, forest.eachOf(a, ids, CtxT{ .s = s, .ids = ids }, struct {
            fn row(arena: std.mem.Allocator, c: CtxT, id: u32) ?forest.Node {
                return svcCard(arena, c.s, CarData.serviceAt(id) orelse return null);
            }
        }.row))) catch @panic("OOM");
    }
    return forest.el(a, .section, .{ .class = "vsec" }, parts.items);
}

const UpsellCtx = struct { s: *Session, sugs: []const Session.Suggestion };

fn upsellOrNull(a: std.mem.Allocator, ctx: UpsellCtx, i: usize) ?forest.Node {
    if (i >= ctx.sugs.len) return null;
    const sug = ctx.sugs[i];
    const sv = CarData.serviceAt(sug.id) orelse return null;
    const in_cart = ctx.s.hasSvc(sug.id);
    return forest.el(a, .div, .{
        .id = std.fmt.allocPrint(a, "upsell-{d}", .{sv.id}) catch @panic("OOM"),
        .class = "upsell",
    }, .{
        forest.el(a, .div, .{ .class = "upsell-txt" }, .{
            forest.el(a, .span, .{ .class = "upsell-name" }, sv.name),
            forest.el(a, .span, .{ .class = "upsell-why" }, sug.reason),
        }),
        forest.el(a, .span, .{ .class = "upsell-price" }, fmtPrice(a, sv.price)),
        if (in_cart)
            forest.el(a, .span, .{ .class = "upsell-in" }, "в заказе")
        else
            forest.el(a, .button, .{
                .class = "btn mini",
                .on = .{ .click = "add_svc" },
                .arg = std.fmt.allocPrint(a, "{d}", .{sv.id}) catch @panic("OOM"),
            }, "+"),
    });
}

fn upsellsView(a: std.mem.Allocator, s: *Session) forest.Node {
    const sugs = s.suggestions(a);
    return forest.when(a, .{ .id = "w-upsell" }, sugs.len > 0, forest.el(a, .section, .{ .class = "vsec" }, .{
        forest.el(a, .h2, .{ .class = "sec" }, "Рекомендуем"),
        forest.el(a, .div, .{ .class = "upsell-list", .id = "upsells" }, forest.eachOf(a, idxSlice(a, sugs.len), UpsellCtx{ .s = s, .sugs = sugs }, upsellOrNull)),
    }));
}

fn sumLine(a: std.mem.Allocator, id: []const u8, name: []const u8, price_text: []const u8, cls: []const u8) forest.Node {
    return forest.el(a, .div, .{ .id = id, .class = cls }, .{
        forest.el(a, .span, .{ .class = "sum-name" }, name),
        forest.el(a, .span, .{ .class = "sum-price" }, price_text),
    });
}

const SumCtx = struct { s: *Session, ids: []u32 };

fn sumOrNull(a: std.mem.Allocator, ctx: SumCtx, id: u32) ?forest.Node {
    _ = ctx;
    const sv = CarData.serviceAt(id) orelse return null;
    return sumLine(
        a,
        std.fmt.allocPrint(a, "sum-{d}", .{sv.id}) catch @panic("OOM"),
        sv.name,
        std.fmt.allocPrint(a, "{s} ₽", .{fmtPrice(a, sv.price)}) catch @panic("OOM"),
        "sum-line",
    );
}

fn summaryView(a: std.mem.Allocator, s: *Session) forest.Node {
    const ids = s.cartIds(a);
    return forest.when(a, .{ .id = "w-sum" }, ids.len > 0, blk: {
        var kids = std.ArrayListUnmanaged(forest.Node).empty;
        kids.append(a, forest.el(a, .h2, .{ .class = "sec" }, "3. Заказ")) catch @panic("OOM");
        kids.append(a, forest.el(a, .div, .{ .class = "sum-list", .id = "cart" }, forest.eachOf(a, ids, SumCtx{ .s = s, .ids = ids }, sumOrNull))) catch @panic("OOM");
        const dbuf = a.alloc(Session.Discount, 3) catch @panic("OOM");
        for (s.discounts(dbuf), 0..) |d, i| {
            kids.append(a, sumLine(
                a,
                std.fmt.allocPrint(a, "disc-{d}", .{i}) catch @panic("OOM"),
                d.label,
                std.fmt.allocPrint(a, "−{s} ₽", .{fmtPrice(a, d.amount)}) catch @panic("OOM"),
                "sum-line disc",
            )) catch @panic("OOM");
        }
        kids.append(a, forest.el(a, .div, .{ .id = "sum-total", .class = "sum-total" }, .{
            forest.el(a, .span, .{}, "Итого"),
            forest.el(a, .span, .{}, std.fmt.allocPrint(a, "{s} ₽", .{fmtPrice(a, s.total())}) catch @panic("OOM")),
        })) catch @panic("OOM");
        kids.append(a, forest.el(a, .form, .{
            .class = "book-form",
            .autocomplete = "off",
            .on = .{ .submit = "book" },
        }, .{
            forest.el(a, .input, .{ .name = "cust", .placeholder = "Ваше имя", .maxlength = 60 }, .{}),
            forest.el(a, .input, .{ .name = "phone", .placeholder = "Телефон", .maxlength = 30 }, .{}),
            forest.el(a, .button, .{ .type = "submit", .class = "btn" }, "Записаться"),
        })) catch @panic("OOM");
        break :blk forest.el(a, .section, .{ .class = "vsec" }, kids.items);
    });
}

const BookCtx = struct { s: *Session };

fn bookOrNull(a: std.mem.Allocator, ctx: BookCtx, b: Booking) ?forest.Node {
    _ = ctx;
    return forest.el(a, .div, .{ .id = std.fmt.allocPrint(a, "bk-{d}", .{b.id}) catch @panic("OOM"), .class = "booking" }, .{
        forest.el(a, .span, .{ .class = "bk-id" }, std.fmt.allocPrint(a, "#{d}", .{b.id}) catch @panic("OOM")),
        forest.el(a, .span, .{ .class = "bk-main" }, .{
            forest.el(a, .span, .{ .class = "bk-name" }, b.name),
            forest.el(a, .span, .{ .class = "bk-car" }, b.car),
        }),
        forest.el(a, .span, .{ .class = "bk-meta" }, std.fmt.allocPrint(a, "{s} · {d} услуги · {s} ₽", .{
            b.phone, b.items, fmtPrice(a, b.total),
        }) catch @panic("OOM")),
    });
}

fn bookingsView(a: std.mem.Allocator, s: *Session) forest.Node {
    return forest.when(a, .{ .id = "w-book" }, s.bookings.items.len > 0, forest.el(a, .section, .{ .class = "vsec" }, .{
        forest.el(a, .h2, .{ .class = "sec" }, "Записи"),
        forest.el(a, .div, .{ .class = "book-list", .id = "bookings" }, forest.eachOf(a, s.bookings.items, BookCtx{ .s = s }, bookOrNull)),
    }));
}

fn buildView(a: std.mem.Allocator, s: *Session) []const forest.Node {
    const nodes = a.alloc(forest.Node, 6) catch @panic("OOM");
    nodes[0] = forest.fragment(a, .{
        forest.el(a, .h1, .{}, .{
            forest.text("zcar "),
            forest.el(a, .span, .{}, "запись в сервис"),
        }),
        forest.el(a, .p, .{ .class = "sub" }, "Автомобиль → услуги → комбо-скидки. Всё считается на сервере."),
    });
    nodes[1] = vehicleView(a, s);
    nodes[2] = servicesView(a, s);
    nodes[3] = upsellsView(a, s);
    nodes[4] = summaryView(a, s);
    nodes[5] = bookingsView(a, s);
    return nodes;
}

// ── session factory ───────────────────────────────────────────────

pub fn createSession(gpa: std.mem.Allocator) *Session {
    const s = gpa.create(Session) catch @panic("OOM");
    s.* = .{
        .gpa = gpa,
        .app = zefx.createApp(gpa),
        .mutate = undefined,
        .seq = undefined,
        .dom = forest.Dom.init(gpa),
        .log = forest.PatchLog.init(gpa),
        .history = History.init(gpa),
        .render_arena = std.heap.ArenaAllocator.init(gpa),
    };
    s.mutate = s.app.createEvent(Mutation);
    s.seq = s.app.createStore(u64, 0);
    s.wire();
    return s;
}

// ── tests ─────────────────────────────────────────────────────────

fn patchJson(s: *Session, alloc: std.mem.Allocator) []u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    s.log.writeJson(&aw.writer) catch @panic("OOM");
    s.log.clear();
    return aw.toOwnedSlice() catch @panic("OOM");
}

fn fields2(alloc: std.mem.Allocator, k1: []const u8, v1: []const u8, k2: []const u8, v2: []const u8) std.json.ObjectMap {
    var m: std.json.ObjectMap = .empty;
    m.put(alloc, k1, .{ .string = v1 }) catch @panic("OOM");
    m.put(alloc, k2, .{ .string = v2 }) catch @panic("OOM");
    return m;
}

test "vehicle cascade resets downstream choices" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();
    s.seedDom();

    try s.dispatch("set_brand", "0", null, null);
    try std.testing.expectEqual(@as(?usize, 0), s.brand);
    try s.dispatch("set_model", "0", null, null);
    try s.dispatch("set_year", "2018", null, null);
    try std.testing.expect(s.vehicleComplete());

    // brand switch resets model+year
    try s.dispatch("set_brand", "4", null, null);
    try std.testing.expectEqual(@as(?usize, 4), s.brand);
    try std.testing.expect(s.model == null and s.year == null);

    // out-of-range / bad args rejected
    try std.testing.expectError(error.InvalidChoice, s.dispatch("set_brand", "99", null, null));
    try std.testing.expectError(error.InvalidChoice, s.dispatch("set_model", "9", null, null)); // Lada has 3 models
    try std.testing.expectError(error.InvalidChoice, s.dispatch("set_year", "1999", null, null));
}

test "cart, combos and booking" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();
    s.seedDom();

    try s.dispatch("set_brand", "0", null, null);
    try s.dispatch("set_model", "0", null, null);
    try s.dispatch("set_year", "2018", null, null);

    // three maintenance services → 15% combo activates
    try s.dispatch("toggle_svc", "1", null, null);
    try s.dispatch("toggle_svc", "2", null, null);
    try s.dispatch("toggle_svc", "3", null, null);
    const sub = s.subtotal();
    try std.testing.expectEqual(@as(u32, 4500 + 6800 + 9200), sub);
    var dbuf: [3]Session.Discount = undefined;
    const discs = s.discounts(&dbuf);
    // 3×ТО combo (15% of 20 500) + big-order combo (10% of 20 500).
    try std.testing.expectEqual(@as(usize, 2), discs.len);
    try std.testing.expectEqual(@as(u32, sub * 15 / 100), discs[0].amount);
    try std.testing.expectEqual(@as(u32, sub * 10 / 100), discs[1].amount);
    var expect_total = sub;
    for (discs) |d| expect_total -|= d.amount;
    try std.testing.expectEqual(expect_total, s.total());

    // toggle off removes
    try s.dispatch("toggle_svc", "3", null, null);
    try std.testing.expect(!s.hasSvc(3));
    try std.testing.expectEqual(@as(usize, 0), s.discounts(&dbuf).len);

    // book without contact → BadContact; with → booking + cart cleared
    var f = fields2(alloc, "cust", "Ivan", "phone", "123");
    defer f.deinit(alloc);
    try std.testing.expectError(error.BadContact, s.dispatch("book", null, null, &f));
    var f2 = fields2(alloc, "cust", "Ivan Petrov", "phone", "+7 900 123-45-67");
    defer f2.deinit(alloc);
    const j = patchJson(s, alloc);
    defer alloc.free(j);
    try s.dispatch("book", null, null, &f2);
    try std.testing.expectEqual(@as(usize, 1), s.bookings.items.len);
    const bk = s.bookings.items[0];
    try std.testing.expectEqualStrings("Toyota Camry 2018", bk.car);
    try std.testing.expectEqual(@as(u32, 2), bk.items);
    try std.testing.expectEqual(@as(usize, 0), s.services.count());
    alloc.free(patchJson(s, alloc));
}

test "upsell suggestions follow cart and vehicle age" {
    const alloc = std.testing.allocator;
    const s = createSession(alloc);
    defer s.deinit();
    s.seedDom();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try s.dispatch("set_brand", "0", null, null);
    try s.dispatch("set_model", "0", null, null);
    try s.dispatch("set_year", "2012", null, null); // ≤2014 → ГРМ upsell

    try std.testing.expectEqual(@as(usize, 1), s.suggestions(a).len);
    try std.testing.expectEqual(@as(u32, 6), s.suggestions(a)[0].id);

    // engine work → oil-change upsell appears too
    try s.dispatch("toggle_svc", "7", null, null);
    const sugs = s.suggestions(a);
    try std.testing.expectEqual(@as(usize, 2), sugs.len);

    // add_svc on an upsell inserts it; duplicates are no-ops
    try s.dispatch("add_svc", "9", null, null);
    try std.testing.expect(s.hasSvc(9));
    try s.dispatch("add_svc", "9", null, null);
    try std.testing.expectEqual(@as(usize, 1), blk: {
        var n: usize = 0;
        var kit = s.services.keyIterator();
        while (kit.next()) |k| {
            if (k.* == 9) n += 1;
        }
        break :blk n;
    });
}
