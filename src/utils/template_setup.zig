const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const fs = std.fs;

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
    force_rebuild: bool,
    modules_verified: bool,
) ![]const u8 {
    return try createSetupScript(
        allocator,
        env_config,
        env_name,
        base_dir,
        req_abs_path,
        valid_deps_list_len,
        force_deps,
        force_rebuild,
        modules_verified,
    );
}

// Create setup script for the environment using templating
fn createSetupScript(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
    req_abs_path: []const u8,
    valid_deps_list_len: usize,
    force_deps: bool,
    force_rebuild: bool,
    modules_verified: bool,
) ![]const u8 {
    std.log.info("Creating setup script for '{s}'...", .{env_name});

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);

    // Check if base_dir is absolute
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
    if (env_config.fallback_python) |py| {
        // Use the explicitly configured fallback Python
        fallback_python = py;
    } else {
        // Try to get the default Python path
        if (@import("python.zig").getDefaultPythonPath(allocator)) |default_python| {
            if (default_python) |path| {
                // Build the full path to the Python binary
                const python_bin = try std.fs.path.join(allocator, &[_][]const u8{path, "bin", "python3"});
                defer allocator.free(python_bin);
                fallback_python = try allocator.dupe(u8, python_bin);
            } else {
                fallback_python = "python3"; // No default Python path found
            }
        } else |err| {
            std.log.warn("Failed to get default Python path: {s}", .{@errorName(err)});
            fallback_python = "python3"; // Default to python3 if no default is configured
        }
    }
    
    try replacements.put("FALLBACK_PYTHON", fallback_python);
    try replacements.put("ACTIVATE_SCRIPT_PATH", activate_script_path);
    try replacements.put("REQUIREMENTS_PATH", req_abs_path);

    // Set modules_verified flag for the template
    try replacements.put("MODULES_VERIFIED_VALUE", if (modules_verified) "MODULES_VERIFIED=true" else "MODULES_VERIFIED=false");

    // Set force_deps flag for the template
    try replacements.put("FORCE_DEPS_VALUE", if (force_deps) "FORCE_DEPS=true" else "FORCE_DEPS=false");
    
    // Set force_rebuild flag for the template
    try replacements.put("FORCE_REBUILD_VALUE", if (force_rebuild) "FORCE_REBUILD=true" else "FORCE_REBUILD=false");

    // Create the pip install command based on whether we have dependencies
    const pip_install_cmd = if (valid_deps_list_len > 0)
        try std.fmt.allocPrint(allocator, "python -m pip install -r {s}", .{req_abs_path})
    else
        "echo '==> No dependencies in requirements file to install.'";
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

        try module_writer.print("echo '==> Loading required modules'\n", .{});
        try module_writer.print("echo 'Loading modules: {s}'\n", .{module_list_str.items});

        // The set +e and error checking are now in the template itself, based on modules_verified

        // Load each module
        for (env_config.modules.items) |module_name| {
            if (modules_verified) {
                // Just load the module when pre-verified, we already checked they exist
                try module_writer.print("module load {s}\n", .{module_name});
            } else {
                // Load with error handling when not pre-verified
                try module_writer.print("module load {s} || handle_module_error \"{s}\"\n", .{ module_name, module_name });
            }
        }
    } else {
        try module_writer.print("echo '==> No modules specified to load'\n", .{});
    }

    const module_loading_slice = try module_loading_block.toOwnedSlice();
    defer allocator.free(module_loading_slice);
    try replacements.put("MODULE_LOADING_BLOCK", module_loading_slice);

    // Generate custom setup commands block
    var custom_setup_commands_block = std.ArrayList(u8).init(allocator);
    defer custom_setup_commands_block.deinit();
    const custom_writer = custom_setup_commands_block.writer();

    if (env_config.setup_commands != null and env_config.setup_commands.?.items.len > 0) {
        try custom_writer.print("echo '==> Step 5: Running custom setup commands'\n", .{});
        try custom_writer.print("# Activate again just in case custom commands need the venv\n", .{});
        try custom_writer.print("source {s}/bin/activate\n", .{venv_dir});
        for (env_config.setup_commands.?.items) |cmd| {
            try custom_writer.print("{s}\n", .{cmd});
        }
        try custom_writer.print("\n", .{});
    }

    const custom_commands_slice = try custom_setup_commands_block.toOwnedSlice();
    defer allocator.free(custom_commands_slice);
    try replacements.put("CUSTOM_SETUP_COMMANDS_BLOCK", custom_commands_slice);

    // Process the template
    const processed_content = try template.processTemplateString(allocator, SETUP_ENV_TEMPLATE, replacements);
    return processed_content;
}
