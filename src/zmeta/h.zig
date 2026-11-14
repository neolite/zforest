//! h — a fluent HTML builder producing `forest.view` nodes: JSX-feel
//! ergonomics without leaving Zig/comptime safety.
//!
//! Entry points are per-tag fns capturing the render arena:
//!
//!   const h = zmeta.h;
//!   return h.div(a)
//!       .id("row-3")
//!       .class("todo")
//!       .class("done")        // .class APPENDS: class="todo done"
//!       .on(.click, "delete") // → data-on-click="delete"
//!       .arg(3)               // → data-arg="3"
//!       .children(.{
//!           h.span(a).class("title").child(t.title),
//!           h.button(a).child("×"),
//!       })
//!       .node();              // terminal → forest.Node
//!
//! Conventions:
//!   - Builders are VALUES, not nodes: every method returns a new
//!     builder; `.node()` is the only way out (children accept builders
//!     directly and call `.node()` for you). Always chain or reassign —
//!     a discarded intermediate builder keeps sharing the arena lists.
//!   - `h.<tag>(a)` captures the per-render arena `a`; every string the
//!     builder formats (ints, joined classes) is allocated there — same
//!     lifetime rules as `forest.el`.
//!   - `.id`/`.lid` are the bound-DOM-id fields, resolved eagerly like
//!     `el`'s `.id`. `.text(v)` is the bound textContent and accepts
//!     everything forest's `.text` does: strings, ints, optionals,
//!     `*T.get()` store pointers, `computed(...)` bindings, `Value`s.
//!     Store pointers resolve LAZILY at render/diff/seed time through
//!     `forest.bind` — live hooks intact, so h-built `*Store.get()`
//!     bindings self-update under `bindTree` exactly like `el` ones.
//!   - `.class(s)` APPENDS (space-joined) rather than sets, so utility
//!     classes compose across calls; a null/absent operand is a no-op.
//!     Mixed string/bound operands merge into one lazy bound that
//!     joins at render time.
//!   - `.on(ev, action)` takes an `Event` member — the same six events
//!     forest whitelists (click/dblclick/change/input/submit/keydown),
//!     verified against a mirrored list at comptime; anything else
//!     fails to compile. Emits `data-on-<ev>` exactly like `el`'s
//!     `.on = .{ .<ev> = ... }`.
//!   - `.attr(name, value)` is the escape hatch `forest.el` can't
//!     offer (its attr names are comptime field names): any runtime
//!     name, same value rules (null optional omits, bool is presence,
//!     ints `{d}`, strings escaped, stores/`computed` lazy). Prefer the
//!     named methods — `.attr("id", ...)` emits an UNBOUND id
//!     attribute; use `.id()` for bound ids.
//!   - Children: `.child(x)` / `.children(x)` accept a `forest.Node`,
//!     a string (auto text node, HTML-escaped), another builder, a
//!     `Children` value (`each`/`eachOf` result), a `[]const Node`, a
//!     `[N]Node`, or a comptime tuple mixing any of those.
//!     `each`/`eachOf` keyed lists must be the element's ONLY child
//!     source (a forest rule — enforced with a panic).
//!   - `h.island(a, .{ .id = "…" }, children)` — per-leaf island
//!     passthrough to `forest.island`: a transparent subtree that
//!     `bindIslands` (the session skeleton's render) turns into
//!     store-bound leaf ops while `diff` skips it. Requires `.id`/`.lid`;
//!     all dynamic content inside must be store-bound.
//!   - `h.f(a, "fmt {d}", .{x})` — `allocPrint` shorthand for the ids
//!     and labels every view formats; arena-allocated like everything
//!     else the builder produces.
//!   - Void tags (`<input>`, `<br>`, …) assert they got no children,
//!     matching `el`.
//!
//! Naming note: entry fns `a`/`p` are file-scope decls, so inside this
//! file every allocator is spelled `alloc` (Zig rejects shadowing).
const std = @import("std");
const view = @import("forest").view;

pub const Node = view.Node;
pub const Tag = view.Tag;
pub const Children = view.Children;
pub const Value = view.Value;
pub const Bound = view.Bound;
pub const Attr = view.Attr;
pub const Element = view.Element;

/// forest passthroughs — everything a view needs stays under `h`.
pub const text = view.text;
pub const raw = view.raw;
pub const fragment = view.fragment;
pub const each = view.each;
pub const eachOf = view.eachOf;
pub const variant = view.variant;
pub const when = view.when;
pub const island = view.island;
pub const computed = view.computed;
pub const writeHtml = view.writeHtml;

