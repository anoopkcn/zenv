const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
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
pub fn createScVenvDir(allocator: Allocator, env_name: []const u8) !void {
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
fn generateShellScriptHeader(script_content: *std.ArrayList(u8), env_name: []const u8, script_purpose: []const u8) !void {
    try script_content.appendSlice("#!/bin/sh\n");
    try script_content.appendSlice("set -e\n"); // Exit on error for setup scripts
    try script_content.writer().print("\n# {s} script for '{s}' environment generated by zenv\n\n", .{ script_purpose, env_name });
}

// Appends module purge, load, and check commands to a script buffer
fn appendModuleCommandsToScript(
    script_content: *std.ArrayList(u8),
    env_config: *const EnvironmentConfig,
    include_package_check: bool, // Flag to include python package detection
) !void {
    try script_content.appendSlice("# Check if module command exists\n");
    try script_content.appendSlice("if command -v module >/dev/null 2>&1; then\n");
    try script_content.appendSlice("  echo '==> Purging all modules'\n");
    try script_content.appendSlice("  module --force purge\n");

    if (env_config.modules.items.len > 0) {
        try script_content.appendSlice("  echo '==> Loading required modules'\n");
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
        try script_content.appendSlice("  echo '==> No modules specified to load'\n");
    }

    // Optionally add code to detect packages provided by modules (for setup script)
    if (include_package_check) {
         try script_content.appendSlice("  echo '==> Checking Python packages provided by modules'\n");
         try script_content.appendSlice("  MODULE_PACKAGES_FILE=$(mktemp)\n");
         // Try python3 first, then python if python3 fails
         try script_content.appendSlice("  (python3 -m pip list --format=freeze > \"$MODULE_PACKAGES_FILE\" 2>/dev/null || python -m pip list --format=freeze > \"$MODULE_PACKAGES_FILE\" 2>/dev/null) || true\n");
         try script_content.appendSlice("  if [ -s \"$MODULE_PACKAGES_FILE\" ]; then\n");
         try script_content.appendSlice("    echo '==> Found packages from modules:'\n");
         try script_content.appendSlice("    echo -n '    '\n");
         // Extract just package names, sort, join with comma-space
         try script_content.appendSlice("    cat \"$MODULE_PACKAGES_FILE\" | sed -E 's/==.*//;s/ .*//' | sort | tr '\n' ',' | sed 's/,/, /g' | sed 's/, $//'\n");
         try script_content.appendSlice("    echo ''\n");
         try script_content.appendSlice("  else\n");
         try script_content.appendSlice("    echo '==> No Python packages detected from modules'\n");
         try script_content.appendSlice("    # Ensure the file exists even if empty for later steps\n");
         try script_content.appendSlice("    touch \"$MODULE_PACKAGES_FILE\"\n");
         try script_content.appendSlice("  fi\n");
    }

    try script_content.appendSlice("else\n");
    try script_content.appendSlice("  echo '==> Module command not found, skipping module operations'\n");
    if (include_package_check) {
        // Define MODULE_PACKAGES_FILE as empty if module command is missing
        try script_content.appendSlice("  MODULE_PACKAGES_FILE=$(mktemp) # Create empty temp file\n");
    }
    try script_content.appendSlice("fi\n\n");
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

    var script_content = std.ArrayList(u8).init(allocator);
    defer script_content.deinit();

    // Add standard header (no set -e for activation)
    try script_content.appendSlice("#!/bin/sh\n");
    try script_content.writer().print("\n# Activation script for '{s}' environment generated by zenv\n\n", .{ env_name });

    // Add module purge and loading commands (no package check needed here)
    try appendModuleCommandsToScript(&script_content, env_config, false);

    // Virtual environment activation with absolute path
    try script_content.appendSlice("# Activate the Python virtual environment\n");
    const venv_path = try std.fmt.allocPrint(allocator, "{s}/zenv/{s}/venv", .{ cwd_path, env_name });
    defer allocator.free(venv_path);
    try script_content.writer().print("source {s}/bin/activate\n\n", .{venv_path});

    // Custom environment variables
    if (env_config.custom_activate_vars.count() > 0) {
        try script_content.appendSlice("# Set custom environment variables\n");
        var vars_iter = env_config.custom_activate_vars.iterator();
        while (vars_iter.next()) |entry| {
            // Basic quoting for safety, assumes no complex shell injection needed
             try script_content.writer().print("export {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
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
    try script_content.appendSlice("  # Check if deactivate function exists (from venv)\n");
    try script_content.appendSlice("  if command -v deactivate >/dev/null 2>&1; then\n");
    try script_content.appendSlice("    echo \"Running venv deactivate...\"\n");
    try script_content.appendSlice("    deactivate\n");
    try script_content.appendSlice("  fi\n");
    try script_content.appendSlice("  # Then unset any custom environment variables\n");
    if (env_config.custom_activate_vars.count() > 0) {
         try script_content.appendSlice("  echo \"Unsetting custom variables...\"\n");
         var vars_iter_unset = env_config.custom_activate_vars.iterator();
         while (vars_iter_unset.next()) |entry| {
             try script_content.writer().print("  unset {s}\n", .{entry.key_ptr.*});
         }
    }
    try script_content.appendSlice("  # Unset this function\n");
    try script_content.appendSlice("  unset -f deactivate_all\n");
    try script_content.appendSlice("  echo \"Environment fully deactivated\"\n");
    try script_content.appendSlice("}\n");

    // Write script to file using relative path
    var script_file = try fs.cwd().createFile(script_rel_path, .{});
    defer script_file.close();
    try script_file.writeAll(script_content.items);
    try script_file.chmod(0o755); // Make executable

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
        std.log.err("Script execution failed with exit code: {d}", .{term.Exited});
        // Display the script content for debugging if it still exists
        const script_content_debug = fs.cwd().readFileAlloc(allocator, script_rel_path, 1024 * 1024) catch |read_err| {
            std.log.err("Failed to read script content for debugging: {s}", .{@errorName(read_err)});
            return ZenvError.ProcessError; // Return original error
        };
        defer allocator.free(script_content_debug);
        // Print the script content for debugging
        std.io.getStdErr().writer().print("\n\nScript contents ({s}):\n", .{script_rel_path}) catch {};
        std.io.getStdErr().writer().print("{s}\n-------------------------------------\n", .{script_content_debug}) catch {};

        return ZenvError.ProcessError;
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
    // Note: Items in valid_deps_list are references to original deps or dupes from parse* fns.
    // The caller of setupEnvironment (handleSetupCommand) owns the memory of the original combined list.

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

        if (valid_deps_list.items.len == 0) {
            std.log.warn("No valid dependencies found! Writing only a comment to requirements file.", .{});
            try req_file.writeAll("# No valid dependencies found\n");
        } else {
            for (valid_deps_list.items) |dep| {
                try req_file.writer().print("{s}\n", .{dep});
                std.log.debug("Wrote dependency to file: {s}", .{dep});
            }
        }
        try req_file.sync(); // Ensure content is written
    } // req_file is closed here
    std.log.info("Created requirements file: {s}", .{req_abs_path});

    // Generate setup script path
    const script_rel_path = try std.fmt.allocPrint(allocator, "zenv/{s}/setup_env.sh", .{env_name});
    defer allocator.free(script_rel_path);
    const script_abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_path, script_rel_path });
    defer allocator.free(script_abs_path);

    var script_content = std.ArrayList(u8).init(allocator);
    defer script_content.deinit();

    // 1. Script header
    try generateShellScriptHeader(&script_content, env_name, "Setup");

    // 2. Module commands (purge, load, check provided packages)
    try appendModuleCommandsToScript(&script_content, env_config, true);

    // 3. Create virtual environment
    try script_content.appendSlice("echo '==> Step 3: Creating Python virtual environment'\n");
    const venv_dir = try std.fmt.allocPrint(allocator, "{s}/zenv/{s}/venv", .{ cwd_path, env_name });
    defer allocator.free(venv_dir);
    // Try python3 first, then python
    try script_content.writer().print(
        \\if command -v {s} >/dev/null 2>&1; then
        \\  {s} -m venv {s}
        \\elif command -v python >/dev/null 2>&1; then
        \\  echo "Falling back to 'python' executable"
        \\  python -m venv {s}
        \\else
        \\  echo "ERROR: Neither '{s}' nor 'python' executable found in PATH after loading modules."
        \\  exit 1
        \\fi
        \\
    , .{ env_config.python_executable, env_config.python_executable, venv_dir, venv_dir, env_config.python_executable });


    // 4. Activate and install dependencies with module package filtering logic
    try script_content.appendSlice("echo '==> Step 4: Activating environment and installing dependencies'\n");
    try script_content.writer().print("source {s}/bin/activate\n", .{venv_dir});
    try script_content.appendSlice("# Ensure pip is available and upgrade it\n");
    try script_content.appendSlice("if ! python -m pip --version >/dev/null 2>&1; then\n");
    try script_content.appendSlice("  echo \"ERROR: 'pip' module not found after activating venv. Ensure Python installation includes pip.\"\n");
    try script_content.appendSlice("  exit 1\n");
    try script_content.appendSlice("fi\n");
    try script_content.appendSlice("python -m pip install --upgrade pip\n");

    // Add script logic to filter requirements.txt based on MODULE_PACKAGES_FILE
    try script_content.appendSlice("\n# Filter requirements to potentially exclude packages provided by modules\n");
    if (force_deps) {
        try script_content.appendSlice("# --force-deps specified: Installing all dependencies regardless of modules\n");
        try script_content.appendSlice("echo '==> Using --force-deps: Installing all specified dependencies'\n");
        if (valid_deps_list.items.len > 0) {
             try script_content.writer().print("python -m pip install -r {s}\n\n", .{req_abs_path});
        } else {
            try script_content.appendSlice("echo '==> No dependencies in requirements file to install.'\n\n");
        }
        // Clean up module package file if it exists (not used in force mode but created by appendModuleCommandsToScript)
        try script_content.appendSlice("rm -f \"$MODULE_PACKAGES_FILE\" 2>/dev/null || true\n");
    } else {
        try script_content.appendSlice("# Comparing requirements file with packages potentially provided by modules\n");
        try script_content.appendSlice("if [ -n \"$MODULE_PACKAGES_FILE\" ] && [ -s \"$MODULE_PACKAGES_FILE\" ]; then\n");
        try script_content.appendSlice("  echo '==> Filtering requirements against module-provided packages (checking $MODULE_PACKAGES_FILE)'\n");
        try script_content.appendSlice("  FILTERED_REQUIREMENTS=$(mktemp)\n");
        try script_content.appendSlice("  EXCLUDED_COUNT=0\n");
        try script_content.appendSlice("  INSTALLED_COUNT=0\n");
        try script_content.appendSlice("  EXCLUDED_LIST=\"\"\n");
        // Use req_abs_path for reading
        try script_content.writer().print("  while IFS= read -r line || [ -n \"$line\" ]; do\n", .{});
        try script_content.appendSlice("    # Trim whitespace and skip comments/empty lines\n");
        try script_content.appendSlice("    trimmed_line=$(echo \"$line\" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')\n");
        try script_content.appendSlice("    if [ -z \"$trimmed_line\" ] || [[ \"$trimmed_line\" == \"#\"* ]]; then\n");
        try script_content.appendSlice("      # Optionally keep comments in filtered file?\n");
        try script_content.appendSlice("      # echo \"$line\" >> \"$FILTERED_REQUIREMENTS\"\n");
        try script_content.appendSlice("      continue\n");
        try script_content.appendSlice("    fi\n");
        try script_content.appendSlice("    # Extract base package name (lowercase, remove extras and version specifiers)\n");
        try script_content.appendSlice("    package_name=$(echo \"$trimmed_line\" | sed -E 's/([a-zA-Z0-9_\\-\\.]+).*/\\1/' | tr '[:upper:]' '[:lower:]')\n");
        try script_content.appendSlice("    # Check if package name exists in module packages file (case-insensitive)\n");
        try script_content.appendSlice("    # Match variations like 'package_name==' or 'package-name ' (editable installs)\n");
        try script_content.appendSlice("    if grep -i -q -E \"^${package_name}==|^${package_name} \" \"$MODULE_PACKAGES_FILE\"; then\n");
        try script_content.appendSlice("      echo \"==> Excluding '$trimmed_line' (provided by loaded modules)\"\n");
        try script_content.appendSlice("      EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))\n");
        try script_content.appendSlice("      EXCLUDED_LIST=\"${EXCLUDED_LIST}${package_name}\\n\"\n");
        try script_content.appendSlice("    else\n");
        try script_content.appendSlice("      # Package not found in modules, add to filtered requirements\n");
        try script_content.appendSlice("      echo \"$line\" >> \"$FILTERED_REQUIREMENTS\"\n");
        try script_content.appendSlice("      INSTALLED_COUNT=$((INSTALLED_COUNT + 1))\n");
        try script_content.appendSlice("    fi\n");
        try script_content.writer().print("  done < \"{s}\"\n\n", .{req_abs_path});

        try script_content.appendSlice("  echo \"==> Installing $INSTALLED_COUNT package(s) from filtered requirements file ($EXCLUDED_COUNT excluded).\"\n");
        try script_content.appendSlice("  if [ -s \"$FILTERED_REQUIREMENTS\" ]; then\n");
        try script_content.appendSlice("    python -m pip install -r \"$FILTERED_REQUIREMENTS\"\n");
        try script_content.appendSlice("  else\n");
        try script_content.appendSlice("    echo '==> No additional packages need to be installed.'\n");
        try script_content.appendSlice("  fi\n");
        // try script_content.appendSlice("  # Report excluded packages\n");
        // try script_content.appendSlice("  if [ $EXCLUDED_COUNT -gt 0 ]; then\n");
        // try script_content.appendSlice("    echo -e '\\n==> Summary of packages excluded (provided by modules):'\n");
        // try script_content.appendSlice("    echo -e \"$EXCLUDED_LIST\" | sort | uniq\n");
        // try script_content.appendSlice("  fi\n");
        try script_content.appendSlice("  # Cleanup temp files\n");
        try script_content.appendSlice("  rm -f \"$FILTERED_REQUIREMENTS\" \"$MODULE_PACKAGES_FILE\"\n");
        try script_content.appendSlice("else\n");
        try script_content.appendSlice("  # Module command failed or no module packages detected, install all requirements\n");
        try script_content.appendSlice("  echo '==> No module packages detected or module command unavailable. Installing all dependencies from requirements file.'\n");
        if (valid_deps_list.items.len > 0) {
            try script_content.writer().print("  python -m pip install -r {s}\n", .{req_abs_path});
        } else {
            try script_content.appendSlice("  echo '==> No dependencies in requirements file to install.'\n");
        }
        // Clean up module package file if it exists
        try script_content.appendSlice("  rm -f \"$MODULE_PACKAGES_FILE\" 2>/dev/null || true\n");
        try script_content.appendSlice("fi\n\n");
    }


    // 5. Run custom commands if any
    if (env_config.setup_commands != null and env_config.setup_commands.?.items.len > 0) {
        try script_content.appendSlice("echo '==> Step 5: Running custom setup commands'\n");
        // Activate again just in case custom commands need the venv
        try script_content.writer().print("source {s}/bin/activate\n", .{venv_dir});
        for (env_config.setup_commands.?.items) |cmd| {
            try script_content.writer().print("{s}\n", .{cmd});
        }
        try script_content.appendSlice("\n");
    }

    // 6. Completion message
    try script_content.appendSlice("echo '==> Setup completed successfully!'\n");
    const activate_script_path = try std.fmt.allocPrint(allocator, "{s}/zenv/{s}/activate.sh", .{ cwd_path, env_name });
    defer allocator.free(activate_script_path);
    try script_content.writer().print("echo 'To activate this environment, run: source {s}'\n", .{activate_script_path});

    // Write setup script to file
    std.log.info("Writing setup script to {s}", .{script_rel_path});
    { // Scope for file write
        var script_file = try fs.cwd().createFile(script_rel_path, .{});
        defer script_file.close();
        try script_file.writeAll(script_content.items);
        try script_file.chmod(0o755); // Make executable
        try script_file.sync();
    }
    std.log.info("Created setup script: {s}", .{script_abs_path});

    // Execute setup script
    try executeShellScript(allocator, script_abs_path, script_rel_path);

    std.log.info("Environment '{s}' setup completed successfully.", .{env_name});
}


// ============================================================================
// Environment Validation & Info Utilities
// ============================================================================

// Get and validate environment configuration based on args and current hostname
pub fn getAndValidateEnvironment(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) ?*const EnvironmentConfig {
    if (args.len < 3) {
        std.log.err("Missing environment name argument for command '{s}'", .{args[1]});
        handleErrorFn(ZenvError.EnvironmentNotFound); // Consider a specific MissingArgument error
        return null;
    }
    const env_name = args[2];

    const env_config = config.getEnvironment(env_name) orelse {
        std.log.err("Environment '{s}' not found in configuration.", .{env_name});
        handleErrorFn(ZenvError.EnvironmentNotFound);
        return null;
    };

    // Get current hostname
    var hostname: []const u8 = undefined;
    hostname = config_module.ZenvConfig.getHostname(allocator) catch |err| {
         std.log.err("Failed to get current hostname: {s}", .{@errorName(err)});
        handleErrorFn(err);
        return null;
    };
    defer allocator.free(hostname);

    // Validate hostname against target_machine
    std.log.debug("Comparing current hostname '{s}' with target machine '{s}' for env '{s}'", .{ hostname, env_config.target_machine, env_name });

    // Enhanced hostname matching
    const hostname_matches = blk: {
        const target = env_config.target_machine;
        // 1. Exact match
        if (std.mem.eql(u8, hostname, target)) {
             std.log.debug("Exact hostname match.", .{});
            break :blk true;
        }
        // 2. Domain suffix match (e.g., node123.cluster matches target cluster)
        if (hostname.len > target.len + 1 and hostname[hostname.len - target.len - 1] == '.') {
            const suffix = hostname[hostname.len - target.len ..];
             if (std.mem.eql(u8, suffix, target)) {
                 std.log.debug("Domain suffix match.", .{});
                 break :blk true;
             }
        }
         // 3. Simple substring match (fallback, less precise)
         if (std.mem.indexOf(u8, hostname, target) != null) {
             std.log.debug("Substring match (fallback).", .{});
             break :blk true;
         }

        break :blk false;
    };

    if (!hostname_matches) {
        std.log.err("Current machine ('{s}') does not match target machine ('{s}') specified for environment '{s}'.", .{
            hostname,
            env_config.target_machine,
            env_name,
        });
        handleErrorFn(ZenvError.TargetMachineMismatch); // Use a specific error
        return null;
    }

    std.log.debug("Hostname validation passed for env '{s}'.", .{env_name});
    return env_config;
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
