const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the main executable module.
    // std.json is part of the standard library, no extra import needed here.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the executable named "zenv"
    const exe = b.addExecutable(.{
        .name = "zenv", // Set executable name
        .root_module = exe_mod,
        .version = .{ .major = 0, .minor = 1, .patch = 0 }, // Optional: Set version
    });

    // Installs the executable
    b.installArtifact(exe);

    // Creates a Run step: `zig build run -- arg1 ...`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing the executable: `zig build test`
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
        // Add options needed for tests, e.g., allocator strategy
        // .test_allocator = .{.allocator = b.allocator},
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
