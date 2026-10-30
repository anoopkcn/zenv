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

/// Tries to get version info from git describe
/// Adapted from https://github.com/kristoff-it/zine/blob/main/build.zig
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

/// Target definitions for release builds
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
    const release_safe = b.option(
        bool,
        "release-safe",
        "Build with ReleaseSafe mode (optimized but with assertions)",
    ) orelse false;
    const small_release = b.option(
        bool,
        "small-release",
        "Build with ReleaseSmall mode (optimize for binary size)",
    ) orelse false;
    // Add option to force releases even without a tag
    const force_release = b.option(
        bool,
        "force-release",
        "Allow release builds without git tags",
    ) orelse false;

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

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version_string);
    const options = build_options.createModule();

    const exe = b.addExecutable(.{
        .name = "zenv",
        .root_module = zenvModule(b, "src/main.zig", target, effective_optimize, null, options),
    });
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
        .root_module = zenvModule(b, "src/test_root.zig", target, optimize, null, options),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // --- Release steps ---
    // Each target is archived once; its per-target step and the all-targets
    // step share that archive. Without a tag every release step fails instead.
    const tagged = version == .tag or force_release;
    const fail = &b.addFail(
        "error: git tag missing or invalid (needed for release builds, e.g., v0.1.0). Use -Dforce-release=true to override.",
    ).step;
    const release_step = b.step("release", "Create release builds for all targets");
    for (release_targets) |release_target| {
        const archive = if (tagged) releaseArchive(b, options, release_target.query) else fail;
        b.step(
            b.fmt("release-{s}", .{release_target.name}),
            b.fmt("Create release build for {s}", .{release_target.description}),
        ).dependOn(archive);
        release_step.dependOn(archive);
    }
}

/// Builds zenv for `query` and packs it as `releases/zenv-<arch>-<os>[-musl].tar.gz`
/// (the names install.sh and the release workflow expect). Returns the step that
/// installs the archive. ReleaseSafe: runtime safety checks turn a bug into a
/// panic instead of undefined behavior in a tool that writes the registry and
/// deletes env directories; zenv is I/O-bound, so ReleaseFast/Small would gain
/// nothing measurable. Stripped, since ReleaseSafe keeps debug info by default.
fn releaseArchive(
    b: *std.Build,
    options: *std.Build.Module,
    query: std.Target.Query,
) *std.Build.Step {
    const target = b.resolveTargetQuery(query);
    const exe = b.addExecutable(.{
        .name = "zenv",
        .root_module = zenvModule(b, "src/main.zig", target, .safe, true, options),
    });

    const t = target.result;
    const archive_name = b.fmt("zenv-{t}-{t}{s}.tar.gz", .{
        t.cpu.arch,
        t.os.tag,
        if (t.os.tag == .linux and t.abi == .musl) "-musl" else "",
    });
    const tar = b.addSystemCommand(&.{ "tar", "-czf" });
    const archive = tar.addOutputFileArg(archive_name);
    tar.addArg("-C");
    tar.addDirectoryArg(exe.getEmittedBinDirectory());
    tar.addArg("zenv");
    return &b.addInstallFileWithDir(archive, .{ .custom = "releases" }, archive_name).step;
}

/// A module rooted at `root` with zenv's imports: the build `options` and the
/// zig-toml parser (`toml`).
fn zenvModule(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    strip: ?bool,
    options: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    module.addImport("options", options);
    module.addImport(
        "toml",
        b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml"),
    );
    return module;
}
