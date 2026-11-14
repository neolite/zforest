//! "/" — the whole zcar UI: vehicle cascade, service catalogue,
//! upsells, booking summary + form, bookings list, and the JSON state
//! dump. Single-route app — this page is the entire `<main>` body.
//!
//! Domain helpers (cart math, discounts, suggestions) live in
//! `../app.zig` — the view reads them through `app.*`.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");
const CarData = @import("../car_data.zig");

const Session = app.Session;
const Discount = app.Discount;
const Suggestion = app.Suggestion;
const Booking = app.Booking;

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    return forest.fragment(a, .{
        forest.fragment(a, .{
            forest.el(a, .h1, .{}, .{
                forest.text("zcar "),
                forest.el(a, .span, .{}, "запись в сервис"),
            }),
            forest.el(a, .p, .{ .class = "sub" }, "Автомобиль → услуги → комбо-скидки. Всё считается на сервере."),
        }),
        vehicleView(a, s),
        servicesView(a, s),
        upsellsView(a, s),
        summaryView(a, s),
        bookingsView(a, s),
        stateView(a, s),
    });
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

    if (app.vehicleComplete(s)) {
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
    const on = app.hasSvc(s, sv.id);
    var kids = std.ArrayListUnmanaged(forest.Node).empty;
    kids.append(a, forest.el(a, .span, .{ .class = "svc-name" }, sv.name)) catch @panic("OOM");
    kids.append(a, forest.el(a, .span, .{ .class = "svc-meta" }, forest.fragment(a, .{
        forest.el(a, .span, .{ .class = "svc-price" }, app.fmtPrice(a, sv.price)),
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
    const in_cart = app.hasSvc(ctx.s, sug.id);
    return forest.el(a, .div, .{
        .id = std.fmt.allocPrint(a, "upsell-{d}", .{sv.id}) catch @panic("OOM"),
        .class = "upsell",
    }, .{
        forest.el(a, .div, .{ .class = "upsell-txt" }, .{
            forest.el(a, .span, .{ .lid = "nm", .class = "upsell-name", .text = sv.name }, .{}),
            forest.el(a, .span, .{ .lid = "why", .class = "upsell-why", .text = sug.reason }, .{}),
        }),
        forest.el(a, .span, .{ .lid = "pr", .class = "upsell-price", .text = app.fmtPrice(a, sv.price) }, .{}),
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

fn idxSlice(a: std.mem.Allocator, n: usize) []usize {
    const ids = a.alloc(usize, n) catch @panic("OOM");
    for (ids, 0..) |*p, i| p.* = i;
    return ids;
}

fn upsellsView(a: std.mem.Allocator, s: *Session) forest.Node {
    const sugs = app.suggestions(s, a);
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
        std.fmt.allocPrint(a, "{s} ₽", .{app.fmtPrice(a, sv.price)}) catch @panic("OOM"),
        "sum-line",
    );
}

fn summaryView(a: std.mem.Allocator, s: *Session) forest.Node {
    const ids = app.cartIds(s, a);
    return forest.when(a, .{ .id = "w-sum" }, ids.len > 0, blk: {
        var kids = std.ArrayListUnmanaged(forest.Node).empty;
        kids.append(a, forest.el(a, .h2, .{ .class = "sec" }, "3. Заказ")) catch @panic("OOM");
        kids.append(a, forest.el(a, .div, .{ .class = "sum-list", .id = "cart" }, forest.eachOf(a, ids, SumCtx{ .s = s, .ids = ids }, sumOrNull))) catch @panic("OOM");
        const dbuf = a.alloc(Discount, 3) catch @panic("OOM");
        for (app.discounts(s, dbuf), 0..) |d, i| {
            kids.append(a, sumLine(
                a,
                std.fmt.allocPrint(a, "disc-{d}", .{i}) catch @panic("OOM"),
                d.label,
                std.fmt.allocPrint(a, "−{s} ₽", .{app.fmtPrice(a, d.amount)}) catch @panic("OOM"),
                "sum-line disc",
            )) catch @panic("OOM");
        }
        kids.append(a, forest.el(a, .div, .{ .id = "sum-total", .class = "sum-total" }, .{
            forest.el(a, .span, .{ .lid = "lbl", .text = "Итого" }, .{}),
            forest.el(a, .span, .{ .lid = "val", .text = std.fmt.allocPrint(a, "{s} ₽", .{app.fmtPrice(a, app.total(s))}) catch @panic("OOM") }, .{}),
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
            b.phone, b.items, app.fmtPrice(a, b.total),
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
    const ids = app.cartIds(s, a);
    for (ids, 0..) |id, i| {
        if (i != 0) w.writeByte(',') catch @panic("OOM");
        jwNum(w, id);
    }
    w.writeByte(']') catch @panic("OOM");
    w.writeAll(",\"subtotal\":") catch @panic("OOM");
    jwNum(w, app.subtotal(s));
    w.writeAll(",\"discounts\":[") catch @panic("OOM");
    var dbuf: [3]Discount = undefined;
    for (app.discounts(s, &dbuf), 0..) |d, i| {
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
    jwNum(w, app.total(s));
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
