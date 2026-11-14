//! zmeta codegen (docs/meta-framework.md §2.1, §2.9, §5.1): scans an
//! app's `pages/` directory and `actions.zig` manifest, then emits
//! `gen/routes.zig` + `gen/actions.zig`.
//!
//! File conventions (v0):
//!
//!   pages/index.zig             → route "/"
//!   pages/about.zig             → route "/about"
//!   pages/item/[id].zig         → route "/item/:id"
//!   pages/t/[post]/index.zig    → route "/t/:post"
//!   pages/t/[post]/c/[c].zig    → route "/t/:post/c/:c"
//!   pages/tag/[tag].zig         → route "/tag/:tag" (string param)
//!   pages/docs/[...rest].zig    → route "/docs/*" (catch-all, last only)
//!   pages/_layout.zig           → root layout wrapping EVERY page
//!   pages/item/_layout.zig      → layout wrapping pages under pages/item/
//!
//! A `_layout.zig` file is NOT a route: it must export
//! `pub fn layout(a, s, env, inner: forest.Node) forest.Node` — the
//! generated view dispatch wraps each page's node with every layout
//! whose directory is the page's directory or an ancestor (root
//! `pages/_layout.zig` first/outermost). Other `_`-prefixed files are
//! rejected — underscore is reserved for framework files.
//!
//! Every page file MUST declare `pub const params = struct { ... };`
//! (empty `struct {}` for static routes) — field names must match the
//! `[name]`/`[...name]` segment names exactly and field types drive
//! the generated parser. Param types: integers (`u8`..`u128`, `usize`,
//! `i8`..`i128`, `isize`) and `[]const u8` — string params slice one
//! path segment, catch-all params slice the raw remainder ("a/b/c").
//! String slices point into the request path, so the skeleton's
//! `setRoute` hands `Deps.setRoute` a session-owned copy — stored
//! routes stay valid after the request buffer is gone.
//!
//! Optional page decls: `pub fn prepare(s, p, env) !void` (any error →
//! 404 before view work) and `pub fn view(a, s, p, env) forest.Node`
//! (required). Optional `pub const route_name = "tag"` overrides the
//! filename-derived union tag.
//!
//! actions.zig manifest: `pub const actions = .{ "ping", "like" };` —
//! each name becomes `act.<name>` (comptime-checked in `.on` attrs) and
//! a dispatch arm calling `on_<name>` on the app's Deps type.
//!
//! Usage: `zig run src/zmeta/gen.zig -- [app-dir ...]` — with no args,
//! scans `src/apps/*/` for directories containing `pages/`.
//! Deterministic: output depends only on the file tree + contents.
//!
//! This file is ALSO a library: the pure helpers below are unit-tested
//! via the `zmeta-gen` test target in build.zig.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const int_types = [_][]const u8{
    "u8", "u16", "u32", "u64", "u128", "usize",
    "i8", "i16", "i32", "i64", "i128", "isize",
};

const GenError = error{
    OutOfMemory,
    FileNotFound,
    BadParams,
    BadRouteName,
    BadSegment,
    BadAction,
    DuplicateRoute,
    DuplicateTag,
    ParamMismatch,
    ReservedFile,
};

// ─────────────────────────────────────────────
// model
// ─────────────────────────────────────────────

const Param = struct {
    name: []const u8,
    ty: []const u8,
};

const Seg = union(enum) {
    /// Literal path segment ("item", "t", "c").
    static: []const u8,
    /// `[name]` dynamic segment — `name` must be a params field.
    dynamic: []const u8,
    /// `[...name]` catch-all — LAST segment only; `name` must be a
    /// `[]const u8` params field receiving the raw remainder ("a/b/c").
    catchall: []const u8,
};

const Page = struct {
    /// Path relative to the app dir, e.g. "pages/item/[id].zig".
    rel: []const u8,
    /// Route segments derived from `rel` (trailing "index" dropped).
    segs: []const Seg,
    /// `pub const params` fields, in declaration order.
    params: []const Param,
    /// Union tag: `pub const route_name` override or derived.
    tag: []const u8,
    /// Indices into the app's layout list, outermost first — the
    /// generated view wraps `page.view` with each in turn.
    wraps: []const usize = &.{},
};

/// A `pages/**/_layout.zig` file: `dir` is its directory relative to
/// the app dir ("pages", "pages/item", ...), `id` the sanitized const
/// name used in generated imports.
const Layout = struct {
    dir: []const u8,
    rel: []const u8,
    id: []const u8,
};

// ─────────────────────────────────────────────
// entry point
// ─────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = init.minimal.args.vector;

    var app_dirs: std.ArrayList([]const u8) = .empty;
    defer app_dirs.deinit(arena);
    if (argv.len > 1) {
        for (argv[1..]) |a| {
            try app_dirs.append(arena, try arena.dupe(u8, std.mem.span(a)));
        }
    } else {
        try discoverApps(io, arena, "src/apps", &app_dirs);
    }
    std.mem.sort([]const u8, app_dirs.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    if (app_dirs.items.len == 0) {
        std.debug.print("zmeta-gen: no apps found (looked in src/apps/*/pages)\n", .{});
        return;
    }
    for (app_dirs.items) |dir| {
        std.debug.print("zmeta-gen: {s}\n", .{dir});
        try genApp(io, arena, dir);
    }
}

/// Scan `root` for subdirectories containing a `pages/` dir — the app
/// convention is `src/apps/<name>/{app.zig,pages/,actions.zig,gen/}`.
fn discoverApps(io: Io, arena: Allocator, root: []const u8, out: *std.ArrayList([]const u8)) !void {
    var d = Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const name = try arena.dupe(u8, entry.name);
        // Existence check for <root>/<name>/pages.
        const pages = try std.fmt.allocPrint(arena, "{s}/{s}/pages", .{ root, name });
        Dir.cwd().access(io, pages, .{}) catch continue;
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, name }));
    }
}

