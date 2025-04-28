const std = @import("std");
const config_module = @import("utils/config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const EnvironmentRegistry = config_module.EnvironmentRegistry;
const errors = @import("utils/errors.zig");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;

pub fn handleSetupCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    registry: *EnvironmentRegistry,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) anyerror!void {
    const env_config = utils.getAndValidateEnvironment(allocator, config, args, handleErrorFn) orelse return;
    const env_name = args[2];

    // Check for --force-deps flag
    var force_deps = false;
    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--force-deps")) {
            force_deps = true;
            std.log.info("Force dependencies flag detected. User-specified dependencies will override module-provided packages.", .{});
            break;
        }
    }

    const display_target = if (env_config.target_machines.items.len > 0) env_config.target_machines.items[0] else "any";
    std.log.info("Setting up environment: {s} (Target: {s})", .{ env_name, display_target });

    // 1. Combine Dependencies
    var all_required_deps = std.ArrayList([]const u8).init(allocator);
    // Track ownership of item strings properly
    var deps_need_cleanup = true;
    defer {
        if (deps_need_cleanup) {
            // We need to free duped lines from parseRequirementsTxt if they exist
            for (all_required_deps.items) |item| {
                // Free any item that was duped by utility functions
                if (!utils.isConfigProvidedDependency(env_config, item)) {
                    allocator.free(item);
                }
            }
            all_required_deps.deinit();
        }
    }

    // Add dependencies from config
    if (env_config.dependencies.items.len > 0) {
        std.log.info("Adding {d} dependencies from configuration:", .{env_config.dependencies.items.len});
        for (env_config.dependencies.items) |dep| {
            std.log.info("  - Config dependency: {s}", .{dep});
            // Don't dupe here, assume config owns them or they are literals
            try all_required_deps.append(dep);
        }
    } else {
        std.log.info("No dependencies specified in configuration.", .{});
    }

    // Add dependencies from requirements file if specified
    if (env_config.requirements_file) |req_file| {
        // Check if the specified requirements file actually exists
        std.fs.cwd().access(req_file, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.log.err("Requirements file specified in configuration ('{s}') not found.", .{req_file});
                handleErrorFn(err); // Use the original file not found error
                return; // Exit setup command
            } else {
                 // Handle other potential access errors
                 std.log.err("Error accessing requirements file '{s}': {s}", .{ req_file, @errorName(err) });
                 handleErrorFn(err);
                 return;
            }
        };

        // Log the absolute path for debugging
        var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = std.fs.cwd().realpath(req_file, &abs_path_buf) catch |err| {
            std.log.err("Failed to resolve absolute path for requirements file '{s}': {s}", .{ req_file, @errorName(err) });
            // handleErrorFn(err); // Or map to ZenvError
            return err; // Propagate error
        };
        std.log.info("Reading dependencies from file: '{s}' (absolute path: '{s}')", .{ req_file, abs_path });

        // Read the file content
        const req_content = std.fs.cwd().readFileAlloc(allocator, req_file, 1 * 1024 * 1024) catch |err| { // Increased size limit
            std.log.err("Failed to read file '{s}': {s}", .{ req_file, @errorName(err) });
            handleErrorFn(error.PathResolutionFailed); // Use specific error
            return; // Exit setup command
        };
        defer allocator.free(req_content); // Content freed after parsing finishes

        std.log.info("Successfully read file ({d} bytes). Parsing dependencies...", .{req_content.len});

        // Determine file type and parse
        const is_toml = std.mem.endsWith(u8, req_file, ".toml");
        var req_file_dep_count: usize = 0;

        if (is_toml) {
            std.log.info("Detected TOML file format, parsing as pyproject.toml", .{});
            req_file_dep_count = try utils.parsePyprojectToml(allocator, req_content, &all_required_deps);
        } else {
            std.log.info("Parsing as requirements.txt format", .{});
            // Use the new utility function
            req_file_dep_count = try utils.parseRequirementsTxt(allocator, req_content, &all_required_deps);
        }

        if (req_file_dep_count > 0) {
            std.log.info("Added {d} dependencies from file '{s}'", .{ req_file_dep_count, req_file });
        } else {
            std.log.warn("No valid dependencies found in file '{s}'", .{req_file});
        }
    } else {
        std.log.info("No requirements file specified in configuration.", .{});
    }

    std.log.info("Total combined dependencies before validation: {d}", .{all_required_deps.items.len});

    // Get base_dir from config
    const base_dir = config.base_dir;

    // 2. Create venv base directory structure using base_dir
    try utils.createVenvDir(allocator, base_dir, env_name);

    // Convert ArrayList to owned slice for more efficient processing
    const deps_slice = try all_required_deps.toOwnedSlice();
    deps_need_cleanup = false; // We've taken ownership of the items, don't clean up in defer block
    defer {
        // Clean up individually owned strings but not config-provided ones
        for (deps_slice) |item| {
            if (!utils.isConfigProvidedDependency(env_config, item)) {
                allocator.free(item);
            }
        }
        allocator.free(deps_slice); // Free the slice itself
    }

    // 3. Perform the main environment setup using the utility function
    utils.setupEnvironment(allocator, env_config, env_name, base_dir, deps_slice, force_deps) catch |err| {
        if (err == error.ModuleLoadError) {
            // For module load errors, we don't want to show a stack trace
            // Just output the error and exit
            std.io.getStdErr().writer().print("Error: {s}\n", .{@errorName(err)}) catch {};
            std.process.exit(1);
        }
        return err; // Propagate other errors
    };

    // 4. Create the final activation script (using a separate utility)
    try utils.createActivationScript(allocator, env_config, env_name, base_dir);

    // 5. Register the environment in the global registry
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = std.fs.cwd().realpath(".", &abs_path_buf) catch |err| {
        std.log.err("Could not get current working directory: {s}", .{@errorName(err)});
        handleErrorFn(err);
        return;
    };

    try registry.register(env_name, cwd_path, base_dir, env_config.description, env_config.target_machines.items);
    try registry.save();

    std.log.info("Environment '{s}' setup complete and registered in global registry.", .{env_name});
    std.log.info("You can now activate it from any directory with: source $(zenv activate {s})", .{env_name});
}

