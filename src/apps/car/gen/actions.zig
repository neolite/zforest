//! GENERATED FILE — do not edit. Regenerate with `zig build gen`.
//! Source: actions.zig manifest (spec §2.9 v0 name table).

const std = @import("std");

/// Comptime action names shared by view `.on` attrs and the
/// dispatch skeleton — `act.like` in `.on = .{ .click = act.like }`
/// is compile-checked; the wire stays strings.
pub const act = struct {
    pub const set_brand = "set_brand";
    pub const set_model = "set_model";
    pub const set_year = "set_year";
    pub const toggle_svc = "toggle_svc";
    pub const add_svc = "add_svc";
    pub const book = "book";
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
    if (std.mem.eql(u8, action, act.set_brand)) return D.on_set_brand(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.set_model)) return D.on_set_model(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.set_year)) return D.on_set_year(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.toggle_svc)) return D.on_toggle_svc(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.add_svc)) return D.on_add_svc(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.book)) return D.on_book(s, arg, value, fields);
    return error.InvalidAction;
}