/// `allocPrint` shorthand — `h.f(a, "item-{d}", .{id})` instead of
/// `std.fmt.allocPrint(a, "item-{d}", .{id}) catch @panic("OOM")`.
pub fn f(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, fmt, args) catch @panic("OOM");
}

/// DOM event types allowed in `.on` — mirrors forest.view's comptime
/// whitelist; the comptime block below keeps the two lists in sync.
pub const Event = enum {
    click,
    dblclick,
    change,
    input,
    submit,
    keydown,
};

/// forest's `.on` whitelist, mirrored — `assertDomEvent` is private, so
/// the sync check below is the only guard against drift.
const dom_events = .{ "click", "dblclick", "change", "input", "submit", "keydown" };

comptime {
    for (@typeInfo(Event).@"enum".field_names) |fname| {
        var ok = false;
        for (dom_events) |allowed| {
            if (std.mem.eql(u8, fname, allowed)) ok = true;
        }
        if (!ok) @compileError("h.Event." ++ fname ++ " is not in forest's .on whitelist");
    }
    for (dom_events) |allowed| {
        var ok = false;
        for (@typeInfo(Event).@"enum".field_names) |fname| {
            if (std.mem.eql(u8, fname, allowed)) ok = true;
        }
        if (!ok) @compileError("forest .on event '" ++ allowed ++ "' missing from h.Event");
    }
}

