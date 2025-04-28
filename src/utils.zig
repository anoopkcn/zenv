const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const fs = std.fs;
const process = std.process;
const StringHashMap = std.StringHashMap;


// ============================================================================
// Dependency Parsing Utilities
// ============================================================================

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

// Helper function to parse a line containing potential dependencies (used by parsePyprojectToml)
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

// Parse dependencies from requirements.txt format content
// Returns the number of dependencies found
pub fn parseRequirementsTxt(allocator: Allocator, content: []const u8, deps_list: *std.ArrayList([]const u8)) !usize {
    std.log.info("Parsing requirements.txt for dependencies...", .{});
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
            // Skip empty lines and comments
            std.log.debug("Skipping comment or empty line: '{s}'", .{trimmed_line});
            continue;
        }

        // Log each dependency being added
        std.log.info("  - Requirements file dependency: {s}", .{trimmed_line});

        // Create a duplicate of the trimmed line to ensure it persists
        const trimmed_dupe = try allocator.dupe(u8, trimmed_line);
        errdefer allocator.free(trimmed_dupe);

        // Add the dependency
        try deps_list.append(trimmed_dupe);
        count += 1;
    }
    std.log.info("Found {d} dependencies in requirements.txt format", .{count});
    return count;
}

// Validate raw dependencies, remove duplicates and invalid entries
pub fn validateDependencies(allocator: Allocator, raw_deps: []const []const u8, env_name: []const u8) !std.ArrayList([]const u8) {
    std.log.info("Validating dependencies for '{s}':", .{env_name});
    var valid_deps = std.ArrayList([]const u8).init(allocator);
    errdefer valid_deps.deinit(); // Clean up if an error occurs during allocation

    // Create a hashmap to track seen package names (case-insensitive) with owned keys
    var seen_packages = std.StringHashMap(void).init(allocator);
    defer {
        // Free all the keys we've stored
        var keys_iter = seen_packages.keyIterator();
        while (keys_iter.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        seen_packages.deinit();
    }

    for (raw_deps) |dep| {
        if (dep.len == 0) {
            std.log.warn("Skipping empty dependency", .{});
            continue;
        }

        // Skip deps that look like file paths
        if (std.mem.indexOf(u8, dep, "/") != null) {
            std.log.warn("Skipping dependency that looks like a path: '{s}'", .{dep});
            continue;
        }

        // Skip deps without a valid package name (only allow common Python package name chars)
        var valid = true;
        var has_alpha = false;
        for (dep) |c| {
            // Allow alphanumeric, hyphen, underscore, dot, and comparison operators/brackets
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                has_alpha = true;
            } else if (!((c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or
                c == '>' or c == '<' or c == '=' or c == '~' or c == ' ' or c == '[' or c == ']'))
            {
                valid = false;
                break;
            }
        }

        if (!valid or !has_alpha) {
            std.log.warn("Skipping invalid dependency: '{s}'", .{dep});
            continue;
        }

        // Extract the package name to check for duplicates (case-insensitive check)
        var package_name_raw: []const u8 = undefined;
        if (std.mem.indexOfAny(u8, dep, "<>=~")) |op_idx| {
            package_name_raw = std.mem.trim(u8, dep[0..op_idx], " ");
        } else if (std.mem.indexOfScalar(u8, dep, '[')) |bracket_idx| {
            package_name_raw = std.mem.trim(u8, dep[0..bracket_idx], " ");
        } else {
            // Just the package name without version
            package_name_raw = std.mem.trim(u8, dep, " ");
        }

        // Convert package name to lowercase for case-insensitive duplicate check
        const package_name_lower = blk: {
            const lowercase_buffer = allocator.alloc(u8, package_name_raw.len) catch {
                std.log.err("Failed to allocate memory for lowercase conversion", .{});
                // If allocation fails, use the original name
                break :blk package_name_raw;
            };
            defer allocator.free(lowercase_buffer);

            // Create a persistent copy that won't be freed until the end of the function
            const result = allocator.dupe(u8, std.ascii.lowerString(lowercase_buffer, package_name_raw)) catch {
                // If duplication fails, use the original name
                break :blk package_name_raw;
            };

            break :blk result;
        };
        defer if (!std.mem.eql(u8, package_name_lower, package_name_raw)) allocator.free(package_name_lower);

        // Check if we've already seen this package (case-insensitive)
        if (seen_packages.contains(package_name_lower)) {
            std.log.warn("Skipping duplicate package '{s}' (already included in dependencies)", .{dep});
            continue;
        }

        // Accept this dependency as valid
        std.log.info("Including dependency: '{s}'", .{dep});
        try valid_deps.append(dep); // Append the original dependency string
        try seen_packages.put(package_name_lower, {});
    }

    return valid_deps;
}

// ============================================================================
// Filesystem and Directory Utilities
// ============================================================================

// Create a virtual environment directory structure (zenv/env_name)
pub fn createVenvDir(allocator: Allocator, env_name: []const u8) !void {
    std.log.info("Creating virtual environment directory structure for '{s}'...", .{env_name});

    // Create base zenv directory if it doesn't exist
    try fs.cwd().makePath("zenv");

    // Create environment-specific directory
    const env_dir_path = try std.fmt.allocPrint(allocator, "zenv/{s}", .{env_name});
    defer allocator.free(env_dir_path);

    try fs.cwd().makePath(env_dir_path);
}

// ============================================================================
// Shell Script Generation Utilities
// ============================================================================

// Generates the standard header for shell scripts
fn generateShellScriptHeader(writer: anytype, env_name: []const u8, script_purpose: []const u8) !void {
    if (std.mem.eql(u8, script_purpose, "Setup")) {
        // For setup scripts, exit on error
        try writer.print(
            \\#!/bin/sh
            \\set -e # Exit on error for setup scripts
            \\
            \\# {s} script for '{s}' environment generated by zenv
            \\
        , .{ script_purpose, env_name });
    } else {
        // For activation scripts, don't exit on error
        try writer.print(
            \\#!/bin/sh
            \\# {s} script for '{s}' environment generated by zenv
            \\
        , .{ script_purpose, env_name });
    }
}

// Appends module purge, load, and check commands to a script buffer
fn appendModuleCommandsToScript(
    writer: anytype, // Use a writer directly
    allocator: Allocator, // Needed for temporary module list string
    env_config: *const EnvironmentConfig,
    include_package_check: bool, // Flag to include python package detection
) !void {
    // Use multi-line string for the initial block
    try writer.print(
        \\# Check if module command exists
        \\if command -v module >/dev/null 2>&1; then
        \\  echo '==> Purging all modules'
        \\  module --force purge
        \\
    , .{});

    if (env_config.modules.items.len > 0) {
        // Build the module list string separately for clarity
        var module_list_str = std.ArrayList(u8).init(allocator);
        defer module_list_str.deinit();
        for (env_config.modules.items, 0..) |module_name, idx| {
            if (idx > 0) try module_list_str.appendSlice(", ");
            try module_list_str.appendSlice(module_name);
        }

        try writer.print("  echo '==> Loading required modules'\n", .{});
        try writer.print("  echo 'Loading modules: {s}'\n", .{module_list_str.items});

        // Use set +e to prevent script from exiting on module load error
        try writer.print("  # Don't exit immediately on module load errors so we can intercept and handle them\n", .{});
        try writer.print("  set +e\n", .{});
        
        // Load each module with error checking
        for (env_config.modules.items) |module_name| {
            try writer.print(
                \\  module load {s}
                \\  if [ $? -ne 0 ]; then
                \\    echo "Error: Failed to load module '{s}'"
                \\    exit 1
                \\  fi
                \\
            , .{module_name, module_name});
        }
        
        // Restore error exit mode
        try writer.print("  set -e\n", .{});
    } else {
        try writer.print("  echo '==> No modules specified to load'\n", .{});
    }

    // Optionally add code to detect packages provided by modules (for setup script)
    if (include_package_check) {
        try writer.print(
            \\  echo '==> Checking Python packages provided by modules'
            \\  MODULE_PACKAGES_FILE=$(mktemp)
            \\  # Try python3 first, then python if python3 fails
            \\  (python3 -m pip list --format=freeze > "$MODULE_PACKAGES_FILE" 2>/dev/null || python -m pip list --format=freeze > "$MODULE_PACKAGES_FILE" 2>/dev/null) || true
            \\  if [ -s "$MODULE_PACKAGES_FILE" ]; then
            \\    echo '==> Found packages from modules:'
            \\    echo -n '    '
            \\    # Extract just package names, sort, join with comma-space
            \\    cat "$MODULE_PACKAGES_FILE" | sed -E 's/==.*//;s/ .*//' | sort | tr '\n' ',' | sed 's/,/, /g' | sed 's/, $//'
            \\    echo ''
            \\  else
            \\    echo '==> No Python packages detected from modules'
            \\    # Ensure the file exists even if empty for later steps
            \\    touch "$MODULE_PACKAGES_FILE"
            \\  fi
            \\
        , .{});
    }

    try writer.print("else\n", .{});
    try writer.print("  echo '==> Module command not found, skipping module operations'\n", .{});

    if (include_package_check) {
        try writer.print("  MODULE_PACKAGES_FILE=$(mktemp) # Create empty temp file\n", .{});
    }
    try writer.print("fi\n\n", .{});
}

// Create activation script for the environment
pub fn createActivationScript(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8) !void {
    std.log.info("Creating activation script for '{s}'...", .{env_name});

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);

    // Generate the activation script path
    const script_rel_path = try std.fmt.allocPrint(allocator, "zenv/{s}/activate.sh", .{env_name});
    defer allocator.free(script_rel_path);
    const script_abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_path, script_rel_path });
    defer allocator.free(script_abs_path);

    // Use a memory buffer for all content before writing to disk
    var content_buffer = std.ArrayList(u8).init(allocator);
    defer content_buffer.deinit();
    const writer = content_buffer.writer();

    // Add standard header (no set -e for activation)
    try writer.print(
        \\#!/bin/sh
        \\
        \\# Activation script for '{s}' environment generated by zenv
        \\
        \\# Define a function to handle errors
        \\handle_module_error() {{
        \\  echo "Error: Failed to load module '$1'" >&2
        \\  echo "Environment activation may be incomplete" >&2
        \\  return 1
        \\}}
        \\
    , .{env_name});

    // Add modified module purge and loading commands for activation scripts
    try writer.print(
        \\# Check if module command exists
        \\if command -v module >/dev/null 2>&1; then
        \\  echo '==> Purging all modules'
        \\  module --force purge || echo "Warning: Failed to purge modules, continuing anyway" >&2
        \\
    , .{});

    if (env_config.modules.items.len > 0) {
        // Build the module list string for display
        var module_list_str = std.ArrayList(u8).init(allocator);
        defer module_list_str.deinit();
        for (env_config.modules.items, 0..) |module_name, idx| {
            if (idx > 0) try module_list_str.appendSlice(", ");
            try module_list_str.appendSlice(module_name);
        }

        try writer.print("  echo '==> Loading required modules'\n", .{});
        try writer.print("  echo 'Loading modules: {s}'\n", .{module_list_str.items});

        for (env_config.modules.items) |module_name| {
            try writer.print("  module load {s} || handle_module_error \"{s}\"\n", .{ module_name, module_name });
        }
    } else {
        try writer.print("  echo '==> No modules specified to load'\n", .{});
    }
    try writer.print("else\n", .{});
    try writer.print("  echo '==> Module command not found, skipping module operations'\n", .{});
    try writer.print("fi\n\n", .{});

    // Virtual environment activation with absolute path
    const venv_path = try std.fmt.allocPrint(allocator, "{s}/zenv/{s}", .{ cwd_path, env_name });
    defer allocator.free(venv_path);
    try writer.print(
        \\# Activate the Python virtual environment
        \\source {s}/bin/activate
        \\
    , .{venv_path});

    // Custom environment variables
    if (env_config.custom_activate_vars.count() > 0) {
        try writer.print("# Set custom environment variables\n", .{});
        var vars_iter = env_config.custom_activate_vars.iterator();
        while (vars_iter.next()) |entry| {
            // Basic quoting for safety, assumes no complex shell injection needed
            try writer.print("export {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try writer.print("\n", .{});
    }

    // Print success message
    if (env_config.description) |desc| {
        try writer.print("echo \"Environment '{s}' activated: {s}\"\n", .{ env_name, desc });
    } else {
        try writer.print("echo \"Environment '{s}' activated\"\n", .{env_name});
    }

    // Create a function to deactivate
    try writer.print(
        \\
        \\# Add deactivate_all function to completely deactivate
        \\deactivate_all() {{
        \\  # Check if deactivate function exists (from venv)
        \\  if command -v deactivate >/dev/null 2>&1; then
        \\    echo "Running venv deactivate..."
        \\    deactivate
        \\  fi
        \\  # Then unset any custom environment variables
    , .{});
    if (env_config.custom_activate_vars.count() > 0) {
        try writer.print("  echo \"Unsetting custom variables...\"\n", .{});
        var vars_iter_unset = env_config.custom_activate_vars.iterator();
        while (vars_iter_unset.next()) |entry| {
            try writer.print("  unset {s}\n", .{entry.key_ptr.*});
        }
    }
    try writer.print(
        \\  # Unset this function
        \\  unset -f deactivate_all
        \\  echo "Environment fully deactivated"
        \\}}
        \\
    , .{});

    // Now write the entire content in one operation
    var file = try fs.cwd().createFile(script_rel_path, .{});
    defer file.close();
    try file.writeAll(content_buffer.items);

    // Make executable
    try file.chmod(0o755);

    std.log.info("Activation script created at {s}", .{script_abs_path});
}

// ============================================================================
// Shell Script Execution Utilities
// ============================================================================

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
            
            debug_file.writeAll(script_content_debug) catch {};
            std.log.debug("Script content written to debug log: {s}", .{debug_log_path});
        }

        // Check if this is a module load failure by reading the script content
        // This is a heuristic but should work for our use case
        const script_content = fs.cwd().readFileAlloc(allocator, script_rel_path, 1024 * 1024) catch |read_err| {
            std.log.err("Failed to read script content: {s}", .{@errorName(read_err)});
            return error.ProcessError;
        };
        defer allocator.free(script_content);
        
        // Check if this script contains module load commands
        if (std.mem.indexOf(u8, script_content, "module load") != null) {
            return error.ModuleLoadError;
        }

        return error.ProcessError;
    }

    std.log.info("Script completed successfully: {s}", .{script_abs_path});
}

