//! "/live" — live-island demo: `pub const live = true` makes the
//! session build this view ONCE per servePage, then `forest.bindTree`
//! subscriptions push leaf ops on store notifications — no rebuild,
//! no diff (docs/meta-framework.md §2.3). Constraint: ALL dynamic
//! content must be store-bound; anything structural goes stale.
const std = @import("std");
const zmeta = @import("../zmeta.zig");
const h = zmeta.h;
const actions = @import("../gen/actions.zig");

/// Live-island opt-in — generated `routes.isLive` forwards here.
pub const live = true;

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) h.Node {
    _ = p;
    _ = env;
    return h.fragment(a, .{
        h.h1(a).id("live-title").child("live island").node(),
        h.p(a)
            .id("live-blurb")
            .child("view built once — store notifications push ops, no rebuild")
            .node(),
        h.button(a).id("tick-btn").on(.click, actions.act.tick).child("tick").node(),
        h.p(a).id("ticks").text(s.deps.ticks).node(),
    });
}
