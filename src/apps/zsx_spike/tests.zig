//! zsx spike parity tests — the evidence for docs/zsx-spike.md.
//!
//! Three implementations of the SAME two views (post form, comment
//! row + inline reply form) must produce byte-identical output:
//!   1. zsx:   templates/*.zsx → gen/*.zig (+ zsx_app.zig ctx glue)
//!   2. h.*:   h_post_form.zig / h_comment_row.zig
//!   3. el:    el_post_form.zig / el_comment_row.zig
//!
//! Compared: SSR writeHtml, snapshot ops JSON, and a diff cycle
//! (bound text, bound attr, keyed reorder/removal, when
//! mount/unmount) serialized through PatchLog.writeJson.
const std = @import("std");
const forest = @import("forest");
const view = forest.view;
const Dom = forest.Dom;
const PatchLog = forest.PatchLog;
const model = @import("model.zig");
const zsx_app = @import("zsx_app.zig");
const h_post_form = @import("h_post_form.zig");
const el_post_form = @import("el_post_form.zig");
const h_comment_row = @import("h_comment_row.zig");
const el_comment_row = @import("el_comment_row.zig");

const Env = model.Env;
const Allocator = std.mem.Allocator;

// ── helpers ───────────────────────────────────────────────────────

fn renderStr(a: Allocator, nodes: []const forest.Node) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    view.writeHtml(a, nodes, &aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

fn snapshotStr(a: Allocator, nodes: []const forest.Node) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    view.writeSnapshotOps(a, nodes, &aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

fn jsonOf(a: Allocator, log: *const PatchLog) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    log.writeJson(&aw.writer) catch @panic("OOM");
    return aw.toOwnedSlice() catch @panic("OOM");
}

/// Post-form env: draft cell bound to the textarea's `value` attr.
fn makePostEnv(a: Allocator, draft_v: ?[]const u8) Env {
    const draft = a.create(model.Cell(?[]const u8)) catch @panic("OOM");
    draft.* = .{ .gpa = a, .v = draft_v };
    return .{
        .slug = "general",
        .draft = draft,
        .placeholder = "Текст поста…",
        .max_len = 2000,
        .submit_label = "Запостить",
    };
}

/// Comment-row env: 3 pool comments, #1 with kids #2/#3.
fn makeRowEnv(a: Allocator) Env {
    const pool = a.alloc(model.Comment, 3) catch @panic("OOM");
    pool[0] = .{
        .id = 1,
        .author = "alice",
        .text = "root comment",
        .ts = 1730000000,
        .children = &.{ 1, 2 },
    };
    pool[1] = .{ .id = 2, .author = "bob", .text = "first reply", .ts = 1730000100 };
    pool[2] = .{ .id = 3, .author = "carol", .text = "second reply", .ts = 1730000200 };
    const likes = a.alloc(model.Cell(u32), 3) catch @panic("OOM");
    likes[0] = .{ .gpa = a, .v = 3 };
    likes[1] = .{ .gpa = a, .v = 1 };
    likes[2] = .{ .gpa = a, .v = 0 };
    return .{
        .pool = pool,
        .post_id = 7,
        .post_str = "7",
        .likes = likes,
    };
}

const PostView = *const fn (Allocator, *const Env) forest.Node;
const RowView = *const fn (Allocator, *const Env, u32) forest.Node;

const post_versions = [_]struct { name: []const u8, view: PostView }{
    .{ .name = "zsx", .view = zsx_app.postForm },
    .{ .name = "h", .view = h_post_form.postForm },
    .{ .name = "el", .view = el_post_form.postForm },
};

const row_versions = [_]struct { name: []const u8, view: RowView }{
    .{ .name = "zsx", .view = zsx_app.commentRow },
    .{ .name = "h", .view = h_comment_row.commentRow },
    .{ .name = "el", .view = el_comment_row.commentRow },
};

// ── SSR + snapshot parity ─────────────────────────────────────────

test "post_form: SSR writeHtml identical across zsx/h/el" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var env = makePostEnv(a, "half-written");
    var expected: ?[]const u8 = null;
    for (post_versions) |v| {
        const node = v.view(a, &env);
        const html = renderStr(a, &.{node});
        if (expected) |e| {
            try std.testing.expectEqualStrings(e, html);
        } else {
            expected = html;
        }
    }
    const html = expected.?;
    try std.testing.expect(std.mem.indexOf(u8, html, "data-on-submit=\"post\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"half-written\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "autofocus") != null);
}

