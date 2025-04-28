const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("../config.zig");
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("../errors.zig");
const fs = std.fs;

const template = @import("template.zig");
const shell_utils = @import("shell_utils.zig");

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

    // Generate the module commands block
    var module_commands_block = std.ArrayList(u8).init(allocator);
    defer module_commands_block.deinit();
    const module_writer = module_commands_block.writer();

    // Module command checking logic
    try module_writer.print(
        \\# Check if module command exists
        \\if command -v module >/dev/null 2>&1; then
        \\  echo '==> Purging all modules'
        \\  module --force purge
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

        try module_writer.print("  echo '==> Loading required modules'\n", .{});
        try module_writer.print("  echo 'Loading modules: {s}'\n", .{module_list_str.items});

        // Use set +e to prevent script from exiting on module load error
        try module_writer.print("  # Don't exit immediately on module load errors so we can intercept and handle them\n", .{});
        try module_writer.print("  set +e\n", .{});

        // Load each module with error checking
        for (env_config.modules.items) |module_name| {
            try module_writer.print(
                \\  module load {s}
                \\  if [ $? -ne 0 ]; then
                \\    echo "Error: Failed to load module '{s}'"
                \\    exit 1
                \\  fi
                \\
            , .{ module_name, module_name });
        }

        // Restore error exit mode
        try module_writer.print("  set -e\n", .{});
    } else {
        try module_writer.print("  echo '==> No modules specified to load'\n", .{});
    }

    // Add code to detect packages provided by modules
    try module_writer.print(
        \\  echo '==> Checking Python packages provided by modules'
        \\  MODULE_PACKAGES_FILE=$(mktemp)
        \\  # Try python3 first, then python if python3 fails
        \\  (python3 -m pip list --format=freeze > "$MODULE_PACKAGES_FILE" 2>/dev/null || python -m pip list --format=freeze > "$MODULE_PACKAGES_FILE" 2>/dev/null) || true
        \\  if [ -s "$MODULE_PACKAGES_FILE" ]; then
        \\    echo '==> Found packages from modules:'
        \\    echo -n '    '
        \\    # Extract just package names, sort, join with comma-space
        \\    cat "$MODULE_PACKAGES_FILE" | sed -E 's/==.*//;s/ .*//' | sort | tr '\\n' ',' | sed 's/,/, /g' | sed 's/, $//'
        \\    echo ''
        \\  else
        \\    echo '==> No Python packages detected from modules'
        \\    # Ensure the file exists even if empty for later steps
        \\    touch "$MODULE_PACKAGES_FILE"
        \\  fi
        \\
    , .{});

    try module_writer.print("else\n", .{});
    try module_writer.print("  echo '==> Module command not found, skipping module operations'\n", .{});
    try module_writer.print("  MODULE_PACKAGES_FILE=$(mktemp) # Create empty temp file\n", .{});
    try module_writer.print("fi\n\n", .{});

    const module_commands_slice = try module_commands_block.toOwnedSlice();
    defer allocator.free(module_commands_slice);
    try replacements.put("MODULE_COMMANDS_BLOCK", module_commands_slice);

    // Generate the dependency installation block
    var dependency_install_block = std.ArrayList(u8).init(allocator);
    defer dependency_install_block.deinit();
    const deps_writer = dependency_install_block.writer();

    if (force_deps) {
        try deps_writer.print(
            \\# --force-deps specified: Installing all dependencies regardless of modules
            \\echo '==> Using --force-deps: Installing all specified dependencies'
        , .{});
        if (valid_deps_list_len > 0) {
            try deps_writer.print("python -m pip install -r {s}\n\n", .{req_abs_path});
        } else {
            try deps_writer.print("echo '==> No dependencies in requirements file to install.'\n\n", .{});
        }
        // Clean up module package file if it exists
        try deps_writer.print("rm -f \"$MODULE_PACKAGES_FILE\" 2>/dev/null || true\n", .{});
    } else {
        // Non-force-deps: Filter based on modules
        try deps_writer.print(
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
        if (valid_deps_list_len > 0) {
            try deps_writer.print("  python -m pip install -r {s}\n", .{req_abs_path});
        } else {
            try deps_writer.print("  echo '==> No dependencies in requirements file to install.'\n", .{});
        }
        // Clean up module package file if it exists
        try deps_writer.print(
            \\  rm -f "$MODULE_PACKAGES_FILE" 2>/dev/null || true
            \\fi
            \\
        , .{});
    }

    const deps_install_slice = try dependency_install_block.toOwnedSlice();
    defer allocator.free(deps_install_slice);
    try replacements.put("DEPENDENCY_INSTALL_BLOCK", deps_install_slice);

    // Generate custom setup commands block
    var custom_setup_commands_block = std.ArrayList(u8).init(allocator);
    defer custom_setup_commands_block.deinit();
    const custom_writer = custom_setup_commands_block.writer();

    if (env_config.setup_commands != null and env_config.setup_commands.?.items.len > 0) {
        try custom_writer.print(
            \\echo '==> Step 5: Running custom setup commands'
            \\# Activate again just in case custom commands need the venv
            \\source {s}/bin/activate
        , .{venv_dir});
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