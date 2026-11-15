//! zboard shared view components — domain route/env types, helpers
//! (nameOf/authorName/fmtTs/href builders) and every reusable piece of
//! markup (post cards, comment trees, forms, auth pages, sort bar).
//! Page views live inline in `pages/*.zig`; the board chrome (sidebar
//! + auth chip) lives in `pages/_layout.zig`. Session-side and
//! render-group builds share this file: `ViewEnv` carries every view
//! input so groups render without a session (see groups.zig). Route
//! *parsing* lives in `gen/routes.zig`; `pageOf` in app.zig maps
//! generated routes onto the domain `Route`.
const std = @import("std");
const forest = @import("forest");
const model = @import("model.zig");
const markdown = @import("markdown.zig");
const routes = @import("gen/routes.zig");

/// Request routes: "/" home, "/b/<slug>", "/t/<post>", "/t/<post>/c/<comment>",
/// "/login", "/register" (auth pages — static, no model rows). This is
/// the DOMAIN route — distinct from the generated wire `routes.Route`
/// (`index`/`b`/`t`/`t_c`/…): `/b/:slug` resolves to a board INDEX here
/// and the comment permalink keeps only the authoritative comment id.
/// Render-group keys, scope dispatch and `ViewEnv.route` all key on
/// this union (see groups.zig / app.zig `pageOf`).
pub const Route = union(enum) {
    home,
    board: usize,
    thread: u64,
    comment: u64,
    login,
    register,
};

/// Top-level comment ordering on thread pages — a per-session
/// preference that is part of the render-group key (like reply_to):
/// sessions only share a view when their sort matches.
pub const Sort = enum { new, top };

/// Everything the view tree reads from session/group state: route,
/// inline-reply target, the resolved `#who` display name, and the cursor
/// `viewEnv` marks caught-up — the session's `seen_seq` or the render
/// group's `last_rendered_seq`. Group members share one env's worth of
/// inputs; that identity IS the render-group key (see groups.zig).
///
/// Pages/layouts obtain one via `s.deps.viewEnv()` — `BoardDeps`
/// (app.zig) for real sessions, `GroupDeps` (groups.zig) for render
/// groups; both stamp `seen` because every call IS a view build.
pub const ViewEnv = struct {
    route: Route,
    reply_to: ?u64 = null,
    /// Top-level comment order — `.new` newest-first (default),
    /// `.top` by like count. Mirrors the session's `sort`.
    sort: Sort = .new,
    /// Resolved AUTH display name for the `#who` chip — "@<account>"
    /// when logged in, else the anonymous name ("Anon#N" / "anon").
    /// Post/comment authors still resolve their own tokens/accts via
    /// `authorName`. This IS a render-group key input (with
    /// `account_id`): every member of a group renders the same chrome.
    name: []const u8 = "anon",
    /// Viewer account id (null = anonymous) — gates own-content
    /// delete buttons and the "posting as" label. Group-key input.
    account_id: ?u64 = null,
    /// Cursor `viewEnv` stamps with `global_seq` — written only by view
    /// builds that actually sync tracked Dom state (diff/seed), never by
    /// incidental SSR/snapshot serialization of an already-current group.
    seen: ?*u64 = null,
};

// ── view helpers ──────────────────────────────────────────────────

/// Resolved display name for a user token ("Anon#N" / "anon").
/// Post/comment AUTHORS go through `authorName` instead — the trip
/// suffix is per-post content, so it must not leak into the `#who`
/// chip or the render-group key (both stay trip-free).
pub fn nameOf(token: []const u8) []const u8 {
    if (token.len == 0) return "anon";
    return model.get().userName(token) orelse "anon";
}

