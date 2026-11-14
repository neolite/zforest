//! zmeta app scaffold: `zig build new-app -- <name>` creates
//! `src/apps/<name>/` (app.zig + pages/index.zig + actions.zig +
//! zmeta.zig shim) and `src/<name>_main.zig`, then the build step
//! regenerates `gen/` — the lightweight "create-app" of the repo.
//!
//! The scaffolded app still needs ~15 lines in build.zig (module +
//! exe + install + run/test steps) — printed verbatim on success.
//! App dirs are inert until registered: nothing imports them, so an
//! unregistered scaffold never breaks `zig build`/`zig build test`.
//!
//! Usage: `zig build new-app -- my_app` (name must be a valid Zig
//! identifier; the directory must not exist yet).

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: zig build new-app -- <name>\n", .{});
        return error.MissingName;
    }
    const name = try arena.dupe(u8, std.mem.span(argv[1]));
    try validateName(name);

    const app_dir = try std.fmt.allocPrint(arena, "src/apps/{s}", .{name});
    var exists = true;
    Dir.cwd().access(init.io, app_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => exists = false,
        else => return err,
    };
    if (exists) {
        std.debug.print("zmeta-new: src/apps/{s} already exists\n", .{name});
        return error.AppExists;
    }

    try writeAppFile(init.io, arena, app_dir, "app.zig", try appZig(arena, name));
    try writeAppFile(init.io, arena, app_dir, "pages/index.zig", try indexZig(arena, name));
    try writeAppFile(init.io, arena, app_dir, "actions.zig", actionsZig);
    try writeAppFile(init.io, arena, app_dir, "zmeta.zig", zmetaZig);

    const main_rel = try std.fmt.allocPrint(arena, "src/{s}_main.zig", .{name});
    try writeFile(init.io, main_rel, try mainZig(arena, name));

    std.debug.print(
        \\zmeta-new: created {s}/ + {s}
        \\next: register the exe in build.zig, then `zig build run-{s}`:
        \\
        \\    const {s}_mod = b.createModule(.{{
        \\        .root_source_file = b.path("src/{s}_main.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .imports = &app_imports,
        \\    }});
        \\    const {s} = b.addExecutable(.{{ .name = "{s}", .root_module = {s}_mod }});
        \\    b.installArtifact({s});
        \\    const run_{s}_step = b.step("run-{s}", "Run the {s} app");
        \\    const run_{s}_cmd = b.addRunArtifact({s});
        \\    run_{s}_step.dependOn(&run_{s}_cmd.step);
        \\    run_{s}_cmd.step.dependOn(b.getInstallStep());
        \\    const {s}_tests = b.addTest(.{{ .root_module = {s}_mod }});
        \\    test_step.dependOn(&b.addRunArtifact({s}_tests).step);
        \\
    , .{ app_dir, main_rel, name, name, name, name, name, name, name, name, name, name, name, name, name, name, name, name, name, name });
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or !std.zig.isValidId(name)) {
        std.debug.print("zmeta-new: '{s}' is not a valid Zig identifier (use snake_case)\n", .{name});
        return error.BadName;
    }
}

fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    const parent = std.fs.path.dirname(path).?;
    try Dir.cwd().createDirPath(io, parent);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn writeAppFile(io: Io, arena: Allocator, app_dir: []const u8, rel: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ app_dir, rel });
    try writeFile(io, path, data);
}

// ─────────────────────────────────────────────
// templates
// ─────────────────────────────────────────────

fn appZig(arena: Allocator, name: []const u8) ![]const u8 {
    const title = try std.fmt.allocPrint(arena, "{s}", .{name});
    return std.fmt.allocPrint(arena,
        \\//! {s} — zmeta app scaffolded by `zig build new-app`.
        \\//! Domain state + `Deps` contract live here; the view is in
        \\//! `pages/`, action names in `actions.zig`, generated glue in
        \\//! `gen/` (regenerate with `zig build gen`).
        \\
        \\const std = @import("std");
        \\const forest = @import("forest");
        \\const zmeta = @import("zmeta.zig");
        \\const routes = @import("gen/routes.zig");
        \\const actions = @import("gen/actions.zig");
        \\
        \\pub const Route = routes.Route;
        \\pub const act = actions.act;
        \\
        \\/// {s}Deps — the zmeta `Deps` contract (docs/meta-framework.md §5).
        \\/// Add domain state fields here; `init` creates graph handles,
        \\/// `wire` registers pure-phase reducers, `deinit` frees domain
        \\/// allocations (optional — declare only when needed).
        \\pub const AppDeps = struct {{
        \\    /// Page <title> / <main> class / session cookie.
        \\    pub const page_title = "{s}";
        \\    pub const page_class = "app app-{s}";
        \\    pub const cookie_name = "zfx-{s}";
        \\
        \\    /// Current typed route — written by generated `routes.setRoute`.
        \\    route: routes.Route = .{{ .index = .{{}} }},
        \\
        \\    /// Domain state fields go here.
        \\
        \\    pub fn init(s: *Session) AppDeps {{
        \\        _ = s;
        \\        return .{{}};
        \\    }}
        \\
        \\    pub fn wire(s: *Session) void {{
        \\        _ = s;
        \\    }}
        \\
        \\    pub fn setRoute(s: *Session, path: []const u8) bool {{
        \\        return routes.setRoute(s, path);
        \\    }}
        \\
        \\    pub fn validPath(path: []const u8) bool {{
        \\        return routes.validPath(path);
        \\    }}
        \\
        \\    pub fn prepare(s: *Session, env: *const zmeta.Env) !void {{
        \\        try routes.prepare(s, env);
        \\    }}
        \\
        \\    pub fn view(a: std.mem.Allocator, s: *Session, env: *const zmeta.Env) []const forest.Node {{
        \\        return routes.viewNodes(a, s, env);
        \\    }}
        \\
        \\    /// Whitelisted action entry — generated dispatch to
        \\    /// `on_<name>` handlers declared on this type. Add names to
        \\    /// `actions.zig`, then implement `on_<name>` here.
        \\    pub fn dispatch(
        \\        s: *Session,
        \\        action: []const u8,
        \\        arg: ?[]const u8,
        \\        value: ?[]const u8,
        \\        fields: ?*const std.json.ObjectMap,
        \\    ) !void {{
        \\        return actions.dispatch(s, action, arg, value, fields);
        \\    }}
        \\}};
        \\
        \\/// One browser session — the transport contract comes from the
        \\/// zmeta skeleton (docs/meta-framework.md §5.2).
        \\pub const Session = zmeta.Session(AppDeps);
        \\
    , .{ name, title, name, name, name });
}

