//! "/register" — account creation (ADR-0001 phase 2). Static route,
//! no params, no prepare gate; the form posts the `register` action
//! (register == auto-login).
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const components = @import("../components.zig");

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    const venv = s.deps.viewEnv();
    const fields = [_]forest.Node{
        components.authField(a, "name", "text", "имя (1–32: a-z 0-9 _ -)", "username"),
        components.authField(a, "password", "password", "пароль (мин. 8)", "new-password"),
        components.authField(a, "confirm", "password", "пароль ещё раз", "new-password"),
    };
    return components.authPage(a, venv, "Регистрация", "register", &fields, "Создать аккаунт", .{ .label = "уже есть аккаунт? вход", .href = components.loginHref(a) });
}
