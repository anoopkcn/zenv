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
pub fn createSetupScriptFromTemplate(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8, base_dir: []const u8, req_abs_path: []const u8, valid_deps_list_len: usize, force_deps: bool) ![]const u8 {
    return try createSetupScript(allocator, env_config, env_name, base_dir, req_abs_path, valid_deps_list_len, force_deps);
}

// Create setup script for the environment using templating
fn createSetupScript(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8, base_dir: []const u8, req_abs_path: []const u8, valid_deps_list_len: usize, force_deps: bool) ![]const u8 {
    std.log.info("Creating setup script for '{s}'...", .{env_name});

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);

    // Virtual environment absolute path
    const venv_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, base_dir, env_name });
    defer allocator.free(venv_dir);

    // Activation script path
    const activate_script_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, base_dir, env_name, "activate.sh" });
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
    try replacements.put("PYTHON_EXECUTABLE", env_config.python_executable);
    try replacements.put("ACTIVATE_SCRIPT_PATH", activate_script_path);
    try replacements.put("REQUIREMENTS_PATH", req_abs_path);

    // Set force_deps flag for the template
    try replacements.put("FORCE_DEPS_VALUE", if (force_deps) "FORCE_DEPS=true" else "FORCE_DEPS=false");

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
        try module_writer.print("# Don't exit immediately on module load errors\n", .{});
        try module_writer.print("set +e\n", .{});

        // Load each module with error checking
        for (env_config.modules.items) |module_name| {
            try module_writer.print("module load {s} || handle_module_error \"{s}\"\n", .{ module_name, module_name });
        }

        try module_writer.print("set -e # Restore error handling\n", .{});
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
