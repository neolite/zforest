const std = @import("std");
const forest = @import("forest");
const todo = @import("../todo_app.zig");

/// Serialize the full-state snapshot event payload: {"rev":N,"ops":[…]}.
/// `ops` is the declarative view emitted as an idempotent state dump —
/// `forest.writeSnapshotOps` over a freshly built view: keyed parents
/// become `html` ops, bound nodes become attr/text ops. Reads model
/// state only — never touches the pending patch log, so a snapshot can
/// never consume an unpublished action's patches.
pub fn writeSnapshotJson(s: *todo.Session, writer: *std.Io.Writer) !void {
    try writer.print("{{\"rev\":{d},\"ops\":", .{s.seq.get()});
    _ = s.render_arena.reset(.retain_capacity);
    const a = s.render_arena.allocator();
    try forest.writeSnapshotOps(a, s.buildViewNodes(a), writer);
    try writer.writeByte('}');
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "snapshot serializes the view as a full-state ops array" {
    const alloc = std.testing.allocator;
    const s = todo.createSession(alloc);
    defer s.deinit();
    s.seedDom();

    var fields: std.json.ObjectMap = .empty;
    defer fields.deinit(alloc);
    try fields.put(alloc, "title", .{ .string = "say \"<b>hi</b>\"" });
    try s.dispatch("add", null, null, &fields);
    s.log.clear(); // simulate publish consuming the batch

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try writeSnapshotJson(s, &aw.writer);
    const json = aw.writer.buffered();

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("rev").?.integer > 0);
    const ops = root.get("ops").?.array.items;

    // The keyed list ships as one html op carrying the row markup —
    // HTML-escaped inside, JSON-escaped outside.
    var html_op: ?[]const u8 = null;
    var count_op: ?[]const u8 = null;
    var active_op = false;
    for (ops) |op| {
        const o = op.object;
        const kind = o.get("op").?.string;
        if (std.mem.eql(u8, kind, "html")) {
            html_op = o.get("html").?.string;
            try std.testing.expectEqualStrings("list", o.get("id").?.string);
        } else if (std.mem.eql(u8, kind, "text")) {
            try std.testing.expectEqualStrings("count", o.get("id").?.string);
            count_op = o.get("text").?.string;
        } else if (std.mem.eql(u8, kind, "attr")) {
            if (std.mem.eql(u8, o.get("id").?.string, "flt-all") and
                std.mem.eql(u8, o.get("name").?.string, "data-active"))
            {
                active_op = std.mem.eql(u8, o.get("value").?.string, "1");
            }
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, html_op.?, "&lt;b&gt;hi&lt;/b&gt;") != null);
    try std.testing.expectEqualStrings("1 item left", count_op.?);
    try std.testing.expect(active_op);
}