// ============================================================================
// Environment Setup Logic (Moved from commands.zig)
// ============================================================================

// Sets up the full environment: creates files, generates and runs setup script.
pub fn setupEnvironment(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8, deps: []const []const u8, force_deps: bool) !void {
    std.log.info("Setting up environment '{s}'...", .{env_name});

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);

    // Validate dependencies first
    var valid_deps_list = try validateDependencies(allocator, deps, env_name);
    defer valid_deps_list.deinit(); // Deinit the list itself

    // Create requirements file path
    const req_rel_path = try std.fmt.allocPrint(allocator, "zenv/{s}/requirements.txt", .{env_name});
    defer allocator.free(req_rel_path);
    const req_abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_path, req_rel_path });
    defer allocator.free(req_abs_path);

    // Write the validated dependencies to the requirements file
    std.log.info("Writing {d} validated dependencies to {s}", .{ valid_deps_list.items.len, req_rel_path });
    { // Scope for file handling
        var req_file = try fs.cwd().createFile(req_rel_path, .{});
        defer req_file.close();
        var bw = std.io.bufferedWriter(req_file.writer()); // Use buffered writer
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
        try bw.flush(); // Ensure content is written
    } // req_file is closed here
    std.log.info("Created requirements file: {s}", .{req_abs_path});

    // Generate setup script path
    const script_rel_path = try std.fmt.allocPrint(allocator, "zenv/{s}/setup_env.sh", .{env_name});
    defer allocator.free(script_rel_path);
    const script_abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_path, script_rel_path });
    defer allocator.free(script_abs_path);

    // Write setup script to file
    std.log.info("Writing setup script to {s}", .{script_rel_path});
    { // Scope for file write
        var script_file = try fs.cwd().createFile(script_rel_path, .{});
        defer script_file.close();
        var bw = std.io.bufferedWriter(script_file.writer()); // Use buffered writer
        const writer = bw.writer();

        // 1. Script header
        try generateShellScriptHeader(writer, env_name, "Setup");

        // 2. Module commands (purge, load, check provided packages)
        try appendModuleCommandsToScript(writer, allocator, env_config, true);

        // 3. Create virtual environment
        const venv_dir = try std.fmt.allocPrint(allocator, "{s}/zenv/{s}", .{ cwd_path, env_name });
        defer allocator.free(venv_dir);
        try writer.print(
            \\echo '==> Step 3: Creating Python virtual environment'
            \\# Try configured python executable first, then python3, then python
            \\VENV_CREATED=false
            \\if command -v {s} >/dev/null 2>&1; then
            \\  echo "Using configured Python: {s}"
            \\  {s} -m venv {s} && VENV_CREATED=true
            \\fi
            \\if [ "$VENV_CREATED" = false ] && command -v python3 >/dev/null 2>&1; then
            \\  echo "Falling back to 'python3' executable"
            \\  python3 -m venv {s} && VENV_CREATED=true
            \\fi
            \\if [ "$VENV_CREATED" = false ] && command -v python >/dev/null 2>&1; then
            \\  echo "Falling back to 'python' executable"
            \\  python -m venv {s} && VENV_CREATED=true
            \\fi
            \\if [ "$VENV_CREATED" = false ]; then
            \\  echo "ERROR: Failed to find a suitable Python executable ('{s}', 'python3', or 'python') to create venv."
            \\  exit 1
            \\fi
            \\
        , .{
            env_config.python_executable, env_config.python_executable, env_config.python_executable, venv_dir,
            venv_dir,                     venv_dir,                     env_config.python_executable,
        });

        // 4. Activate and install dependencies with module package filtering logic
        try writer.print(
            \\echo '==> Step 4: Activating environment and installing dependencies'
            \\source {s}/bin/activate
            \\# Ensure pip is available and upgrade it
            \\if ! python -m pip --version >/dev/null 2>&1; then
            \\  echo "ERROR: 'pip' module not found after activating venv. Ensure Python installation includes pip."
            \\  exit 1
            \\fi
            \\python -m pip install --upgrade pip
            \\
            \\# Filter requirements to potentially exclude packages provided by modules
        , .{venv_dir});

        if (force_deps) {
            try writer.print(
                \\# --force-deps specified: Installing all dependencies regardless of modules
                \\echo '==> Using --force-deps: Installing all specified dependencies'
            , .{});
            if (valid_deps_list.items.len > 0) {
                try writer.print("python -m pip install -r {s}\n\n", .{req_abs_path});
            } else {
                try writer.print("echo '==> No dependencies in requirements file to install.'\n\n", .{});
            }
            // Clean up module package file if it exists
            try writer.print("rm -f \"$MODULE_PACKAGES_FILE\" 2>/dev/null || true\n", .{});
        } else {
            // Non-force-deps: Filter based on modules
            try writer.print(
                \\# Comparing requirements file with packages potentially provided by modules
                \\if [ -n "$MODULE_PACKAGES_FILE" ] && [ -s "$MODULE_PACKAGES_FILE" ]; then
                \\  echo '==> Filtering requirements against module-provided packages (checking $MODULE_PACKAGES_FILE)'
                \\  FILTERED_REQUIREMENTS=$(mktemp)
                \\  EXCLUDED_COUNT=0
                \\  INSTALLED_COUNT=0
                \\  # EXCLUDED_LIST="" # Uncomment if summary needed
                \\  while IFS= read -r line || [ -n "$line" ]; do
                \\    # Trim whitespace and skip comments/empty lines
                \\    trimmed_line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                \\    if [ -z "$trimmed_line" ] || [[ "$trimmed_line" == "#"* ]]; then
                \\      continue
                \\    fi
                \\    # Extract base package name (lowercase, remove extras and version specifiers)
                \\    package_name=$(echo "$trimmed_line" | sed 's/[^a-zA-Z0-9_.-].*//' | tr '[:upper:]' '[:lower:]')
                \\    # Check if package name exists in module packages file (case-insensitive)
                \\    # Match variations like 'package_name==' or 'package-name ' (editable installs)
                \\    if grep -i -q "^${{package_name}}==" "$MODULE_PACKAGES_FILE" || grep -i -q "^${{package_name}} " "$MODULE_PACKAGES_FILE"; then
                \\      echo "==> Excluding '$trimmed_line' (provided by loaded modules)"
                \\      EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
                \\      # EXCLUDED_LIST="${{EXCLUDED_LIST}}${{package_name}}\\n" # Uncomment if summary needed
                \\    else
                \\      # Package not found in modules, add to filtered requirements
                \\      echo "$line" >> "$FILTERED_REQUIREMENTS"
                \\      INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
                \\    fi
                \\  done < "{s}"
                \\
                \\  echo "==> Installing $INSTALLED_COUNT package(s) from filtered requirements file ($EXCLUDED_COUNT excluded)."
                \\  if [ -s "$FILTERED_REQUIREMENTS" ]; then
                \\    python -m pip install -r "$FILTERED_REQUIREMENTS"
                \\  else
                \\    echo '==> No additional packages need to be installed.'
                \\  fi
                \\  # Report excluded packages (Optional)
                \\  # if [ $EXCLUDED_COUNT -gt 0 ]; then
                \\  #   echo -e '\\n==> Summary of packages excluded (provided by modules):'
                \\  #   echo -e "$EXCLUDED_LIST" | sort | uniq
                \\  # fi
                \\  # Cleanup temp files
                \\  rm -f "$FILTERED_REQUIREMENTS" "$MODULE_PACKAGES_FILE"
                \\else
                \\  # Module command failed or no module packages detected, install all requirements
                \\  echo '==> No module packages detected or module command unavailable. Installing all dependencies from requirements file.'
            , .{req_abs_path}); // req_abs_path for the 'done <' part
            if (valid_deps_list.items.len > 0) {
                try writer.print("  python -m pip install -r {s}\n", .{req_abs_path});
            } else {
                try writer.print("  echo '==> No dependencies in requirements file to install.'\n", .{});
            }
            // Clean up module package file if it exists
            try writer.print(
                \\  rm -f "$MODULE_PACKAGES_FILE" 2>/dev/null || true
                \\fi
                \\
            , .{});
        }

        // 5. Run custom commands if any
        if (env_config.setup_commands != null and env_config.setup_commands.?.items.len > 0) {
            try writer.print(
                \\echo '==> Step 5: Running custom setup commands'
                \\# Activate again just in case custom commands need the venv
                \\source {s}/bin/activate
            , .{venv_dir});
            for (env_config.setup_commands.?.items) |cmd| {
                try writer.print("{s}\n", .{cmd});
            }
            try writer.print("\n", .{});
        }

        // 6. Completion message
        const activate_script_path = try std.fmt.allocPrint(allocator, "{s}/zenv/{s}/activate.sh", .{ cwd_path, env_name });
        defer allocator.free(activate_script_path);
        try writer.print(
            \\echo '==> Setup completed successfully!'
            \\echo 'To activate this environment, run: source {s}'
            \\
        , .{activate_script_path});

        // Flush buffer and set executable permissions
        try bw.flush();
        try script_file.chmod(0o755); // Make executable
    } // script_file is closed here
    std.log.info("Created setup script: {s}", .{script_abs_path});

    // Execute setup script
    executeShellScript(allocator, script_abs_path, script_rel_path) catch |err| {
        if (err == error.ModuleLoadError) {
            // Let this error propagate up as is
            return err;
        }
        // For other errors, propagate as ProcessError
        return error.ProcessError;
    };

    std.log.info("Environment '{s}' setup completed successfully.", .{env_name});
}

