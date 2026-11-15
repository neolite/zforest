//! Root `_layout.zig` — wraps EVERY page of this app: the board chrome
//! (sidebar board list + auth-aware identity chip) around the page's
//! `inner` node. This is the old `buildView` wrapper, now expressed as
//! a layout: the generated `viewNodes` calls
//! `layout(a, s, env, page.view(...))` per route, so SSR, patch diffs
//! and SSE snapshots all see the wrapped tree.
//!
//! View state comes from `s.deps.viewEnv()` — the domain `ViewEnv`
//! (route/reply_to/sort/name/account) — NOT from `env`: render groups
//! build views through the same dispatch with a session stand-in that
//! has no request env (see groups.zig `GroupDeps`).
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const components = @import("../components.zig");
const model = @import("../model.zig");

/// Sidebar: real links (full navigation) + the auth-aware identity
/// chip. Anonymous viewers get "login · register" links; logged-in
/// viewers get "@name" plus a logout action button. `env.name` is the
/// resolved AUTH display name — identical for every member of a
/// render group, which is exactly why auth state is a group-key input.
fn navView(a: std.mem.Allocator, env: components.ViewEnv) forest.Node {
    var links: std.ArrayListUnmanaged(forest.Node) = .empty;
    const home_on = env.route == .home;
    links.append(a, forest.el(a, .a, .{ .href = components.homeHref(a), .class = if (home_on) "on" else null }, "⌂")) catch @panic("OOM");
    for (model.boards, 0..) |b, i| {
        const on = switch (env.route) {
            .board => |bi| bi == i,
            else => false,
        };
        links.append(a, forest.el(a, .a, .{
            .href = components.boardHref(a, b.slug),
            .class = if (on) "on" else null,
        }, b.title)) catch @panic("OOM");
    }
    // Identity chip is bound (`#who` + .text) so identity changes
    // patch in live.
    links.append(a, forest.el(a, .span, .{ .id = "who", .class = "who", .text = env.name }, .{})) catch @panic("OOM");
    if (env.account_id != null) {
        links.append(a, forest.el(a, .button, .{
            .class = "mini nav-logout",
            .on = .{ .click = "logout" },
        }, "log out")) catch @panic("OOM");
    } else {
        links.append(a, forest.el(a, .a, .{ .href = components.loginHref(a), .class = "auth-link" }, "login")) catch @panic("OOM");
        links.append(a, forest.text(" · ")) catch @panic("OOM");
        links.append(a, forest.el(a, .a, .{ .href = components.registerHref(a), .class = "auth-link" }, "register")) catch @panic("OOM");
    }
    return forest.el(a, .div, .{ .class = "bnav" }, links.toOwnedSlice(a) catch @panic("OOM"));
}

/// The `<main>` inner content: sidebar + the active page. Two top-level
/// nodes grouped in a transparent fragment — identical output to the
/// old `buildView`'s `[nav, .bmain]` pair on every consumer
/// (writeHtml/diff/writeSnapshotOps all expand fragments).
pub fn layout(
    a: std.mem.Allocator,
    s: anytype,
    env: *const zmeta.Env,
    inner: forest.Node,
) forest.Node {
    _ = env;
    const venv = s.deps.viewEnv();
    return forest.fragment(a, .{
        navView(a, venv),
        forest.el(a, .div, .{ .class = "bmain" }, inner),
    });
}
