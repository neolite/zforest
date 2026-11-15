//! markdown — a conservative subset renderer for zboard post/comment
//! text. Deliberately NOT CommonMark: posts are short, the grammar is
//! small enough to audit for XSS, and anything unrecognized stays
//! literal text.
//!
//! Supported:
//!   inline  `code`              — literal content, no inner parsing
//!           **bold**            — <strong>, nests other inline markup
//!           *italic* / _italic_ — <em>; '_' refuses to open/close
//!                                  inside a word so snake_case stays
//!                                  literal
//!           [text](url)         — <a target=_blank rel=noopener>,
//!                                  http/https schemes only
//!   block   paragraphs          — blank-line separated; single
//!                                  newlines preserved (the container
//!                                  is `white-space: pre-wrap`)
//!           > quote lines       — a run of '>'-prefixed lines becomes
//!                                  one <blockquote> (one level only)
//!           ``` fences           — literal content in <pre><code>
//!
//! Everything else — '#', '-', '|', '__', raw HTML, link titles —
//! renders literally. Safety: every literal byte goes through forest
//! text/element nodes (`writeHtml` escapes them) and link hrefs ride
//! the normal attribute path after a scheme check; `forest.raw` is
//! never used, so user input cannot inject markup.
//!
//! Cost: one O(n) scan per nesting level (indexOf-based marker search,
//! depth-capped) over <= model.max_text_len chars, all in the render
//! arena — no caching; the parsed nodes only exist for the keyed row's
//! create/snapshot serialization anyway.
const std = @import("std");
const forest = @import("forest");

/// Recursion cap for markup nested inside emphasis/link text.
const max_depth = 8;

const Line = struct { lo: usize, hi: usize };

/// `src` split into '\n'-separated spans ([lo,hi) into `src`; a
/// trailing '\r' stays inside the span — the HTML parser normalizes it).
fn linesOf(a: std.mem.Allocator, src: []const u8) []const Line {
    var out: std.ArrayListUnmanaged(Line) = .empty;
    var off: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        out.append(a, .{ .lo = off, .hi = off + raw.len }) catch @panic("OOM");
        off += raw.len + 1;
    }
    return out.toOwnedSlice(a) catch @panic("OOM");
}

/// Line content for classification: the span minus one trailing '\r'.
fn lineText(src: []const u8, ln: Line) []const u8 {
    var s = src[ln.lo..ln.hi];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}

