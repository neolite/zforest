//! zcar — auto-service booking on the diff path: cascading vehicle
//! picker (brand → model → year → derived specs), a category-grouped
//! service menu, context-sensitive upsells and combo discounts, and a
//! booking form producing a per-session bookings list. Structure changes
//! constantly (chips swap, cart lines appear), so this app uses the
//! rebuild+diff renderer — the counterpart to zmon's live bindings.

const std = @import("std");
const zefx = @import("zefx");
const forest = @import("forest");
const zmeta = @import("zmeta/root.zig");
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

/// Car domain state + graph handles — the zmeta `Deps`
/// (docs/meta-framework.md §5.2-5.3). The `zmeta.Session` skeleton owns
/// the transport contract (Dom/log/history/arena/CSRF/seq/render hook);
/// everything domain-specific — vehicle selection, the service cart,
/// bookings, the mutation event, action validation, the view tree —
/// lives here. The session contract for the generic server is provided
/// by the skeleton (see zmeta/session.zig).
pub const CarDeps = struct {
    /// Page <title> and <main> class rendered by the server's page shell.
    pub const page_title = "zcar — запись в сервис";
    pub const page_class = "app app-car";
    /// Session cookie name — "zfxc" keeps zcar sessions distinct from
    /// the other apps' on the same host.
    pub const cookie_name = "zfxc";

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

    /// `Deps.validPath` — single-route app: only "/" is a page route,
    /// so bogus paths 404 before a session is minted (the same gate
    /// the hand-rolled `validPath` applied).
    pub fn validPath(path: []const u8) bool {
        return std.mem.eql(u8, path, "/");
    }

    /// `Deps.dispatch` — whitelisted action entry point: the DOM event
    /// protocol maps to a Mutation emitted into the graph; the flush
    /// applies it (pure phase) and the skeleton's after-flush hook
    /// renders DOM patches into `s.log`.
    pub fn dispatch(
        s: *Session,
        action: []const u8,
        arg: ?[]const u8,
        value: ?[]const u8,
        fields: ?*const std.json.ObjectMap,
    ) ActionError!void {
        if (std.mem.eql(u8, action, "set_brand")) {
            const i = try argIdx(value orelse arg, CarData.brands.len);
            s.deps.mutate.emit(.{ .set_brand = i });
        } else if (std.mem.eql(u8, action, "set_model")) {
            const i = try argIdx(value orelse arg, if (s.deps.brand) |b| CarData.brandAt(b).?.models.len else 0);
            s.deps.mutate.emit(.{ .set_model = i });
        } else if (std.mem.eql(u8, action, "set_year")) {
            const a_str = value orelse arg orelse return error.InvalidAction;
            const y = std.fmt.parseInt(u16, a_str, 10) catch return error.InvalidChoice;
            const m = if (s.deps.brand != null and s.deps.model != null)
                CarData.modelAt(s.deps.brand.?, s.deps.model.?)
            else
                null;
            const md = m orelse return error.InvalidChoice;
            if (y < md.year_lo or y > md.year_hi) return error.InvalidChoice;
            s.deps.mutate.emit(.{ .set_year = y });
        } else if (std.mem.eql(u8, action, "toggle_svc") or std.mem.eql(u8, action, "add_svc")) {
            const a_str = arg orelse return error.InvalidAction;
            const id = std.fmt.parseInt(u32, a_str, 10) catch return error.InvalidChoice;
            if (CarData.serviceAt(id) == null) return error.InvalidChoice;
            if (std.mem.eql(u8, action, "toggle_svc")) {
                s.deps.mutate.emit(.{ .toggle_svc = id });
            } else {
                s.deps.mutate.emit(.{ .add_svc = id });
            }
        } else if (std.mem.eql(u8, action, "book")) {
            const f = fields orelse return error.InvalidAction;
            const name = try fieldStr(f, "cust");
            const phone = try fieldStr(f, "phone");
            const n = std.mem.trim(u8, name, " \t\r\n");
            const p = std.mem.trim(u8, phone, " \t\r\n");
            if (n.len < 2 or p.len < 5) return error.BadContact;
            if (!vehicleComplete(s)) return error.IncompleteVehicle;
            if (s.deps.services.count() == 0) return error.EmptyCart;
            s.deps.mutate.emit(.{ .book = .{ .name = n, .phone = p } });
        } else {
            return error.InvalidAction;
        }
    }

    /// `Deps.view` — the `<main>` body. Single-route app: `env.route`
    /// is always "/"; the tree is `buildView` below.
    pub fn view(a: std.mem.Allocator, s: *Session, env: *const zmeta.Env) []const forest.Node {
        _ = env;
        return buildView(a, s);
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

fn hasSvc(s: *Session, id: u32) bool {
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
fn discounts(s: *Session, buf: []Discount) []const Discount {
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

fn subtotal(s: *Session) u32 {
    var sum: u32 = 0;
    var it = s.deps.services.keyIterator();
    while (it.next()) |id| {
        if (CarData.serviceAt(id.*)) |sv| sum += sv.price;
    }
    return sum;
}

fn total(s: *Session) u32 {
    var t = subtotal(s);
    var buf: [3]Discount = undefined;
    for (discounts(s, &buf)) |d| t -|= d.amount;
    return t;
}

/// Selected ids sorted ascending — stable order for the summary list.
fn cartIds(s: *Session, a: std.mem.Allocator) []u32 {
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
fn suggestions(s: *Session, a: std.mem.Allocator) []const Suggestion {
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

fn vehicleComplete(s: *Session) bool {
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

/// One `<option>` in a linked select: `key` is the stable keyed-list
/// id suffix, `val` the payload sent back on change (the select's
/// `el.value`), `label` the visible text.
const OptItem = struct {
    key: []const u8,
    val: []const u8,
    label: []const u8,
    sel: bool,
    dis: bool = false,
};

const OptCtx = struct { which: []const u8 };

fn optOrNull(a: std.mem.Allocator, ctx: OptCtx, item: OptItem) ?forest.Node {
    return forest.el(a, .option, .{
        .id = std.fmt.allocPrint(a, "opt-{s}-{s}", .{ ctx.which, item.key }) catch @panic("OOM"),
        .value = item.val,
        .selected = item.sel,
        .disabled = item.dis,
        .text = item.label,
    }, .{});
}

fn numStr(a: std.mem.Allocator, n: anytype) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n}) catch @panic("OOM");
}

/// A `<select>` whose options are a keyed list. `value` binds the
/// select's current payload (attr op → `el.value` picks the option);
/// `disabled` is a presence attr gated on the upstream selection.
fn selectEl(
    a: std.mem.Allocator,
    id: []const u8,
    action: []const u8,
    value: []const u8,
    disabled: bool,
    which: []const u8,
    items: []const OptItem,
) forest.Node {
    return forest.el(a, .select, .{
        .id = id,
        .class = "sel",
        .on = .{ .change = action },
        .value = value,
        .disabled = disabled,
    }, forest.eachOf(a, items, OptCtx{ .which = which }, optOrNull));
}

fn fld(a: std.mem.Allocator, label: []const u8, control: forest.Node) forest.Node {
    return forest.el(a, .div, .{ .class = "fld" }, .{
        forest.el(a, .span, .{ .class = "flabel" }, label),
        control,
    });
}

fn vehicleView(a: std.mem.Allocator, s: *Session) forest.Node {
    var parts = std.ArrayListUnmanaged(forest.Node).empty;
    parts.append(a, forest.el(a, .h2, .{ .class = "sec" }, "1. Автомобиль")) catch @panic("OOM");

    var bitems = std.ArrayListUnmanaged(OptItem).empty;
    bitems.append(a, .{ .key = "x", .val = "", .label = "— марка —", .sel = s.deps.brand == null, .dis = true }) catch @panic("OOM");
    for (CarData.brands, 0..) |b, i| {
        const v = numStr(a, i);
        bitems.append(a, .{ .key = v, .val = v, .label = b.name, .sel = s.deps.brand != null and s.deps.brand.? == i }) catch @panic("OOM");
    }
    parts.append(a, fld(a, "Марка", selectEl(a, "sel-brand", "set_brand", if (s.deps.brand) |b| numStr(a, b) else "", false, "brand", bitems.items))) catch @panic("OOM");

    var mitems = std.ArrayListUnmanaged(OptItem).empty;
    mitems.append(a, .{ .key = "x", .val = "", .label = "— модель —", .sel = s.deps.model == null, .dis = true }) catch @panic("OOM");
    if (s.deps.brand) |bi| {
        const br = CarData.brandAt(bi).?;
        for (br.models, 0..) |m, i| {
            const v = numStr(a, i);
            mitems.append(a, .{ .key = v, .val = v, .label = m.name, .sel = s.deps.model != null and s.deps.model.? == i }) catch @panic("OOM");
        }
    }
    parts.append(a, fld(a, "Модель", selectEl(a, "sel-model", "set_model", if (s.deps.model) |m| numStr(a, m) else "", s.deps.brand == null, "model", mitems.items))) catch @panic("OOM");

    var yitems = std.ArrayListUnmanaged(OptItem).empty;
    yitems.append(a, .{ .key = "x", .val = "", .label = "— год —", .sel = s.deps.year == null, .dis = true }) catch @panic("OOM");
    if (s.deps.brand != null and s.deps.model != null) {
        const md = CarData.modelAt(s.deps.brand.?, s.deps.model.?).?;
        var y = md.year_lo;
        while (y <= md.year_hi) : (y += 1) {
            const v = numStr(a, y);
            yitems.append(a, .{ .key = v, .val = v, .label = v, .sel = s.deps.year != null and s.deps.year.? == y }) catch @panic("OOM");
        }
    }
    parts.append(a, fld(a, "Год", selectEl(a, "sel-year", "set_year", if (s.deps.year) |y| numStr(a, y) else "", s.deps.brand == null or s.deps.model == null, "year", yitems.items))) catch @panic("OOM");

    if (vehicleComplete(s)) {
        const b = CarData.brandAt(s.deps.brand.?).?;
        const m = CarData.modelAt(s.deps.brand.?, s.deps.model.?).?;
        const spec = std.fmt.allocPrint(a, "{s} {s} · {d} г. · {s} · {s} · {s} привод", .{
            b.name, m.name, s.deps.year.?, m.spec.engine, m.spec.gearbox, m.spec.drivetrain,
        }) catch @panic("OOM");
        // Mounted through a when-anchor: non-keyed children can't appear
        // or disappear via diff — only bound leaves and branch swaps can.
        parts.append(a, forest.when(a, .{ .id = "w-spec" }, true, forest.el(a, .div, .{ .id = "car-spec", .class = "spec", .text = spec }, .{}))) catch @panic("OOM");
    } else {
        parts.append(a, forest.when(a, .{ .id = "w-spec" }, false, forest.el(a, .div, .{ .id = "car-spec", .class = "spec" }, .{}))) catch @panic("OOM");
    }
    return forest.el(a, .section, .{ .class = "vsec" }, parts.items);
}

fn svcCard(a: std.mem.Allocator, s: *Session, sv: *const CarData.Service) forest.Node {
    const on = hasSvc(s, sv.id);
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

const UpsellCtx = struct { s: *Session, sugs: []const Suggestion };

fn upsellOrNull(a: std.mem.Allocator, ctx: UpsellCtx, i: usize) ?forest.Node {
    if (i >= ctx.sugs.len) return null;
    const sug = ctx.sugs[i];
    const sv = CarData.serviceAt(sug.id) orelse return null;
    const in_cart = hasSvc(ctx.s, sug.id);
    return forest.el(a, .div, .{
        .id = std.fmt.allocPrint(a, "upsell-{d}", .{sv.id}) catch @panic("OOM"),
        .class = "upsell",
    }, .{
        forest.el(a, .div, .{ .class = "upsell-txt" }, .{
            forest.el(a, .span, .{ .lid = "nm", .class = "upsell-name", .text = sv.name }, .{}),
            forest.el(a, .span, .{ .lid = "why", .class = "upsell-why", .text = sug.reason }, .{}),
        }),
        forest.el(a, .span, .{ .lid = "pr", .class = "upsell-price", .text = fmtPrice(a, sv.price) }, .{}),
        // Tag swap (span ↔ button) needs a branch anchor — plain
        // non-keyed children can't replace each other via diff.
        forest.variant(a, .{ .lid = "act" }, if (in_cart) "in" else "add", if (in_cart)
            forest.el(a, .span, .{ .class = "upsell-in" }, "в заказе")
        else
            forest.el(a, .button, .{
                .class = "btn mini",
                .on = .{ .click = "add_svc" },
                .arg = std.fmt.allocPrint(a, "{d}", .{sv.id}) catch @panic("OOM"),
            }, "+")),
    });
}

fn upsellsView(a: std.mem.Allocator, s: *Session) forest.Node {
    const sugs = suggestions(s, a);
    return forest.when(a, .{ .id = "w-upsell" }, sugs.len > 0, forest.el(a, .section, .{ .class = "vsec" }, .{
        forest.el(a, .h2, .{ .class = "sec" }, "Рекомендуем"),
        forest.el(a, .div, .{ .class = "upsell-list", .id = "upsells" }, forest.eachOf(a, idxSlice(a, sugs.len), UpsellCtx{ .s = s, .sugs = sugs }, upsellOrNull)),
    }));
}

fn sumLine(a: std.mem.Allocator, id: []const u8, name: []const u8, price_text: []const u8, cls: []const u8) forest.Node {
    return forest.el(a, .div, .{ .id = id, .class = cls }, .{
        forest.el(a, .span, .{ .lid = "nm", .class = "sum-name", .text = name }, .{}),
        forest.el(a, .span, .{ .lid = "pr", .class = "sum-price", .text = price_text }, .{}),
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
    const ids = cartIds(s, a);
    return forest.when(a, .{ .id = "w-sum" }, ids.len > 0, blk: {
        var kids = std.ArrayListUnmanaged(forest.Node).empty;
        kids.append(a, forest.el(a, .h2, .{ .class = "sec" }, "3. Заказ")) catch @panic("OOM");
        kids.append(a, forest.el(a, .div, .{ .class = "sum-list", .id = "cart" }, forest.eachOf(a, ids, SumCtx{ .s = s, .ids = ids }, sumOrNull))) catch @panic("OOM");
        const dbuf = a.alloc(Discount, 3) catch @panic("OOM");
        for (discounts(s, dbuf), 0..) |d, i| {
            kids.append(a, sumLine(
                a,
                std.fmt.allocPrint(a, "disc-{d}", .{i}) catch @panic("OOM"),
                d.label,
                std.fmt.allocPrint(a, "−{s} ₽", .{fmtPrice(a, d.amount)}) catch @panic("OOM"),
                "sum-line disc",
            )) catch @panic("OOM");
        }
        kids.append(a, forest.el(a, .div, .{ .id = "sum-total", .class = "sum-total" }, .{
            forest.el(a, .span, .{ .lid = "lbl", .text = "Итого" }, .{}),
            forest.el(a, .span, .{ .lid = "val", .text = std.fmt.allocPrint(a, "{s} ₽", .{fmtPrice(a, total(s))}) catch @panic("OOM") }, .{}),
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
    return forest.when(a, .{ .id = "w-book" }, s.deps.bookings.items.len > 0, forest.el(a, .section, .{ .class = "vsec" }, .{
        forest.el(a, .h2, .{ .class = "sec" }, "Записи"),
        forest.el(a, .div, .{ .class = "book-list", .id = "bookings" }, forest.eachOf(a, s.deps.bookings.items, BookCtx{ .s = s }, bookOrNull)),
    }));
}

// ── debug state dump ──────────────────────────────────────────────

fn jwStr(w: anytype, s: []const u8) void {
    forest.patch.writeJsonStringInto(w, s) catch @panic("OOM");
}

fn jwNum(w: anytype, n: anytype) void {
    w.print("{d}", .{n}) catch @panic("OOM");
}

/// Serializable snapshot of the whole backend model — the same state the
/// view reads, emitted as JSON for the on-page debug block. Bound via
/// `.text`, so every flush ships a `text` op when anything changed.
fn stateJson(a: std.mem.Allocator, s: *Session) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    w.writeByte('{') catch @panic("OOM");
    w.writeAll("\"rev\":") catch @panic("OOM");
    jwNum(w, s.seq.get());
    w.writeAll(",\"vehicle\":") catch @panic("OOM");
    if (s.deps.brand != null and s.deps.model != null and s.deps.year != null) {
        const b = CarData.brandAt(s.deps.brand.?).?;
        const m = CarData.modelAt(s.deps.brand.?, s.deps.model.?).?;
        w.writeByte('{') catch @panic("OOM");
        w.writeAll("\"brand\":") catch @panic("OOM");
        jwStr(w, b.name);
        w.writeAll(",\"model\":") catch @panic("OOM");
        jwStr(w, m.name);
        w.writeAll(",\"year\":") catch @panic("OOM");
        jwNum(w, s.deps.year.?);
        w.writeByte('}') catch @panic("OOM");
    } else {
        w.writeAll("null") catch @panic("OOM");
    }
    w.writeAll(",\"services\":[") catch @panic("OOM");
    const ids = cartIds(s, a);
    for (ids, 0..) |id, i| {
        if (i != 0) w.writeByte(',') catch @panic("OOM");
        jwNum(w, id);
    }
    w.writeByte(']') catch @panic("OOM");
    w.writeAll(",\"subtotal\":") catch @panic("OOM");
    jwNum(w, subtotal(s));
    w.writeAll(",\"discounts\":[") catch @panic("OOM");
    var dbuf: [3]Discount = undefined;
    for (discounts(s, &dbuf), 0..) |d, i| {
        if (i != 0) w.writeByte(',') catch @panic("OOM");
        w.writeByte('{') catch @panic("OOM");
        w.writeAll("\"label\":") catch @panic("OOM");
        jwStr(w, d.label);
        w.writeAll(",\"amount\":") catch @panic("OOM");
        jwNum(w, d.amount);
        w.writeByte('}') catch @panic("OOM");
    }
    w.writeByte(']') catch @panic("OOM");
    w.writeAll(",\"total\":") catch @panic("OOM");
    jwNum(w, total(s));
    w.writeAll(",\"bookings\":[") catch @panic("OOM");
    for (s.deps.bookings.items, 0..) |b, i| {
        if (i != 0) w.writeByte(',') catch @panic("OOM");
        w.writeByte('{') catch @panic("OOM");
        w.writeAll("\"id\":") catch @panic("OOM");
        jwNum(w, b.id);
        w.writeAll(",\"name\":") catch @panic("OOM");
        jwStr(w, b.name);
        w.writeAll(",\"car\":") catch @panic("OOM");
        jwStr(w, b.car);
        w.writeAll(",\"items\":") catch @panic("OOM");
        jwNum(w, b.items);
        w.writeAll(",\"total\":") catch @panic("OOM");
        jwNum(w, b.total);
        w.writeByte('}') catch @panic("OOM");
    }
    w.writeByte(']') catch @panic("OOM");
    w.writeByte('}') catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

fn stateView(a: std.mem.Allocator, s: *Session) forest.Node {
    // Native <details> accordion — collapsible without any client JS.
    return forest.el(a, .details, .{ .class = "dbg" }, .{
        forest.el(a, .summary, .{ .class = "dbg-sum" }, "Состояние сервера (JSON)"),
        forest.el(a, .pre, .{ .id = "state-json", .class = "state-json", .text = stateJson(a, s) }, .{}),
    });
}

fn buildView(a: std.mem.Allocator, s: *Session) []const forest.Node {
    const nodes = a.alloc(forest.Node, 7) catch @panic("OOM");
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
    nodes[6] = stateView(a, s);
    return nodes;
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
