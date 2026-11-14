//! zsx — `.zsx` template → `forest.el` Zig transpiler (spike,
//! docs/zsx-spike.md). Plain source like the rest of `zmeta/` — no
//! named module; the CLI is `zig run src/zmeta/zsx.zig -- [app-dir ...]`
//! or `zig build zsx` / `zig build zsx-check`.
//!
//! Input convention: `<app-dir>/templates/**/*.zsx`, one root element
//! per file. Output: `<app-dir>/gen/<same-rel>.zig` exposing
//! `pub fn render(a: std.mem.Allocator, ctx: anytype) forest.Node`.
//! Generated files are checked in (same convention as `zmeta/gen.zig`).
//!
//! Grammar (fixed spike scope — see docs/zsx-spike.md for the full spec):
//!
//!   <tag attr="lit" attr={zig_expr} on:click={expr} arg={expr}
//!        id={expr} lid={expr} text={expr}>children</tag>
//!   <tag ... />                        self-closing (required for voids)
//!
//!   children: nested elements, literal text, and `{expr}`
//!   holes that pass through UNWRAPPED — a hole may evaluate to a
//!   `forest.Node`, or (as the element's sole child) any operand
//!   `forest.el` accepts, including a keyed `Children` from `eachOf`.
//!   Holes in multi-child position must therefore yield `forest.Node`
//!   (tuple children are `Node`-typed) — write `{forest.text(" … ")}`
//!   for dynamic text there.
//!
//!   Text is verbatim: whitespace-only runs containing a newline are
//!   dropped as formatting indentation; everything else — including
//!   same-line spaces — becomes a `forest.text` node. There is no
//!   entity decoding and no whitespace collapsing.
//!
//!   `on:<ev>` merges into one `.on = .{ .<ev> = expr }` field placed
//!   at the first `on:*` attribute's position; `<ev>` is checked
//!   against forest's DOM-event whitelist at gen time.
//!
//!   `{...}` boundaries are Zig-aware: nested `{}()[]`, string and
//!   char literals (with escapes), `//` comments and `\\` multiline
//!   strings are all balanced correctly. Diagnostics are
//!   `file.zsx:line:col: message`.
//!
//! NOT supported (rejected or documented as out of scope): spread
//! attrs, components, HTML error recovery, markup inside Zig
//! expressions, loops/conditionals in templates (use `forest.when`/
//! `variant`/`eachOf` nodes passed as holes), entities, `<!…>`
//! declarations, template comments.
//!
//! This file is ALSO a library: `generateFile`/`parseTemplate` are
//! unit-tested via the `zsx` test target in build.zig.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

// ─────────────────────────────────────────────
// model
// ─────────────────────────────────────────────

/// One parse/emit failure with a template position. `msg` is
/// arena-allocated; callers print before freeing the arena.
pub const Diag = struct {
    line: usize,
    col: usize,
    msg: []const u8,
};

/// `generateFile` result: generated Zig source, or a positioned diag.
pub const Outcome = union(enum) {
    src: []const u8,
    diag: Diag,
};

const AttrKind = enum { plain, on, arg, id, lid, text };

const Attr = struct {
    /// Source name (`class`, `data-x`, `for`, …) — for `.on`, the event.
    name: []const u8,
    kind: AttrKind,
    /// Quoted literal contents (Zig-escaped at emit), or null.
    lit: ?[]const u8 = null,
    /// `{...}` hole contents, trimmed (emitted verbatim), or null.
    expr: ?[]const u8 = null,
    line: usize,
    col: usize,
};

const TNode = union(enum) {
    /// Literal text — emitted as `forest.text("…")`.
    text: []const u8,
    /// `{expr}` child hole — emitted verbatim.
    hole: []const u8,
    elem: *Elem,
};

const Elem = struct {
    tag: []const u8,
    attrs: []Attr,
    children: []const TNode,
    self_close: bool,
    line: usize,
    col: usize,
};

// ─────────────────────────────────────────────
// tag / event whitelists (mirrors of forest.view's Tag + dom_events)
// ─────────────────────────────────────────────

const tags = [_][]const u8{
    "a",        "area",     "base",    "body",    "br",     "button", "col",
    "details",  "div",      "em",      "embed",   "footer", "form",   "h1",
    "h2",       "h3",       "head",    "hr",      "html",   "img",    "input",
    "label",    "li",       "link",    "main",    "meta",   "option", "p",
    "pre",      "polyline", "script",  "section", "select", "source", "span",
    "strong",   "style",    "summary", "svg",     "table",  "tbody",  "td",
    "textarea", "th",       "thead",   "title",   "tr",     "track",  "ul",
    "wbr",
};

