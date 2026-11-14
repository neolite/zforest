//! Per-app shim for the plain-source zmeta modules — keeps page/app
//! imports short (`@import("../zmeta.zig")`, `@import("../../zmeta.zig")`)
//! while preserving type identity: these are the SAME files
//! `zmeta/root.zig` exports, reached relatively like `server/` does.
//! zmeta is deliberately NOT a named build module (History type
//! identity — see zmeta/root.zig).
pub const Archetype = @import("../../zmeta/root.zig").Archetype;
pub const Env = @import("../../zmeta/root.zig").Env;
pub const Session = @import("../../zmeta/root.zig").Session;
pub const h = @import("../../zmeta/root.zig").h;
