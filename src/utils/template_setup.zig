const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const EnvironmentConfig = config_module.EnvironmentConfig;
const output = @import("output.zig");
const template = @import("template.zig");
const runtime = @import("runtime.zig");
const CommandFlags = @import("flags.zig").CommandFlags;

// Embed the template file at compile time
const SETUP_ENV_TEMPLATE = @embedFile("templates/setup.template");

// Public function to export
pub fn createSetupScriptFromTemplate(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    req_abs_path: []const u8,
    flags: CommandFlags,
    modules_verified: bool,
    command_str: ?[]const u8,
) ![]const u8 {
    return try createSetupScript(
        allocator,
        env_config,
        env_name,
        base_dir,
        req_abs_path,
        flags,
        modules_verified,
        command_str,
    );
}

fn createSetupScript(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    req_abs_path: []const u8,
    flags: CommandFlags,
    modules_verified: bool,
    command_str: ?[]const u8,
) ![]const u8 {
    try output.print(allocator, "Creating setup script for '{s}'...", .{env_name});

    // Get absolute path of current working directory (where zenv.json is)
    const cwd_path = try runtime.cwdRealpath(allocator);
    defer allocator.free(cwd_path);
    output.print(allocator, "Current working directory: {s}", .{cwd_path}) catch {};

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

    // Create scripts directory for hook scripts if needed
    var scripts_rel_path: []const u8 = undefined;
    if (is_absolute_base_dir) {
        scripts_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "scripts" });
    } else {
        scripts_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, base_dir, env_name, "scripts" });
    }
    defer allocator.free(scripts_rel_path);

    // Create the scripts directory
    output.print(allocator, "Creating scripts directory: {s}", .{scripts_rel_path}) catch {};
    runtime.makePath(scripts_rel_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            output.printError(allocator, "Failed to create scripts directory '{s}': {s}", .{ scripts_rel_path, @errorName(err) }) catch {};
            // Continue anyway, as this is not a critical error
        }
    };

    // Handle setup hook script copying if present
    var setup_hook_block = std.array_list.Managed(u8).init(allocator);
    defer setup_hook_block.deinit();
    var setup_hook_path: ?[]const u8 = null;
    defer if (setup_hook_path) |path| allocator.free(path);

    if (env_config.setup != null and env_config.setup.?.script != null) {
        const hook_path = env_config.setup.?.script.?;
        output.print(allocator, "Processing setup script: '{s}'", .{hook_path}) catch {};

        // Copy the script to the environment's scripts directory
        const dest_path = template.copyHookScript(allocator, hook_path, scripts_rel_path, "setup_hook.sh", cwd_path) catch |err| {
            // A configured setup script that can't be copied is a hard error: the
            // environment would otherwise be set up without the user's setup steps,
            // silently diverging from zenv.json. Fail loudly instead.
            output.printError(allocator, "Failed to copy setup script '{s}': {s}", .{ hook_path, @errorName(err) }) catch {};
            return error.FileNotFound;
        };
        defer allocator.free(dest_path);
        setup_hook_path = try allocator.dupe(u8, dest_path);

        try setup_hook_block.print(
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

    // Add command string if provided
    if (command_str) |cmd| {
        try replacements.put("COMMAND_STRING", cmd);
    } else {
        try replacements.put("COMMAND_STRING", "unknown");
    }

    // Get the fallback python to use. Track ownership separately: only the two
    // duped branches below allocate, so only those may be freed. The config-
    // provided branch borrows from env_config and the "python3" branches are
    // static — freeing either would be an invalid free.
    var fallback_python: []const u8 = undefined;
    var fallback_python_owned: ?[]const u8 = null;
    defer if (fallback_python_owned) |p| allocator.free(p);

    // When --python flag is used, try to get the default Python
    if (flags.use_default_python) {
        // Try to get the default Python path
        const default_python = @import("python.zig").getDefaultPythonPath(allocator) catch |err| {
            output.printError(allocator, "Failed to read default Python path with --python flag: {s}", .{@errorName(err)}) catch {};
            return error.MissingPythonExecutable;
        };

        if (default_python) |path| {
            defer allocator.free(path); // getDefaultPythonPath returns an owned copy
            // Build the full path to the Python binary
            const python_bin = try std.fs.path.join(allocator, &[_][]const u8{ path, "bin", "python3" });
            defer allocator.free(python_bin);
            fallback_python = try allocator.dupe(u8, python_bin);
            fallback_python_owned = fallback_python;
            try output.print(allocator, "Using default Python from ZENV_DIR/default-python: {s}", .{fallback_python});
        } else {
            output.printError(allocator, "--python flag specified but no default Python configured", .{}) catch {};
            output.printError(allocator, "Set a default Python first: zenv python use <version>", .{}) catch {};
            return error.MissingPythonExecutable;
        }
    } else {
        // Normal behavior without --python flag
        if (env_config.fallback_python) |py| {
            // Use the explicitly configured fallback Python (borrowed; do not free)
            fallback_python = py;
        } else {
            // Try to get the default Python path
            if (@import("python.zig").getDefaultPythonPath(allocator)) |default_python| {
                if (default_python) |path| {
                    defer allocator.free(path); // owned copy from getDefaultPythonPath
                    // Build the full path to the Python binary
                    const python_bin = try std.fs.path.join(allocator, &[_][]const u8{ path, "bin", "python3" });
                    defer allocator.free(python_bin);
                    fallback_python = try allocator.dupe(u8, python_bin);
                    fallback_python_owned = fallback_python;
                } else {
                    fallback_python = "python3"; // No default Python path found
                }
            } else |err| {
                try output.print(allocator, "Warning: Failed to get default Python path: {s}", .{@errorName(err)});
                fallback_python = "python3"; // Default to python3 if no default is configured
            }
        }
    }

    try replacements.put("FALLBACK_PYTHON", fallback_python);
    try replacements.put("REQUIREMENTS_PATH", req_abs_path);

    // Set modules_verified flag for the template
    try replacements.put("MODULES_VERIFIED_VALUE", if (modules_verified) "MODULES_VERIFIED=true" else "MODULES_VERIFIED=false");

    // Set force_deps flag for the template
    try replacements.put("FORCE_DEPS_VALUE", if (flags.force_deps) "FORCE_DEPS=true" else "FORCE_DEPS=false");

    // Set use_default_python flag for the template
    try replacements.put("USE_DEFAULT_PYTHON_VALUE", if (flags.use_default_python) "USE_DEFAULT_PYTHON=true" else "USE_DEFAULT_PYTHON=false");

    // Set dev_mode flag for the template
    try replacements.put("DEV_MODE_VALUE", if (flags.dev_mode) "DEV_MODE=true" else "DEV_MODE=false");

    // Set use_uv flag for the template
    try replacements.put("USE_UV_VALUE", if (flags.use_uv) "USE_UV=true" else "USE_UV=false");

    // Set no_cache flag for the template
    try replacements.put("NO_CACHE_VALUE", if (flags.no_cache) "NO_CACHE=true" else "NO_CACHE=false");

    // Module-environment cache placeholders. Only active when caching is enabled
    // AND the env actually declares modules (nothing to cache otherwise), matching
    // the activate-side gate in buildModuleSection.
    const module_cache_active = env_config.module_cache and env_config.modules.items.len > 0;
    try replacements.put("MODULE_CACHE_ENABLED_VALUE", if (module_cache_active) "MODULE_CACHE_ENABLED=true" else "MODULE_CACHE_ENABLED=false");

    const cache_version_str = try std.fmt.allocPrint(allocator, "{d}", .{template.MODULE_CACHE_VERSION});
    defer allocator.free(cache_version_str);
    try replacements.put("CACHE_VERSION", cache_version_str);

    const module_cache_file = try std.fs.path.join(allocator, &[_][]const u8{ venv_dir, template.MODULE_CACHE_FILE });
    defer allocator.free(module_cache_file);
    try replacements.put("MODULE_CACHE_FILE", module_cache_file);

    const module_cache_stamp = try std.fs.path.join(allocator, &[_][]const u8{ venv_dir, template.MODULE_CACHE_STAMP });
    defer allocator.free(module_cache_stamp);
    try replacements.put("MODULE_CACHE_STAMP", module_cache_stamp);

    // Generate the module loading block
    var module_loading_block = std.array_list.Managed(u8).init(allocator);
    defer module_loading_block.deinit();
    const module_writer = &module_loading_block;

    if (env_config.modules.items.len > 0) {
        if (env_config.modules_file) |modules_file| {
            try module_writer.print("echo 'Info: Loading required modules from file: {s}'\n", .{modules_file});
        } else {
            try module_writer.print("echo 'Info: Loading required modules'\n", .{});
        }
        try module_writer.print("echo 'Info: Loading {d} modules'\n", .{env_config.modules.items.len});
        for (env_config.modules.items, 0..) |module_name, idx| {
            // Module names come from zenv.json; escape them inside the quoted
            // shell strings so a stray quote can't break the generated script.
            try module_writer.print("echo '  - Module #{d}: \"", .{idx + 1});
            try template.appendSqEscaped(module_writer, module_name);
            try module_writer.appendSlice("\"'\n");
        }

        // The set +e and error checking are now in the template itself, based on modules_verified

        // Load each module
        for (env_config.modules.items) |module_name| {
            // Add debug information before loading
            try module_writer.appendSlice("info \"Attempting to load module: '");
            try template.appendSqEscaped(module_writer, module_name);
            try module_writer.appendSlice("'\"\n");

            if (modules_verified) {
                // Just load the module when pre-verified, we already checked they exist.
                // A failure still flips ZENV_MOD_OK so a half-loaded env is never cached.
                try module_writer.appendSlice("safe_module_load '");
                try template.appendSqEscaped(module_writer, module_name);
                try module_writer.appendSlice("' || ZENV_MOD_OK=0\n");
            } else {
                // Load with error handling when not pre-verified
                try module_writer.appendSlice("safe_module_load '");
                try template.appendSqEscaped(module_writer, module_name);
                try module_writer.appendSlice("' || { handle_module_error '");
                try template.appendSqEscaped(module_writer, module_name);
                try module_writer.appendSlice("'; ZENV_MOD_OK=0; }\n");
            }
        }
    } else {
        try module_writer.print("echo 'Info: No modules specified to load'\n", .{});
    }

    const module_loading_slice = try module_loading_block.toOwnedSlice();
    defer allocator.free(module_loading_slice);
    try replacements.put("MODULE_LOADING_BLOCK", module_loading_slice);

    // Generate custom setup commands block
    var custom_setup_commands_block = std.array_list.Managed(u8).init(allocator);
    defer custom_setup_commands_block.deinit();
    const custom_writer = &custom_setup_commands_block;

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
