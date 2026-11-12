const std = @import("std");
const patch_mod = @import("patch.zig");
const dom_mod = @import("dom.zig");

const Dom = dom_mod.Dom;
const PatchLog = patch_mod.PatchLog;
const escapeHtmlInto = patch_mod.escapeHtmlInto;

/// Element tags supported by `el`. The tag name is emitted verbatim, so
/// this enum doubles as the (extendable) tag whitelist.
pub const Tag = enum {
    a,
    area,
    base,
    body,
    br,
    button,
    col,
    div,
    em,
    embed,
    footer,
    form,
    h1,
    h2,
    h3,
    head,
    hr,
    html,
    img,
    input,
    label,
    li,
    link,
    main,
    meta,
    option,
    p,
    script,
    section,
    select,
    source,
    span,
    strong,
    style,
    table,
    tbody,
    td,
    textarea,
    th,
    thead,
    title,
    tr,
    track,
    ul,
    wbr,

    /// Void elements emit no closing tag and may not have children.
    fn isVoid(t: Tag) bool {
        return switch (t) {
            .area, .base, .br, .col, .embed, .hr, .img, .input, .link, .meta, .source, .track, .wbr => true,
            else => false,
        };
    }
};

/// One attribute of an element. `value == null` omits the attribute in SSR
/// and removes it in a diff. `presence` renders the bare name (` checked`)
/// and is set for boolean attributes.
pub const Attr = struct {
    name: []const u8,
    value: ?Value = null,
    presence: bool = false,
};

/// An attribute/`.text` operand held for deferred resolution: either a
/// rendered string, or a `Bound` thunk (`computed`, or a `*T.get()` store
/// pointer) invoked by `resolveValue` inside writeNode/diffNode/seedNode.
pub const Value = union(enum) {
    str: []const u8,
    bound: Bound,
};

/// A deferred binding produced by `computed` (store pointers passed to
/// `.text`/attrs are wrapped automatically). The thunk runs at render/
/// diff/seed time, so its output is always current and lives in the
/// per-render arena.
pub const Bound = struct {
    ctx: *const anyopaque,
    call: *const fn (a: std.mem.Allocator, ctx: *const anyopaque) ?[]const u8,
    /// Resolved bools render as bare-name presence attributes.
    presence: bool = false,
};

/// An element's children: either static nodes or a keyed list (from
/// `each`) in which every child element must carry `.id`. The two never
/// mix — a parent is one or the other.
pub const Children = union(enum) {
    nodes: []const Node,
    keyed: []const Node,
};

pub const Element = struct {
    tag: Tag,
    /// Bound DOM id: makes the node addressable — its attrs and `.text`
    /// are diffed against the Dom's tracked state, and it is the key when
    /// the element sits inside a keyed list.
    id: ?[]const u8 = null,
    /// Local id, resolved against the nearest bound ancestor as
    /// `{parent_id}/{lid}` (e.g. `cb` inside `row-3` → `row-3/cb`).
    lid: ?[]const u8 = null,
    /// Bound textContent — rendered into the element and diffed via
    /// `Dom.setText`. When set it replaces `children` entirely. Accepts
    /// anything `resolveValue` handles: strings, ints, `*T.get()` store
    /// pointers, and `computed` bindings.
    text: ?Value = null,
    attrs: []const Attr = &.{},
    children: Children = .{ .nodes = &.{} },
};

/// A conditional subtree pinned between `<!--z-when:ID-->` /
/// `<!--/z-when:ID-->` comment anchors — the markers are always emitted,
/// so a branch mounts/unmounts at a fixed DOM position without wrapper
/// markup. `key` names the active branch (resolved via `resolveValue` —
/// bound values ok); `null` is the empty branch. `nodes` is the
/// caller-picked markup for the current branch, rendered only while
/// `key` is non-null.
pub const Variant = struct {
    /// Bound anchor id, resolved like `Element.id` — becomes the marker
    /// text (`z-when:ID`), so `--` is not allowed in it.
    id: ?[]const u8 = null,
    /// Local id composed against the nearest bound ancestor's id —
    /// `lid` inside `row-3` anchors `row-3/sw`.
    lid: ?[]const u8 = null,
    key: ?Value = null,
    nodes: []const Node = &.{},
};

/// One node of a view tree. Strings are borrowed — keep them alive until
/// `writeHtml`/`diff` return (a per-render arena covers this naturally).
pub const Node = union(enum) {
    element: Element,
    /// Escaped text content.
    text: []const u8,
    /// Trusted markup — emitted verbatim, never escaped, never diffed.
    raw: []const u8,
    /// A transparent sibling group — emits no markup of its own, so a
    /// component fn can return one Node covering several roots.
    fragment: []const Node,
    /// A conditional subtree between `z-when` comment anchors — see
    /// `variant`/`when`.
    variant: Variant,
};

/// Text child node — HTML-escaped on output.
pub fn text(s: []const u8) Node {
    return .{ .text = s };
}

/// Trusted raw HTML — never escaped, never diffed.
pub fn raw(html: []const u8) Node {
    return .{ .raw = html };
}

/// Mark `nodes` as a keyed child list: every child must be an element with
/// `.id`. Diffing reconciles membership and order via `Dom.syncKeyedList`
/// (create/remove/move patches); static children are untouched.
pub fn each(nodes: []const Node) Children {
    return .{ .keyed = nodes };
}

/// Group sibling nodes into one transparent `Node` — emits no wrapper of
/// its own. `kids` accepts the same shapes as `el` children; this is how a
/// component (a plain fn → Node) can cover several roots.
pub fn fragment(a: std.mem.Allocator, kids: anytype) Node {
    return .{ .fragment = switch (normChildren(a, kids)) {
        .nodes, .keyed => |s| s,
    } };
}

/// A conditional subtree at a fixed DOM position. `idspec` is an
/// anonymous struct — `.id`/`.lid` resolved like element bindings —
/// naming the `<!--z-when:ID-->` / `<!--/z-when:ID-->` anchor pair.
/// `key` identifies the active branch (any `resolveValue` operand:
/// strings, ints, optionals, `*T.get()` stores, `computed` bindings);
/// `null` mounts the empty branch. `children` is the current branch's
/// markup — the same shapes as `el` children except a bare keyed list
/// (wrap `each`/`eachOf` in a bound parent element instead: a comment
/// anchor can't be a create/move parent) — rendered only while `key` is
/// non-null. SSR always emits both comments; on a branch-key change the
/// diff ships one idempotent `when` op with the new branch markup.
pub fn variant(a: std.mem.Allocator, idspec: anytype, key: anytype, children: anytype) Node {
    var v: Variant = .{ .key = valueFor(a, key) };
    const sinfo = @typeInfo(@TypeOf(idspec)).@"struct";
    inline for (sinfo.field_names) |name| {
        const f = @field(idspec, name);
        if (comptime std.mem.eql(u8, name, "id")) {
            v.id = resolveValue(a, f);
        } else if (comptime std.mem.eql(u8, name, "lid")) {
            v.lid = resolveValue(a, f);
        } else {
            @compileError("variant idspec fields must be .id/.lid, found ." ++ name);
        }
    }
    v.nodes = switch (normChildren(a, children)) {
        .nodes => |s| s,
        .keyed => @panic("variant children can't be a bare keyed list; wrap each/eachOf in a bound parent element"),
    };
    return .{ .variant = v };
}

