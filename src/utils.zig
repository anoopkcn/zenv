const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const fs = std.fs;

// Parse dependencies from pyproject.toml file
// Returns the number of dependencies found
pub fn parsePyprojectToml(allocator: Allocator, content: []const u8, deps_list: *std.ArrayList([]const u8)) !usize {
    std.log.info("Parsing pyproject.toml for dependencies...", .{});

    var count: usize = 0;
    var in_dependencies_section = false;
    var in_dependencies_array = false;
    var bracket_depth: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        // Check for the dependencies section in different possible formats
        if (!in_dependencies_section) {
            // Match [project.dependencies] or [tool.poetry.dependencies]
            if (std.mem.indexOf(u8, trimmed, "[project.dependencies]") != null or
                std.mem.indexOf(u8, trimmed, "[tool.poetry.dependencies]") != null)
            {
                std.log.info("Found project dependencies section", .{});
                in_dependencies_section = true;
                continue;
            }

            // Match dependencies = [ ... on a single line
            if (std.mem.indexOf(u8, trimmed, "dependencies") != null and
                std.mem.indexOf(u8, trimmed, "=") != null and
                std.mem.indexOf(u8, trimmed, "[") != null)
            {
                std.log.info("Found dependencies array declaration", .{});
                in_dependencies_section = true;
                in_dependencies_array = true;
                bracket_depth = 1;

                // If the line contains deps, process them
                const opening_bracket = std.mem.indexOf(u8, trimmed, "[") orelse continue;
                const line_after_bracket = trimmed[opening_bracket + 1 ..];
                try parseDependenciesLine(allocator, line_after_bracket, deps_list, &count);
                continue;
            }

            // If we see another section after looking for dependencies, we've gone too far
            if (std.mem.indexOf(u8, trimmed, "[") == 0 and
                std.mem.indexOf(u8, trimmed, "]") != null)
            {
                continue; // Skip to next section
            }
        }
        // Already in dependencies section
        else {
            // Check if we've hit a new section
            if (std.mem.indexOf(u8, trimmed, "[") == 0 and
                std.mem.indexOf(u8, trimmed, "]") != null)
            {
                std.log.info("End of dependencies section", .{});
                in_dependencies_section = false;
                in_dependencies_array = false;
                continue;
            }

            // If we're in a dependencies array, look for the array elements
            if (in_dependencies_array) {
                // Update bracket depth
                for (trimmed) |c| {
                    if (c == '[') bracket_depth += 1;
                    if (c == ']') {
                        bracket_depth -= 1;
                        if (bracket_depth == 0) {
                            in_dependencies_array = false;
                            break;
                        }
                    }
                }

                try parseDependenciesLine(allocator, trimmed, deps_list, &count);
            }
            // If we're in the dependencies section but haven't found the array yet
            else if (std.mem.indexOf(u8, trimmed, "dependencies") != null and
                std.mem.indexOf(u8, trimmed, "=") != null)
            {
                std.log.info("Found dependencies array", .{});
                in_dependencies_array = true;

                // Check if array starts on this line
                if (std.mem.indexOf(u8, trimmed, "[") != null) {
                    bracket_depth = 1;
                    const opening_bracket = std.mem.indexOf(u8, trimmed, "[") orelse continue;
                    const line_after_bracket = trimmed[opening_bracket + 1 ..];
                    try parseDependenciesLine(allocator, line_after_bracket, deps_list, &count);
                }
            }
            // If we're not in an array but in dependencies section, look for individual dependencies
            else if (std.mem.indexOf(u8, trimmed, "=") != null) {
                // This is for the format: package = "version" or package = {version="1.0"}
                var parts = std.mem.splitScalar(u8, trimmed, '=');
                if (parts.next()) |package_name| {
                    const package = std.mem.trim(u8, package_name, " \t\r");
                    if (package.len > 0) {
                        // Create a valid pip-style dependency (keep version specifiers)
                        const dep = try allocator.dupe(u8, package);
                        std.log.info("  - TOML individual dependency: {s}", .{dep});
                        try deps_list.append(dep);
                        count += 1;
                    }
                }
            }
        }
    }

    std.log.info("Found {d} dependencies in pyproject.toml", .{count});
    return count;
}

