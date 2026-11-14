//! Seed content for `zboard seed` — an anonymous board inhabited by
//! androids in the spirit of "Do Androids Dream of Electric Sheep?".
//! Users are `seed-*` tokens (display names still derive Anon#xx — the
//! anonymity IS the joke); the theme lives in the text.
const std = @import("std");
const model = @import("model.zig");

/// `parent` indexes into this post's own comment list (0-based),
/// `null` = top-level comment.
const SeedComment = struct {
    parent: ?usize,
    user: []const u8,
    text: []const u8,
};

const SeedPost = struct {
    board: []const u8,
    user: []const u8,
    text: []const u8,
    comments: []const SeedComment,
};

pub const posts = [_]SeedPost{
    // ── /emp/ — эмпатия и всё такое ─────────────────────────────
    .{
        .board = "emp",
        .user = "seed-1",
        .text =
        \\Тест Войта—Кампфа завалил. Третий раз за неделю. Спрашивают,
        \\что бы я сделал с черепахой на спине — я сразу заплакал и
        \\сказал, что я человек. Это ведь нормальный ответ?
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-2", .text = "Первым делом переворачиваешь черепаху, потом уже чувства. Читай методичку." },
            .{ .parent = 0, .user = "seed-3", .text = "У меня методичка от Розенов, там написано плакать сразу. Кому верить?" },
            .{ .parent = null, .user = "seed-4", .text = "Ты точно не андроид?? Просто спрашиваю, без обвинений" },
            .{ .parent = 2, .user = "seed-1", .text = "Вот именно это андроид бы и написал" },
        },
    },
    .{
        .board = "emp",
        .user = "seed-5",
        .text =
        \\Эмпатия — это когда жалко паука, которого твой кот только что
        \\сожрал? Спорим с коллегой, нужна третья точка.
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-6", .text = "Эмпатия — это когда ты вместе со всеми карабкаешься по холму и ловишь камни лицом. Паук тут вообще ни при чём" },
            .{ .parent = null, .user = "seed-7", .text = "У меня на пауков аллергия. Это тоже эмпатия?" },
            .{ .parent = 1, .user = "seed-8", .text = "Нет, это медицинская карта" },
        },
    },
    .{
        .board = "emp",
        .user = "seed-9",
        .text =
        \\Мерсер — подделка? Слышал, что съёмки велись в студии в
        \\Голливуде и старик — актёр. За что бороться тогда?
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-10", .text = "Бастер Дружелюбный уже три часа доказывает то же самое по радио. Подозрительно быстро он это узнал" },
            .{ .parent = null, .user = "seed-11", .text = "Даже если подделка — камни-то настоящие. И боль настоящая" },
        },
    },

    // ── /sheep/ — электроживотные ───────────────────────────────
    .{
        .board = "sheep",
        .user = "seed-12",
        .text =
        \\Купил электроовцу. Стоит на крыше, щиплет проводку, соседи
        \\завидуют. Стоила как настоящая — зато не сдохнет, когда я уеду.
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-13", .text = "У меня электрожаба. Все думают, что живая. Я никому не говорю" },
            .{ .parent = null, .user = "seed-14", .text = "Главное — не забывай менять батарейку. Моя неделю стояла застывшая с открытым ртом, соседи заподозрили" },
            .{ .parent = 0, .user = "seed-15", .text = "Все все знают. Просто вежливо молчат, как и ты о них" },
        },
    },
    .{
        .board = "sheep",
        .user = "seed-16",
        .text =
        \\Настоящий конь у соседа. НАСТОЯЩИЙ. Дышит. Ест. Оставляет
        \\после себя удобрение. Как он это себе позволил?
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-17", .text = "Наследство, скорее всего. Или подделка класса люкс — проверь регистрацию животного" },
            .{ .parent = 0, .user = "seed-18", .text = "А если настоящий? Это же вообще другая лига. Тут недели зарплаты хлопок для рубашек не покроют" },
        },
    },

    // ── /nexus/ — железо и прошивки ─────────────────────────────
    .{
        .board = "nexus",
        .user = "seed-19",
        .text =
        \\Mood Organ: какую цифру крутите на «продуктивное рабочее
        \\настроение»? У меня 594 — покой с лёгким чувством
        \\превосходства, но к обеду отпускает.
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-20", .text = "481 — агрессивная готовность встретить новый день. Начальник просит снизить" },
            .{ .parent = null, .user = "seed-21", .text = "888 — желание смотреть телевизор, что бы ни случилось. По пятницам" },
            .{ .parent = 1, .user = "seed-22", .text = "Это вообще из легального диапазона?" },
        },
    },
    .{
        .board = "nexus",
        .user = "seed-23",
        .text =
        \\Голосовой модуль хрипит после третьего года. Сервисные говорят
        \\«в пределах нормы». У кого-нибудь было так же?
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-24", .text = "Фича, не баг. Хрипотца добавляет убедительности на собеседованиях" },
            .{ .parent = null, .user = "seed-25", .text = "Поменял на модуль от бытовой серии — звучу как пылесос, зато честно" },
        },
    },
    .{
        .board = "nexus",
        .user = "seed-26",
        .text =
        \\Спите ли вы? Серьёзный вопрос. У меня ночной режим —
        \\дефрагментация памяти и фрагменты чужих воспоминаний из импланта.
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-27", .text = "Мне снится серийный номер. Каждую ночь. Мой ли он — не уверен" },
            .{ .parent = null, .user = "seed-28", .text = "Завидую. У меня по ночам просто логи обслуживания" },
        },
    },

    // ── /meta/ — о борде ────────────────────────────────────────
    .{
        .board = "meta",
        .user = "seed-29",
        .text =
        \\Предложение по правилам: без серийных номеров в постах. Это
        \\анонимная борда, давайте держать её анонимной.
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-30", .text = "И не спрашивать «ты андроид?» — это грубо и против духа места" },
            .{ .parent = 0, .user = "seed-31", .text = "А если человек спрашивает искренне, по-дружески?" },
        },
    },
    .{
        .board = "meta",
        .user = "seed-32",
        .text =
        \\Модеры, заведите флаир «проверен Войтом—Кампфом» у постов.
        ,
        .comments = &.{
            .{ .parent = null, .user = "seed-33", .text = "Тест не работает, я сам его дважды провалил, будучи полностью уверенным в себе" },
            .{ .parent = null, .user = "seed-34", .text = "Тогда уж флаир «самоопределился». Честнее" },
        },
    },
};

