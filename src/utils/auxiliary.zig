const std = @import("std");
const Allocator = std.mem.Allocator;
const runtime = @import("runtime.zig");

const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const EnvironmentRegistry = config_module.EnvironmentRegistry;
const errors = @import("errors.zig");
const parse_deps = @import("parse_deps.zig");
const environment = @import("environment.zig");
const template_activate = @import("template_activate.zig");
const template_setup = @import("template_setup.zig");
const output = @import("output.zig");
const CommandFlags = @import("flags.zig").CommandFlags;

// Create activation script for the environment
pub fn createActivationScript(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
) !void {
    return template_activate.createScriptFromTemplate(allocator, env_config, env_name, base_dir);
}

// Executes a given shell script, inheriting stdio and handling errors
pub fn executeShellScript(
    allocator: std.mem.Allocator,
    script_abs_path: []const u8,
) !void {
    output.print(allocator, "Running script: {s}", .{script_abs_path}) catch {};
    var child = try std.process.spawn(runtime.io, .{
        .argv = &[_][]const u8{ "/bin/bash", script_abs_path },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(runtime.io);

    // Check if the command was successful
    const success = blk: {
        if (term != .exited) break :blk false;
        if (term.exited != 0) break :blk false;
        break :blk true;
    };

    if (!success) {
        return error.ProcessError;
    }

    // output.print(allocator,"Setup script completed successfully", .{}) catch {};
}

pub fn setupEnvironmentDirectory(
    allocator: Allocator,
    base_dir: []const u8,
    env_name: []const u8,
) !void {
    // runtime.makePath is recursive and idempotent, and works for both
    // absolute and relative paths.
    output.print(allocator, "Ensuring virtual environment base directory '{s}' exists...", .{base_dir}) catch {};
    try runtime.makePath(base_dir);

    const joined = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name });
    defer allocator.free(joined);

    output.print(allocator, "Creating environment directory '{s}'...", .{joined}) catch {};
    try runtime.makePath(joined);
}

pub fn installDependencies(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    all_required_deps: *std.array_list.Managed([]const u8),
    flags: CommandFlags,
    modules_verified: bool,
    command_str: ?[]const u8,
) !void {
    // Convert ArrayList to owned slice for more efficient processing
    const deps_slice = try all_required_deps.toOwnedSlice();
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
        modules_verified,
        command_str,
    );
}

// Sets up the full environment: creates files, generates and runs setup script.
pub fn setupEnvironment(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    deps: []const []const u8,
    flags: CommandFlags,
    modules_verified: bool,
    command_str: ?[]const u8,
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
        valid_deps_list.deinit();
    }

    // Handle paths differently based on whether base_dir is absolute or relative
    const is_absolute_base_dir = std.fs.path.isAbsolute(base_dir);
    output.print(allocator, "Base directory is {s}: '{s}'", .{ if (is_absolute_base_dir) "absolute" else "relative", base_dir }) catch {};

    // Create requirements file path using base_dir
    var req_rel_path: []const u8 = undefined;
    var req_abs_path: []const u8 = undefined;

    if (is_absolute_base_dir) {
        // base_dir is already absolute, so the relative and absolute paths are
        // identical — share one allocation rather than duplicating it.
        req_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "requirements.txt" });
        req_abs_path = req_rel_path;
    } else {
        // For relative base_dir, combine with cwd for absolute paths
        req_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "requirements.txt" });
        req_abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, req_rel_path });
    }
    output.print(allocator, "Requirements file paths: relative='{s}', absolute='{s}'", .{ req_rel_path, req_abs_path }) catch {};

    defer allocator.free(req_rel_path);
    defer if (req_abs_path.ptr != req_rel_path.ptr) allocator.free(req_abs_path);

    // Write the validated dependencies to the requirements file
    output.print(allocator, "Writing {d} validated dependencies to {s}", .{ valid_deps_list.items.len, req_rel_path }) catch {};
    {
        var req_file = try runtime.createFile(req_rel_path, .{});

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

    // Generate setup script path using base_dir
    var script_rel_path: []const u8 = undefined;
    var script_abs_path: []const u8 = undefined;

    if (is_absolute_base_dir) {
        // base_dir is already absolute — share one allocation for both paths.
        script_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "setup_env.sh" });
        script_abs_path = script_rel_path;
    } else {
        // For relative base_dir, combine with cwd for absolute paths
        script_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "setup_env.sh" });
        script_abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, script_rel_path });
    }

    defer allocator.free(script_rel_path);
    defer if (script_abs_path.ptr != script_rel_path.ptr) allocator.free(script_abs_path);

    // Generate setup script content using the template
    const script_content = try template_setup.createSetupScriptFromTemplate(
        allocator,
        env_config,
        env_name,
        base_dir,
        req_abs_path,
        flags,
        modules_verified,
        command_str,
    );
    defer allocator.free(script_content);

    // Write setup script to file
    output.print(allocator, "Writing setup script to {s}", .{script_rel_path}) catch {};
    {
        var script_file = try runtime.createFile(script_rel_path, .{ .permissions = .fromMode(0o755) });
        defer script_file.close(runtime.io);
        try script_file.writeStreamingAll(runtime.io, script_content);
    }
    output.print(allocator, "Created setup script: {s}", .{script_abs_path}) catch {};

    // Execute setup script. Any failure (non-zero exit or spawn error) surfaces
    // as ProcessError; executeShellScript never returns ModuleLoadError.
    executeShellScript(allocator, script_abs_path) catch {
        output.printError(allocator, "Setup script execution failed.", .{}) catch {};
        return error.ProcessError;
    };

    output.print(allocator, "Environment '{s}' setup completed successfully.", .{env_name}) catch {};
}
