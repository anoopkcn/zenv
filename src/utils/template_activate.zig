const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");

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
    const cwd_path = try runtime.cwdRealpath(allocator);
    defer allocator.free(cwd_path);

    // Check if base_dir is absolute
    const is_absolute_base_dir = std.fs.path.isAbsolute(base_dir);

    // Create scripts directory for hook scripts if needed
    const scripts_rel_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name, "scripts" });
    defer allocator.free(scripts_rel_path);

    // Create the scripts directory (idempotent, works for absolute and relative)
    runtime.makePath(scripts_rel_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            output.printError(allocator, "Failed to create scripts directory: {s}", .{@errorName(err)}) catch {};
            // Continue anyway, as this is not a critical error
        }
    };

    // Handle activation script copying if present
    var activate_hook_block = std.array_list.Managed(u8).init(allocator);
    defer activate_hook_block.deinit();
    var activate_hook_path: ?[]const u8 = null;
    defer if (activate_hook_path) |path| allocator.free(path);

    if (env_config.activate != null and env_config.activate.?.script != null) {
        const hook_path = env_config.activate.?.script.?;
        // Copy the script to the environment's scripts directory
        if (copyHookScript(allocator, hook_path, scripts_rel_path, "activate_hook.sh", is_absolute_base_dir, cwd_path)) |dest_path| {
            defer allocator.free(dest_path);
            activate_hook_path = try allocator.dupe(u8, dest_path);

            try activate_hook_block.print(
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
            try activate_hook_block.print(
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

    // Generate the module section: cache-aware replay, plain load, or a no-op.
    const module_section = try buildModuleSection(allocator, env_config.modules.items, env_config.module_cache, venv_path);
    defer allocator.free(module_section);
    try replacements.put("MODULE_SECTION", module_section);

    // Create empty placeholders for template compatibility
    const exports_slice = try allocator.dupe(u8, "");
    defer allocator.free(exports_slice);
    const unset_slice = try allocator.dupe(u8, "");
    defer allocator.free(unset_slice);

    try replacements.put("CUSTOM_VAR_EXPORTS", exports_slice);
    try replacements.put("CUSTOM_VAR_UNSET", unset_slice);

    // Generate activate commands block
    var activate_commands_block = std.array_list.Managed(u8).init(allocator);
    defer activate_commands_block.deinit();

    if (env_config.activate != null and env_config.activate.?.commands != null and env_config.activate.?.commands.?.items.len > 0) {
        try activate_commands_block.print("# Run custom activation commands\n", .{});
        for (env_config.activate.?.commands.?.items) |cmd| {
            try activate_commands_block.print("{s}\n", .{cmd});
        }
        try activate_commands_block.print("\n", .{});
    }

    const activate_commands_slice = try activate_commands_block.toOwnedSlice();
    defer allocator.free(activate_commands_slice);
    try replacements.put("ACTIVATE_COMMANDS_BLOCK", activate_commands_slice);

    // Add the hook script block to replacements
    const activate_hook_slice = try activate_hook_block.toOwnedSlice();
    defer allocator.free(activate_hook_slice);
    try replacements.put("ACTIVATE_HOOK_BLOCK", activate_hook_slice);

    // Add optional description
    var description_text = std.array_list.Managed(u8).init(allocator);
    defer description_text.deinit();
    if (env_config.description) |desc| {
        try description_text.print(": {s}", .{desc});
    }
    const desc_slice = try description_text.toOwnedSlice();
    defer allocator.free(desc_slice);
    try replacements.put("ENV_DESCRIPTION", desc_slice);

    const processed_content = try template.processTemplateString(allocator, ACTIVATION_TEMPLATE, replacements);
    defer allocator.free(processed_content);

    // Write the processed content to the file (executable)
    var file = try runtime.createFile(script_rel_path, .{ .permissions = .fromMode(0o755) });
    defer file.close(runtime.io);
    try file.writeStreamingAll(runtime.io, processed_content);

    output.print(allocator, "Activation script created at {s}", .{script_abs_path}) catch {};
}

// Appends `value` to `buf` as a shell single-quoted string body, escaping any
// embedded single quotes (the classic '\'' trick). Caller writes the wrapping
// quotes around the call.
fn appendSqEscaped(buf: *std.array_list.Managed(u8), value: []const u8) !void {
    for (value) |c| {
        if (c == '\'') {
            try buf.appendSlice("'\\''");
        } else {
            try buf.append(c);
        }
    }
}

// Writes the per-module load lines (header echoes + `safe_module_load` calls)
// shared by the no-cache path and the cache-miss fallback.
fn writeModuleLoadLines(buf: *std.array_list.Managed(u8), modules: []const []const u8) !void {
    try buf.print("echo 'Info: Loading {d} modules'\n", .{modules.len});
    for (modules, 0..) |module_name, idx| {
        try buf.print("echo '  - Module {d}: \"{s}\"'\n", .{ idx + 1, module_name });
    }
    for (modules) |module_name| {
        try buf.print("safe_module_load '{s}' || handle_module_error '{s}'\n", .{ module_name, module_name });
    }
}

/// Builds the `@@MODULE_SECTION@@` block for activate.sh. Three shapes:
///   - no modules: a no-op notice;
///   - modules without caching: the historical `module --force purge` + loads;
///   - modules with caching: source the captured module-env cache when the stamp
///     is fresh (version + `$SYSTEMNAME` match, not untrusted), else fall back to
///     a real `module load` and hint to re-run `zenv setup`.
/// The absolute venv path is baked in because `ZENV_ENV_DIR` is exported only
/// AFTER this block runs in activate.sh, so it is not yet available here.
/// Caller owns the returned slice.
fn buildModuleSection(
    allocator: Allocator,
    modules: []const []const u8,
    module_cache: bool,
    venv_path: []const u8,
) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    const w = &buf;

    if (modules.len == 0) {
        // Preserve the historical behavior: still purge on systems with Lmod.
        try w.print("if command -v module >/dev/null 2>&1; then\n", .{});
        try w.print("  module --force purge || echo \"WARNING: Failed to purge modules, continuing anyway\" >&2\n", .{});
        try w.print("  echo 'Info: No modules specified to load'\n", .{});
        try w.print("fi\n", .{});
        return buf.toOwnedSlice();
    }

    if (!module_cache) {
        try w.print("if command -v module >/dev/null 2>&1; then\n", .{});
        try w.print("  module --force purge || echo \"WARNING: Failed to purge modules, continuing anyway\" >&2\n", .{});
        try writeModuleLoadLines(w, modules);
        try w.print("fi\n", .{});
        return buf.toOwnedSlice();
    }

    // Cache-aware path. Bake absolute, shell-single-quoted cache paths.
    try w.print("if command -v module >/dev/null 2>&1; then\n", .{});

    try w.appendSlice("  __zenv_cache='");
    try appendSqEscaped(w, venv_path);
    try w.print("/{s}'\n", .{template.MODULE_CACHE_FILE});

    try w.appendSlice("  __zenv_stamp='");
    try appendSqEscaped(w, venv_path);
    try w.print("/{s}'\n", .{template.MODULE_CACHE_STAMP});

    try w.print("  __zenv_use_cache=0\n", .{});
    try w.print("  if [ -f \"$__zenv_cache\" ] && [ -f \"$__zenv_stamp\" ]; then\n", .{});
    try w.print("    __zenv_cv=$(sed -n 's/^version=//p' \"$__zenv_stamp\")\n", .{});
    try w.print("    __zenv_cs=$(sed -n 's/^system=//p' \"$__zenv_stamp\")\n", .{});
    try w.print("    __zenv_cu=$(sed -n 's/^untrusted=//p' \"$__zenv_stamp\")\n", .{});
    try w.print("    __zenv_cur=\"${{SYSTEMNAME:-$(hostname 2>/dev/null)}}\"\n", .{});
    try w.print("    if [ \"$__zenv_cv\" = \"{d}\" ] && [ \"$__zenv_cs\" = \"$__zenv_cur\" ] && [ \"$__zenv_cu\" != \"1\" ]; then\n", .{template.MODULE_CACHE_VERSION});
    try w.print("      __zenv_use_cache=1\n", .{});
    try w.print("    fi\n", .{});
    try w.print("  fi\n", .{});
    try w.print("  if [ \"$__zenv_use_cache\" = \"1\" ]; then\n", .{});
    try w.print("    . \"$__zenv_cache\"\n", .{});
    try w.print("  else\n", .{});
    try w.print("    module --force purge || echo \"WARNING: Failed to purge modules, continuing anyway\" >&2\n", .{});
    try writeModuleLoadLines(w, modules);
    try w.print("    if [ -f \"$__zenv_stamp\" ]; then echo \"INFO: zenv module cache unusable (system/version mismatch); ran 'module load'. Re-run 'zenv setup' on this system to refresh.\" >&2; fi\n", .{});
    try w.print("  fi\n", .{});
    try w.print("  unset __zenv_cache __zenv_stamp __zenv_use_cache __zenv_cv __zenv_cs __zenv_cu __zenv_cur\n", .{});
    try w.print("fi\n", .{});

    return buf.toOwnedSlice();
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
        runtime.access(resolved_hook_path) catch |err| {
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

    // Copy the script file (read whole source, write to an executable dest)
    const content = try runtime.readFileAlloc(allocator, resolved_hook_path, 10 * 1024 * 1024);
    defer allocator.free(content);

    var dest_file = try runtime.createFile(dest_path, .{ .permissions = .fromMode(0o755) });
    defer dest_file.close(runtime.io);
    try dest_file.writeStreamingAll(runtime.io, content);

    output.print(allocator, "Copied hook script from {s} to {s}", .{ resolved_hook_path, dest_path }) catch {};
    return dest_path;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null) catch |err| {
        std.debug.print("expected to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return err;
    };
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

test "buildModuleSection: no modules keeps historical purge, no cache machinery" {
    const a = std.testing.allocator;
    const out = try buildModuleSection(a, &[_][]const u8{}, true, "/venv/e");
    defer a.free(out);
    try expectContains(out, "No modules specified");
    try expectContains(out, "module --force purge"); // historical behavior preserved
    try expectNotContains(out, "__zenv_cache"); // but no cache when there are no modules
    try expectNotContains(out, "safe_module_load");
}

test "buildModuleSection: modules without cache uses plain purge+load" {
    const a = std.testing.allocator;
    const mods = [_][]const u8{ "gcc", "cuda" };
    const out = try buildModuleSection(a, &mods, false, "/venv/e");
    defer a.free(out);
    try expectContains(out, "if command -v module");
    try expectContains(out, "module --force purge");
    try expectContains(out, "safe_module_load 'gcc' || handle_module_error 'gcc'");
    try expectContains(out, "safe_module_load 'cuda' || handle_module_error 'cuda'");
    try expectNotContains(out, "__zenv_cache"); // no caching machinery
}

test "buildModuleSection: cache-aware replays when fresh, falls back otherwise" {
    const a = std.testing.allocator;
    const mods = [_][]const u8{"gcc"};
    const out = try buildModuleSection(a, &mods, true, "/venv/e");
    defer a.free(out);
    // Baked absolute cache paths.
    try expectContains(out, "__zenv_cache='/venv/e/.zenv_module_cache.sh'");
    try expectContains(out, "__zenv_stamp='/venv/e/.zenv_module_cache.stamp'");
    // Freshness gate: version + per-cluster system + untrusted.
    try expectContains(out, "${SYSTEMNAME:-$(hostname 2>/dev/null)}");
    try expectContains(out, "[ \"$__zenv_cv\" = \"1\" ]");
    try expectContains(out, "$__zenv_cu\" != \"1\"");
    // Fast path sources the cache.
    try expectContains(out, ". \"$__zenv_cache\"");
    // Fallback still runs the real load + hint.
    try expectContains(out, "module --force purge");
    try expectContains(out, "safe_module_load 'gcc' || handle_module_error 'gcc'");
    try expectContains(out, "Re-run 'zenv setup'");
}

test "buildModuleSection: venv path with a single quote is escaped" {
    const a = std.testing.allocator;
    const mods = [_][]const u8{"gcc"};
    const out = try buildModuleSection(a, &mods, true, "/ve'nv/e");
    defer a.free(out);
    // The embedded quote must be closed/escaped/reopened, not left raw.
    try expectContains(out, "__zenv_cache='/ve'\\''nv/e/.zenv_module_cache.sh'");
}
