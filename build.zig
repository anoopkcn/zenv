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

    // Determine the build root directory containing .git
    const build_root_path = b.root.toString(b.allocator) catch @panic("OOM");

    // Run git describe --tags --match '*.*.*'. Spawning resolves `git` via PATH,
    // so a missing git surfaces as `spawn_failed` without a separate lookup.
    const result = switch (b.runFallible(&.{
        "git",
        "-C", // Change directory before running command
        build_root_path, // Path to the repo root (where .git lives)
        "describe",
        "--tags", // Use tags
        "--match", "*.*.*", // Match semantic version like tags
        "--dirty=-dirty", // Append -dirty if working tree is modified
        "--always", // Fallback to commit hash if no tag found
    }, .{ .stderr_behavior = .ignore })) {
        .success => |stdout| stdout,
        .spawn_failed => |err| {
            std.log.warn("git not found, cannot determine version: {t}", .{err});
            return .unknown;
        },
        .bad_exit_code, .crashed => {
            std.log.warn("git describe failed, cannot determine version", .{});
            return .unknown;
        },
    };

    // stdout is arena-owned by the build graph, so slices of it stay valid.
    const git_describe = std.mem.trim(u8, result, " \n\r");

    if (git_describe.len == 0) {
        std.log.warn("git describe output was empty, cannot determine version", .{});
        return .unknown;
    }

    // Simple check: if it contains '-', assume it's a commit description
    // (e.g. "0.25.1-3-gabc123-dirty"), otherwise a tag.
    if (std.mem.findScalar(u8, git_describe, '-') != null) {
        return .{ .commit = git_describe };
    } else {
        return .{ .tag = git_describe };
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
    const effective_optimize: std.lang.Optimize = if (small_release)
        .small
    else if (release_safe)
        .safe
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
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = effective_optimize,
        }),
    });

    // Add the options module as an import named "options"
    exe.root_module.addImport("options", options_module.createModule());

    // Add the zig-toml parser as an import named "toml" (used by utils/parse_deps.zig)
    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = effective_optimize });
    exe.root_module.addImport("toml", toml_dep.module("toml"));

    // Link standard library, etc.
    b.installArtifact(exe);

    // Add a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Forward `zig build run -- <args>` to zenv.
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Add a build step for the executable itself (ensure it depends on install)
    const exe_step = b.step("exe", "Build the executable");
    exe_step.dependOn(b.getInstallStep());

    // Add a `zig build test` step that runs the unit tests.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // test_root.zig imports utils/parse_deps.zig, which imports "toml"
    unit_tests.root_module.addImport("toml", toml_dep.module("toml"));
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // --- Individual Target Steps ---
    if (version == .tag or force_release) {
        // Add individual target-specific build steps
        for (release_targets) |release_target| {
            const target_step_small = b.step(b.fmt("release-{s}-small", .{release_target.name}), b.fmt("Create ReleaseSmall build for {s}", .{release_target.description}));
            setupTargetReleaseWithOptimize(b, target_step_small, version_string, release_target.query, .small);

            const target_step_fast = b.step(b.fmt("release-{s}", .{release_target.name}), b.fmt("Create ReleaseFast build for {s}", .{release_target.description}));
            setupTargetReleaseWithOptimize(b, target_step_fast, version_string, release_target.query, .fast);
        }
    } else {
        // When not on a tag, add the fail message to each individual target step
        const error_msg = "error: git tag missing or invalid (needed for release builds, e.g., v0.1.0). Use -Dforce-release=true to override.";
        for (release_targets) |release_target| {
            const target_step_small = b.step(b.fmt("release-{s}-small", .{release_target.name}), b.fmt("Create ReleaseSmall build for {s}", .{release_target.description}));
            target_step_small.dependOn(&b.addFail(error_msg).step);

            const target_step_fast = b.step(b.fmt("release-{s}", .{release_target.name}), b.fmt("Create ReleaseFast build for {s}", .{release_target.description}));
            target_step_fast.dependOn(&b.addFail(error_msg).step);
        }
    }

    // --- All Targets Release Step ---
    const release_step = b.step("release", "Create release builds for all targets");
    const release_small_step = b.step("release-small", "Create small release builds for all targets");

    if (version == .tag or force_release) {
        // Set up release-all steps with different optimizations
        for (release_targets) |release_target| {
            setupTargetReleaseWithOptimize(b, release_step, version_string, release_target.query, .fast);
            setupTargetReleaseWithOptimize(b, release_small_step, version_string, release_target.query, .small);
        }
    } else {
        // Prevent running release builds on non-tagged commits
        const error_msg = "error: git tag missing or invalid (needed for release builds, e.g., v0.1.0). Use -Dforce-release=true to override.";
        release_step.dependOn(&b.addFail(error_msg).step);
        release_small_step.dependOn(&b.addFail(error_msg).step);
    }
}

// Creates a simplified version of the target triple for file naming:
// "<arch>-linux-musl" for musl Linux, "<arch>-<os>" otherwise.
fn simplifyTripleName(b: *std.Build, target: std.Target) []const u8 {
    const arch = @tagName(target.cpu.arch);
    const os = @tagName(target.os.tag);
    if (target.os.tag == .linux and target.abi == .musl) {
        return b.fmt("{s}-{s}-musl", .{ arch, os });
    }
    return b.fmt("{s}-{s}", .{ arch, os });
}

// Creates release artifact for a single target with specified optimization
fn setupTargetReleaseWithOptimize(
    b: *std.Build,
    release_step: *std.Build.Step,
    version_string: []const u8,
    target_query: std.Target.Query,
    comptime optimize: std.lang.Optimize,
) void {
    const target = b.resolveTargetQuery(target_query);
    const exe_name = "zenv";
    const release_dir_path = b.pathJoin(&.{"releases"});

    // --- Create Target-Specific Options Module ---
    const options_module_release = b.addOptions();
    options_module_release.addOption([]const u8, "version", version_string);
    const options_import = options_module_release.createModule();

    // --- Build Executable for the Target ---
    const exe_release = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_release.root_module.addImport("options", options_import);

    // Add the zig-toml parser for this cross-compiled target
    const toml_dep_rel = b.dependency("toml", .{ .target = target, .optimize = optimize });
    exe_release.root_module.addImport("toml", toml_dep_rel.module("toml"));

    // --- Package the Executable ---
    const triple = target.result.zigTriple(b.allocator) catch |err| {
        std.log.err("Failed to get target triple: {s}", .{@errorName(err)});
        return; // Skip this target if we can't get the triple
    };

    // Create a simplified name for the archive
    const simplified_triple = simplifyTripleName(b, target.result);

    // Add optimization mode to the archive name for clarity
    const opt_suffix = switch (optimize) {
        .small => "-small",
        else => "",
    };

    switch (target.result.os.tag) {
        .macos, .linux => { // Assuming tar for Linux and macOS
            // Create a more compatible archive format
            const archive_basename = b.fmt("{s}-{s}{s}.tar.gz", .{ exe_name, simplified_triple, opt_suffix });
            const tar_cmd = b.addSystemCommand(&.{
                "tar",
                "-czf", // Create, use gzip compression (more universal than xz)
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
