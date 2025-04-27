const std = @import("std");
const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const process = std.process;
const fs = std.fs;
const Allocator = std.mem.Allocator;


// Common function to get and validate environment config
fn getAndValidateEnvironment(
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
     std.log.debug("Comparing hostname '{s}' with target machine '{s}'", .{hostname, env_config.target_machine});

     // Enhanced hostname matching to handle different patterns
     const hostname_matches = blk: {
         // Check if hostname ends with ".target_machine" (domain-style matching)
         const target = env_config.target_machine;
         const domain_check = std.mem.concat(allocator, u8, &[_][]const u8{".", target}) catch {
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
             const suffix = hostname[hostname.len - domain_check.len..];
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


pub fn handleSetupCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void, // Renamed for clarity
) anyerror!void {
    const env_config = getAndValidateEnvironment(allocator, config, args, handleErrorFn) orelse return;
    const env_name = args[2]; // Safe now after check in getAndValidateEnvironment

    // Check for --force-deps flag
    var force_deps = false;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--force-deps")) {
            force_deps = true;
            std.log.info("Force dependencies flag detected. User-specified dependencies will override module-provided packages.", .{});
            break;
        }
    }

    std.log.info("Setting up environment: {s} (Target: {s})", .{ env_name, env_config.target_machine });

    // --- Automation Logic ---
    // 1. Combine Dependencies:
    //    - Start with env_config.dependencies.items
    //    - If env_config.requirements_file != null, read that file and add its lines.
    //    - Store the combined list (e.g., in an ArrayList).
    var all_required_deps = std.ArrayList([]const u8).init(allocator);
    defer all_required_deps.deinit(); // Assuming items are references or freed elsewhere

    // First add all dependencies from the config
    if (env_config.dependencies.items.len > 0) {
        std.log.info("Adding {d} dependencies from configuration:", .{env_config.dependencies.items.len});
        for (env_config.dependencies.items) |dep| {
            std.log.info("  - Config dependency: {s}", .{dep});
            try all_required_deps.append(dep); // Let error propagate
        }
    } else {
        std.log.info("No dependencies specified in configuration.", .{});
    }

    // Then add dependencies from requirements file if it exists
    if (env_config.requirements_file) |req_file| {
        // Log the absolute path for debugging
        var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = std.fs.cwd().realpath(req_file, &abs_path_buf) catch |err| {
            std.log.err("Failed to resolve absolute path for requirements file '{s}': {s}",
                       .{req_file, @errorName(err)});
            abs_path_buf[0] = 0; // Empty string in case of error
            return err;
        };
        std.log.info("Reading dependencies from requirements file: '{s}' (absolute path: '{s}')",
                   .{req_file, abs_path});

        // Try to read the file
        std.log.info("Verifying requirements file exists and is readable...", .{});
        const req_file_stat = fs.cwd().statFile(req_file) catch |err| {
            std.log.err("Failed to stat requirements file '{s}': {s}", .{req_file, @errorName(err)});
            handleErrorFn(ZenvError.PathResolutionFailed);
            return;
        };
        std.log.info("Requirements file size: {d} bytes", .{req_file_stat.size});

        // Now read the file content
        const req_content = fs.cwd().readFileAlloc(allocator, req_file, 100 * 1024) catch |err| {
            std.log.err("Failed to read requirements file '{s}': {s}", .{req_file, @errorName(err)});
            handleErrorFn(ZenvError.PathResolutionFailed);
            return;
        };
        defer allocator.free(req_content);

        std.log.info("Successfully read requirements file ({d} bytes). Parsing dependencies...", .{req_content.len});

        var lines = std.mem.splitScalar(u8, req_content, '\n');
        var req_file_dep_count: usize = 0;

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
            try all_required_deps.append(trimmed_dupe);
            req_file_dep_count += 1;
        }

        if (req_file_dep_count > 0) {
            std.log.info("Added {d} dependencies from requirements file", .{req_file_dep_count});
        } else {
            std.log.warn("No valid dependencies found in requirements file", .{});
        }
    } else {
        std.log.info("No requirements file specified in configuration.", .{});
    }

    std.log.info("Total combined dependencies: {d}", .{all_required_deps.items.len});

    // Create sc_venv directory if it doesn't exist
    try createScVenvDir(allocator, env_name);

    // Create and run a single setup script that handles all steps
    try setupEnvironment(allocator, env_config, env_name, all_required_deps.items, force_deps);

    // Create an activation script
    try createActivationScript(allocator, env_config, env_name);

    std.log.info("Environment '{s}' setup complete.", .{env_name});
    // --- End Automation Logic ---
}

