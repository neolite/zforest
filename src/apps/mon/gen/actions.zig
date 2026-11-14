//! GENERATED FILE — do not edit. Regenerate with `zig build gen`.
//! Source: actions.zig manifest (spec §2.9 v0 name table).

const std = @import("std");

/// Comptime action names shared by view `.on` attrs and the
/// dispatch skeleton — `act.like` in `.on = .{ .click = act.like }`
/// is compile-checked; the wire stays strings.
pub const act = struct {
    pub const inject_ok = "inject_ok";
    pub const inject_err = "inject_err";
    pub const inject_slow = "inject_slow";
    pub const inject_storm = "inject_storm";
    pub const ctl_rate = "ctl_rate";
    pub const ctl_err = "ctl_err";
    pub const ctl_lat = "ctl_lat";
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
    if (std.mem.eql(u8, action, act.inject_ok)) return D.on_inject_ok(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.inject_err)) return D.on_inject_err(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.inject_slow)) return D.on_inject_slow(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.inject_storm)) return D.on_inject_storm(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.ctl_rate)) return D.on_ctl_rate(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.ctl_err)) return D.on_ctl_err(s, arg, value, fields);
    if (std.mem.eql(u8, action, act.ctl_lat)) return D.on_ctl_lat(s, arg, value, fields);
    return error.InvalidAction;
}