test "comment_row: SSR writeHtml identical across zsx/h/el (replying + kids)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var env = makeRowEnv(a);
    env.reply_to = 1; // inline reply form mounted on row #1
    var expected: ?[]const u8 = null;
    for (row_versions) |v| {
        const node = v.view(a, &env, 0);
        const html = renderStr(a, &.{node});
        if (expected) |e| {
            try std.testing.expectEqualStrings(e, html);
        } else {
            expected = html;
        }
    }
    const html = expected.?;
    try std.testing.expect(std.mem.indexOf(u8, html, "<!--z-when:w-rep-1-->") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "reply-form") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "cm-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "cm-3") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "like-c1") != null);
}

test "snapshot ops identical across zsx/h/el" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var env = makeRowEnv(a);
    env.reply_to = 2;
    var expected: ?[]const u8 = null;
    for (row_versions) |v| {
        const snap = snapshotStr(a, &.{v.view(a, &env, 0)});
        if (expected) |e| {
            try std.testing.expectEqualStrings(e, snap);
        } else {
            expected = snap;
        }
    }
    // Sanity: the snapshot carries the when op + keyed html dump + text op.
    const snap = expected.?;
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"op\":\"when\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"op\":\"html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap, "\"op\":\"text\"") != null);
}

// ── diff-cycle parity ─────────────────────────────────────────────

/// One diff step: rebuild the view, diff, return the serialized batch.
fn diffJson(a: Allocator, dom: *Dom, log: *PatchLog, node: forest.Node) []const u8 {
    forest.diff(a, &.{node}, dom, log);
    const j = jsonOf(a, log);
    log.clear();
    return j;
}

test "post_form: diff cycle emits identical PatchLog ops across versions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var s0: [3][]const u8 = undefined;
    var s1: [3][]const u8 = undefined;
    var s2: [3][]const u8 = undefined;
    for (post_versions, 0..) |v, vi| {
        var env = makePostEnv(a, null);
        var dom = Dom.init(std.testing.allocator);
        defer dom.deinit();
        var log = PatchLog.init(std.testing.allocator);
        defer log.deinit();

        // s0: seed — draft absent, max_len 2000.
        s0[vi] = diffJson(a, &dom, &log, v.view(a, &env));
        // s1: draft appears + maxlength shrinks → attr patches.
        if (env.draft) |d| d.v = "now typing";
        env.max_len = 100;
        s1[vi] = diffJson(a, &dom, &log, v.view(a, &env));
        // s2: draft cleared → value attr removed.
        if (env.draft) |d| d.v = null;
        s2[vi] = diffJson(a, &dom, &log, v.view(a, &env));
    }
    for (1..3) |i| {
        try std.testing.expectEqualStrings(s0[0], s0[i]);
        try std.testing.expectEqualStrings(s1[0], s1[i]);
        try std.testing.expectEqualStrings(s2[0], s2[i]);
    }
    // Sanity: s1 carries the two bound-attr patches on post-text.
    try std.testing.expect(std.mem.indexOf(u8, s1[0], "\"op\":\"attr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1[0], "post-text") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2[0], "\"value\":null") != null);
}