/// A fluent builder for one element. Generic over the comptime `Tag`;
/// construct via the `h.<tag>(a)` entry fns below. See the file header
/// for the chaining conventions.
pub fn Builder(comptime tag: Tag) type {
    return struct {
        const Self = @This();

        /// Marker decl — `.child()`/`.children()` duck-type builders on it.
        pub const h_builder = true;

        /// The per-render arena every builder allocation lands in.
        a: std.mem.Allocator,
        attrs: std.ArrayListUnmanaged(Attr) = .empty,
        kids: std.ArrayListUnmanaged(Node) = .empty,
        /// Set INSTEAD of `kids` when the sole child source is a keyed
        /// list (`each`/`eachOf`) — forest requires keyed children to be
        /// the element's only children.
        keyed: ?[]const Node = null,
        id_v: ?[]const u8 = null,
        lid_v: ?[]const u8 = null,
        text_v: ?Value = null,

        /// Terminal: produce the `forest.Node`. The builder's lists are
        /// arena-owned; don't keep chaining a builder after this (or
        /// after passing it to `.child()`).
        pub fn node(self: Self) Node {
            var e: Element = .{ .tag = tag };
            e.id = self.id_v;
            e.lid = self.lid_v;
            e.text = self.text_v;
            e.attrs = self.attrs.items;
            if (comptime tagIsVoid(tag)) {
                std.debug.assert(self.kids.items.len == 0 and self.keyed == null);
            }
            e.children = if (self.keyed) |ks| .{ .keyed = ks } else .{ .nodes = self.kids.items };
            return .{ .element = e };
        }

        /// Bound DOM id — resolved eagerly, exactly like `el`'s `.id`
        /// (strings, ints, optionals, `*T.get()` stores, `computed`).
        pub fn id(self: Self, v: anytype) Self {
            var s = self;
            s.id_v = resolveStr(s.a, v);
            return s;
        }

        /// Local id composed against the nearest bound ancestor
        /// (`{parent}/{lid}`), like `el`'s `.lid`.
        pub fn lid(self: Self, v: anytype) Self {
            var s = self;
            s.lid_v = resolveStr(s.a, v);
            return s;
        }

        /// Append a class name — SPACE-JOINED with any previous
        /// `.class()` calls (append semantics, not set). A null operand
        /// is a no-op; bound operands merge lazily.
        pub fn class(self: Self, v: anytype) Self {
            var s = self;
            const nv = valueFor(s.a, v) orelse return s;
            var found: ?usize = null;
            for (s.attrs.items, 0..) |at, i| {
                if (std.mem.eql(u8, at.name, "class")) {
                    found = i;
                    break;
                }
            }
            if (found) |i| {
                s.attrs.items[i] = .{
                    .name = "class",
                    .value = mergeClass(s.a, s.attrs.items[i].value, nv),
                    .presence = false,
                };
                return s;
            }
            s.attrs.append(s.a, .{
                .name = "class",
                .value = nv,
                .presence = comptime presenceOf(@TypeOf(v)),
            }) catch @panic("OOM");
            return s;
        }

        /// Bound textContent — replaces children at render, accepts
        /// every operand forest's `.text` does (see file header).
        pub fn text(self: Self, v: anytype) Self {
            var s = self;
            s.text_v = valueFor(s.a, v);
            return s;
        }

        /// DOM event binding → `data-on-<ev>="action"`. `ev` is
        /// comptime-checked against forest's whitelist via `Event`.
        pub fn on(self: Self, comptime ev: Event, action: anytype) Self {
            var s = self;
            s.attrs.append(s.a, makeAttr(s.a, "data-on-" ++ @tagName(ev), action)) catch @panic("OOM");
            return s;
        }

        /// Action payload → `data-arg` (string or int), like `el`'s
        /// `.arg`.
        pub fn arg(self: Self, v: anytype) Self {
            return self.attr("data-arg", v);
        }

        /// Escape hatch: any attribute by runtime name, same value
        /// rules as `el`'s attr fields (null optional omits, bool is
        /// presence, ints `{d}`, strings escaped, stores/`computed`
        /// lazy). `forest.el` can't do this — its names are comptime
        /// field names.
        pub fn attr(self: Self, attr_name: []const u8, v: anytype) Self {
            var s = self;
            s.attrs.append(s.a, makeAttr(s.a, attr_name, v)) catch @panic("OOM");
            return s;
        }

        /// Single child — see the file header for accepted types.
        pub fn child(self: Self, x: anytype) Self {
            var s = self;
            s.add(x);
            return s;
        }

        /// Children — a single child, a comptime tuple `.{a, b, c}`,
        /// a `[]const Node`, or an `each`/`eachOf` `Children` value.
        pub fn children(self: Self, x: anytype) Self {
            var s = self;
            s.add(x);
            return s;
        }

        // ── named attribute conveniences ──────────────────────────

        pub fn href(self: Self, v: anytype) Self {
            return self.attr("href", v);
        }

        pub fn @"type"(self: Self, v: anytype) Self {
            return self.attr("type", v);
        }

        pub fn value(self: Self, v: anytype) Self {
            return self.attr("value", v);
        }

        pub fn name(self: Self, v: anytype) Self {
            return self.attr("name", v);
        }

        pub fn placeholder(self: Self, v: anytype) Self {
            return self.attr("placeholder", v);
        }

        /// `for` is a Zig keyword — the method is `for_`.
        pub fn for_(self: Self, v: anytype) Self {
            return self.attr("for", v);
        }

        /// Boolean attribute → bare-name presence (`disabled`,
        /// `checked`, …); false/null resolves to absent, like `el`.
        pub fn disabled(self: Self, v: anytype) Self {
            return self.attr("disabled", v);
        }

        pub fn checked(self: Self, v: anytype) Self {
            return self.attr("checked", v);
        }

        // ── internals ─────────────────────────────────────────────

        fn push(self: *Self, n: Node) void {
            if (self.keyed != null) @panic("h: each/eachOf children must be the element's only child source");
            self.kids.append(self.a, n) catch @panic("OOM");
        }

        fn pushChildren(self: *Self, c: Children) void {
            switch (c) {
                .nodes => |ns| for (ns) |n| self.push(n),
                .keyed => |ks| {
                    if (self.kids.items.len != 0 or self.keyed != null)
                        @panic("h: each/eachOf children must be the element's only child source");
                    self.keyed = ks;
                },
            }
        }

        /// Normalize one child operand — mirrors `forest`'s
        /// `normChildren`, extended to builders and mixed tuples.
        fn add(self: *Self, x: anytype) void {
            const T = @TypeOf(x);
            if (T == Node) return self.push(x);
            if (T == Children) return self.pushChildren(x);
            if (comptime isBuilder(T)) return self.push(x.node());
            switch (@typeInfo(T)) {
                .pointer => |pi| {
                    if (pi.size == .slice and pi.child == Node) {
                        for (x) |n| self.push(n);
                        return;
                    }
                    if (pi.size == .one and @typeInfo(pi.child) == .array and
                        @typeInfo(pi.child).array.child == Node)
                    {
                        for (x.*) |n| self.push(n);
                        return;
                    }
                    const s: []const u8 = x; // string slice/literal → text
                    self.push(.{ .text = s });
                    return;
                },
                .array => |info| {
                    if (info.child == Node) {
                        for (x) |n| self.push(n);
                        return;
                    }
                    @compileError("h children arrays must be []Node");
                },
                .@"struct" => |info| {
                    if (!info.is_tuple) @compileError("h child must be a Node, builder, text, or tuple");
                    inline for (info.field_names) |fname| self.add(@field(x, fname));
                    return;
                },
                else => @compileError("unsupported h child type: " ++ @typeName(T)),
            }
        }
    };
}

