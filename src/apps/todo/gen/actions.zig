//! GENERATED FILE — do not edit. Regenerate with `zig build gen`.
//! Source: actions.zig manifest (spec §2.9 v0 name table).

const std = @import("std");

/// Comptime action names shared by view `.on` attrs and the
/// dispatch skeleton — `act.like` in `.on = .{ .click = act.like }`
/// is compile-checked; the wire stays strings.
pub const act = struct {
    pub const add = "add";
    pub const toggle = "toggle";
    pub const set_checked = "set_checked";
    pub const delete = "delete";
    pub const filter = "filter";
    pub const edit = "edit";
    pub const edit_save = "edit_save";
    pub const edit_cancel = "edit_cancel";
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
    if (std.mem.eql(u8, action, act.add)) return D.on_add(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.toggle)) return D.on_toggle(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.set_checked)) return D.on_set_checked(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.delete)) return D.on_delete(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.filter)) return D.on_filter(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.edit)) return D.on_edit(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.edit_save)) return D.on_edit_save(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.edit_cancel)) return D.on_edit_cancel(s, arg, value, fields);
    return error.InvalidAction;
}
