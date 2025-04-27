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

// Target definitions for release builds
const ReleaseTarget = struct {
    query: std.Target.Query,
    name: []const u8,
    description: []const u8,
};

const release_targets = [_]ReleaseTarget{
    .{
        .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .name = "linux-x64",
        .description = "Linux x86_64 (musl)",
    },
    .{
        .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .name = "linux-arm64",
        .description = "Linux ARM64 (musl)",
    },
    .{
        .query = .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .name = "macos-x64",
        .description = "macOS x86_64",
    },
    .{
        .query = .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .name = "macos-arm64",
        .description = "macOS ARM64",
    },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Add release-safe option for building with assertions enabled
    const release_safe = b.option(bool, "release-safe", "Build with ReleaseSafe mode (optimized but with assertions)") orelse false;
    const small_release = b.option(bool, "small-release", "Build with ReleaseSmall mode (optimize for binary size)") orelse false;
    // Add option to force releases even without a tag
    const force_release = b.option(bool, "force-release", "Allow release builds without git tags") orelse false;
    
    // Determine effective optimization level
    const effective_optimize = if (small_release) 
        .ReleaseSmall 
    else if (release_safe) 
        .ReleaseSafe 
    else 
        optimize;

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
        .optimize = effective_optimize,
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

    // --- Individual Target Steps ---
    if (version == .tag or force_release) {
        // Add individual target-specific build steps
        for (release_targets) |release_target| {
            const target_step_small = b.step(
                b.fmt("release-{s}-small", .{release_target.name}), 
                b.fmt("Create ReleaseSmall build for {s}", .{release_target.description})
            );
            setupTargetReleaseWithOptimize(b, target_step_small, version_string, release_target.query, .ReleaseSmall);
            
            const target_step_fast = b.step(
                b.fmt("release-{s}", .{release_target.name}), 
                b.fmt("Create ReleaseFast build for {s}", .{release_target.description})
            );
            setupTargetReleaseWithOptimize(b, target_step_fast, version_string, release_target.query, .ReleaseFast);
        }
    } else {
        // When not on a tag, add the fail message to each individual target step
        const error_msg = "error: git tag missing or invalid (needed for release builds, e.g., v0.1.0). Use -Dforce-release=true to override.";
        for (release_targets) |release_target| {
            const target_step_small = b.step(
                b.fmt("release-{s}-small", .{release_target.name}), 
                b.fmt("Create ReleaseSmall build for {s}", .{release_target.description})
            );
            target_step_small.dependOn(&b.addFail(error_msg).step);
            
            const target_step_fast = b.step(
                b.fmt("release-{s}", .{release_target.name}), 
                b.fmt("Create ReleaseFast build for {s}", .{release_target.description})
            );
            target_step_fast.dependOn(&b.addFail(error_msg).step);
        }
    }

    // --- All Targets Release Step ---
    const release_step = b.step("release", "Create release builds for all targets");
    const release_small_step = b.step("release-small", "Create small release builds for all targets");
    
    if (version == .tag or force_release) {
        // Set up release-all steps with different optimizations
        for (release_targets) |release_target| {
            setupTargetReleaseWithOptimize(b, release_step, version_string, release_target.query, .ReleaseFast);
            setupTargetReleaseWithOptimize(b, release_small_step, version_string, release_target.query, .ReleaseSmall);
        }
    } else {
        // Prevent running release builds on non-tagged commits
        const error_msg = "error: git tag missing or invalid (needed for release builds, e.g., v0.1.0). Use -Dforce-release=true to override.";
        release_step.dependOn(&b.addFail(error_msg).step);
        release_small_step.dependOn(&b.addFail(error_msg).step);
    }
}

// Creates a simplified version of the target triple for file naming
fn simplifyTripleName(target: std.Target) []const u8 {
    const allocator = std.heap.page_allocator;
    
    // Format based on architecture, OS, and possibly ABI
    const arch = @tagName(target.cpu.arch);
    const os = @tagName(target.os.tag);
    
    // For Linux with musl, include the ABI
    if (target.os.tag == .linux and target.abi == .musl) {
        return std.fmt.allocPrint(allocator, "{s}-{s}-musl", .{arch, os}) catch "unknown";
    }
    
    // For macOS, just use arch-macos
    if (target.os.tag == .macos) {
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{arch, os}) catch "unknown";
    }
    
    // Default case - just combine arch and OS
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{arch, os}) catch "unknown";
}

// Creates release artifact for a single target with specified optimization
fn setupTargetReleaseWithOptimize(
    b: *std.Build,
    release_step: *std.Build.Step,
    version_string: []const u8,
    target_query: std.Target.Query,
    comptime optimize: std.builtin.OptimizeMode,
) void {
    const target = b.resolveTargetQuery(target_query);
    const exe_name = "zenv";
    const release_dir_path = b.pathJoin(&.{ "releases" });

    // --- Create Target-Specific Options Module ---
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

    // --- Package the Executable --- 
    const triple = target.result.zigTriple(b.allocator) catch |err| {
        std.log.err("Failed to get target triple: {s}", .{@errorName(err)});
        return; // Skip this target if we can't get the triple
    };

    // Create a simplified name for the archive
    const simplified_triple = simplifyTripleName(target.result);
    
    // Add optimization mode to the archive name for clarity
    const opt_suffix = switch (optimize) {
        .ReleaseSmall => "-small",
        else => "",
    };

    switch (target.result.os.tag) {
        .macos, .linux => { // Assuming tar for Linux and macOS
            const archive_basename = b.fmt("{s}-{s}{s}.tar.xz", .{exe_name, simplified_triple, opt_suffix});
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