/// `variant` sugar for a boolean condition: mounts `children` while
/// `cond` is truthy (bool, non-zero int, non-empty string, present
/// optional, or a `*T.get()`/`computed` of one of those). The branch key
/// is "on"/null.
pub fn when(a: std.mem.Allocator, idspec: anytype, cond: anytype, children: anytype) Node {
    const key: ?[]const u8 = if (truthy(a, cond)) "on" else null;
    return variant(a, idspec, key, children);
}

/// Bind `store` (any `*T` exposing `.get()`) through the mapping fn `f` —
/// `f(a, store.get())` is resolved lazily wherever the `Bound` lands
/// (`.text` or an attribute), so `.text = computed(s.remaining, countText)`
/// renders and diffs like the equivalent pre-rendered string.
pub fn computed(store: anytype, comptime f: anytype) Bound {
    const S = @TypeOf(store);
    comptime assertGettable(S);
    const gen = struct {
        fn call(a: std.mem.Allocator, ctx: *const anyopaque) ?[]const u8 {
            const s: *const std.meta.Child(S) = @ptrCast(@alignCast(ctx));
            return resolveValue(a, f(a, s.get()));
        }
    };
    return .{
        .ctx = store,
        .call = &gen.call,
        .presence = comptime fnReturnsBool(@TypeOf(f)),
    };
}

/// Build a keyed child list from `items`: `render(a, ctx, item)` maps each
/// item to a `Node` — returning null filters it out. Every non-null child
/// must be an element carrying `.id` (enforced at diff/seed time).
pub fn eachOf(a: std.mem.Allocator, items: anytype, ctx: anytype, render: anytype) Children {
    var list: std.ArrayListUnmanaged(Node) = .empty;
    for (items) |item| {
        if (render(a, ctx, item)) |n| list.append(a, n) catch @panic("OOM");
    }
    return .{ .keyed = list.toOwnedSlice(a) catch @panic("OOM") };
}

/// Build an element node in `a` (the per-render arena). `attrs` is an
/// anonymous struct: field names become attribute names (use `@"data-*"`
/// for dashed names); `id`, `lid` and `text` are the bindings documented
/// on `Element` — everything else is a plain attribute. Value types:
/// `?T` omits the attribute on null, `bool` is presence/absence, ints are
/// formatted with `{d}`, strings are emitted escaped — and any `*T`
/// exposing `.get()` (e.g. a zefx `Store`, duck-typed: forest does not
/// depend on it) resolves `v.get()` and formats it like a plain value,
/// lazily at render/diff/seed time. `computed` bindings work the same.
///
/// `children` accepts `[]const Node`, a single `Node`, a string (a text
/// child), a tuple of nodes, or `each`/`eachOf(...)` for a keyed list.
///
/// Two attr fields declare DOM events instead of plain attributes:
///   `.on = .{ .click = "delete" }` — field names are DOM event types
///     (comptime-whitelisted: click/change/input/submit/keydown); each
///     emits `data-on-<ev>="<value>"`, which the delegated client-side
///     listener turns into an action POST.
///   `.arg = v` — emits `data-arg` (string or int), the action's payload.
/// Both render through the normal attr path: written into SSR/create
/// markup and treated as ordinary attrs by diff (self-diff → no churn).
pub fn el(a: std.mem.Allocator, comptime tag: Tag, attrs: anytype, children: anytype) Node {
    var e: Element = .{ .tag = tag };
    const sinfo = @typeInfo(@TypeOf(attrs)).@"struct";
    var list: std.ArrayListUnmanaged(Attr) = .empty;
    inline for (sinfo.field_names) |name| {
        const v = @field(attrs, name);
        if (comptime std.mem.eql(u8, name, "id")) {
            e.id = resolveValue(a, v);
        } else if (comptime std.mem.eql(u8, name, "lid")) {
            e.lid = resolveValue(a, v);
        } else if (comptime std.mem.eql(u8, name, "text")) {
            e.text = valueFor(a, v);
        } else if (comptime std.mem.eql(u8, name, "on")) {
            inline for (@typeInfo(@TypeOf(v)).@"struct".field_names) |ev| {
                comptime assertDomEvent(ev);
                list.append(a, attrOf(a, "data-on-" ++ ev, @field(v, ev))) catch @panic("OOM");
            }
        } else if (comptime std.mem.eql(u8, name, "arg")) {
            list.append(a, attrOf(a, "data-arg", v)) catch @panic("OOM");
        } else {
            list.append(a, attrOf(a, name, v)) catch @panic("OOM");
        }
    }
    e.attrs = list.toOwnedSlice(a) catch @panic("OOM");
    e.children = normChildren(a, children);
    if (e.tag.isVoid()) {
        std.debug.assert(std.meta.activeTag(e.children) == .nodes and e.children.nodes.len == 0);
    }
    return .{ .element = e };
}

/// Serialize `nodes` to HTML — SSR pages, create-patch bodies, snapshot
/// row markup. `a` is scratch space for resolved `lid` ids.
pub fn writeHtml(a: std.mem.Allocator, nodes: []const Node, writer: anytype) !void {
    for (nodes) |n| try writeNode(a, n, "", writer);
}

/// Reconcile `nodes` against the Dom's tracked state and emit the real
/// changes into `log`. `a` is scratch (the render arena): row html and
/// resolved ids live for the duration of the call.
///
/// Bound nodes (`.id`/`.lid`) self-diff every attr plus `.text`. A keyed
/// parent goes through `syncKeyedList`; newly created rows have all their
/// bound state seeded to match the shipped html, so a follow-up render
/// emits only real changes. Static elements only recurse.
pub fn diff(a: std.mem.Allocator, nodes: []const Node, dom: *Dom, log: *PatchLog) void {
    for (nodes) |n| diffNode(a, n, "", dom, log);
}

/// Serialize `nodes` as a full-state ops array — the SSE snapshot
/// payload. Keyed parents emit `{"op":"html","id":pid,"html":<children>}`
/// (an idempotent innerHTML state dump whose markup fully covers the
/// subtree); `variant`/`when` anchors emit `{"op":"when","id":aid,"html":
/// <branch>}` covering everything between their comment markers; bound
/// nodes emit one attr op per attr plus a text op for `.text`. Op order
/// is irrelevant: this is a state dump, not a diff.
/// `a` is scratch space for resolved ids and row markup.
pub fn writeSnapshotOps(a: std.mem.Allocator, nodes: []const Node, writer: anytype) !void {
    var ops: std.ArrayListUnmanaged(patch_mod.Patch) = .empty;
    defer ops.deinit(a);
    for (nodes) |n| try snapshotOps(a, n, "", &ops);
    try writer.writeByte('[');
    for (ops.items, 0..) |p, i| {
        if (i != 0) try writer.writeByte(',');
        try patch_mod.writeOpJson(writer, p);
    }
    try writer.writeByte(']');
}

// ── internals ───────────────────────────────────────────────────

/// Normalize any view-layer operand to its rendered string (null = the
/// binding is absent). The single resolution point used by `el` and by
/// writeNode/diffNode/seedNode:
///   - null / null optional           → null
///   - `Bound` / `Value`              → deferred thunk resolution
///   - `*T` exposing `.get()`         → resolve `v.get()` recursively
///   - bool                           → presence: "" when set, null when not
///   - int                            → "{d}" into `a`
///   - []const u8 / string literal    → verbatim
fn resolveValue(a: std.mem.Allocator, v: anytype) ?[]const u8 {
    const T = @TypeOf(v);
    if (T == Bound) return v.call(a, v.ctx);
    if (T == Value) return switch (v) {
        .str => |s| s,
        .bound => |b| b.call(a, b.ctx),
    };
    switch (@typeInfo(T)) {
        .null => return null,
        .optional => return if (v) |inner| resolveValue(a, inner) else null,
        .bool => return if (v) "" else null,
        .int, .comptime_int => return std.fmt.allocPrint(a, "{d}", .{v}) catch @panic("OOM"),
        .pointer => {
            if (comptime isGetPtr(T)) return resolveValue(a, v.get());
            return v;
        },
        else => @compileError("unsupported view value type: " ++ @typeName(T)),
    }
}