fn isTag(name: []const u8) bool {
    for (tags) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

fn isVoid(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "area") or
        std.mem.eql(u8, tag, "base") or
        std.mem.eql(u8, tag, "br") or
        std.mem.eql(u8, tag, "col") or
        std.mem.eql(u8, tag, "embed") or
        std.mem.eql(u8, tag, "hr") or
        std.mem.eql(u8, tag, "img") or
        std.mem.eql(u8, tag, "input") or
        std.mem.eql(u8, tag, "link") or
        std.mem.eql(u8, tag, "meta") or
        std.mem.eql(u8, tag, "source") or
        std.mem.eql(u8, tag, "track") or
        std.mem.eql(u8, tag, "wbr");
}

/// forest.view's comptime `.on` whitelist (view.zig `dom_events`).
const dom_events = [_][]const u8{ "click", "dblclick", "change", "input", "submit", "keydown" };

fn isDomEvent(name: []const u8) bool {
    for (dom_events) |e| {
        if (std.mem.eql(u8, e, name)) return true;
    }
    return false;
}

// ─────────────────────────────────────────────
// entry points
// ─────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = init.minimal.args.vector;

    var check = false;
    var app_dirs: std.ArrayList([]const u8) = .empty;
    defer app_dirs.deinit(arena);
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, std.mem.span(arg), "--check")) {
            check = true;
        } else {
            try app_dirs.append(arena, try arena.dupe(u8, std.mem.span(arg)));
        }
    }
    if (app_dirs.items.len == 0) {
        try discoverApps(io, arena, "src/apps", &app_dirs);
    }
    std.mem.sort([]const u8, app_dirs.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    if (app_dirs.items.len == 0) {
        std.debug.print("zsx: no apps found (looked in src/apps/*/templates)\n", .{});
        return;
    }

    var stale: usize = 0;
    for (app_dirs.items) |dir| {
        std.debug.print("zsx: {s}\n", .{dir});
        stale += try genApp(io, arena, dir, check);
    }
    if (check and stale != 0) {
        std.debug.print("zsx: {d} file(s) stale or missing — run `zig build zsx`\n", .{stale});
        std.process.exit(1);
    }
}

/// Scan `root` for subdirectories containing a `templates/` dir.
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
        const templates = try std.fmt.allocPrint(arena, "{s}/{s}/templates", .{ root, name });
        Dir.cwd().access(io, templates, .{}) catch continue;
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, name }));
    }
}

/// Generate `gen/**.zig` for every `templates/**.zsx` under one app
/// dir. Returns the number of stale/missing files in check mode.
fn genApp(io: Io, arena: Allocator, app_dir: []const u8, check: bool) !usize {
    const templates = try scanTemplates(io, arena, app_dir);
    if (templates.len == 0) return 0;

    const gen_rel = try std.fmt.allocPrint(arena, "{s}/gen", .{app_dir});
    try Dir.cwd().createDirPath(io, gen_rel);

    var stale: usize = 0;
    var expected: std.ArrayList([]const u8) = .empty;
    for (templates) |rel| {
        const src_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ app_dir, rel });
        const text = try Dir.cwd().readFileAlloc(io, src_path, arena, .limited(1 << 20));
        const outcome = generateFile(arena, text, rel);
        // rel is "templates/x/y.zsx" → out "gen/x/y.zig".
        const out_rel = try std.fmt.allocPrint(
            arena,
            "{s}/gen/{s}.zig",
            .{ app_dir, rel["templates/".len .. rel.len - ".zsx".len] },
        );
        switch (outcome) {
            .diag => |d| {
                std.debug.print("zsx: {s}:{d}:{d}: {s}\n", .{ rel, d.line, d.col, d.msg });
                return error.ParseFailed;
            },
            .src => |gen_src| {
                if (check) {
                    const existing = Dir.cwd().readFileAlloc(io, out_rel, arena, .limited(4 << 20)) catch null;
                    if (existing == null or !std.mem.eql(u8, existing.?, gen_src)) {
                        std.debug.print("zsx: stale {s}\n", .{out_rel});
                        stale += 1;
                    }
                } else {
                    const sub = std.fs.path.dirname(out_rel).?;
                    try Dir.cwd().createDirPath(io, sub);
                    var f = try Dir.cwd().createFile(io, out_rel, .{});
                    defer f.close(io);
                    try f.writeStreamingAll(io, gen_src);
                }
                try expected.append(arena, out_rel);
            },
        }
    }

    if (check) {
        // Orphan check: gen/*.zig files with no .zsx source.
        var orphans: usize = 0;
        var gen_dir = try Dir.cwd().openDir(io, gen_rel, .{ .iterate = true });
        defer gen_dir.close(io);
        var walker = try gen_dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ gen_rel, entry.path });
            var found = false;
            for (expected.items) |e| {
                if (std.mem.eql(u8, e, full)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print("zsx: orphan {s} (no .zsx source)\n", .{full});
                orphans += 1;
            }
        }
        stale += orphans;
    }
    return stale;
}