fn isBlank(t: []const u8) bool {
    for (t) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn isFence(t: []const u8) bool {
    return t.len >= 3 and t[0] == '`' and t[1] == '`' and t[2] == '`';
}

fn isQuote(t: []const u8) bool {
    return t.len > 0 and t[0] == '>';
}

/// Render `src` to forest nodes for a `.ptext`/`.ctext` container.
/// Blank-line gaps between blocks re-emit verbatim as text nodes —
/// pre-wrap renders them exactly like the source newlines did.
pub fn render(a: std.mem.Allocator, src: []const u8) []const forest.Node {
    var out: std.ArrayListUnmanaged(forest.Node) = .empty;
    const lines = linesOf(a, src);
    var i: usize = 0;
    var prev_end: usize = 0;
    var emitted = false;
    while (i < lines.len) {
        const t = lineText(src, lines[i]);
        if (isBlank(t)) {
            i += 1;
            continue;
        }
        var j: usize = i;
        var kind: enum { para, quote, fence } = .para;
        var content: []const u8 = "";
        var bend: usize = 0;
        if (isFence(t)) {
            kind = .fence;
            j = i + 1;
            while (j < lines.len and !isFence(lineText(src, lines[j]))) j += 1;
            if (j < lines.len) {
                if (i + 1 < j) content = src[lines[i + 1].lo..lines[j - 1].hi];
                bend = lines[j].hi;
                j += 1;
            } else {
                // Unterminated fence: content runs to EOF.
                if (i + 1 < lines.len) content = src[lines[i + 1].lo..src.len];
                bend = src.len;
            }
            // CommonMark drops the content's final newline.
            if (content.len > 0 and content[content.len - 1] == '\n') {
                content = content[0 .. content.len - 1];
                if (content.len > 0 and content[content.len - 1] == '\r')
                    content = content[0 .. content.len - 1];
            }
        } else if (isQuote(t)) {
            kind = .quote;
            while (j < lines.len and isQuote(lineText(src, lines[j]))) j += 1;
            bend = lines[j - 1].hi;
        } else {
            while (j < lines.len) {
                const lt = lineText(src, lines[j]);
                if (isBlank(lt) or isFence(lt) or isQuote(lt)) break;
                j += 1;
            }
            bend = lines[j - 1].hi;
        }
        const blo = lines[i].lo;
        if (emitted and prev_end < blo)
            out.append(a, .{ .text = src[prev_end..blo] }) catch @panic("OOM");
        switch (kind) {
            .para => inlineInto(a, src[blo..bend], &out, 0),
            .quote => {
                var qb: std.ArrayListUnmanaged(u8) = .empty;
                for (lines[i..j], 0..) |ln, n| {
                    var qt = lineText(src, ln);
                    qt = qt[1..]; // '>'
                    if (qt.len > 0 and qt[0] == ' ') qt = qt[1..];
                    if (n != 0) qb.append(a, '\n') catch @panic("OOM");
                    qb.appendSlice(a, qt) catch @panic("OOM");
                }
                var qkids: std.ArrayListUnmanaged(forest.Node) = .empty;
                inlineInto(a, qb.items, &qkids, 0);
                out.append(a, forest.el(a, .blockquote, .{}, qkids.items)) catch @panic("OOM");
            },
            .fence => {
                out.append(a, forest.el(a, .pre, .{}, forest.el(a, .code, .{}, content))) catch @panic("OOM");
            },
        }
        prev_end = bend;
        emitted = true;
        i = j;
    }
    return out.toOwnedSlice(a) catch @panic("OOM");
}

// ── inline parsing ────────────────────────────────────────────────

fn pushText(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(forest.Node), s: []const u8) void {
    if (s.len == 0) return;
    out.append(a, .{ .text = s }) catch @panic("OOM");
}

/// Emphasis content must be non-empty with non-whitespace edges —
/// rejects "* *", "** **" and friends.
fn emphOk(inner: []const u8) bool {
    return inner.len > 0 and
        !std.ascii.isWhitespace(inner[0]) and
        !std.ascii.isWhitespace(inner[inner.len - 1]);
}

const Span = struct { tag: forest.Tag, inner: []const u8, next: usize };

const LinkSpan = struct { inner: []const u8, url: []const u8, next: usize };

/// Index after the closing '`' of a code span starting at src[i], or
/// null. Empty `` spans stay literal.
fn codeSpanEnd(src: []const u8, i: usize) ?usize {
    const rel = std.mem.indexOfScalar(u8, src[i + 1 ..], '`') orelse return null;
    const close = i + 1 + rel;
    if (close == i + 1) return null;
    return close + 1;
}

/// '*'/'**' emphasis starting at src[i]. Single '*' matches intraword
/// (CommonMark-style); the closer is the next '*' — including one that
/// begins a '**' pair, which just leaves a literal '*' behind.
fn starSpan(src: []const u8, i: usize) ?Span {
    if (i + 1 < src.len and src[i + 1] == '*') {
        const rel = std.mem.indexOf(u8, src[i + 2 ..], "**") orelse return null;
        const close = i + 2 + rel;
        const inner = src[i + 2 .. close];
        if (!emphOk(inner)) return null;
        return .{ .tag = .strong, .inner = inner, .next = close + 2 };
    }
    const rel = std.mem.indexOfScalar(u8, src[i + 1 ..], '*') orelse return null;
    const close = i + 1 + rel;
    const inner = src[i + 1 .. close];
    if (!emphOk(inner)) return null;
    return .{ .tag = .em, .inner = inner, .next = close + 1 };
}

/// '_' emphasis starting at src[i]. Refuses to open after an
/// alphanumeric and only accepts closers not followed by one — so
/// snake_case identifiers never italicize.
fn underSpan(src: []const u8, i: usize) ?Span {
    if (i > 0 and std.ascii.isAlphanumeric(src[i - 1])) return null;
    var j = i + 1;
    while (j < src.len) {
        const rel = std.mem.indexOfScalar(u8, src[j..], '_') orelse return null;
        const close = j + rel;
        const after_ok = close + 1 >= src.len or !std.ascii.isAlphanumeric(src[close + 1]);
        if (after_ok) {
            const inner = src[i + 1 .. close];
            if (emphOk(inner)) return .{ .tag = .em, .inner = inner, .next = close + 1 };
        }
        j = close + 1;
    }
    return null;
}

/// http/https only — everything else (javascript:, data:, relative,
/// scheme-less) fails and the '[...]' stays literal text.
fn validUrl(u: []const u8) bool {
    const p: usize = if (hasScheme(u, "https://")) "https://".len else if (hasScheme(u, "http://")) "http://".len else return false;
    if (u.len <= p) return false;
    for (u) |c| if (c <= 0x20 or c == 0x7f) return false;
    return true;
}

fn hasScheme(u: []const u8, comptime s: []const u8) bool {
    return u.len > s.len and std.ascii.eqlIgnoreCase(u[0..s.len], s);
}

/// `[text](url)` starting at src[i]: first ']' then '(' … ')'. The url
/// is validated but NOT unescaped — it rides the attr path verbatim.
fn linkSpan(src: []const u8, i: usize) ?LinkSpan {
    const r1 = std.mem.indexOfScalar(u8, src[i + 1 ..], ']') orelse return null;
    const rb = i + 1 + r1;
    if (rb + 1 >= src.len or src[rb + 1] != '(') return null;
    const r2 = std.mem.indexOfScalar(u8, src[rb + 2 ..], ')') orelse return null;
    const rp = rb + 2 + r2;
    const text = src[i + 1 .. rb];
    const url = src[rb + 2 .. rp];
    if (text.len == 0 or !validUrl(url)) return null;
    return .{ .inner = text, .url = url, .next = rp + 1 };
}

fn emphNode(a: std.mem.Allocator, tag: forest.Tag, inner: []const u8, depth: usize) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    inlineInto(a, inner, &kids, depth + 1);
    return switch (tag) {
        .strong => forest.el(a, .strong, .{}, kids.items),
        .em => forest.el(a, .em, .{}, kids.items),
        else => unreachable,
    };
}