/// Whether `T` is a `*Child` where `Child` declares `.get` — the
/// duck-typed store contract (zefx `Store`, test fakes, anything
/// compatible). `@hasDecl` only accepts container types, hence the gate.
fn isGetPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .one and switch (@typeInfo(p.child)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(p.child, "get"),
            else => false,
        },
        else => false,
    };
}

/// Wrap an attr/`.text` operand for deferred resolution: `Bound` passes
/// through, `*T.get()` pointers become lazy `Bound` thunks, and plain
/// values render eagerly into `a` like before. Null operands → null.
fn valueFor(a: std.mem.Allocator, v: anytype) ?Value {
    const T = @TypeOf(v);
    if (T == Bound) return .{ .bound = v };
    if (T == Value) return v;
    switch (@typeInfo(T)) {
        .null => return null,
        .optional => return if (v) |inner| valueFor(a, inner) else null,
        .pointer => {
            if (comptime isGetPtr(T)) return .{ .bound = bindGet(v) };
            return .{ .str = v };
        },
        else => {
            const s = resolveValue(a, v) orelse return null;
            return .{ .str = s };
        },
    }
}

/// Wrap a `*T.get()` store pointer as a `Bound` — the get() call is
/// deferred so writeNode/diffNode/seedNode always see the live value.
fn bindGet(store: anytype) Bound {
    const S = @TypeOf(store);
    const gen = struct {
        fn call(a: std.mem.Allocator, ctx: *const anyopaque) ?[]const u8 {
            const s: *const std.meta.Child(S) = @ptrCast(@alignCast(ctx));
            return resolveValue(a, s.get());
        }
    };
    return .{
        .ctx = store,
        .call = &gen.call,
        .presence = comptime getReturnsBool(S),
    };
}

fn assertGettable(comptime S: type) void {
    if (!isGetPtr(S)) {
        @compileError("expected a pointer to a type exposing .get(), found " ++ @typeName(S));
    }
}

fn unwrapOpt(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| unwrapOpt(o.child),
        else => T,
    };
}

/// Whether `*T`'s `.get()` returns a bool — those bindings are presence
/// attributes (`checked`-style), not `key="value"` pairs.
fn getReturnsBool(comptime S: type) bool {
    if (!isGetPtr(S)) return false;
    const r = switch (@typeInfo(@TypeOf(std.meta.Child(S).get))) {
        .@"fn" => |f| f.return_type orelse return false,
        else => return false,
    };
    return unwrapOpt(r) == bool;
}

/// Whether `f` (a fn or fn pointer) returns a bool — for `computed`.
fn fnReturnsBool(comptime F: type) bool {
    const r = switch (@typeInfo(F)) {
        .@"fn" => |f| f.return_type orelse return false,
        .pointer => |p| switch (@typeInfo(p.child)) {
            .@"fn" => |f| f.return_type orelse return false,
            else => return false,
        },
        else => return false,
    };
    return unwrapOpt(r) == bool;
}

/// Whether a plain (non-Bound) operand resolves to a presence attribute.
fn presenceOf(comptime T: type) bool {
    const U = unwrapOpt(T);
    return switch (@typeInfo(U)) {
        .bool => true,
        .pointer => getReturnsBool(U),
        else => false,
    };
}

/// DOM event types allowed in `.on` — anything else is almost certainly
/// a typo that would produce a dead listener, so it fails at comptime.
const dom_events = .{ "click", "dblclick", "change", "input", "submit", "keydown" };

fn assertDomEvent(comptime ev: [:0]const u8) void {
    inline for (dom_events) |allowed| {
        if (comptime std.mem.eql(u8, ev, allowed)) return;
    }
    @compileError("unsupported .on event type: " ++ ev);
}

fn attrOf(a: std.mem.Allocator, name: []const u8, v: anytype) Attr {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .optional => return if (v) |inner| attrOf(a, name, inner) else .{ .name = name },
        else => {},
    }
    if (T == Bound) return .{ .name = name, .value = .{ .bound = v }, .presence = v.presence };
    return .{
        .name = name,
        .value = valueFor(a, v),
        .presence = comptime presenceOf(T),
    };
}

fn oneNode(a: std.mem.Allocator, n: Node) []const Node {
    const s = a.alloc(Node, 1) catch @panic("OOM");
    s[0] = n;
    return s;
}

fn normChildren(a: std.mem.Allocator, c: anytype) Children {
    const T = @TypeOf(c);
    if (T == Children) return c;
    if (T == Node) return .{ .nodes = oneNode(a, c) };
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice and p.child == Node) {
                const s: []const Node = c;
                return .{ .nodes = s };
            }
            if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == Node) {
                return .{ .nodes = a.dupe(Node, c.*) catch @panic("OOM") };
            }
            const s: []const u8 = c; // string literal or u8 slice
            return .{ .nodes = oneNode(a, .{ .text = s }) };
        },
        .array => |info| {
            if (info.child != Node) @compileError("children arrays must be []Node");
            return .{ .nodes = a.dupe(Node, &c) catch @panic("OOM") };
        },
        .@"struct" => |info| {
            if (!info.is_tuple) @compileError("children must be nodes, text, or each(...)");
            const slice = a.alloc(Node, info.field_names.len) catch @panic("OOM");
            inline for (info.field_names, 0..) |name, i| {
                const child: Node = @field(c, name);
                slice[i] = child;
            }
            return .{ .nodes = slice };
        },
        else => @compileError("unsupported children type: " ++ @typeName(T)),
    }
}

/// The DOM id a node answers to: `.id` verbatim, or `.lid` composed
/// against the nearest bound ancestor's id (`parent/lid`).
fn resolvedId(a: std.mem.Allocator, id: ?[]const u8, lid: ?[]const u8, parent_path: []const u8) ?[]const u8 {
    if (id) |v| return v;
    const l = lid orelse return null;
    if (parent_path.len == 0) return a.dupe(u8, l) catch @panic("OOM");
    // Manual concat — this runs per bound element per render, so skip fmt.
    const out = a.alloc(u8, parent_path.len + 1 + l.len) catch @panic("OOM");
    @memcpy(out[0..parent_path.len], parent_path);
    out[parent_path.len] = '/';
    @memcpy(out[parent_path.len + 1 ..], l);
    return out;
}

/// The id a `z-when` comment pair answers to — `resolvedId` over the
/// variant's `.id`/`.lid`. An anchor is required and `--` would corrupt
/// the marker text (ids are dev-controlled, so assert).
fn anchorId(a: std.mem.Allocator, v: Variant, parent_path: []const u8) []const u8 {
    const anchor = resolvedId(a, v.id, v.lid, parent_path) orelse
        @panic("variant requires a bound anchor (.id/.lid)");
    std.debug.assert(std.mem.indexOf(u8, anchor, "--") == null);
    return anchor;
}