// ============================================================================
// Environment Validation & Info Utilities
// ============================================================================

// Pure function to validate environment for a specific hostname
// Normalizes a hostname for better matching
// Handles common variations like ".local" suffix on macOS
fn normalizeHostname(hostname: []const u8) []const u8 {
    // Remove ".local" suffix common in macOS environments
    if (std.mem.endsWith(u8, hostname, ".local")) {
        return hostname[0 .. hostname.len - 6];
    }
    return hostname;
}

// Checks if pattern with wildcards matches a string
// Supports * (any characters) and ? (single character)
fn patternMatches(pattern: []const u8, str: []const u8) bool {
    // Empty pattern only matches empty string
    if (pattern.len == 0) return str.len == 0;
    
    // Special case: single * matches anything
    if (pattern.len == 1 and pattern[0] == '*') return true;
    
    // Empty string only matches if pattern is just asterisks
    if (str.len == 0) {
        for (pattern) |c| {
            if (c != '*') return false;
        }
        return true;
    }
    
    // Handle common prefix pattern: "compute-*"
    if (pattern.len >= 2 and pattern[pattern.len - 1] == '*') {
        // Check if it's a simple prefix pattern without other wildcards
        var has_other_wildcards = false;
        for (pattern[0 .. pattern.len - 1]) |c| {
            if (c == '*' or c == '?') {
                has_other_wildcards = true;
                break;
            }
        }
        
        if (!has_other_wildcards) {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, str, prefix);
        }
    }
    
    // Handle common suffix pattern: "*.example.com"
    if (pattern.len >= 2 and pattern[0] == '*') {
        // Check if it's a simple suffix pattern without other wildcards
        var has_other_wildcards = false;
        for (pattern[1..]) |c| {
            if (c == '*' or c == '?') {
                has_other_wildcards = true;
                break;
            }
        }
        
        if (!has_other_wildcards) {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, str, suffix);
        }
    }
    
    // For other patterns, use a more general algorithm
    // This is a simple implementation - could be optimized further
    if (pattern[0] == '*') {
        // '*' can match 0 or more characters
        // Try matching rest of pattern with current string, or
        // keep the asterisk and match with next character of string
        return patternMatches(pattern[1..], str) or patternMatches(pattern, str[1..]);
    } else if (pattern[0] == '?' or pattern[0] == str[0]) {
        // '?' matches any single character, or match exact character
        if (str.len >= 1) {
            return patternMatches(pattern[1..], str[1..]);
        }
    }
    
    return false;
}

