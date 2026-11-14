//! "/" — the whole todo UI: static chrome (h1 + add form), the
//! `w-empty`/`w-flt`/`w-foot` conditional anchors, filter buttons, the
//! bound `count` footer, and the keyed todo list. Single-route app —
//! this page is the entire `<main>` body.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");

const Session = app.Session;
const Todo = app.Todo;
const Filter = app.Filter;

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    return forest.fragment(a, .{
        headerView(a),
        emptyView(a, s),
        filtersView(a, s),
        listView(a, s),
        footerView(a, s),
    });
}

// ── view components ─────────────────────────────────────────────
// A component is a plain fn returning a forest.Node. `view` composes
// them; `forest.fragment` groups several roots into one Node without
// emitting wrapper markup.

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
                .maxlength = app.max_title_len,
                .autofocus = true,
            }, .{}),
            forest.el(a, .button, .{ .type = "submit" }, "Add"),
        }),
    });
}

/// The empty-state note: mounted via the `w-empty` anchor only while the
/// list has no todos at all — real mount/unmount instead of `hidden`.
fn emptyView(a: std.mem.Allocator, s: *Session) forest.Node {
    return forest.when(a, .{ .id = "w-empty" }, s.deps.todos.items.len == 0, forest.el(a, .p, .{ .id = "empty-msg" }, "Nothing yet"));
}

/// The filter button row: mounted via the `w-flt` anchor while the list
/// is non-empty. The div itself is static branch markup; the `flt-*`
/// buttons keep absolute ids so `data-active` still diffs in place.
fn filtersView(a: std.mem.Allocator, s: *Session) forest.Node {
    var btns: std.ArrayListUnmanaged(forest.Node) = .empty;
    inline for (.{ Filter.all, Filter.active, Filter.completed }) |f| {
        btns.append(a, forest.el(a, .button, .{
            .id = comptime "flt-" ++ f.name(),
            .@"data-active" = if (s.deps.filter == f) "1" else null,
            .on = .{ .click = "filter" },
            .arg = f.name(),
        }, f.name())) catch @panic("OOM");
    }
    return forest.when(a, .{ .id = "w-flt" }, s.deps.todos.items.len != 0, forest.el(a, .div, .{ .class = "filters" }, btns.toOwnedSlice(a) catch @panic("OOM")));
}

/// The keyed todo list — `eachOf` renders every todo through rowOrNull.
fn listView(a: std.mem.Allocator, s: *Session) forest.Node {
    return forest.el(a, .ul, .{ .id = "list" }, forest.eachOf(a, s.deps.todos.items, s, rowOrNull));
}

/// The footer: mounted via the `w-foot` anchor while the list is
/// non-empty. `count` keeps its absolute id inside the branch and stays
/// bound via `computed` — `countText` maps the `remaining` store.
fn footerView(a: std.mem.Allocator, s: *Session) forest.Node {
    return forest.when(a, .{ .id = "w-foot" }, s.deps.todos.items.len != 0, forest.el(a, .footer, .{}, .{
        forest.el(a, .span, .{ .id = "count", .text = forest.computed(s.deps.remaining, app.countText) }, .{}),
    }));
}

/// Idle row branch: the title, which enters edit mode on double-click.
fn viewBranch(a: std.mem.Allocator, t: Todo, arg: []const u8) forest.Node {
    return forest.el(a, .span, .{
        .class = "title",
        .on = .{ .dblclick = "edit" },
        .arg = arg,
    }, t.title);
}

/// Editing row branch: an inline form swapped in through the `row-N/we`
/// anchor. The hidden `id` input carries the todo id — form submits
/// serialize named fields only, never `data-arg`.
fn editBranch(a: std.mem.Allocator, draft: []const u8, arg: []const u8) forest.Node {
    return forest.el(a, .form, .{
        .class = "edit-form",
        .autocomplete = "off",
        .on = .{ .submit = "edit_save" },
    }, .{
        forest.el(a, .input, .{ .type = "hidden", .name = "id", .value = arg }, .{}),
        forest.el(a, .input, .{
            .name = "text",
            .value = draft,
            .maxlength = app.max_title_len,
            .autofocus = true,
        }, .{}),
        forest.el(a, .button, .{ .type = "submit" }, "Save"),
        forest.el(a, .button, .{
            .type = "button",
            .class = "edit-cancel",
            .on = .{ .click = "edit_cancel" },
            .arg = arg,
        }, "×"),
    });
}

fn buildRow(a: std.mem.Allocator, s: *Session, t: Todo) forest.Node {
    const ui = app.uiEntry(s, t.id);
    // The todo id formats once per row and is shared by every `data-arg`
    // / hidden `value` binding — previously each attr ran its own `{d}`.
    var idbuf: [24]u8 = undefined;
    const arg = a.dupe(u8, std.fmt.bufPrint(&idbuf, "{d}", .{t.id}) catch unreachable) catch @panic("OOM");
    const base = if (t.done) "todo done" else "todo";
    const suffix: []const u8 = if (ui != null) " editing" else "";
    const class = a.alloc(u8, base.len + suffix.len) catch @panic("OOM");
    @memcpy(class[0..base.len], base);
    @memcpy(class[base.len..], suffix);
    return forest.el(a, .li, .{
        .id = std.fmt.allocPrint(a, "row-{d}", .{t.id}) catch @panic("OOM"),
        .class = class,
    }, .{
        forest.el(a, .input, .{
            .lid = "cb",
            .type = "checkbox",
            .checked = t.done,
            .on = .{ .change = "set_checked" },
            .arg = arg,
        }, .{}),
        // One `when` op swaps the whole title/form branch; inside a
        // branch the diff recurses into bound descendants as usual.
        forest.variant(a, .{ .lid = "we" }, if (ui != null) "edit" else "view", if (ui) |u| editBranch(a, u.draft, arg) else viewBranch(a, t, arg)),
        forest.el(a, .button, .{
            .class = "del",
            .@"aria-label" = "delete",
            .on = .{ .click = "delete" },
            .arg = arg,
        }, "×"),
    });
}

/// `eachOf` render fn: the active filter hides rows by returning null;
/// every survivor is an element carrying `.id`.
fn rowOrNull(a: std.mem.Allocator, s: *Session, t: Todo) ?forest.Node {
    if (!app.visible(s, t)) return null;
    return buildRow(a, s, t);
}
