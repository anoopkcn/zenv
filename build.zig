const std = @import("std");

const Version = union(enum) {
    tag: []const u8,
    commit: []const u8,
    // not in a git repo
    unknown,

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
    // utils/parse_deps.zig imports "toml"; utils/venv.zig imports "options".
    unit_tests.root_module.addImport("toml", toml_dep.module("toml"));
    unit_tests.root_module.addImport("options", options_module.createModule());
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // --- Release steps ---
    // Each target and mode is archived once; its per-target step and the
    // all-targets step share that archive. Without a tag every release step
    // fails instead.
    const tagged = version == .tag or force_release;
    const fail = &b.addFail("error: git tag missing or invalid (needed for release builds, e.g., v0.1.0). Use -Dforce-release=true to override.").step;
    var fast: [release_targets.len]*std.Build.Step = undefined;
    var small: [release_targets.len]*std.Build.Step = undefined;
    for (release_targets, &fast, &small) |release_target, *f, *s| {
        s.* = if (tagged) releaseArchive(b, options_module, release_target.query, .small) else fail;
        b.step(b.fmt("release-{s}-small", .{release_target.name}), b.fmt("Create ReleaseSmall build for {s}", .{release_target.description})).dependOn(s.*);

        f.* = if (tagged) releaseArchive(b, options_module, release_target.query, .fast) else fail;
        b.step(b.fmt("release-{s}", .{release_target.name}), b.fmt("Create ReleaseFast build for {s}", .{release_target.description})).dependOn(f.*);
    }

    const release_step = b.step("release", "Create release builds for all targets");
    const release_small_step = b.step("release-small", "Create small release builds for all targets");
    if (!tagged) {
        release_step.dependOn(fail);
        release_small_step.dependOn(fail);
    } else for (fast, small) |f, s| {
        release_step.dependOn(f);
        release_small_step.dependOn(s);
    }
}

/// Builds zenv for `query` and packs it as
/// `releases/zenv-<arch>-<os>[-musl][-small].tar.gz` (the names install.sh and
/// the release workflow expect). Returns the step that installs the archive.
fn releaseArchive(
    b: *std.Build,
    options: *std.Build.Step.Options,
    query: std.Target.Query,
    optimize: std.lang.Optimize,
) *std.Build.Step {
    const target = b.resolveTargetQuery(query);
    const exe = b.addExecutable(.{
        .name = "zenv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("options", options.createModule());
    exe.root_module.addImport("toml", b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml"));

    const t = target.result;
    const archive_name = b.fmt("zenv-{t}-{t}{s}{s}.tar.gz", .{
        t.cpu.arch,
        t.os.tag,
        if (t.os.tag == .linux and t.abi == .musl) "-musl" else "",
        if (optimize == .small) "-small" else "",
    });
    const tar = b.addSystemCommand(&.{ "tar", "-czf" });
    const archive = tar.addOutputFileArg(archive_name);
    tar.addArg("-C");
    tar.addDirectoryArg(exe.getEmittedBinDirectory());
    tar.addArg("zenv");
    return &b.addInstallFileWithDir(archive, .{ .custom = "releases" }, archive_name).step;
}