/// Collect `.zsx` files under `<app_dir>/templates/` as app-dir-relative
/// paths ("templates/x.zsx"), sorted — same walk convention as gen.zig.
fn scanTemplates(io: Io, arena: Allocator, app_dir: []const u8) ![]const []const u8 {
    const t_dir = try std.fmt.allocPrint(arena, "{s}/templates", .{app_dir});
    var dir = Dir.cwd().openDir(io, t_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zsx")) continue;
        try out.append(arena, try std.fmt.allocPrint(arena, "templates/{s}", .{entry.path}));
    }
    const items = out.items;
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return items;
}

// ─────────────────────────────────────────────
// generate: parse + emit
// ─────────────────────────────────────────────

/// Parse one `.zsx` source and emit the generated Zig file. `rel` is
/// the app-dir-relative template path ("templates/x.zsx") used in the
/// generated header comment.
pub fn generateFile(arena: Allocator, src: []const u8, rel: []const u8) Outcome {
    var p = Parser{ .src = src, .arena = arena };
    const root = p.parseTemplate() catch |err| switch (err) {
        error.Parse => return .{ .diag = p.diag.? },
    };
    return .{ .src = emitFile(arena, rel, root) };
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: Allocator,
    diag: ?Diag = null,

    fn eof(p: *Parser) bool {
        return p.pos >= p.src.len;
    }

    fn peek(p: *Parser) u8 {
        return if (p.eof()) 0 else p.src[p.pos];
    }

    fn lineCol(src: []const u8, pos: usize) struct { line: usize, col: usize } {
        var line: usize = 1;
        var col: usize = 1;
        var i: usize = 0;
        while (i < pos and i < src.len) : (i += 1) {
            if (src[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }

    fn fail(p: *Parser, at: usize, comptime fmt: []const u8, args: anytype) error{Parse} {
        const lc = lineCol(p.src, at);
        p.diag = .{
            .line = lc.line,
            .col = lc.col,
            .msg = std.fmt.allocPrint(p.arena, fmt, args) catch @panic("OOM"),
        };
        return error.Parse;
    }

    fn skipWs(p: *Parser) void {
        while (!p.eof() and std.ascii.isWhitespace(p.src[p.pos])) p.pos += 1;
    }

    fn parseTemplate(p: *Parser) error{Parse}!*Elem {
        p.skipWs();
        if (p.eof() or p.peek() != '<') {
            return p.fail(p.pos, "expected a root element '<tag …>'", .{});
        }
        const root = try p.parseElement();
        p.skipWs();
        if (!p.eof()) {
            return p.fail(p.pos, "unexpected content after the root element", .{});
        }
        return root;
    }

    fn isNameStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn isNameChar(c: u8) bool {
        return isNameStart(c) or (c >= '0' and c <= '9');
    }

    /// `<tag attrs>children</tag>` or `<tag attrs />`. `p.pos` is at '<'.
    fn parseElement(p: *Parser) error{Parse}!*Elem {
        const start = p.pos;
        const lc = lineCol(p.src, start);
        p.pos += 1; // '<'
        const name_start = p.pos;
        while (!p.eof() and isNameChar(p.peek())) p.pos += 1;
        const tag = p.src[name_start..p.pos];
        if (tag.len == 0 or !isNameStart(tag[0])) {
            return p.fail(start, "expected a tag name after '<'", .{});
        }
        if (!isTag(tag)) {
            return p.fail(start, "unknown tag '<{s}>' — not a forest.Tag member", .{tag});
        }

        var attrs: std.ArrayList(Attr) = .empty;
        var self_close = false;
        attrs_loop: while (true) {
            p.skipWs();
            if (p.eof()) {
                return p.fail(start, "unclosed tag '<{s}>' — expected '>'", .{tag});
            }
            switch (p.peek()) {
                '>' => {
                    p.pos += 1;
                    break :attrs_loop;
                },
                '/' => {
                    p.pos += 1;
                    p.skipWs();
                    if (p.eof() or p.peek() != '>') {
                        return p.fail(p.pos, "expected '>' after '/' in self-closing tag", .{});
                    }
                    p.pos += 1;
                    self_close = true;
                    break :attrs_loop;
                },
                else => attrs.append(p.arena, try p.parseAttr()) catch @panic("OOM"),
            }
        }

        if (isVoid(tag) and !self_close) {
            return p.fail(start, "void element <{s}> must self-close — write '<{s} … />'", .{ tag, tag });
        }
        const children = if (self_close) &.{} else try p.parseChildren(tag, start);
        const e = p.arena.create(Elem) catch @panic("OOM");
        e.* = .{
            .tag = tag,
            .attrs = attrs.items,
            .children = children,
            .self_close = self_close,
            .line = lc.line,
            .col = lc.col,
        };
        return e;
    }

    /// Children of an open element up to the matching `</tag>`.
    /// `close_at` is the open tag's '<' position for diagnostics.
    fn parseChildren(p: *Parser, tag: []const u8, close_at: usize) error{Parse}![]TNode {
        var out: std.ArrayList(TNode) = .empty;
        while (true) {
            if (p.eof()) {
                return p.fail(close_at, "unclosed <{s}> — expected </{s}>", .{ tag, tag });
            }
            const c = p.peek();
            if (c == '<') {
                if (p.pos + 1 < p.src.len and p.src[p.pos + 1] == '/') {
                    try p.parseCloseTag(tag, close_at);
                    return out.items;
                }
                const next = if (p.pos + 1 < p.src.len) p.src[p.pos + 1] else 0;
                if (next != 0 and isNameStart(next)) {
                    out.append(p.arena, .{ .elem = try p.parseElement() }) catch @panic("OOM");
                    continue;
                }
                return p.fail(p.pos, "unexpected '<' — literal angle brackets need a {{expr}} hole or forest.raw", .{});
            }
            if (c == '{') {
                const expr = try p.scanExpr();
                out.append(p.arena, .{ .hole = expr }) catch @panic("OOM");
                continue;
            }
            // Literal text: run to the next '<' or '{'. Whitespace-only
            // runs containing a newline are formatting indentation and
            // are dropped; same-line whitespace (" ") is REAL text —
            // forest has no CSS-collapse, so it must survive verbatim.
            const tstart = p.pos;
            while (!p.eof() and p.peek() != '<' and p.peek() != '{') p.pos += 1;
            const raw = p.src[tstart..p.pos];
            const ws_only = std.mem.trim(u8, raw, " \t\r\n").len == 0;
            const has_nl = std.mem.indexOfScalar(u8, raw, '\n') != null;
            if (!(ws_only and has_nl)) {
                out.append(p.arena, .{ .text = raw }) catch @panic("OOM");
            }
        }
    }

    /// `</name >` — validates the name matches the open tag.
    fn parseCloseTag(p: *Parser, want: []const u8, open_at: usize) error{Parse}!void {
        p.pos += 2; // '</'
        const ns = p.pos;
        while (!p.eof() and isNameChar(p.peek())) p.pos += 1;
        const name = p.src[ns..p.pos];
        p.skipWs();
        if (p.eof() or p.peek() != '>') {
            return p.fail(p.pos, "malformed closing tag '</{s}'", .{name});
        }
        p.pos += 1;
        if (!std.mem.eql(u8, name, want)) {
            _ = open_at;
            return p.fail(ns, "mismatched close tag — expected </{s}>, found </{s}>", .{ want, name });
        }
    }

    /// `name=value` inside a tag. `p.pos` is at the name start.
    fn parseAttr(p: *Parser) error{Parse}!Attr {
        const lc = lineCol(p.src, p.pos);
        const ns = p.pos;
        while (!p.eof()) : (p.pos += 1) {
            const c = p.peek();
            if (c == '=' or c == '>' or c == '/' or c == '<' or c == '{' or
                c == '"' or std.ascii.isWhitespace(c)) break;
        }
        const name = p.src[ns..p.pos];
        if (name.len == 0) {
            return p.fail(p.pos, "expected an attribute name", .{});
        }
        p.skipWs();
        if (p.eof() or p.peek() != '=') {
            return p.fail(p.pos, "expected '=' after attribute '{s}'", .{name});
        }
        p.pos += 1;
        p.skipWs();
        if (p.eof()) {
            return p.fail(p.pos, "unterminated attribute '{s}'", .{name});
        }

        var kind: AttrKind = .plain;
        var event: []const u8 = "";
        if (std.mem.startsWith(u8, name, "on:")) {
            event = name["on:".len..];
            if (event.len == 0 or !isDomEvent(event)) {
                return p.fail(ns, "unknown event '{s}' in on:{s} — forest allows {s}", .{
                    event, event, "click/dblclick/change/input/submit/keydown",
                });
            }
            kind = .on;
        } else if (std.mem.eql(u8, name, "on")) {
            return p.fail(ns, "attribute 'on' needs a form: on:<event>={{expr}}", .{});
        } else if (std.mem.eql(u8, name, "arg")) {
            kind = .arg;
        } else if (std.mem.eql(u8, name, "id")) {
            kind = .id;
        } else if (std.mem.eql(u8, name, "lid")) {
            kind = .lid;
        } else if (std.mem.eql(u8, name, "text")) {
            kind = .text;
        }

        var lit: ?[]const u8 = null;
        var expr: ?[]const u8 = null;
        switch (p.peek()) {
            '"' => {
                p.pos += 1;
                const vs = p.pos;
                while (!p.eof() and p.peek() != '"') p.pos += 1;
                if (p.eof()) {
                    return p.fail(ns, "unterminated string in attribute '{s}'", .{name});
                }
                lit = p.src[vs..p.pos];
                p.pos += 1;
            },
            '{' => expr = try p.scanExpr(),
            else => return p.fail(p.pos, "attribute '{s}' needs a quoted value or {{expr}}", .{name}),
        }
        return .{
            .name = if (kind == .on) event else name,
            .kind = kind,
            .lit = lit,
            .expr = expr,
            .line = lc.line,
            .col = lc.col,
        };
    }

    /// `{expr}` — `p.pos` is at '{'. Returns the trimmed inner source and
    /// leaves `p.pos` just past the matching '}'. Zig-aware: nested
    /// delimiters, strings, char literals, // comments and \\ lines.
    fn scanExpr(p: *Parser) error{Parse}![]const u8 {
        const open = p.pos;
        var closers = std.ArrayList(u8).empty;
        closers.append(p.arena, '}') catch @panic("OOM");
        p.pos += 1;
        while (!p.eof()) {
            const c = p.peek();
            switch (c) {
                '"' => try p.skipString(),
                '\'' => try p.skipCharLit(),
                '/' => {
                    if (p.pos + 1 < p.src.len and p.src[p.pos + 1] == '/') {
                        p.skipLine();
                    } else {
                        p.pos += 1;
                    }
                },
                '\\' => {
                    if (p.pos + 1 < p.src.len and p.src[p.pos + 1] == '\\') {
                        p.skipLine(); // Zig multiline-string line
                    } else {
                        p.pos += 1;
                    }
                },
                '{', '[', '(' => {
                    closers.append(p.arena, switch (c) {
                        '{' => '}',
                        '[' => ']',
                        else => ')',
                    }) catch @panic("OOM");
                    p.pos += 1;
                },
                '}', ']', ')' => {
                    const want = closers.items[closers.items.len - 1];
                    if (c != want) {
                        return p.fail(p.pos, "mismatched delimiter '{c}' in {{…}} expression (expected '{c}')", .{ c, want });
                    }
                    _ = closers.pop();
                    p.pos += 1;
                    if (closers.items.len == 0) {
                        return std.mem.trim(u8, p.src[open + 1 .. p.pos - 1], " \t\r\n");
                    }
                },
                else => p.pos += 1,
            }
        }
        return p.fail(open, "unterminated '{{' — missing '}}' (watch for strings/comments inside the expression)", .{});
    }

    fn skipLine(p: *Parser) void {
        while (!p.eof() and p.peek() != '\n') p.pos += 1;
    }

    /// `"…"` — escapes honored; raw newlines tolerated (Zig rejects them
    /// later, the scanner only needs the boundary).
    fn skipString(p: *Parser) error{Parse}!void {
        p.pos += 1;
        while (!p.eof()) {
            const c = p.peek();
            if (c == '\\') {
                p.pos += 2;
            } else if (c == '"') {
                p.pos += 1;
                return;
            } else {
                p.pos += 1;
            }
        }
        return p.fail(p.pos, "unterminated string literal inside {{…}}", .{});
    }

    /// `'x'` char literal — escapes honored.
    fn skipCharLit(p: *Parser) error{Parse}!void {
        p.pos += 1;
        while (!p.eof()) {
            const c = p.peek();
            if (c == '\\') {
                p.pos += 2;
            } else if (c == '\'') {
                p.pos += 1;
                return;
            } else {
                p.pos += 1;
            }
        }
        return p.fail(p.pos, "unterminated char literal inside {{…}}", .{});
    }
};

// ─────────────────────────────────────────────
// emit
// ─────────────────────────────────────────────

fn emitFile(arena: Allocator, rel: []const u8, root: *Elem) []const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll(
        \\//! GENERATED FILE — do not edit. Regenerate with `zig build zsx`
        \\//! (src/zmeta/zsx.zig). Source: 
    ) catch @panic("OOM");
    w.writeAll(rel) catch @panic("OOM");
    w.writeAll(
        \\
        \\const std = @import("std");
        \\const forest = @import("forest");
        \\
        \\/// `
    ) catch @panic("OOM");
    w.writeAll(rel) catch @panic("OOM");
    w.writeAll(
        \\` — `a` is the render arena; `ctx` is the view model
        \\/// (anytype: field accesses and calls inside {…} holes resolve
        \\/// per call site — `a`, `ctx`, `std` and `forest` are in scope).
        \\pub fn render(a: std.mem.Allocator, ctx: anytype) forest.Node {
        \\    return 
    ) catch @panic("OOM");
    emitElem(w, root, 1);
    w.writeAll(";\n}\n") catch @panic("OOM");
    return out.toOwnedSlice() catch @panic("OOM");
}

fn emitIndent(w: *std.Io.Writer, depth: usize) void {
    for (0..depth) |_| w.writeAll("    ") catch @panic("OOM");
}

/// `"…"` Zig string literal with escapes.
fn writeZigString(w: *std.Io.Writer, s: []const u8) void {
    w.writeByte('"') catch @panic("OOM");
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch @panic("OOM"),
            '\\' => w.writeAll("\\\\") catch @panic("OOM"),
            '\n' => w.writeAll("\\n") catch @panic("OOM"),
            '\r' => w.writeAll("\\r") catch @panic("OOM"),
            '\t' => w.writeAll("\\t") catch @panic("OOM"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                w.writeAll("\\x") catch @panic("OOM");
                const digs = "0123456789abcdef";
                w.writeByte(digs[c >> 4]) catch @panic("OOM");
                w.writeByte(digs[c & 0xf]) catch @panic("OOM");
            },
            else => w.writeByte(c) catch @panic("OOM"),
        }
    }
    w.writeByte('"') catch @panic("OOM");
}

/// The anonymous-struct field name for a plain attribute: bare when it
/// is a valid non-keyword Zig identifier, else `@"…"` (covers `for`,
/// `data-*`, `aria-*`).
fn writeFieldName(w: *std.Io.Writer, name: []const u8) void {
    if (std.zig.isValidId(name)) {
        w.writeAll(name) catch @panic("OOM");
    } else {
        w.writeAll("@\"") catch @panic("OOM");
        w.writeAll(name) catch @panic("OOM");
        w.writeByte('"') catch @panic("OOM");
    }
}

fn attrValue(w: *std.Io.Writer, at: Attr) void {
    if (at.lit) |s| {
        writeZigString(w, s);
    } else {
        w.writeAll(at.expr.?) catch @panic("OOM");
    }
}

fn emitNode(w: *std.Io.Writer, n: TNode, depth: usize) void {
    switch (n) {
        .text => |s| {
            w.writeAll("forest.text(") catch @panic("OOM");
            writeZigString(w, s);
            w.writeByte(')') catch @panic("OOM");
        },
        .hole => |expr| w.writeAll(expr) catch @panic("OOM"),
        .elem => |e| emitElem(w, e, depth),
    }
}

fn emitElem(w: *std.Io.Writer, e: *Elem, depth: usize) void {
    w.writeAll("forest.el(a, .") catch @panic("OOM");
    w.writeAll(e.tag) catch @panic("OOM");
    w.writeAll(", .{") catch @panic("OOM");

    // `.on = .{ .<ev> = … }` merges every on:* attr; it is emitted at
    // the position of the FIRST on:* attribute (deterministic order).
    var first_on: ?usize = null;
    for (e.attrs, 0..) |at, i| {
        if (at.kind == .on and first_on == null) first_on = i;
    }
    if (e.attrs.len == 0) {
        w.writeAll("}") catch @panic("OOM");
    } else {
        w.writeByte('\n') catch @panic("OOM");
        for (e.attrs, 0..) |at, i| {
            if (at.kind == .on and i != first_on.?) continue;
            emitIndent(w, depth + 1);
            switch (at.kind) {
                .plain => {
                    w.writeByte('.') catch @panic("OOM");
                    writeFieldName(w, at.name);
                    w.writeAll(" = ") catch @panic("OOM");
                    attrValue(w, at);
                    w.writeByte(',') catch @panic("OOM");
                },
                .on => {
                    w.writeAll(".on = .{") catch @panic("OOM");
                    for (e.attrs) |ev_at| {
                        if (ev_at.kind != .on) continue;
                        w.writeAll(" .") catch @panic("OOM");
                        w.writeAll(ev_at.name) catch @panic("OOM");
                        w.writeAll(" = ") catch @panic("OOM");
                        attrValue(w, ev_at);
                    }
                    w.writeAll(" },") catch @panic("OOM");
                },
                .arg, .id, .lid, .text => {
                    w.writeAll(".") catch @panic("OOM");
                    w.writeAll(specialField(at.kind)) catch @panic("OOM");
                    w.writeAll(" = ") catch @panic("OOM");
                    attrValue(w, at);
                    w.writeByte(',') catch @panic("OOM");
                },
            }
            w.writeByte('\n') catch @panic("OOM");
        }
        emitIndent(w, depth);
        w.writeByte('}') catch @panic("OOM");
    }

    w.writeAll(", ") catch @panic("OOM");
    emitChildren(w, e.children, depth);
    w.writeByte(')') catch @panic("OOM");
}

fn specialField(k: AttrKind) []const u8 {
    return switch (k) {
        .arg => "arg",
        .id => "id",
        .lid => "lid",
        .text => "text",
        else => unreachable,
    };
}

/// The `children` operand of `forest.el`: `.{}` empty, a single child
/// passed directly (Node or any el-children operand — keyed `Children`
/// included), or a `.{…}` tuple of Nodes.
fn emitChildren(w: *std.Io.Writer, kids: []const TNode, depth: usize) void {
    switch (kids.len) {
        0 => w.writeAll(".{}") catch @panic("OOM"),
        1 => emitNode(w, kids[0], depth),
        else => {
            w.writeAll(".{\n") catch @panic("OOM");
            for (kids) |k| {
                emitIndent(w, depth + 1);
                emitNode(w, k, depth + 1);
                w.writeAll(",\n") catch @panic("OOM");
            }
            emitIndent(w, depth);
            w.writeByte('}') catch @panic("OOM");
        },
    }
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "generateFile emits forest.el calls for a simple template" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const outcome = generateFile(arena,
        \\<div class="card" id={ctx.id}><span>hi</span>{ctx.tail}</div>
    , "templates/x.zsx");
    const src = switch (outcome) {
        .src => |s| s,
        .diag => |d| {
            std.debug.print("unexpected diag: {d}:{d}: {s}\n", .{ d.line, d.col, d.msg });
            return error.TestUnexpectedResult;
        },
    };
    try std.testing.expect(std.mem.indexOf(u8, src, "forest.el(a, .div, .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".class = \"card\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".id = ctx.id,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "forest.el(a, .span") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "forest.text(\"hi\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "ctx.tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn render(a: std.mem.Allocator, ctx: anytype) forest.Node") != null);
}

test "on:* attrs merge into one .on field; specials map to bindings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const outcome = generateFile(arena,
        \\<button class="b" on:click={ctx.a} arg={ctx.n} lid="x" text={ctx.t} on:input={ctx.b} />
    , "templates/x.zsx");
    const src = switch (outcome) {
        .src => |s| s,
        .diag => return error.TestUnexpectedResult,
    };
    // One merged .on with both events; specials become .arg/.lid/.text.
    try std.testing.expect(std.mem.indexOf(u8, src, ".on = .{ .click = ctx.a .input = ctx.b },") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".arg = ctx.n,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".lid = \"x\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".text = ctx.t,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".@\"for\"") == null); // sanity
}

test "quoted attr names that need it emit @\"name\"" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = generateFile(arena, "<label for={ctx.f} data-x=\"1\">l</label>", "templates/x.zsx");
    const src = switch (outcome) {
        .src => |s| s,
        .diag => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.indexOf(u8, src, ".@\"for\" = ctx.f,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".@\"data-x\" = \"1\",") != null);
}

test "brace scanner handles nested delimiters, strings, comments, char lits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = generateFile(arena,
        \\<div>{foo(.{ .x = "}" }, '}', // } in comment
        \\  "multiline } string"
        \\  , bar[{1}] )}</div>
    , "templates/x.zsx");
    switch (outcome) {
        .src => |s| try std.testing.expect(std.mem.indexOf(u8, s, "foo(.{ .x = \"}\" }, '}',") != null),
        .diag => |d| {
            std.debug.print("unexpected diag: {d}:{d}: {s}\n", .{ d.line, d.col, d.msg });
            return error.TestUnexpectedResult;
        },
    }
}

test "unknown tag is a positioned diag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = generateFile(arena, "<blink>x</blink>", "templates/x.zsx");
    switch (outcome) {
        .diag => |d| {
            try std.testing.expectEqual(@as(usize, 1), d.line);
            try std.testing.expect(std.mem.indexOf(u8, d.msg, "unknown tag") != null);
        },
        .src => return error.TestUnexpectedResult,
    }
}

test "mismatched close tag reports both names and position" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = generateFile(arena, "<div>\n  <span>x</div>\n", "templates/x.zsx");
    switch (outcome) {
        .diag => |d| {
            try std.testing.expectEqual(@as(usize, 2), d.line);
            try std.testing.expect(std.mem.indexOf(u8, d.msg, "</span>") != null);
            try std.testing.expect(std.mem.indexOf(u8, d.msg, "</div>") != null);
        },
        .src => return error.TestUnexpectedResult,
    }
}

test "malformed { hole is a positioned diag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mismatched = generateFile(arena, "<div>{foo(}</div>", "templates/x.zsx");
    switch (mismatched) {
        .diag => |d| {
            try std.testing.expect(std.mem.indexOf(u8, d.msg, "mismatched delimiter") != null);
        },
        .src => return error.TestUnexpectedResult,
    }
    const unterminated = generateFile(arena, "<div>{foo(", "templates/x.zsx");
    switch (unterminated) {
        .diag => |d| {
            try std.testing.expect(std.mem.indexOf(u8, d.msg, "unterminated") != null);
        },
        .src => return error.TestUnexpectedResult,
    }
}

test "void elements must self-close; void children rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = generateFile(arena, "<div><input type=\"text\"></div>", "templates/x.zsx");
    switch (bad) {
        .diag => |d| try std.testing.expect(std.mem.indexOf(u8, d.msg, "self-close") != null),
        .src => return error.TestUnexpectedResult,
    }
    const ok = generateFile(arena, "<div><input type=\"text\" /></div>", "templates/x.zsx");
    switch (ok) {
        .src => |s| try std.testing.expect(std.mem.indexOf(u8, s, "forest.el(a, .input") != null),
        .diag => return error.TestUnexpectedResult,
    }
}

test "bad event name is a positioned diag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = generateFile(arena, "<button on:hover={ctx.x}>b</button>", "templates/x.zsx");
    switch (outcome) {
        .diag => |d| {
            try std.testing.expect(std.mem.indexOf(u8, d.msg, "unknown event") != null);
        },
        .src => return error.TestUnexpectedResult,
    }
}

test "whitespace-only text between tags is dropped; real text kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = generateFile(arena,
        \\<div>
        \\  <span>a</span> · <span>b</span>
        \\</div>
    , "templates/x.zsx");
    const src = switch (outcome) {
        .src => |s| s,
        .diag => return error.TestUnexpectedResult,
    };
    // The " · " separator survives; indentation-only runs do not.
    try std.testing.expect(std.mem.indexOf(u8, src, "forest.text(\" · \")") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "forest.text(\"\\n\")") == null);
}

test "same-line whitespace text is preserved verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = generateFile(arena, "<div><span>a</span> <span>b</span></div>", "templates/x.zsx");
    const src = switch (outcome) {
        .src => |s| s,
        .diag => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.indexOf(u8, src, "forest.text(\" \")") != null);
}