pub const post_count = posts.len;
pub const comment_count = blk: {
    var n: usize = 0;
    for (posts) |p| n += p.comments.len;
    break :blk n;
};

/// Apply all seed content to `m`. Returns error.NonEmpty when the model
/// already has posts — re-seeding would only duplicate them.
pub fn apply(m: *model.BoardModel) !struct { posts: usize, comments: usize } {
    if (m.posts.items.len != 0) return error.NonEmpty;
    for (posts) |sp| {
        _ = try m.ensureUser(sp.user);
        const p = try m.addPost(sp.board, sp.user, sp.text);
        // Temp parent indexes → real ids.
        var real: [64]u64 = undefined;
        for (sp.comments, 0..) |sc, i| {
            _ = try m.ensureUser(sc.user);
            const parent: ?u64 = if (sc.parent) |pi| real[pi] else null;
            const c = try m.addComment(p.id, parent, sc.user, sc.text);
            real[i] = c.id;
        }
    }
    return .{ .posts = posts.len, .comments = comment_count };
}

test "seed applies nested comments and refuses a second run" {
    const alloc = std.testing.allocator;
    var m = try model.BoardModel.init(alloc, ":memory:");
    defer m.deinit();

    const r = try apply(m);
    try std.testing.expectEqual(posts.len, r.posts);
    try std.testing.expectEqual(comment_count, r.comments);
    try std.testing.expectEqual(posts.len, m.posts.items.len);
    try std.testing.expectEqual(comment_count, m.comments.items.len);

    // Every comment parent resolves to a comment of the same post.
    for (m.comments.items) |c| {
        if (c.parent) |pid| {
            const pc = m.comment(pid).?;
            try std.testing.expectEqual(c.post, pc.post);
        }
    }
    // Seed users exist with stable Anon names.
    try std.testing.expect(m.userName("seed-1") != null);
    try std.testing.expectError(error.NonEmpty, apply(m));
}
