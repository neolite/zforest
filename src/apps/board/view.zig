//! zboard view layer — domain route/env types, shared components
//! (nav, post cards, comment trees, forms) and the `buildView`
//! dispatcher. Session-side and render-group builds share this file:
//! `ViewEnv` carries every view input so groups render without a
//! session (see groups.zig). Route *parsing* lives in `gen/routes.zig`;
//! `pageOf` in app.zig maps generated routes onto the domain `Route`.
const std = @import("std");
const forest = @import("forest");
const model = @import("model.zig");
const routes = @import("gen/routes.zig");

/// Request routes: "/" home, "/b/<slug>", "/t/<post>", "/t/<post>/c/<comment>".
pub const Route = union(enum) {
    home,
    board: usize,
    thread: u64,
    comment: u64,
};

/// Top-level comment ordering on thread pages — a per-session
/// preference that is part of the render-group key (like reply_to):
/// sessions only share a view when their sort matches.
pub const Sort = enum { new, top };

/// Everything the view tree reads from session/group state: route,
/// inline-reply target, the resolved `#who` display name, and the cursor
/// `buildView` marks caught-up — the session's `seen_seq` or the render
/// group's `last_rendered_seq`. Group members share one env's worth of
/// inputs; that identity IS the render-group key (see groups.zig).
pub const ViewEnv = struct {
    route: Route,
    reply_to: ?u64 = null,
    /// Top-level comment order — `.new` newest-first (default),
    /// `.top` by like count. Mirrors the session's `sort`.
    sort: Sort = .new,
    /// Resolved display name for the `#who` chip ("Anon#N" / "anon") —
    /// post/comment authors still resolve their own tokens via `nameOf`.
    name: []const u8 = "anon",
    /// Cursor `buildView` stamps with `global_seq` — written only by view
    /// builds that actually sync tracked Dom state (diff/seed), never by
    /// incidental SSR/snapshot serialization of an already-current group.
    seen: ?*u64 = null,
};

// ── view helpers ──────────────────────────────────────────────────

/// Resolved display name for a user token ("Anon#N" / "anon").
pub fn nameOf(token: []const u8) []const u8 {
    if (token.len == 0) return "anon";
    return model.get().userName(token) orelse "anon";
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
fn boardHref(a: std.mem.Allocator, slug: []const u8) []const u8 {
    return routes.href(a, .{ .b = .{ .slug = slug } });
}

fn threadHref(a: std.mem.Allocator, post_id: u64) []const u8 {
    return routes.href(a, .{ .t = .{ .post = post_id } });
}

fn commentHref(a: std.mem.Allocator, post_id: u64, cid: u64) []const u8 {
    return routes.href(a, .{ .t_c = .{ .post = post_id, .comment = cid } });
}

fn homeHref(a: std.mem.Allocator) []const u8 {
    return routes.href(a, .{ .index = .{} });
}

// ── view components ───────────────────────────────────────────────

/// Sidebar: real links (full navigation) + the poster identity chip.
fn navView(a: std.mem.Allocator, env: ViewEnv) forest.Node {
    var links: std.ArrayListUnmanaged(forest.Node) = .empty;
    const home_on = env.route == .home;
    links.append(a, forest.el(a, .a, .{ .href = homeHref(a), .class = if (home_on) "on" else null }, "⌂")) catch @panic("OOM");
    for (model.boards, 0..) |b, i| {
        const on = switch (env.route) {
            .board => |bi| bi == i,
            else => false,
        };
        links.append(a, forest.el(a, .a, .{
            .href = boardHref(a, b.slug),
            .class = if (on) "on" else null,
        }, b.title)) catch @panic("OOM");
    }
    // Identity chip is bound (`#who` + .text) so the first POST's minted
    // "Anon#N" name patches in live. `env.name` is the RESOLVED display
    // name — identical for every member of a render group.
    links.append(a, forest.el(a, .span, .{ .id = "who", .class = "who", .text = env.name }, .{})) catch @panic("OOM");
    return forest.el(a, .div, .{ .class = "bnav" }, links.toOwnedSlice(a) catch @panic("OOM"));
}

/// Post card: #id, board, Anon, time, pre-wrap text, thread link with a
/// live comment count (diffed in place via `lid`).
/// `"c<id>"`/`"p<id>"` — the `data-arg` payload of like buttons.
fn likeArg(a: std.mem.Allocator, prefix: u8, id: u64) []const u8 {
    return std.fmt.allocPrint(a, "{c}{d}", .{ prefix, id }) catch @panic("OOM");
}

fn likeLabel(a: std.mem.Allocator, count: u32) []const u8 {
    return std.fmt.allocPrint(a, "\u{25B2} {d}", .{count}) catch @panic("OOM");
}

fn postCard(a: std.mem.Allocator, p: *const model.Post, show_link: bool) forest.Node {
    const mm = model.get();
    const count = mm.commentCount(p.id);
    const lcount = mm.likeCount(p.id);
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .div, .{ .class = "meta" }, .{
        forest.el(a, .span, .{ .class = "pid" }, std.fmt.allocPrint(a, "#{d}", .{p.id}) catch @panic("OOM")),
        forest.text(" · "),
        forest.el(a, .a, .{ .href = boardHref(a, p.board), .class = "bref" }, p.board),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "who" }, nameOf(p.user)),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "ts" }, fmtTs(a, p.ts)),
    })) catch @panic("OOM");
    kids.append(a, forest.el(a, .div, .{ .class = "ptext" }, p.text)) catch @panic("OOM");
    if (show_link) {
        kids.append(a, forest.el(a, .div, .{ .class = "actions" }, .{
            forest.el(a, .a, .{
                .lid = "go",
                .href = threadHref(a, p.id),
                .text = std.fmt.allocPrint(a, "→ тред ({d})", .{count}) catch @panic("OOM"),
            }, .{}),
            forest.text(" "),
            forest.el(a, .button, .{
                .id = std.fmt.allocPrint(a, "like-p{d}", .{p.id}) catch @panic("OOM"),
                .class = "like-btn",
                .on = .{ .click = "like" },
                .arg = likeArg(a, 'p', p.id),
                .text = likeLabel(a, lcount),
            }, .{}),
        })) catch @panic("OOM");
    }
    return forest.el(a, .div, .{
        .id = std.fmt.allocPrint(a, "post-{d}", .{p.id}) catch @panic("OOM"),
        .class = "post",
    }, kids.toOwnedSlice(a) catch @panic("OOM"));
}

