//! h.* handwritten equivalent of templates/comment_row.zsx +
//! templates/reply_form.zsx (the reply form is the row's `when`
//! branch). Same view, same Env. Counted as "h view code".
const std = @import("std");
const forest = @import("forest");
const h = @import("../../zmeta/h.zig");
const model = @import("model.zig");

pub const Env = model.Env;
pub const Comment = model.Comment;

/// templates/reply_form.zsx — inline reply form (when branch).
fn replyForm(a: std.mem.Allocator, env: *const Env, num: []const u8) forest.Node {
    return h.form(a)
        .class("reply-form")
        .attr("autocomplete", "off")
        .on(.submit, env.act_comment)
        .children(.{
            h.input(a).type("hidden").name("post").value(env.post_str).node(),
            h.input(a).type("hidden").name("parent").value(num).node(),
            h.input(a)
                .name("text")
                .placeholder("Ответить…")
                .attr("maxlength", env.max_len)
                .attr("autofocus", true)
                .node(),
            h.button(a).type("submit").class("mini").child("→").node(),
            h.button(a).type("button").class("mini cancel").on(.click, env.act_cancel).child("×").node(),
        })
        .node();
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

    return h.li(a)
        .id(id_str)
        .class("comment")
        .children(.{
            h.div(a)
                .class("cmeta")
                .children(.{
                    h.a(a).class("plink").href(perm).child(hash),
                    " · ",
                    h.span(a).class("who").child(c.author),
                    " · ",
                    h.span(a).class("ts").child(ts_str),
                    " ",
                    h.button(a).class("reply-btn").on(.click, env.act_reply).arg(num).child("ответить"),
                    " ",
                    h.button(a)
                        .id(like_id)
                        .class("like-btn")
                        .on(.click, env.act_like)
                        .arg(like_arg)
                        .text(like_label)
                        .node(),
                })
                .node(),
            h.div(a).class("ctext").child(c.text).node(),
            h.when(a, .{ .id = rep_id }, replying, replyForm(a, env, num)),
            h.ul(a)
                .lid("kids")
                .class("kids")
                .child(forest.eachOf(a, c.children, env, kidRow))
                .node(),
        })
        .node();
}
