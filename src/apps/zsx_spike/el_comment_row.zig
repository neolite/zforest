//! forest.el handwritten equivalent of templates/comment_row.zsx +
//! templates/reply_form.zsx. Same view, same Env. Counted as
//! "forest.el view code" in the LOC comparison.
const std = @import("std");
const forest = @import("forest");
const model = @import("model.zig");

pub const Env = model.Env;
pub const Comment = model.Comment;

/// templates/reply_form.zsx — inline reply form (when branch).
fn replyForm(a: std.mem.Allocator, env: *const Env, num: []const u8) forest.Node {
    return forest.el(a, .form, .{
        .class = "reply-form",
        .autocomplete = "off",
        .on = .{ .submit = env.act_comment },
    }, .{
        forest.el(a, .input, .{ .type = "hidden", .name = "post", .value = env.post_str }, .{}),
        forest.el(a, .input, .{ .type = "hidden", .name = "parent", .value = num }, .{}),
        forest.el(a, .input, .{
            .name = "text",
            .placeholder = "Ответить…",
            .maxlength = env.max_len,
            .autofocus = true,
        }, .{}),
        forest.el(a, .button, .{ .type = "submit", .class = "mini" }, "→"),
        forest.el(a, .button, .{
            .type = "button",
            .class = "mini cancel",
            .on = .{ .click = env.act_cancel },
        }, "×"),
    });
}

fn kidRow(a: std.mem.Allocator, env: *const Env, i: u32) ?forest.Node {
    return commentRow(a, env, i);
}

/// templates/comment_row.zsx — `i` indexes `env.pool`.
pub fn commentRow(a: std.mem.Allocator, env: *const Env, i: u32) forest.Node {
    const c = &env.pool[i];
    const num = model.u64str(a, c.id);
    const id_str = std.fmt.allocPrint(a, "cm-{d}", .{c.id}) catch @panic("OOM");
    const perm = model.commentHref(a, env.post_id, c.id);
    const hash = std.fmt.allocPrint(a, "#{d}", .{c.id}) catch @panic("OOM");
    const ts_str = model.fmtTs(a, c.ts);
    const like_id = std.fmt.allocPrint(a, "like-c{d}", .{c.id}) catch @panic("OOM");
    const like_arg = std.fmt.allocPrint(a, "c{d}", .{c.id}) catch @panic("OOM");
    const like_label = forest.computed(&env.likes[i], model.likeLabel);
    const rep_id = std.fmt.allocPrint(a, "w-rep-{d}", .{c.id}) catch @panic("OOM");
    const replying = env.reply_to != null and env.reply_to.? == c.id;

    return forest.el(a, .li, .{ .id = id_str, .class = "comment" }, .{
        forest.el(a, .div, .{ .class = "cmeta" }, .{
            forest.el(a, .a, .{ .class = "plink", .href = perm }, hash),
            forest.text(" · "),
            forest.el(a, .span, .{ .class = "who" }, c.author),
            forest.text(" · "),
            forest.el(a, .span, .{ .class = "ts" }, ts_str),
            forest.text(" "),
            forest.el(a, .button, .{
                .class = "reply-btn",
                .on = .{ .click = env.act_reply },
                .arg = num,
            }, "ответить"),
            forest.text(" "),
            forest.el(a, .button, .{
                .id = like_id,
                .class = "like-btn",
                .on = .{ .click = env.act_like },
                .arg = like_arg,
                .text = like_label,
            }, .{}),
        }),
        forest.el(a, .div, .{ .class = "ctext" }, c.text),
        forest.when(a, .{ .id = rep_id }, replying, replyForm(a, env, num)),
        forest.el(a, .ul, .{ .lid = "kids", .class = "kids" }, forest.eachOf(a, c.children, env, kidRow)),
    });
}