/// `when` condition truthiness, mirroring `resolveValue`'s operand set:
/// bool → itself; optional → null is false, else the inner recurses;
/// `*T.get()` → deref and recurse; int → non-zero; string → non-empty;
/// `Bound`/`Value` → resolved, then presence-bound non-null or
/// non-empty is true.
fn truthy(a: std.mem.Allocator, v: anytype) bool {
    const T = @TypeOf(v);
    if (T == Bound) return truthyBound(a, v);
    if (T == Value) return switch (v) {
        .str => |s| s.len != 0,
        .bound => |b| truthyBound(a, b),
    };
    switch (@typeInfo(T)) {
        .null => return false,
        .optional => return if (v) |inner| truthy(a, inner) else false,
        .bool => return v,
        .int, .comptime_int => return v != 0,
        .pointer => |p| {
            if (comptime isGetPtr(T)) return truthy(a, v.get());
            if (p.child == u8 and p.size == .slice) return v.len != 0;
            if (p.size == .one and @typeInfo(p.child) == .array and
                @typeInfo(p.child).array.child == u8) return v.len != 0;
            @compileError("unsupported when() cond type: " ++ @typeName(T));
        },
        else => @compileError("unsupported when() cond type: " ++ @typeName(T)),
    }
}

fn truthyBound(a: std.mem.Allocator, b: Bound) bool {
    const s = b.call(a, b.ctx) orelse return false;
    // Presence bindings render "" for true; plain ones a real string.
    return if (b.presence) true else s.len != 0;
}

fn keyedChildId(k: Node) []const u8 {
    const e = switch (k) {
        .element => |ce| ce,
        else => @panic("keyed children must be elements"),
    };
    return e.id orelse @panic("keyed children require .id");
}

fn writeNode(a: std.mem.Allocator, node: Node, parent_path: []const u8, writer: anytype) !void {
    switch (node) {
        .text => |s| try escapeHtmlInto(writer, s),
        .raw => |s| try writer.writeAll(s),
        .fragment => |kids| for (kids) |k| try writeNode(a, k, parent_path, writer),
        .variant => |v| {
            // Both markers always — branch markup lives strictly between.
            const anchor = anchorId(a, v, parent_path);
            try writer.writeAll("<!--z-when:");
            try writer.writeAll(anchor);
            try writer.writeAll("-->");
            if (resolveValue(a, v.key) != null) {
                for (v.nodes) |k| try writeNode(a, k, anchor, writer);
            }
            try writer.writeAll("<!--/z-when:");
            try writer.writeAll(anchor);
            try writer.writeAll("-->");
        },
        .element => |e| {
            const id = resolvedId(a, e.id, e.lid, parent_path);
            try writer.writeByte('<');
            try writer.writeAll(@tagName(e.tag));
            if (id) |v| {
                try writer.writeAll(" id=\"");
                try escapeHtmlInto(writer, v);
                try writer.writeByte('"');
            }
            for (e.attrs) |at| {
                const v = resolveValue(a, at.value) orelse continue;
                try writer.writeByte(' ');
                try writer.writeAll(at.name);
                if (!at.presence) {
                    try writer.writeAll("=\"");
                    try escapeHtmlInto(writer, v);
                    try writer.writeByte('"');
                }
            }
            try writer.writeByte('>');
            if (e.tag.isVoid()) return;
            if (e.text) |tv| {
                if (resolveValue(a, tv)) |t| try escapeHtmlInto(writer, t);
            } else {
                const kids: []const Node = switch (e.children) {
                    .nodes, .keyed => |k| k,
                };
                const path = id orelse parent_path;
                for (kids) |k| try writeNode(a, k, path, writer);
            }
            try writer.writeAll("</");
            try writer.writeAll(@tagName(e.tag));
            try writer.writeByte('>');
        },
    }
}

fn diffNode(a: std.mem.Allocator, node: Node, parent_path: []const u8, dom: *Dom, log: *PatchLog) void {
    switch (node) {
        .text, .raw => {},
        .fragment => |kids| for (kids) |k| diffNode(a, k, parent_path, dom, log),
        .variant => |v| {
            const anchor = anchorId(a, v, parent_path);
            const key = resolveValue(a, v.key);
            if (!dom.setWhen(anchor, key)) {
                // Same branch: recurse normally; an empty branch mounts nothing.
                if (key != null) for (v.nodes) |k| diffNode(a, k, anchor, dom, log);
                return;
            }
            // Branch changed (appear/disappear/swap): one idempotent
            // when-op ships the new branch markup; stale `anchor/…` state
            // is dropped and the shipped branch seeded so the next diff
            // emits only real changes. (Absolute .id nodes inside the
            // branch aren't anchor-prefixed — re-seeded on every remount,
            // bounded and harmless.)
            var aw: std.Io.Writer.Allocating = .init(a);
            defer aw.deinit();
            if (key != null) {
                for (v.nodes) |k| writeNode(a, k, anchor, &aw.writer) catch @panic("OOM");
            }
            log.setWhen(anchor, aw.toOwnedSlice() catch @panic("OOM"));
            dom.removeTracked(anchor);
            // removeTracked drops the anchor's own when_state too — re-seed.
            dom.seedWhen(anchor, key);
            if (key != null) for (v.nodes) |k| seedNode(a, k, anchor, dom);
        },
        .element => |e| {
            const id = resolvedId(a, e.id, e.lid, parent_path);
            if (id) |nid| {
                for (e.attrs) |at| dom.setAttr(log, nid, at.name, resolveValue(a, at.value));
                if (e.text) |tv| {
                    if (resolveValue(a, tv)) |t| dom.setText(log, nid, t);
                }
            }
            const path = id orelse parent_path;
            if (e.text != null) return; // .text owns the element's content
            switch (e.children) {
                .nodes => |kids| for (kids) |k| diffNode(a, k, path, dom, log),
                .keyed => |kids| {
                    const pid = id orelse @panic("keyed children require a bound parent (.id/.lid)");
                    diffKeyed(a, pid, kids, dom, log);
                },
            }
        },
    }
}

/// Context for `rowHtml` — serializes keyed child `i`'s markup. Called
/// by `Dom.syncKeyedList` only for rows that actually need a create
/// patch, so existing rows never pay for HTML serialization.
const RowHtml = struct {
    a: std.mem.Allocator,
    kids: []const Node,
    parent_id: []const u8,
};

