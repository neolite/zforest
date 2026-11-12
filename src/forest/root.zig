const std = @import("std");

pub const patch = @import("patch.zig");
pub const dom = @import("dom.zig");
pub const view = @import("view.zig");

pub const Patch = patch.Patch;
pub const PatchLog = patch.PatchLog;
pub const escapeHtml = patch.escapeHtml;
pub const escapeHtmlInto = patch.escapeHtmlInto;
pub const Dom = dom.Dom;
pub const Node = view.Node;
pub const Element = view.Element;
pub const Variant = view.Variant;
pub const Attr = view.Attr;
pub const Value = view.Value;
pub const Bound = view.Bound;
pub const Children = view.Children;
pub const Tag = view.Tag;
pub const el = view.el;
pub const text = view.text;
pub const raw = view.raw;
pub const each = view.each;
pub const eachOf = view.eachOf;
pub const fragment = view.fragment;
pub const variant = view.variant;
pub const when = view.when;
pub const computed = view.computed;
pub const writeHtml = view.writeHtml;
pub const writeSnapshotOps = view.writeSnapshotOps;
pub const diff = view.diff;
pub const bindTree = view.bindTree;
pub const Live = view.Live;
pub const AttachEnv = view.AttachEnv;
pub const Binder = view.Binder;

test {
    _ = patch;
    _ = dom;
    _ = view;
}