/// Post/comment author label: "@<account>" for account-owned rows
/// (the trip is ignored — account identity already proves authorship,
/// ADR-0001 phase 2), else "Anon#N" plus "!code" when the row carries
/// a trip hash (4chan-style per-post identity, ADR-0001 phase 1).
fn authorName(a: std.mem.Allocator, token: []const u8, trip: ?[]const u8, acct: ?u64) []const u8 {
    if (acct) |id| {
        const n = model.get().accountName(id) orelse return nameOf(token);
        return std.fmt.allocPrint(a, "@{s}", .{n}) catch @panic("OOM");
    }
    const base = nameOf(token);
    const code = model.tripCode(a, trip) orelse return base;
    return std.fmt.allocPrint(a, "{s}!{s}", .{ base, code }) catch @panic("OOM");
}

fn fmtTs(a: std.mem.Allocator, ts: i64) []const u8 {
    const secs = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = secs.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = secs.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>2}.{d:0>2} {d:0>2}:{d:0>2}", .{
        md.day_index + 1, md.month.numeric(), ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch @panic("OOM");
}

// Type-safe hrefs via the generated route table.
pub fn boardHref(a: std.mem.Allocator, slug: []const u8) []const u8 {
    return routes.href(a, .{ .b = .{ .slug = slug } });
}

pub fn threadHref(a: std.mem.Allocator, post_id: u64) []const u8 {
    return routes.href(a, .{ .t = .{ .post = post_id } });
}

pub fn commentHref(a: std.mem.Allocator, post_id: u64, cid: u64) []const u8 {
    return routes.href(a, .{ .t_c = .{ .post = post_id, .comment = cid } });
}

pub fn homeHref(a: std.mem.Allocator) []const u8 {
    return routes.href(a, .{ .index = .{} });
}

pub fn loginHref(a: std.mem.Allocator) []const u8 {
    return routes.href(a, .{ .login = .{} });
}

pub fn registerHref(a: std.mem.Allocator) []const u8 {
    return routes.href(a, .{ .register = .{} });
}

// ── view components ───────────────────────────────────────────────

/// `"c<id>"`/`"p<id>"` — the `data-arg` payload of like buttons.
fn likeArg(a: std.mem.Allocator, prefix: u8, id: u64) []const u8 {
    return std.fmt.allocPrint(a, "{c}{d}", .{ prefix, id }) catch @panic("OOM");
}

fn likeLabel(a: std.mem.Allocator, count: u32) []const u8 {
    return std.fmt.allocPrint(a, "\u{25B2} {d}", .{count}) catch @panic("OOM");
}

/// Format a u64 id once per use site — shared by `data-arg`, hidden
/// `value`s and `#N` labels instead of a `{d}` fmt per binding per render.
pub fn u64str(a: std.mem.Allocator, v: u64) []const u8 {
    var buf: [24]u8 = undefined;
    return a.dupe(u8, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable) catch @panic("OOM");
}

/// Own-content delete button — rendered only when the row's `acct`
/// matches the viewer's account (env.account_id); anonymous rows and
/// other accounts' rows never show it. `action` is "delete_post" or
/// "delete_comment"; the model re-checks ownership server-side.
fn deleteButton(a: std.mem.Allocator, action: []const u8, id: u64) forest.Node {
    return forest.el(a, .button, .{
        .class = "del-btn",
        .on = .{ .click = action },
        .arg = u64str(a, id),
    }, "del");
}

