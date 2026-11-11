const std = @import("std");
const stream_mod = @import("stream.zig");
const History = @import("history.zig").History;

const index_js = @embedFile("../client.js");
const style_css = @embedFile("../style.css");

const cookie_name = "zfxs"; // default; Session may declare `cookie_name`
const max_sessions = 32;
const max_body_len = 4096;
const max_conns = 128;
const head_buf_len = 8192;
const sse_poll_ms = 50;
const sse_heartbeat_ticks = 200; // 200 * 50ms ≈ 10s

/// Session contract for the generic server. A session type provides:
///
///   - `pub fn create(gpa: std.mem.Allocator) *Self` — wired constructor.
///   - `deinit()`, `csrf_token: []u8`, `setCsrf(token: []u8)`.
///   - `history: History` — retained patch batches for SSE replay.
///   - `seq: *zefx.Store(u64)` (or anything exposing `.get()`) — revision.
///   - `dispatch(action, arg, value, fields) !void` — the DOM event
///     protocol (see Action below); errors map via `statusOf`.
///   - `writeView(writer)` / `buildViewNodes(a) []const forest.Node`.
///   - `setRoute(path) bool` — request-path hook: false → 404. Multi-route
///     apps (board) implement real routing; single-page apps accept "/".
///   - `servePage(path, writer) !bool` — setRoute + dom.reset + writeView
///     + seedDom so tracked state matches the shipped page.
///   - `syncPull()` — called by the SSE worker every poll; sessions whose
///     model is shared (board) re-render when `model.global_seq` moved.
///   - `out_cookie: []const u8` — Set-Cookie value for the /action response
///     ("" = none); used to mint per-user cookies on first POST.
///   - `page_title` / `page_class` — <title> text and <main> class.
///   - `cookie_name` — session cookie name (avoid host-wide clobbering).
///   - Optional `readCookies(cookie_header)` — called before dispatch so
///     the session can pick up auxiliary cookies (board's `zfxu`).
///   - Optional `validPath(path) bool` — pure route check run before a
///     session is created for a GET; false → 404 without minting one.
///
/// Session registry. Demo cap: `max_sessions`, oldest session is evicted
/// (documented teardown policy — no persistence, no timers needed).
/// All access is serialized by `Server.mutex`.
pub fn SessionStore(comptime Session: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        by_token: std.StringHashMapUnmanaged(*Session) = .empty,
        order: std.ArrayListUnmanaged([]u8) = .empty,

        pub fn init(gpa: std.mem.Allocator, io: std.Io) Self {
            return .{ .gpa = gpa, .io = io };
        }

        pub fn deinit(self: *Self) void {
            for (self.order.items) |tok| {
                const s = self.by_token.get(tok).?;
                s.deinit();
                self.gpa.free(tok);
            }
            self.order.deinit(self.gpa);
            self.by_token.deinit(self.gpa);
        }

        pub fn lookup(self: *Self, token: []const u8) ?*Session {
            return self.by_token.get(token);
        }

        /// Create a session and return its fresh token (owned by the store).
        pub fn create(self: *Self) []u8 {
            if (self.order.items.len >= max_sessions) {
                const oldest = self.order.orderedRemove(0);
                const s = self.by_token.fetchRemove(oldest).?;
                s.value.deinit();
                self.gpa.free(oldest);
            }
            var rand_bytes: [16]u8 = undefined;
            self.io.random(&rand_bytes);
            const token = std.fmt.allocPrint(self.gpa, "{x:0>16}", .{std.mem.readInt(u64, rand_bytes[0..8], .little)}) catch @panic("OOM");
            const s = Session.create(self.gpa);
            s.setCsrf(std.fmt.allocPrint(self.gpa, "{x:0>32}", .{std.mem.readInt(u128, &rand_bytes, .little)}) catch @panic("OOM"));
            self.by_token.put(self.gpa, token, s) catch @panic("OOM");
            self.order.append(self.gpa, token) catch @panic("OOM");
            return token;
        }
    };
}

/// Shared server state. `mutex` serializes every access to the session
/// store, the reactive models, and the patch histories. It is NEVER held
/// while doing network I/O or sleeping — connection tasks read/write
/// sockets and poll outside the critical section.
pub fn Server(comptime Session: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        store: SessionStore(Session),
        mutex: std.Io.Mutex = .init,
        conns: std.atomic.Value(u32) = .init(0),
    };
}