// ── entry points — one per forest Tag member ────────────────────

pub fn a(alloc: std.mem.Allocator) Builder(.a) {
    return .{ .a = alloc };
}
pub fn area(alloc: std.mem.Allocator) Builder(.area) {
    return .{ .a = alloc };
}
pub fn base(alloc: std.mem.Allocator) Builder(.base) {
    return .{ .a = alloc };
}
pub fn body(alloc: std.mem.Allocator) Builder(.body) {
    return .{ .a = alloc };
}
pub fn br(alloc: std.mem.Allocator) Builder(.br) {
    return .{ .a = alloc };
}
pub fn button(alloc: std.mem.Allocator) Builder(.button) {
    return .{ .a = alloc };
}
pub fn col(alloc: std.mem.Allocator) Builder(.col) {
    return .{ .a = alloc };
}
pub fn details(alloc: std.mem.Allocator) Builder(.details) {
    return .{ .a = alloc };
}
pub fn div(alloc: std.mem.Allocator) Builder(.div) {
    return .{ .a = alloc };
}
pub fn em(alloc: std.mem.Allocator) Builder(.em) {
    return .{ .a = alloc };
}
pub fn embed(alloc: std.mem.Allocator) Builder(.embed) {
    return .{ .a = alloc };
}
pub fn footer(alloc: std.mem.Allocator) Builder(.footer) {
    return .{ .a = alloc };
}
pub fn form(alloc: std.mem.Allocator) Builder(.form) {
    return .{ .a = alloc };
}
pub fn h1(alloc: std.mem.Allocator) Builder(.h1) {
    return .{ .a = alloc };
}
pub fn h2(alloc: std.mem.Allocator) Builder(.h2) {
    return .{ .a = alloc };
}
pub fn h3(alloc: std.mem.Allocator) Builder(.h3) {
    return .{ .a = alloc };
}
pub fn head(alloc: std.mem.Allocator) Builder(.head) {
    return .{ .a = alloc };
}
pub fn hr(alloc: std.mem.Allocator) Builder(.hr) {
    return .{ .a = alloc };
}
pub fn html(alloc: std.mem.Allocator) Builder(.html) {
    return .{ .a = alloc };
}
pub fn img(alloc: std.mem.Allocator) Builder(.img) {
    return .{ .a = alloc };
}
pub fn input(alloc: std.mem.Allocator) Builder(.input) {
    return .{ .a = alloc };
}
pub fn label(alloc: std.mem.Allocator) Builder(.label) {
    return .{ .a = alloc };
}
pub fn li(alloc: std.mem.Allocator) Builder(.li) {
    return .{ .a = alloc };
}
pub fn link(alloc: std.mem.Allocator) Builder(.link) {
    return .{ .a = alloc };
}
pub fn main(alloc: std.mem.Allocator) Builder(.main) {
    return .{ .a = alloc };
}
pub fn meta(alloc: std.mem.Allocator) Builder(.meta) {
    return .{ .a = alloc };
}
pub fn option(alloc: std.mem.Allocator) Builder(.option) {
    return .{ .a = alloc };
}
pub fn p(alloc: std.mem.Allocator) Builder(.p) {
    return .{ .a = alloc };
}
pub fn pre(alloc: std.mem.Allocator) Builder(.pre) {
    return .{ .a = alloc };
}
pub fn polyline(alloc: std.mem.Allocator) Builder(.polyline) {
    return .{ .a = alloc };
}
pub fn script(alloc: std.mem.Allocator) Builder(.script) {
    return .{ .a = alloc };
}
pub fn section(alloc: std.mem.Allocator) Builder(.section) {
    return .{ .a = alloc };
}
pub fn select(alloc: std.mem.Allocator) Builder(.select) {
    return .{ .a = alloc };
}
pub fn source(alloc: std.mem.Allocator) Builder(.source) {
    return .{ .a = alloc };
}
pub fn span(alloc: std.mem.Allocator) Builder(.span) {
    return .{ .a = alloc };
}
pub fn strong(alloc: std.mem.Allocator) Builder(.strong) {
    return .{ .a = alloc };
}
pub fn style(alloc: std.mem.Allocator) Builder(.style) {
    return .{ .a = alloc };
}
pub fn summary(alloc: std.mem.Allocator) Builder(.summary) {
    return .{ .a = alloc };
}
pub fn svg(alloc: std.mem.Allocator) Builder(.svg) {
    return .{ .a = alloc };
}
pub fn table(alloc: std.mem.Allocator) Builder(.table) {
    return .{ .a = alloc };
}
pub fn tbody(alloc: std.mem.Allocator) Builder(.tbody) {
    return .{ .a = alloc };
}
pub fn td(alloc: std.mem.Allocator) Builder(.td) {
    return .{ .a = alloc };
}
pub fn textarea(alloc: std.mem.Allocator) Builder(.textarea) {
    return .{ .a = alloc };
}
pub fn th(alloc: std.mem.Allocator) Builder(.th) {
    return .{ .a = alloc };
}
pub fn thead(alloc: std.mem.Allocator) Builder(.thead) {
    return .{ .a = alloc };
}
pub fn title(alloc: std.mem.Allocator) Builder(.title) {
    return .{ .a = alloc };
}
pub fn tr(alloc: std.mem.Allocator) Builder(.tr) {
    return .{ .a = alloc };
}
pub fn track(alloc: std.mem.Allocator) Builder(.track) {
    return .{ .a = alloc };
}
pub fn ul(alloc: std.mem.Allocator) Builder(.ul) {
    return .{ .a = alloc };
}
pub fn wbr(alloc: std.mem.Allocator) Builder(.wbr) {
    return .{ .a = alloc };
}