/// Generate `gen/routes.zig` + `gen/actions.zig` for one app dir.
fn genApp(io: Io, arena: Allocator, app_dir: []const u8) !void {
    const scanned = try scanPages(io, arena, app_dir);
    if (scanned.len == 0) return error.FileNotFound;

    // Partition the scan: `_layout.zig` files are layouts, other
    // `_`-prefixed files are reserved and rejected, the rest are pages.
    var page_rels: std.ArrayList([]const u8) = .empty;
    var layouts: std.ArrayList(Layout) = .empty;
    for (scanned) |rel| {
        const base = std.fs.path.basename(rel);
        if (std.mem.startsWith(u8, base, "_")) {
            if (std.mem.eql(u8, base, "_layout.zig")) {
                const dir = std.fs.path.dirname(rel).?;
                try layouts.append(arena, .{
                    .dir = dir,
                    .rel = rel,
                    .id = try layoutId(arena, dir),
                });
            } else {
                std.debug.print("zmeta-gen: {s}: '{s}' — underscore prefix is reserved for _layout.zig\n", .{ app_dir, rel });
                return error.ReservedFile;
            }
        } else {
            try page_rels.append(arena, rel);
        }
    }
    if (page_rels.items.len == 0) return error.FileNotFound;

    // Sort layouts outermost-first (shallowest dir, then lexicographic)
    // so `wraps` indices compose root → leaf.
    std.mem.sort(Layout, layouts.items, {}, struct {
        fn lt(_: void, a: Layout, b: Layout) bool {
            const da = std.mem.count(u8, a.dir, "/");
            const db = std.mem.count(u8, b.dir, "/");
            if (da != db) return da < db;
            return std.mem.order(u8, a.dir, b.dir) == .lt;
        }
    }.lt);

    var parsed = try arena.alloc(Page, page_rels.items.len);
    for (page_rels.items, 0..) |rel, i| {
        const src = try readAppFile(io, arena, app_dir, rel);
        parsed[i] = try buildPage(arena, rel, src);
        parsed[i].wraps = try pageWraps(arena, rel, layouts.items);
    }
    try checkConflicts(parsed);
    std.mem.sort(Page, parsed, {}, pageLessThan);

    const zmeta_path = try zmetaImportPath(io, arena, app_dir);
    const routes_src = try emitRoutes(arena, zmeta_path, parsed, layouts.items);
    const actions_src = try emitActions(io, arena, app_dir);

    const gen_rel = try std.fmt.allocPrint(arena, "{s}/gen", .{app_dir});
    try Dir.cwd().createDirPath(io, gen_rel);
    var gen_dir = try Dir.cwd().openDir(io, gen_rel, .{});
    defer gen_dir.close(io);
    try gen_dir.writeFile(io, .{ .sub_path = "routes.zig", .data = routes_src });
    try gen_dir.writeFile(io, .{ .sub_path = "actions.zig", .data = actions_src });
}

// ─────────────────────────────────────────────
// scanning
// ─────────────────────────────────────────────

/// Recursively collect `.zig` files under `<app_dir>/pages/` as
/// app-dir-relative paths ("pages/item/[id].zig"), sorted.
fn scanPages(io: Io, arena: Allocator, app_dir: []const u8) ![]const []const u8 {
    const pages_dir = try std.fmt.allocPrint(arena, "{s}/pages", .{app_dir});
    var dir = Dir.cwd().openDir(io, pages_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // entry.path is invalidated by the next next() — dupe now.
        try out.append(arena, try std.fmt.allocPrint(arena, "pages/{s}", .{entry.path}));
    }
    const items = out.items;
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return items;
}

fn readAppFile(io: Io, arena: Allocator, app_dir: []const u8, rel: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ app_dir, rel });
    return Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
}

/// Sanitized const name for a layout's directory: "pages" → "root",
/// "pages/item" → "item", "pages/t/[post]" → "t__post_" — always a
/// valid Zig identifier, unique per directory.
fn layoutId(arena: Allocator, dir: []const u8) GenError![]const u8 {
    const suffix = if (std.mem.eql(u8, dir, "pages")) "root" else dir["pages/".len..];
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "lay_");
    for (suffix) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try buf.append(arena, std.ascii.toLower(c));
        } else {
            try buf.append(arena, '_');
        }
    }
    return buf.items;
}

/// The directory a page file lives in, app-dir-relative:
/// "pages/index.zig" → "pages", "pages/item/[id].zig" → "pages/item".
fn pageDir(rel: []const u8) []const u8 {
    return std.fs.path.dirname(rel).?;
}

/// A layout applies to a page when the layout's directory is the
/// page's directory or an ancestor of it ("pages/item" layout wraps
/// "pages/item/[id].zig" but not "pages/index.zig"). `layouts` must
/// already be sorted outermost-first; the result keeps that order.
fn pageWraps(arena: Allocator, rel: []const u8, layouts: []const Layout) GenError![]const usize {
    const dir = pageDir(rel);
    var out: std.ArrayList(usize) = .empty;
    for (layouts, 0..) |l, i| {
        const applies = std.mem.eql(u8, dir, l.dir) or
            (dir.len > l.dir.len and std.mem.startsWith(u8, dir, l.dir) and dir[l.dir.len] == '/');
        if (applies) try out.append(arena, i);
    }
    return out.items;
}

// ─────────────────────────────────────────────
// page parsing
// ─────────────────────────────────────────────

/// Build a Page from a page file's source: route segments from the
/// path, params fields + optional route_name from the decls.
fn buildPage(arena: Allocator, rel: []const u8, src: []const u8) GenError!Page {
    const segs = try routeSegments(arena, rel);
    const params = parseParams(arena, src) orelse return error.BadParams;
    try checkParamSegments(segs, params);

    const tag = if (parseRouteName(src)) |rn| rn else try deriveTag(arena, segs);
    if (!std.zig.isValidId(tag)) return error.BadRouteName;
    return .{ .rel = rel, .segs = segs, .params = params, .tag = tag };
}