/// Post card: #id, board, Anon, time, markdown-rendered text (see
/// markdown.zig — the subset is documented there), thread link with a
/// live comment count (diffed in place via `lid`).
pub fn postCard(a: std.mem.Allocator, env: ViewEnv, p: *const model.Post, show_link: bool) forest.Node {
    const mm = model.get();
    const count = mm.commentCount(p.id);
    const lcount = mm.likeCount(p.id);
    const own = env.account_id != null and p.acct != null and p.acct.? == env.account_id.?;
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .div, .{ .class = "meta" }, .{
        forest.el(a, .span, .{ .class = "pid" }, std.fmt.allocPrint(a, "#{d}", .{p.id}) catch @panic("OOM")),
        forest.text(" · "),
        forest.el(a, .a, .{ .href = boardHref(a, p.board), .class = "bref" }, p.board),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "who" }, authorName(a, p.user, p.trip, p.acct)),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "ts" }, fmtTs(a, p.ts)),
    })) catch @panic("OOM");
    kids.append(a, forest.el(a, .div, .{ .class = "ptext" }, markdown.render(a, p.text))) catch @panic("OOM");
    if (show_link or own) {
        var acts: std.ArrayListUnmanaged(forest.Node) = .empty;
        if (show_link) {
            acts.append(a, forest.el(a, .a, .{
                .lid = "go",
                .href = threadHref(a, p.id),
                .text = std.fmt.allocPrint(a, "→ тред ({d})", .{count}) catch @panic("OOM"),
            }, .{})) catch @panic("OOM");
            acts.append(a, forest.text(" ")) catch @panic("OOM");
            acts.append(a, forest.el(a, .button, .{
                .id = std.fmt.allocPrint(a, "like-p{d}", .{p.id}) catch @panic("OOM"),
                .class = "like-btn",
                .on = .{ .click = "like" },
                .arg = likeArg(a, 'p', p.id),
                .text = likeLabel(a, lcount),
            }, .{})) catch @panic("OOM");
        }
        if (own) {
            acts.append(a, forest.text(" ")) catch @panic("OOM");
            acts.append(a, deleteButton(a, "delete_post", p.id)) catch @panic("OOM");
        }
        kids.append(a, forest.el(a, .div, .{ .class = "actions" }, acts.toOwnedSlice(a) catch @panic("OOM"))) catch @panic("OOM");
    }
    return forest.el(a, .div, .{
        .id = std.fmt.allocPrint(a, "post-{d}", .{p.id}) catch @panic("OOM"),
        .class = "post",
    }, kids.toOwnedSlice(a) catch @panic("OOM"));
}

/// "posting as @name" hint shown inside post/comment forms for
/// logged-in viewers (env.name is already the "@account" display).
fn postingAs(a: std.mem.Allocator, env: ViewEnv) ?forest.Node {
    if (env.account_id == null) return null;
    const label = std.fmt.allocPrint(a, "posting as {s}", .{env.name}) catch @panic("OOM");
    return forest.el(a, .div, .{ .class = "posting-as" }, label);
}

/// New-post form: hidden `board` field + textarea + optional `trip`
/// input; `post` action. `env` only feeds the posting-as hint.
pub fn postForm(a: std.mem.Allocator, env: ViewEnv, slug: []const u8) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .input, .{ .type = "hidden", .name = "board", .value = slug }, .{})) catch @panic("OOM");
    kids.append(a, forest.el(a, .textarea, .{
        .name = "text",
        .placeholder = "Текст поста…",
        .rows = "4",
        .maxlength = model.max_text_len,
        .autofocus = true,
    }, .{})) catch @panic("OOM");
    // Tripcode stays AFTER the text field: client.js's draft
    // stash/clear picks the first editable named input.
    kids.append(a, forest.el(a, .input, .{
        .name = "trip",
        .class = "trip",
        .type = "text",
        .placeholder = "tripcode (optional)",
        .maxlength = model.max_trip_len,
    }, .{})) catch @panic("OOM");
    if (postingAs(a, env)) |pa| kids.append(a, pa) catch @panic("OOM");
    kids.append(a, forest.el(a, .button, .{ .type = "submit" }, "Запостить")) catch @panic("OOM");
    return forest.el(a, .form, .{
        .id = "post-form",
        .class = "post-form",
        .autocomplete = "off",
        .on = .{ .submit = "post" },
    }, kids.toOwnedSlice(a) catch @panic("OOM"));
}

/// Comment form: hidden `post` (+ optional `parent`) + text input +
/// optional `trip` input + posting-as hint for account viewers.
pub fn commentForm(a: std.mem.Allocator, env: ViewEnv, post_id: u64, parent_id: ?u64) forest.Node {
    const post_str = u64str(a, post_id);
    const parent_str = if (parent_id) |pid| u64str(a, pid) else null;
    return forest.el(a, .form, .{
        .class = "comment-form",
        .autocomplete = "off",
        .on = .{ .submit = "comment" },
    }, commentFormNodes(a, env, post_str, parent_str, false));
}

