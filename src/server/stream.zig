const std = @import("std");
const forest = @import("forest");
// NOTE: no app imports here — this file compiles inside the `zserver`
// named module, which must stay framework-only. The snapshot test
// against the real todo view lives in `src/apps/todo/app.zig` and
// reaches `writeSnapshotJson` via `zserver.writeSnapshotJson`.

/// Serialize the full-state snapshot event payload: {"rev":N,"ops":[…]}.
/// `ops` is the declarative view emitted as an idempotent state dump —
/// `forest.writeSnapshotOps` over a freshly built view: keyed parents
/// become `html` ops, bound nodes become attr/text ops. Reads model
/// state only — never touches the pending patch log, so a snapshot can
/// never consume an unpublished action's patches.
/// `s` is duck-typed: `render_arena`, `buildViewNodes(a)`.
/// `rev` is passed explicitly: grouped sessions adopt their render
/// group's revision, which is not necessarily `s.seq.get()`.
pub fn writeSnapshotJson(s: anytype, rev: u64, writer: *std.Io.Writer) !void {
    try writer.print("{{\"rev\":{d},\"ops\":", .{rev});
    _ = s.render_arena.reset(.retain_capacity);
    const a = s.render_arena.allocator();
    try forest.writeSnapshotOps(a, s.buildViewNodes(a), writer);
    try writer.writeByte('}');
}
