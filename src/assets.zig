//! Embedded web assets for the `zserver` transport: `client.js` is the
//! app-agnostic DOM patch renderer + `data-on-*` action POST plumbing,
//! `style.css` the shared styling. Both live at the `src/` root, so this
//! file — the `zassets` named module's root — is the only place that can
//! embed them: `server/http.zig`'s package path stops at `src/server/`,
//! which cannot reach `../client.js`. Only `zserver` imports `zassets`.
pub const client_js = @embedFile("client.js");
pub const style_css = @embedFile("style.css");