/// Comment form node list — shared by `commentForm` (page-level) and
/// `replyForm` (inline, mounted under a comment via `w-rep-N`).
fn commentFormNodes(a: std.mem.Allocator, env: ViewEnv, post_str: []const u8, parent_str: ?[]const u8, is_inline: bool) []const forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .input, .{ .type = "hidden", .name = "post", .value = post_str }, .{})) catch @panic("OOM");
    if (parent_str) |ps| {
        kids.append(a, forest.el(a, .input, .{ .type = "hidden", .name = "parent", .value = ps }, .{})) catch @panic("OOM");
    }
    if (is_inline) {
        kids.append(a, forest.el(a, .input, .{
            .name = "text",
            .placeholder = "Ответить…",
            .maxlength = model.max_text_len,
            .autofocus = true,
        }, .{})) catch @panic("OOM");
        kids.append(a, forest.el(a, .input, .{
            .name = "trip",
            .class = "trip",
            .type = "text",
            .placeholder = "tripcode (optional)",
            .maxlength = model.max_trip_len,
        }, .{})) catch @panic("OOM");
        if (postingAs(a, env)) |pa| kids.append(a, pa) catch @panic("OOM");
        kids.append(a, forest.el(a, .button, .{ .type = "submit", .class = "mini" }, "→")) catch @panic("OOM");
        kids.append(a, forest.el(a, .button, .{
            .type = "button",
            .class = "mini cancel",
            .on = .{ .click = "cancel_reply" },
        }, "×")) catch @panic("OOM");
    } else {
        kids.append(a, forest.el(a, .textarea, .{
            .name = "text",
            .placeholder = "Комментарий…",
            .rows = "3",
            .maxlength = model.max_text_len,
            .autofocus = true,
        }, .{})) catch @panic("OOM");
        kids.append(a, forest.el(a, .input, .{
            .name = "trip",
            .class = "trip",
            .type = "text",
            .placeholder = "tripcode (optional)",
            .maxlength = model.max_trip_len,
        }, .{})) catch @panic("OOM");
        if (postingAs(a, env)) |pa| kids.append(a, pa) catch @panic("OOM");
        kids.append(a, forest.el(a, .button, .{ .type = "submit" }, "Комментировать")) catch @panic("OOM");
    }
    return kids.toOwnedSlice(a) catch @panic("OOM");
}

/// Inline reply form mounted under comment `c` via the `w-rep-N` anchor.
fn replyForm(a: std.mem.Allocator, env: ViewEnv, post_str: []const u8, parent_str: []const u8) forest.Node {
    return forest.el(a, .form, .{
        .class = "reply-form",
        .autocomplete = "off",
        .on = .{ .submit = "comment" },
    }, commentFormNodes(a, env, post_str, parent_str, true));
}

