const std = @import("std");

const sqlite_c = "vendor/sqlite3/sqlite3.c";
const sqlite_flags = [_][]const u8{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION" };

/// Attach the vendored sqlite3 amalgamation (SQLite 3.54.1) to a module:
/// link libc, compile sqlite3.c with the documented flags. Only modules
/// that actually link the db get this — the todo exe never sees C.
fn addSqlite(m: *std.Build.Module, b: *std.Build) void {
    m.link_libc = true;
    m.addIncludePath(b.path("vendor/sqlite3"));
    m.addCSourceFile(.{
        .file = b.path(sqlite_c),
        .flags = &sqlite_flags,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zefx_mod = b.addModule("zefx", .{
        .root_source_file = b.path("src/zefx/root.zig"),
        .target = target,
    });

    const forest_mod = b.addModule("forest", .{
        .root_source_file = b.path("src/forest/root.zig"),
        .target = target,
    });

    const app_imports = [_]std.Build.Module.Import{
        .{ .name = "zefx", .module = zefx_mod },
        .{ .name = "forest", .module = forest_mod },
    };

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &app_imports,
    });
    const exe = b.addExecutable(.{ .name = "zforest", .root_module = exe_mod });

    b.installArtifact(exe);

    // The board app: shares the zefx/forest modules plus sqlite via db.zig.
    const zboard_mod = b.createModule(.{
        .root_source_file = b.path("src/board_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &app_imports,
    });
    addSqlite(zboard_mod, b);

    const zboard = b.addExecutable(.{ .name = "zboard", .root_module = zboard_mod });

    b.installArtifact(zboard);

    // The zmon dashboard: same zefx/forest modules, no sqlite — but libc
    // for time(3) (wall-clock uptime/start timestamps).
    const zmon_mod = b.createModule(.{
        .root_source_file = b.path("src/mon_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &app_imports,
    });
    zmon_mod.link_libc = true;
    const zmon = b.addExecutable(.{ .name = "zmon", .root_module = zmon_mod });

    b.installArtifact(zmon);

    // The zcar booking app: same zefx/forest modules, no sqlite, no libc.
    const zcar_mod = b.createModule(.{
        .root_source_file = b.path("src/car_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &app_imports,
    });
    const zcar = b.addExecutable(.{ .name = "zcar", .root_module = zcar_mod });

    b.installArtifact(zcar);

    // zmeta codegen: `zig build gen` regenerates src/apps/*/gen/*.zig
    // from each app's pages/ tree + actions.zig manifest. The output is
    // deterministic and checked in — the demo module below compiles the
    // checked-in files directly (no build-time codegen dependency).
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("src/zmeta/gen.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gen_tool = b.addExecutable(.{ .name = "zmeta-gen", .root_module = gen_mod });
    const gen_step = b.step("gen", "Regenerate zmeta app gen/ files (routes.zig, actions.zig)");
    const gen_run = b.addRunArtifact(gen_tool);
    gen_run.setCwd(b.path("."));
    gen_step.dependOn(&gen_run.step);

    // `zig build new-app -- <name>`: scaffold src/apps/<name>/ +
    // src/<name>_main.zig, then regenerate gen/ for the new app in the
    // same invocation (the scaffold step must finish first).
    const scaffold_mod = b.createModule(.{
        .root_source_file = b.path("src/zmeta/scaffold.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scaffold_tool = b.addExecutable(.{ .name = "zmeta-new", .root_module = scaffold_mod });
    const new_app_step = b.step("new-app", "Scaffold a new zmeta app: zig build new-app -- <name>");
    const new_app_run = b.addRunArtifact(scaffold_tool);
    new_app_run.setCwd(b.path("."));
    new_app_run.addPassthruArgs();
    new_app_step.dependOn(&new_app_run.step);
    const gen_for_new = b.addRunArtifact(gen_tool);
    gen_for_new.step.dependOn(&new_app_run.step);
    new_app_step.dependOn(&gen_for_new.step);

    // The zmeta demo app: file-based routes with typed params + the
    // comptime action table, served through the zmeta Session skeleton.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/zmeta_demo_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &app_imports,
    });
    const demo = b.addExecutable(.{ .name = "zmeta-demo", .root_module = demo_mod });

    b.installArtifact(demo);

    const run_step = b.step("run", "Run the todo server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_board_step = b.step("run-board", "Run the board server");
    const run_board_cmd = b.addRunArtifact(zboard);
    run_board_step.dependOn(&run_board_cmd.step);
    run_board_cmd.step.dependOn(b.getInstallStep());

    const run_mon_step = b.step("run-mon", "Run the zmon dashboard");
    const run_mon_cmd = b.addRunArtifact(zmon);
    run_mon_step.dependOn(&run_mon_cmd.step);
    run_mon_cmd.step.dependOn(b.getInstallStep());

    const run_car_step = b.step("run-car", "Run the zcar booking app");
    const run_car_cmd = b.addRunArtifact(zcar);
    run_car_step.dependOn(&run_car_cmd.step);
    run_car_cmd.step.dependOn(b.getInstallStep());

    const run_demo_step = b.step("run-demo", "Run the zmeta demo app");
    const run_demo_cmd = b.addRunArtifact(demo);
    run_demo_step.dependOn(&run_demo_cmd.step);
    run_demo_cmd.step.dependOn(b.getInstallStep());

    const zefx_tests = b.addTest(.{ .root_module = zefx_mod });
    const run_zefx_tests = b.addRunArtifact(zefx_tests);

    const forest_tests = b.addTest(.{ .root_module = forest_mod });
    const run_forest_tests = b.addRunArtifact(forest_tests);

    // exe tests pull db.zig/board.zig via main.zig's test block — the
    // amalgamation is compiled into this test binary only, never into the
    // zforest exe artifact.
    const exe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &app_imports,
    });
    addSqlite(exe_test_mod, b);
    const exe_tests = b.addTest(.{ .root_module = exe_test_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const zboard_tests = b.addTest(.{ .root_module = zboard_mod });
    const run_zboard_tests = b.addRunArtifact(zboard_tests);

    const zmon_tests = b.addTest(.{ .root_module = zmon_mod });
    const run_zmon_tests = b.addRunArtifact(zmon_tests);

    const zcar_tests = b.addTest(.{ .root_module = zcar_mod });
    const run_zcar_tests = b.addRunArtifact(zcar_tests);

    const demo_tests = b.addTest(.{ .root_module = demo_mod });
    const run_demo_tests = b.addRunArtifact(demo_tests);

    const gen_tests = b.addTest(.{ .root_module = gen_mod });
    const run_gen_tests = b.addRunArtifact(gen_tests);

    const scaffold_tests = b.addTest(.{ .root_module = scaffold_mod });
    const run_scaffold_tests = b.addRunArtifact(scaffold_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_zefx_tests.step);
    test_step.dependOn(&run_forest_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_zboard_tests.step);
    test_step.dependOn(&run_zmon_tests.step);
    test_step.dependOn(&run_zcar_tests.step);
    test_step.dependOn(&run_demo_tests.step);
    test_step.dependOn(&run_gen_tests.step);
    test_step.dependOn(&run_scaffold_tests.step);
}
