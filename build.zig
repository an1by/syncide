const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "Optimization mode (default: small)",
    ) orelse .small;
    const is_debug = optimize == .debug;

    const mod = b.addModule("syncide", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = !is_debug,
        .unwind_tables = if (is_debug) .sync else .none,
        .single_threaded = true,
    });

    const exe = b.addExecutable(.{
        .name = "syncide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = !is_debug,
            .unwind_tables = if (is_debug) .sync else .none,
            .single_threaded = true,
            .imports = &.{
                .{ .name = "syncide", .module = mod },
            },
        }),
    });

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "../build" } },
    });
    b.getInstallStep().dependOn(&install_exe.step);

    const run_step = b.step("run", "Run syncide CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "syncide", .module = mod },
            },
        }),
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit and sandbox integration tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
