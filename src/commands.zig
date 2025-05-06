const std = @import("std");
const Allocator = std.mem.Allocator;

const CommandFlags = @import("utils/flags.zig").CommandFlags;
const env = @import("utils/environment.zig");
const deps = @import("utils/parse_deps.zig");
const aux = @import("utils/auxiliary.zig");
const python = @import("utils/python.zig");
const configurations = @import("utils/config.zig");
const output = @import("utils/output.zig");
const ZenvConfig = configurations.ZenvConfig;
const EnvironmentConfig = configurations.EnvironmentConfig;
const EnvironmentRegistry = configurations.EnvironmentRegistry;

pub fn handleInitCommand(
    allocator: Allocator,
) void {
    const cwd = std.fs.cwd();
    const config_path = "zenv.json";

    // Check if file exists
    const file_exists = blk: {
        cwd.access(config_path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                output.printError("Accessing current directory: {s}", .{@errorName(err)}) catch {};
                std.process.exit(1);
            }
            // File doesn't exist
            break :blk false;
        };
        break :blk true;
    };

    if (file_exists) {
        output.printError("{s} already exists. Please remove or rename it first.", .{config_path}) catch {};
        std.process.exit(1);
    }

    // Use a static string as the default target_machine
    const hostname = "*";

    // Import the template module for JSON
    const template_json = @import("utils/template_json.zig");

    // Create a map for template replacements
    var replacements = std.StringHashMap([]const u8).init(allocator);
    defer replacements.deinit();

    // Add replacements for the template
    replacements.put("HOSTNAME", hostname) catch |err| {
        output.printError("Creating replacements: {s}", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };

    // Process the template using our JSON template utility
    const processed_content = template_json.createJsonConfigFromTemplate(allocator, replacements) catch |err| {
        output.printError("Processing template: {s}", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    defer allocator.free(processed_content);

    // Write template to file
    const file = cwd.createFile(config_path, .{}) catch |err| {
        output.printError("Creating {s}: {s}", .{ config_path, @errorName(err) }) catch {};
        std.process.exit(1);
    };
    defer file.close();

    file.writeAll(processed_content) catch |err| {
        output.printError("Writing to {s}: {s}", .{ config_path, @errorName(err) }) catch {};
        std.process.exit(1);
    };

    output.print("Created zenv.json template in the current directory.", .{}) catch {};
    output.print("Edit it to customize your environments.", .{}) catch {};
}

pub fn handleSetupCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) anyerror!void {
    // Create an arena allocator for temporary allocations
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const temp_allocator = temp_arena.allocator();

    // Parse command-line flags
    const flags = CommandFlags.fromArgs(args);

    // Log the detected flags
    if (flags.force_deps) {
        output.print(
            \\Force dependencies flag detected.
            \\User-specified dependencies will try to override module-provided packages.
        , .{}) catch {};
    }
    if (flags.skip_hostname_check) {
        output.print("No-host flag detected. Bypassing hostname validation.", .{}) catch {};
    }
    if (flags.force_rebuild) {
        output.print("Force rebuild flag detected. Will recreate the virtual environment.", .{}) catch {};
    }

    // Get and validate the environment config
    const env_config = env.getAndValidateEnvironment(allocator, config, args, flags, handleErrorFn) orelse return;
    const env_name = args[2];

    const display_target = if (env_config.target_machines.items.len > 0) env_config.target_machines.items[0] else "any";
    output.print("Setting up environment: {s} (Target: {s})", .{ env_name, display_target }) catch {};

    // 0. Check the availability of modules
    var modules_verified = false;
    if (env_config.modules.items.len > 0) {
        // Use the improved validateModules function
        const modules_available = env.validateModules(allocator, env_config, flags.force_deps) catch |err| {
            output.printError("Failed to validate modules: {s}", .{@errorName(err)}) catch {};
            handleErrorFn(error.ModuleLoadError);
            return;
        };

        if (!modules_available) {
            // Error messages already printed by validateModules
            handleErrorFn(error.ModuleLoadError);
            return;
        }

        output.print("All modules appear to be available.", .{}) catch {};
        modules_verified = true;
    }

    // 1. Combine Dependencies
    var all_required_deps = std.ArrayList([]const u8).init(allocator);
    // Track ownership of item strings properly
    var deps_need_cleanup = true;
    // Defer cleanup if needed
    defer {
        if (deps_need_cleanup) {
            // We need to free duped lines from parseRequirementsTxt if they exist
            for (all_required_deps.items) |item| {
                // Free any item that was duped by utility functions
                if (!deps.isConfigProvidedDependency(env_config, item)) {
                    allocator.free(item);
                }
            }
            all_required_deps.deinit();
        } else {
            // Just deinit the list if we don't need to cleanup individual items
            all_required_deps.deinit();
        }
    }

    // Add dependencies from config
    if (env_config.dependencies.items.len > 0) {
        output.print("Adding {d} dependencies from configuration:", .{env_config.dependencies.items.len}) catch {};
        for (env_config.dependencies.items) |dep| {
            output.print("  - Config dependency: {s}", .{dep}) catch {};
            // Don't dupe here, assume config owns them or they are literals
            try all_required_deps.append(dep);
        }
    } else {
        output.print("No dependencies specified in configuration.", .{}) catch {};
    }

    // Add dependencies from requirements file if specified
    if (env_config.dependency_file) |req_file| {
        // Check if the specified requirements file actually exists
        std.fs.cwd().access(req_file, .{}) catch |err| {
            if (err == error.FileNotFound) {
                output.printError("Requirements file specified in configuration ('{s}') not found.", .{req_file}) catch {};
                handleErrorFn(err); // Use the original file not found error
                return; // Exit setup command
            } else {
                // Handle other potential access errors
                output.printError("Error accessing requirements file '{s}': {s}", .{ req_file, @errorName(err) }) catch {};
                handleErrorFn(err);
                return;
            }
        };

        // Log the absolute path for debugging
        var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = std.fs.cwd().realpath(req_file, &abs_path_buf) catch |err| {
            output.printError("Failed to resolve absolute path for requirements file '{s}': {s}", .{ req_file, @errorName(err) }) catch {};
            // handleErrorFn(err); // Or map to ZenvError
            return err; // Propagate error
        };
        output.print("Reading dependencies from file: '{s}' (absolute path: '{s}')", .{ req_file, abs_path }) catch {};

        // Read the file content - use temp_allocator since we're done with it after parsing
        const req_content = std.fs.cwd().readFileAlloc(temp_allocator, req_file, 1 * 1024 * 1024) catch |err| {
            output.printError("Failed to read file '{s}': {s}", .{ req_file, @errorName(err) }) catch {};
            handleErrorFn(error.PathResolutionFailed); // Use specific error
            return; // Exit setup command
        };
        // No need to defer free because the arena will handle cleanup

        output.print("Successfully read file ({d} bytes). Parsing dependencies...", .{req_content.len}) catch {};

        // Determine file type and parse
        const is_toml = std.mem.endsWith(u8, req_file, ".toml");
        var req_file_dep_count: usize = 0;

        if (is_toml) {
            output.print("Detected TOML file format, parsing as pyproject.toml", .{}) catch {};
            req_file_dep_count = try deps.parsePyprojectToml(allocator, req_content, &all_required_deps);
        } else {
            output.print("Parsing as requirements.txt format", .{}) catch {};
            // Use the new utility function
            req_file_dep_count = try deps.parseRequirementsTxt(allocator, req_content, &all_required_deps);
        }

        if (req_file_dep_count > 0) {
            output.print("Added {d} dependencies from file '{s}'", .{ req_file_dep_count, req_file }) catch {};
        } else {
            output.print("Warning: No valid dependencies found in file '{s}'", .{req_file}) catch {};
        }
    } else {
        output.print("No requirements file specified in configuration.", .{}) catch {};
    }

    // Get base_dir from config
    const base_dir = config.base_dir;

    // Debug output - print the combined dependencies
    output.print("Combined dependency list ({d} items):", .{all_required_deps.items.len}) catch {};
    for (all_required_deps.items) |dep| {
        output.print("  - {s}", .{dep}) catch {};
    }

    // 2. Create venv base directory structure using base_dir
    try aux.setupEnvironmentDirectory(allocator, base_dir, env_name);

    // 3. Install dependencies
    aux.installDependencies(
        allocator,
        env_config,
        env_name,
        base_dir,
        &all_required_deps,
        flags.force_deps,
        flags.force_rebuild,
        modules_verified,
        flags.use_default_python,
        flags.dev_mode,
    ) catch |err| {
        handleErrorFn(err);
        return;
    };
    deps_need_cleanup = false;

    // 4. Create the final activation script (using a separate utility)
    try aux.createActivationScript(allocator, env_config, env_name, base_dir);

    // 5. Register the environment in the global registry
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = std.fs.cwd().realpath(".", &abs_path_buf) catch |err| {
        output.printError("Could not get current working directory: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };

    try registry.register(
        env_name,
        cwd_path,
        base_dir,
        env_config.description,
        env_config.target_machines.items,
    );
    try registry.save();

    output.print(
        \\Environment '{s}' setup complete and registered in global registry.
        \\Usage: source $(zenv activate {s})
    , .{ env_name, env_name }) catch {};
}

pub fn handleActivateCommand(
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError("Missing environment name or ID argument. Usage: zenv activate <name|id>", .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const identifier = args[2];

    const entry = env.lookupRegistryEntry(registry, identifier, handleErrorFn) orelse return;
    const venv_path = entry.venv_path;

    std.io.getStdOut().writer().print("{s}/activate.sh\n", .{venv_path}) catch |e| {
        output.printError("Error writing to stdout: {s}", .{@errorName(e)}) catch {};
        return;
    };
}

pub fn handleListCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) void {
    const stdout = std.io.getStdOut().writer(); // special case for using standard writter
    const list_all = args.len > 2 and std.mem.eql(u8, args[2], "--all");

    var current_hostname: ?[]const u8 = null;
    var hostname_allocd = false; // Track if hostname was allocated
    var use_hostname_filter = !list_all; // New variable to track if we should use hostname filter

    if (use_hostname_filter) {
        // Get hostname directly using the utility function
        current_hostname = env.getSystemHostname(allocator) catch |err| {
            output.print(
                \\Could not determine current hostname for filtering: {s}
            , .{@errorName(err)}) catch {};
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
    // Ensure hostname is freed if allocated using optional chaining
    defer if (hostname_allocd) if (current_hostname) |hostname| allocator.free(hostname);

    // stdout.print("Available zenv environments:\n", .{}) catch {};

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

                if (env.checkHostnameMatch(current_hostname.?, target_pattern)) {
                    matches_any_target = true;
                    break; // Found a match, no need to check further patterns for this entry
                }
            }

            if (!matches_any_target) {
                continue; // Skip this environment if no pattern matched
            }
        }

        // Get short ID (first 7 characters)
        // const short_id = if (entry.id.len >= 7) entry.id[0..7] else entry.id;

        // Print environment name, short ID, and target machine string
        stdout.print("- {s}", .{env_name}) catch {};
        stdout.print("\n  id      : {s}", .{entry.id}) catch {};
        stdout.print("\n  target  : {s}", .{target_machines_str}) catch {};
        stdout.print("\n  project : {s}", .{entry.project_dir}) catch {};
        stdout.print("\n  venv    : {s}", .{entry.venv_path}) catch {};

        // Optionally print description
        if (entry.description) |desc| {
            stdout.print("\n  desc    : {s}\n\n", .{desc}) catch {};
        }

        count += 1;
    }

    // Print summary message
    if (count == 0) {
        if (!list_all and current_hostname != null) {
            stdout.print(
                \\No environments found for the current machine ('{s}')
                \\Use 'zenv list --all' to see all registered environments.
                \\
            , .{current_hostname.?}) catch {};
        } else if (!list_all and current_hostname == null) {
            stdout.print(
                \\No environments found. (Could not determine current hostname).
                \\
            , .{}) catch {};
        } else { // Listing all or hostname failed
            stdout.print(
                \\No environments found in the registry
                \\Use 'zenv setup <name>' OR 'zenv register <name>' to register environments
                \\
            , .{}) catch {};
        }
    } else {
        if (!list_all and current_hostname != null) {
            stdout.print(
                \\Found {d} environment(s) for the current machine ('{s}')
                \\
            , .{ count, current_hostname.? }) catch {};
        } else { // Listing all or hostname failed
            stdout.print(
                \\Found {d} total registered environment(s)
                \\
            , .{count}) catch {};
        }
    }
}

pub fn handleRegisterCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError("Missing environment name argument. Usage: zenv register <name>", .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const env_name = args[2];

    const flags = CommandFlags.fromArgs(args);

    // Log flags if they're set
    if (flags.skip_hostname_check) {
        output.print("'--no-host' flag detected. Skipping hostname validation.", .{}) catch {};
    }

    // Get the environment config directly without re-parsing validation
    const env_config = config.getEnvironment(env_name) orelse {
        output.printError("Environment '{s}' not found in configuration.", .{env_name}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    };

    // Validate the environment config
    if (ZenvConfig.validateEnvironment(env_config, env_name)) |err| {
        output.printError("Invalid configuration for '{s}': {s}", .{ env_name, @errorName(err) }) catch {};
        handleErrorFn(err);
        return;
    }

    // Check hostname validation if needed
    if (!flags.skip_hostname_check) {
        const hostname = env.getSystemHostname(allocator) catch |err| {
            output.printError("Failed to get current hostname: {s}", .{@errorName(err)}) catch {};
            handleErrorFn(err);
            return;
        };
        defer allocator.free(hostname);

        // Use the dedicated function for hostname validation
        const hostname_matches = env.validateEnvironmentForMachine(env_config, hostname);

        if (!hostname_matches) {
            output.printError(
                \\Current machine ('{s}') does not match target machines specified for environment '{s}'
                \\Use '--no-host' flag to bypass this check if needed
            , .{ hostname, env_name }) catch {};
            handleErrorFn(error.TargetMachineMismatch);
            return;
        }
    }

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = std.fs.cwd().realpath(".", &abs_path_buf) catch |err| {
        output.printError("Could not get current working directory: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };

    // Get the base_dir from the loaded config
    const base_dir = config.base_dir;

    // Register the environment in the global registry, passing base_dir
    registry.register(
        env_name,
        cwd_path,
        base_dir,
        env_config.description,
        env_config.target_machines.items,
    ) catch |err| {
        output.printError("Failed to register environment: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };

    // Save the registry
    registry.save() catch |err| {
        output.printError("Failed to save registry: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };

    output.print(
        \\Environment '{s}' registered successfully.
        \\Usage: source $(zenv activate {s})
    , .{ env_name, env_name }) catch {};
}

pub fn handleDeregisterCommand(
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError(
            \\Missing environment name or ID argument.
            \\Usage: zenv deregister <name|id>
        , .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const identifier = args[2];

    // Look up environment in registry first to check if it exists
    // We use lookupRegistryEntry utility which handles error reporting for ambiguous IDs
    const entry = env.lookupRegistryEntry(registry, identifier, handleErrorFn) orelse return;

    // Store name for the success message - make a copy to ensure it remains valid
    const env_name = registry.allocator.dupe(u8, entry.env_name) catch |err| {
        output.printError("Failed to duplicate environment name: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };
    defer registry.allocator.free(env_name);

    // Remove the environment from the registry using the name
    // We pass the original identifier which could be a name or ID
    if (registry.deregister(identifier)) {
        // Save the registry
        registry.save() catch |err| {
            output.printError("Failed to save registry: {s}", .{@errorName(err)}) catch {};
            handleErrorFn(err);
            return;
        };

        output.print("Environment '{s}' unregistered successfully.", .{env_name}) catch {};
    } else {
        output.printError("Failed to unregister environment '{s}'.", .{env_name}) catch {};
        handleErrorFn(error.EnvironmentNotRegistered);
    }
}

pub fn handleCdCommand(
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError(
            \\Missing environment name or ID argument
            \\Usage: zenv cd <name|id>
        , .{}) catch {};
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
            var isSameId = false;

            for (registry.entries.items) |reg_entry| {
                isSameId = std.mem.eql(u8, reg_entry.id[0..identifier.len], identifier);
                if (reg_entry.id.len >= identifier.len and isSameId) {
                    match_found = true;
                    matching_envs.append(reg_entry.env_name) catch continue;
                }
            }

            if (match_found and matching_envs.items.len > 1) {
                output.printError("ID prefix '{s}' matches multiple environments:", .{identifier}) catch {};
                for (matching_envs.items) |env_name| {
                    output.printError("  - {s}", .{env_name}) catch {};
                }
                output.printError("Please use more characters to make the ID unique.", .{}) catch {};
                handleErrorFn(error.AmbiguousIdentifier);
                return;
            }
        }

        // Default error for no matches
        output.printError(
            \\Environment with name or ID '{s}' not found in registry
            \\use 'zenv list --all' to list all available environments
        , .{identifier}) catch {};
        handleErrorFn(error.EnvironmentNotRegistered);
        return;
    };

    // Get project directory from registry entry
    const project_dir = entry.project_dir;

    // Output just the project directory path
    std.io.getStdOut().writer().print("{s}\n", .{project_dir}) catch |e| {
        output.printError("Error writing to stdout: {s}", .{@errorName(e)}) catch {};
        return;
    };
}

pub fn handlePythonCommand(
    allocator: Allocator,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) !void {
    // Check if we have a subcommand
    if (args.len < 3) {
        output.printError("Missing subcommand for 'python' command", .{}) catch {};
        output.print("Available subcommands: install, use, list", .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "install")) {
        // Python install [version] command
        var version: ?[]const u8 = null;
        if (args.len >= 4) {
            version = args[3];
            output.print("Installing Python version: {s}", .{version.?}) catch {};
        } else {
            output.print("No version specified, will install default version", .{}) catch {};
        }

        // Install Python
        python.installPython(allocator, version) catch |err| {
            output.printError("Python installation failed: {s}", .{@errorName(err)}) catch {};
            handleErrorFn(err);
            return;
        };
    } else if (std.mem.eql(u8, subcommand, "use")) {
        // Python use [version] command
        if (args.len < 4) {
            output.printError("Missing version argument for 'python use' command", .{}) catch {};
            output.print("Usage: zenv python use <version>", .{}) catch {};
            handleErrorFn(error.ArgsError);
            return;
        }

        const version = args[3];
        try python.setDefaultPythonPath(allocator, version);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        // Python list command - list all installed versions
        try python.listInstalledVersions(allocator);
    } else {
        output.printError("Unknown subcommand '{s}' for 'python' command", .{subcommand}) catch {};
        output.print("Available subcommands: install, use, list", .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }
}
