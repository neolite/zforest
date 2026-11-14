//! Framework-owned render context handed to `Deps.view`/`Deps.prepare`
//! — the v0 slice of the spec's §5.2 `Env`.
//!
//! Session state is reached through the `*Session` argument the view
//! receives; `Env` carries only what the FRAMEWORK resolved for this
//! render. Deliberately absent in v0 (they arrive with the routing
//! codegen step, §5.1-5.2):
//!
//!   - typed route params — routes are still raw paths; `setRoute`
//!     validation lives in `Deps.setRoute`, params don't exist yet;
//!   - request identity helpers — cookies arrive via the optional
//!     `Deps.readCookies` hook instead;
//!   - the shared-model render cursor — that is a render-group concern
//!     owned outside page code (§4.4); per-session apps have no cursor
//!     at all, and nothing reachable through `Env` may grow one.

const std = @import("std");

pub const Env = struct {
    /// Route path accepted by the last successful `setRoute` — "/" for
    /// single-page apps. Owned by the session; valid for the session's
    /// lifetime, not just the render.
    route: []const u8 = "/",
    /// Raw query string of the last page GET (no leading `?`, "" when
    /// absent) — owned by the session like `route`, so it stays
    /// readable across patch renders until the next navigation.
    /// Read params with `queryParam`; values are NOT URL-decoded.
    query: []const u8 = "",
};

/// First value of `name` in a raw query string ("a=1&b=2") —
/// `?`-less, `&`-separated, no URL-decoding (same convention as the
/// server's own `?r=`/`?x=` params).
pub fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

test "queryParam picks first value, missing name → null" {
    try std.testing.expectEqualStrings("zig", queryParam("q=zig&tag=lang", "q").?);
    try std.testing.expectEqualStrings("lang", queryParam("q=zig&tag=lang", "tag").?);
    try std.testing.expectEqualStrings("", queryParam("q=", "q").?);
    try std.testing.expect(queryParam("q=zig", "missing") == null);
    try std.testing.expect(queryParam("", "q") == null);
    try std.testing.expect(queryParam("flag", "flag") == null);
    // first occurrence wins
    try std.testing.expectEqualStrings("1", queryParam("a=1&a=2", "a").?);
}