fn createScVenvDir(allocator: Allocator, env_name: []const u8) !void {
    std.log.info("Creating virtual environment directory for '{s}'...", .{env_name});

    // Create base sc_venv directory if it doesn't exist
    try fs.cwd().makePath("sc_venv");

    // Create environment-specific directory
    const env_dir_path = try std.fmt.allocPrint(allocator, "sc_venv/{s}", .{env_name});
    defer allocator.free(env_dir_path);

    try fs.cwd().makePath(env_dir_path);
}

fn setupEnvironment(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8, deps: []const []const u8, force_deps: bool) !void {
    std.log.info("Setting up environment '{s}'...", .{env_name});

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);

    // Create requirements file from scratch with validated dependencies
    const req_rel_path = try std.fmt.allocPrint(allocator, "sc_venv/{s}/requirements.txt", .{env_name});
    defer allocator.free(req_rel_path);

    const req_abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{cwd_path, req_rel_path});
    defer allocator.free(req_abs_path);

    // Display dependencies for debugging
    if (deps.len == 0) {
        std.log.warn("No dependencies provided to setupEnvironment", .{});
    } else {
        std.log.info("Processing {d} dependencies before validation:", .{deps.len});
        for (deps, 0..) |dep, i| {
            if (dep.len > 0) {
                std.log.info("  [{d}] '{s}'", .{i + 1, dep});
            } else {
                std.log.warn("  [{d}] Empty dependency", .{i + 1});
            }
        }
    }

    // Create a clean set of valid dependencies
    var valid_deps = std.ArrayList([]const u8).init(allocator);
    defer valid_deps.deinit();

    // Create a HashMap to track seen package names to avoid duplicates
    var seen_packages = std.StringHashMap(bool).init(allocator);
    defer seen_packages.deinit();

    // Only accept properly formatted Python package requirements
    // Pattern: package_name[>=<~=]=version
    std.log.info("Validating dependencies for '{s}':", .{env_name});
    for (deps) |dep| {
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
            // Allow alphanumeric, hyphen, underscore, dot, and comparison operators
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                has_alpha = true;
            } else if (!((c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or
                        c == '>' or c == '<' or c == '=' or c == '~' or c == ' ' or c == '[' or c == ']')) {
                valid = false;
                break;
            }
        }

        if (!valid or !has_alpha) {
            std.log.warn("Skipping invalid dependency: '{s}'", .{dep});
            continue;
        }

        // Extract the package name to check for duplicates
        var package_name: []const u8 = undefined;
        if (std.mem.indexOfAny(u8, dep, "<>=~")) |op_idx| {
            package_name = std.mem.trim(u8, dep[0..op_idx], " ");
        } else if (std.mem.indexOfScalar(u8, dep, '[')) |bracket_idx| {
            package_name = std.mem.trim(u8, dep[0..bracket_idx], " ");
        } else {
            // Just the package name without version
            package_name = std.mem.trim(u8, dep, " ");
        }

        // Check if we've already seen this package
        const is_duplicate = seen_packages.get(package_name) != null;
        if (is_duplicate) {
            std.log.warn("Skipping duplicate package '{s}' with value '{s}' (already included in dependencies)",
                       .{package_name, dep});
            continue;
        }

        // Accept this dependency as valid
        std.log.info("Including dependency: '{s}' (package: '{s}')", .{dep, package_name});
        try valid_deps.append(dep);
        try seen_packages.put(package_name, true);
    }

    // Write the validated dependencies to the requirements file
    std.log.info("Writing {d} validated dependencies to requirements file", .{valid_deps.items.len});
    var req_file = try fs.cwd().createFile(req_rel_path, .{});
    defer req_file.close(); // Only defer once

    if (valid_deps.items.len == 0) {
        std.log.warn("No valid dependencies found! Only writing a comment to requirements file.", .{});
        try req_file.writeAll("# No valid dependencies found\n");
    } else {
        for (valid_deps.items) |dep| {
            try req_file.writer().print("{s}\n", .{dep});
            std.log.debug("Wrote dependency to file: {s}", .{dep});
        }
    }

    // Flush and verify requirements file content
    try req_file.sync();
    std.log.info("Created requirements file at: {s} with {d} validated dependencies", .{req_abs_path, valid_deps.items.len});

    // Read and display the file for debugging
    const req_file_handle = try fs.cwd().openFile(req_rel_path, .{});
    defer req_file_handle.close();
    const req_content_debug = try req_file_handle.readToEndAlloc(allocator, 100 * 1024);
    defer allocator.free(req_content_debug);
    std.log.info("Requirements file contents:\n{s}", .{req_content_debug});

    // Generate setup script with absolute paths
    const script_rel_path = try std.fmt.allocPrint(allocator, "sc_venv/{s}/setup_env.sh", .{env_name});
    defer allocator.free(script_rel_path);

    const script_abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{cwd_path, script_rel_path});
    defer allocator.free(script_abs_path);

    var script_content = std.ArrayList(u8).init(allocator);
    defer script_content.deinit();

    // Script header
    try script_content.appendSlice("#!/bin/sh\n");
    try script_content.appendSlice("set -e\n");  // Exit on error
    try script_content.writer().print("\n# Setup script for '{s}' environment\n\n", .{env_name});

    // Add module command check - skip module commands if not available
    try script_content.appendSlice("# Check if module command exists\n");
    try script_content.appendSlice("if command -v module >/dev/null 2>&1; then\n");
    try script_content.appendSlice("  echo '==> Step 1: Purging all modules'\n");
    try script_content.appendSlice("  module --force purge\n");

    if (env_config.modules.items.len > 0) {
        try script_content.appendSlice("  echo '==> Step 2: Loading required modules'\n");
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
        try script_content.appendSlice("  echo '==> Step 2: No modules to load'\n");
    }

    // Add code to detect packages provided by modules
    try script_content.appendSlice("  echo '==> Checking Python packages provided by modules'\n");
    try script_content.appendSlice("  MODULE_PACKAGES_FILE=$(mktemp)\n");
    try script_content.appendSlice("  python3 -m pip list --format=freeze > $MODULE_PACKAGES_FILE 2>/dev/null || true\n");
    try script_content.appendSlice("  if [ -s $MODULE_PACKAGES_FILE ]; then\n");
    try script_content.appendSlice("    echo '==> Found packages from modules:'\n");
    try script_content.appendSlice("    echo -n '    '\n");
    try script_content.appendSlice("    cat $MODULE_PACKAGES_FILE | sed 's/==.*//' | sort | tr '\n' ',' | sed 's/,/, /g' | sed 's/, $//'\n");
    try script_content.appendSlice("    echo ''\n");
    try script_content.appendSlice("  else\n");
    try script_content.appendSlice("    echo '==> No Python packages detected from modules'\n");
    try script_content.appendSlice("  fi\n");

    try script_content.appendSlice("else\n");
    try script_content.appendSlice("  echo '==> Module command not found, skipping module operations'\n");
    try script_content.appendSlice("  MODULE_PACKAGES_FILE=\"\"\n");
    try script_content.appendSlice("fi\n\n");

    // Step 3: Create virtual environment
    try script_content.appendSlice("echo '==> Step 3: Creating Python virtual environment'\n");
    const venv_dir = try std.fmt.allocPrint(allocator, "{s}/sc_venv/{s}/venv", .{cwd_path, env_name});
    defer allocator.free(venv_dir);
    try script_content.writer().print("{s} -m venv {s}\n\n", .{env_config.python_executable, venv_dir});

    // Step 4: Activate and install dependencies with module package filtering
    try script_content.appendSlice("echo '==> Step 4: Activating environment and installing dependencies'\n");
    try script_content.writer().print("source {s}/bin/activate\n", .{venv_dir});
    try script_content.appendSlice("python -m pip install --upgrade pip\n");

    // Add script to filter requirements.txt and exclude packages from modules
    try script_content.appendSlice("# Filter requirements to exclude packages from modules\n");

    if (force_deps) {
        try script_content.appendSlice("# --force-deps flag detected\n");
        try script_content.appendSlice("echo '==> Using --force-deps: Installing all specified dependencies even if provided by modules'\n");
        try script_content.writer().print("python -m pip install -r {s}\n\n", .{req_abs_path});
    } else {
        try script_content.appendSlice("if [ -n \"$MODULE_PACKAGES_FILE\" ] && [ -s \"$MODULE_PACKAGES_FILE\" ]; then\n");
        try script_content.appendSlice("  echo '==> Filtering requirements to exclude packages from modules'\n");
        try script_content.appendSlice("  FILTERED_REQUIREMENTS=$(mktemp)\n");
        try script_content.appendSlice("  EXCLUDED_PACKAGES=\"\"\n");
        try script_content.writer().print("  while IFS= read -r line || [ -n \"$line\" ]; do\n", .{});
        try script_content.appendSlice("    # Skip empty lines and comments\n");
        try script_content.appendSlice("    if [[ -z \"$line\" || \"$line\" == \"#\"* ]]; then\n");
        try script_content.appendSlice("      echo \"$line\" >> \"$FILTERED_REQUIREMENTS\"\n");
        try script_content.appendSlice("      continue\n");
        try script_content.appendSlice("    fi\n");
        try script_content.appendSlice("    # Extract package name (remove version specifiers)\n");
        try script_content.appendSlice("    package_name=$(echo \"$line\" | sed -E 's/([a-zA-Z0-9_\\-\\.]+)(.*)/\\1/g' | tr '[:upper:]' '[:lower:]')\n");
        try script_content.appendSlice("    # Check if package is in MODULE_PACKAGES_FILE (case insensitive)\n");
        try script_content.appendSlice("    if grep -i -q \"^$package_name==\" \"$MODULE_PACKAGES_FILE\" || grep -i -q \"^$package_name \" \"$MODULE_PACKAGES_FILE\"; then\n");
        try script_content.appendSlice("      echo \"==> Excluding $line (provided by loaded modules)\"\n");
        try script_content.appendSlice("      EXCLUDED_PACKAGES=\"$EXCLUDED_PACKAGES$package_name\n\"\n");
        try script_content.appendSlice("    else\n");
        try script_content.appendSlice("      echo \"$line\" >> \"$FILTERED_REQUIREMENTS\"\n");
        try script_content.appendSlice("    fi\n");
        try script_content.writer().print("  done < {s}\n", .{req_abs_path});
        try script_content.appendSlice("  echo '==> Installing filtered requirements'\n");
        try script_content.appendSlice("  if [ -s \"$FILTERED_REQUIREMENTS\" ]; then\n");
        try script_content.appendSlice("    python -m pip install -r \"$FILTERED_REQUIREMENTS\"\n");
        try script_content.appendSlice("  else\n");
        try script_content.appendSlice("    echo '==> No additional packages to install (all provided by modules)'\n");
        try script_content.appendSlice("  fi\n");
        try script_content.appendSlice("  # Report excluded packages\n");
        try script_content.appendSlice("  if [ -n \"$EXCLUDED_PACKAGES\" ]; then\n");
        try script_content.appendSlice("    echo -e '\n==> Summary of packages excluded (since they are provided by modules):'\n");
        try script_content.appendSlice("    echo -e \"$EXCLUDED_PACKAGES\" | sort | uniq\n");
        try script_content.appendSlice("  fi\n");
        try script_content.appendSlice("  # Cleanup temp files\n");
        try script_content.appendSlice("  rm -f \"$FILTERED_REQUIREMENTS\" \"$MODULE_PACKAGES_FILE\"\n");
        try script_content.appendSlice("else\n");
        try script_content.appendSlice("  # No module packages detected, install requirements as is\n");
        try script_content.writer().print("  python -m pip install -r {s}\n", .{req_abs_path});
        try script_content.appendSlice("fi\n\n");
    }

    // Step 5: Run custom commands if any
    if (env_config.setup_commands != null and env_config.setup_commands.?.items.len > 0) {
        try script_content.appendSlice("echo '==> Step 5: Running custom setup commands'\n");
        for (env_config.setup_commands.?.items) |cmd| {
            try script_content.writer().print("{s}\n", .{cmd});
        }
        try script_content.appendSlice("\n");
    }

    // Step 6: Completion message
    try script_content.appendSlice("echo '==> Setup completed successfully!'\n");
    const activate_abs_path = try std.fmt.allocPrint(allocator, "{s}/sc_venv/{s}/activate.sh", .{cwd_path, env_name});
    defer allocator.free(activate_abs_path);
    try script_content.writer().print("echo 'To activate this environment, run: source {s}'\n", .{activate_abs_path});

    // Write script to file
    var script_file = try fs.cwd().createFile(script_rel_path, .{});
    defer script_file.close();
    try script_file.writeAll(script_content.items);
    try script_file.chmod(0o755);  // Make executable

    // Execute script
    std.log.info("Running setup script from {s}...", .{script_abs_path});
    const argv = [_][]const u8{"/bin/sh", script_abs_path};
    var child = std.process.Child.init(&argv, allocator);
    // Set stdout and stderr to inherit from parent process for real-time output
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    // Wait for the script to complete
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.log.err("Setup script failed with exit code: {d}", .{term.Exited});

        // Display the content of the setup script for debugging
        std.log.info("Displaying setup script content for debugging:", .{});
        try fs.cwd().access(script_rel_path, .{}); // Check if file still exists
        const script_content_debug = try fs.cwd().readFileAlloc(allocator, script_rel_path, 1024 * 1024);
        defer allocator.free(script_content_debug);
        std.io.getStdOut().writer().print("\n----- Setup Script Content -----\n{s}\n-----------------------------\n", .{script_content_debug}) catch {};

        return ZenvError.ProcessError;
    }

    std.log.info("Environment setup completed successfully.", .{});
}

