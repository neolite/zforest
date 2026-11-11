const std = @import("std");
const todo = @import("../todo_app.zig");
const stream_mod = @import("stream.zig");
const History = @import("history.zig").History;

const index_js = @embedFile("../client.js");
const style_css = @embedFile("../style.css");

const cookie_name = "zfxs";
const max_sessions = 32;
const max_body_len = 4096;
const max_conns = 128;
const head_buf_len = 8192;
const sse_poll_ms = 50;
const sse_heartbeat_ticks = 200; // 200 * 50ms ≈ 10s

/// A live session plus its retained patch-batch history for SSE replay.
const Entry = struct {
    s: *todo.Session,
    history: History,
};

/// Session registry. Demo cap: `max_sessions`, oldest session is evicted
/// (documented teardown policy — no persistence, no timers needed).
/// All access is serialized by `Server.mutex`.
pub const SessionStore = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    by_token: std.StringHashMapUnmanaged(*Entry) = .empty,
    order: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) SessionStore {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *SessionStore) void {
        for (self.order.items) |tok| {
            const e = self.by_token.get(tok).?;
            e.s.deinit();
            e.history.deinit();
            self.gpa.destroy(e);
            self.gpa.free(tok);
        }
        self.order.deinit(self.gpa);
        self.by_token.deinit(self.gpa);
    }

    pub fn lookup(self: *SessionStore, token: []const u8) ?*Entry {
        return self.by_token.get(token);
    }

    /// Create a session and return its fresh token (owned by the store).
    pub fn create(self: *SessionStore) []u8 {
        if (self.order.items.len >= max_sessions) {
            const oldest = self.order.orderedRemove(0);
            const e = self.by_token.fetchRemove(oldest).?;
            e.value.s.deinit();
            e.value.history.deinit();
            self.gpa.destroy(e.value);
            self.gpa.free(oldest);
        }
        var rand_bytes: [16]u8 = undefined;
        self.io.random(&rand_bytes);
        const token = std.fmt.allocPrint(self.gpa, "{x:0>16}", .{std.mem.readInt(u64, rand_bytes[0..8], .little)}) catch @panic("OOM");
        const e = self.gpa.create(Entry) catch @panic("OOM");
        e.* = .{ .s = todo.createSession(self.gpa), .history = History.init(self.gpa) };
        e.s.csrf_token = std.fmt.allocPrint(self.gpa, "{x:0>32}", .{std.mem.readInt(u128, &rand_bytes, .little)}) catch @panic("OOM");
        self.by_token.put(self.gpa, token, e) catch @panic("OOM");
        self.order.append(self.gpa, token) catch @panic("OOM");
        return token;
    }
};

/// Shared server state. `mutex` serializes every access to the session
/// store, the reactive models, and the patch histories. It is NEVER held
/// while doing network I/O or sleeping — connection tasks read/write
/// sockets and poll outside the critical section.
const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: SessionStore,
    mutex: std.Io.Mutex = .init,
    conns: std.atomic.Value(u32) = .init(0),
};

fn cookieValue(cookie_header: ?[]const u8) ?[]const u8 {
    const h = cookie_header orelse return null;
    var it = std.mem.splitScalar(u8, h, ';');
    while (it.next()) |part| {
        const kv = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, kv, cookie_name ++ "=")) {
            return kv[cookie_name.len + 1 ..];
        }
    }
    return null;
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

fn statusOf(err: todo.ActionError) std.http.Status {
    return switch (err) {
        error.TodoNotFound => .not_found,
        else => .bad_request,
    };
}

fn renderIndex(s: *todo.Session, out: anytype) !void {
    try out.writeAll(
        \\<!doctype html><html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>zforest todos</title><link rel="stylesheet" href="/style.css">
        \\<meta name="zforest-csrf" content="
    );
    try out.writeAll(s.csrf_token);
    try out.writeAll("\"><meta name=\"zforest-rev\" content=\"");
    var rbuf: [24]u8 = undefined;
    try out.writeAll(std.fmt.bufPrint(&rbuf, "{d}", .{s.seq.get()}) catch unreachable);
    try out.writeAll(
        \\"></head>
        \\<body><main class="app">
    );
    // Declarative view: h1 + add form + filters + keyed list + count.
    try s.writeView(out);
    try out.writeAll("</main><script src=\"/client.js?v=1\"></script></body></html>");
}

