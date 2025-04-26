const std = @import("std");

const Version = union(Kind) {
    tag: []const u8,
    commit: []const u8,
    // not in a git repo
    unknown,

    pub const Kind = enum { tag, commit, unknown };

    pub fn string(v: Version) []const u8 {
        return switch (v) {
            .tag, .commit => |tc| tc,
            .unknown => "unknown",
        };
    }
};

// Tries to get version info from git describe
// Adapted from https://github.com/kristoff-it/zine/blob/main/build.zig
fn getVersion(b: *std.Build) Version {
    // Allow overriding via build option first
    if (b.option([]const u8, "version", "Override the version string")) |ver| {
        return .{ .tag = ver }; // Treat override as a tag
    }

    // Try to find git
    const git_path = b.findProgram(&.{"git"}, &.{}) catch |err| {
        std.log.warn("git not found, cannot determine version: {s}", .{@errorName(err)});
        return .unknown;
    };

    // Determine the build root directory containing .git
    const build_root_path = b.build_root.path orelse "."; // Default to current dir if null

    // Run git describe --tags --match '*.*.*'
    var exit_code: u8 = undefined;
    const result = b.runAllowFail(
        &[_][]const u8{
            git_path,
            "-C", // Change directory before running command
            build_root_path, // Path to the repo root (where .git lives)
            "describe",
            "--tags",         // Use tags
            "--match", "*.*.*", // Match semantic version like tags
            "--dirty=-dirty", // Append -dirty if working tree is modified
            "--always",       // Fallback to commit hash if no tag found
        },
        &exit_code, // Pass address for exit code
        .Ignore    // Ignore stderr
    ) catch |err| {
        std.log.warn("git describe failed, cannot determine version: {s}", .{@errorName(err)});
        return .unknown;
    };

    const git_describe = std.mem.trim(u8, result, " \\n\\r");

    if (git_describe.len == 0) {
        std.log.warn("git describe output was empty, cannot determine version", .{});
        return .unknown;
    }

    // Simple check: if it contains '-', assume it's a commit description, otherwise a tag.
    // This is a simplification from zine's logic for brevity.
    if (std.mem.containsAtLeast(u8, git_describe, 1, "-")) {
         // Check if it's just the commit hash (fallback from --always)
         // or tag-like-description
         // We'll just call it a commit version for simplicity here
         return .{ .commit = b.allocator.dupe(u8, git_describe) catch |err| {
              std.log.err("Failed to allocate version string: {s}", .{@errorName(err)});
              return .unknown; // Treat allocation failure as unknown
         } };
    } else {
         return .{ .tag = b.allocator.dupe(u8, git_describe) catch |err| {
             std.log.err("Failed to allocate version string: {s}", .{@errorName(err)});
             return .unknown; // Treat allocation failure as unknown
         } };
    }
}


pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Determine version string
    const version = getVersion(b);
    const version_string = version.string(); // Get the final string representation

    // Create the options module
    const options_module = b.addOptions();
    options_module.addOption([]const u8, "version", version_string);

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "zenv",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the options module as an import named "options"
    exe.root_module.addImport("options", options_module.createModule());

    // Link standard library, etc.
    b.installArtifact(exe);

    // Add a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Add a build step for the executable itself
    const exe_step = b.step("exe", "Build the executable");
    exe_step.dependOn(&exe.step);
}
