//! h.* handwritten equivalent of templates/post_form.zsx — same view,
//! same Env, expressed with the fluent builder. Counted as "h view
//! code" in the LOC comparison.
const std = @import("std");
const forest = @import("forest");
const h = @import("../../zmeta/h.zig");
const model = @import("model.zig");

pub const Env = model.Env;

pub fn postForm(a: std.mem.Allocator, env: *const Env) forest.Node {
    return h.form(a)
        .id("post-form")
        .class("post-form")
        .attr("autocomplete", "off")
        .on(.submit, env.act_post)
        .children(.{
            h.input(a).type("hidden").name("board").value(env.slug).node(),
            h.textarea(a)
                .id("post-text")
                .name("text")
                .placeholder(env.placeholder)
                .attr("rows", "4")
                .attr("maxlength", env.max_len)
                .value(env.draft)
                .attr("autofocus", true)
                .node(),
            h.button(a).type("submit").child(env.submit_label).node(),
        })
        .node();
}
