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

pub const Env = struct {
    /// Route path accepted by the last successful `setRoute` — "/" for
    /// single-page apps. Owned by the session; valid for the session's
    /// lifetime, not just the render.
    route: []const u8 = "/",
};
