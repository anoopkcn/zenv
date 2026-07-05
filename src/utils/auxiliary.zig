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
    const term = try runtime.exec(&[_][]const u8{ "/bin/bash", script_abs_path }, .{});

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

    // One venv-path derivation for the whole setup; everything below joins
    // onto this absolute directory (setup runs in the project dir, so cwd is
    // the anchor for a relative base_dir).
    const venv_dir = try paths.venvPath(allocator, cwd_path, base_dir, env_name);
    defer allocator.free(venv_dir);
    output.print(allocator, "Environment directory: '{s}'", .{venv_dir}) catch {};

    const req_abs_path = try std.fs.path.join(allocator, &[_][]const u8{ venv_dir, "requirements.txt" });
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

    const script_abs_path = try std.fs.path.join(allocator, &[_][]const u8{ venv_dir, "setup_env.sh" });
    defer allocator.free(script_abs_path);

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

    // Write setup script to file, synced before we execute it below.
    output.print(allocator, "Writing setup script to {s}", .{script_abs_path}) catch {};
    {
        var script_file = try runtime.createFile(script_abs_path, .{ .permissions = .fromMode(0o755) });
        defer script_file.close(runtime.io);
        try script_file.writeStreamingAll(runtime.io, script_content);
        try script_file.sync(runtime.io);
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

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");

test "executeShellScript maps the child's exit status to success/ProcessError" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const prev = test_support.useFakeExec();
    defer runtime.exec_backend = prev;

    test_support.fake_exec_exit = 0; // clean exit -> ok (the fake ignores the path)
    try executeShellScript(a, "/tmp/ignored.sh");

    test_support.fake_exec_exit = 1; // non-zero exit -> ProcessError
    try testing.expectError(error.ProcessError, executeShellScript(a, "/tmp/ignored.sh"));
}