fn cookieValue(cookie_header: ?[]const u8, name: []const u8) ?[]const u8 {
    const h = cookie_header orelse return null;
    var it = std.mem.splitScalar(u8, h, ';');
    while (it.next()) |part| {
        const kv = std.mem.trim(u8, part, " \t");
        if (kv.len > name.len and kv[name.len] == '=' and std.mem.eql(u8, kv[0..name.len], name)) {
            return kv[name.len + 1 ..];
        }
    }
    return null;
}

fn sessionCookieName(comptime Session: type) []const u8 {
    return if (@hasDecl(Session, "cookie_name")) Session.cookie_name else cookie_name;
}

/// Cross-origin POST guard: if an Origin header is present its host must
/// match the Host header. Requests without Origin (curl, same-origin form
/// posts rely on SameSite=Strict cookie anyway) are allowed.
fn sameOrigin(origin: ?[]const u8, host: ?[]const u8) bool {
    const o = origin orelse return true;
    const h = host orelse return false;
    const scheme_end = std.mem.indexOf(u8, o, "://") orelse return false;
    return std.mem.eql(u8, o[scheme_end + 3 ..], h);
}

/// Route key: path only, tolerating cache-busting query strings and
/// absolute-form targets sent by proxying clients.
fn requestPath(target: []const u8) []const u8 {
    var path = target;
    if (std.mem.indexOf(u8, path, "://")) |scheme_end| {
        const rest = path[scheme_end + 3 ..];
        path = rest[std.mem.indexOfScalar(u8, rest, '/') orelse rest.len ..];
    }
    return path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
}

/// The DOM event protocol posted to /action: `action` is the
/// `data-on-<event>` attribute, `arg` the `data-arg` payload, `value`
/// the changed element's new value, and `fields` an object of a
/// submitted form's named inputs. `unknown_fields` stay ignored.
const Action = struct {
    action: []const u8,
    arg: ?[]const u8 = null,
    value: ?[]const u8 = null,
    fields: ?std.json.Value = null,
};

fn statusOf(err: anyerror) std.http.Status {
    return switch (err) {
        error.TodoNotFound, error.PostNotFound, error.CommentNotFound, error.NotFound => .not_found,
        else => .bad_request,
    };
}

fn renderHead(comptime Session: type, s: *Session, out: anytype) !void {
    const title = if (@hasDecl(Session, "page_title")) Session.page_title else "zforest";
    const pclass = if (@hasDecl(Session, "page_class")) Session.page_class else "app";
    try out.writeAll(
        \\<!doctype html><html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>
    );
    try out.writeAll(title);
    try out.writeAll(
        \\</title><link rel="stylesheet" href="/style.css">
        \\<meta name="zforest-csrf" content="
    );
    try out.writeAll(s.csrf_token);
    try out.writeAll("\"><meta name=\"zforest-rev\" content=\"");
    var rbuf: [24]u8 = undefined;
    try out.writeAll(std.fmt.bufPrint(&rbuf, "{d}", .{s.seq.get()}) catch unreachable);
    try out.writeAll(
        "\"></head>\n<body><main class=\"",
    );
    try out.writeAll(pclass);
    try out.writeAll(
        "\">\n",
    );
}

fn renderTail(out: anytype) !void {
    try out.writeAll("</main><script src=\"/client.js?v=1\"></script></body></html>");
}

