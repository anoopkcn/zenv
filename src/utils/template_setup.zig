const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const fs = std.fs;
const output = @import("output.zig");
const template = @import("template.zig");

// Embed the template file at compile time
const SETUP_ENV_TEMPLATE = @embedFile("templates/setup_env.sh.template");

// Public function to export
pub fn createSetupScriptFromTemplate(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    req_abs_path: []const u8,
    valid_deps_list_len: usize,
    force_deps: bool,
    rebuild_env: bool,
    modules_verified: bool,
    use_default_python: bool,
    dev_mode: bool,
    use_uv: bool,
    no_cache: bool,
) ![]const u8 {
    return try createSetupScript(
        allocator,
        env_config,
        env_name,
        base_dir,
        req_abs_path,
        valid_deps_list_len,
        force_deps,
        rebuild_env,
        modules_verified,
        use_default_python,
        dev_mode,
        use_uv,
        no_cache,
    );
}

fn fileExists(path: []const u8) bool {
    fs.cwd().access(path, .{}) catch {
        return false;
    };
    return true;
}

// Helper function to copy hook scripts to the environment's scripts directory
fn copyHookScript(
    allocator: Allocator,
    hook_path: []const u8,
    scripts_dir: []const u8,
    dest_filename: []const u8,
    is_absolute_base_dir: bool,
    cwd_path: []const u8,
) ![]const u8 {
    var source_path: []const u8 = undefined;
    var path_allocd = false;

    // 1. Try hook_path as-is (if absolute)
    if (std.fs.path.isAbsolute(hook_path)) {
        source_path = hook_path;
        path_allocd = false;
    } else {
        // 2. Try relative to cwd (where zenv.json is)
        const rel_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, hook_path });
        defer allocator.free(rel_path);

        if (accessFile(rel_path)) {
            source_path = try allocator.dupe(u8, rel_path);
            path_allocd = true;
        } else {
            // 3. Try just the filename in current directory
            if (accessFile(hook_path)) {
                source_path = hook_path;
                path_allocd = false;
            } else {
                // No path worked, report error
                output.printError("Hook script not found: tried '{s}' and '{s}'", .{ hook_path, rel_path }) catch {};
                return error.FileNotFound;
            }
        }
    }
    defer if (path_allocd) allocator.free(source_path);

    output.print("Found hook script at: {s}", .{source_path}) catch {};

    // Ensure the source file really exists and is readable before proceeding
    if (!accessFile(source_path)) {
        output.printError("Hook script found but cannot be read: {s}", .{source_path}) catch {};
        return error.FileNotFound;
    }

    // Construct destination path
    var dest_path: []const u8 = undefined;
    if (is_absolute_base_dir) {
        dest_path = try std.fs.path.join(allocator, &[_][]const u8{ scripts_dir, dest_filename });
    } else {
        // For relative paths, scripts_dir is already joined with cwd_path earlier
        // so we should not include cwd_path again
        dest_path = try std.fs.path.join(allocator, &[_][]const u8{ scripts_dir, dest_filename });
    }
    errdefer allocator.free(dest_path);

    // Copy the script file - add extra debug info
    output.print("Attempting to open source file: {s}", .{source_path}) catch {};
    var source_file = fs.cwd().openFile(source_path, .{}) catch |err| {
        output.printError("Failed to open source hook script '{s}': {s}", .{ source_path, @errorName(err) }) catch {};
        return error.FileNotFound;
    };
    defer source_file.close();

    output.print("Attempting to create destination file: {s}", .{dest_path}) catch {};
    var dest_file = if (is_absolute_base_dir)
        std.fs.createFileAbsolute(dest_path, .{}) catch |err| {
            output.printError("Failed to create destination file '{s}': {s}", .{ dest_path, @errorName(err) }) catch {};
            return error.FileNotFound;
        }
    else
        fs.cwd().createFile(dest_path, .{}) catch |err| {
            output.printError("Failed to create destination file '{s}': {s}", .{ dest_path, @errorName(err) }) catch {};
            return error.FileNotFound;
        };
    defer dest_file.close();

    // Copy the content
    var buffer: [8192]u8 = undefined;
    var bytes_read: usize = 0;
    while (true) {
        bytes_read = source_file.read(&buffer) catch |err| {
            output.printError("Error reading from source file '{s}': {s}", .{ source_path, @errorName(err) }) catch {};
            return error.FileNotFound;
        };
        if (bytes_read == 0) break;
        dest_file.writeAll(buffer[0..bytes_read]) catch |err| {
            output.printError("Error writing to destination file '{s}': {s}", .{ dest_path, @errorName(err) }) catch {};
            return error.FileNotFound;
        };
    }

    // Make the destination file executable
    dest_file.chmod(0o755) catch |err| {
        output.printError("Failed to set permissions on '{s}': {s}", .{ dest_path, @errorName(err) }) catch {};
        // Continue anyway, this is not critical
    };

    output.print("Copied hook script from {s} to {s}", .{ source_path, dest_path }) catch {};
    return dest_path;
}

