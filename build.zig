const std = @import("std");

const sqlite_c = "vendor/sqlite3/sqlite3.c";
const sqlite_flags = [_][]const u8{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION" };

/// Attach the vendored sqlite3 amalgamation (SQLite 3.54.1) to a module:
/// link libc, compile sqlite3.c with the documented flags. Only modules
/// that actually link the db get this — the framework itself never
/// imports zdb; apps (in the zforest-examples repo) opt in per-exe.
fn addSqlite(m: *std.Build.Module, b: *std.Build) void {
    m.link_libc = true;
    m.addIncludePath(b.path("vendor/sqlite3"));
    m.addCSourceFile(.{
        .file = b.path(sqlite_c),
        .flags = &sqlite_flags,
    });
}

// zforest is the FRAMEWORK repo: zefx (reactive graph), forest (view /
// DOM diff / snapshot), zserver (HTTP/SSE transport), zmeta
// (file-routing meta-framework), zdb (sqlite wrapper) and zassets
// (client.js/style.css embedding). The example apps that consume
// these modules live in the sibling zforest-examples repo — this build
// produces no executables, only the module graph plus tests.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zefx_mod = b.addModule("zefx", .{
        .root_source_file = b.path("src/zefx/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const forest_mod = b.addModule("forest", .{
        .root_source_file = b.path("src/forest/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Framework modules — named so every consumer compiles ONE copy of
    // each type (History/Dom/zefx/forest): `zserver` (HTTP/SSE transport,
    // generic over Session) sits below `zmeta` (session skeleton), and
    // zmeta reaching `zserver.History` through the named module is what
    // keeps the retained-batch ring type identical everywhere. No
    // framework module may import app code — the dependency arrow only
    // ever points app → framework.
    //
    // `client.js`/`style.css` stay at the `src/` root; `src/assets.zig`
    // (module `zassets`) is the only file whose package path can embed
    // them — `zserver`'s stops at `src/server/`. Only zserver imports it.
    const assets_mod = b.addModule("zassets", .{
        .root_source_file = b.path("src/assets.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zserver_mod = b.addModule("zserver", .{
        .root_source_file = b.path("src/server/http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "forest", .module = forest_mod },
            .{ .name = "zassets", .module = assets_mod },
        },
    });

    const zmeta_mod = b.addModule("zmeta", .{
        .root_source_file = b.path("src/zmeta/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zefx", .module = zefx_mod },
            .{ .name = "forest", .module = forest_mod },
            .{ .name = "zserver", .module = zserver_mod },
        },
    });

    // `db.zig` → named module `zdb`: it sits at the `src/` root, outside
    // every app's module path. Apps import it by name; only the
    // sqlite-linked exes get the import, keeping "db is app-side,
    // never framework" enforced by the module graph. The sqlite3
    // amalgamation + flags live on zdb itself: whichever exe imports it
    // links the C exactly once per compilation.
    const db_mod = b.addModule("zdb", .{
        .root_source_file = b.path("src/db.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSqlite(db_mod, b);

    // zmeta codegen/scaffold are std-only CLI tools shipped with the
    // framework. They are consumed by the examples repo, which roots
    // its own tool modules at these files (dep.path("src/zmeta/…")) and
    // runs them with cwd = the examples repo; here they exist only as
    // test targets.
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("src/zmeta/gen.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scaffold_mod = b.createModule(.{
        .root_source_file = b.path("src/zmeta/scaffold.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zefx_tests = b.addTest(.{ .root_module = zefx_mod });
    const run_zefx_tests = b.addRunArtifact(zefx_tests);

    const forest_tests = b.addTest(.{ .root_module = forest_mod });
    const run_forest_tests = b.addRunArtifact(forest_tests);

    // Framework module tests: zserver covers http/history; zmeta covers
    // the Session skeleton (its tests instantiate Session(TestDeps)).
    const zserver_tests = b.addTest(.{ .root_module = zserver_mod });
    const run_zserver_tests = b.addRunArtifact(zserver_tests);

    const zmeta_tests = b.addTest(.{ .root_module = zmeta_mod });
    const run_zmeta_tests = b.addRunArtifact(zmeta_tests);

    // zdb tests: the sqlite wrapper's own round-trip coverage (the
    // amalgamation is compiled into this test binary via zdb itself).
    const db_tests = b.addTest(.{ .root_module = db_mod });
    const run_db_tests = b.addRunArtifact(db_tests);

    const gen_tests = b.addTest(.{ .root_module = gen_mod });
    const run_gen_tests = b.addRunArtifact(gen_tests);

    const scaffold_tests = b.addTest(.{ .root_module = scaffold_mod });
    const run_scaffold_tests = b.addRunArtifact(scaffold_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_zefx_tests.step);
    test_step.dependOn(&run_forest_tests.step);
    test_step.dependOn(&run_zserver_tests.step);
    test_step.dependOn(&run_zmeta_tests.step);
    test_step.dependOn(&run_db_tests.step);
    test_step.dependOn(&run_gen_tests.step);
    test_step.dependOn(&run_scaffold_tests.step);
}