fn linkNode(a: std.mem.Allocator, inner: []const u8, url: []const u8, depth: usize) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    inlineInto(a, inner, &kids, depth + 1);
    return forest.el(a, .a, .{
        .href = url,
        .target = "_blank",
        .rel = "noopener noreferrer",
    }, kids.items);
}

/// Scan `src` for inline markup, appending nodes to `out`. Literal
/// runs (including failed markers) flush as text nodes between hits.
fn inlineInto(
    a: std.mem.Allocator,
    src: []const u8,
    out: *std.ArrayListUnmanaged(forest.Node),
    depth: usize,
) void {
    if (depth >= max_depth) {
        pushText(a, out, src);
        return;
    }
    var i: usize = 0;
    var run: usize = 0;
    while (i < src.len) {
        var next: ?usize = null;
        var node: ?forest.Node = null;
        switch (src[i]) {
            '`' => {
                if (codeSpanEnd(src, i)) |end| {
                    next = end;
                    node = forest.el(a, .code, .{}, src[i + 1 .. end - 1]);
                }
            },
            '*' => {
                if (starSpan(src, i)) |s| {
                    next = s.next;
                    node = emphNode(a, s.tag, s.inner, depth);
                }
            },
            '_' => {
                if (underSpan(src, i)) |s| {
                    next = s.next;
                    node = emphNode(a, s.tag, s.inner, depth);
                }
            },
            '[' => {
                if (linkSpan(src, i)) |s| {
                    next = s.next;
                    node = linkNode(a, s.inner, s.url, depth);
                }
            },
            else => {},
        }
        if (node) |n| {
            pushText(a, out, src[run..i]);
            out.append(a, n) catch @panic("OOM");
            i = next.?;
            run = i;
        } else i += 1;
    }
    pushText(a, out, src[run..src.len]);
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

fn renderStr(alloc: std.mem.Allocator, src: []const u8) []const u8 {
    const nodes = render(alloc, src);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    forest.writeHtml(alloc, nodes, &aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

test "markdown: plain text passes through unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("hello world", renderStr(alloc, "hello world"));
    try std.testing.expectEqualStrings("a\nb", renderStr(alloc, "a\nb"));
    try std.testing.expectEqualStrings("", renderStr(alloc, ""));
    // Blank-only input has no blocks — leading/trailing blanks collapse.
    try std.testing.expectEqualStrings("", renderStr(alloc, "\n\n"));
    // Unbalanced/edge markers stay literal.
    try std.testing.expectEqualStrings("* a *", renderStr(alloc, "* a *"));
    try std.testing.expectEqualStrings("2 * 3 * 4", renderStr(alloc, "2 * 3 * 4"));
    try std.testing.expectEqualStrings("``", renderStr(alloc, "``"));
    try std.testing.expectEqualStrings("`unclosed", renderStr(alloc, "`unclosed"));
    try std.testing.expectEqualStrings("[x](notaurl)", renderStr(alloc, "[x](notaurl)"));
}

test "markdown: bold and italic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("<strong>b</strong>", renderStr(alloc, "**b**"));
    try std.testing.expectEqualStrings("<em>i</em>", renderStr(alloc, "*i*"));
    try std.testing.expectEqualStrings("<em>i</em>", renderStr(alloc, "_i_"));
    try std.testing.expectEqualStrings("a <strong>b</strong> c", renderStr(alloc, "a **b** c"));
    try std.testing.expectEqualStrings("<strong>a <em>b</em> c</strong>", renderStr(alloc, "**a *b* c**"));
    try std.testing.expectEqualStrings("<em>a</em>b*", renderStr(alloc, "*a*b*"));
    // Word-internal underscores stay literal.
    try std.testing.expectEqualStrings("snake_case_name", renderStr(alloc, "snake_case_name"));
    try std.testing.expectEqualStrings("a_b_", renderStr(alloc, "a_b_"));
    // '*' is intraword like CommonMark.
    try std.testing.expectEqualStrings("a<em>b</em>c", renderStr(alloc, "a*b*c"));
}

test "markdown: inline code is literal and escaped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("<code>x</code>", renderStr(alloc, "`x`"));
    try std.testing.expectEqualStrings("a <code>b&lt;c</code> d", renderStr(alloc, "a `b<c` d"));
    // No markup parsing inside code spans.
    try std.testing.expectEqualStrings("<code>**x**</code>", renderStr(alloc, "`**x**`"));
}