// ── internals — ports of forest.view's private helpers ──────────
//
// `forest.el` keeps most of its operand pipeline private
// (`resolveValue`, `valueFor`, `attrOf`, `normChildren`,
// `presenceOf`, `assertDomEvent`). h builds `Element`s directly, so
// it mirrors those helpers here — same semantics, same operand set.
// Store operands go through `view.bind` (forest's `bindGet`) so
// `Bound.live` hooks survive; merged class pairs still carry
// `.live = null` — a lazy join has no single store to subscribe.

fn isGetPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pi| pi.size == .one and switch (@typeInfo(pi.child)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(pi.child, "get"),
            else => false,
        },
        else => false,
    };
}

fn unwrapOpt(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| unwrapOpt(o.child),
        else => T,
    };
}

/// Whether `*T`'s `.get()` returns a bool — presence attributes.
fn getReturnsBool(comptime S: type) bool {
    if (!isGetPtr(S)) return false;
    const r = switch (@typeInfo(@TypeOf(std.meta.Child(S).get))) {
        .@"fn" => |fninfo| fninfo.return_type orelse return false,
        else => return false,
    };
    return unwrapOpt(r) == bool;
}

/// Whether a plain (non-Bound) operand resolves to a presence attr.
fn presenceOf(comptime T: type) bool {
    const U = unwrapOpt(T);
    return switch (@typeInfo(U)) {
        .bool => true,
        .pointer => getReturnsBool(U),
        else => false,
    };
}

/// Port of forest's private `resolveValue`: normalize any operand to
/// its rendered string (null = absent). Used for `.id`/`.lid` (eager,
/// like `el`) and inside the lazy `Bound` thunks.
fn resolveStr(alloc: std.mem.Allocator, v: anytype) ?[]const u8 {
    const T = @TypeOf(v);
    if (T == Bound) return v.call(alloc, v.ctx);
    if (T == Value) return switch (v) {
        .str => |s| s,
        .bound => |b| b.call(alloc, b.ctx),
    };
    switch (@typeInfo(T)) {
        .null => return null,
        .optional => return if (v) |inner| resolveStr(alloc, inner) else null,
        .bool => return if (v) "" else null,
        .int, .comptime_int => return std.fmt.allocPrint(alloc, "{d}", .{v}) catch @panic("OOM"),
        .pointer => {
            if (comptime isGetPtr(T)) return resolveStr(alloc, v.get());
            return v;
        },
        else => @compileError("unsupported h value type: " ++ @typeName(T)),
    }
}

