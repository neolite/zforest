//! forest.el handwritten equivalent of templates/post_form.zsx —
//! same view, same Env, expressed with raw `forest.el` calls.
//! Counted as "forest.el view code" in the LOC comparison.
const std = @import("std");
const forest = @import("forest");
const model = @import("model.zig");

pub const Env = model.Env;

pub fn postForm(a: std.mem.Allocator, env: *const Env) forest.Node {
    return forest.el(a, .form, .{
        .id = "post-form",
        .class = "post-form",
        .autocomplete = "off",
        .on = .{ .submit = env.act_post },
    }, .{
        forest.el(a, .input, .{
            .type = "hidden",
            .name = "board",
            .value = env.slug,
        }, .{}),
        forest.el(a, .textarea, .{
            .id = "post-text",
            .name = "text",
            .placeholder = env.placeholder,
            .rows = "4",
            .maxlength = env.max_len,
            .value = env.draft,
            .autofocus = true,
        }, .{}),
        forest.el(a, .button, .{ .type = "submit" }, env.submit_label),
    });
}
