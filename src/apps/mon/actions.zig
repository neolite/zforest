//! zmeta action manifest — `zig build gen` turns these names into the
//! comptime `act` table + dispatch arms in `gen/actions.zig`. Each name
//! needs an `on_<name>` handler decl on the app's Deps type (app.zig);
//! view `.on` attrs reference `act.<name>` for compile-checked wiring.
pub const actions = .{
    "inject_ok",
    "inject_err",
    "inject_slow",
    "inject_storm",
    "ctl_rate",
    "ctl_err",
    "ctl_lat",
};