/// "pages/item/[id].zig" → segs [static "item", dynamic "id"];
/// "pages/index.zig" → [] (route "/"). A trailing "index" file stem
/// contributes no segment; "index" elsewhere is a literal segment.
fn routeSegments(arena: Allocator, rel: []const u8) GenError![]const Seg {
    if (!std.mem.startsWith(u8, rel, "pages/")) return error.BadSegment;
    if (!std.mem.endsWith(u8, rel, ".zig")) return error.BadSegment;
    var body = rel["pages/".len .. rel.len - ".zig".len];
    if (std.mem.eql(u8, body, "index")) {
        body = "";
    } else if (std.mem.endsWith(u8, body, "/index")) {
        body = body[0 .. body.len - "/index".len];
    }

    var segs: std.ArrayList(Seg) = .empty;
    if (body.len == 0) return segs.items;
    var it = std.mem.splitScalar(u8, body, '/');
    while (it.next()) |part| {
        if (part.len == 0) return error.BadSegment;
        if (part[0] == '[') {
            if (part.len < 3 or part[part.len - 1] != ']') return error.BadSegment;
            const inner = part[1 .. part.len - 1];
            if (std.mem.startsWith(u8, inner, "...")) {
                // Catch-all: last segment only, plain name after "...".
                const name = inner[3..];
                if (name.len == 0 or !std.zig.isValidId(name)) return error.BadSegment;
                if (it.next() != null) return error.BadSegment;
                segs.append(arena, .{ .catchall = name }) catch return error.OutOfMemory;
            } else {
                if (!std.zig.isValidId(inner)) return error.BadSegment;
                segs.append(arena, .{ .dynamic = inner }) catch return error.OutOfMemory;
            }
        } else {
            if (std.mem.indexOfAny(u8, part, "[]") != null) return error.BadSegment;
            segs.append(arena, .{ .static = part }) catch return error.OutOfMemory;
        }
    }
    return segs.items;
}

/// Extract `pub const params = struct { name: ty, ... };` fields.
/// Returns null when the decl is absent/malformed. v1 types: integers
/// (`[id]` segments) and `[]const u8` (string `[slug]` segments and
/// `[...rest]` catch-all remainders — slices into the session-owned
/// route path, see session.zig `setRoute`).
fn parseParams(arena: Allocator, src: []const u8) ?[]const Param {
    const decl = findDecl(src, "pub const params") orelse return null;
    var i = skipWs(src, decl);
    if (i >= src.len or src[i] != '=') return null;
    i = skipWs(src, i + 1);
    const kw = "struct";
    if (!std.mem.startsWith(u8, src[i..], kw)) return null;
    i = skipWs(src, i + kw.len);
    if (i >= src.len or src[i] != '{') return null;
    const open = i;
    // Find the matching close brace; a nested '{' means a non-flat
    // params type — unsupported in v0.
    var close: ?usize = null;
    var j = open + 1;
    while (j < src.len) : (j += 1) {
        switch (src[j]) {
            '{' => return null,
            '}' => {
                close = j;
                break;
            },
            else => {},
        }
    }
    const end = close orelse return null;
    const body = src[open + 1 .. end];

    var params: std.ArrayList(Param) = .empty;
    var fit = std.mem.splitScalar(u8, body, ',');
    while (fit.next()) |raw_field| {
        var field = std.mem.trim(u8, raw_field, " \t\r\n");
        if (std.mem.indexOf(u8, field, "//")) |cidx| field = field[0..cidx];
        field = std.mem.trim(u8, field, " \t\r\n");
        if (field.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse return null;
        const name = std.mem.trim(u8, field[0..colon], " \t");
        const ty = std.mem.trim(u8, field[colon + 1 ..], " \t");
        if (name.len == 0 or ty.len == 0) return null;
        if (std.mem.indexOfAny(u8, ty, "=,;") != null) return null; // no defaults/exprs
        if (!std.zig.isValidId(name)) return null;
        const is_int = for (int_types) |t| {
            if (std.mem.eql(u8, ty, t)) break true;
        } else false;
        const is_str = std.mem.eql(u8, ty, "[]const u8");
        if (!is_int and !is_str) return null; // flat int/string params only
        // Param names become `const <name>` bindings inside the
        // generated parseRoute — reject collisions with its locals.
        if (std.mem.eql(u8, name, "path") or
            std.mem.eql(u8, name, "segs") or
            std.mem.eql(u8, name, "n") or
            std.mem.eql(u8, name, "it") or
            std.mem.eql(u8, name, "ca_off")) return null;
        params.append(arena, .{ .name = name, .ty = ty }) catch return null;
    }
    return params.items;
}

/// `pub const route_name = "tag";` → the literal, or null.
fn parseRouteName(src: []const u8) ?[]const u8 {
    const decl = findDecl(src, "pub const route_name") orelse return null;
    var i = skipWs(src, decl);
    if (i >= src.len or src[i] != '=') return null;
    i = skipWs(src, i + 1);
    if (i >= src.len or src[i] != '"') return null;
    const start = i + 1;
    var j = start;
    while (j < src.len and src[j] != '"') : (j += 1) {
        if (src[j] == '\\') return null; // no escapes in v0
    }
    if (j >= src.len) return null;
    return src[start..j];
}

/// Find `needle` in `src` and return the index just past it.
fn findDecl(src: []const u8, needle: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, src, needle) orelse return null;
    return idx + needle.len;
}

fn skipWs(src: []const u8, i: usize) usize {
    var j = i;
    while (j < src.len and std.ascii.isWhitespace(src[j])) j += 1;
    return j;
}