fn handle(
    srv: *Server,
    arena: std.mem.Allocator,
    req: *std.http.Server.Request,
    out_body: *std.ArrayListUnmanaged(u8),
    extra: *std.ArrayListUnmanaged(std.http.Header),
) std.http.Status {
    const method = req.head.method;
    const path = requestPath(req.head.target);

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
            const pre = if (cookieValue(cookie_hdr)) |tok| srv.store.lookup(tok) else null;
            const ps = pre orelse return .forbidden;
            const pre_ok = csrf_hdr != null and std.mem.eql(u8, csrf_hdr.?, ps.s.csrf_token);
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
        const entry = if (cookieValue(cookie_hdr)) |tok| srv.store.lookup(tok) else null;
        const e = entry orelse return .forbidden;
        const s = e.s;
        // CSRF: accept when the custom X-Zforest-CSRF header matches the
        // per-session token (browsers can't set custom headers cross-origin
        // without CORS, which we never grant), OR when Origin matches Host.
        // Everything else — cross-origin or no token — is rejected.
        const token_ok = csrf_hdr != null and std.mem.eql(u8, csrf_hdr.?, s.csrf_token);
        if (!token_ok and !sameOrigin(origin_hdr, host_hdr)) return .forbidden;

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
        e.history.publish(rev, jaw.toOwnedSlice() catch @panic("OOM"));
        s.log.clear();

        var ack: std.Io.Writer.Allocating = .init(arena);
        ack.writer.print("{{\"rev\":{d}}}", .{rev}) catch @panic("OOM");
        out_body.appendSlice(arena, ack.writer.buffered()) catch @panic("OOM");
        extra.append(arena, .{ .name = "content-type", .value = "application/json" }) catch @panic("OOM");
        return .ok;
    }

    // GETs below need the session state; keep the lock span tight —
    // rendering happens into the per-request arena, not the socket.
    if (method == .GET and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html"))) {
        srv.mutex.lockUncancelable(srv.io);
        defer srv.mutex.unlock(srv.io);
        var token: []const u8 = undefined;
        const entry = if (cookieValue(cookie_hdr)) |tok| srv.store.lookup(tok) else null;
        const e = entry orelse blk: {
            token = srv.store.create();
            break :blk srv.store.lookup(token).?;
        };
        if (entry == null) {
            extra.append(arena, .{
                .name = "set-cookie",
                .value = std.fmt.allocPrint(arena, "{s}={s}; HttpOnly; SameSite=Strict; Path=/", .{ cookie_name, token }) catch @panic("OOM"),
            }) catch @panic("OOM");
        }
        e.s.seedDom();
        extra.append(arena, .{ .name = "content-type", .value = "text/html; charset=utf-8" }) catch @panic("OOM");
        var aw: std.Io.Writer.Allocating = .init(arena);
        renderIndex(e.s, &aw.writer) catch @panic("OOM");
        out_body.appendSlice(arena, aw.writer.buffered()) catch @panic("OOM");
        return .ok;
    }

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
fn serveEvents(srv: *Server, req: *std.http.Server.Request) !void {
    var cookie_hdr: ?[]const u8 = null;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) cookie_hdr = h.value;
    }
    const token = try srv.gpa.dupe(u8, cookieValue(cookie_hdr) orelse "");
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
            const entry = srv.store.lookup(token);
            if (entry) |e| {
                if (!connected) {
                    connected = true;
                    cursor = e.s.seq.get();
                    fw.writer.writeAll("event: snapshot\ndata: ") catch @panic("OOM");
                    stream_mod.writeSnapshotJson(e.s, &fw.writer) catch @panic("OOM");
                    fw.writer.writeAll("\n\n") catch @panic("OOM");
                } else {
                    const f = e.history.fetch(cursor, srv.gpa) catch @panic("OOM");
                    defer History.freeFetch(srv.gpa, f);
                    switch (f) {
                        .gap => {
                            cursor = e.s.seq.get();
                            fw.writer.writeAll("event: snapshot\ndata: ") catch @panic("OOM");
                            stream_mod.writeSnapshotJson(e.s, &fw.writer) catch @panic("OOM");
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

fn connTask(srv: *Server, stream: std.Io.net.Stream) void {
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
        serveEvents(srv, &req) catch {};
        return;
    }

    var body: std.ArrayListUnmanaged(u8) = .empty;
    var extra: std.ArrayListUnmanaged(std.http.Header) = .empty;
    extra.append(arena, .{ .name = "x-content-type-options", .value = "nosniff" }) catch @panic("OOM");
    // Session HTML and action responses are per-session — never cache.
    extra.append(arena, .{ .name = "cache-control", .value = "no-store" }) catch @panic("OOM");

    const status = handle(srv, arena, &req, &body, &extra);
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
/// Loopback only.
pub fn serve(gpa: std.mem.Allocator, io: std.Io, port: u16) !void {
    var srv: Server = .{
        .gpa = gpa,
        .io = io,
        .store = SessionStore.init(gpa, io),
    };
    defer srv.store.deinit();

    var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("zforest todo listening on http://127.0.0.1:{d}\n", .{port});

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
        group.concurrent(io, connTask, .{ &srv, stream }) catch {
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
