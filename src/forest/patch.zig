const std = @import("std");

/// Escape `s` for embedding inside generated HTML markup.
pub fn escapeHtmlInto(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(c),
        }
    }
}

pub fn escapeHtml(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    try escapeHtmlInto(&aw.writer, s);
    return aw.toOwnedSlice();
}

/// JSON-string escaping (also safe for embedding in an HTML <script> via \u003c).
pub fn writeJsonStringInto(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '<' => try writer.writeAll("\\u003c"),
            '>' => try writer.writeAll("\\u003e"),
            '&' => try writer.writeAll("\\u0026"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

/// A fine-grained DOM mutation. Node ids are stable strings owned by the app
/// (e.g. "row-7"). All string fields are owned by the emitting PatchLog's
/// arena and stay valid until the log is cleared or deinited.
pub const Patch = union(enum) {
    /// Insert trusted, server-generated HTML under `parent_id`, before
    /// `before_id` (or at the end when null). Dynamic data inside `html`
    /// must already be HTML-escaped by the producer.
    create: struct { parent_id: []const u8, before_id: ?[]const u8, id: []const u8, html: []const u8 },
    remove: struct { id: []const u8 },
    /// Move an existing node before `before_id` (null = append at end).
    move: struct { parent_id: []const u8, id: []const u8, before_id: ?[]const u8 },
    /// Replace element text content (client uses textContent — no escaping needed).
    text: struct { id: []const u8, text: []const u8 },
    /// Set/remove an attribute. `value == null` removes it.
    attr: struct { id: []const u8, name: []const u8, value: ?[]const u8 },
};

/// Ordered patch batch for one revision. Strings are duplicated into an
/// internal arena, so producers may pass temporary slices.
pub const PatchLog = struct {
    arena: std.heap.ArenaAllocator,
    patches: std.ArrayListUnmanaged(Patch) = .empty,
    revision: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) PatchLog {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *PatchLog) void {
        // `patches` and all owned strings live in the arena — one deinit
        // frees everything; do NOT deinit the list against child_allocator.
        self.arena.deinit();
    }

    /// Drop all recorded patches (frees owned strings), keep the log usable.
    pub fn clear(self: *PatchLog) void {
        _ = self.arena.reset(.retain_capacity);
        self.patches = .empty;
    }

    fn alloc(self: *PatchLog) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn dupe(self: *PatchLog, s: []const u8) []const u8 {
        return self.alloc().dupe(u8, s) catch @panic("OOM");
    }

    fn dupeOpt(self: *PatchLog, s: ?[]const u8) ?[]const u8 {
        const v = s orelse return null;
        return self.dupe(v);
    }

    fn push(self: *PatchLog, p: Patch) void {
        self.patches.append(self.alloc(), p) catch @panic("OOM");
    }

    pub fn create(self: *PatchLog, parent_id: []const u8, before_id: ?[]const u8, id: []const u8, html: []const u8) void {
        self.push(.{ .create = .{
            .parent_id = self.dupe(parent_id),
            .before_id = self.dupeOpt(before_id),
            .id = self.dupe(id),
            .html = self.dupe(html),
        } });
    }

    pub fn remove(self: *PatchLog, id: []const u8) void {
        self.push(.{ .remove = .{ .id = self.dupe(id) } });
    }

    pub fn move(self: *PatchLog, parent_id: []const u8, id: []const u8, before_id: ?[]const u8) void {
        self.push(.{ .move = .{
            .parent_id = self.dupe(parent_id),
            .id = self.dupe(id),
            .before_id = self.dupeOpt(before_id),
        } });
    }

    pub fn setText(self: *PatchLog, id: []const u8, text: []const u8) void {
        self.push(.{ .text = .{ .id = self.dupe(id), .text = self.dupe(text) } });
    }

    pub fn setAttr(self: *PatchLog, id: []const u8, name: []const u8, value: ?[]const u8) void {
        self.push(.{ .attr = .{
            .id = self.dupe(id),
            .name = self.dupe(name),
            .value = self.dupeOpt(value),
        } });
    }

    /// Serialize as `{"rev":N,"patches":[...]}`.
    pub fn writeJson(self: *const PatchLog, writer: anytype) !void {
        try writer.writeAll("{\"rev\":");
        try writer.print("{d}", .{self.revision});
        try writer.writeAll(",\"patches\":[");
        for (self.patches.items, 0..) |p, i| {
            if (i != 0) try writer.writeByte(',');
            switch (p) {
                .create => |c| {
                    try writer.writeAll("{\"op\":\"create\",\"parent\":");
                    try writeJsonStringInto(writer, c.parent_id);
                    try writer.writeAll(",\"id\":");
                    try writeJsonStringInto(writer, c.id);
                    try writer.writeAll(",\"before\":");
                    try writeOptJsonString(writer, c.before_id);
                    try writer.writeAll(",\"html\":");
                    try writeJsonStringInto(writer, c.html);
                    try writer.writeByte('}');
                },
                .remove => |r| {
                    try writer.writeAll("{\"op\":\"remove\",\"id\":");
                    try writeJsonStringInto(writer, r.id);
                    try writer.writeByte('}');
                },
                .move => |m| {
                    try writer.writeAll("{\"op\":\"move\",\"parent\":");
                    try writeJsonStringInto(writer, m.parent_id);
                    try writer.writeAll(",\"id\":");
                    try writeJsonStringInto(writer, m.id);
                    try writer.writeAll(",\"before\":");
                    try writeOptJsonString(writer, m.before_id);
                    try writer.writeByte('}');
                },
                .text => |t| {
                    try writer.writeAll("{\"op\":\"text\",\"id\":");
                    try writeJsonStringInto(writer, t.id);
                    try writer.writeAll(",\"text\":");
                    try writeJsonStringInto(writer, t.text);
                    try writer.writeByte('}');
                },
                .attr => |a| {
                    try writer.writeAll("{\"op\":\"attr\",\"id\":");
                    try writeJsonStringInto(writer, a.id);
                    try writer.writeAll(",\"name\":");
                    try writeJsonStringInto(writer, a.name);
                    try writer.writeAll(",\"value\":");
                    try writeOptJsonString(writer, a.value);
                    try writer.writeByte('}');
                },
            }
        }
        try writer.writeAll("]}");
    }

    fn writeOptJsonString(writer: anytype, s: ?[]const u8) !void {
        if (s) |v| {
            try writeJsonStringInto(writer, v);
        } else {
            try writer.writeAll("null");
        }
    }
};

test "escapeHtml escapes markup characters" {
    const got = try escapeHtml(std.testing.allocator, "<b>&\"'x</b>");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("&lt;b&gt;&amp;&quot;&#39;x&lt;/b&gt;", got);
}

test "patch log serializes owned strings to JSON" {
    var log = PatchLog.init(std.testing.allocator);
    defer log.deinit();

    const tmp = "row-<7>"; // temporary buffer
    log.create("list", null, tmp, "<li>safe &amp; sound</li>");
    log.setText("count", "2 left");
    log.setAttr("flt-all", "data-active", "1");
    log.setAttr("flt-all", "hidden", null);
    log.move("list", "row-3", "row-7");
    log.remove("row-9");
    log.revision = 4;

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try log.writeJson(&aw.writer);
    const got = try aw.toOwnedSlice();
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings(
        \\{"rev":4,"patches":[{"op":"create","parent":"list","id":"row-\u003c7\u003e","before":null,"html":"\u003cli\u003esafe \u0026amp; sound\u003c/li\u003e"},{"op":"text","id":"count","text":"2 left"},{"op":"attr","id":"flt-all","name":"data-active","value":"1"},{"op":"attr","id":"flt-all","name":"hidden","value":null},{"op":"move","parent":"list","id":"row-3","before":"row-7"},{"op":"remove","id":"row-9"}]}
    , got);
}

test "patch log deinit with live patches frees cleanly" {
    var log = PatchLog.init(std.testing.allocator);
    log.create("list", null, "row-1", "<li>x</li>");
    log.setText("count", "1 left");
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try log.writeJson(&aw.writer);
    const owned = try aw.toOwnedSlice();
    defer std.testing.allocator.free(owned);
    log.deinit();
    try std.testing.expectEqualStrings("{\"rev\":0", owned[0..8]);
}