fn rowHtml(ctx: RowHtml, i: usize) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(ctx.a);
    defer aw.deinit();
    writeNode(ctx.a, ctx.kids[i], ctx.parent_id, &aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

fn diffKeyed(a: std.mem.Allocator, parent_id: []const u8, kids: []const Node, dom: *Dom, log: *PatchLog) void {
    const ids = a.alloc([]const u8, kids.len) catch @panic("OOM");
    for (kids, 0..) |k, i| ids[i] = keyedChildId(k);

    // `created` is allocated with the Dom's gpa (see syncKeyedList).
    var created: std.ArrayListUnmanaged([]const u8) = .empty;
    defer created.deinit(dom.gpa);
    const hctx: RowHtml = .{ .a = a, .kids = kids, .parent_id = parent_id };
    dom.syncKeyedList(log, a, parent_id, ids, rowHtml, hctx, &created);

    for (kids) |k| {
        const kid = keyedChildId(k);
        var was_created = false;
        for (created.items) |cid| {
            if (std.mem.eql(u8, cid, kid)) {
                was_created = true;
                break;
            }
        }
        if (was_created) {
            // Markup already shipped inside the create patch — record the
            // bound state so the next diff emits only real changes.
            seedNode(a, k, parent_id, dom);
        } else {
            diffNode(a, k, parent_id, dom, log);
        }
    }
}

/// Collect the full-state ops for `node` into `ops` — the walk behind
/// `writeSnapshotOps`. Keyed children are not recursed into: the parent
/// `html` op already ships their markup.
fn snapshotOps(a: std.mem.Allocator, node: Node, parent_path: []const u8, ops: *std.ArrayListUnmanaged(patch_mod.Patch)) !void {
    switch (node) {
        .text, .raw => {},
        .fragment => |kids| for (kids) |k| try snapshotOps(a, k, parent_path, ops),
        .variant => |v| {
            // One full-state when-op per anchor; the branch markup covers
            // everything between the markers — no inner ops (same rule as
            // a keyed `html` op covering its rows).
            const anchor = anchorId(a, v, parent_path);
            var aw: std.Io.Writer.Allocating = .init(a);
            defer aw.deinit();
            if (resolveValue(a, v.key) != null) {
                for (v.nodes) |k| writeNode(a, k, anchor, &aw.writer) catch @panic("OOM");
            }
            ops.append(a, .{ .when = .{
                .id = anchor,
                .html = aw.toOwnedSlice() catch @panic("OOM"),
            } }) catch @panic("OOM");
        },
        .element => |e| {
            const id = resolvedId(a, e.id, e.lid, parent_path);
            if (id) |nid| {
                for (e.attrs) |at| {
                    ops.append(a, .{ .attr = .{
                        .id = nid,
                        .name = at.name,
                        .value = resolveValue(a, at.value),
                    } }) catch @panic("OOM");
                }
                if (e.text) |tv| {
                    if (resolveValue(a, tv)) |t| {
                        ops.append(a, .{ .text = .{ .id = nid, .text = t } }) catch @panic("OOM");
                    }
                }
            }
            const path = id orelse parent_path;
            if (e.text != null) return;
            switch (e.children) {
                .nodes => |kids| for (kids) |k| try snapshotOps(a, k, path, ops),
                .keyed => |kids| {
                    const pid = id orelse @panic("keyed children require a bound parent (.id/.lid)");
                    var aw: std.Io.Writer.Allocating = .init(a);
                    defer aw.deinit();
                    writeHtml(a, kids, &aw.writer) catch @panic("OOM");
                    ops.append(a, .{ .html = .{ .id = pid, .html = aw.toOwnedSlice() catch @panic("OOM") } }) catch @panic("OOM");
                },
            }
        },
    }
}

/// Record all bound state under `node` (attrs, `.text`, keyed orders) as
/// already-on-the-page truth — no patches.
fn seedNode(a: std.mem.Allocator, node: Node, parent_path: []const u8, dom: *Dom) void {
    switch (node) {
        .text, .raw => {},
        .fragment => |kids| for (kids) |k| seedNode(a, k, parent_path, dom),
        .variant => |v| {
            const anchor = anchorId(a, v, parent_path);
            const key = resolveValue(a, v.key);
            dom.seedWhen(anchor, key);
            if (key != null) for (v.nodes) |k| seedNode(a, k, anchor, dom);
        },
        .element => |e| {
            const id = resolvedId(a, e.id, e.lid, parent_path);
            if (id) |nid| {
                for (e.attrs) |at| dom.seedAttr(nid, at.name, resolveValue(a, at.value));
                if (e.text) |tv| {
                    if (resolveValue(a, tv)) |t| dom.seedText(nid, t);
                }
            }
            const path = id orelse parent_path;
            if (e.text != null) return;
            switch (e.children) {
                .nodes => |kids| for (kids) |k| seedNode(a, k, path, dom),
                .keyed => |kids| {
                    const pid = id orelse @panic("keyed children require a bound parent (.id/.lid)");
                    var ids: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer ids.deinit(a);
                    for (kids) |k| ids.append(a, keyedChildId(k)) catch @panic("OOM");
                    dom.seedOrder(pid, ids.items);
                    for (kids) |k| seedNode(a, k, pid, dom);
                },
            }
        },
    }
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

const TRow = struct { id: u32, title: []const u8, done: bool };
const TFilt = enum { all, active, completed };

/// Mini todo-shaped view used by the diff tests: filters (bound attrs),
/// keyed list of rows, bound counter — same shape as the real session.
fn testView(a: std.mem.Allocator, rows: []const TRow, filt: TFilt, remaining: usize) []const Node {
    var list: std.ArrayListUnmanaged(Node) = .empty;
    for (rows) |t| {
        const vis = switch (filt) {
            .all => true,
            .active => !t.done,
            .completed => t.done,
        };
        if (!vis) continue;
        list.append(a, el(a, .li, .{
            .id = std.fmt.allocPrint(a, "row-{d}", .{t.id}) catch @panic("OOM"),
            .class = if (t.done) "todo done" else "todo",
        }, .{
            el(a, .input, .{
                .lid = "cb",
                .type = "checkbox",
                .checked = t.done,
                .on = .{ .change = "set_checked" },
                .arg = t.id,
            }, .{}),
            el(a, .span, .{ .class = "title" }, t.title),
            el(a, .button, .{
                .class = "del",
                .@"aria-label" = "delete",
                .on = .{ .click = "delete" },
                .arg = t.id,
            }, "×"),
        })) catch @panic("OOM");
    }

    var top: std.ArrayListUnmanaged(Node) = .empty;
    var btns: std.ArrayListUnmanaged(Node) = .empty;
    inline for (.{ TFilt.all, TFilt.active, TFilt.completed }) |f| {
        btns.append(a, el(a, .button, .{
            .id = comptime "flt-" ++ @tagName(f),
            .@"data-active" = if (filt == f) "1" else null,
            .on = .{ .click = "filter" },
            .arg = @tagName(f),
        }, @tagName(f))) catch @panic("OOM");
    }
    top.append(a, el(a, .div, .{ .class = "filters" }, btns.toOwnedSlice(a) catch @panic("OOM"))) catch @panic("OOM");
    top.append(a, el(a, .ul, .{ .id = "list" }, each(list.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    const count = std.fmt.allocPrint(a, "{d} item{s} left", .{ remaining, if (remaining == 1) "" else "s" }) catch @panic("OOM");
    top.append(a, el(a, .footer, .{}, .{
        el(a, .span, .{ .id = "count", .text = count }, .{}),
    })) catch @panic("OOM");
    return top.toOwnedSlice(a) catch @panic("OOM");
}

fn renderStr(a: std.mem.Allocator, nodes: []const Node) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    writeHtml(a, nodes, &aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

test "view SSR emits exact html" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = el(a, .div, .{ .class = "x", .@"data-n" = 3 }, .{
        text("a<&\"'b"),
        el(a, .span, .{ .@"data-x" = "p\"q" }, "hi"),
        raw("<b>raw</b>"),
    });
    try std.testing.expectEqualStrings(
        "<div class=\"x\" data-n=\"3\">a&lt;&amp;&quot;&#39;b<span data-x=\"p&quot;q\">hi</span><b>raw</b></div>",
        renderStr(a, &.{v}),
    );
}

test "view SSR omits null attrs and renders bool presence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = el(a, .button, .{
        .id = "flt-all",
        .@"data-filter" = "all",
        .@"data-active" = @as(?[]const u8, null),
    }, "all");
    try std.testing.expectEqualStrings(
        "<button id=\"flt-all\" data-filter=\"all\">all</button>",
        renderStr(a, &.{v}),
    );

    const on = el(a, .input, .{ .id = "c", .type = "checkbox", .checked = true }, .{});
    const off = el(a, .input, .{ .id = "c", .type = "checkbox", .checked = false }, .{});
    try std.testing.expectEqualStrings("<input id=\"c\" type=\"checkbox\" checked>", renderStr(a, &.{on}));
    try std.testing.expectEqualStrings("<input id=\"c\" type=\"checkbox\">", renderStr(a, &.{off}));
}

test "view SSR resolves lid against parent id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = el(a, .li, .{ .id = "row-3", .class = "todo" }, .{
        el(a, .input, .{ .lid = "cb", .type = "checkbox" }, .{}),
    });
    try std.testing.expectEqualStrings(
        "<li id=\"row-3\" class=\"todo\"><input id=\"row-3/cb\" type=\"checkbox\"></li>",
        renderStr(a, &.{v}),
    );
}