fn handle(
    comptime Session: type,
    srv: *Server(Session),
    arena: std.mem.Allocator,
    req: *std.http.Server.Request,
    out_body: *std.ArrayListUnmanaged(u8),
    extra: *std.ArrayListUnmanaged(std.http.Header),
) std.http.Status {
    const method = req.head.method;
    const path = requestPath(req.head.target);
    const cname = sessionCookieName(Session);

    var cookie_hdr: ?[]const u8 = null;
    var host_hdr: ?[]const u8 = null;
    var origin_hdr: ?[]const u8 = null;
    var csrf_hdr: ?[]const u8 = null;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) cookie_hdr = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host_hdr = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin_hdr = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "x-zforest-csrf")) csrf_hdr = h.value;
    }

    if (method == .POST and std.mem.eql(u8, path, "/action")) {
        // Fast locked precheck so unauthorized requests get 403 without
        // waiting on a body read (ordering identical to the old server).
        {
            srv.mutex.lockUncancelable(srv.io);
            defer srv.mutex.unlock(srv.io);
            const pre = if (cookieValue(cookie_hdr, cname)) |tok| srv.store.lookup(tok) else null;
            const ps = pre orelse return .forbidden;
            const pre_ok = csrf_hdr != null and std.mem.eql(u8, csrf_hdr.?, ps.csrf_token);
            if (!pre_ok and !sameOrigin(origin_hdr, host_hdr)) return .forbidden;
        }

        // Read and parse the bounded body BEFORE touching the model lock —
        // a slow client must not stall every other session.
        if (req.head.content_length == null or req.head.content_length.? > max_body_len)
            return .payload_too_large;
        var body_buf: [256]u8 = undefined;
        const reader = req.readerExpectNone(&body_buf);
        const body = reader.allocRemaining(arena, .limited(max_body_len)) catch return .bad_request;
        const parsed = std.json.parseFromSlice(Action, arena, body, .{ .ignore_unknown_fields = true }) catch return .bad_request;

        // One atomic critical section: session lookup + CSRF check +
        // apply + serialize + publish + clear. No network I/O inside.
        srv.mutex.lockUncancelable(srv.io);
        defer srv.mutex.unlock(srv.io);
        const entry = if (cookieValue(cookie_hdr, cname)) |tok| srv.store.lookup(tok) else null;
        const s = entry orelse return .forbidden;
        // CSRF: accept when the custom X-Zforest-CSRF header matches the
        // per-session token (browsers can't set custom headers cross-origin
        // without CORS, which we never grant), OR when Origin matches Host.
        // Everything else — cross-origin or no token — is rejected.
        const token_ok = csrf_hdr != null and std.mem.eql(u8, csrf_hdr.?, s.csrf_token);
        if (!token_ok and !sameOrigin(origin_hdr, host_hdr)) return .forbidden;

        // Let the session pick up auxiliary cookies (board's `zfxu`) before
        // the action runs — identity is established inside dispatch.
        if (@hasDecl(Session, "readCookies")) s.readCookies(cookie_hdr);

        const body_v = parsed.value;
        const fields: ?*const std.json.ObjectMap = if (body_v.fields) |*f| switch (f.*) {
            .object => |*m| m,
            else => null,
        } else null;
        s.dispatch(body_v.action, body_v.arg, body_v.value, fields) catch |err| return statusOf(err);

        // Publish the serialized batch to this session's history for SSE
        // replay; the response itself is only an ACK.
        var jaw: std.Io.Writer.Allocating = .init(srv.gpa);
        defer jaw.deinit();
        s.log.writeJson(&jaw.writer) catch @panic("OOM");
        const rev = s.seq.get();
        s.history.publish(rev, jaw.toOwnedSlice() catch @panic("OOM"));
        s.log.clear();

        // Per-action Set-Cookie hook (e.g. minted on first POST) — the
        // value stays valid in `extra` because the session owns it.
        if (s.out_cookie.len != 0) {
            extra.append(arena, .{ .name = "set-cookie", .value = s.out_cookie }) catch @panic("OOM");
        }

        var ack: std.Io.Writer.Allocating = .init(arena);
        ack.writer.print("{{\"rev\":{d}}}", .{rev}) catch @panic("OOM");
        out_body.appendSlice(arena, ack.writer.buffered()) catch @panic("OOM");
        extra.append(arena, .{ .name = "content-type", .value = "application/json" }) catch @panic("OOM");
        return .ok;
    }

    // Static assets — never session routes.
    if (method == .GET and std.mem.eql(u8, path, "/client.js")) {
        extra.append(arena, .{ .name = "content-type", .value = "text/javascript; charset=utf-8" }) catch @panic("OOM");
        out_body.appendSlice(arena, index_js) catch @panic("OOM");
        return .ok;
    }
    if (method == .GET and std.mem.eql(u8, path, "/style.css")) {
        extra.append(arena, .{ .name = "content-type", .value = "text/css; charset=utf-8" }) catch @panic("OOM");
        out_body.appendSlice(arena, style_css) catch @panic("OOM");
        return .ok;
    }

    // Every other GET is a page route resolved by the session type.
    if (method == .GET) {
        // "/index.html" is an alias for "/" on every app.
        const rpath = if (std.mem.eql(u8, path, "/index.html")) "/" else path;
        // Optional pure route check keeps bogus paths from minting sessions.
        if (@hasDecl(Session, "validPath") and !Session.validPath(rpath)) return .not_found;
        srv.mutex.lockUncancelable(srv.io);
        defer srv.mutex.unlock(srv.io);
        var token: []const u8 = undefined;
        const entry = if (cookieValue(cookie_hdr, cname)) |tok| srv.store.lookup(tok) else null;
        const e = entry orelse blk: {
            token = srv.store.create();
            break :blk srv.store.lookup(token).?;
        };
        extra.append(arena, .{ .name = "content-type", .value = "text/html; charset=utf-8" }) catch @panic("OOM");
        // Render into the request arena; servePage decides route validity.
        var aw: std.Io.Writer.Allocating = .init(arena);
        renderHead(Session, e, &aw.writer) catch @panic("OOM");
        const ok = e.servePage(rpath, &aw.writer) catch @panic("OOM");
        if (!ok) return .not_found;
        renderTail(&aw.writer) catch @panic("OOM");
        if (entry == null) {
            extra.append(arena, .{
                .name = "set-cookie",
                .value = std.fmt.allocPrint(arena, "{s}={s}; HttpOnly; SameSite=Strict; Path=/", .{ cname, token }) catch @panic("OOM"),
            }) catch @panic("OOM");
        }
        out_body.appendSlice(arena, aw.writer.buffered()) catch @panic("OOM");
        return .ok;
    }

    return .not_found;
}