pub fn handleActivateCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) void {
     const env_config = getAndValidateEnvironment(allocator, config, args, handleErrorFn) orelse return;
     const env_name = args[2];

     // Get absolute path of current working directory
     var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
     const cwd_path = std.fs.cwd().realpath(".", &abs_path_buf) catch |err| {
         std.log.err("Could not get current working directory: {s}", .{@errorName(err)});
         handleErrorFn(err);
         return;
     };

     const stdout = std.io.getStdOut().writer();

     stdout.print("# To activate environment '{s}', run the following commands:\n", .{env_name}) catch {};
     stdout.print("# ---------------------------------------------------------\n", .{}) catch {};
     stdout.print("# Option 1: Use the activation script (recommended)\n", .{}) catch {};
     stdout.print("source {s}/sc_venv/{s}/activate.sh\n\n", .{cwd_path, env_name}) catch {};

     stdout.print("# Option 2: Manual activation\n", .{}) catch {};
     // Suggest checking for module command before using it
     stdout.print("if command -v module >/dev/null 2>&1; then\n", .{}) catch {};
     // Suggest purging first for clean state
     stdout.print("  module --force purge\n", .{}) catch {};

     // Print module load commands with a clear list first
     if (env_config.modules.items.len > 0) {
         var modules_list = std.ArrayList(u8).init(allocator);
         defer modules_list.deinit();

         for (env_config.modules.items, 0..) |module_name, i| {
             if (i > 0) {
                 modules_list.appendSlice(", ") catch {};
             }
             modules_list.appendSlice(module_name) catch {};
         }

         stdout.print("  echo 'Loading modules: {s}'\n", .{modules_list.items}) catch {};

         // Print individual load commands
         for (env_config.modules.items) |module_name| {
             stdout.print("  module load {s}\n", .{module_name}) catch {};
         }
     } else {
         stdout.print("  echo 'No modules to load'\n", .{}) catch {};
     }

     stdout.print("else\n", .{}) catch {};
     stdout.print("  echo 'Module command not available, skipping module operations'\n", .{}) catch {};
     stdout.print("fi\n", .{}) catch {};

     // Print virtual environment activation with absolute path
     stdout.print("source {s}/sc_venv/{s}/venv/bin/activate\n", .{cwd_path, env_name}) catch {};

     // Print custom environment variables
     var vars_iter = env_config.custom_activate_vars.iterator();
     while (vars_iter.next()) |entry| {
         // Basic shell escaping (might need more robust escaping for complex values)
         const escaped_value = entry.value_ptr.*; // TODO: Implement proper shell escaping if needed
         stdout.print("export {s}='{s}'\n", .{entry.key_ptr.*, escaped_value}) catch {};
     }
     stdout.print("# ---------------------------------------------------------\n", .{}) catch {};
     if (env_config.description) |desc| {
        stdout.print("# Description: {s}\n", .{desc}) catch {};
     }
     stdout.print("# Target Machine: {s}\n", .{env_config.target_machine}) catch {};
}