/// Port of forest's private `valueFor`: wrap an attr/`.text` operand
/// for deferred resolution — `Bound` passes through, `*T.get()`
/// pointers become lazy `Bound` thunks, plain values render eagerly.
fn valueFor(alloc: std.mem.Allocator, v: anytype) ?Value {
    const T = @TypeOf(v);
    if (T == Bound) return .{ .bound = v };
    if (T == Value) return v;
    switch (@typeInfo(T)) {
        .null => return null,
        .optional => return if (v) |inner| valueFor(alloc, inner) else null,
        .pointer => {
            if (comptime isGetPtr(T)) return .{ .bound = view.bind(v) };
            return .{ .str = v };
        },
        else => {
            const s = resolveStr(alloc, v) orelse return null;
            return .{ .str = s };
        },
    }
}

/// Store operands go through `view.bind` — forest's own `bindGet`
/// with `Bound.live` hooks intact, so h-built bindings self-update
/// under `bindTree` exactly like `forest.el` ones.
/// Port of forest's private `attrOf`: one `Attr` from a name + operand.
fn makeAttr(alloc: std.mem.Allocator, name: []const u8, v: anytype) Attr {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .optional => return if (v) |inner| makeAttr(alloc, name, inner) else .{ .name = name },
        else => {},
    }
    if (T == Bound) return .{ .name = name, .value = .{ .bound = v }, .presence = v.presence };
    if (T == Value) return switch (v) {
        .bound => |b| .{ .name = name, .value = v, .presence = b.presence },
        .str => |s| .{ .name = name, .value = .{ .str = s } },
    };
    return .{
        .name = name,
        .value = valueFor(alloc, v),
        .presence = comptime presenceOf(T),
    };
}

/// Whether `T` is an h `Builder` instantiation — `.child()` accepts
/// builders of any tag.
fn isBuilder(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| !info.is_tuple and @hasDecl(T, "h_builder"),
        else => false,
    };
}

/// Void elements emit no closing tag and may not have children —
/// mirrors the private `Tag.isVoid` (kept private by forest).
fn tagIsVoid(comptime t: Tag) bool {
    return switch (t) {
        .area, .base, .br, .col, .embed, .hr, .img, .input, .link, .meta, .source, .track, .wbr => true,
        else => false,
    };
}

// ── .class append-merge ─────────────────────────────────────────

const ClassPair = struct {
    first: Value,
    second: Value,
};

fn operandStr(alloc: std.mem.Allocator, v: Value) ?[]const u8 {
    return switch (v) {
        .str => |s| s,
        .bound => |b| b.call(alloc, b.ctx),
    };
}

/// Lazy join for mixed string/bound class operands — resolves both
/// sides at render time and space-joins the non-null ones.
fn classCall(alloc: std.mem.Allocator, ctx: *const anyopaque) ?[]const u8 {
    const pair: *const ClassPair = @ptrCast(@alignCast(ctx));
    const x = operandStr(alloc, pair.first);
    const y = operandStr(alloc, pair.second);
    if (x == null) return y;
    if (y == null) return x;
    return std.fmt.allocPrint(alloc, "{s} {s}", .{ x.?, y.? }) catch @panic("OOM");
}

/// Merge a new class operand into the existing class `Value`: two
/// strings concat eagerly; anything involving a bound becomes one
/// lazy `Bound` that joins at render time.
fn mergeClass(alloc: std.mem.Allocator, old: ?Value, new: Value) Value {
    const o = old orelse return new;
    switch (o) {
        .str => |os| switch (new) {
            .str => |ns| return .{ .str = std.fmt.allocPrint(alloc, "{s} {s}", .{ os, ns }) catch @panic("OOM") },
            .bound => {},
        },
        .bound => {},
    }
    const pair = alloc.create(ClassPair) catch @panic("OOM");
    pair.* = .{ .first = o, .second = new };
    return .{ .bound = .{
        .ctx = pair,
        .call = &classCall,
        .presence = false,
        .live = null,
    } };
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

fn renderStr(alloc: std.mem.Allocator, nodes: []const Node) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    writeHtml(alloc, nodes, &aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// Duck-typed fake store — same contract forest's tests use: a
/// `*T.get()` is all the binding pipeline requires.
fn FakeStore(comptime T: type) type {
    return struct {
        v: T,
        pub fn get(self: *const @This()) T {
            return self.v;
        }
    };
}

test "h builder SSR matches the forest.el equivalent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const via_el = view.el(alloc, .div, .{ .id = "d", .class = "x", .@"data-n" = 3 }, .{
        view.el(alloc, .span, .{ .class = "t" }, "hi"),
        view.text("!"),
    });
    const via_h = div(alloc)
        .id("d")
        .class("x")
        .attr("data-n", 3)
        .children(.{
            span(alloc).class("t").child("hi"),
            "!",
        })
        .node();
    try std.testing.expectEqualStrings(
        renderStr(alloc, &.{via_el}),
        renderStr(alloc, &.{via_h}),
    );
    try std.testing.expectEqualStrings(
        "<div id=\"d\" class=\"x\" data-n=\"3\"><span class=\"t\">hi</span>!</div>",
        renderStr(alloc, &.{via_h}),
    );
}