fn writeChunk(out: *std.Io.Writer, data: []const u8) !void {
    try out.print("{x}\r\n{s}\r\n", .{ data.len, data });
    try out.flush();
}

/// Persistent Server-Sent Events stream, one per connection task.
///
/// Protocol:
///   event: snapshot — {"rev","ops"} on connect and whenever the
///     subscriber's cursor fell behind retained history. `ops` is the
///     declarative view serialized as a state dump (html/attr/text ops).
///   event: patch, id: {rev} — {"rev","patches"} for each mutation batch.
///   event: session_expired — once, then the connection closes.
///
/// Every poll re-acquires the model mutex, copies owned payload out, and
/// releases the lock before writing to the socket — a session can be
/// evicted between iterations, so no session pointer is retained.
fn serveEvents(comptime Session: type, srv: *Server(Session), req: *std.http.Server.Request) !void {
    var cookie_hdr: ?[]const u8 = null;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) cookie_hdr = h.value;
    }
    const token = try srv.gpa.dupe(u8, cookieValue(cookie_hdr, sessionCookieName(Session)) orelse "");
    defer srv.gpa.free(token);

    const out = req.server.out;
    try out.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-store\r\nx-accel-buffering: no\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n");
    try out.flush();

    var fw: std.Io.Writer.Allocating = .init(srv.gpa);
    defer fw.deinit();

    var cursor: u64 = 0;
    var connected = false; // rev 0 is a valid cursor, so track state instead
    var ticks: u32 = 0;
    while (true) {
        _ = fw.writer.consumeAll();
        var expired = false;
        {
            srv.mutex.lockUncancelable(srv.io);
            defer srv.mutex.unlock(srv.io);
            const s = srv.store.lookup(token);
            if (s) |sess| {
                if (!connected) {
                    connected = true;
                    cursor = sess.seq.get();
                    fw.writer.writeAll("event: snapshot\ndata: ") catch @panic("OOM");
                    stream_mod.writeSnapshotJson(sess, &fw.writer) catch @panic("OOM");
                    fw.writer.writeAll("\n\n") catch @panic("OOM");
                } else {
                    // Shared-model sessions (board) re-render when the
                    // global mutation counter moved; publish any produced
                    // batch (even patch-empty — keeps cursors contiguous).
                    sess.syncPull();
                    if (sess.seq.get() > sess.history.latest_rev) {
                        var jaw: std.Io.Writer.Allocating = .init(srv.gpa);
                        defer jaw.deinit();
                        sess.log.writeJson(&jaw.writer) catch @panic("OOM");
                        sess.history.publish(sess.seq.get(), jaw.toOwnedSlice() catch @panic("OOM"));
                        sess.log.clear();
                    }
                    const f = sess.history.fetch(cursor, srv.gpa) catch @panic("OOM");
                    defer History.freeFetch(srv.gpa, f);
                    switch (f) {
                        .gap => {
                            cursor = sess.seq.get();
                            fw.writer.writeAll("event: snapshot\ndata: ") catch @panic("OOM");
                            stream_mod.writeSnapshotJson(sess, &fw.writer) catch @panic("OOM");
                            fw.writer.writeAll("\n\n") catch @panic("OOM");
                        },
                        .batches => |batches| {
                            for (batches) |b| {
                                cursor = b.rev;
                                fw.writer.print("id: {d}\nevent: patch\ndata: {s}\n\n", .{ b.rev, b.data }) catch @panic("OOM");
                            }
                        },
                    }
                }
            } else {
                expired = true;
            }
        }
        if (expired) {
            try writeChunk(out, "event: session_expired\ndata: {}\n\n");
            break;
        }
        if (fw.writer.buffered().len > 0) try writeChunk(out, fw.writer.buffered());
        ticks += 1;
        if (ticks % sse_heartbeat_ticks == 0) try writeChunk(out, ": hb\n\n");
        std.Io.sleep(srv.io, .fromMilliseconds(sse_poll_ms), .awake) catch |e| switch (e) {
            error.Canceled => return,
        };
    }
    // Terminate the chunked body so the close is a valid HTTP stream end.
    out.writeAll("0\r\n\r\n") catch {};
    out.flush() catch {};
}