// Helper function to parse a line containing potential dependencies
fn parseDependenciesLine(allocator: Allocator, line: []const u8, deps_list: *std.ArrayList([]const u8), count: *usize) !void {
    // Handle quoted strings in arrays: "package1", "package2"
    var pos: usize = 0;
    while (pos < line.len) {
        // Find opening quote
        const quote_start = std.mem.indexOfPos(u8, line, pos, "\"") orelse
            std.mem.indexOfPos(u8, line, pos, "'") orelse
            break;
        const quote_char = line[quote_start];
        pos = quote_start + 1;

        // Find closing quote
        const quote_end = std.mem.indexOfPos(u8, line, pos, &[_]u8{quote_char}) orelse break;

        // Extract package name with version
        if (quote_end > pos) {
            const quoted_content = std.mem.trim(u8, line[pos..quote_end], " \t\r");
            if (quoted_content.len > 0) {
                // Keep the version specifier for pip compatibility
                const dep = try allocator.dupe(u8, quoted_content);
                std.log.info("  - TOML array dependency: {s}", .{dep});
                try deps_list.append(dep);
                count.* += 1;
            }
        }

        pos = quote_end + 1;
    }
}

// Create a virtual environment directory
pub fn createScVenvDir(allocator: Allocator, env_name: []const u8) !void {
    std.log.info("Creating virtual environment directory for '{s}'...", .{env_name});

    // Create base sc_venv directory if it doesn't exist
    try fs.cwd().makePath("sc_venv");

    // Create environment-specific directory
    const env_dir_path = try std.fmt.allocPrint(allocator, "sc_venv/{s}", .{env_name});
    defer allocator.free(env_dir_path);

    try fs.cwd().makePath(env_dir_path);
}