// Splits a hostname into domain components and checks if any match the target
fn matchDomainComponent(hostname: []const u8, target: []const u8) bool {
    var parts = std.mem.splitScalar(u8, hostname, '.');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, target)) {
            return true;
        }
    }
    return false;
}

pub fn validateEnvironmentForMachine(
    env_config: anytype,
    hostname: []const u8
) bool {
    // Special case: No target machines means any machine is valid
    if (env_config.target_machines.items.len == 0) {
        return true;
    }
    
    // Check against each target machine in the list
    for (env_config.target_machines.items) |target| {
        // Special cases for universal targets
        if (std.mem.eql(u8, target, "localhost") or 
            std.mem.eql(u8, target, "any") or 
            std.mem.eql(u8, target, "*")) {
            return true;
        }
        
        // Normalize the hostname
        const norm_hostname = normalizeHostname(hostname);
        
        // Check if the target contains wildcard characters
        const has_wildcards = std.mem.indexOfAny(u8, target, "*?") != null;
        
        // If target has wildcards, use pattern matching
        if (has_wildcards) {
            if (patternMatches(target, norm_hostname)) {
                return true;
            }
            continue; // Try next target
        }
        
        // Otherwise, try various matching strategies in order of specificity
        
        // 1. Exact match (most specific)
        if (std.mem.eql(u8, norm_hostname, target)) {
            return true;
        }
        
        // 2. Domain component match (e.g., matching "jureca" in "jrlogin08.jureca")
        if (matchDomainComponent(norm_hostname, target)) {
            return true;
        }
        
        // 3. Check if target is a domain suffix like ".example.com"
        if (target.len > 0 and target[0] == '.' and 
            std.mem.endsWith(u8, norm_hostname, target)) {
            return true;
        }
        
        // 4. Domain suffix match (e.g., node123.cluster matches target cluster)
        if (norm_hostname.len > target.len + 1 and norm_hostname[norm_hostname.len - target.len - 1] == '.') {
            const suffix = norm_hostname[norm_hostname.len - target.len..];
            if (std.mem.eql(u8, suffix, target)) {
                return true;
            }
        }
    }
    
    // No match found with any target machine
    return false;
}

