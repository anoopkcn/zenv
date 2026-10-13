const std = @import("std");
const Allocator = std.mem.Allocator;
const runtime = @import("runtime.zig");
const paths = @import("paths.zig");

const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const EnvironmentRegistry = config_module.EnvironmentRegistry;
const errors = @import("errors.zig");
const parse_deps = @import("parse_deps.zig");
const environment = @import("environment.zig");
const envbuild = @import("envbuild.zig");
const output = @import("output.zig");
const CommandFlags = @import("flags.zig").CommandFlags;

pub fn setupEnvironmentDirectory(
    allocator: Allocator,
    base_dir: []const u8,
    env_name: []const u8,
) !void {
    // runtime.makePath is recursive and idempotent, and works for both
    // absolute and relative paths.
    output.print(allocator, "Ensuring virtual environment base directory '{s}' exists...", .{base_dir}) catch {};
    try runtime.makePath(base_dir);

    const joined = try std.Io.Dir.path.join(allocator, &[_][]const u8{ base_dir, env_name });
    defer allocator.free(joined);

    output.print(allocator, "Creating environment directory '{s}'...", .{joined}) catch {};
    try runtime.makePath(joined);
}

pub fn installDependencies(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    all_required_deps: *std.ArrayList([]const u8),
    flags: CommandFlags,
) !void {
    // Convert ArrayList to owned slice for more efficient processing
    const deps_slice = try all_required_deps.toOwnedSlice(allocator);
    // Handle memory cleanup
    defer {
        // Clean up individually owned strings but not config-provided ones
        for (deps_slice) |item| {
            if (!parse_deps.isConfigProvidedDependency(env_config, item)) {
                allocator.free(item);
            }
        }
        allocator.free(deps_slice); // Free the slice itself
    }

    // Call the main environment setup function
    try setupEnvironment(
        allocator,
        env_config,
        env_name,
        base_dir,
        deps_slice,
        flags,
    );
}

// Sets up the full environment: records the dependency list, then builds the
// venv (see envbuild.zig).
pub fn setupEnvironment(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    deps: []const []const u8,
    flags: CommandFlags,
) !void {
    output.print(allocator, "Setting up environment '{s}' in base directory '{s}'...", .{ env_name, base_dir }) catch {};

    // Get absolute path of current working directory
    const cwd_path = try runtime.cwdRealpath(allocator);
    defer allocator.free(cwd_path);

    // Validate dependencies first
    var valid_deps_list = try parse_deps.validateDependencies(allocator, deps, env_name);
    defer {
        // Important: Defer freeing the list *after* freeing potentially owned items
        // validateDependencies returns an ArrayList whose items point EITHER to the original `deps` slices
        // OR to slices owned by the caller of setupEnvironment (e.g., duplicated from reading files).
        // It does NOT allocate new strings for the deps itself. The caller owns the deps strings.
        // Therefore, we only need to deinit the ArrayList itself.
        valid_deps_list.deinit(allocator);
    }

    // One venv-path derivation for the whole setup; everything below joins
    // onto this absolute directory (setup runs in the project dir, so cwd is
    // the anchor for a relative base_dir).
    const venv_dir = try paths.venvPath(allocator, cwd_path, base_dir, env_name);
    defer allocator.free(venv_dir);
    output.print(allocator, "Environment directory: '{s}'", .{venv_dir}) catch {};

    const req_abs_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_dir, "requirements.txt" });
    defer allocator.free(req_abs_path);

    // Write the validated dependencies to the requirements file
    output.print(allocator, "Writing {d} validated dependencies to {s}", .{ valid_deps_list.items.len, req_abs_path }) catch {};
    {
        var req_file = try runtime.createFile(req_abs_path, .{});

        defer {
            // Explicitly sync file content to disk before closing
            req_file.sync(runtime.io) catch |err| {
                output.printError(allocator, "Warning: Failed to sync requirements file: {s}", .{@errorName(err)}) catch {};
            };
            req_file.close(runtime.io);
        }

        var wbuf: [4096]u8 = undefined;
        var fw = req_file.writer(runtime.io, &wbuf);
        const writer = &fw.interface;

        if (valid_deps_list.items.len == 0) {
            output.print(allocator, "Warning: No valid dependencies found! Writing only a comment to requirements file.", .{}) catch {};
            try writer.writeAll("# No valid dependencies found\n");
        } else {
            for (valid_deps_list.items) |dep| {
                try writer.print("{s}\n", .{dep});
                errors.debugLog(allocator, "Wrote dependency to file: {s}", .{dep});
            }
        }

        // Make sure to flush the buffered writer and check for errors
        try writer.flush();
        output.print(allocator, "Requirements file successfully written and flushed", .{}) catch {};
    }
    output.print(allocator, "Created requirements file: {s}", .{req_abs_path}) catch {};

    try envbuild.run(allocator, .{
        .env_config = env_config,
        .env_name = env_name,
        .venv_dir = venv_dir,
        .project_dir = cwd_path,
        .deps = valid_deps_list.items,
        .flags = flags,
    });

    output.print(allocator, "Environment '{s}' setup completed successfully.", .{env_name}) catch {};
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");