fn indexZig(arena: Allocator, name: []const u8) ![]const u8 {
    const title = try std.fmt.allocPrint(arena, "Hello {s}", .{name});
    return std.fmt.allocPrint(arena,
        \\//! "/" — scaffolded index page. File = route: rename/move this
        \\//! file and `zig build gen` rewires the route table.
        \\const std = @import("std");
        \\const forest = @import("forest");
        \\const zmeta = @import("../zmeta.zig");
        \\const h = zmeta.h;
        \\
        \\/// Route params — static route, empty struct (required).
        \\pub const params = struct {{}};
        \\
        \\pub fn view(a: std.mem.Allocator, s: anytype, p: params, env: *const zmeta.Env) forest.Node {{
        \\    _ = s;
        \\    _ = p;
        \\    _ = env;
        \\    return h.h1(a).id("title").child("{s}").node();
        \\}}
        \\
    , .{title});
}

const actionsZig =
    \\//! zmeta action manifest — `zig build gen` turns these names into
    \\//! the comptime `act` table + dispatch arms in `gen/actions.zig`.
    \\//! Each name needs an `on_<name>` handler decl on the app's Deps
    \\//! type (app.zig); view `.on` attrs reference `act.<name>` for
    \\//! compile-checked wiring. Example: .{ "ping", "like" }.
    \\pub const actions = .{};
    \\
;

const zmetaZig =
    \\//! Per-app shim for the plain-source zmeta modules — keeps page/app
    \\//! imports short while preserving type identity (same files
    \\//! `zmeta/root.zig` exports; zmeta is NOT a named build module).
    \\pub const Archetype = @import("../../zmeta/root.zig").Archetype;
    \\pub const Env = @import("../../zmeta/root.zig").Env;
    \\pub const Session = @import("../../zmeta/root.zig").Session;
    \\pub const h = @import("../../zmeta/root.zig").h;
    \\
;

fn mainZig(arena: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\const std = @import("std");
        \\const server = @import("server/http.zig");
        \\const app = @import("apps/{s}/app.zig");
        \\
        \\/// Parse the optional `bind-ip` arg: a dotted IPv4 literal, or
        \\/// loopback for anything unparsable (safe demo default).
        \\fn bindIp(arg: ?[]const u8) std.Io.net.Ip4Address {{
        \\    const s = arg orelse return .loopback(0);
        \\    return std.Io.net.Ip4Address.parse(s, 0) catch .loopback(0);
        \\}}
        \\
        \\/// `{s} [port] [bind-ip]` — defaults 8080 / 127.0.0.1.
        \\pub fn main(init: std.process.Init) !void {{
        \\    const argv = init.minimal.args.vector;
        \\    const port: u16 = if (argv.len < 2) 8080 else std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch 8080;
        \\    var bind = bindIp(if (argv.len < 3) null else std.mem.span(argv[2]));
        \\    bind.port = port;
        \\
        \\    try server.serve(init.gpa, init.io, bind, app.Session);
        \\}}
        \\
        \\test {{
        \\    _ = @import("apps/{s}/app.zig");
        \\}}
        \\
    , .{ name, name, name });
}

test "scaffold templates substitute the app name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const app_src = try appZig(a, "my_app");
    try std.testing.expect(std.mem.indexOf(u8, app_src, "cookie_name = \"zfx-my_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_src, "zmeta.Session(AppDeps)") != null);
    const page_src = try indexZig(a, "my_app");
    try std.testing.expect(std.mem.indexOf(u8, page_src, "Hello my_app") != null);
    const main_src = try mainZig(a, "my_app");
    try std.testing.expect(std.mem.indexOf(u8, main_src, "apps/my_app/app.zig") != null);
    try std.testing.expectError(error.BadName, validateName("9lives"));
    try std.testing.expectError(error.BadName, validateName("has-dash"));
}