// Get and validate environment configuration based on args and current hostname
pub fn getAndValidateEnvironment(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) ?*const EnvironmentConfig {
    if (args.len < 3) {
        std.log.err("Missing environment name argument for command '{s}'", .{args[1]});
        // Create error context but use standard error for now
        // TODO: Update error handling to use contextualized errors
        handleErrorFn(error.EnvironmentNotFound);
        return null;
    }
    const env_name = args[2];

    const env_config = config.getEnvironment(env_name) orelse {
        std.log.err("Environment '{s}' not found in configuration.", .{env_name});
        handleErrorFn(error.EnvironmentNotFound);
        return null;
    };

    // Use new validation function for early validation
    if (config_module.ZenvConfig.validateEnvironment(env_config, env_name)) |err| {
        std.log.err("Invalid environment configuration for '{s}': {s}", .{env_name, @errorName(err)});
        handleErrorFn(err);
        return null;
    }
    
    // Check for --no-host flag to bypass hostname validation
    var skip_hostname_check = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-host")) {
            skip_hostname_check = true;
            std.log.info("'--no-host' flag detected. Skipping hostname validation.", .{});
            break;
        }
    }
    
    if (skip_hostname_check) {
        std.log.info("Hostname validation bypassed for environment '{s}'.", .{env_name});
        return env_config;
    }

    // Get current hostname
    var hostname: []const u8 = undefined;
    hostname = config.getHostname() catch |err| {
        std.log.err("Failed to get current hostname: {s}", .{@errorName(err)});
        handleErrorFn(err);
        return null;
    };
    defer allocator.free(hostname);

    // Validate hostname against target_machine
    std.log.debug("Comparing current hostname '{s}' with target machines for env '{s}'", .{ hostname, env_name });

    // Use our pure function for hostname matching
    const hostname_matches = validateEnvironmentForMachine(env_config, hostname);

    if (!hostname_matches) {
        // Format the target machines for the error message, handle OOM gracefully
        var formatted_targets: []const u8 = undefined;
        var formatted_targets_allocated = false;
        format_block: {
            var targets_buffer = std.ArrayList(u8).init(allocator);
            defer targets_buffer.deinit();
            
            // Attempt to format the string
            targets_buffer.appendSlice("[") catch |err| {
                if (err == error.OutOfMemory) break :format_block;
                // For other errors, also just break and use the placeholder
                break :format_block;
            };
            for (env_config.target_machines.items, 0..) |target, i| {
                if (i > 0) {
                    targets_buffer.appendSlice(", ") catch |err| {
                       if (err == error.OutOfMemory) break :format_block;
                       break :format_block;
                    };
                }
                targets_buffer.writer().print("\"{s}\"", .{target}) catch |err| {
                   if (err == error.OutOfMemory) break :format_block;
                   break :format_block;
                };
            }
            targets_buffer.appendSlice("]") catch |err| {
                if (err == error.OutOfMemory) break :format_block;
                break :format_block;
            };
            
            // If formatting succeeded, duplicate the result
            formatted_targets = allocator.dupe(u8, targets_buffer.items) catch |err| {
                if (err == error.OutOfMemory) break :format_block;
                break :format_block;
            };
            formatted_targets_allocated = true; // Mark that we need to free this later
        }
        
        // If formatting failed (OOM or other error before allocation), use a placeholder
        if (!formatted_targets_allocated) {
            formatted_targets = "<...>";
        }
        // Ensure allocated string is freed if we successfully allocated it
        if (formatted_targets_allocated) {
            defer allocator.free(formatted_targets);
        }

        std.log.err("Current machine ('{s}') does not match target machines ('{s}') specified for environment '{s}'.", .{
            hostname,
            formatted_targets,
            env_name,
        });
        std.log.err("Use '--no-host' flag to bypass this check if needed.", .{});
        handleErrorFn(error.TargetMachineMismatch);
        return null;
    }

    std.log.debug("Hostname validation passed for env '{s}'.", .{env_name});
    return env_config;
}

