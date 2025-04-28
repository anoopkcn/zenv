const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("../config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const EnvironmentRegistry = config_module.EnvironmentRegistry;
const errors = @import("../errors.zig");
const fs = @import("std").fs;
const process = @import("std").process;

const parse_deps = @import("parse_deps.zig");
const environment = @import("environment.zig");
const template_activate = @import("template_activate.zig");
const template_setup = @import("template_setup.zig");

// Create activation script for the environment
pub fn createActivationScript(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8, base_dir: []const u8) !void {
    return template_activate.createScriptFromTemplate(allocator, env_config, env_name, base_dir);
}

// Executes a given shell script, inheriting stdio and handling errors
pub fn executeShellScript(allocator: Allocator, script_abs_path: []const u8, script_rel_path: []const u8) !void {
    std.log.info("Running script: {s}", .{script_abs_path});
    const argv = [_][]const u8{ "/bin/sh", script_abs_path };
    var child = process.Child.init(&argv, allocator);

    // Inherit stdio for real-time output
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.stdin_behavior = .Inherit; // Allow user input if script needs it

    const term = try child.spawnAndWait();

    if (term != .Exited or term.Exited != 0) {
        // Just show a concise error message - since stdout/stderr is already inherited,
        // the actual error output from the module command will have been displayed already
        std.log.err("Script execution failed with exit code: {d}", .{term.Exited});

        // Only log debug info when enabled via environment variable
        const enable_debug_logs = blk: {
            const env_var = std.process.getEnvVarOwned(allocator, "ZENV_DEBUG") catch |err| {
                if (err == error.EnvironmentVariableNotFound) break :blk false;
                std.log.warn("Failed to check ZENV_DEBUG environment variable: {s}", .{@errorName(err)});
                break :blk false;
            };
            defer allocator.free(env_var);
            break :blk std.mem.eql(u8, env_var, "1") or
                std.mem.eql(u8, env_var, "true") or
                std.mem.eql(u8, env_var, "yes");
        };

        if (enable_debug_logs) {
            const script_content_debug = fs.cwd().readFileAlloc(allocator, script_rel_path, 1024 * 1024) catch |read_err| {
                std.log.err("Failed to read script content for debug log: {s}", .{@errorName(read_err)});
                return error.ProcessError;
            };
            defer allocator.free(script_content_debug);

            // Log to a debug file instead of stderr
            const debug_log_path = try std.fmt.allocPrint(allocator, "{s}.debug.log", .{script_rel_path});
            defer allocator.free(debug_log_path);

            var debug_file = fs.cwd().createFile(debug_log_path, .{}) catch |err| {
                std.log.err("Could not create debug log file: {s}", .{@errorName(err)});
                return error.ProcessError;
            };
            defer debug_file.close();

            _ = debug_file.writeAll(script_content_debug) catch {};
            std.log.debug("Script content written to debug log: {s}", .{debug_log_path});
        }

        // Check if this is a module load failure by reading the script content
        // This is a heuristic but should work for our use case
        const script_content = fs.cwd().readFileAlloc(allocator, script_rel_path, 1024 * 1024) catch |read_err| {
            std.log.err("Failed to read script content: {s}", .{@errorName(read_err)});
            return error.ProcessError;
        };
        defer allocator.free(script_content);

        // Check if this script contains module load commands and the specific error text
        if (std.mem.indexOf(u8, script_content, "module load") != null and
            std.mem.indexOf(u8, script_content, "Error: Failed to load module") != null)
        {
            return error.ModuleLoadError;
        }

        return error.ProcessError;
    }

    std.log.info("Script completed successfully: {s}", .{script_abs_path});
}

// Sets up the full environment: creates files, generates and runs setup script.
pub fn setupEnvironment(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8, base_dir: []const u8, deps: []const []const u8, force_deps: bool) !void {
    std.log.info("Setting up environment '{s}' in base directory '{s}'...", .{ env_name, base_dir });

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

    // Create requirements file path using base_dir
    const req_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "requirements.txt" });
    defer allocator.free(req_rel_path);
    const req_abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, req_rel_path });
    defer allocator.free(req_abs_path);

    // Write the validated dependencies to the requirements file
    std.log.info("Writing {d} validated dependencies to {s}", .{ valid_deps_list.items.len, req_rel_path });
    {
        var req_file = try fs.cwd().createFile(req_rel_path, .{});
        defer req_file.close();
        var bw = std.io.bufferedWriter(req_file.writer());
        const writer = bw.writer();

        if (valid_deps_list.items.len == 0) {
            std.log.warn("No valid dependencies found! Writing only a comment to requirements file.", .{});
            try writer.writeAll("# No valid dependencies found\n");
        } else {
            for (valid_deps_list.items) |dep| {
                try writer.print("{s}\n", .{dep});
                std.log.debug("Wrote dependency to file: {s}", .{dep});
            }
        }
        try bw.flush();
    }
    std.log.info("Created requirements file: {s}", .{req_abs_path});

    // Generate setup script path using base_dir
    const script_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "setup_env.sh" });
    defer allocator.free(script_rel_path);
    const script_abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, script_rel_path });
    defer allocator.free(script_abs_path);

    // Generate setup script content using the template
    const script_content = try template_setup.createSetupScriptFromTemplate(allocator, env_config, env_name, base_dir, req_abs_path, valid_deps_list.items.len, force_deps);
    defer allocator.free(script_content);

    // Write setup script to file
    std.log.info("Writing setup script to {s}", .{script_rel_path});
    {
        var script_file = try fs.cwd().createFile(script_rel_path, .{});
        defer script_file.close();
        try script_file.writeAll(script_content);
        try script_file.chmod(0o755);
    }
    std.log.info("Created setup script: {s}", .{script_abs_path});

    // Execute setup script
    executeShellScript(allocator, script_abs_path, script_rel_path) catch |err| {
        if (err == error.ModuleLoadError) {
            // Let this error propagate up as is
            return err;
        }
        // For other errors, propagate as ProcessError
        std.log.err("Setup script execution failed.", .{});
        return error.ProcessError;
    };

    std.log.info("Environment '{s}' setup completed successfully.", .{env_name});
}
