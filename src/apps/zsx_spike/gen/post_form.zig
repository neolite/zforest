//! GENERATED FILE — do not edit. Regenerate with `zig build zsx`
//! (src/zmeta/zsx.zig). Source: templates/post_form.zsx
const std = @import("std");
const forest = @import("forest");

/// `templates/post_form.zsx` — `a` is the render arena; `ctx` is the view model
/// (anytype: field accesses and calls inside {…} holes resolve
/// per call site — `a`, `ctx`, `std` and `forest` are in scope).
pub fn render(a: std.mem.Allocator, ctx: anytype) forest.Node {
    return forest.el(a, .form, .{
        .id = "post-form",
        .class = "post-form",
        .autocomplete = "off",
        .on = .{ .submit = ctx.act_post },
    }, .{
        forest.el(a, .input, .{
            .type = "hidden",
            .name = "board",
            .value = ctx.slug,
        }, .{}),
        forest.el(a, .textarea, .{
            .id = "post-text",
            .name = "text",
            .placeholder = ctx.placeholder,
            .rows = "4",
            .maxlength = ctx.max_len,
            .value = ctx.draft,
            .autofocus = true,
        }, .{}),
        forest.el(a, .button, .{
            .type = "submit",
        }, ctx.submit_label),
    });
}
