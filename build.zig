const std = @import("std");

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

    const exe = b.addExecutable(.{
        .name = "zforest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zefx", .module = zefx_mod },
                .{ .name = "forest", .module = forest_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the todo server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const zefx_tests = b.addTest(.{ .root_module = zefx_mod });
    const run_zefx_tests = b.addRunArtifact(zefx_tests);

    const forest_tests = b.addTest(.{ .root_module = forest_mod });
    const run_forest_tests = b.addRunArtifact(forest_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_zefx_tests.step);
    test_step.dependOn(&run_forest_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