// Helper function to look up a registry entry by name or ID, handling ambiguity
pub fn lookupRegistryEntry(registry: *const config_module.EnvironmentRegistry, identifier: []const u8, handleErrorFn: fn (anyerror) void) ?config_module.RegistryEntry {
    const is_potential_id_prefix = identifier.len >= 7 and identifier.len < 40;

    // Look up environment in registry
    const entry = registry.lookup(identifier) orelse {
        // Special handling for ambiguous ID prefixes
        if (is_potential_id_prefix) {
            var matching_envs = std.ArrayList([]const u8).init(registry.allocator);
            defer matching_envs.deinit();
            var match_count: usize = 0; 

            for (registry.entries.items) |reg_entry| {
                if (reg_entry.id.len >= identifier.len and std.mem.eql(u8, reg_entry.id[0..identifier.len], identifier)) {
                    match_count += 1;
                    // Only store names if count might exceed 1
                    if (match_count > 1) {
                       matching_envs.append(reg_entry.env_name) catch |err| {
                          // Handle potential allocation error, though unlikely
                          std.log.err("Failed to allocate memory for ambiguous env list: {s}", .{@errorName(err)});
                          handleErrorFn(error.OutOfMemory);
                          return null;
                       };
                    }
                }
            }

            if (match_count > 1) {
                std.io.getStdErr().writer().print("Error: Ambiguous ID prefix '{s}' matches multiple environments:\n", .{identifier}) catch {};
                // Print the names we collected (or the first one if collection failed)
                if (matching_envs.items.len > 0) {
                    for (matching_envs.items) |env_name| {
                        std.io.getStdErr().writer().print("  - {s}\n", .{env_name}) catch {};
                    }
                } else if (match_count > 1) {
                   // Fallback if allocation failed but we know there were >1 matches
                   std.io.getStdErr().writer().print("  (Could not list all matching environments due to memory issue)\n", .{}) catch {};
                }
                std.io.getStdErr().writer().print("Please use more characters to make the ID unique.\n", .{}) catch {};
                handleErrorFn(error.AmbiguousIdentifier);
                return null;
            }
        }

        // Default error for no matches (exact or unique prefix)
        std.io.getStdErr().writer().print("Error: Environment with name or ID '{s}' not found in registry.\n", .{identifier}) catch {};
        std.io.getStdErr().writer().print("Use 'zenv list' to see all available environments with their IDs.\n", .{}) catch {};
        handleErrorFn(error.EnvironmentNotRegistered);
        return null;
    };

    // Found a unique entry
    return entry;
}