test "h .text and attrs bind *T.get() stores lazily" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var n = FakeStore(usize){ .v = 3 };
    var flag = FakeStore(bool){ .v = true };

    const v = span(alloc).id("c").text(&n).node();
    try std.testing.expectEqualStrings("<span id=\"c\">3</span>", renderStr(alloc, &.{v}));

    const d = div(alloc).id("d").attr("data-n", &n).attr("hidden", &flag).node();
    try std.testing.expectEqualStrings(
        "<div id=\"d\" data-n=\"3\" hidden></div>",
        renderStr(alloc, &.{d}),
    );

    // Live binding: mutating between renders resolves the new value.
    n.v = 7;
    flag.v = false;
    try std.testing.expectEqualStrings("<span id=\"c\">7</span>", renderStr(alloc, &.{v}));
    try std.testing.expectEqualStrings(
        "<div id=\"d\" data-n=\"7\"></div>",
        renderStr(alloc, &.{d}),
    );
}

test "h computed() bindings stay lazy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var remaining = FakeStore(usize){ .v = 2 };
    const fmt = struct {
        fn count(alloc2: std.mem.Allocator, rem: usize) []const u8 {
            return std.fmt.allocPrint(alloc2, "{d} item{s} left", .{ rem, if (rem == 1) "" else "s" }) catch @panic("OOM");
        }
    }.count;

    const v = span(alloc).id("count").text(computed(&remaining, fmt)).node();
    try std.testing.expectEqualStrings(
        "<span id=\"count\">2 items left</span>",
        renderStr(alloc, &.{v}),
    );
    remaining.v = 1; // resolved at render time, not at .text() time
    try std.testing.expectEqualStrings(
        "<span id=\"count\">1 item left</span>",
        renderStr(alloc, &.{v}),
    );
}

test "h .on/.arg emit data-on-* and data-arg; .disabled/.checked are presence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = button(alloc)
        .class("del")
        .on(.click, "delete")
        .arg(@as(u32, 7))
        .child("×")
        .node();
    try std.testing.expectEqualStrings(
        "<button class=\"del\" data-on-click=\"delete\" data-arg=\"7\">×</button>",
        renderStr(alloc, &.{v}),
    );

    const form_v = form(alloc).on(.submit, "add").node();
    try std.testing.expectEqualStrings(
        "<form data-on-submit=\"add\"></form>",
        renderStr(alloc, &.{form_v}),
    );

    const on = input(alloc).id("c").type("checkbox").checked(true).node();
    const off = input(alloc).id("c").type("checkbox").checked(false).node();
    const dis = input(alloc).disabled(true).node();
    try std.testing.expectEqualStrings("<input id=\"c\" type=\"checkbox\" checked>", renderStr(alloc, &.{on}));
    try std.testing.expectEqualStrings("<input id=\"c\" type=\"checkbox\">", renderStr(alloc, &.{off}));
    try std.testing.expectEqualStrings("<input disabled>", renderStr(alloc, &.{dis}));
}

test "h children accept strings (escaped), Nodes, builders, tuples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = div(alloc).children(.{
        "a<&\"'b", // string → escaped text node
        em(alloc).child("i"), // builder → node
        raw("<b>raw</b>"), // forest.Node passthrough
        text(" t"), // forest.text Node
    }).node();
    try std.testing.expectEqualStrings(
        "<div>a&lt;&amp;&quot;&#39;b<em>i</em><b>raw</b> t</div>",
        renderStr(alloc, &.{v}),
    );

    // .child() single-operand forms.
    const w = p(alloc).child(span(alloc).child("x")).node();
    try std.testing.expectEqualStrings("<p><span>x</span></p>", renderStr(alloc, &.{w}));
}

test "h .class appends with space and skips nulls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = div(alloc).class("todo").class("done").class(@as(?[]const u8, null)).node();
    try std.testing.expectEqualStrings("<div class=\"todo done\"></div>", renderStr(alloc, &.{v}));
}

