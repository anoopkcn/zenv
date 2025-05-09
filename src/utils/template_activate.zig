const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const fs = std.fs;
const output = @import("output.zig");

const template = @import("template.zig");

// Embed the template file at compile time
const ACTIVATION_TEMPLATE = @embedFile("templates/activate.sh.template");

// Public function to export
pub fn createScriptFromTemplate(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
) !void {
    return createActivationScript(allocator, env_config, env_name, base_dir);
}

// Create activation script for the environment using templating
fn createActivationScript(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    base_dir: []const u8,
) !void {
    output.print("Creating activation script for '{s}'...", .{env_name}) catch {};

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);
    errdefer {
        _ = output.printError("Failed to get CWD realpath in createActivationScript", .{}) catch {};
    } // Add error context

    // Check if base_dir is absolute
    const is_absolute_base_dir = std.fs.path.isAbsolute(base_dir);

    // Generate the activation script path using base_dir
    var script_rel_path: []const u8 = undefined;
    var script_abs_path: []const u8 = undefined;

    if (is_absolute_base_dir) {
        // For absolute base_dir, paths are already absolute
        script_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "activate.sh" });
        script_abs_path = try allocator.dupe(u8, script_rel_path); // Use same path for both
    } else {
        // For relative base_dir, combine with cwd for absolute paths
        script_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "activate.sh" });
        script_abs_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, script_rel_path });
    }

    defer allocator.free(script_rel_path);
    defer allocator.free(script_abs_path);

    // Virtual environment absolute path
    var venv_path: []const u8 = undefined;

    if (is_absolute_base_dir) {
        // For absolute base_dir, simply join with env_name
        venv_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name });
    } else {
        // For relative base_dir, combine with cwd for absolute path
        venv_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, base_dir, env_name });
    }

    defer allocator.free(venv_path);

    // Create a map for template replacements
    var replacements = std.StringHashMap([]const u8).init(allocator);
    defer {
        // We'll handle freeing allocated values but not static strings
        replacements.deinit();
    }

    // Add basic replacements for the template
    try replacements.put("ENV_NAME", env_name);
    try replacements.put("VENV_PATH", venv_path);

    const zenv_env_dir_export_line = try std.fmt.allocPrint(allocator, "export ZENV_ENV_DIR={s}", .{venv_path});
    defer allocator.free(zenv_env_dir_export_line);
    try replacements.put("ZENV_ENV_DIR", zenv_env_dir_export_line);

    // Generate the module loading block
    var module_loading_block = std.ArrayList(u8).init(allocator);
    defer module_loading_block.deinit();
    const module_writer = module_loading_block.writer();

    // Add module loading logic
    if (env_config.modules.items.len > 0) {
        // Build the module list string for display
        var module_list_str = std.ArrayList(u8).init(allocator);
        defer module_list_str.deinit();
        for (env_config.modules.items, 0..) |module_name, idx| {
            if (idx > 0) try module_list_str.appendSlice(", ");
            try module_list_str.appendSlice(module_name);
        }

        try module_writer.print("echo 'Info: Loading modules - {s}'\n", .{module_list_str.items});

        for (env_config.modules.items) |module_name| {
            try module_writer.print("module load {s} || handle_module_error \"{s}\"\n", .{ module_name, module_name });
        }
    } else {
        try module_writer.print("echo 'Info: No modules specified to load'\n", .{});
    }

    const module_loading_slice = try module_loading_block.toOwnedSlice();
    defer allocator.free(module_loading_slice);
    try replacements.put("MODULE_LOADING_BLOCK", module_loading_slice);

    // Generate custom variable exports
    var custom_var_exports = std.ArrayList(u8).init(allocator);
    defer custom_var_exports.deinit();
    var custom_var_unset = std.ArrayList(u8).init(allocator);
    defer custom_var_unset.deinit();

    if (env_config.custom_activate_vars.count() > 0) {
        try custom_var_exports.writer().print("# Set custom environment variables\n", .{});
        try custom_var_unset.writer().print("  echo \"Unsetting custom variables...\"\n", .{});

        var vars_iter = env_config.custom_activate_vars.iterator();
        while (vars_iter.next()) |entry| {
            // Basic quoting for safety, assumes no complex shell injection needed
            try custom_var_exports.writer().print("export {s}='", .{entry.key_ptr.*});
            try template.escapeShellValue(entry.value_ptr.*, custom_var_exports.writer());
            try custom_var_exports.writer().print("'\n", .{});

            // Add to the unset commands
            try custom_var_unset.writer().print("  unset {s}\n", .{entry.key_ptr.*});
        }
        try custom_var_exports.writer().print("\n", .{});
    }

    // Get the owned slices for exports and unsets
    const exports_slice = try custom_var_exports.toOwnedSlice();
    defer allocator.free(exports_slice);
    const unset_slice = try custom_var_unset.toOwnedSlice();
    defer allocator.free(unset_slice);

    try replacements.put("CUSTOM_VAR_EXPORTS", exports_slice);
    try replacements.put("CUSTOM_VAR_UNSET", unset_slice);

    // Generate activate commands block
    var activate_commands_block = std.ArrayList(u8).init(allocator);
    defer activate_commands_block.deinit();

    if (env_config.activate_commands != null and env_config.activate_commands.?.items.len > 0) {
        try activate_commands_block.writer().print("# Run custom activation commands\n", .{});
        for (env_config.activate_commands.?.items) |cmd| {
            try activate_commands_block.writer().print("{s}\n", .{cmd});
        }
        try activate_commands_block.writer().print("\n", .{});
    }

    const activate_commands_slice = try activate_commands_block.toOwnedSlice();
    defer allocator.free(activate_commands_slice);
    try replacements.put("ACTIVATE_COMMANDS_BLOCK", activate_commands_slice);

    // Add optional description
    var description_text = std.ArrayList(u8).init(allocator);
    defer description_text.deinit();
    if (env_config.description) |desc| {
        try description_text.writer().print(": {s}", .{desc});
    }
    const desc_slice = try description_text.toOwnedSlice();
    defer allocator.free(desc_slice);
    try replacements.put("ENV_DESCRIPTION", desc_slice);

    // Process the template directly using the embedded template content
    const processed_content = try template.processTemplateString(allocator, ACTIVATION_TEMPLATE, replacements);
    defer allocator.free(processed_content);

    // Write the processed content to the file
    var file = if (is_absolute_base_dir)
        try std.fs.createFileAbsolute(script_rel_path, .{})
    else
        try fs.cwd().createFile(script_rel_path, .{});

    defer file.close();
    try file.writeAll(processed_content);

    // Make executable
    try file.chmod(0o755);

    output.print("Activation script created at {s}", .{script_abs_path}) catch {};
}
