const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = @import("std").fs;

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
    output.print("Running script: {s}", .{script_abs_path}) catch {};
    var argv = [_][]const u8{ "/bin/bash", script_abs_path };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();

    // Check if the command was successful
    const success = blk: {
        if (term != .Exited) break :blk false;
        if (term.Exited != 0) break :blk false;
        break :blk true;
    };

    if (!success) {
        return error.ProcessError;
    }

    output.print("Setup script completed successfully", .{}) catch {};
}

pub fn setupEnvironmentDirectory(
    allocator: Allocator,
    base_dir: []const u8,
    env_name: []const u8,
) !void {
    const is_absolute_base_dir = std.fs.path.isAbsolute(base_dir);

    if (is_absolute_base_dir) {
        output.print("Ensuring absolute virtual environment base directory '{s}' exists...", .{base_dir}) catch {};

        // For absolute paths, create the directory directly
        std.fs.makeDirAbsolute(base_dir) catch |err| {
            if (err == error.PathAlreadyExists) {
                // Ignore this error, directory already exists
            } else {
                return err;
            }
        };

        // Create environment-specific directory using absolute path
        const joined = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name });
        defer allocator.free(joined);

        output.print("Creating environment directory '{s}'...", .{joined}) catch {};
        std.fs.makeDirAbsolute(joined) catch |err| {
            if (err == error.PathAlreadyExists) {
                // Ignore this error, directory already exists
            } else {
                return err;
            }
        };
    } else {
        output.print("Ensuring relative virtual environment base directory '{s}' exists...", .{base_dir}) catch {};

        // For relative paths, create the directory relative to cwd
        // First make sure base dir exists
        try fs.cwd().makePath(base_dir);

        // Create the environment directory
        const joined = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name });
        defer allocator.free(joined);

        output.print("Creating environment directory '{s}'...", .{joined}) catch {};
        try fs.cwd().makePath(joined);
    }
}

pub fn installDependencies(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    all_required_deps: *std.ArrayList([]const u8),
    force_deps: bool,
    rebuild_env: bool,
    modules_verified: bool,
    use_default_python: bool,
    dev_mode: bool,
    use_uv: bool,
    no_cache: bool,
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
    try setupEnvironment(allocator, env_config, env_name, base_dir, deps_slice, force_deps, rebuild_env, modules_verified, use_default_python, dev_mode, use_uv, no_cache);
}

// Sets up the full environment: creates files, generates and runs setup script.
pub fn setupEnvironment(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    deps: []const []const u8,
    force_deps: bool,
    rebuild_env: bool,
    modules_verified: bool,
    use_default_python: bool,
    dev_mode: bool,
    use_uv: bool,
    no_cache: bool,
) !void {
    output.print("Setting up environment '{s}' in base directory '{s}'...", .{ env_name, base_dir }) catch {};

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);

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
    output.print("Base directory is {s}: '{s}'", .{ if (is_absolute_base_dir) "absolute" else "relative", base_dir }) catch {};

    // Create requirements file path using base_dir
    var req_rel_path: []const u8 = undefined;
    var req_abs_path: []const u8 = undefined;

    if (is_absolute_base_dir) {
        // For absolute base_dir, paths are already absolute
        req_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "requirements.txt" });
        req_abs_path = try allocator.dupe(u8, req_rel_path); // Use same path for both
    } else {
        // For relative base_dir, combine with cwd for absolute paths
        req_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "requirements.txt" });
        req_abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, req_rel_path });
    }
    output.print("Requirements file paths: relative='{s}', absolute='{s}'", .{ req_rel_path, req_abs_path }) catch {};

    defer allocator.free(req_rel_path);
    defer allocator.free(req_abs_path);

    // Write the validated dependencies to the requirements file
    output.print("Writing {d} validated dependencies to {s}", .{ valid_deps_list.items.len, req_rel_path }) catch {};
    {
        var req_file = if (is_absolute_base_dir)
            try std.fs.createFileAbsolute(req_rel_path, .{})
        else
            try fs.cwd().createFile(req_rel_path, .{});

        defer {
            // Explicitly sync file content to disk before closing
            req_file.sync() catch |err| {
                output.printError("Warning: Failed to sync requirements file: {s}", .{@errorName(err)}) catch {};
            };
            req_file.close();
        }

        var bw = std.io.bufferedWriter(req_file.writer());
        const writer = bw.writer();

        if (valid_deps_list.items.len == 0) {
            output.print("Warning: No valid dependencies found! Writing only a comment to requirements file.", .{}) catch {};
            try writer.writeAll("# No valid dependencies found\n");
        } else {
            for (valid_deps_list.items) |dep| {
                try writer.print("{s}\n", .{dep});
                errors.debugLog(allocator, "Wrote dependency to file: {s}", .{dep});
            }
        }

        // Make sure to flush the buffered writer and check for errors
        try bw.flush();
        output.print("Requirements file successfully written and flushed", .{}) catch {};
    }
    output.print("Created requirements file: {s}", .{req_abs_path}) catch {};

    // Generate setup script path using base_dir
    var script_rel_path: []const u8 = undefined;
    var script_abs_path: []const u8 = undefined;

    if (is_absolute_base_dir) {
        // For absolute base_dir, paths are already absolute
        script_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "setup_env.sh" });
        script_abs_path = try allocator.dupe(u8, script_rel_path); // Use same path for both
    } else {
        // For relative base_dir, combine with cwd for absolute paths
        script_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "setup_env.sh" });
        script_abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, script_rel_path });
    }

    defer allocator.free(script_rel_path);
    defer allocator.free(script_abs_path);

    // Generate setup script content using the template
    const script_content = try template_setup.createSetupScriptFromTemplate(
        allocator,
        env_config,
        env_name,
        base_dir,
        req_abs_path,
        valid_deps_list.items.len,
        force_deps,
        rebuild_env,
        modules_verified,
        use_default_python,
        dev_mode,
        use_uv,
        no_cache,
    );
    defer allocator.free(script_content);

    // Write setup script to file
    output.print("Writing setup script to {s}", .{script_rel_path}) catch {};
    {
        var script_file = if (is_absolute_base_dir)
            try std.fs.createFileAbsolute(script_rel_path, .{})
        else
            try fs.cwd().createFile(script_rel_path, .{});

        defer script_file.close();
        try script_file.writeAll(script_content);
        try script_file.chmod(0o755);
    }
    output.print("Created setup script: {s}", .{script_abs_path}) catch {};

    // Execute setup script
    executeShellScript(allocator, script_abs_path) catch |err| {
        if (err == error.ModuleLoadError) {
            // Let this error propagate up as is
            return err;
        }
        // For other errors, propagate as ProcessError
        output.printError("Setup script execution failed.", .{}) catch {};
        return error.ProcessError;
    };

    output.print("Environment '{s}' setup completed successfully.", .{env_name}) catch {};
}
