//! GENERATED FILE — do not edit. Regenerate with `zig build zsx`
//! (src/zmeta/zsx.zig). Source: templates/reply_form.zsx
const std = @import("std");
const forest = @import("forest");

/// `templates/reply_form.zsx` — `a` is the render arena; `ctx` is the view model
/// (anytype: field accesses and calls inside {…} holes resolve
/// per call site — `a`, `ctx`, `std` and `forest` are in scope).
pub fn render(a: std.mem.Allocator, ctx: anytype) forest.Node {
    return forest.el(a, .form, .{
        .class = "reply-form",
        .autocomplete = "off",
        .on = .{ .submit = ctx.env.act_comment },
    }, .{
        forest.el(a, .input, .{
            .type = "hidden",
            .name = "post",
            .value = ctx.env.post_str,
        }, .{}),
        forest.el(a, .input, .{
            .type = "hidden",
            .name = "parent",
            .value = ctx.num,
        }, .{}),
        forest.el(a, .input, .{
            .name = "text",
            .placeholder = "Ответить…",
            .maxlength = ctx.env.max_len,
            .autofocus = true,
        }, .{}),
        forest.el(a, .button, .{
            .type = "submit",
            .class = "mini",
        }, forest.text("→")),
        forest.el(a, .button, .{
            .type = "button",
            .class = "mini cancel",
            .on = .{ .click = ctx.env.act_cancel },
        }, forest.text("×")),
    });
}
