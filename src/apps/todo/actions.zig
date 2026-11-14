//! zmeta action manifest — `zig build gen` turns these names into the
//! comptime `act` table + dispatch arms in `gen/actions.zig`. Each name
//! needs an `on_<name>` handler decl on the app's Deps type (app.zig);
//! view `.on` attrs reference `act.<name>` for compile-checked wiring.
pub const actions = .{
    "add",
    "toggle",
    "set_checked",
    "delete",
    "filter",
    "edit",
    "edit_save",
    "edit_cancel",
};
