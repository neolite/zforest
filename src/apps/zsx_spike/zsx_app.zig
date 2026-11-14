//! zsx spike — handwritten ctx glue around the GENERATED templates.
//! This file is counted as "zsx view code" in the LOC comparison:
//! the .zsx templates hold the markup, this file holds everything a
//! real app's view-model layer would (display strings, `forest.when`/
//! `eachOf` wiring, the `computed` like label). `render` takes
//! `ctx: anytype`, so ctx is an anonymous struct literal — no named
//! ctx types to declare.
const std = @import("std");
const forest = @import("forest");
const model = @import("model.zig");
const gen_post_form = @import("gen/post_form.zig");
const gen_reply_form = @import("gen/reply_form.zig");
const gen_comment_row = @import("gen/comment_row.zig");

pub const Env = model.Env;
pub const Comment = model.Comment;

// ── post form ─────────────────────────────────────────────────────

/// `templates/post_form.zsx` — ctx IS the shared Env (fields read
/// directly in the template's {…} holes).
pub fn postForm(a: std.mem.Allocator, env: *const Env) forest.Node {
    return gen_post_form.render(a, env);
}

// ── comment row ───────────────────────────────────────────────────

fn kidRow(a: std.mem.Allocator, env: *const Env, i: u32) ?forest.Node {
    return commentRow(a, env, i);
}

/// `templates/comment_row.zsx` — `i` indexes `env.pool`; child rows
/// recurse through the same template via `eachOf`. The ctx literal
/// below is the only "glue": derived strings formatted once, the
/// `computed` like label, the `when` branch node, and the reply
/// form's own ctx.
pub fn commentRow(a: std.mem.Allocator, env: *const Env, i: u32) forest.Node {
    const c = &env.pool[i];
    const num = model.u64str(a, c.id);
    const id_str = std.fmt.allocPrint(a, "cm-{d}", .{c.id}) catch @panic("OOM");
    const permalink = model.commentHref(a, env.post_id, c.id);
    const hash = std.fmt.allocPrint(a, "#{d}", .{c.id}) catch @panic("OOM");
    const ts_str = model.fmtTs(a, c.ts);
    const like_id = std.fmt.allocPrint(a, "like-c{d}", .{c.id}) catch @panic("OOM");
    const like_arg = std.fmt.allocPrint(a, "c{d}", .{c.id}) catch @panic("OOM");
    const like_label = forest.computed(&env.likes[i], model.likeLabel);
    const rep_id = std.fmt.allocPrint(a, "w-rep-{d}", .{c.id}) catch @panic("OOM");
    const replying = env.reply_to != null and env.reply_to.? == c.id;
    const reply_form = gen_reply_form.render(a, .{ .env = env, .num = num });
    return gen_comment_row.render(a, .{
        .env = env,
        .c = c,
        .id_str = id_str,
        .permalink = permalink,
        .hash = hash,
        .ts_str = ts_str,
        .num = num,
        .like_id = like_id,
        .like_arg = like_arg,
        .like_label = like_label,
        .rep_id = rep_id,
        .replying = replying,
        .reply_form = reply_form,
        .kid_row = kidRow,
    });
}