fn connTask(comptime Session: type, srv: *Server(Session), stream: std.Io.net.Stream) void {
    defer _ = srv.conns.fetchSub(1, .acq_rel);
    defer stream.close(srv.io);

    var arena_state = std.heap.ArenaAllocator.init(srv.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rbuf: [head_buf_len]u8 = undefined;
    var wbuf: [head_buf_len]u8 = undefined;
    var reader = stream.reader(srv.io, &rbuf);
    var writer = stream.writer(srv.io, &wbuf);
    var http_srv = std.http.Server.init(&reader.interface, &writer.interface);

    var req = http_srv.receiveHead() catch return;

    const path = requestPath(req.head.target);
    if (req.head.method == .GET and std.mem.eql(u8, path, "/events")) {
        serveEvents(Session, srv, &req) catch {};
        return;
    }

    var body: std.ArrayListUnmanaged(u8) = .empty;
    var extra: std.ArrayListUnmanaged(std.http.Header) = .empty;
    extra.append(arena, .{ .name = "x-content-type-options", .value = "nosniff" }) catch @panic("OOM");
    // Session HTML and action responses are per-session — never cache.
    extra.append(arena, .{ .name = "cache-control", .value = "no-store" }) catch @panic("OOM");

    const status = handle(Session, srv, arena, &req, &body, &extra);
    if (body.items.len == 0 and status != .ok) {
        body.appendSlice(arena, @tagName(status)) catch @panic("OOM");
    }
    req.respond(body.items, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = extra.items,
    }) catch {};
}

/// Demo server: at most `max_conns` concurrent worker tasks, spawned via
/// `std.Io.Group.concurrent` in the accept loop (thread-per-connection —
/// simple but not scalable like an event loop). Admissions beyond the cap
/// are closed before any HTTP headers are read. All session/model state is
/// serialized by `Server.mutex`, never held across network I/O.
pub fn serve(gpa: std.mem.Allocator, io: std.Io, bind: std.Io.net.Ip4Address, comptime Session: type) !void {
    var srv: Server(Session) = .{
        .gpa = gpa,
        .io = io,
        .store = SessionStore(Session).init(gpa, io),
    };
    defer srv.store.deinit();

    var addr: std.Io.net.IpAddress = .{ .ip4 = bind };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("listening on http://{f}\n", .{bind});

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = listener.accept(io) catch continue;
        // Admission is decided here, before spawning a worker: once
        // `max_conns` tasks are live the connection is closed without
        // reading a single header byte (documented overload behavior —
        // a pending client sees ECONNRESET, not a hung accept).
        if (srv.conns.fetchAdd(1, .acq_rel) >= max_conns) {
            _ = srv.conns.fetchSub(1, .acq_rel);
            stream.close(io);
            continue;
        }
        // `connTask` is generic over Session — instantiate it locally so
        // group.concurrent sees a fully-typed function pointer.
        const Task = struct {
            fn run(srvp: *Server(Session), st: std.Io.net.Stream) void {
                connTask(Session, srvp, st);
            }
        };
        group.concurrent(io, Task.run, .{ &srv, stream }) catch {
            // Never serve inline — a long-lived SSE stream would freeze
            // the accept loop forever. Drop and release the reservation.
            _ = srv.conns.fetchSub(1, .acq_rel);
            stream.close(io);
        };
    }
}

test {
    // Pull sibling server modules into the exe test binary so their
    // colocated test blocks are discovered by `zig build test`.
    _ = @import("history.zig");
    _ = @import("stream.zig");
}