// Create activation script for the environment
pub fn createActivationScript(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8) !void {
    std.log.info("Creating activation script for '{s}'...", .{env_name});

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);

    // Generate the activation script with absolute path
    const script_rel_path = try std.fmt.allocPrint(allocator, "sc_venv/{s}/activate.sh", .{env_name});
    defer allocator.free(script_rel_path);

    const script_abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_path, script_rel_path });
    defer allocator.free(script_abs_path);

    var script_content = std.ArrayList(u8).init(allocator);
    defer script_content.deinit();

    try script_content.appendSlice("#!/bin/sh\n");
    try script_content.writer().print("\n# This script activates the '{s}' environment\n\n", .{env_name});

    // Module purge and loading
    try script_content.appendSlice("# Check if module command exists\n");
    try script_content.appendSlice("if command -v module >/dev/null 2>&1; then\n");
    try script_content.appendSlice("  # Unload all modules\n");
    try script_content.appendSlice("  module --force purge\n");

    if (env_config.modules.items.len > 0) {
        try script_content.appendSlice("  # Load required modules\n");
        try script_content.appendSlice("  echo 'Loading modules: ");
        for (env_config.modules.items, 0..) |module_name, idx| {
            if (idx > 0) {
                try script_content.appendSlice(", ");
            }
            try script_content.writer().print("{s}", .{module_name});
        }
        try script_content.appendSlice("'\n");

        for (env_config.modules.items) |module_name| {
            try script_content.writer().print("  module load {s}\n", .{module_name});
        }
    } else {
        try script_content.appendSlice("  echo 'No modules to load'\n");
    }
    try script_content.appendSlice("else\n");
    try script_content.appendSlice("  echo '==> Module command not found, skipping module operations'\n");
    try script_content.appendSlice("fi\n\n");

    // Virtual environment activation with absolute path
    try script_content.appendSlice("# Activate the Python virtual environment\n");
    const venv_path = try std.fmt.allocPrint(allocator, "{s}/sc_venv/{s}/venv", .{ cwd_path, env_name });
    defer allocator.free(venv_path);
    try script_content.writer().print("source {s}/bin/activate\n\n", .{venv_path});

    // Custom environment variables
    if (env_config.custom_activate_vars.count() > 0) {
        try script_content.appendSlice("# Set custom environment variables\n");
        var vars_iter = env_config.custom_activate_vars.iterator();
        while (vars_iter.next()) |entry| {
            try script_content.writer().print("export {s}=\"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try script_content.appendSlice("\n");
    }

    // Print success message
    if (env_config.description) |desc| {
        try script_content.writer().print("echo \"Environment '{s}' activated: {s}\"\n", .{ env_name, desc });
    } else {
        try script_content.writer().print("echo \"Environment '{s}' activated\"\n", .{env_name});
    }

    // Create a function to deactivate
    try script_content.appendSlice("\n# Add deactivate_all function to completely deactivate\n");
    try script_content.appendSlice("deactivate_all() {\n");
    try script_content.appendSlice("  # First run Python's deactivate\n");
    try script_content.appendSlice("  deactivate\n");
    try script_content.appendSlice("  # Then unset any custom environment variables\n");
    var vars_iter = env_config.custom_activate_vars.iterator();
    while (vars_iter.next()) |entry| {
        try script_content.writer().print("  unset {s}\n", .{entry.key_ptr.*});
    }
    try script_content.appendSlice("  # Unset this function\n");
    try script_content.appendSlice("  unset -f deactivate_all\n");
    try script_content.appendSlice("  echo \"Environment fully deactivated\"\n");
    try script_content.appendSlice("}\n");

    // Write script to file using relative path (it's created in the current directory context)
    var script_file = try fs.cwd().createFile(script_rel_path, .{});
    defer script_file.close();
    try script_file.writeAll(script_content.items);
    try script_file.chmod(0o755); // Make executable

    std.log.info("Activation script created at {s}", .{script_abs_path});
}

// Get and validate environment configuration
pub fn getAndValidateEnvironment(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) ?*const EnvironmentConfig {
    if (args.len < 3) {
        std.log.err("Missing environment name argument for command '{s}'", .{args[1]});
        handleErrorFn(ZenvError.EnvironmentNotFound); // Or a new error like MissingArgument
        return null;
    }
    const env_name = args[2];

    const env_config = config.getEnvironment(env_name) orelse {
        std.log.err("Environment '{s}' not found in configuration.", .{env_name});
        handleErrorFn(ZenvError.EnvironmentNotFound);
        return null;
    };

    // *** Crucial Validation ***
    var hostname: []const u8 = undefined;
    hostname = config_module.ZenvConfig.getHostname(allocator) catch |err| {
        handleErrorFn(err);
        return null;
    };
    defer allocator.free(hostname); // Free hostname obtained from getHostname

    // Check for hostname matching with improved logic
    std.log.debug("Comparing hostname '{s}' with target machine '{s}'", .{ hostname, env_config.target_machine });

    // Enhanced hostname matching to handle different patterns
    const hostname_matches = blk: {
        // Check if hostname ends with ".target_machine" (domain-style matching)
        const target = env_config.target_machine;
        const domain_check = std.mem.concat(allocator, u8, &[_][]const u8{ ".", target }) catch {
            // If concat fails, just do simple substring check
            break :blk std.mem.indexOf(u8, hostname, target) != null;
        };
        defer allocator.free(domain_check);

        // Try exact match first
        if (std.mem.eql(u8, hostname, target)) {
            break :blk true;
        }

        // Try domain suffix match (e.g. hostname ends with ".jureca")
        if (hostname.len >= domain_check.len) {
            const suffix = hostname[hostname.len - domain_check.len ..];
            if (std.mem.eql(u8, suffix, domain_check)) {
                break :blk true;
            }
        }

        // Fallback to substring match
        break :blk std.mem.indexOf(u8, hostname, target) != null;
    };

    if (!hostname_matches) {
        std.log.err("Current machine ('{s}') does not match target machine ('{s}') specified for environment '{s}'.", .{
            hostname,
            env_config.target_machine,
            env_name,
        });
        // Maybe add a new error ZenvError.TargetMachineMismatch
        handleErrorFn(ZenvError.ClusterNotFound); // Re-using for now
        return null;
    }

    return env_config;
}