fn accessFile(path: []const u8) bool {
    fs.cwd().access(path, .{}) catch {
        return false;
    };
    return true;
}

fn createSetupScript(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    req_abs_path: []const u8,
    valid_deps_list_len: usize,
    force_deps: bool,
    rebuild_env: bool,
    modules_verified: bool,
    use_default_python: bool,
    dev_mode: bool,
    use_uv: bool,
    no_cache: bool,
) ![]const u8 {
    try output.print("Creating setup script for '{s}'...", .{env_name});

    // Get absolute path of current working directory (where zenv.json is)
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);
    output.print("Current working directory: {s}", .{cwd_path}) catch {};

    const is_absolute_base_dir = std.fs.path.isAbsolute(base_dir);

    // Virtual environment absolute path
    var venv_dir: []const u8 = undefined;
    if (is_absolute_base_dir) {
        // For absolute base_dir, simply join with env_name
        venv_dir = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name });
    } else {
        // For relative base_dir, combine with cwd for absolute path
        venv_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, base_dir, env_name });
    }
    defer allocator.free(venv_dir);

    // Activation script path
    var activate_script_path: []const u8 = undefined;
    if (is_absolute_base_dir) {
        // For absolute base_dir, paths are already absolute
        activate_script_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "activate.sh" });
    } else {
        // For relative base_dir, combine with cwd for absolute paths
        activate_script_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, base_dir, env_name, "activate.sh" });
    }
    defer allocator.free(activate_script_path);

    // Create scripts directory for hook scripts if needed
    var scripts_rel_path: []const u8 = undefined;
    if (is_absolute_base_dir) {
        scripts_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "scripts" });
    } else {
        scripts_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, base_dir, env_name, "scripts" });
    }
    defer allocator.free(scripts_rel_path);

    // Create the scripts directory
    output.print("Creating scripts directory: {s}", .{scripts_rel_path}) catch {};
    if (is_absolute_base_dir) {
        std.fs.makeDirAbsolute(scripts_rel_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                output.printError("Failed to create scripts directory '{s}': {s}", .{ scripts_rel_path, @errorName(err) }) catch {};
                // Continue anyway, as this is not a critical error
            }
        };
    } else {
        fs.cwd().makePath(scripts_rel_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                output.printError("Failed to create scripts directory '{s}': {s}", .{ scripts_rel_path, @errorName(err) }) catch {};
                // Continue anyway, as this is not a critical error
            }
        };
    }

    // Handle setup hook script copying if present
    var setup_hook_block = std.ArrayList(u8).init(allocator);
    defer setup_hook_block.deinit();
    var setup_hook_path: ?[]const u8 = null;
    defer if (setup_hook_path) |path| allocator.free(path);

    if (env_config.setup != null and env_config.setup.?.script != null) {
        const hook_path = env_config.setup.?.script.?;
        output.print("Processing setup script: '{s}'", .{hook_path}) catch {};

        // Copy the script to the environment's scripts directory
        const dest_path = copyHookScript(allocator, hook_path, scripts_rel_path, "setup_hook.sh", is_absolute_base_dir, cwd_path) catch |err| {
            output.printError("Failed to copy setup script '{s}': {s}", .{ hook_path, @errorName(err) }) catch {};
            // Continue anyway, but add a warning in the script
            try setup_hook_block.writer().print(
                \\
                \\# Warning: Failed to copy setup script from '{s}'
                \\echo "Warning: Failed to copy setup script from '{s}'"
                \\
            , .{ hook_path, hook_path });

            // Skip the rest of this hook processing
            return error.FileNotFound;
        };
        defer allocator.free(dest_path);
        setup_hook_path = try allocator.dupe(u8, dest_path);

        try setup_hook_block.writer().print(
            \\
            \\# Execute custom setup script if it exists
            \\if [ -f "{s}" ]; then
            \\  echo "Info: Running setup script: {s}"
            \\  # Source the script to maintain environment variables
            \\  source "{s}" || echo "Warning: Setup script failed with exit code $?"
            \\else
            \\  echo "Warning: Setup script not found at {s}"
            \\fi
            \\
        , .{ dest_path, dest_path, dest_path, dest_path });
    }

    // Create a map for template replacements
    var replacements = std.StringHashMap([]const u8).init(allocator);
    defer {
        // We'll handle freeing allocated values but not static strings
        replacements.deinit();
    }

    // Add basic replacements for the template
    try replacements.put("ENV_NAME", env_name);
    try replacements.put("VENV_DIR", venv_dir);

    // Get the fallback python to use
    var fallback_python: []const u8 = undefined;

    // When --python flag is used, try to get the default Python
    if (use_default_python) {
        // Try to get the default Python path
        const default_python = @import("python.zig").getDefaultPythonPath(allocator) catch |err| {
            output.printError("Failed to read default Python path with --python flag: {s}", .{@errorName(err)}) catch {};
            return error.MissingPythonExecutable;
        };

        if (default_python) |path| {
            // Build the full path to the Python binary
            const python_bin = try std.fs.path.join(allocator, &[_][]const u8{ path, "bin", "python3" });
            defer allocator.free(python_bin);
            fallback_python = try allocator.dupe(u8, python_bin);
            try output.print("Using default Python from ZENV_DIR/default-python: {s}", .{fallback_python});
        } else {
            output.printError("--python flag specified but no default Python configured", .{}) catch {};
            output.printError("Set a default Python first: zenv python use <version>", .{}) catch {};
            return error.MissingPythonExecutable;
        }
    } else {
        // Normal behavior without --python flag
        if (env_config.fallback_python) |py| {
            // Use the explicitly configured fallback Python
            fallback_python = py;
        } else {
            // Try to get the default Python path
            if (@import("python.zig").getDefaultPythonPath(allocator)) |default_python| {
                if (default_python) |path| {
                    // Build the full path to the Python binary
                    const python_bin = try std.fs.path.join(allocator, &[_][]const u8{ path, "bin", "python3" });
                    defer allocator.free(python_bin);
                    fallback_python = try allocator.dupe(u8, python_bin);
                } else {
                    fallback_python = "python3"; // No default Python path found
                }
            } else |err| {
                try output.print("Warning: Failed to get default Python path: {s}", .{@errorName(err)});
                fallback_python = "python3"; // Default to python3 if no default is configured
            }
        }
    }

    try replacements.put("FALLBACK_PYTHON", fallback_python);
    try replacements.put("ACTIVATE_SCRIPT_PATH", activate_script_path);
    try replacements.put("REQUIREMENTS_PATH", req_abs_path);

    // Set modules_verified flag for the template
    try replacements.put("MODULES_VERIFIED_VALUE", if (modules_verified) "MODULES_VERIFIED=true" else "MODULES_VERIFIED=false");

    // Set force_deps flag for the template
    try replacements.put("FORCE_DEPS_VALUE", if (force_deps) "FORCE_DEPS=true" else "FORCE_DEPS=false");

    // Set rebuild_env flag for the template
    try replacements.put("REBUILD_ENV_VALUE", if (rebuild_env) "REBUILD_ENV=true" else "REBUILD_ENV=false");

    // Set use_default_python flag for the template
    try replacements.put("USE_DEFAULT_PYTHON_VALUE", if (use_default_python) "USE_DEFAULT_PYTHON=true" else "USE_DEFAULT_PYTHON=false");

    // Set dev_mode flag for the template
    try replacements.put("DEV_MODE_VALUE", if (dev_mode) "DEV_MODE=true" else "DEV_MODE=false");

    // Set use_uv flag for the template
    try replacements.put("USE_UV_VALUE", if (use_uv) "USE_UV=true" else "USE_UV=false");

    // Set no_cache flag for the template
    try replacements.put("NO_CACHE_VALUE", if (no_cache) "NO_CACHE=true" else "NO_CACHE=false");

    // Create the pip install command based on whether we have dependencies
    const pip_install_cmd = if (valid_deps_list_len > 0)
        try std.fmt.allocPrint(allocator, "python -m pip install -r {s}", .{req_abs_path})
    else
        "echo 'Info: No dependencies in requirements file to install.'";
    defer if (valid_deps_list_len > 0) allocator.free(pip_install_cmd);

    try replacements.put("PIP_INSTALL_COMMAND", pip_install_cmd);

    // Generate the module loading block
    var module_loading_block = std.ArrayList(u8).init(allocator);
    defer module_loading_block.deinit();
    const module_writer = module_loading_block.writer();

    if (env_config.modules.items.len > 0) {
        // Build the module list string for display
        var module_list_str = std.ArrayList(u8).init(allocator);
        defer module_list_str.deinit();
        for (env_config.modules.items, 0..) |module_name, idx| {
            if (idx > 0) try module_list_str.appendSlice(", ");
            try module_list_str.appendSlice(module_name);
        }

        if (env_config.modules_file) |modules_file| {
            try module_writer.print("echo 'Info: Loading required modules from file: {s}'\n", .{modules_file});
        } else {
            try module_writer.print("echo 'Info: Loading required modules'\n", .{});
        }
        try module_writer.print("echo 'Info: Loading {d} modules:'\n", .{env_config.modules.items.len});
        for (env_config.modules.items, 0..) |module_name, idx| {
            try module_writer.print("echo '  - Module #{d}: \"{s}\"'\n", .{ idx + 1, module_name });
        }

        // The set +e and error checking are now in the template itself, based on modules_verified

        // Load each module
        for (env_config.modules.items) |module_name| {
            // Add debug information before loading
            try module_writer.print("info \"Attempting to load module: '{s}'\"\n", .{module_name});

            if (modules_verified) {
                // Just load the module when pre-verified, we already checked they exist
                try module_writer.print("safe_module_load '{s}'\n", .{module_name});
            } else {
                // Load with error handling when not pre-verified
                try module_writer.print("safe_module_load '{s}' || handle_module_error '{s}'\n", .{ module_name, module_name });
            }
        }
    } else {
        try module_writer.print("echo 'Info: No modules specified to load'\n", .{});
    }

    const module_loading_slice = try module_loading_block.toOwnedSlice();
    defer allocator.free(module_loading_slice);
    try replacements.put("MODULE_LOADING_BLOCK", module_loading_slice);

    // Generate custom setup commands block
    var custom_setup_commands_block = std.ArrayList(u8).init(allocator);
    defer custom_setup_commands_block.deinit();
    const custom_writer = custom_setup_commands_block.writer();

    if (env_config.setup != null and env_config.setup.?.commands != null and env_config.setup.?.commands.?.items.len > 0) {
        try custom_writer.print("echo 'Info: Step 5: Running custom setup commands'\n", .{});
        try custom_writer.print("# Activate again just in case custom commands need the venv\n", .{});
        try custom_writer.print("source {s}/bin/activate\n", .{venv_dir});
        for (env_config.setup.?.commands.?.items) |cmd| {
            try custom_writer.print("{s}\n", .{cmd});
        }
        try custom_writer.print("\n", .{});
    }

    const custom_commands_slice = try custom_setup_commands_block.toOwnedSlice();
    defer allocator.free(custom_commands_slice);
    try replacements.put("CUSTOM_SETUP_COMMANDS_BLOCK", custom_commands_slice);

    // Add the hook script block to replacements
    const setup_hook_slice = try setup_hook_block.toOwnedSlice();
    defer allocator.free(setup_hook_slice);
    try replacements.put("SETUP_HOOK_BLOCK", setup_hook_slice);

    const processed_content = try template.processTemplateString(allocator, SETUP_ENV_TEMPLATE, replacements);
    return processed_content;
}