/// Dynamic `[name]`/`[...name]` segments must correspond 1:1 to params
/// fields.
fn checkParamSegments(segs: []const Seg, params: []const Param) GenError!void {
    var dyn_count: usize = 0;
    for (segs) |s| {
        if (s != .static) dyn_count += 1;
    }
    if (dyn_count != params.len) return error.ParamMismatch;
    for (segs) |s| {
        const name = switch (s) {
            .dynamic, .catchall => |n| n,
            .static => continue,
        };
        var found = false;
        for (params) |p| {
            if (std.mem.eql(u8, p.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.ParamMismatch;
    }
}

/// Default tag: static segments joined with "_", or "index" for "/".
/// Dynamics contribute nothing; a catch-all contributes its param
/// name so "/docs/[...rest]" can't collide with "/docs" or
/// "/docs/[id]" tags.
fn deriveTag(arena: Allocator, segs: []const Seg) GenError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var first = true;
    for (segs) |s| {
        const name = switch (s) {
            .static => |v| v,
            .dynamic => continue,
            .catchall => |n| n,
        };
        if (!first) buf.append(arena, '_') catch return error.OutOfMemory;
        first = false;
        buf.appendSlice(arena, name) catch return error.OutOfMemory;
    }
    if (buf.items.len == 0) return "index";
    return buf.items;
}

/// Two pages may not produce the same segment shape (static segments
/// equal, dynamics in the same positions) — the parser could not tell
/// them apart. Tag names must also be unique.
fn checkConflicts(pages: []const Page) GenError!void {
    for (pages, 0..) |p, i| {
        for (pages[i + 1 ..]) |q| {
            if (sameShape(p.segs, q.segs)) {
                std.debug.print(
                    "zmeta-gen: ambiguous routes {s} and {s} — same segment shape\n",
                    .{ p.rel, q.rel },
                );
                return error.DuplicateRoute;
            }
            if (std.mem.eql(u8, p.tag, q.tag)) {
                std.debug.print(
                    "zmeta-gen: duplicate route tag '{s}': {s} and {s}\n",
                    .{ p.tag, p.rel, q.rel },
                );
                return error.DuplicateTag;
            }
        }
    }
}

fn sameShape(a: []const Seg, b: []const Seg) bool {
    if (a.len != b.len) return false;
    for (a, b) |sa, sb| {
        const same = switch (sa) {
            .static => |sv| switch (sb) {
                .static => |bv| std.mem.eql(u8, sv, bv),
                else => false,
            },
            .dynamic => sb == .dynamic,
            .catchall => sb == .catchall,
        };
        if (!same) return false;
    }
    return true;
}

/// Match precedence: at the first differing segment, static beats
/// dynamic beats catch-all; otherwise lexicographic on statics;
/// shorter routes first.
fn pageLessThan(_: void, a: Page, b: Page) bool {
    const n = @min(a.segs.len, b.segs.len);
    for (a.segs[0..n], b.segs[0..n]) |sa, sb| {
        const rank = struct {
            fn f(s: Seg) u8 {
                return switch (s) {
                    .static => 0,
                    .dynamic => 1,
                    .catchall => 2,
                };
            }
        }.f;
        const ra = rank(sa);
        const rb = rank(sb);
        if (ra != rb) return ra < rb;
        if (sa == .static) {
            const c = std.mem.order(u8, sa.static, sb.static);
            if (c != .eq) return c == .lt;
        }
    }
    return a.segs.len < b.segs.len;
}

// ─────────────────────────────────────────────
// emission: routes.zig
// ─────────────────────────────────────────────

fn emitRoutes(arena: Allocator, zmeta_path: []const u8, pages: []const Page, layouts: []const Layout) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    try w.writeAll(
        \\//! GENERATED FILE — do not edit. Regenerate with `zig build gen`
        \\//! (or `zig run src/zmeta/gen.zig -- <app-dir>`).
        \\//! Source: pages/ files + actions.zig manifest.
        \\
        \\const std = @import("std");
        \\const forest = @import("forest");
        \\const zmeta = @import("
    );
    try w.writeAll(zmeta_path);
    try w.writeAll("\");\n\n");
    for (pages) |p| {
        try w.print("const {s}_page = @import(\"../{s}\");\n", .{ p.tag, p.rel });
    }
    // Layout imports — only the ones some page actually wraps with.
    var used = std.AutoHashMap(usize, void).init(arena);
    defer used.deinit();
    for (pages) |p| {
        for (p.wraps) |wi| try used.put(wi, {});
    }
    var used_ids: std.ArrayList(usize) = .empty;
    var kit = used.keyIterator();
    while (kit.next()) |k| try used_ids.append(arena, k.*);
    std.mem.sort(usize, used_ids.items, {}, struct {
        fn lt(_: void, a: usize, b: usize) bool {
            return a < b;
        }
    }.lt);
    for (used_ids.items) |wi| {
        const l = layouts[wi];
        try w.print("const {s} = @import(\"../{s}\");\n", .{ l.id, l.rel });
    }
    try w.writeAll("\n");

    // Route union — payload is the page's declared `params` type.
    try w.writeAll(
        \\/// Typed route — one tag per page file. Dynamic `[name]`
        \\/// segments carry the page's `params` struct as payload.
        \\pub const Route = union(enum) {
        \\
    );
    for (pages) |p| {
        try w.print("    {s}: {s}_page.params,\n", .{ p.tag, p.tag });
    }
    try w.writeAll("};\n\n");

    // parseRoute
    var max_depth: usize = 0;
    for (pages) |p| max_depth = @max(max_depth, p.segs.len);
    const buf_len = @max(@as(usize, 1), max_depth);
    try w.writeAll(
        \\/// Parse a request path into a typed Route. Static segments take
        \\/// precedence over `[name]` dynamics at the same position;
        \\/// `[...name]` catch-alls match any non-empty tail. Int params
        \\/// parse as integers; `[]const u8` params slice the path —
        \\/// callers storing the route must pass session-owned memory
        \\/// (the skeleton's `setRoute` does). Returns null on any
        \\/// mismatch — the caller maps that to 404.
        \\pub fn parseRoute(path: []const u8) ?Route {
        \\
    );
    // "/" early-out: the root page's tag, or an explicit null.
    var root_tag: ?[]const u8 = null;
    for (pages) |p| {
        if (p.segs.len == 0) root_tag = p.tag;
    }
    if (root_tag) |t| {
        try w.print("    if (std.mem.eql(u8, path, \"/\")) return Route{{ .{s} = .{{}} }};\n", .{t});
    } else {
        try w.writeAll("    if (std.mem.eql(u8, path, \"/\")) return null;\n");
    }
    try w.writeAll(
        \\    if (!std.mem.startsWith(u8, path, "/")) return null;
        \\    var segs: [
    );
    try w.print("{d}", .{buf_len});
    try w.writeAll(
        \\][]const u8 = undefined;
        \\    var n: usize = 0;
        \\    var it = std.mem.splitScalar(u8, path[1..], '/');
        \\    while (it.next()) |seg| {
        \\        // Store only what fits — catch-all routes match tails
        \\        // deeper than the deepest static route, so `n` keeps
        \\        // counting past the buffer instead of bailing out.
        \\        if (n < segs.len) segs[n] = seg;
        \\        n += 1;
        \\    }
        \\    return result: {
        \\
    );
    for (pages) |p| {
        if (p.segs.len == 0) continue; // "/" handled above
        try emitRouteMatch(arena, w, p);
    }
    try w.writeAll(
        \\        break :result null;
        \\    };
        \\}
        \\
    );

    // setRoute / validPath glue — the app's Deps delegates here; `s` is
    // duck-typed (`s.deps.route` must be a `Route`).
    try w.writeAll(
        \\
        \\/// Session glue: parse + store the typed route. Deps.setRoute
        \\/// delegates here; returns false → 404.
        \\pub fn setRoute(s: anytype, path: []const u8) bool {
        \\    const r = parseRoute(path) orelse return false;
        \\    s.deps.route = r;
        \\    return true;
        \\}
        \\
        \\/// Pure route pre-check for the server's validPath hook.
        \\pub fn validPath(path: []const u8) bool {
        \\    return parseRoute(path) != null;
        \\}
        \\
    );

    // href constructors
    var any_dynamic = false;
    for (pages) |p| {
        for (p.segs) |s| {
            if (s != .static) any_dynamic = true;
        }
    }
    try w.writeAll(
        \\
        \\/// Type-safe href: `href(a, .{ .item = .{ .id = 3 } })` allocates
        \\/// the path in `a` (the render arena in views). Static routes
        \\/// return comptime literals.
        \\pub fn href(a: std.mem.Allocator, r: Route) []const u8 {
        \\
    );
    // All-static route tables never touch the arena — discard `a` so the
    // parameter isn't an unused-parameter error.
    if (!any_dynamic) try w.writeAll("    _ = a;\n");
    try w.writeAll("    return switch (r) {\n");
    for (pages) |p| {
        try emitHrefCase(arena, w, p);
    }
    try w.writeAll("    };\n}\n\n");

    // prepare dispatch — optional per-page `prepare(s, p, env)`.
    try w.writeAll(
        \\fn preparePage(comptime Page: type, s: anytype, p: anytype, env: *const zmeta.Env) !void {
        \\    if (@hasDecl(Page, "prepare")) try Page.prepare(s, p, env);
        \\}
        \\
        \\/// Route-param gate: Deps.prepare delegates here. Any page
        \\/// `prepare` error → servePage 404s before view work.
        \\pub fn prepare(s: anytype, env: *const zmeta.Env) !void {
        \\    switch (s.deps.route) {
        \\
    );
    for (pages) |p| {
        try w.print("        .{s} => |p| try preparePage({s}_page, s, p, env),\n", .{ p.tag, p.tag });
    }
    try w.writeAll(
        \\    }
        \\}
        \\
        \\/// View dispatch: Deps.view delegates here. Each page's
        \\/// `view(a, s, params, env) forest.Node` becomes one node,
        \\/// wrapped by every applicable `_layout.zig` (outermost
        \\/// first — `pages/_layout.zig` wraps all pages).
        \\pub fn viewNodes(a: std.mem.Allocator, s: anytype, env: *const zmeta.Env) []const forest.Node {
        \\    const nodes = a.alloc(forest.Node, 1) catch @panic("OOM");
        \\    nodes[0] = switch (s.deps.route) {
        \\
    );
    for (pages) |p| {
        try emitViewNodesWraps(arena, w, p, layouts);
    }
    try w.writeAll(
        \\    };
        \\    return nodes;
        \\}
        \\
    );
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// One viewNodes switch arm: `page.view(...)` wrapped by the page's
/// applicable `_layout.zig` files — innermost layout applied first, so
/// `lay_root.layout(a, s, env, lay_item.layout(a, s, env, view))`.
fn emitViewNodesWraps(arena: Allocator, w: *std.Io.Writer, p: Page, layouts: []const Layout) !void {
    var expr: std.ArrayList(u8) = .empty;
    try expr.appendSlice(arena, p.tag);
    try expr.appendSlice(arena, "_page.view(a, s, p, env)");
    var i = p.wraps.len;
    while (i > 0) {
        i -= 1;
        const lid = layouts[p.wraps[i]].id;
        var wrapped: std.ArrayList(u8) = .empty;
        try wrapped.appendSlice(arena, lid);
        try wrapped.appendSlice(arena, ".layout(a, s, env, ");
        try wrapped.appendSlice(arena, expr.items);
        try wrapped.append(arena, ')');
        expr = wrapped;
    }
    try w.print("        .{s} => |p| {s},\n", .{ p.tag, expr.items });
}

/// One route's match arm inside parseRoute's `result:` block.
fn emitRouteMatch(arena: Allocator, w: *std.Io.Writer, p: Page) !void {
    const has_catchall = p.segs.len > 0 and p.segs[p.segs.len - 1] == .catchall;
    var cond: std.ArrayList(u8) = .empty;
    try cond.appendSlice(arena, "        if (n ");
    try cond.appendSlice(arena, if (has_catchall) ">= " else "== ");
    var nb: [24]u8 = undefined;
    try cond.appendSlice(arena, std.fmt.bufPrint(&nb, "{d}", .{p.segs.len}) catch unreachable);
    for (p.segs, 0..) |s, i| {
        const name = switch (s) {
            .static => |v| v,
            .dynamic, .catchall => continue,
        };
        try cond.appendSlice(arena, " and std.mem.eql(u8, segs[");
        try cond.appendSlice(arena, std.fmt.bufPrint(&nb, "{d}", .{i}) catch unreachable);
        try cond.appendSlice(arena, "], \"");
        try cond.appendSlice(arena, name);
        try cond.appendSlice(arena, "\")");
    }
    try cond.appendSlice(arena, ") {\n");
    try w.writeAll(cond.items);

    // Dynamic params: ints parse, `[]const u8` slices the path.
    for (p.segs, 0..) |s, i| {
        const name = switch (s) {
            .dynamic => |v| v,
            .static, .catchall => continue,
        };
        const ty = paramType(p, name);
        if (std.mem.eql(u8, ty, "[]const u8")) {
            try w.print("            const {s} = segs[{d}];\n", .{ name, i });
        } else {
            try w.print(
                "            const {s} = std.fmt.parseInt({s}, segs[{d}], 10) catch break :result null;\n",
                .{ name, ty, i },
            );
        }
    }
    if (has_catchall) {
        // Remainder = path slice starting after the "/" preceding the
        // catch-all position: 1 (leading '/') + each prefix segment's
        // len + its '/' delimiter.
        const name = p.segs[p.segs.len - 1].catchall;
        const prefix = p.segs.len - 1;
        try w.print(
            \\            var ca_off: usize = 1;
            \\            for (segs[0..{d}]) |sg| ca_off += sg.len + 1;
            \\            const {s} = path[ca_off..];
            \\            if ({s}.len == 0) break :result null;
            \\
        , .{ prefix, name, name });
    }
    // Construct the payload in params-declaration order.
    try w.print("            break :result Route{{ .{s} = .{{ ", .{p.tag});
    for (p.params, 0..) |param, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print(".{s} = {s}", .{ param.name, param.name });
    }
    try w.writeAll(" } };\n        }\n");
}

fn paramType(p: Page, name: []const u8) []const u8 {
    for (p.params) |param| {
        if (std.mem.eql(u8, param.name, name)) return param.ty;
    }
    unreachable;
}

/// `.{ .tag => "/static/path", }` or an allocPrint arm for dynamics.
fn emitHrefCase(arena: Allocator, w: *std.Io.Writer, p: Page) !void {
    if (p.segs.len == 0) {
        try w.print("        .{s} => \"/\",\n", .{p.tag});
        return;
    }
    var has_dyn = false;
    for (p.segs) |s| {
        if (s != .static) has_dyn = true;
    }
    if (!has_dyn) {
        // All-static route: comptime literal path.
        var path: std.ArrayList(u8) = .empty;
        try path.append(arena, '/');
        for (p.segs, 0..) |s, i| {
            if (i != 0) try path.append(arena, '/');
            try path.appendSlice(arena, s.static);
        }
        try w.print("        .{s} => \"{s}\",\n", .{ p.tag, path.items });
        return;
    }
    // Dynamic: allocPrint — "{d}" for int params, "{s}" for
    // `[]const u8` params and catch-all remainders; args p.<name> in
    // path order.
    var fmt: std.ArrayList(u8) = .empty;
    try fmt.append(arena, '/');
    var args: std.ArrayList(u8) = .empty;
    for (p.segs, 0..) |s, i| {
        if (i != 0) try fmt.append(arena, '/');
        switch (s) {
            .static => |v| try fmt.appendSlice(arena, v),
            .dynamic => |name| {
                const verb = if (std.mem.eql(u8, paramType(p, name), "[]const u8")) "{s}" else "{d}";
                try fmt.appendSlice(arena, verb);
                if (args.items.len != 0) try args.appendSlice(arena, ", ");
                try args.appendSlice(arena, "p.");
                try args.appendSlice(arena, name);
            },
            .catchall => |name| {
                try fmt.appendSlice(arena, "{s}");
                if (args.items.len != 0) try args.appendSlice(arena, ", ");
                try args.appendSlice(arena, "p.");
                try args.appendSlice(arena, name);
            },
        }
    }
    try w.print(
        "        .{s} => |p| std.fmt.allocPrint(a, \"{s}\", .{{{s}}}) catch @panic(\"OOM\"),\n",
        .{ p.tag, fmt.items, args.items },
    );
}

// ─────────────────────────────────────────────
// emission: actions.zig
// ─────────────────────────────────────────────

fn emitActions(io: Io, arena: Allocator, app_dir: []const u8) ![]const u8 {
    const manifest_rel = try std.fmt.allocPrint(arena, "{s}/actions.zig", .{app_dir});
    const src = Dir.cwd().readFileAlloc(io, manifest_rel, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    const names = if (src) |s| try parseActionManifest(arena, s) else &.{};

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(
        \\//! GENERATED FILE — do not edit. Regenerate with `zig build gen`.
        \\//! Source: actions.zig manifest (spec §2.9 v0 name table).
        \\
        \\const std = @import("std");
        \\
        \\/// Comptime action names shared by view `.on` attrs and the
        \\/// dispatch skeleton — `act.like` in `.on = .{ .click = act.like }`
        \\/// is compile-checked; the wire stays strings.
        \\pub const act = struct {
        \\
    );
    for (names) |n| {
        try w.print("    pub const {s} = \"{s}\";\n", .{ n, n });
    }
    try w.writeAll("};\n\n");
    try w.writeAll(
        \\/// Dispatch skeleton: each whitelisted action calls the app's
        \\/// `on_<name>` decl on the Deps type (`@TypeOf(s.deps)`), with
        \\/// the same (arg, value, fields) payload the session contract
        \\/// receives. Unknown actions → error.InvalidAction.
        \\pub fn dispatch(
        \\    s: anytype,
        \\    action: []const u8,
        \\    arg: ?[]const u8,
        \\    value: ?[]const u8,
        \\    fields: ?*const std.json.ObjectMap,
        \\) !void {
        \\
    );
    if (names.len == 0) {
        // Empty manifest: no dispatch arms, so every parameter is
        // unused — discard them explicitly.
        try w.writeAll("    _ = s;\n    _ = action;\n    _ = arg;\n    _ = value;\n    _ = fields;\n");
    } else {
        try w.writeAll("    const D = @TypeOf(s.deps);\n");
        for (names) |n| {
            try w.print("    if (std.mem.eql(u8, action, act.{s})) return D.on_{s}(s, arg, value, fields);\n", .{ n, n });
        }
    }
    try w.writeAll("    return error.InvalidAction;\n}\n");
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// Parse `pub const actions = .{ "a", "b" };` → name list.
fn parseActionManifest(arena: Allocator, src: []const u8) GenError![]const []const u8 {
    const decl = findDecl(src, "pub const actions") orelse return error.BadAction;
    var i = skipWs(src, decl);
    if (i >= src.len or src[i] != '=') return error.BadAction;
    i = skipWs(src, i + 1);
    if (!std.mem.startsWith(u8, src[i..], ".{")) return error.BadAction;
    i += 2;
    var names: std.ArrayList([]const u8) = .empty;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '}' => return names.items,
            '"' => {
                const start = i + 1;
                var j = start;
                while (j < src.len and src[j] != '"') : (j += 1) {
                    if (src[j] == '\\') return error.BadAction;
                }
                if (j >= src.len) return error.BadAction;
                const name = src[start..j];
                if (!std.zig.isValidId(name)) return error.BadAction;
                names.append(arena, name) catch return error.OutOfMemory;
                i = j;
            },
            ',', ' ', '\t', '\r', '\n' => {},
            else => return error.BadAction,
        }
    }
    return error.BadAction;
}

/// Relative @import path from `<app>/gen/` to the repo's
/// `src/zmeta/root.zig`: walk app_dir's ancestors for the directory
/// containing `src/zmeta/root.zig`, then compute the ../.. path.
fn zmetaImportPath(io: Io, arena: Allocator, app_dir: []const u8) ![]const u8 {
    var dir: []const u8 = app_dir;
    var tried_cwd = false;
    while (true) {
        const candidate = try std.fmt.allocPrint(arena, "{s}/src/zmeta/root.zig", .{dir});
        Dir.cwd().access(io, candidate, .{}) catch {
            const parent = std.fs.path.dirname(dir);
            if (parent) |p| {
                dir = p;
                continue;
            }
            // Single-component relative paths have no dirname — the
            // cwd itself is the last ancestor worth trying.
            if (!tried_cwd) {
                tried_cwd = true;
                dir = ".";
                continue;
            }
            return error.FileNotFound;
        };
        // Found the repo root at `dir`. Import path is relative from
        // "<app>/gen" to "<dir>/src/zmeta/root.zig".
        const from = try std.fmt.allocPrint(arena, "{s}/gen", .{app_dir});
        const rel = try std.fs.path.relativeAlloc(arena, ".", null, from, candidate);
        return rel;
    }
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "routeSegments maps page paths to route segments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { rel: []const u8, want: []const Seg }{
        .{ .rel = "pages/index.zig", .want = &.{} },
        .{ .rel = "pages/about.zig", .want = &.{.{ .static = "about" }} },
        .{ .rel = "pages/item/[id].zig", .want = &.{ .{ .static = "item" }, .{ .dynamic = "id" } } },
        .{ .rel = "pages/t/[post]/index.zig", .want = &.{ .{ .static = "t" }, .{ .dynamic = "post" } } },
        .{ .rel = "pages/t/[post]/c/[comment].zig", .want = &.{
            .{ .static = "t" }, .{ .dynamic = "post" }, .{ .static = "c" }, .{ .dynamic = "comment" },
        } },
        .{ .rel = "pages/foo/index.zig", .want = &.{.{ .static = "foo" }} },
        .{ .rel = "pages/tag/[tag].zig", .want = &.{ .{ .static = "tag" }, .{ .dynamic = "tag" } } },
        .{ .rel = "pages/docs/[...rest].zig", .want = &.{ .{ .static = "docs" }, .{ .catchall = "rest" } } },
        .{ .rel = "pages/[...rest].zig", .want = &.{.{ .catchall = "rest" }} },
    };
    for (cases) |c| {
        const segs = try routeSegments(arena, c.rel);
        try std.testing.expectEqual(c.want.len, segs.len);
        for (c.want, segs) |w, g| {
            switch (w) {
                .static => |ws| try std.testing.expectEqualStrings(ws, g.static),
                .dynamic => |wd| try std.testing.expectEqualStrings(wd, g.dynamic),
                .catchall => |wc| try std.testing.expectEqualStrings(wc, g.catchall),
            }
        }
    }
}

test "routeSegments rejects malformed paths" {
    const arena = std.testing.allocator;
    try std.testing.expectError(error.BadSegment, routeSegments(arena, "pages/[...rest]/x.zig")); // catch-all must be last
    try std.testing.expectError(error.BadSegment, routeSegments(arena, "pages/[...].zig"));
    try std.testing.expectError(error.BadSegment, routeSegments(arena, "pages/[]/x.zig"));
    try std.testing.expectError(error.BadSegment, routeSegments(arena, "pages/a[0].zig"));
    try std.testing.expectError(error.BadSegment, routeSegments(arena, "notpages/x.zig"));
}

test "parseParams extracts flat int fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\pub const params = struct { id: u64, slug: i32 };
        \\pub fn view() void {}
    ;
    const params = parseParams(arena, src).?;
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("id", params[0].name);
    try std.testing.expectEqualStrings("u64", params[0].ty);
    try std.testing.expectEqualStrings("slug", params[1].name);
    try std.testing.expectEqualStrings("i32", params[1].ty);
}

test "parseParams accepts int and []const u8 fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src =
        \\pub const params = struct { id: u64, slug: []const u8, rest: []const u8 };
        \\pub fn view() void {}
    ;
    const params = parseParams(arena, src).?;
    try std.testing.expectEqual(@as(usize, 3), params.len);
    try std.testing.expectEqualStrings("[]const u8", params[1].ty);
}

test "parseParams rejects unsupported and nested types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(parseParams(arena, "pub const params = struct { s: []u8 };") == null);
    try std.testing.expect(parseParams(arena, "pub const params = struct { x: struct { y: u64 } };") == null);
    try std.testing.expect(parseParams(arena, "pub const view = 1;") == null);
}

test "checkParamSegments enforces segment/field bijection" {
    const segs = [_]Seg{ .{ .static = "item" }, .{ .dynamic = "id" } };
    const ok = [_]Param{.{ .name = "id", .ty = "u64" }};
    try checkParamSegments(&segs, &ok);
    const missing = [_]Param{};
    try std.testing.expectError(error.ParamMismatch, checkParamSegments(&segs, &missing));
    const wrong = [_]Param{.{ .name = "other", .ty = "u64" }};
    try std.testing.expectError(error.ParamMismatch, checkParamSegments(&segs, &wrong));
    // Catch-all counts as a dynamic field.
    const ca = [_]Seg{ .{ .static = "docs" }, .{ .catchall = "rest" } };
    const ca_ok = [_]Param{.{ .name = "rest", .ty = "[]const u8" }};
    try checkParamSegments(&ca, &ca_ok);
    try std.testing.expectError(error.ParamMismatch, checkParamSegments(&ca, &missing));
}

test "pageLessThan orders static before dynamic at first difference" {
    const a = Page{ .rel = "pages/a/[x].zig", .segs = &.{ .{ .static = "a" }, .{ .dynamic = "x" } }, .params = &.{}, .tag = "a_x" };
    const b = Page{ .rel = "pages/a/b.zig", .segs = &.{ .{ .static = "a" }, .{ .static = "b" } }, .params = &.{}, .tag = "a_b" };
    try std.testing.expect(pageLessThan({}, b, a)); // "/a/b" before "/a/:x"
    try std.testing.expect(!pageLessThan({}, a, b));
}

test "parseActionManifest extracts quoted names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = try parseActionManifest(arena, "pub const actions = .{ \"ping\", \"like_it\" };");
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("ping", names[0]);
    try std.testing.expectEqualStrings("like_it", names[1]);
    try std.testing.expectError(error.BadAction, parseActionManifest(arena, "pub const actions = .{ \"bad-name\" };"));
}

test "sameShape detects ambiguous routes" {
    const a = [_]Seg{ .{ .static = "a" }, .{ .dynamic = "x" } };
    const b = [_]Seg{ .{ .static = "a" }, .{ .dynamic = "y" } };
    const c = [_]Seg{ .{ .static = "a" }, .{ .static = "b" } };
    try std.testing.expect(sameShape(&a, &b));
    try std.testing.expect(!sameShape(&a, &c));
}

test "layoutId sanitizes layout dirs into valid const names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("lay_root", try layoutId(arena, "pages"));
    try std.testing.expectEqualStrings("lay_item", try layoutId(arena, "pages/item"));
    try std.testing.expectEqualStrings("lay_t__post_", try layoutId(arena, "pages/t/[post]"));
    for ([_][]const u8{ "pages", "pages/item", "pages/t/[post]" }) |d| {
        const id = try layoutId(arena, d);
        try std.testing.expect(std.zig.isValidId(id));
    }
}