test "h .class merges bound operands lazily" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var done = FakeStore(bool){ .v = true };
    const w = div(alloc).class("a").class(computed(&done, struct {
        fn f(_: std.mem.Allocator, b: bool) []const u8 {
            return if (b) "on" else "off";
        }
    }.f)).node();
    try std.testing.expectEqualStrings("<div class=\"a on\"></div>", renderStr(alloc, &.{w}));
    done.v = false;
    try std.testing.expectEqualStrings("<div class=\"a off\"></div>", renderStr(alloc, &.{w}));
}

test "h eachOf keyed children and .lid compose like forest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Row = struct { id: u32, name: []const u8 };
    const rows = [_]Row{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "b" } };
    const render = struct {
        fn row(alloc2: std.mem.Allocator, ctx: anytype, r: Row) ?Node {
            _ = ctx;
            return li(alloc2)
                .id(std.fmt.allocPrint(alloc2, "r-{d}", .{r.id}) catch @panic("OOM"))
                .child(r.name)
                .node();
        }
    }.row;

    const kids = eachOf(alloc, &rows, .{}, render);
    const v = ul(alloc).id("list").child(kids).node();
    try std.testing.expectEqualStrings(
        "<ul id=\"list\"><li id=\"r-1\">a</li><li id=\"r-2\">b</li></ul>",
        renderStr(alloc, &.{v}),
    );

    // .lid composes against the bound parent id.
    const row = li(alloc).id("row-3").children(.{
        input(alloc).lid("cb").type("checkbox"),
    }).node();
    try std.testing.expectEqualStrings(
        "<li id=\"row-3\"><input id=\"row-3/cb\" type=\"checkbox\"></li>",
        renderStr(alloc, &.{row}),
    );
}

test "h .for_/.href/.value/.name/.placeholder emit plain attrs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = label(alloc).for_("name").child("Name").node();
    try std.testing.expectEqualStrings("<label for=\"name\">Name</label>", renderStr(alloc, &.{v}));

    const i = input(alloc).name("q").value("zig").placeholder("search…").node();
    try std.testing.expectEqualStrings(
        "<input name=\"q\" value=\"zig\" placeholder=\"search…\">",
        renderStr(alloc, &.{i}),
    );

    const l = a(alloc).href("/item/1").child("cog").node();
    try std.testing.expectEqualStrings("<a href=\"/item/1\">cog</a>", renderStr(alloc, &.{l}));
}

test "h store bindings keep Bound.live hooks via view.bind" {
    // Minimal watch-contract store: `get` + `watchCtx` + `unwatch` +
    // `Value` — the same duck-typed contract forest's bindTree uses.
    const LiveStore = struct {
        const Self = @This();
        pub const Value = []const u8;
        pub const Sub = struct { index: u32 };
        const Entry = struct {
            ctx: *anyopaque,
            cb: *const fn (*anyopaque, []const u8) void,
        };
        subs: std.ArrayListUnmanaged(Entry) = .empty,
        v: []const u8 = "hi",
        pub fn get(self: *const Self) []const u8 {
            return self.v;
        }
        pub fn watchCtx(self: *Self, ctx: anytype, comptime cb: *const fn (@TypeOf(ctx), []const u8) void) Sub {
            const CtxT = @TypeOf(ctx);
            const S = struct {
                fn call(ptr: *anyopaque, val: []const u8) void {
                    const c: CtxT = @ptrCast(@alignCast(ptr));
                    cb(c, val);
                }
            };
            const idx = self.subs.items.len;
            self.subs.append(std.testing.allocator, .{ .ctx = @ptrCast(ctx), .cb = &S.call }) catch @panic("OOM");
            return .{ .index = @intCast(idx) };
        }
        pub fn unwatch(self: *Self, sub: Sub) void {
            if (sub.index < self.subs.items.len) self.subs.items[sub.index].cb = undefined;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var st = LiveStore{};
    const b = span(alloc).text(&st).node();
    const el = switch (b) {
        .element => |e| e,
        else => return error.TestUnexpectedResult,
    };
    // .text stored as an Element attr? — locate the bound operand:
    // Element.text is a Value; assert it carries live hooks.
    const tv = el.text orelse return error.TestUnexpectedResult;
    const bound = switch (tv) {
        .bound => |bb| bb,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(bound.live != null);
}