test "markdown: links are http/https only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "<a href=\"https://ziglang.org\" target=\"_blank\" rel=\"noopener noreferrer\">z</a>",
        renderStr(alloc, "[z](https://ziglang.org)"),
    );
    try std.testing.expectEqualStrings(
        "<a href=\"HTTP://a.b\" target=\"_blank\" rel=\"noopener noreferrer\">x</a>",
        renderStr(alloc, "[x](HTTP://a.b)"),
    );
    // Markup inside link text still parses.
    try std.testing.expectEqualStrings(
        "<a href=\"https://x\" target=\"_blank\" rel=\"noopener noreferrer\"><strong>b</strong></a>",
        renderStr(alloc, "[**b**](https://x)"),
    );
    // Rejected schemes and malformed urls stay literal.
    try std.testing.expectEqualStrings("[x](javascript:alert(1))", renderStr(alloc, "[x](javascript:alert(1))"));
    try std.testing.expectEqualStrings("[x](data:text/html,&lt;b&gt;)", renderStr(alloc, "[x](data:text/html,<b>)"));
    try std.testing.expectEqualStrings("[x](ftp://a)", renderStr(alloc, "[x](ftp://a)"));
    try std.testing.expectEqualStrings("[x](/rel/path)", renderStr(alloc, "[x](/rel/path)"));
    try std.testing.expectEqualStrings("[x](https://a b)", renderStr(alloc, "[x](https://a b)"));
    try std.testing.expectEqualStrings("[x](https://)", renderStr(alloc, "[x](https://)"));
}

test "markdown: user html and attrs stay escaped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings(
        "&lt;script&gt;alert(1)&lt;/script&gt;",
        renderStr(alloc, "<script>alert(1)</script>"),
    );
    try std.testing.expectEqualStrings(
        "&lt;img src=x onerror=alert(1)&gt;",
        renderStr(alloc, "<img src=x onerror=alert(1)>"),
    );
    // A quote inside a url is attr-escaped, not markup.
    try std.testing.expectEqualStrings(
        "<a href=\"https://a&quot;b\" target=\"_blank\" rel=\"noopener noreferrer\">x</a>",
        renderStr(alloc, "[x](https://a\"b)"),
    );
}

test "markdown: block structure — paragraphs, quotes, fences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Blank-line gap re-emits verbatim.
    try std.testing.expectEqualStrings("a\n\nb", renderStr(alloc, "a\n\nb"));
    try std.testing.expectEqualStrings("para\n\n<blockquote>q</blockquote>\n\nafter", renderStr(alloc, "para\n\n> q\n\nafter"));
    // Quote runs join lines; markup inside parses.
    try std.testing.expectEqualStrings("<blockquote>a\nb</blockquote>", renderStr(alloc, "> a\n> b"));
    try std.testing.expectEqualStrings("<blockquote><strong>x</strong></blockquote>", renderStr(alloc, "> **x**"));
    // Fences are literal; unterminated runs to EOF.
    try std.testing.expectEqualStrings("<pre><code>code &lt;b&gt;</code></pre>", renderStr(alloc, "```\ncode <b>\n```"));
    try std.testing.expectEqualStrings("<pre><code>code</code></pre>", renderStr(alloc, "```\ncode"));
    try std.testing.expectEqualStrings("<pre><code></code></pre>", renderStr(alloc, "```\n```"));
    // Blocks interrupt paragraphs; single-newline gaps stay text.
    try std.testing.expectEqualStrings("a\n<blockquote>q</blockquote>\nb", renderStr(alloc, "a\n> q\nb"));
    // Leading/trailing blank lines collapse.
    try std.testing.expectEqualStrings("x", renderStr(alloc, "\n\nx\n\n"));
}