test "comment_row: diff cycle (text/attr/keyed reorder+remove/when) identical across versions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var s0: [3][]const u8 = undefined;
    var s1: [3][]const u8 = undefined;
    var s2: [3][]const u8 = undefined;
    var s3: [3][]const u8 = undefined;
    for (row_versions, 0..) |v, vi| {
        var env = makeRowEnv(a);
        var dom = Dom.init(std.testing.allocator);
        defer dom.deinit();
        var log = PatchLog.init(std.testing.allocator);
        defer log.deinit();

        // s0: seed — 2 kids, no reply, likes 3/1/0.
        s0[vi] = diffJson(a, &dom, &log, v.view(a, &env, 0));

        // s1: like count bumps (bound .text), reply mounts (when op),
        // kids reorder (keyed move), kid like bumps inside the row.
        env.likes[0].v = 5;
        env.likes[1].v = 2;
        env.reply_to = 1;
        env.pool[0].children = &.{ 2, 1 };
        s1[vi] = diffJson(a, &dom, &log, v.view(a, &env, 0));

        // s2: reply unmounts, kid #2 removed from the keyed list.
        env.reply_to = null;
        env.pool[0].children = &.{2};
        s2[vi] = diffJson(a, &dom, &log, v.view(a, &env, 0));

        // s3: stable re-render — must be empty for every version.
        s3[vi] = diffJson(a, &dom, &log, v.view(a, &env, 0));
    }
    for (1..3) |i| {
        try std.testing.expectEqualStrings(s0[0], s0[i]);
        try std.testing.expectEqualStrings(s1[0], s1[i]);
        try std.testing.expectEqualStrings(s2[0], s2[i]);
        try std.testing.expectEqualStrings(s3[0], s3[i]);
    }

    // Sanity on the shared stream: when op, move, remove, text ops all
    // appear where the scenario demands them.
    try std.testing.expect(std.mem.indexOf(u8, s1[0], "\"op\":\"when\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1[0], "\"op\":\"move\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1[0], "\"op\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2[0], "\"op\":\"when\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s2[0], "\"op\":\"remove\"") != null);
    try std.testing.expectEqualStrings("{\"rev\":0,\"patches\":[]}", s3[0]);
}

// ── live binding fixture ──────────────────────────────────────────

test "comment_row: computed .text binding stays live through zsx lowering" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var env = makeRowEnv(a);
    const nodes = &.{zsx_app.commentRow(a, &env, 0)};
    var dom = Dom.init(std.testing.allocator);
    defer dom.deinit();
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    forest.diff(a, nodes, &dom, &log); // SSR-equivalent seed
    log.clear();
    forest.bindTree(a, nodes, &dom, &log);
    // Three like buttons (cm-1/2/3 rows) each subscribe their store.
    try std.testing.expectEqual(@as(usize, 3), dom.bindings.items.len);
    try std.testing.expectEqual(@as(usize, 1), env.likes[0].watcherCount());

    env.likes[0].emit(9);
    try std.testing.expectEqual(@as(usize, 1), log.patches.items.len);
    try std.testing.expect(log.patches.items[0] == .text);
    try std.testing.expectEqualStrings("like-c1", log.patches.items[0].text.id);
    try std.testing.expectEqualStrings("\u{25B2} 9", log.patches.items[0].text.text);
}

test "post_form: raw store attr keeps live hooks via zsx, h and el" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var binding_counts: [3]usize = undefined;
    var emitted: [3]bool = undefined;
    for (post_versions, 0..) |v, vi| {
        var env = makePostEnv(a, "draft");
        const nodes = &.{v.view(a, &env)};
        var dom = Dom.init(std.testing.allocator);
        defer dom.deinit();
        var log = PatchLog.init(std.testing.allocator);
        defer log.deinit();
        forest.diff(a, nodes, &dom, &log);
        log.clear();
        forest.bindTree(a, nodes, &dom, &log);
        binding_counts[vi] = dom.bindings.items.len;
        if (env.draft) |d| d.emit("changed");
        emitted[vi] = log.patches.items.len != 0;
    }
    // All three keep Bound.live → 1 attr binding each. h routes store
    // operands through forest.bind, so the old h-vs-el divergence is
    // gone (fixed after the spike — see h.zig internals note).
    try std.testing.expectEqual(@as(usize, 1), binding_counts[0]);
    try std.testing.expectEqual(@as(usize, 1), binding_counts[1]);
    try std.testing.expectEqual(@as(usize, 1), binding_counts[2]);
    try std.testing.expect(emitted[0]);
    try std.testing.expect(emitted[1]);
    try std.testing.expect(emitted[2]);
}
