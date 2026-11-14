//! "/" — the zmon dashboard: stat cards, traffic sliders, sparklines,
//! feed + request-log leaves, inject buttons. Built ONCE per session
//! into `deps.view_arena` (live bindings subscribe to the stores) —
//! `view` runs a single time, never per flush.
const std = @import("std");
const forest = @import("forest");
const zmeta = @import("../zmeta.zig");
const app = @import("../app.zig");

const Session = app.Session;

/// Route params — static route, empty struct (required by the contract).
pub const params = struct {};

pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {
    _ = p;
    _ = env;
    return buildView(a, s);
}

// ── view ──────────────────────────────────────────────────────────

fn card(a: std.mem.Allocator, id: []const u8, label: []const u8, val: anytype) forest.Node {
    return forest.el(a, .div, .{ .class = "card" }, .{
        forest.el(a, .div, .{ .class = "clabel" }, label),
        forest.el(a, .div, .{ .class = "cval", .id = id, .text = val }, .{}),
    });
}

fn btn(a: std.mem.Allocator, action: []const u8, label: []const u8) forest.Node {
    return forest.el(a, .button, .{ .class = "btn", .on = .{ .click = action } }, label);
}

/// Range slider bound to a model param via `change` → POST /action.
fn ctl(
    a: std.mem.Allocator,
    label: []const u8,
    action: []const u8,
    min: u32,
    max: u32,
    step: u32,
    val: anytype,
) forest.Node {
    return forest.el(a, .div, .{ .class = "ctl" }, .{
        forest.el(a, .span, .{ .class = "ctl-name" }, label),
        forest.el(a, .input, .{
            .type = "range",
            .min = min,
            .max = max,
            .step = step,
            .on = .{ .change = action },
        }, .{}),
        forest.el(a, .span, .{ .class = "ctl-val", .text = val }, .{}),
    });
}

/// Sparkline card: label + SVG polyline whose `points` attr is a live
/// leaf bound to a store (attr op per refresh — no rebuild).
fn spark(a: std.mem.Allocator, id: []const u8, label: []const u8, pts: anytype) forest.Node {
    return forest.el(a, .div, .{ .class = "spark" }, .{
        forest.el(a, .div, .{ .class = "clabel" }, label),
        forest.el(a, .svg, .{ .class = "spark-svg", .viewBox = "0 0 120 28" }, .{
            forest.el(a, .polyline, .{ .id = id, .class = "spark-line", .points = pts, .fill = "none" }, .{}),
        }),
    });
}

fn errPctText(a: std.mem.Allocator, bp: u64) []const u8 {
    return std.fmt.allocPrint(a, "{d}.{d}%", .{ bp / 100, bp % 100 }) catch "—";
}

fn statusText(_: std.mem.Allocator, bp: u64) []const u8 {
    return if (bp > 500) "DEGRADED" else "HEALTHY";
}

fn buildView(a: std.mem.Allocator, s: *Session) forest.Node {
    const d = &s.deps;
    return forest.el(a, .div, .{ .class = "mon" }, .{
        forest.el(a, .div, .{ .class = "mon-head" }, .{
            forest.el(a, .span, .{ .class = "mon-title" }, "zmon — live ops"),
            // Structural fine-graining: the pill mounts/unmounts live via
            // a `variant` key bound to derived stores — no rebuild.
            forest.variant(a, .{ .id = "mon-pill-ok" }, d.st_ok, .{
                forest.el(a, .span, .{ .class = "mon-pill ok" }, "HEALTHY"),
            }),
            forest.variant(a, .{ .id = "mon-pill-bad" }, d.st_bad, .{
                forest.el(a, .span, .{ .class = "mon-pill bad" }, "DEGRADED"),
            }),
        }),
        forest.el(a, .div, .{ .class = "mon-grid" }, .{
            card(a, "mon-rps", "req/s", d.st_rps_s),
            card(a, "mon-err", "error rate", forest.computed(d.st_err_bp, errPctText)),
            card(a, "mon-lat", "avg latency", d.st_lat_s),
            card(a, "mon-total", "total reqs", d.st_total_s),
            card(a, "mon-up", "uptime", d.st_up_s),
            card(a, "mon-status", "status", forest.computed(d.st_err_bp, statusText)),
        }),
        forest.el(a, .div, .{ .class = "mon-controls" }, .{
            ctl(a, "traffic", "ctl_rate", 0, 500, 10, d.st_p_rate),
            ctl(a, "errors", "ctl_err", 0, 3000, 50, d.st_p_err),
            ctl(a, "latency", "ctl_lat", 0, 400, 10, d.st_p_lat),
        }),
        forest.el(a, .div, .{ .class = "mon-sparks" }, .{
            spark(a, "sp-rps", "req/s", d.st_sp_rps),
            spark(a, "sp-err", "errors %", d.st_sp_err),
            spark(a, "sp-lat", "latency ms", d.st_sp_lat),
        }),
        forest.el(a, .div, .{ .id = "feed", .class = "feed", .text = d.st_feed }, .{}),
        forest.el(a, .div, .{ .class = "mon-logwrap" }, .{
            forest.el(a, .div, .{ .class = "clabel" }, "request log"),
            forest.el(a, .div, .{ .id = "mon-log", .class = "mon-log", .text = d.st_log }, .{}),
        }),
        forest.el(a, .div, .{ .class = "mon-actions" }, .{
            btn(a, "inject_ok", "ok req"),
            btn(a, "inject_err", "err req"),
            btn(a, "inject_slow", "slow req"),
            btn(a, "inject_storm", "storm ×400"),
        }),
    });
}
