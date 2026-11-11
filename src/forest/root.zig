const std = @import("std");

pub const patch = @import("patch.zig");
pub const dom = @import("dom.zig");

pub const Patch = patch.Patch;
pub const PatchLog = patch.PatchLog;
pub const escapeHtml = patch.escapeHtml;
pub const escapeHtmlInto = patch.escapeHtmlInto;
pub const Dom = dom.Dom;
pub const Row = dom.Row;

test {
    _ = patch;
    _ = dom;
}
