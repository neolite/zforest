//! Root `_middleware.zig` — runs inside the generated `prepare`
//! dispatch BEFORE each page's own `prepare`, for every page route
//! (`pages/api/` endpoints skip it). Scoped exactly like layouts:
//! this file gates all pages; a `pages/item/_middleware.zig` would
//! add a second, inner gate for the item subtree only, running
//! outermost-first.
//!
//! `env` is immutable — middleware passes data through app-owned
//! `s.deps` fields. Here it counts page navigations: `prepare` runs
//! once per `servePage` (SSE snapshot/patch renders don't re-run it),
//! and the index page displays the total.
const zmeta = @import("../zmeta.zig");

pub fn middleware(s: anytype, env: *const zmeta.Env) !void {
    _ = env;
    s.deps.hits += 1;
}