// Prints the module load commands needed for manual activation to a writer
pub fn printManualActivationModuleCommands(
    allocator: Allocator,
    writer: anytype, // Should conform to std.io.Writer
    env_config: *const EnvironmentConfig,
) !void {
    // Suggest checking for module command before using it
    try writer.print("if command -v module >/dev/null 2>&1; then\n", .{});
    // Suggest purging first for clean state
    try writer.print("  module --force purge\n", .{});

    // Print module load commands with a clear list first
    if (env_config.modules.items.len > 0) {
        var modules_list = std.ArrayList(u8).init(allocator);
        defer modules_list.deinit();

        for (env_config.modules.items, 0..) |module_name, i| {
            if (i > 0) {
                try modules_list.appendSlice(", ");
            }
            try modules_list.appendSlice(module_name);
        }

        try writer.print("  echo 'Loading modules: {s}'\n", .{modules_list.items});

        // Print individual load commands
        for (env_config.modules.items) |module_name| {
            try writer.print("  module load {s}\n", .{module_name});
        }
    } else {
        try writer.print("  echo 'No modules to load'\n", .{});
    }

    try writer.print("else\n", .{});
    try writer.print("  echo 'Module command not available, skipping module operations'\n", .{});
    try writer.print("fi\n", .{});
}

// *** Placeholder for potential future I/O Utilities ***
// pub fn printOutputHeader(writer: anytype, title: []const u8) !void { ... }
// pub fn printOutputFooter(writer: anytype) !void { ... }

// Helper function to escape shell values (single quotes)
// Uses a fixed buffer to avoid memory allocations
pub fn escapeShellValue(value: []const u8, writer: anytype) !void {
    for (value) |char| {
        if (char == '\'') {
            try writer.writeAll("'\\''" );
        } else {
            try writer.writeByte(char);
        }
    }
}

