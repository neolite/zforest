//! "/wiki/[[...rest]]" — OPTIONAL catch-all: matches "/wiki" (rest =
//! "") and "/wiki/a/b/c" (rest = "a/b/c"). Contrast with
//! `docs/[...rest].zig`, which 404s on the bare prefix.
const std = @import("std");
const zmeta = @import("../../zmeta.zig");
const h = zmeta.h;

/// `[...name]`-family params are `[]const u8` slices of the path.
pub const params = struct { rest: []const u8 };

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) h.Node {
    _ = s;
    _ = env;
    const shown = if (p.rest.len == 0) "(root)" else p.rest;
    return h.div(a).children(.{
        h.h1(a).id("title").child("wiki").node(),
        h.p(a).id("rest").child(h.f(a, "rest={s}", .{shown})).node(),
        h.p(a).id("links").children(.{
            h.a(a).href("/wiki").child("/wiki").node(),
            " · ",
            h.a(a).href("/wiki/a/b").child("/wiki/a/b").node(),
            " · ",
            h.a(a).href("/docs").child("/docs (404s!)").node(),
        }).node(),
    }).node();
}
