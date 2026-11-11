const std = @import("std");
const todo = @import("../todo_app.zig");

/// Serialize the full-state snapshot event payload:
/// {"rev":N,"html":"…","count":"…","filter":"…"}
/// Reads model state only — never touches the pending patch log, so a
/// snapshot can never consume an unpublished action's patches.
pub fn writeSnapshotJson(s: *todo.Session, writer: *std.Io.Writer) !void {
    try writer.print("{{\"rev\":{d},\"html\":", .{s.seq.get()});
    var rows: std.Io.Writer.Allocating = .init(s.gpa);
    defer rows.deinit();
    try s.writeListRows(&rows.writer);
    try std.json.Stringify.encodeJsonString(rows.writer.buffered(), .{}, writer);
    var buf: [64]u8 = undefined;
    const rem = s.remaining.get();
    const count = std.fmt.bufPrint(&buf, "{d} item{s} left", .{ rem, if (rem == 1) "" else "s" }) catch unreachable;
    try writer.writeAll(",\"count\":");
    try std.json.Stringify.encodeJsonString(count, .{}, writer);
    try writer.print(",\"filter\":\"{s}\"}}", .{s.filter.name()});
}

// ─────────────────────────────────────────────
// tests
// ─────────────────────────────────────────────

test "snapshot serializes escaped html and model state" {
    const alloc = std.testing.allocator;
    const s = todo.createSession(alloc);
    defer s.deinit();
    s.seedDom();

    try s.apply("add", null, "say \"<b>hi</b>\"");
    s.log.clear(); // simulate publish consuming the batch

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try writeSnapshotJson(s, &aw.writer);
    const json = aw.writer.buffered();

    // HTML-escaped inside, JSON-escaped outside; valid JSON overall.
    try std.testing.expect(std.mem.indexOf(u8, json, "&lt;b&gt;hi&lt;/b&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("all", parsed.value.object.get("filter").?.string);
    try std.testing.expectEqualStrings("1 item left", parsed.value.object.get("count").?.string);
    try std.testing.expect(parsed.value.object.get("rev").?.integer > 0);
}
