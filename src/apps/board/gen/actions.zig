//! GENERATED FILE — do not edit. Regenerate with `zig build gen`.
//! Source: actions.zig manifest (spec §2.9 v0 name table).

const std = @import("std");

/// Comptime action names shared by view `.on` attrs and the
/// dispatch skeleton — `act.like` in `.on = .{ .click = act.like }`
/// is compile-checked; the wire stays strings.
pub const act = struct {
    pub const post = "post";
    pub const comment = "comment";
    pub const reply = "reply";
    pub const cancel_reply = "cancel_reply";
    pub const sort = "sort";
    pub const like = "like";
};

/// Dispatch skeleton: each whitelisted action calls the app's
/// `on_<name>` decl on the Deps type (`@TypeOf(s.deps)`), with
/// the same (arg, value, fields) payload the session contract
/// receives. Unknown actions → error.InvalidAction.
pub fn dispatch(
    s: anytype,
    action: []const u8,
    arg: ?[]const u8,
    value: ?[]const u8,
    fields: ?*const std.json.ObjectMap,
) !void {
    const D = @TypeOf(s.deps);
    if (std.mem.eql(u8, action, act.post)) return D.on_post(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.comment)) return D.on_comment(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.reply)) return D.on_reply(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.cancel_reply)) return D.on_cancel_reply(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.sort)) return D.on_sort(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.like)) return D.on_like(s, arg, value, fields);
    return error.InvalidAction;
}