// setupEnvironment moved to utils.zig

pub fn handleActivateCommand(
    registry: *const EnvironmentRegistry,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        std.io.getStdErr().writer().print("Error: Missing environment name or ID argument.\n", .{}) catch {};
        std.io.getStdErr().writer().print("Usage: zenv activate <env_name|env_id>\n", .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const identifier = args[2];

    // Look up environment using the utility function
    const entry = utils.lookupRegistryEntry(registry, identifier, handleErrorFn) orelse return;

    // Get venv_path from registry entry
    const venv_path = entry.venv_path;

    const writer = std.io.getStdOut().writer();

    // Output the absolute path to our custom activation script
    writer.print("{s}/activate.sh\n", .{venv_path}) catch |e| {
        std.log.err("Error writing to stdout: {s}", .{@errorName(e)});
        return;
    };
}

pub fn handleListCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: [][]const u8,
) void {
    const stdout = std.io.getStdOut().writer();
    const list_all = args.len > 2 and std.mem.eql(u8, args[2], "--all");

    var current_hostname: ?[]const u8 = null;
    var hostname_allocd = false; // Track if hostname was allocated
    var use_hostname_filter = !list_all; // New variable to track if we should use hostname filter

    if (use_hostname_filter) {
        // Get hostname directly using the utility function
        current_hostname = utils.getSystemHostname(allocator) catch |err| {
            std.log.warn("Could not determine current hostname for filtering: {s}. Listing all environments.", .{@errorName(err)});
            use_hostname_filter = false;
            current_hostname = null;
            hostname_allocd = false; // Ensure flag is false if hostname fetch failed
            // Explicitly return void to match the catch expression type
            return void{};
        };
        // This part only runs if the catch block wasn't executed
        if (current_hostname != null) {
            hostname_allocd = true; // Mark that we need to free it
        }
    }
    // Ensure hostname is freed if allocated
    defer if (hostname_allocd and current_hostname != null) allocator.free(current_hostname.?);

    stdout.print("Available zenv environments:\n", .{}) catch {};

    var count: usize = 0;
    for (registry.entries.items) |entry| {
        const env_name = entry.env_name;
        const target_machines_str = entry.target_machines_str; // Renamed

        // Filter by target machine if requested and hostname was successfully obtained
        if (use_hostname_filter and current_hostname != null) {
            // Check if the current hostname matches ANY of the target patterns
            var matches_any_target = false;
            var targets_iter = std.mem.splitScalar(u8, target_machines_str, ','); // Use the renamed variable
            while (targets_iter.next()) |target_pattern_raw| {
                const target_pattern = std.mem.trim(u8, target_pattern_raw, " ");
                if (target_pattern.len == 0) continue; // Skip empty patterns

                if (utils.checkHostnameMatch(current_hostname.?, target_pattern)) {
                    matches_any_target = true;
                    break; // Found a match, no need to check further patterns for this entry
                }
            }

            if (!matches_any_target) {
                continue; // Skip this environment if no pattern matched
            }
        }

        // Get short ID (first 7 characters)
        const short_id = if (entry.id.len >= 7) entry.id[0..7] else entry.id;

        // Print environment name, short ID, and target machine string
        stdout.print("- {s} (ID: {s}... Target: {s}", .{ env_name, short_id, target_machines_str }) catch {}; // Renamed

        // Optionally print description
        if (entry.description) |desc| {
            stdout.print(" - {s}", .{desc}) catch {};
        }
        // Print project and venv paths
        stdout.print(")\n  [Project: {s}]\n  [Venv:    {s}]\n", .{entry.project_dir, entry.venv_path}) catch {};

        // Print full ID on a separate line for reference
        // stdout.print("  Full ID: {s} (you can use the first 7+ characters)\n", .{entry.id}) catch {};
        count += 1;
    }

    // Print summary message
    if (count == 0) {
        if (!list_all and current_hostname != null) {
            stdout.print("No environments found configured for the current machine ('{s}'). Use 'zenv list --all' to see all registered environments.\n", .{current_hostname.?}) catch {};
        } else if (!list_all and current_hostname == null) {
            stdout.print("No environments found. (Could not determine current hostname for filtering).\n", .{}) catch {};
        } else { // Listing all or hostname failed
            stdout.print("No environments found in the registry. Use 'zenv register <env_name>' to register environments.\n", .{}) catch {};
        }
    } else {
        if (!list_all and current_hostname != null) {
            stdout.print("Found {d} environment(s) for the current machine ('{s}').\n", .{ count, current_hostname.? }) catch {};
        } else { // Listing all or hostname failed
            stdout.print("Found {d} total registered environment(s).\n", .{count}) catch {};
        }
    }
}
pub fn handleRegisterCommand(
    allocator: Allocator,
    // config: *const ZenvConfig, // Config is no longer passed in, load it here
    registry: *EnvironmentRegistry,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        std.io.getStdErr().writer().print("Error: Missing environment name argument.\n", .{}) catch {};
        std.io.getStdErr().writer().print("Usage: zenv register <env_name>\n", .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const env_name = args[2];

    // Load the configuration for the current directory to find base_dir
    const config_path = "zenv.json";
    var config = config_module.ZenvConfig.parse(allocator, config_path) catch |err| {
        // If config is missing or invalid, we cannot determine the base_dir
        std.log.err("Failed to load or parse '{s}' in current directory: {s}", .{config_path, @errorName(err)});
        std.log.err("Cannot register environment without valid configuration.", .{});
        handleErrorFn(err);
        return;
    };
    // Ensure config is deinitialized even if subsequent operations fail
    defer config.deinit();

    // Validate that the environment exists in the config
    // Note: getAndValidateEnvironment needs a *const pointer
    const env_config = utils.getAndValidateEnvironment(allocator, &config, args, handleErrorFn) orelse return;

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = std.fs.cwd().realpath(".", &abs_path_buf) catch |err| {
        std.log.err("Could not get current working directory: {s}", .{@errorName(err)});
        handleErrorFn(err);
        return;
    };

    // Get the base_dir from the loaded config
    const base_dir = config.base_dir;

    // Register the environment in the global registry, passing base_dir
    registry.register(env_name, cwd_path, base_dir, env_config.description, env_config.target_machines.items) catch |err| {
        std.log.err("Failed to register environment: {s}", .{@errorName(err)});
        handleErrorFn(err);
        return;
    };

    // Save the registry
    registry.save() catch |err| {
        std.log.err("Failed to save registry: {s}", .{@errorName(err)});
        handleErrorFn(err);
        return;
    };

    std.io.getStdOut().writer().print("Environment '{s}' registered successfully.\n", .{env_name}) catch {};
    std.io.getStdOut().writer().print("You can now activate it from any directory with: source $(zenv activate {s})\n", .{env_name}) catch {};
}

// Handle cd command - outputs the project directory path for a given environment
pub fn handleCdCommand(
    registry: *const EnvironmentRegistry,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        std.io.getStdErr().writer().print("Error: Missing environment name or ID argument.\n", .{}) catch {};
        std.io.getStdErr().writer().print("Usage: zenv cd <env_name|env_id>\n", .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const identifier = args[2];

    // Check if this might be a partial ID (7+ characters)
    const is_potential_id_prefix = identifier.len >= 7 and identifier.len < 40;

    // Look up environment in registry
    const entry = registry.lookup(identifier) orelse {
        // Special handling for ambiguous ID prefixes
        if (is_potential_id_prefix) {
            // Count how many environments have this ID prefix
            var matching_envs = std.ArrayList([]const u8).init(registry.allocator);
            defer matching_envs.deinit();
            var match_found = false;

            for (registry.entries.items) |reg_entry| {
                if (reg_entry.id.len >= identifier.len and std.mem.eql(u8, reg_entry.id[0..identifier.len], identifier)) {
                    match_found = true;
                    matching_envs.append(reg_entry.env_name) catch continue;
                }
            }

            if (match_found and matching_envs.items.len > 1) {
                std.io.getStdErr().writer().print("Error: Ambiguous ID prefix '{s}' matches multiple environments:\n", .{identifier}) catch {};
                for (matching_envs.items) |env_name| {
                    std.io.getStdErr().writer().print("  - {s}\n", .{env_name}) catch {};
                }
                std.io.getStdErr().writer().print("Please use more characters to make the ID unique.\n", .{}) catch {};
                handleErrorFn(error.AmbiguousIdentifier);
                return;
            }
        }

        // Default error for no matches
        std.io.getStdErr().writer().print("Error: Environment with name or ID '{s}' not found in registry.\n", .{identifier}) catch {};
        std.io.getStdErr().writer().print("Use 'zenv list' to see all available environments with their IDs.\n", .{}) catch {};
        handleErrorFn(error.EnvironmentNotRegistered);
        return;
    };

    // Get project directory from registry entry
    const project_dir = entry.project_dir;

    const writer = std.io.getStdOut().writer();

    // Output just the project directory path
    writer.print("{s}\n", .{project_dir}) catch |e| {
        std.log.err("Error writing to stdout: {s}", .{@errorName(e)});
        return;
    };
}

pub fn handleDeregisterCommand(
    registry: *EnvironmentRegistry,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        std.io.getStdErr().writer().print("Error: Missing environment name argument.\n", .{}) catch {};
        std.io.getStdErr().writer().print("Usage: zenv deregister <env_name>\n", .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const env_name = args[2];

    // Look up environment in registry first to check if it exists
    _ = registry.lookup(env_name) orelse {
        std.io.getStdErr().writer().print("Error: Environment '{s}' not found in registry.\n", .{env_name}) catch {};
        handleErrorFn(error.EnvironmentNotRegistered);
        return;
    };

    // Remove the environment from the registry
    if (registry.deregister(env_name)) {
        // Save the registry
        registry.save() catch |err| {
            std.log.err("Failed to save registry: {s}", .{@errorName(err)});
            handleErrorFn(err);
            return;
        };

        std.io.getStdOut().writer().print("Environment '{s}' unregistered successfully.\n", .{env_name}) catch {};
    } else {
        std.io.getStdErr().writer().print("Error: Failed to unregister environment '{s}'.\n", .{env_name}) catch {};
        handleErrorFn(error.EnvironmentNotRegistered);
    }
}

/// Handles the `init` command by creating a new zenv.json template in the current directory
pub fn handleInitCommand(allocator: std.mem.Allocator) void {
    const cwd = std.fs.cwd();
    const config_path = "zenv.json";

    // Check if file exists
    const file_exists = blk: {
        cwd.access(config_path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                std.io.getStdErr().writer().print("Error accessing current directory: {s}\n", .{@errorName(err)}) catch {};
                std.process.exit(1);
            }
            // File doesn't exist
            break :blk false;
        };
        break :blk true;
    };

    if (file_exists) {
        std.io.getStdErr().writer().print("Error: {s} already exists. Please remove or rename it first.\n", .{config_path}) catch {};
        std.process.exit(1);
    }

    // Use a static string as the default target_machine - now supporting patterns
    const hostname = "localhost";

    // Create template content with pattern examples
    const template_content = std.fmt.allocPrint(allocator,
        \\{{
        \\  "base_dir": "zenv",
        \\  "default_env": {{
        \\    "target_machines": ["{s}"],
        \\    "description": "Default environment",
        \\    "python_executable": "python3",
        \\    "modules": [],
        \\    "dependencies": [],
        \\    "requirements_file": "requirements.txt",
        \\    "custom_activate_vars": {{
        \\      "CUSTOM_VAR": "custom_value"
        \\    }},
        \\    "setup_commands": [
        \\      "echo 'Environment setup complete!'"
        \\    ]
        \\  }},
        \\  "dev_env": {{
        \\    "target_machines": ["{s}", "any"],
        \\    "description": "Development environment with additional tools",
        \\    "python_executable": "python3",
        \\    "modules": [],
        \\    "dependencies": [
        \\      "pytest",
        \\      "black"
        \\    ],
        \\    "requirements_file": "pyproject.toml",
        \\    "custom_activate_vars": {{
        \\      "DEVELOPMENT": "true",
        \\    }},
        \\    "setup_commands": [
        \\      "echo 'Development environment setup complete!'"
        \\    ]
        \\  }}
        \\}}
        \\
    , .{ hostname, hostname }) catch |err| {
        std.io.getStdErr().writer().print("Error creating template content: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    defer allocator.free(template_content);

    // Write template to file
    const file = cwd.createFile(config_path, .{}) catch |err| {
        std.io.getStdErr().writer().print("Error creating {s}: {s}\n", .{ config_path, @errorName(err) }) catch {};
        std.process.exit(1);
    };
    defer file.close();

    file.writeAll(template_content) catch |err| {
        std.io.getStdErr().writer().print("Error writing to {s}: {s}\n", .{ config_path, @errorName(err) }) catch {};
        std.process.exit(1);
    };

    std.io.getStdOut().writer().print("Created zenv.json template in the current directory.\n", .{}) catch {};
    std.io.getStdOut().writer().print("Edit it to customize your environments.\n", .{}) catch {};
    // std.io.getStdOut().writer().print("\nNOTE: 'target_machine' now supports pattern matching:\n", .{}) catch {};
    // std.io.getStdOut().writer().print("  - Use '*' to match any characters, e.g., 'jrlogin*' matches all login nodes\n", .{}) catch {};
    // std.io.getStdOut().writer().print("  - Use '?' to match a single character, e.g., 'node0?' matches node01-09\n", .{}) catch {};
    // std.io.getStdOut().writer().print("  - Use domain components like 'jureca' to match 'jrlogin08.jureca'\n", .{}) catch {};
}