fn createActivationScript(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8) !void {
    std.log.info("Creating activation script for '{s}'...", .{env_name});

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try std.fs.cwd().realpath(".", &abs_path_buf);

    // Generate the activation script with absolute path
    const script_rel_path = try std.fmt.allocPrint(allocator, "sc_venv/{s}/activate.sh", .{env_name});
    defer allocator.free(script_rel_path);

    const script_abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{cwd_path, script_rel_path});
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
    const venv_path = try std.fmt.allocPrint(allocator, "{s}/sc_venv/{s}/venv", .{cwd_path, env_name});
    defer allocator.free(venv_path);
    try script_content.writer().print("source {s}/bin/activate\n\n", .{venv_path});

    // Custom environment variables
    if (env_config.custom_activate_vars.count() > 0) {
        try script_content.appendSlice("# Set custom environment variables\n");
        var vars_iter = env_config.custom_activate_vars.iterator();
        while (vars_iter.next()) |entry| {
            try script_content.writer().print("export {s}=\"{s}\"\n", .{entry.key_ptr.*, entry.value_ptr.*});
        }
        try script_content.appendSlice("\n");
    }

    // Print success message
    if (env_config.description) |desc| {
        try script_content.writer().print("echo \"Environment '{s}' activated: {s}\"\n", .{env_name, desc});
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
    try script_file.chmod(0o755);  // Make executable

    std.log.info("Activation script created at {s}", .{script_abs_path});
}