test "view SSR writes bound .text and int attrs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = el(a, .span, .{ .id = "count", .text = "2 items left" }, .{});
    try std.testing.expectEqualStrings(
        "<span id=\"count\">2 items left</span>",
        renderStr(a, &.{v}),
    );
    const inp = el(a, .input, .{ .maxlength = @as(u16, 500) }, .{});
    try std.testing.expectEqualStrings("<input maxlength=\"500\">", renderStr(a, &.{inp}));
}

/// Duck-typed fake store: forest bindings only require a `*T.get()`,
/// never a concrete type (zefx stays out of this module).
fn FakeStore(comptime T: type) type {
    return struct {
        v: T,
        pub fn get(self: *const @This()) T {
            return self.v;
        }
    };
}

test "store pointers bind in .text and attrs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var n = FakeStore(usize){ .v = 3 };
    var flag = FakeStore(bool){ .v = true };

    const v = el(a, .span, .{ .id = "c", .text = &n }, .{});
    try std.testing.expectEqualStrings("<span id=\"c\">3</span>", renderStr(a, &.{v}));

    const d = el(a, .div, .{ .id = "d", .@"data-n" = &n, .hidden = &flag }, .{});
    try std.testing.expectEqualStrings(
        "<div id=\"d\" data-n=\"3\" hidden></div>",
        renderStr(a, &.{d}),
    );

    // Live binding: mutating between renders resolves the new value.
    n.v = 7;
    flag.v = false;
    try std.testing.expectEqualStrings("<span id=\"c\">7</span>", renderStr(a, &.{v}));
    try std.testing.expectEqualStrings(
        "<div id=\"d\" data-n=\"7\"></div>",
        renderStr(a, &.{d}),
    );
}

test "computed maps a store through a fn lazily" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var remaining = FakeStore(usize){ .v = 2 };
    const fmt = struct {
        fn count(alloc: std.mem.Allocator, rem: usize) []const u8 {
            return std.fmt.allocPrint(alloc, "{d} item{s} left", .{ rem, if (rem == 1) "" else "s" }) catch @panic("OOM");
        }
    }.count;

    const v = el(a, .span, .{ .id = "count", .text = computed(&remaining, fmt) }, .{});
    try std.testing.expectEqualStrings(
        "<span id=\"count\">2 items left</span>",
        renderStr(a, &.{v}),
    );
    remaining.v = 1; // resolved at render time, not at el() time
    try std.testing.expectEqualStrings(
        "<span id=\"count\">1 item left</span>",
        renderStr(a, &.{v}),
    );
}

test "eachOf maps items through ctx render and filters nulls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Ctx = struct {
        skip: u8,
        fn row(alloc: std.mem.Allocator, c: *const @This(), n: u8) ?Node {
            if (n == c.skip) return null;
            return el(alloc, .li, .{
                .id = std.fmt.allocPrint(alloc, "r-{d}", .{n}) catch @panic("OOM"),
            }, "x");
        }
    };
    const ctx = Ctx{ .skip = 2 };
    const items = [3]u8{ 1, 2, 3 };

    const kids = eachOf(a, &items, &ctx, Ctx.row);
    try std.testing.expect(kids == .keyed);
    try std.testing.expectEqual(@as(usize, 2), kids.keyed.len);

    const v = el(a, .ul, .{ .id = "list" }, kids);
    try std.testing.expectEqualStrings(
        "<ul id=\"list\"><li id=\"r-1\">x</li><li id=\"r-3\">x</li></ul>",
        renderStr(a, &.{v}),
    );
}

test "bool presence attr diffs on a bound non-keyed node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    diff(a, &.{el(a, .div, .{ .id = "flt", .class = "filters", .hidden = false }, .{})}, &dom, &log);
    log.clear();

    diff(a, &.{el(a, .div, .{ .id = "flt", .class = "filters", .hidden = true }, .{})}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try expectAttr(log.patches.items[0], "flt", "hidden", "");
    log.clear();

    diff(a, &.{el(a, .div, .{ .id = "flt", .class = "filters", .hidden = false }, .{})}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try expectAttr(log.patches.items[0], "flt", "hidden", null);
}

test "fragment renders siblings without a wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = fragment(a, .{
        el(a, .h1, .{}, "title"),
        el(a, .form, .{ .id = "add-form" }, .{}),
    });
    try std.testing.expectEqualStrings(
        "<h1>title</h1><form id=\"add-form\"></form>",
        renderStr(a, &.{v}),
    );
}

test ".on and .arg emit data-on-* and data-arg attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = el(a, .button, .{
        .class = "del",
        .on = .{ .click = "delete" },
        .arg = @as(u32, 7),
    }, "×");
    try std.testing.expectEqualStrings(
        "<button class=\"del\" data-on-click=\"delete\" data-arg=\"7\">×</button>",
        renderStr(a, &.{v}),
    );

    const form = el(a, .form, .{ .on = .{ .submit = "add" } }, .{});
    try std.testing.expectEqualStrings(
        "<form data-on-submit=\"add\"></form>",
        renderStr(a, &.{form}),
    );

    const cb = el(a, .input, .{
        .type = "checkbox",
        .on = .{ .change = "set_checked", .input = "typing" },
        .arg = "row-1",
    }, .{});
    try std.testing.expectEqualStrings(
        "<input type=\"checkbox\" data-on-change=\"set_checked\" data-on-input=\"typing\" data-arg=\"row-1\">",
        renderStr(a, &.{cb}),
    );
}

test "writeSnapshotOps dumps html op for keyed parent plus bound node ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rows = [2]TRow{
        .{ .id = 1, .title = "one", .done = false },
        .{ .id = 2, .title = "two", .done = true },
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeSnapshotOps(a, testView(a, &rows, .all, 1), &aw.writer);
    const json = aw.writer.buffered();

    // keyed parent → html state dump covering the whole list (JSON-escaped markup)
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"op\":\"html\",\"id\":\"list\",\"html\":\"\\u003cli id=\\\"row-1\\\"") != null);
    // bound filter buttons → data-active attr ops
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"op\":\"attr\",\"id\":\"flt-all\",\"name\":\"data-active\",\"value\":\"1\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"op\":\"attr\",\"id\":\"flt-active\",\"name\":\"data-active\",\"value\":null}") != null);
    // bound count → text op
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"op\":\"text\",\"id\":\"count\",\"text\":\"1 item left\"}") != null);
    // no diff ops leak into a state dump
    try std.testing.expect(std.mem.indexOf(u8, json, "create") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "remove") == null);
}

fn expectAttr(p: patch_mod.Patch, id: []const u8, name: []const u8, value: ?[]const u8) !void {
    try std.testing.expect(p == .attr);
    const at = p.attr;
    try std.testing.expectEqualStrings(id, at.id);
    try std.testing.expectEqualStrings(name, at.name);
    if (value) |v| {
        try std.testing.expect(at.value != null);
        try std.testing.expectEqualStrings(v, at.value.?);
    } else {
        try std.testing.expect(at.value == null);
    }
}

fn expectText(p: patch_mod.Patch, id: []const u8, txt: []const u8) !void {
    try std.testing.expect(p == .text);
    try std.testing.expectEqualStrings(id, p.text.id);
    try std.testing.expectEqualStrings(txt, p.text.text);
}

