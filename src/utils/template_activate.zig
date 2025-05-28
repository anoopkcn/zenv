const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const fs = std.fs;
const output = @import("output.zig");

const template = @import("template.zig");

// Embed the template file at compile time
const ACTIVATION_TEMPLATE = @embedFile("templates/activate.template");

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
    output.print(allocator, "Creating activation script for '{s}'...", .{env_name}) catch {};

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);
    errdefer {
        _ = output.printError(allocator, "Failed to get CWD realpath in createActivationScript", .{}) catch {};
    } // Add error context

    // Check if base_dir is absolute
    const is_absolute_base_dir = std.fs.path.isAbsolute(base_dir);

    // Create scripts directory for hook scripts if needed
    var scripts_rel_path: []const u8 = undefined;
    if (is_absolute_base_dir) {
        scripts_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "scripts" });
    } else {
        scripts_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "scripts" });
    }
    defer allocator.free(scripts_rel_path);

    // Create the scripts directory
    if (is_absolute_base_dir) {
        std.fs.makeDirAbsolute(scripts_rel_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                output.printError(allocator, "Failed to create scripts directory: {s}", .{@errorName(err)}) catch {};
                // Continue anyway, as this is not a critical error
            }
        };
    } else {
        fs.cwd().makePath(scripts_rel_path) catch |err| {
            output.printError(allocator, "Failed to create scripts directory: {s}", .{@errorName(err)}) catch {};
            // Continue anyway, as this is not a critical error
        };
    }

    // Handle activation script copying if present
    var activate_hook_block = std.ArrayList(u8).init(allocator);
    defer activate_hook_block.deinit();
    var activate_hook_path: ?[]const u8 = null;
    defer if (activate_hook_path) |path| allocator.free(path);

    if (env_config.activate != null and env_config.activate.?.script != null) {
        const hook_path = env_config.activate.?.script.?;
        // Copy the script to the environment's scripts directory
        if (copyHookScript(allocator, hook_path, scripts_rel_path, "activate_hook.sh", is_absolute_base_dir, cwd_path)) |dest_path| {
            defer allocator.free(dest_path);
            activate_hook_path = try allocator.dupe(u8, dest_path);

            try activate_hook_block.writer().print(
                \\
                \\if [ -f "{s}" ]; then
                \\  source "{s}" || echo "Warning: Activation script failed with exit code $?"
                \\else
                \\  echo "Warning: Activation script not found at {s}"
                \\fi
                \\
            , .{ dest_path, dest_path, dest_path });
        } else |err| {
            output.printError(allocator, "Failed to copy activation script: {s}", .{@errorName(err)}) catch {};
            // Continue anyway, but add a warning in the script
            try activate_hook_block.writer().print(
                \\
                \\echo "Warning: Failed to copy activation script from '{s}'"
                \\
            , .{hook_path});
        }
    }

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

        try module_writer.print("echo 'Info: Loading {d} modules:'\n", .{env_config.modules.items.len});
        // for (env_config.modules.items, 0..) |module_name, idx| {
        //     try module_writer.print("echo '  - Module #{d}: \"{s}\"'\n", .{idx + 1, module_name});
        // }

        for (env_config.modules.items) |module_name| {
            // try module_writer.print("echo \"Info: Attempting to load module: '{s}'\"\n", .{module_name});
            try module_writer.print("safe_module_load '{s}' || handle_module_error '{s}'\n", .{ module_name, module_name });
        }
    } else {
        try module_writer.print("echo 'Info: No modules specified to load'\n", .{});
    }

    const module_loading_slice = try module_loading_block.toOwnedSlice();
    defer allocator.free(module_loading_slice);
    try replacements.put("MODULE_LOADING_BLOCK", module_loading_slice);

    // Create empty placeholders for template compatibility
    const exports_slice = try allocator.dupe(u8, "");
    defer allocator.free(exports_slice);
    const unset_slice = try allocator.dupe(u8, "");
    defer allocator.free(unset_slice);

    try replacements.put("CUSTOM_VAR_EXPORTS", exports_slice);
    try replacements.put("CUSTOM_VAR_UNSET", unset_slice);

    // Generate activate commands block
    var activate_commands_block = std.ArrayList(u8).init(allocator);
    defer activate_commands_block.deinit();

    if (env_config.activate != null and env_config.activate.?.commands != null and env_config.activate.?.commands.?.items.len > 0) {
        try activate_commands_block.writer().print("# Run custom activation commands\n", .{});
        for (env_config.activate.?.commands.?.items) |cmd| {
            try activate_commands_block.writer().print("{s}\n", .{cmd});
        }
        try activate_commands_block.writer().print("\n", .{});
    }

    const activate_commands_slice = try activate_commands_block.toOwnedSlice();
    defer allocator.free(activate_commands_slice);
    try replacements.put("ACTIVATE_COMMANDS_BLOCK", activate_commands_slice);

    // Add the hook script block to replacements
    const activate_hook_slice = try activate_hook_block.toOwnedSlice();
    defer allocator.free(activate_hook_slice);
    try replacements.put("ACTIVATE_HOOK_BLOCK", activate_hook_slice);

    // Add optional description
    var description_text = std.ArrayList(u8).init(allocator);
    defer description_text.deinit();
    if (env_config.description) |desc| {
        try description_text.writer().print(": {s}", .{desc});
    }
    const desc_slice = try description_text.toOwnedSlice();
    defer allocator.free(desc_slice);
    try replacements.put("ENV_DESCRIPTION", desc_slice);

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

    output.print(allocator, "Activation script created at {s}", .{script_abs_path}) catch {};
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
    // Determine if the hook_path is absolute or relative
    const resolved_hook_path = if (std.fs.path.isAbsolute(hook_path))
        hook_path
    else
        try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, hook_path });

    defer if (!std.fs.path.isAbsolute(hook_path)) allocator.free(resolved_hook_path);

    output.print(allocator, "Looking for hook script at: {s}", .{resolved_hook_path}) catch {};

    // Check if hook script exists
    const source_exists = blk: {
        fs.cwd().access(resolved_hook_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                output.printError(allocator, "Hook script not found: {s}", .{resolved_hook_path}) catch {};
                return err;
            }
            output.printError(allocator, "Error accessing hook script {s}: {s}", .{ resolved_hook_path, @errorName(err) }) catch {};
            return err;
        };
        break :blk true;
    };

    if (!source_exists) {
        return error.FileNotFound;
    }

    // Construct destination path
    var dest_path: []const u8 = undefined;
    if (is_absolute_base_dir) {
        dest_path = try std.fs.path.join(allocator, &[_][]const u8{ scripts_dir, dest_filename });
    } else {
        dest_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, scripts_dir, dest_filename });
    }
    errdefer allocator.free(dest_path);

    // Copy the script file
    var source_file = try fs.cwd().openFile(resolved_hook_path, .{});
    defer source_file.close();

    var dest_file = if (is_absolute_base_dir)
        try std.fs.createFileAbsolute(dest_path, .{})
    else
        try fs.cwd().createFile(dest_path, .{});
    defer dest_file.close();

    // Copy the content
    var buffer: [8192]u8 = undefined;
    var bytes_read: usize = 0;
    while (true) {
        bytes_read = try source_file.read(&buffer);
        if (bytes_read == 0) break;
        try dest_file.writeAll(buffer[0..bytes_read]);
    }

    // Make the destination file executable
    try dest_file.chmod(0o755);

    output.print(allocator, "Copied hook script from {s} to {s}", .{ resolved_hook_path, dest_path }) catch {};
    return dest_path;
}