pub fn handleListCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    // _ = allocator; // Not using allocator directly here yet - Used later
    // _ = handleErrorFn; // Not using error handling here yet - Used later

    const stdout = std.io.getStdOut().writer();
    const list_all = args.len > 2 and std.mem.eql(u8, args[2], "--all");

    var current_hostname: ?[]const u8 = null;
    if (!list_all) {
        // Only get hostname if we need to filter
        current_hostname = config_module.ZenvConfig.getHostname(allocator) catch |err| {
            std.log.warn("Could not determine current hostname for filtering: {s}", .{@errorName(err)});
            // Proceed to list all if hostname fails? Or error out? For now, list all.
             handleErrorFn(err); // Report error
             return; // Exit if hostname is required for filtering
        };
       defer if (current_hostname) |h| allocator.free(h);
    }


    stdout.print("Available zenv environments:\n", .{}) catch {};
    stdout.print("----------------------------\n", .{}) catch {};

    var iter = config.environments.iterator();
    var count: usize = 0;
    while (iter.next()) |entry| {
        const env_name = entry.key_ptr.*;
        const env_config = entry.value_ptr.*;

        // Filter by target machine if not '--all' and hostname was found
        if (!list_all and current_hostname != null) {
             if (!std.mem.eql(u8, current_hostname.?, env_config.target_machine)) {
                 continue; // Skip environment if target machine doesn't match
             }
        }

        // Print environment name and target machine
        stdout.print("- {s} (Target: {s}", .{ env_name, env_config.target_machine}) catch {};
        // Optionally print description
        if (env_config.description) |desc| {
            stdout.print(" - {s}", .{desc}) catch {};
        }
        stdout.print(")\n", .{}) catch {};
        count += 1;
    }
     stdout.print("----------------------------\n", .{}) catch {};
      if (count == 0) {
          if (!list_all and current_hostname != null) {
              stdout.print("No environments found configured for the current machine ('{s}'). Use 'zenv list --all' to see all configured environments.\n", .{current_hostname.?}) catch {};
          } else {
              stdout.print("No environments found in the configuration file.\n", .{}) catch {};
          }
      } else {
          if (!list_all and current_hostname != null) {
              stdout.print("Found {d} environment(s) for the current machine ('{s}').\n", .{count, current_hostname.?}) catch {};
          } else {
              stdout.print("Found {d} environment(s) total.\n", .{count}) catch {};
          }
      }
}

// Helper function placeholder for shell escaping (replace with robust implementation)
// fn escapeForShell(allocator: Allocator, input: []const u8) ![]const u8 {
//     // Basic example: replace single quotes
//     // A real implementation needs to handle various special characters
//     var escaped = ArrayList(u8).init(allocator);
//     defer escaped.deinit();
//     try escaped.append('\'');
//     for (input) |char| {
//         if (char == '\'') {
//             try escaped.appendSlice("'\\\''"); // Replace ' with '\''
//         } else {
//             try escaped.append(char);
//         }
//     }
//      try escaped.append('\'');
//     return escaped.toOwnedSlice();
// }
