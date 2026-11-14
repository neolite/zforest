//! GENERATED FILE — do not edit. Regenerate with `zig build zsx`
//! (src/zmeta/zsx.zig). Source: templates/comment_row.zsx
const std = @import("std");
const forest = @import("forest");

/// `templates/comment_row.zsx` — `a` is the render arena; `ctx` is the view model
/// (anytype: field accesses and calls inside {…} holes resolve
/// per call site — `a`, `ctx`, `std` and `forest` are in scope).
pub fn render(a: std.mem.Allocator, ctx: anytype) forest.Node {
    return forest.el(a, .li, .{
        .id = ctx.id_str,
        .class = "comment",
    }, .{
        forest.el(a, .div, .{
            .class = "cmeta",
        }, .{
            forest.el(a, .a, .{
                .class = "plink",
                .href = ctx.permalink,
            }, ctx.hash),
            forest.text(" · "),
            forest.el(a, .span, .{
                .class = "who",
            }, ctx.c.author),
            forest.text(" · "),
            forest.el(a, .span, .{
                .class = "ts",
            }, ctx.ts_str),
            forest.text(" "),
            forest.el(a, .button, .{
                .class = "reply-btn",
                .on = .{ .click = ctx.env.act_reply },
                .arg = ctx.num,
            }, forest.text("ответить")),
            forest.text(" "),
            forest.el(a, .button, .{
                .id = ctx.like_id,
                .class = "like-btn",
                .on = .{ .click = ctx.env.act_like },
                .arg = ctx.like_arg,
                .text = ctx.like_label,
            }, .{}),
        }),
        forest.el(a, .div, .{
            .class = "ctext",
        }, ctx.c.text),
        forest.when(a, .{ .id = ctx.rep_id }, ctx.replying, ctx.reply_form),
        forest.el(a, .ul, .{
            .lid = "kids",
            .class = "kids",
        }, forest.eachOf(a, ctx.c.children, ctx.env, ctx.kid_row)),
    });
}
