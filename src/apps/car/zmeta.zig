//! Per-app shim over the `zmeta` named build module — keeps page/app
//! imports short (`@import("../../zmeta.zig")`, `@import("../zmeta.zig")`)
//! while preserving type identity: `zmeta` is a real named module
//! (build.zig), so `Session`/`Env`/`History` here are THE same types
//! `zserver`/`zefx`/`forest` see — never relative-import
//! `src/zmeta/` or `src/server/` from app code.
pub const Archetype = @import("zmeta").Archetype;
pub const Env = @import("zmeta").Env;
pub const Session = @import("zmeta").Session;
pub const queryParam = @import("zmeta").queryParam;
pub const h = @import("zmeta").h;
