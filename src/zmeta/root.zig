//! zmeta — the meta-framework spike (docs/meta-framework.md §5).
//!
//! Plain source files, NOT a named build module: like `server/`, these
//! files are compiled into whichever exe module imports them relatively,
//! so `History`/`Dom`/`zefx`/`forest` types stay identical to the ones
//! `server/http.zig` sees. Apps import `zmeta/root.zig` (or the files
//! directly) — never `@import("zmeta")` as a package name.

pub const Env = @import("env.zig").Env;
pub const Session = @import("session.zig").Session;