test "diff emits nothing once seeded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    const rows = [2]TRow{
        .{ .id = 1, .title = "one", .done = false },
        .{ .id = 2, .title = "two", .done = true },
    };
    diff(a, testView(a, &rows, .all, 1), &dom, &log);
    try std.testing.expect(log.patches.items.len > 0); // first pass populates
    log.clear();
    diff(a, testView(a, &rows, .all, 1), &dom, &log);
    try std.testing.expectEqual(@as(usize, 0), log.patches.items.len);
}

test "diff add emits create with full row html plus count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    diff(a, testView(a, &.{}, .all, 0), &dom, &log);
    log.clear();

    const rows = [1]TRow{.{ .id = 1, .title = "say \"<b>hi</b>\"", .done = false }};
    diff(a, testView(a, &rows, .all, 1), &dom, &log);
    try std.testing.expectEqual(@as(usize, 2), log.patches.items.len);
    const c = log.patches.items[0].create;
    try std.testing.expectEqualStrings("list", c.parent_id);
    try std.testing.expect(c.before_id == null);
    try std.testing.expectEqualStrings("row-1", c.id);
    try std.testing.expectEqualStrings(
        "<li id=\"row-1\" class=\"todo\"><input id=\"row-1/cb\" type=\"checkbox\" data-on-change=\"set_checked\" data-arg=\"1\"><span class=\"title\">say &quot;&lt;b&gt;hi&lt;/b&gt;&quot;</span><button class=\"del\" aria-label=\"delete\" data-on-click=\"delete\" data-arg=\"1\">×</button></li>",
        c.html,
    );
    try expectText(log.patches.items[1], "count", "1 item left");
}

test "diff toggle emits class and checked only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    const before = [1]TRow{.{ .id = 1, .title = "x", .done = false }};
    diff(a, testView(a, &before, .all, 1), &dom, &log);
    log.clear();

    const after = [1]TRow{.{ .id = 1, .title = "x", .done = true }};
    diff(a, testView(a, &after, .all, 0), &dom, &log);
    try std.testing.expectEqual(@as(usize, 3), log.patches.items.len);
    try expectAttr(log.patches.items[0], "row-1", "class", "todo done");
    try expectAttr(log.patches.items[1], "row-1/cb", "checked", "");
    try expectText(log.patches.items[2], "count", "0 items left");
}

test "diff filter emits data-active flips and removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    const rows = [2]TRow{
        .{ .id = 1, .title = "done", .done = true },
        .{ .id = 2, .title = "open", .done = false },
    };
    diff(a, testView(a, &rows, .all, 1), &dom, &log);
    log.clear();

    // Switch to .active: flt-all loses data-active, flt-active gains it,
    // done row leaves the list; remaining count is filter-independent.
    diff(a, testView(a, &rows, .active, 1), &dom, &log);
    try std.testing.expectEqual(@as(usize, 3), log.patches.items.len);
    try expectAttr(log.patches.items[0], "flt-all", "data-active", null);
    try expectAttr(log.patches.items[1], "flt-active", "data-active", "1");
    try std.testing.expect(log.patches.items[2] == .remove);
    try std.testing.expectEqualStrings("row-1", log.patches.items[2].remove.id);
}

test "diff delete emits remove and count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    const rows = [2]TRow{
        .{ .id = 1, .title = "a", .done = false },
        .{ .id = 2, .title = "b", .done = false },
    };
    diff(a, testView(a, &rows, .all, 2), &dom, &log);
    log.clear();

    const kept = [1]TRow{.{ .id = 2, .title = "b", .done = false }};
    diff(a, testView(a, &kept, .all, 1), &dom, &log);
    try std.testing.expectEqual(@as(usize, 2), log.patches.items.len);
    try std.testing.expect(log.patches.items[0] == .remove);
    try std.testing.expectEqualStrings("row-1", log.patches.items[0].remove.id);
    try expectText(log.patches.items[1], "count", "1 item left");
    // The removed row's bindings are gone from tracked state.
    try std.testing.expect(dom.texts.get("row-1") == null);
}

test "diff reorder emits a move patch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    const rows = [3]TRow{
        .{ .id = 1, .title = "a", .done = false },
        .{ .id = 2, .title = "b", .done = false },
        .{ .id = 3, .title = "c", .done = false },
    };
    diff(a, testView(a, &rows, .all, 3), &dom, &log);
    log.clear();

    const reordered = [3]TRow{
        .{ .id = 3, .title = "c", .done = false },
        .{ .id = 1, .title = "a", .done = false },
        .{ .id = 2, .title = "b", .done = false },
    };
    diff(a, testView(a, &reordered, .all, 3), &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    const m = log.patches.items[0].move;
    try std.testing.expectEqualStrings("list", m.parent_id);
    try std.testing.expectEqualStrings("row-3", m.id);
    try std.testing.expectEqualStrings("row-1", m.before_id.?);
}

test "created row seeds bindings so toggle emits only real diffs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    diff(a, testView(a, &.{}, .all, 0), &dom, &log);
    log.clear();

    // Create row-7, then toggle it in the very next render: the bindings
    // seeded at create time must absorb type/data-on-change so only the
    // real class/checked/count changes are emitted.
    const created = [1]TRow{.{ .id = 7, .title = "new", .done = false }};
    diff(a, testView(a, &created, .all, 1), &dom, &log);
    log.clear();

    const toggled = [1]TRow{.{ .id = 7, .title = "new", .done = true }};
    diff(a, testView(a, &toggled, .all, 0), &dom, &log);
    try std.testing.expectEqual(@as(usize, 3), log.patches.items.len);
    try expectAttr(log.patches.items[0], "row-7", "class", "todo done");
    try expectAttr(log.patches.items[1], "row-7/cb", "checked", "");
    try expectText(log.patches.items[2], "count", "0 items left");
}

// ─────────────────────────────────────────────
// variant/when tests
// ─────────────────────────────────────────────

test "variant SSR anchors the branch between comment markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const on = variant(a, .{ .id = "w-x" }, "a", el(a, .p, .{ .class = "note" }, "hi"));
    try std.testing.expectEqualStrings(
        "<!--z-when:w-x--><p class=\"note\">hi</p><!--/z-when:w-x-->",
        renderStr(a, &.{on}),
    );

    // null key = empty branch: both comments and nothing between.
    const off = variant(a, .{ .id = "w-x" }, null, el(a, .p, .{}, "hi"));
    try std.testing.expectEqualStrings(
        "<!--z-when:w-x--><!--/z-when:w-x-->",
        renderStr(a, &.{off}),
    );

    // when() sugar: truthy mounts the branch, falsy mounts nothing.
    const w_on = when(a, .{ .id = "w-e" }, true, el(a, .p, .{}, "shown"));
    try std.testing.expectEqualStrings(
        "<!--z-when:w-e--><p>shown</p><!--/z-when:w-e-->",
        renderStr(a, &.{w_on}),
    );
    const w_off = when(a, .{ .id = "w-e" }, false, el(a, .p, .{}, "shown"));
    try std.testing.expectEqualStrings(
        "<!--z-when:w-e--><!--/z-when:w-e-->",
        renderStr(a, &.{w_off}),
    );
}

test "variant lid composes anchor ids inside a row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const row = el(a, .li, .{ .id = "row-3" }, .{
        variant(a, .{ .lid = "sw" }, "on", el(a, .span, .{ .lid = "tag" }, "x")),
    });
    try std.testing.expectEqualStrings(
        "<li id=\"row-3\"><!--z-when:row-3/sw--><span id=\"row-3/sw/tag\">x</span><!--/z-when:row-3/sw--></li>",
        renderStr(a, &.{row}),
    );
}

