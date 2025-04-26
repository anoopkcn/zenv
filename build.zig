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

    // Add a build step for the executable itself (ensure it depends on install)
    const exe_step = b.step("exe", "Build the executable");
    exe_step.dependOn(b.getInstallStep());

    // --- Release Step Setup ---
    const release_step = b.step("release", "Create release builds for various targets");
    if (version == .tag) {
        // Only allow release builds from tagged versions
        setupReleaseStep(b, release_step, version_string);
    } else {
        // Prevent running 'zig build release' on non-tagged commits
        release_step.dependOn(
            &b.addFail("error: git tag missing or invalid (needed for release builds, e.g., v0.1.0)").step
        );
    }
}

// Creates release artifacts for various targets
// Inspired by https://github.com/kristoff-it/zine/blob/main/build.zig
fn setupReleaseStep(
    b: *std.Build,
    release_step: *std.Build.Step,
    version_string: []const u8,
) void {
    // Define the targets to build for
    const targets: []const std.Target.Query = &.{        
        // Linux
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        // macOS (Nativemusl not applicable)
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        // Windows
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, // MinGW
        // .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu }, // Add if needed
    };

    const release_dir_path = b.pathJoin(&.{ "releases" }); // Relative to install prefix (zig-out)
    // No top-level makePath here, let addInstallFileWithDir handle it implicitly if needed,
    // or handle errors within the loop if required.

    for (targets) |t| {
        const target = b.resolveTargetQuery(t);
        const optimize = .ReleaseFast;
        const exe_name = "zenv";

        // --- Create Target-Specific Options Module ---
        // This ensures the correct version is baked into each target's executable
        const options_module_release = b.addOptions();
        options_module_release.addOption([]const u8, "version", version_string);
        const options_import = options_module_release.createModule();

        // --- Build Executable for the Target ---
        const exe_release = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_release.root_module.addImport("options", options_import);
        // If zenv adds dependencies later, they need to be configured here
        // similar to how zine does it (passing target, optimize etc.)

        // --- Package the Executable --- 
        // Get the target triple string (e.g., "x86_64-linux-musl")
        const triple = target.result.zigTriple(b.allocator) catch |err| {
            std.log.err("Failed to get target triple: {s}", .{@errorName(err)});
            continue; // Skip this target if we can't get the triple
        };

        switch (target.result.os.tag) {
            .windows => {
                const archive_basename = b.fmt("{s}-{s}.zip", .{exe_name, triple});
                const zip_cmd = b.addSystemCommand(&.{
                    "zip", 
                    "-j", // Junk paths (store only the file, not dir structure)
                    "-q", // Quiet
                    "-9", // Max compression
                });
                const archive_path = zip_cmd.addOutputFileArg(archive_basename);
                zip_cmd.addFileArg(exe_release.getEmittedBin()); // Add the executable file
                
                release_step.dependOn(&b.addInstallFileWithDir(
                    archive_path,
                    .{ .custom = release_dir_path },
                    archive_basename,
                ).step);
            },
            .macos, .linux => { // Assuming tar for Linux and macOS
                const archive_basename = b.fmt("{s}-{s}.tar.xz", .{exe_name, triple});
                const tar_cmd = b.addSystemCommand(&.{
                    "tar",
                    "-cJf", // Create, use xz compression, specify archive file
                });
                const archive_path = tar_cmd.addOutputFileArg(archive_basename);
                tar_cmd.addArg("-C"); // Change directory before adding files
                tar_cmd.addDirectoryArg(exe_release.getEmittedBinDirectory()); // Directory containing the exe
                tar_cmd.addArg(exe_name); // Name of the file to add within the archive

                 release_step.dependOn(&b.addInstallFileWithDir(
                    archive_path,
                    .{ .custom = release_dir_path },
                    archive_basename,
                ).step);
            },
            else => {
                 std.log.warn("Skipping packaging for unsupported OS target: {s}", .{triple});
            },
        }
    }
}
