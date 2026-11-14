//! "/search" — query params: `env.query` carries the raw query string
//! (no `?`); `zmeta.queryParam` picks values out. The session owns the
//! copy, so the params stay stable across patch renders until the next
//! navigation — `/search?q=a` and `/search?q=b` share one session.
const std = @import("std");
const zmeta = @import("../zmeta.zig");
const h = zmeta.h;

pub const params = struct {};

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) h.Node {
    _ = s;
    _ = p;
    const q = zmeta.queryParam(env.query, "q") orelse "";
    const tag = zmeta.queryParam(env.query, "tag") orelse "any";
    const raw = if (env.query.len == 0) "(none)" else env.query;
    return h.div(a).children(.{
        h.h1(a).id("title").child("search").node(),
        h.p(a).id("q").child(h.f(a, "q={s} tag={s}", .{ q, tag })).node(),
        h.p(a).id("raw").child(h.f(a, "raw query: {s}", .{raw})).node(),
        h.p(a).id("links").children(.{
            h.a(a).href("/search?q=zig&tag=lang").child("zig+lang").node(),
            " · ",
            h.a(a).href("/search?q=").child("empty q").node(),
            " · ",
            h.a(a).href("/search").child("no query").node(),
        }).node(),
    }).node();
}
