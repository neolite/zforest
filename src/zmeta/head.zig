//! Per-page `<head>` overrides (docs/meta-framework.md §5.2): a page
//! file may declare
//!
//!   pub fn head(a: std.mem.Allocator, s: anytype, p: params,
//!       env: *const zmeta.Env) ?zmeta.HeadSpec { ... }
//!
//! returning a spec the server's `renderHead` merges over the
//! session/app defaults. The generated `routes.headSpec` dispatch
//! calls it once per page GET, AFTER `servePage` resolved the route —
//! so `prepare` has already run and `s.deps`/model reads see the same
//! state the view does. `head` is infallible by contract (returns
//! `?HeadSpec`, not an error union): allocate with
//! `catch @panic("OOM")`, or return null to decline overrides.
//!
//! Every field is optional; null keeps the default. Strings may be
//! allocated in `a` (the session's render arena in generated glue) —
//! they only need to outlive the response write, which happens
//! synchronously inside `renderHead`.
//!
//!   - `title`  overrides `<title>` (default: `Deps.page_title` /
//!     "zforest").
//!   - `extra`  raw HTML injected immediately before `</head>` —
//!     meta description, Open Graph, Twitter cards, JSON-LD,
//!     canonical link, extra stylesheets. NOT escaped; the page owns
//!     correctness (same trust level as `view` markup).
//!   - `lang`   overrides the `<html lang>` attribute (default:
//!     `Deps.page_lang` / "en").

const std = @import("std");

/// What a page's `head` fn may override. See the file header.
pub const HeadSpec = struct {
    /// `<title>` text — overrides `Deps.page_title` when non-null.
    title: ?[]const u8 = null,
    /// Raw markup appended before `</head>`.
    extra: ?[]const u8 = null,
    /// `<html lang>` value — overrides `Deps.page_lang` when non-null.
    lang: ?[]const u8 = null,
};

test "HeadSpec defaults are all-null" {
    const spec = HeadSpec{};
    try std.testing.expect(spec.title == null);
    try std.testing.expect(spec.extra == null);
    try std.testing.expect(spec.lang == null);
}

test "HeadSpec fields accept overrides" {
    const spec = HeadSpec{
        .title = "Post: hello",
        .extra = "<meta name=\"description\" content=\"x\">",
        .lang = "ru",
    };
    try std.testing.expectEqualStrings("Post: hello", spec.title.?);
    try std.testing.expectEqualStrings("ru", spec.lang.?);
}