test "pageWraps applies ancestor layouts outermost-first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layouts = [_]Layout{
        .{ .dir = "pages", .rel = "pages/_layout.zig", .id = "lay_root" },
        .{ .dir = "pages/item", .rel = "pages/item/_layout.zig", .id = "lay_item" },
        .{ .dir = "pages/other", .rel = "pages/other/_layout.zig", .id = "lay_other" },
    };
    // Root page: only the root layout.
    const idx = try pageWraps(arena, "pages/index.zig", &layouts);
    try std.testing.expectEqual(@as(usize, 1), idx.len);
    try std.testing.expectEqual(@as(usize, 0), idx[0]);
    // Nested page: root + its own dir layout, root first.
    const item = try pageWraps(arena, "pages/item/[id].zig", &layouts);
    try std.testing.expectEqual(@as(usize, 2), item.len);
    try std.testing.expectEqual(@as(usize, 0), item[0]);
    try std.testing.expectEqual(@as(usize, 1), item[1]);
    // Deeper page under item/: same two layouts.
    const deep = try pageWraps(arena, "pages/item/sub/x.zig", &layouts);
    try std.testing.expectEqual(@as(usize, 2), deep.len);
    // Sibling dir: root + other, NOT item.
    const other = try pageWraps(arena, "pages/other/y.zig", &layouts);
    try std.testing.expectEqual(@as(usize, 2), other.len);
    try std.testing.expectEqual(@as(usize, 2), other[1]);
    // Boundary: "pages/item2" must not match "pages/item".
    const boundary = try pageWraps(arena, "pages/item2/z.zig", &layouts);
    try std.testing.expectEqual(@as(usize, 1), boundary.len);
}