/// New-post form: hidden `board` field + textarea; `post` action.
fn postForm(a: std.mem.Allocator, slug: []const u8) forest.Node {
    return forest.el(a, .form, .{
        .id = "post-form",
        .class = "post-form",
        .autocomplete = "off",
        .on = .{ .submit = "post" },
    }, .{
        forest.el(a, .input, .{ .type = "hidden", .name = "board", .value = slug }, .{}),
        forest.el(a, .textarea, .{
            .name = "text",
            .placeholder = "Текст поста…",
            .rows = "4",
            .maxlength = model.max_text_len,
            .autofocus = true,
        }, .{}),
        forest.el(a, .button, .{ .type = "submit" }, "Запостить"),
    });
}

/// Format a u64 id once per use site — shared by `data-arg`, hidden
/// `value`s and `#N` labels instead of a `{d}` fmt per binding per render.
fn u64str(a: std.mem.Allocator, v: u64) []const u8 {
    var buf: [24]u8 = undefined;
    return a.dupe(u8, std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable) catch @panic("OOM");
}

/// Comment form: hidden `post` (+ optional `parent`) + text input.
fn commentFormNodes(a: std.mem.Allocator, post_str: []const u8, parent_str: ?[]const u8, is_inline: bool) []const forest.Node {
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
        kids.append(a, forest.el(a, .button, .{ .type = "submit" }, "Комментировать")) catch @panic("OOM");
    }
    return kids.toOwnedSlice(a) catch @panic("OOM");
}

fn commentForm(a: std.mem.Allocator, post_id: u64, parent_id: ?u64) forest.Node {
    const post_str = u64str(a, post_id);
    const parent_str = if (parent_id) |pid| u64str(a, pid) else null;
    return forest.el(a, .form, .{
        .class = "comment-form",
        .autocomplete = "off",
        .on = .{ .submit = "comment" },
    }, commentFormNodes(a, post_str, parent_str, false));
}

/// Inline reply form mounted under comment `c` via the `w-rep-N` anchor.
fn replyForm(a: std.mem.Allocator, post_str: []const u8, parent_str: []const u8) forest.Node {
    return forest.el(a, .form, .{
        .class = "reply-form",
        .autocomplete = "off",
        .on = .{ .submit = "comment" },
    }, commentFormNodes(a, post_str, parent_str, true));
}