// Helper function to determine if a dependency was provided in the config
// Used for memory management to avoid double freeing strings
pub fn isConfigProvidedDependency(env_config: *const EnvironmentConfig, dep: []const u8) bool {
    for (env_config.dependencies.items) |config_dep| {
        if (std.mem.eql(u8, config_dep, dep)) {
            return true;
        }
    }
    return false;
}

// Get hostname using environment variables or fallback to command
pub fn getSystemHostname(allocator: Allocator) ![]const u8 {
    std.log.debug("Attempting to get hostname from environment variable...", .{});

    // Try HOSTNAME first
    const hostname_env = std.process.getEnvVarOwned(allocator, "HOSTNAME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            // Try HOST if HOSTNAME is not found
            std.log.debug("HOSTNAME not set, trying HOST...", .{});
            const host_env = std.process.getEnvVarOwned(allocator, "HOST") catch |err2| {
                 if (err2 == error.EnvironmentVariableNotFound) {
                    // Fallback to command if neither env var is set
                    std.log.debug("HOST not set, falling back to 'hostname' command...", .{});
                    return getHostnameFromCommand(allocator);
                 } else {
                    // Propagate other errors from getting HOST
                    std.log.err("Failed to get HOST environment variable: {s}", .{@errorName(err2)});
                    return err2;
                 }
            };
            // Check if HOST was empty
            if (host_env.len == 0) {
                allocator.free(host_env);
                std.log.debug("HOST was empty, falling back to 'hostname' command...", .{});
                return getHostnameFromCommand(allocator);
            }
            std.log.debug("Got hostname from HOST: '{s}'", .{host_env});
            return host_env; // Return hostname from HOST
        } else {
            // Propagate other errors from getting HOSTNAME
            std.log.err("Failed to get HOSTNAME environment variable: {s}", .{@errorName(err)});
            return err;
        }
    };

    // Check if HOSTNAME was empty
    if (hostname_env.len == 0) {
        allocator.free(hostname_env);
        std.log.debug("HOSTNAME was empty, falling back to 'hostname' command...", .{});
        return getHostnameFromCommand(allocator);
    }

    std.log.debug("Got hostname from HOSTNAME: '{s}'", .{hostname_env});
    return hostname_env;
}

// Simple check for hostname matching target machine
pub fn checkHostnameMatch(hostname: []const u8, target_machine: []const u8) bool {
    // This function is only for the simplified registry case of a single target machine
    // Use the same matching logic for consistency
    
    // Special cases for universal targets
    if (std.mem.eql(u8, target_machine, "localhost") or 
        std.mem.eql(u8, target_machine, "any") or 
        std.mem.eql(u8, target_machine, "*")) {
        return true;
    }
    
    // Normalize the hostname
    const norm_hostname = normalizeHostname(hostname);
    
    // Check if the target contains wildcard characters
    const has_wildcards = std.mem.indexOfAny(u8, target_machine, "*?") != null;
    
    // If target has wildcards, use pattern matching
    if (has_wildcards) {
        return patternMatches(target_machine, norm_hostname);
    }
    
    // Try various matching strategies
    
    // 1. Exact match
    if (std.mem.eql(u8, norm_hostname, target_machine)) {
        return true;
    }
    
    // 2. Domain component match
    if (matchDomainComponent(norm_hostname, target_machine)) {
        return true;
    }
    
    // 3. Domain suffix
    if (target_machine.len > 0 and target_machine[0] == '.' and 
        std.mem.endsWith(u8, norm_hostname, target_machine)) {
        return true;
    }
    
    // 4. Domain suffix match
    if (norm_hostname.len > target_machine.len + 1 and 
        norm_hostname[norm_hostname.len - target_machine.len - 1] == '.') {
        const suffix = norm_hostname[norm_hostname.len - target_machine.len..];
        if (std.mem.eql(u8, suffix, target_machine)) {
            return true;
        }
    }
    
    return false;
}

// Helper function to get hostname using the `hostname` command
pub fn getHostnameFromCommand(allocator: Allocator) ![]const u8 {
    std.log.debug("Executing 'hostname' command", .{});
    const argv = [_][]const u8{"hostname"};
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe; // Capture stderr as well
    try child.spawn();

    const stdout = child.stdout.?.readToEndAlloc(allocator, 128) // Limit size for hostname
        catch |err| {
            std.log.err("Failed to read stdout from `hostname` command: {s}", .{@errorName(err)});
            _ = child.wait() catch {}; // Ensure child process is waited on
            return error.ProcessError;
        };
    errdefer allocator.free(stdout);

    const stderr = child.stderr.?.readToEndAlloc(allocator, 512) // Limit stderr size
        catch |err| {
            std.log.err("Failed to read stderr from `hostname` command: {s}", .{@errorName(err)});
            _ = child.wait() catch {};
            return error.ProcessError;
        };
    defer allocator.free(stderr);

    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        std.log.err("`hostname` command failed. Term: {?} Stderr: {s}", .{ term, stderr });
        return error.ProcessError;
    }

    const trimmed_hostname = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (trimmed_hostname.len == 0) {
        std.log.err("`hostname` command returned empty output.", .{});
        return error.MissingHostname;
    }
    std.log.debug("Got hostname from command: '{s}'", .{trimmed_hostname});
    // Return a duplicate of the trimmed hostname
    return allocator.dupe(u8, trimmed_hostname);
}
