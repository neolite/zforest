//! zcar — auto-service booking on the diff path: cascading vehicle
//! picker (brand → model → year → derived specs), a category-grouped
//! service menu, context-sensitive upsells and combo discounts, and a
//! booking form producing a per-session bookings list. Structure changes
//! constantly (chips swap, cart lines appear), so this app uses the
//! rebuild+diff renderer — the counterpart to zmon's live bindings.
//!
//! zmeta app dir: `app.zig` holds the domain model + `CarDeps` (the
//! `Session(Deps)` skeleton contract), `pages/index.zig` the single
//! "/" view, `actions.zig` the manifest, `gen/` the checked-in codegen.

const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const zmeta = @import("zmeta.zig");
const routes = @import("gen/routes.zig");
const actions = @import("gen/actions.zig");
const CarData = @import("car_data.zig");

pub const Route = routes.Route;
pub const act = actions.act;

pub const Booking = struct {
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

/// Car domain state + graph handles — the zmeta `Deps`
/// (docs/meta-framework.md §5.2-5.3). The `zmeta.Session` skeleton owns
/// the transport contract (Dom/log/history/arena/CSRF/seq/render hook);
/// everything domain-specific — vehicle selection, the service cart,
/// bookings, the mutation event, action validation — lives here. The
/// session contract for the generic server is provided by the skeleton
/// (see zmeta/session.zig).
pub const CarDeps = struct {
    /// Page <title> and <main> class rendered by the server's page shell.
    pub const page_title = "zcar — запись в сервис";
    pub const page_class = "app app-car";
    /// Session cookie name — "zfxc" keeps zcar sessions distinct from
    /// the other apps' on the same host.
    pub const cookie_name = "zfxc";

    /// Current typed route — written by the generated `routes.setRoute`
    /// glue; read by `routes.prepare`/`routes.viewNodes` dispatch.
    route: routes.Route = .{ .index = .{} },

    brand: ?usize = null,
    model: ?usize = null,
    year: ?u16 = null,
    /// Selected service ids — presence is the state.
    services: std.AutoHashMapUnmanaged(u32, void) = .empty,
    bookings: std.ArrayListUnmanaged(Booking) = .empty,
    next_booking: u32 = 1,

    mutate: *zefx.Event(Mutation),

    /// `Deps.init` — create the graph handles on the session's engine.
    /// `seq` already exists; `wire` registers the reducer next.
    pub fn init(s: *Session) CarDeps {
        return .{ .mutate = s.app.createEvent(Mutation) };
    }

    /// `Deps.deinit` — free domain allocations. Runs before the
    /// skeleton tears down dom/log/history/arena/app.
    pub fn deinit(s: *Session) void {
        s.deps.services.deinit(s.gpa);
        for (s.deps.bookings.items) |b| {
            s.gpa.free(b.name);
            s.gpa.free(b.phone);
            s.gpa.free(b.car);
        }
        s.deps.bookings.deinit(s.gpa);
    }

    /// `Deps.wire` — pure-phase reducers. The skeleton installs the
    /// render after-flush hook after this returns.
    pub fn wire(s: *Session) void {
        s.deps.mutate.onReducer(s, &applyMutation);
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

    /// act.set_brand — brand index; resets model+year downstream.
    pub fn on_set_brand(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = fields;
        const i = try argIdx(value orelse arg, CarData.brands.len);
        s.deps.mutate.emit(.{ .set_brand = i });
    }

    /// act.set_model — model index within the chosen brand.
    pub fn on_set_model(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = fields;
        const bound = if (s.deps.brand) |b| CarData.brandAt(b).?.models.len else 0;
        const i = try argIdx(value orelse arg, bound);
        s.deps.mutate.emit(.{ .set_model = i });
    }

    /// act.set_year — year within the chosen model's range.
    pub fn on_set_year(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = fields;
        const a_str = value orelse arg orelse return error.InvalidAction;
        const y = std.fmt.parseInt(u16, a_str, 10) catch return error.InvalidChoice;
        const m = if (s.deps.brand != null and s.deps.model != null)
            CarData.modelAt(s.deps.brand.?, s.deps.model.?)
        else
            null;
        const md = m orelse return error.InvalidChoice;
        if (y < md.year_lo or y > md.year_hi) return error.InvalidChoice;
        s.deps.mutate.emit(.{ .set_year = y });
    }

    /// act.toggle_svc / act.add_svc — cart toggle vs guaranteed add;
    /// both validate the service id the same way.
    pub fn on_toggle_svc(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = value;
        _ = fields;
        s.deps.mutate.emit(.{ .toggle_svc = try svcId(arg) });
    }

    pub fn on_add_svc(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = value;
        _ = fields;
        s.deps.mutate.emit(.{ .add_svc = try svcId(arg) });
    }

    /// act.book — `fields.cust`/`fields.phone`; requires a complete
    /// vehicle and a non-empty cart.
    pub fn on_book(
        s: *Session,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        _ = arg;
        _ = value;
        const f = fields orelse return error.InvalidAction;
        const name = try fieldStr(f, "cust");
        const phone = try fieldStr(f, "phone");
        const n = std.mem.trim(u8, name, " \t\r\n");
        const p = std.mem.trim(u8, phone, " \t\r\n");
        if (n.len < 2 or p.len < 5) return error.BadContact;
        if (!vehicleComplete(s)) return error.IncompleteVehicle;
        if (s.deps.services.count() == 0) return error.EmptyCart;
        s.deps.mutate.emit(.{ .book = .{ .name = n, .phone = p } });
    }
};

/// One browser session: an isolated zefx graph + booking draft + DOM
/// patch state, provided by the zmeta skeleton (see zmeta/session.zig).
pub const Session = zmeta.Session(CarDeps);

/// Wired session constructor for tests — the server mints sessions via
/// `Session.create(gpa, io)`; zcar mints no tokens so `io` is unused.
pub fn createSession(gpa: std.mem.Allocator) *Session {
    return Session.create(gpa, std.testing.io);
}

// ── cart math ─────────────────────────────────────────────────

pub fn hasSvc(s: *Session, id: u32) bool {
    return s.deps.services.contains(id);
}

fn catCount(s: *Session, cat: CarData.Cat) u32 {
    var n: u32 = 0;
    var it = s.deps.services.keyIterator();
    while (it.next()) |id| {
        if (CarData.serviceAt(id.*)) |sv| {
            if (sv.cat == cat) n += 1;
        }
    }
    return n;
}

fn catSubtotal(s: *Session, cat: CarData.Cat) u32 {
    var sum: u32 = 0;
    var it = s.deps.services.keyIterator();
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
pub fn discounts(s: *Session, buf: []Discount) []const Discount {
    var n: usize = 0;
    const maint_n = catCount(s, .maintenance);
    if (maint_n >= 3) {
        buf[n] = .{ .label = "Лояльность: 3+ ТО — скидка 15% на ТО", .amount = catSubtotal(s, .maintenance) * 15 / 100 };
        n += 1;
    }
    if (hasSvc(s, 16) and hasSvc(s, 17)) {
        buf[n] = .{ .label = "Комбо: шиномонтаж + балансировка −20%", .amount = (CarData.serviceAt(16).?.price + CarData.serviceAt(17).?.price) * 20 / 100 };
        n += 1;
    }
    const sub = subtotal(s);
    if (sub >= 20000) {
        buf[n] = .{ .label = "Крупный заказ — скидка 10%", .amount = sub * 10 / 100 };
        n += 1;
    }
    return buf[0..n];
}

pub fn subtotal(s: *Session) u32 {
    var sum: u32 = 0;
    var it = s.deps.services.keyIterator();
    while (it.next()) |id| {
        if (CarData.serviceAt(id.*)) |sv| sum += sv.price;
    }
    return sum;
}

pub fn total(s: *Session) u32 {
    var t = subtotal(s);
    var buf: [3]Discount = undefined;
    for (discounts(s, &buf)) |d| t -|= d.amount;
    return t;
}

/// Selected ids sorted ascending — stable order for the summary list.
pub fn cartIds(s: *Session, a: std.mem.Allocator) []u32 {
    const ids = a.alloc(u32, s.deps.services.count()) catch @panic("OOM");
    var n: usize = 0;
    var it = s.deps.services.keyIterator();
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
pub fn suggestions(s: *Session, a: std.mem.Allocator) []const Suggestion {
    var out: std.ArrayListUnmanaged(Suggestion) = .empty;
    const add = struct {
        fn f(list: *std.ArrayListUnmanaged(Suggestion), alloc: std.mem.Allocator, id: u32, reason: []const u8) void {
            for (list.items) |sug| {
                if (sug.id == id) return;
            }
            list.append(alloc, .{ .id = id, .reason = reason }) catch @panic("OOM");
        }
    }.f;

    var it = s.deps.services.keyIterator();
    var has_engine = false;
    var has_gearbox = false;
    while (it.next()) |id| {
        if (CarData.serviceAt(id.*)) |sv| {
            has_engine = has_engine or sv.cat == .engine;
            has_gearbox = has_gearbox or sv.cat == .gearbox;
        }
    }
    if (has_engine and !hasSvc(s, 9)) add(&out, a, 9, "Вместе с работами по двигателю");
    if (has_gearbox and !hasSvc(s, 10)) add(&out, a, 10, "Вместе с работами по коробке");
    if (hasSvc(s, 16) and !hasSvc(s, 17)) add(&out, a, 17, "В пару к шиномонтажу");
    if (hasSvc(s, 13) and !hasSvc(s, 14)) add(&out, a, 14, "Геометрия после амортизаторов");
    if (s.deps.year) |y| {
        if (y <= 2014 and !hasSvc(s, 6)) {
            const reason = std.fmt.allocPrint(a, "Авто {d} г.в. — износ цепи ГРМ", .{y}) catch unreachable;
            add(&out, a, 6, reason);
        }
    }
    if (s.deps.services.count() >= 4) add(&out, a, 21, "Перед выдачей — проверить электрику");
    return out.items;
}

pub fn vehicleComplete(s: *Session) bool {
    return s.deps.brand != null and s.deps.model != null and s.deps.year != null;
}

fn carDesc(s: *Session, a: std.mem.Allocator) []u8 {
    const b = CarData.brandAt(s.deps.brand.?).?;
    const m = CarData.modelAt(s.deps.brand.?, s.deps.model.?).?;
    return std.fmt.allocPrint(a, "{s} {s} {d}", .{ b.name, m.name, s.deps.year.? }) catch @panic("OOM");
}

// ── action helpers ──────────────────────────────────────────────

fn argIdx(arg: ?[]const u8, bound: usize) ActionError!usize {
    const a = arg orelse return error.InvalidAction;
    const i = std.fmt.parseInt(usize, a, 10) catch return error.InvalidChoice;
    if (i >= bound) return error.InvalidChoice;
    return i;
}

/// Shared service-id validation for toggle_svc/add_svc: `arg` carries
/// the id, it must parse and name a real service.
fn svcId(arg: ?[]const u8) ActionError!u32 {
    const a = arg orelse return error.InvalidAction;
    const id = std.fmt.parseInt(u32, a, 10) catch return error.InvalidChoice;
    if (CarData.serviceAt(id) == null) return error.InvalidChoice;
    return id;
}

fn fieldStr(f: *const std.json.ObjectMap, key: []const u8) ActionError![]const u8 {
    const v = f.get(key) orelse return error.InvalidAction;
    return switch (v) {
        .string => |s| s,
        else => error.InvalidAction,
    };
}

// ── graph wiring ───────────────────────────────────────────────

/// mutate reducer — pure-phase model change, then bump the revision
/// (the skeleton's after-flush hook renders the diff).
fn applyMutation(s: *Session, m: Mutation) void {
    switch (m) {
        .set_brand => |i| {
            s.deps.brand = i;
            s.deps.model = null;
            s.deps.year = null;
        },
        .set_model => |i| {
            s.deps.model = i;
            s.deps.year = null;
        },
        .set_year => |y| s.deps.year = y,
        .toggle_svc => |id| {
            if (s.deps.services.fetchRemove(id)) |_| {
                // removed
            } else {
                s.deps.services.put(s.gpa, id, {}) catch @panic("OOM");
            }
        },
        .add_svc => |id| {
            if (!s.deps.services.contains(id)) {
                s.deps.services.put(s.gpa, id, {}) catch @panic("OOM");
            }
        },
        .book => |b| {
            const car = carDesc(s, s.gpa);
            s.deps.bookings.append(s.gpa, .{
                .id = s.deps.next_booking,
                .name = s.gpa.dupe(u8, b.name) catch @panic("OOM"),
                .phone = s.gpa.dupe(u8, b.phone) catch @panic("OOM"),
                .car = car,
                .items = @intCast(s.deps.services.count()),
                .total = total(s),
            }) catch @panic("OOM");
            s.deps.next_booking += 1;
            s.deps.services.clearRetainingCapacity();
        },
    }
    s.bumpSeq();
}

// ── formatting helpers ────────────────────────────────────────────

/// "12345" → "12 345" — thin-space grouping for prices.
pub fn fmtPrice(a: std.mem.Allocator, price: u32) []const u8 {
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
    try std.testing.expectEqual(@as(?usize, 0), s.deps.brand);
    try s.dispatch("set_model", "0", null, null);
    try s.dispatch("set_year", "2018", null, null);
    try std.testing.expect(vehicleComplete(s));

    // brand switch resets model+year
    try s.dispatch("set_brand", "4", null, null);
    try std.testing.expectEqual(@as(?usize, 4), s.deps.brand);
    try std.testing.expect(s.deps.model == null and s.deps.year == null);

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
    const sub = subtotal(s);
    try std.testing.expectEqual(@as(u32, 4500 + 6800 + 9200), sub);
    var dbuf: [3]Discount = undefined;
    const discs = discounts(s, &dbuf);
    // 3×ТО combo (15% of 20 500) + big-order combo (10% of 20 500).
    try std.testing.expectEqual(@as(usize, 2), discs.len);
    try std.testing.expectEqual(@as(u32, sub * 15 / 100), discs[0].amount);
    try std.testing.expectEqual(@as(u32, sub * 10 / 100), discs[1].amount);
    var expect_total = sub;
    for (discs) |d| expect_total -|= d.amount;
    try std.testing.expectEqual(expect_total, total(s));

    // toggle off removes
    try s.dispatch("toggle_svc", "3", null, null);
    try std.testing.expect(!hasSvc(s, 3));
    try std.testing.expectEqual(@as(usize, 0), discounts(s, &dbuf).len);

    // book without contact → BadContact; with → booking + cart cleared
    var f = fields2(alloc, "cust", "Ivan", "phone", "123");
    defer f.deinit(alloc);
    try std.testing.expectError(error.BadContact, s.dispatch("book", null, null, &f));
    var f2 = fields2(alloc, "cust", "Ivan Petrov", "phone", "+7 900 123-45-67");
    defer f2.deinit(alloc);
    const j = patchJson(s, alloc);
    defer alloc.free(j);
    try s.dispatch("book", null, null, &f2);
    try std.testing.expectEqual(@as(usize, 1), s.deps.bookings.items.len);
    const bk = s.deps.bookings.items[0];
    try std.testing.expectEqualStrings("Toyota Camry 2018", bk.car);
    try std.testing.expectEqual(@as(u32, 2), bk.items);
    try std.testing.expectEqual(@as(usize, 0), s.deps.services.count());
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

    try std.testing.expectEqual(@as(usize, 1), suggestions(s, a).len);
    try std.testing.expectEqual(@as(u32, 6), suggestions(s, a)[0].id);

    // engine work → oil-change upsell appears too
    try s.dispatch("toggle_svc", "7", null, null);
    const sugs = suggestions(s, a);
    try std.testing.expectEqual(@as(usize, 2), sugs.len);

    // add_svc on an upsell inserts it; duplicates are no-ops
    try s.dispatch("add_svc", "9", null, null);
    try std.testing.expect(hasSvc(s, 9));
    try s.dispatch("add_svc", "9", null, null);
    try std.testing.expectEqual(@as(usize, 1), blk: {
        var n: usize = 0;
        var kit = s.deps.services.keyIterator();
        while (kit.next()) |k| {
            if (k.* == 9) n += 1;
        }
        break :blk n;
    });
}