test "variant bound keys resolve lazily" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var branch = FakeStore(?[]const u8){ .v = "a" };
    const v = variant(a, .{ .id = "w-b" }, &branch, el(a, .p, .{}, "on"));
    try std.testing.expectEqualStrings(
        "<!--z-when:w-b--><p>on</p><!--/z-when:w-b-->",
        renderStr(a, &.{v}),
    );
    // Same node, mutated store: the key resolves at render time.
    branch.v = null;
    try std.testing.expectEqualStrings(
        "<!--z-when:w-b--><!--/z-when:w-b-->",
        renderStr(a, &.{v}),
    );
}

test "variant appear emits one when op and seeds branch bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    // Seed the absent-branch state (first sight records the key).
    diff(a, &.{variant(a, .{ .id = "w-f" }, null, el(a, .div, .{ .id = "in" }, "hi"))}, &dom, &log);
    log.clear();

    // Branch appears: a single when-op carries the branch markup.
    diff(a, &.{variant(a, .{ .id = "w-f" }, "on", el(a, .div, .{ .id = "in", .@"data-x" = "1" }, "hi"))}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    const w = log.patches.items[0].when;
    try std.testing.expectEqualStrings("w-f", w.id);
    try std.testing.expectEqualStrings("<div id=\"in\" data-x=\"1\">hi</div>", w.html);
    log.clear();

    // The shipped branch was seeded: only the real attr change emits.
    diff(a, &.{variant(a, .{ .id = "w-f" }, "on", el(a, .div, .{ .id = "in", .@"data-x" = "2" }, "hi"))}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try expectAttr(log.patches.items[0], "in", "data-x", "2");
}

test "variant disappear and swap ship replacement html" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    diff(a, &.{variant(a, .{ .id = "w-v" }, "a", el(a, .div, .{ .id = "va" }, "A"))}, &dom, &log);
    log.clear();

    // Branch swap A -> B: one when-op, new markup, stale state dropped.
    diff(a, &.{variant(a, .{ .id = "w-v" }, "b", el(a, .span, .{ .id = "vb" }, "B"))}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try std.testing.expectEqualStrings("w-v", log.patches.items[0].when.id);
    try std.testing.expectEqualStrings("<span id=\"vb\">B</span>", log.patches.items[0].when.html);
    log.clear();

    // Disappear: the empty branch is a when-op with "".
    diff(a, &.{variant(a, .{ .id = "w-v" }, null, el(a, .span, .{ .id = "vb" }, "B"))}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try std.testing.expectEqualStrings("", log.patches.items[0].when.html);
    log.clear();

    // Stable empty branch: nothing to emit.
    diff(a, &.{variant(a, .{ .id = "w-v" }, null, el(a, .span, .{ .id = "vb" }, "B"))}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 0), log.patches.items.len);
}

test "variant same branch recurses inner bindings without a when op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    const mk = struct {
        fn view(alloc: std.mem.Allocator, active: bool) Node {
            return variant(alloc, .{ .id = "w-s" }, "on", el(alloc, .button, .{
                .id = "b1",
                .@"data-active" = if (active) "1" else null,
            }, "x"));
        }
    }.view;

    diff(a, &.{mk(a, true)}, &dom, &log);
    log.clear();

    diff(a, &.{mk(a, false)}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try expectAttr(log.patches.items[0], "b1", "data-active", null);
}

test "nested variants diff the inner anchor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    const mk = struct {
        fn view(alloc: std.mem.Allocator, key: ?[]const u8, label: []const u8) Node {
            return variant(alloc, .{ .id = "w-o" }, "on", variant(alloc, .{ .id = "w-i" }, key, el(alloc, .em, .{}, label)));
        }
    }.view;

    // Mount: one when-op for the outer anchor; its html nests the inner markers.
    diff(a, &.{mk(a, "a", "A")}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    const outer = log.patches.items[0].when;
    try std.testing.expectEqualStrings("w-o", outer.id);
    try std.testing.expectEqualStrings(
        "<!--z-when:w-i--><em>A</em><!--/z-when:w-i-->",
        outer.html,
    );
    log.clear();

    // Outer stable, inner key flips: the recursion reaches the inner anchor.
    diff(a, &.{mk(a, "b", "B")}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    const inner = log.patches.items[0].when;
    try std.testing.expectEqualStrings("w-i", inner.id);
    try std.testing.expectEqualStrings("<em>B</em>", inner.html);
    log.clear();

    // Outer unmounts: single op; inner state is dropped and re-seeded.
    diff(a, &.{variant(a, .{ .id = "w-o" }, null, variant(a, .{ .id = "w-i" }, "b", el(a, .em, .{}, "B")))}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try std.testing.expectEqualStrings("w-o", log.patches.items[0].when.id);
    try std.testing.expectEqualStrings("", log.patches.items[0].when.html);
}

test "variant inside a keyed row seeds on create and purges on removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    const mk = struct {
        fn view(alloc: std.mem.Allocator, key: ?[]const u8) Node {
            // Rows must outlive the call — each() borrows the slice.
            const rows = alloc.alloc(Node, 1) catch @panic("OOM");
            rows[0] = el(alloc, .li, .{ .id = "row-1" }, .{
                variant(alloc, .{ .lid = "sw" }, key, el(alloc, .span, .{ .lid = "tag", .class = "t" }, "x")),
            });
            return el(alloc, .ul, .{ .id = "list" }, each(rows));
        }
    }.view;

    // Row create ships the anchored branch markup inside the row html…
    diff(a, &.{mk(a, "on")}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try std.testing.expect(log.patches.items[0] == .create);
    try std.testing.expect(std.mem.indexOf(u8, log.patches.items[0].create.html, "<!--z-when:row-1/sw-->") != null);
    // …and seeds the anchor state, so an in-place key flip diffs minimal.
    try std.testing.expect(dom.when_states.get("row-1/sw") != null);
    try std.testing.expect(dom.attrs.get("row-1/sw/tag\x00class") != null);
    log.clear();

    diff(a, &.{mk(a, "off")}, &dom, &log);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    const w = log.patches.items[0].when;
    try std.testing.expectEqualStrings("row-1/sw", w.id);
    log.clear();

    // Removing the row purges the lid-composed anchor state.
    diff(a, &.{el(a, .ul, .{ .id = "list" }, each(&.{}))}, &dom, &log);
    try std.testing.expect(dom.when_states.get("row-1/sw") == null);
    try std.testing.expect(dom.attrs.get("row-1/sw/tag\x00class") == null);
}

test "snapshot ops cover variant branches without inner ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const view = fragment(a, .{
        variant(a, .{ .id = "w-s" }, "on", el(a, .div, .{
            .id = "in",
            .@"data-x" = "1",
            .text = "body",
        }, .{})),
        variant(a, .{ .id = "w-off" }, null, el(a, .div, .{ .id = "gone" }, "x")),
    });

    var aw: std.Io.Writer.Allocating = .init(a);
    try writeSnapshotOps(a, &.{view}, &aw.writer);
    const json = aw.writer.buffered();

    // One when op per anchor; mounted branch html covers its contents.
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"op\":\"when\",\"id\":\"w-s\",\"html\":\"\\u003cdiv id=\\\"in\\\" data-x=\\\"1\\\"\\u003ebody\\u003c/div\\u003e\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"op\":\"when\",\"id\":\"w-off\",\"html\":\"\"}") != null);
    // Covered subtrees emit no inner ops.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"in\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"gone\"") == null);
}