/// One comment node: meta (id, Anon, time, «ответить»), text, the inline
/// reply `when` anchor, and a nested keyed `<ul>` of children.
/// `post_str` is the thread's post id pre-formatted once per view.
fn commentNode(a: std.mem.Allocator, env: ViewEnv, c: *const model.Comment, post_str: []const u8) forest.Node {
    const mm = model.get();
    const id_str = std.fmt.allocPrint(a, "cm-{d}", .{c.id}) catch @panic("OOM");
    const rep_id = std.fmt.allocPrint(a, "w-rep-{d}", .{c.id}) catch @panic("OOM");
    const replying = env.reply_to != null and env.reply_to.? == c.id;
    const num = u64str(a, c.id);
    const hash = std.fmt.allocPrint(a, "#{d}", .{c.id}) catch @panic("OOM");

    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .div, .{ .class = "cmeta" }, .{
        // #id doubles as the permalink to the comment page.
        forest.el(a, .a, .{
            .class = "plink",
            .href = commentHref(a, c.post, c.id),
        }, hash),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "who" }, nameOf(c.user)),
        forest.text(" · "),
        forest.el(a, .span, .{ .class = "ts" }, fmtTs(a, c.ts)),
        forest.text(" "),
        forest.el(a, .button, .{
            .class = "reply-btn",
            .on = .{ .click = "reply" },
            .arg = num,
        }, "ответить"),
        forest.text(" "),
        forest.el(a, .button, .{
            .id = std.fmt.allocPrint(a, "like-c{d}", .{c.id}) catch @panic("OOM"),
            .class = "like-btn",
            .on = .{ .click = "like" },
            .arg = likeArg(a, 'c', c.id),
            .text = likeLabel(a, mm.likeCount(c.id)),
        }, .{}),
    })) catch @panic("OOM");
    kids.append(a, forest.el(a, .div, .{ .class = "ctext" }, c.text)) catch @panic("OOM");
    // Inline reply form mounts between the text and the children list.
    kids.append(a, forest.when(a, .{ .id = rep_id }, replying, replyForm(a, post_str, num))) catch @panic("OOM");

    const kid_idx = mm.childIdx(a, c.id) catch @panic("OOM");
    var ck: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (kid_idx) |ci| {
        ck.append(a, commentNode(a, env, &mm.comments.items[ci], post_str)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .ul, .{ .lid = "kids", .class = "kids" }, forest.each(ck.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");

    return forest.el(a, .li, .{ .id = id_str, .class = "comment" }, kids.toOwnedSlice(a) catch @panic("OOM"));
}

fn crumbsView(a: std.mem.Allocator, post: *const model.Post, chain: []const u64) forest.Node {
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

fn notFoundView(a: std.mem.Allocator, what: []const u8) forest.Node {
    return forest.el(a, .p, .{ .class = "empty", .id = "not-found" }, what);
}

// ── routes ────────────────────────────────────────────────────────

fn homeView(a: std.mem.Allocator) forest.Node {
    const mm = model.get();
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .h1, .{}, .{
        forest.text("z"),
        forest.el(a, .span, .{}, "board"),
    })) catch @panic("OOM");
    kids.append(a, forest.el(a, .p, .{ .class = "boards-label" }, "Доски:")) catch @panic("OOM");
    var bl: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (model.boards) |b| {
        bl.append(a, forest.el(a, .li, .{}, forest.el(a, .a, .{ .href = boardHref(a, b.slug) }, b.title))) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .ul, .{ .class = "board-list" }, bl.toOwnedSlice(a) catch @panic("OOM"))) catch @panic("OOM");
    kids.append(a, forest.el(a, .h2, .{}, "Последнее:")) catch @panic("OOM");

    const latest_idx = mm.latestPostIdx(a, model.latest_home_count) catch @panic("OOM");
    var lp: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (latest_idx) |pi| {
        lp.append(a, postCard(a, &mm.posts.items[pi], true)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .div, .{ .id = "latest", .class = "posts" }, forest.each(lp.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    kids.append(a, forest.when(a, .{ .id = "w-latest-empty" }, latest_idx.len == 0, forest.el(a, .p, .{ .class = "empty" }, "Пока пусто — напиши первым пост."))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}

fn boardView(a: std.mem.Allocator, idx: usize) forest.Node {
    const b = model.boards[idx];
    const mm = model.get();
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, forest.el(a, .h1, .{}, b.title)) catch @panic("OOM");
    kids.append(a, postForm(a, b.slug)) catch @panic("OOM");

    const pidx = mm.boardPostIdx(a, b.slug) catch @panic("OOM");
    var pk: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (pidx) |pi| {
        pk.append(a, postCard(a, &mm.posts.items[pi], true)) catch @panic("OOM");
    }
    kids.append(a, forest.el(a, .div, .{ .id = "posts", .class = "posts" }, forest.each(pk.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    kids.append(a, forest.when(a, .{ .id = "w-board-empty" }, pidx.len == 0, forest.el(a, .p, .{ .class = "empty", .id = "empty-posts" }, "Пока пусто — напиши первым пост."))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}

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
fn sortBar(a: std.mem.Allocator, sort: Sort) forest.Node {
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

fn threadView(a: std.mem.Allocator, env: ViewEnv, post_id: u64) forest.Node {
    const mm = model.get();
    const p = mm.post(post_id) orelse {
        return notFoundView(a, "Тред не найден.");
    };
    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, crumbsView(a, p, &[_]u64{})) catch @panic("OOM");
    kids.append(a, postCard(a, p, false)) catch @panic("OOM");
    kids.append(a, commentForm(a, post_id, null)) catch @panic("OOM");

    const tops = mm.topCommentIdx(a, post_id) catch @panic("OOM");
    const ordered = sortTops(a, mm, tops, env.sort);
    const post_str = u64str(a, post_id);
    var ck: std.ArrayListUnmanaged(forest.Node) = .empty;
    for (ordered) |ci| {
        ck.append(a, commentNode(a, env, &mm.comments.items[ci], post_str)) catch @panic("OOM");
    }
    kids.append(a, sortBar(a, env.sort)) catch @panic("OOM");
    kids.append(a, forest.el(a, .ul, .{ .id = "comments", .class = "comments" }, forest.each(ck.toOwnedSlice(a) catch @panic("OOM")))) catch @panic("OOM");
    kids.append(a, forest.when(a, .{ .id = "w-comments-empty" }, tops.len == 0, forest.el(a, .p, .{ .class = "empty" }, "Нет комментариев — будь первым."))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}

fn commentView(a: std.mem.Allocator, env: ViewEnv, cid: u64) forest.Node {
    const mm = model.get();
    const c = mm.comment(cid) orelse {
        return notFoundView(a, "Комментарий не найден.");
    };
    const p = mm.post(c.post) orelse {
        return notFoundView(a, "Тред не найден.");
    };
    // Ancestor chain root→…→c (excluding c itself — it renders as root).
    var chain_rev: std.ArrayListUnmanaged(u64) = .empty;
    var cur: ?u64 = c.parent;
    while (cur) |pid| {
        const pc = mm.comment(pid) orelse break;
        chain_rev.append(a, pid) catch @panic("OOM");
        cur = pc.parent;
    }
    std.mem.reverse(u64, chain_rev.items);
    // The focused comment closes the crumb trail as a plain label.
    chain_rev.append(a, cid) catch @panic("OOM");

    var kids: std.ArrayListUnmanaged(forest.Node) = .empty;
    kids.append(a, crumbsView(a, p, chain_rev.items)) catch @panic("OOM");
    kids.append(a, commentForm(a, p.id, null)) catch @panic("OOM");
    // Arena-allocate the single-row slice — a `&.{…}` temporary would
    // dangle once the statement ends (the keyed list outlives it).
    const only = a.alloc(forest.Node, 1) catch @panic("OOM");
    only[0] = commentNode(a, env, c, u64str(a, p.id));
    kids.append(a, forest.el(a, .ul, .{ .id = "comments", .class = "comments" }, forest.each(only))) catch @panic("OOM");
    return forest.fragment(a, kids.toOwnedSlice(a) catch @panic("OOM"));
}

/// The `<main>` inner content: sidebar + the active route's page.
/// `env.seen` is the caught-up cursor — every shipped view marks it
/// synced to the shared model's mutation counter (the session's
/// `seen_seq`, or a render group's `last_rendered_seq` on group
/// seed/render builds only).
pub fn buildView(a: std.mem.Allocator, env: ViewEnv) []const forest.Node {
    if (env.seen) |p| p.* = model.get().global_seq.load(.seq_cst);
    const content = switch (env.route) {
        .home => homeView(a),
        .board => |i| boardView(a, i),
        .thread => |pid| threadView(a, env, pid),
        .comment => |cid| commentView(a, env, cid),
    };
    const nodes = a.alloc(forest.Node, 2) catch @panic("OOM");
    nodes[0] = navView(a, env);
    nodes[1] = forest.el(a, .div, .{ .class = "bmain" }, content);
    return nodes;
}

/// Single-node page body for the generated `viewNodes` convention —
/// `buildView`'s two top-level nodes wrapped in a fragment. Board's
/// real pipeline (Deps.view/buildViewNodes) calls `buildView`
/// directly; this exists so `pages/*/view` delegates stay honest.
pub fn page(a: std.mem.Allocator, env: ViewEnv) forest.Node {
    return forest.fragment(a, buildView(a, env));
}