/// One comment node: meta (id, Anon, time, «ответить»), text, the inline
/// reply `when` anchor, and a nested keyed `<ul>` of children.
/// `post_str` is the thread's post id pre-formatted once per view.
pub fn commentNode(a: std.mem.Allocator, env: ViewEnv, c: *const model.Comment, post_str: []const u8) forest.Node {
    const mm = model.get();
    const id_str = std.fmt.allocPrint(a, "cm-{d}", .{c.id}) catch @panic("OOM");
    const rep_id = std.fmt.allocPrint(a, "w-rep-{d}", .{c.id}) catch @panic("OOM");
    const replying = env.reply_to != null and env.reply_to.? == c.id;
    const num = u64str(a, c.id);
    const hash = std.fmt.allocPrint(a, "#{d}", .{c.id}) catch @panic("OOM");
    const own = env.account_id != null and c.acct != null and c.acct.? == env.account_id.?;

    var meta_kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    meta_kids.append(a, forest.el(a, .a, .{
        .class = "plink",
        .href = commentHref(a, c.post, c.id),
    }, hash)) catch @panic("OOM");
    meta_kids.append(a, forest.text(" · ")) catch @panic("OOM");
    meta_kids.append(a, forest.el(a, .span, .{ .class = "who" }, authorName(a, c.user, c.trip, c.acct))) catch @panic("OOM");
    meta_kids.append(a, forest.text(" · ")) catch @panic("OOM");
    meta_kids.append(a, forest.el(a, .span, .{ .class = "ts" }, fmtTs(a, c.ts))) catch @panic("OOM");
    meta_kids.append(a, forest.text(" ")) catch @panic("OOM");
    meta_kids.append(a, forest.el(a, .button, .{
        .class = "reply-btn",
        .on = .{ .click = "reply" },
        .arg = num,
    }, "ответить")) catch @panic("OOM");
    meta_kids.append(a, forest.text(" ")) catch @panic("OOM");
    meta_kids.append(a, forest.el(a, .button, .{
        .id = std.fmt.allocPrint(a, "like-c{d}", .{c.id}) catch @panic("OOM"),
        .class = "like-btn",
        .on = .{ .click = "like" },
        .arg = likeArg(a, 'c', c.id),
        .text = likeLabel(a, mm.likeCount(c.id)),
    }, .{})) catch @panic("OOM");
    if (own) {
        meta_kids.append(a, forest.text(" ")) catch @panic("OOM");
        meta_kids.append(a, deleteButton(a, "delete_comment", c.id)) catch @panic("OOM");
    }

    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .div, .{ .class = "cmeta" }, meta_kids.toOwnedSlice(a) catch @panic("OOM"))) catch @panic("OOM");
    kids.append(a, forest.el(a, .div, .{ .class = "ctext" }, markdown.render(a, c.text))) catch @panic("OOM");
    // Inline reply form mounts between the text and the children list.
    kids.append(a, forest.when(a, .{ .id = rep_id }, replying, replyForm(a, env, post_str, num))) catch @panic("OOM");

    const kid_idx = mm.childIdx(a, c.id) catch @panic("OOM");
    var ck: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (kid_idx) |ci| {
        ck.append(a, commentNode(a, env, &mm.comments.items[ci], post_str)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .ul, .{ .lid = "kids", .class = "kids" }, forest.each(ck.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");

    return forest.el(a, .li, .{ .id = id_str, .class = "comment" }, kids.toOwnedSlice(a) catch @panic("OOM"));
}

pub fn crumbsView(a: std.mem.Allocator, post: *const model.Post, chain: []const u64) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .a, .{ .href = boardHref(a, post.board), .class = "bref" }, post.board)) catch @panic("OOM");
    kids.append(a, forest.text(" › ")) catch @panic("OOM");
    kids.append(a, forest.el(a, .a, .{ .href = threadHref(a, post.id) }, std.fmt.allocPrint(a, "#{d}", .{post.id}) catch @panic("OOM"))) catch @panic("OOM");
    for (chain, 0..) |cid, i| {
        kids.append(a, forest.text(" › ")) catch @panic("OOM");
        const is_last = i + 1 == chain.len;
        const label = std.fmt.allocPrint(a, "#{d}", .{cid}) catch @panic("OOM");
        if (is_last) {
            kids.append(a, forest.el(a, .span, .{ .class = "cid" }, label)) catch @panic("OOM");
        } else {
            kids.append(a, forest.el(a, .a, .{ .href = commentHref(a, post.id, cid) }, label)) catch @panic("OOM");
        }
    }
    return forest.el(a, .div, .{ .class = "crumbs" }, kids.toOwnedSlice(a) catch @panic("OOM"));
}

pub fn notFoundView(a: std.mem.Allocator, what: []const u8) forest.Node {
    return forest.el(a, .p, .{ .class = "empty", .id = "not-found" }, what);
}

// ── auth pages (ADR-0001 phase 2) ────────────────────────────────
// /login + /register are ordinary file-routed pages whose forms post
// the `login`/`register` actions through the same data-on-submit
// protocol as post/comment. Errors ride the existing path: a rejected
// action returns HTTP 400 and client.js's showError displays it.

