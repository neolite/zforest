//! zmeta — the meta-framework spike (docs/meta-framework.md §5).
//!
//! `zmeta` IS a named build module (build.zig): its root is this file,
//! with named imports `{zefx, forest, zserver}` so `History`/`Dom`/
//! `zefx`/`forest` types stay identical to the ones `server/http.zig`
//! and every app see — one type per program, enforced by the module
//! graph. Apps reach it through their per-app `zmeta.zig` shim
//! (`pub const Session = @import("zmeta").Session;` etc.), which keeps
//! page/app imports short without sacrificing type identity.

pub const Archetype = @import("session.zig").Archetype;
pub const Env = @import("env.zig").Env;
/// Per-page `<head>` override spec — page files return it from an
/// optional `pub fn head(a, s, p, env) ?zmeta.HeadSpec`.
pub const HeadSpec = @import("head.zig").HeadSpec;
pub const queryParam = @import("env.zig").queryParam;
pub const Session = @import("session.zig").Session;
/// Fluent HTML builder over `forest.view` — `h.div(a).id("x").node()`.
pub const h = @import("h.zig");