/// One auth form input: placeholder doubles as the visible label.
pub fn authField(a: std.mem.Allocator, name: []const u8, ptype: []const u8, placeholder: []const u8, autocomplete: ?[]const u8) forest.Node {
    return forest.el(a, .input, .{
        .type = ptype,
        .name = name,
        .class = "auth-input",
        .placeholder = placeholder,
        .autocomplete = autocomplete,
        .required = true,
    }, .{});
}

/// Shared auth-page body: heading, optional already-authed note, the
/// form card, and cross-links. `fields` are the form's inputs (hidden
/// payload fields are NOT needed — login/register take `fields` only).
pub fn authPage(a: std.mem.Allocator, env: ViewEnv, title: []const u8, action_name: []const u8, fields: []const forest.Node, submit_label: []const u8, other: struct { label: []const u8, href: []const u8 }) forest.Node {
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .h1, .{}, title)) catch @panic("OOM");
    if (env.account_id != null) {
        const note = std.fmt.allocPrint(a, "Вы уже вошли как {s}.", .{env.name}) catch @panic("OOM");
        kids.append(a, forest.el(a, .p, .{ .class = "auth-note" }, note)) catch @panic("OOM");
    }
    var fkids: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (fields) |f| fkids.append(a, f) catch @panic("OOM");
    fkids.append(a, forest.el(a, .button, .{ .type = "submit", .class = "auth-submit" }, submit_label)) catch @panic("OOM");
    kids.append(a, forest.el(a, .form, .{
        .class = "auth-form",
        .autocomplete = "off",
        .on = .{ .submit = action_name },
    }, fkids.toOwnedSlice(a) catch @panic("OOM"))) catch @panic("OOM");
    kids.append(a, forest.el(a, .p, .{ .class = "auth-links" }, .{
        forest.el(a, .a, .{ .href = other.href }, other.label),
        forest.text(" · "),
        forest.el(a, .a, .{ .href = homeHref(a) }, "на главную"),
    })) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}

// ── routes ────────────────────────────────────────────────────────

/// Order top-level comment indices per the session's sort: `.new` =
/// newest first (id desc — tops arrive ascending), `.top` = likes desc
/// then newer first. Children stay chronological — sorting applies to
/// the top level only.
pub fn sortTops(a: std.mem.Allocator, mm: *model.BoardModel, tops: []const usize, sort: Sort) []const usize {
    const out = a.alloc(usize, tops.len) catch @panic("OOM");
    switch (sort) {
        .new => {
            var j: usize = 0;
            var i = tops.len;
            while (i > 0) : (i -= 1) {
                out[j] = tops[i - 1];
                j += 1;
            }
        },
        .top => {
            @memcpy(out, tops);
            std.sort.block(usize, out, mm, struct {
                fn less(mm2: *model.BoardModel, x: usize, y: usize) bool {
                    const cx = mm2.likeCount(mm2.comments.items[x].id);
                    const cy = mm2.likeCount(mm2.comments.items[y].id);
                    if (cx != cy) return cx > cy;
                    return mm2.comments.items[x].id > mm2.comments.items[y].id;
                }
            }.less);
        },
    }
    return out;
}

/// "сортировка: новые | топ" — per-session preference via the `sort`
/// action; the active mode gets the `sort-on` class.
pub fn sortBar(a: std.mem.Allocator, sort: Sort) forest.Node {
    return forest.el(a, .div, .{ .class = "sort-bar" }, .{
        forest.text("сортировка: "),
        forest.el(a, .button, .{
            .id = "sort-new",
            .class = if (sort == .new) "mini sort-on" else "mini",
            .on = .{ .click = "sort" },
            .arg = "new",
        }, "новые"),
        forest.text(" "),
        forest.el(a, .button, .{
            .id = "sort-top",
            .class = if (sort == .top) "mini sort-on" else "mini",
            .on = .{ .click = "sort" },
            .arg = "top",
        }, "топ"),
    });
}
