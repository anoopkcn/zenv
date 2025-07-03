const std = @import("std");
const Allocator = std.mem.Allocator;

const CommandFlags = @import("utils/flags.zig").CommandFlags;
const env = @import("utils/environment.zig");
const deps = @import("utils/parse_deps.zig");
const aux = @import("utils/auxiliary.zig");
const python = @import("utils/python.zig");
const jupyter = @import("utils/jupyter.zig");
const configurations = @import("utils/config.zig");
const validation = @import("utils/validation.zig");
const output = @import("utils/output.zig");
const ZenvConfig = configurations.ZenvConfig;
const EnvironmentConfig = configurations.EnvironmentConfig;
const EnvironmentRegistry = configurations.EnvironmentRegistry;

pub fn handleInitCommand(
    allocator: Allocator,
    args: []const []const u8,
) void {
    const cwd = std.fs.cwd();
    const config_path = "zenv.json";

    // Check if file exists
    const file_exists = blk: {
        cwd.access(config_path, .{}) catch |err| {
            if (err != error.FileNotFound) {
                output.printError(allocator, "Accessing current directory: {s}", .{@errorName(err)}) catch {};
                std.process.exit(1);
            }
            // File doesn't exist
            break :blk false;
        };
        break :blk true;
    };

    if (file_exists) {
        output.printError(allocator, "{s} already exists. Please remove or rename it first.", .{config_path}) catch {};
        std.process.exit(1);
    }

    // Use a static string as the default target_machine
    const hostname = "*";

    // Import the template module for JSON
    const template_json = @import("utils/template_json.zig");

    // Create a map for template replacements
    var replacements = std.StringHashMap([]const u8).init(allocator);
    defer replacements.deinit();

    // Add common replacements for all templates
    replacements.put("HOSTNAME", hostname) catch |err| {
        output.printError(allocator, "Creating HOSTNAME replacement: {s}", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };

    // Determine the dependency file (used by both templates)
    const dev_dep_file_value: []const u8 = blk: {
        var requirements_txt_found: bool = false;
        // Check for requirements.txt
        if (cwd.access("requirements.txt", .{})) |_| {
            requirements_txt_found = true;
        } else |err| {
            if (err == error.FileNotFound) {
                requirements_txt_found = false;
            } else {
                // For errors other than FileNotFound, print and exit
                output.printError(allocator, "Accessing requirements.txt: {s}", .{@errorName(err)}) catch {};
                std.process.exit(1);
            }
        }

        if (requirements_txt_found) {
            break :blk "\"requirements.txt\"";
        }

        // Check for pyproject.toml
        var pyproject_toml_found: bool = false;
        if (cwd.access("pyproject.toml", .{})) |_| {
            pyproject_toml_found = true;
        } else |err| {
            if (err == error.FileNotFound) {
                pyproject_toml_found = false;
            } else {
                output.printError(allocator, "Accessing pyproject.toml: {s}", .{@errorName(err)}) catch {};
                std.process.exit(1);
            }
        }

        if (pyproject_toml_found) {
            break :blk "\"pyproject.toml\"";
        }

        // Neither file exists
        break :blk "null";
    };

    replacements.put("DEV_DEPENDENCY_FILE", dev_dep_file_value) catch |err| {
        output.printError(allocator, "Adding DEV_DEPENDENCY_FILE replacement: {s}", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };

    var custom_env_name: []const u8 = "test";
    var custom_env_desc: []const u8 = "Env config created by zenv";

    if (args.len > 2) {
        custom_env_name = args[2];
        if (args.len > 3) {
            custom_env_desc = args[3];
        }
    }

    replacements.put("ENV_NAME", custom_env_name) catch |err| {
        output.printError(allocator, "Adding ENV_NAME replacement: {s}", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    replacements.put("ENV_DESCRIPTION", custom_env_desc) catch |err| {
        output.printError(allocator, "Adding ENV_DESCRIPTION replacement: {s}", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };

    // Process the custom template
    const processed_content = template_json.createCustomJsonConfigFromTemplate(allocator, replacements) catch |err| {
        output.printError(allocator, "Processing custom template: {s}", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    defer allocator.free(processed_content);

    // Write template to file
    const file = cwd.createFile(config_path, .{}) catch |err| {
        output.printError(allocator, "Creating {s}: {s}", .{ config_path, @errorName(err) }) catch {};
        std.process.exit(1);
    };
    defer file.close();

    file.writeAll(processed_content) catch |err| {
        output.printError(allocator, "Writing to {s}: {s}", .{ config_path, @errorName(err) }) catch {};
        std.process.exit(1);
    };

    output.print(allocator, "Created zenv.json. Run 'zenv setup {s}'", .{custom_env_name}) catch {};
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
        output.print(allocator,
            \\Force dependencies flag detected.
            \\User-specified dependencies will try to override module-provided packages.
        , .{}) catch {};
    }
    if (flags.skip_hostname_check) {
        output.print(allocator, "No-host flag detected. Bypassing hostname validation.", .{}) catch {};
    }
    if (flags.init_mode) {
        output.print(allocator, "Init flag detected. Using configuration created by --init.", .{}) catch {};
    }
    if (flags.no_cache) {
        output.print(allocator, "No-cache flag detected. Will disable package cache during dependency installation.", .{}) catch {};
    }

    // Get and validate the environment config
    const env_config = env.getAndValidateEnvironment(allocator, config, args, flags, handleErrorFn) orelse return;
    const env_name = args[2];

    const display_target = if (env_config.target_machines.items.len > 0) env_config.target_machines.items[0] else "any";

    // Set up logging to a file inside the environment directory
    const base_dir_path = if (std.fs.path.isAbsolute(config.base_dir))
        config.base_dir
    else
        try std.fs.path.join(allocator, &[_][]const u8{ try std.fs.cwd().realpathAlloc(allocator, "."), config.base_dir });
    defer if (!std.fs.path.isAbsolute(config.base_dir)) allocator.free(base_dir_path);

    const env_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir_path, env_name });
    defer allocator.free(env_dir_path);

    const log_path = try std.fs.path.join(allocator, &[_][]const u8{ env_dir_path, "zenv_setup.log" });
    defer allocator.free(log_path);

    try output.startLogging(allocator, log_path);
    defer output.stopLogging();

    // Log the command that was used to start the setup
    var command_str = std.ArrayList(u8).init(allocator);
    // Note: don't free command_str until after installation is complete
    for (args, 0..) |arg, i| {
        if (i > 0) {
            command_str.writer().print(" ", .{}) catch {};
        }
        if (std.mem.indexOf(u8, arg, " ") != null) {
            // Quote arguments with spaces
            command_str.writer().print("\"{s}\"", .{arg}) catch {};
        } else {
            command_str.writer().print("{s}", .{arg}) catch {};
        }
    }
    output.print(allocator, "Command: {s}", .{command_str.items}) catch {};
    output.print(allocator, "Setting up environment: {s} (Target: {s})", .{ env_name, display_target }) catch {};

    // 0. Check the availability of modules
    var modules_verified = false;
    if (env_config.modules.items.len > 0) {
        // Use the improved validateModules function
        const modules_available = env.validateModules(allocator, env_config, flags.force_deps) catch |err| {
            output.printError(allocator, "Failed to validate modules: {s}", .{@errorName(err)}) catch {};
            handleErrorFn(error.ModuleLoadError);
            return error.ModuleLoadError;
        };

        if (!modules_available) {
            // Error messages already printed by validateModules
            handleErrorFn(error.ModuleLoadError);
            return error.ModuleLoadError;
        }

        output.print(allocator, "All modules appear to be available.", .{}) catch {};
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
        output.print(allocator, "Adding {d} dependencies from configuration:", .{env_config.dependencies.items.len}) catch {};
        for (env_config.dependencies.items) |dep| {
            output.print(allocator, "  - Config dependency: {s}", .{dep}) catch {};
            // Don't dupe here, assume config owns them or they are literals
            try all_required_deps.append(dep);
        }
    } else {
        output.print(allocator, "No dependencies specified in configuration.", .{}) catch {};
    }

    // Add dependencies from requirements file if specified
    if (env_config.dependency_file) |req_file| {
        // Check if the specified requirements file actually exists
        std.fs.cwd().access(req_file, .{}) catch |err| {
            if (err == error.FileNotFound) {
                output.printError(allocator, "Requirements file specified in configuration ('{s}') not found.", .{req_file}) catch {};
                handleErrorFn(err); // Use the original file not found error
                return err; // Exit setup command
            } else {
                // Handle other potential access errors
                output.printError(allocator, "Error accessing requirements file '{s}': {s}", .{ req_file, @errorName(err) }) catch {};
                handleErrorFn(err);
                return err;
            }
        };

        // Log the absolute path for debugging
        var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path = std.fs.cwd().realpath(req_file, &abs_path_buf) catch |err| {
            output.printError(allocator, "Failed to resolve absolute path for requirements file '{s}': {s}", .{ req_file, @errorName(err) }) catch {};
            // handleErrorFn(err); // Or map to ZenvError
            return err; // Propagate error
        };
        output.print(allocator, "Reading dependencies from file: '{s}' (absolute path: '{s}')", .{ req_file, abs_path }) catch {};

        // Read the file content - use temp_allocator since we're done with it after parsing
        const req_content = std.fs.cwd().readFileAlloc(temp_allocator, req_file, 1 * 1024 * 1024) catch |err| {
            output.printError(allocator, "Failed to read file '{s}': {s}", .{ req_file, @errorName(err) }) catch {};
            handleErrorFn(error.PathResolutionFailed); // Use specific error
            return error.PathResolutionFailed; // Exit setup command
        };
        // No need to defer free because the arena will handle cleanup

        output.print(allocator, "Successfully read file ({d} bytes). Parsing dependencies...", .{req_content.len}) catch {};

        // Determine file type and parse
        const is_toml = std.mem.endsWith(u8, req_file, ".toml");
        var req_file_dep_count: usize = 0;

        if (is_toml) {
            output.print(allocator, "Detected TOML file format, parsing as pyproject.toml", .{}) catch {};
            req_file_dep_count = try deps.parsePyprojectToml(allocator, req_content, &all_required_deps);
        } else {
            output.print(allocator, "Parsing as requirements.txt format", .{}) catch {};
            // Use the new utility function
            req_file_dep_count = try deps.parseRequirementsTxt(allocator, req_content, &all_required_deps);
        }

        if (req_file_dep_count > 0) {
            output.print(allocator, "Added {d} dependencies from file '{s}'", .{ req_file_dep_count, req_file }) catch {};
        } else {
            output.print(allocator, "Warning: No valid dependencies found in file '{s}'", .{req_file}) catch {};
        }
    } else {
        output.print(allocator, "No requirements file specified in configuration.", .{}) catch {};
    }

    // Get base_dir from config
    const base_dir = config.base_dir;

    // Debug output - print the combined dependencies
    output.print(allocator, "Combined dependency list ({d} items):", .{all_required_deps.items.len}) catch {};
    for (all_required_deps.items) |dep| {
        output.print(allocator, "  - {s}", .{dep}) catch {};
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
        modules_verified,
        flags.use_default_python,
        flags.dev_mode,
        flags.use_uv,
        flags.no_cache,
        command_str.items,
    ) catch |err| {
        handleErrorFn(err);
        command_str.deinit();
        return err;
    };
    deps_need_cleanup = false;
    command_str.deinit();

    // 4. Create the final activation script (using a separate utility)
    try aux.createActivationScript(allocator, env_config, env_name, base_dir);

    // 5. Register the environment in the global registry
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = std.fs.cwd().realpath(".", &abs_path_buf) catch |err| {
        output.printError(allocator, "Failed to get current working directory: {s}", .{@errorName(err)}) catch {};
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

    // Create Jupyter kernel if requested
    if (flags.create_jupyter_kernel) {
        jupyter.createKernel(allocator, env_name, null, null) catch |err| {
            output.printError(allocator, "Failed to create Jupyter kernel: {s}", .{@errorName(err)}) catch {};
        };
    }

    output.print(allocator,
        \\Environment '{s}' setup complete and registered in global registry.
        \\Usage: source $(zenv activate {s})
    , .{ env_name, env_name }) catch {};
}

pub fn handleActivateCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError(allocator, "Missing environment name or ID argument. Usage: zenv activate <name|id>", .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const identifier = args[2];

    const entry = env.lookupRegistryEntry(allocator, registry, identifier, handleErrorFn) orelse return;
    const venv_path = entry.venv_path;

    std.io.getStdOut().writer().print("{s}/activate.sh\n", .{venv_path}) catch |e| {
        output.printError(allocator, "Error writing to stdout: {s}", .{@errorName(e)}) catch {};
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
            output.print(allocator,
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
        output.printError(allocator, "Missing environment name argument. Usage: zenv register <n>", .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const env_name = args[2];

    const flags = CommandFlags.fromArgs(args);

    // Log flags if they're set
    if (flags.skip_hostname_check) {
        output.print(allocator, "'--no-host' flag detected. Skipping hostname validation.", .{}) catch {};
    }

    // Get the environment config directly without re-parsing validation
    const env_config = config.getEnvironment(env_name) orelse {
        output.printError(allocator, "Environment '{s}' not found in configuration.", .{env_name}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    };

    // Validate the environment config
    if (ZenvConfig.validateEnvironment(env_config, env_name)) |err| {
        output.printError(allocator, "Invalid configuration for '{s}': {s}", .{ env_name, @errorName(err) }) catch {};
        handleErrorFn(err);
        return;
    }

    // Check hostname validation if needed
    if (!flags.skip_hostname_check) {
        const hostname = env.getSystemHostname(allocator) catch |err| {
            output.printError(allocator, "Failed to get current hostname: {s}", .{@errorName(err)}) catch {};
            handleErrorFn(err);
            return;
        };
        defer allocator.free(hostname);

        // Use the dedicated function for hostname validation
        const hostname_matches = env.validateEnvironmentForMachine(env_config, hostname);

        if (!hostname_matches) {
            output.printError(allocator,
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
        output.printError(allocator, "Could not get current working directory: {s}", .{@errorName(err)}) catch {};
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
        output.printError(allocator, "Failed to register environment: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };

    // Save the registry
    registry.save() catch |err| {
        output.printError(allocator, "Failed to save registry: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };

    output.print(allocator,
        \\Environment '{s}' registered successfully.
        \\Usage: source $(zenv activate {s})
    , .{ env_name, env_name }) catch {};
}

pub fn handleDeregisterCommand(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing environment name or ID argument.
            \\Usage: zenv deregister <name|id|.>
        , .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const identifier = args[2];

    // Look up environment in registry first to check if it exists
    // We use lookupRegistryEntry utility which handles error reporting for ambiguous IDs
    const entry = env.lookupRegistryEntry(allocator, registry, identifier, handleErrorFn) orelse return;

    // Store name for the success message - make a copy to ensure it remains valid
    const env_name = registry.allocator.dupe(u8, entry.env_name) catch |err| {
        output.printError(allocator, "Failed to duplicate environment name: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };
    defer registry.allocator.free(env_name);

    // Remove the environment from the registry using the name
    // We pass the actual environment name from the resolved entry
    if (registry.deregister(entry.env_name)) {
        // Save the registry
        registry.save() catch |err| {
            output.printError(allocator, "Failed to save registry: {s}", .{@errorName(err)}) catch {};
            handleErrorFn(err);
            return;
        };

        output.print(allocator, "Environment '{s}' unregistered successfully.", .{env_name}) catch {};
    } else {
        output.printError(allocator, "Failed to unregister environment '{s}'.", .{env_name}) catch {};
        handleErrorFn(error.EnvironmentNotRegistered);
        return;
    }
}

pub fn handleCdCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing environment name or ID argument
            \\Usage: zenv cd <name|id|.>
        , .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const identifier = args[2];

    const entry = env.lookupRegistryEntry(allocator, registry, identifier, handleErrorFn) orelse return;

    // Get project directory from registry entry
    const project_dir = entry.project_dir;

    // Output just the project directory path
    std.io.getStdOut().writer().print("{s}\n", .{project_dir}) catch |e| {
        output.printError(allocator, "Error writing to stdout: {s}", .{@errorName(e)}) catch {};
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
        output.printError(allocator, "Missing subcommand for 'python' command", .{}) catch {};
        output.print(allocator, "Available subcommands: install, use, list", .{}) catch {};
        handleErrorFn(error.ArgsError);
        return error.ArgsError;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "install")) {
        // Python install [version] command
        var version: ?[]const u8 = null;
        if (args.len >= 4) {
            version = args[3];
            output.print(allocator, "Installing Python version: {s}", .{version.?}) catch {};
        } else {
            output.print(allocator, "No version specified, will install default version", .{}) catch {};
        }

        // Install Python
        python.installPython(allocator, version) catch |err| {
            output.printError(allocator, "Python installation failed: {s}", .{@errorName(err)}) catch {};
            handleErrorFn(err);
            return;
        };

        // DO NOT PINN PYTHON VERSION HERE
        // const installed_version = version orelse python.DEFAULT_PYTHON_VERSION;
        // try output.print(allocator,"Pinning newly installed Python {s}", .{installed_version});
        // try python.setDefaultPythonPath(allocator, installed_version);
    } else if (std.mem.eql(u8, subcommand, "use") or std.mem.eql(u8, subcommand, "pin")) {
        // Python use [version] command
        if (args.len < 4) {
            output.printError(allocator, "Missing version argument for 'python use' command", .{}) catch {};
            output.print(allocator, "Usage: zenv python use <version>", .{}) catch {};
            handleErrorFn(error.ArgsError);
            return error.ArgsError;
        }

        const version = args[3];
        try python.setDefaultPythonPath(allocator, version);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        // Python list command - list all installed versions
        try python.listInstalledVersions(allocator);
    } else {
        output.printError(allocator, "Unknown subcommand '{s}' for 'python' command", .{subcommand}) catch {};
        output.print(allocator, "Available subcommands: install, use, list", .{}) catch {};
        handleErrorFn(error.ArgsError);
        return error.ArgsError;
    }
}

pub fn handleRmCommand(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing environment name or ID argument.
            \\Usage: zenv rm <name|id>
        , .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const identifier = args[2];

    const entry = env.lookupRegistryEntry(allocator, registry, identifier, handleErrorFn) orelse return;

    const env_name_to_remove = registry.allocator.dupe(u8, entry.env_name) catch |err| {
        output.printError(allocator, "Failed to duplicate environment name for removal: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };
    defer registry.allocator.free(env_name_to_remove);

    const venv_path_to_remove = registry.allocator.dupe(u8, entry.venv_path) catch |err| {
        output.printError(allocator, "Failed to duplicate venv path for removal: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };
    defer registry.allocator.free(venv_path_to_remove);

    if (registry.deregister(identifier)) {
        output.print(allocator, "Environment '{s}' deregistered successfully.", .{env_name_to_remove}) catch {};
        registry.save() catch |err| {
            output.printError(allocator, "Failed to save registry after deregistering '{s}': {s}", .{ env_name_to_remove, @errorName(err) }) catch {};
        };
    } else {
        output.printError(allocator, "Failed to find environment '{s}' for deregistration.", .{identifier}) catch {};
        handleErrorFn(error.EnvironmentNotRegistered);
        return;
    }

    output.print(allocator, "Attempting to remove: {s}", .{venv_path_to_remove}) catch {};
    std.fs.deleteTreeAbsolute(venv_path_to_remove) catch |err| {
        output.printError(allocator, "Failed to remove '{s}': {s}", .{ venv_path_to_remove, @errorName(err) }) catch {};
        output.printError(allocator, "You may need to remove it manually.", .{}) catch {};
        handleErrorFn(err);
        return;
    };

    output.print(allocator, "Directory '{s}' removed successfully.", .{venv_path_to_remove}) catch {};
    output.print(allocator, "Environment '{s}' removed.", .{env_name_to_remove}) catch {};
}

pub fn handleRunCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    // Need at least 4 args: zenv run <env> <command>
    if (args.len < 4) {
        output.printError(allocator, "Missing environment name or command. Usage: zenv run <name|id> <command> [args...]", .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    const identifier = args[2];
    const command = args[3];
    const command_args = args[4..];

    const entry = env.lookupRegistryEntry(allocator, registry, identifier, handleErrorFn) orelse return;
    const venv_path = entry.venv_path;

    const activate_path = std.fs.path.join(allocator, &[_][]const u8{ venv_path, "activate.sh" }) catch |err| {
        output.printError(allocator, "Failed to construct activation script path: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };
    defer allocator.free(activate_path);

    // Create temporary script
    const temp_script_path = createTempRunScript(allocator, activate_path, command, command_args) catch |err| {
        output.printError(allocator, "Failed to create temporary run script: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };
    defer {
        std.fs.cwd().deleteFile(temp_script_path) catch |err| {
            output.print(allocator, "Warning: Failed to delete temporary script: {s}", .{@errorName(err)}) catch {};
        };
        allocator.free(temp_script_path);
    }

    // Execute the script
    var script_argv = [_][]const u8{ "/bin/bash", temp_script_path };
    var child = std.process.Child.init(&script_argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| {
        output.printError(allocator, "Failed to spawn command: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };

    const term = child.wait() catch |err| {
        output.printError(allocator, "Failed to wait for command: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };

    // Check if the command was successful
    const success = blk: {
        if (term != .Exited) break :blk false;
        if (term.Exited != 0) break :blk false;
        break :blk true;
    };

    if (!success) {
        if (term == .Exited) {
            output.printError(allocator, "Command exited with status: {d}", .{term.Exited}) catch {};
        } else {
            output.printError(allocator, "Command terminated abnormally", .{}) catch {};
        }
        handleErrorFn(error.ProcessError);
        return;
    }
}

// Helper function to create a temporary script that activates an environment and runs a command
fn createTempRunScript(
    allocator: Allocator,
    activate_path: []const u8,
    command: []const u8,
    args: []const []const u8,
) ![]const u8 {
    // Create temporary file with unique name
    var temp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = try std.fmt.bufPrint(&temp_path_buf, "/tmp/zenv_run_{d}.sh", .{std.time.milliTimestamp()});
    const temp_path_owned = try allocator.dupe(u8, temp_path);
    errdefer allocator.free(temp_path_owned);

    var file = try std.fs.cwd().createFile(temp_path_owned, .{});
    defer file.close();

    // Make it executable
    try file.chmod(0o755);

    // Write script content
    try file.writeAll("#!/bin/bash\nset -e\n\n");
    try file.writer().print("source \"{s}\"\n\n", .{activate_path});

    // Add command with arguments, properly escaped
    try file.writer().print("{s}", .{command});
    for (args) |arg| {
        // Escape quotes in arguments
        var escaped_arg = std.ArrayList(u8).init(allocator);
        defer escaped_arg.deinit();

        for (arg) |char| {
            if (char == '"' or char == '\\' or char == '$') {
                try escaped_arg.append('\\');
            }
            try escaped_arg.append(char);
        }

        try file.writer().print(" \"{s}\"", .{escaped_arg.items});
    }
    try file.writeAll("\n");

    return temp_path_owned;
}

pub fn handleLogCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing environment name or ID argument.
            \\Usage: zenv log <name|id>
        , .{}) catch {};
        handleErrorFn(error.EnvironmentNotFound);
        return;
    }

    const identifier = args[2];

    // Look up environment in registry
    const entry = env.lookupRegistryEntry(allocator, registry, identifier, handleErrorFn) orelse return;

    // Construct the path to the log file
    const log_file_path = std.fs.path.join(allocator, &[_][]const u8{ entry.venv_path, "zenv_setup.log" }) catch |err| {
        output.printError(allocator, "Failed to construct log file path: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };
    defer allocator.free(log_file_path);

    // Check if the log file exists
    std.fs.cwd().access(log_file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            output.printError(allocator, "No setup log found for environment '{s}'", .{entry.env_name}) catch {};
            output.printError(allocator, "The log file should be at: {s}", .{log_file_path}) catch {};
            handleErrorFn(error.FileNotFound);
            return;
        } else {
            output.printError(allocator, "Error accessing log file '{s}': {s}", .{ log_file_path, @errorName(err) }) catch {};
            handleErrorFn(err);
            return;
        }
    };

    // Read and print the log file
    const log_content = std.fs.cwd().readFileAlloc(allocator, log_file_path, 10 * 1024 * 1024) catch |err| {
        output.printError(allocator, "Failed to read log file '{s}': {s}", .{ log_file_path, @errorName(err) }) catch {};
        handleErrorFn(err);
        return;
    };
    defer allocator.free(log_content);

    // Output the log content
    std.io.getStdOut().writer().print("{s}", .{log_content}) catch |err| {
        output.printError(allocator, "Error writing log to stdout: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };
}

pub fn handleValidateCommand(
    allocator: Allocator,
    config_path: []const u8,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {

    // Use custom config path if provided as an argument
    var validate_config_path: []const u8 = config_path;

    if (args.len > 2) {
        validate_config_path = args[2];
        output.print(allocator, "Using provided file path: {s}", .{validate_config_path}) catch {};
    } else {
        output.print(allocator, "Using default config path: {s}", .{validate_config_path}) catch {};
    }

    // Check if file exists before validating
    if (std.fs.cwd().openFile(validate_config_path, .{})) |file| {
        file.close();
        output.print(allocator, "File exists, proceeding with validation", .{}) catch {};
    } else |err| {
        output.printError(allocator, "Failed to open file '{s}': {s}", .{ validate_config_path, @errorName(err) }) catch {};
        std.process.exit(1);
    }

    // Modified validate implementation for single file validation
    const validateSingleFile = struct {
        fn handleValidationError(err: anyerror) void {
            // Use a modified error handler with the correct file path
            switch (err) {
                error.ConfigFileNotFound, error.JsonParseError, error.InvalidFormat, error.ConfigInvalid => {
                    // Syntax check already printed details
                    std.process.exit(1);
                },
                else => handleErrorFn(err),
            }
        }
    }.handleValidationError;

    if (validation.validateConfigFile(allocator, validate_config_path)) |errors_opt| {
        if (errors_opt) |errors| {
            // Errors were found and already printed by validateConfigFile
            // Clean up errors
            for (errors.items) |*err| {
                err.deinit(allocator);
            }
            errors.deinit();
            std.process.exit(1);
        } else {
            // No errors found
            output.print(allocator, "Configuration file is valid!", .{}) catch {};
        }
    } else |err| {
        validateSingleFile(err);
        std.process.exit(1);
    }
}

pub fn handleAliasCommand(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing alias subcommand.
            \\Usage: zenv alias <create|remove|list|show> [arguments]
        , .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "create")) {
        handleAliasCreate(allocator, registry, args, handleErrorFn);
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        handleAliasRemove(allocator, registry, args, handleErrorFn);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        handleAliasList(allocator, registry, args, handleErrorFn);
    } else if (std.mem.eql(u8, subcommand, "show")) {
        handleAliasShow(allocator, registry, args, handleErrorFn);
    } else {
        output.printError(allocator,
            \\Unknown alias subcommand '{s}'.
            \\Usage: zenv alias <create|remove|list|show> [arguments]
        , .{subcommand}) catch {};
        handleErrorFn(error.ArgsError);
    }
}

fn handleAliasCreate(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 5) {
        output.printError(allocator,
            \\Missing arguments for alias create.
            \\Usage: zenv alias create <alias_name> <env_name|env_id>
        , .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    const alias_name = args[3];
    const env_identifier = args[4];

    // Check if alias name would conflict with existing commands
    const reserved_names = [_][]const u8{ "setup", "activate", "list", "register", "deregister", "cd", "init", "rm", "python", "log", "run", "validate", "alias", "jupyter", "help", "version" };
    for (reserved_names) |reserved| {
        if (std.mem.eql(u8, alias_name, reserved)) {
            output.printError(allocator, "Alias name '{s}' conflicts with existing command.", .{alias_name}) catch {};
            handleErrorFn(error.ArgsError);
            return;
        }
    }

    // Check if alias name is "." (reserved for current directory)
    if (std.mem.eql(u8, alias_name, ".")) {
        output.printError(allocator, "Alias name '.' is reserved for current directory notation.", .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    // Resolve environment identifier to get the actual environment name
    const target_entry = env.lookupRegistryEntry(allocator, registry, env_identifier, handleErrorFn) orelse return;
    const target_env_name = target_entry.env_name;

    // Add alias to registry
    registry.addAlias(alias_name, target_env_name) catch |err| {
        switch (err) {
            error.EnvironmentNotFound => {
                output.printError(allocator, "Environment '{s}' not found.", .{env_identifier}) catch {};
                handleErrorFn(err);
                return;
            },
            error.AliasAlreadyExists => {
                output.printError(allocator, "Alias '{s}' already exists.", .{alias_name}) catch {};
                handleErrorFn(err);
                return;
            },
            else => {
                output.printError(allocator, "Failed to create alias: {s}", .{@errorName(err)}) catch {};
                handleErrorFn(err);
                return;
            },
        }
    };

    // Save registry
    registry.save() catch |err| {
        output.printError(allocator, "Failed to save registry: {s}", .{@errorName(err)}) catch {};
        handleErrorFn(err);
        return;
    };

    output.print(allocator, "Alias '{s}' created for environment '{s}'.", .{ alias_name, target_env_name }) catch {};
}

fn handleAliasRemove(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing alias name.
            \\Usage: zenv alias remove <alias_name>
        , .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    const alias_name = args[3];

    if (registry.removeAlias(alias_name)) {
        // Save registry
        registry.save() catch |err| {
            output.printError(allocator, "Failed to save registry: {s}", .{@errorName(err)}) catch {};
            handleErrorFn(err);
            return;
        };

        output.print(allocator, "Alias '{s}' removed.", .{alias_name}) catch {};
    } else {
        output.printError(allocator, "Alias '{s}' not found.", .{alias_name}) catch {};
        handleErrorFn(error.AliasNotFound);
    }
}

fn handleAliasList(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    _ = args;
    _ = handleErrorFn;

    const aliases = registry.listAliases();

    if (aliases.count() == 0) {
        output.print(allocator, "No aliases defined.", .{}) catch {};
        return;
    }

    output.print(allocator, "Defined aliases:", .{}) catch {};
    var iterator = aliases.iterator();
    while (iterator.next()) |alias_entry| {
        const alias_name = alias_entry.key_ptr.*;
        const env_name = alias_entry.value_ptr.*;
        output.print(allocator, "  {s} -> {s}", .{ alias_name, env_name }) catch {};
    }
}

fn handleAliasShow(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing alias name.
            \\Usage: zenv alias show <alias_name>
        , .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    const alias_name = args[3];

    if (registry.resolveAlias(alias_name)) |target_env| {
        output.print(allocator, "Alias '{s}' points to environment '{s}'.", .{ alias_name, target_env }) catch {};
    } else {
        output.printError(allocator, "Alias '{s}' not found.", .{alias_name}) catch {};
        handleErrorFn(error.AliasNotFound);
    }
}

pub fn handleJupyterCommand(
    allocator: Allocator,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing jupyter subcommand.
            \\Usage: zenv jupyter <create|remove|list|check> [arguments]
        , .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "create")) {
        handleJupyterCreate(allocator, args, handleErrorFn);
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        handleJupyterRemove(allocator, args, handleErrorFn);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        handleJupyterList(allocator, handleErrorFn);
    } else if (std.mem.eql(u8, subcommand, "check")) {
        handleJupyterCheck(allocator, handleErrorFn);
    } else {
        output.printError(allocator,
            \\Unknown jupyter subcommand '{s}'.
            \\Usage: zenv jupyter <create|remove|list|check> [arguments]
        , .{subcommand}) catch {};
        handleErrorFn(error.ArgsError);
    }
}

fn handleJupyterCreate(
    allocator: Allocator,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing environment name argument.
            \\Usage: zenv jupyter create <env_name> [--name <kernel_name>] [--display-name <display_name>]
        , .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    const env_name = args[3];
    var custom_name: ?[]const u8 = null;
    var custom_display_name: ?[]const u8 = null;

    // Parse optional flags
    var i: usize = 4;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--name") and i + 1 < args.len) {
            custom_name = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--display-name") and i + 1 < args.len) {
            custom_display_name = args[i + 1];
            i += 2;
        } else {
            output.printError(allocator, "Unknown flag: {s}", .{args[i]}) catch {};
            handleErrorFn(error.ArgsError);
            return;
        }
    }

    jupyter.createKernel(allocator, env_name, custom_name, custom_display_name) catch |err| {
        handleErrorFn(err);
    };
}

fn handleJupyterRemove(
    allocator: Allocator,
    args: []const []const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing environment name argument.
            \\Usage: zenv jupyter remove <env_name>
        , .{}) catch {};
        handleErrorFn(error.ArgsError);
        return;
    }

    const env_name = args[3];
    jupyter.removeKernel(allocator, env_name) catch |err| {
        handleErrorFn(err);
    };
}

fn handleJupyterList(
    allocator: Allocator,
    handleErrorFn: fn (anyerror) void,
) void {
    jupyter.listKernels(allocator) catch |err| {
        handleErrorFn(err);
    };
}

fn handleJupyterCheck(
    allocator: Allocator,
    handleErrorFn: fn (anyerror) void,
) void {
    jupyter.checkJupyter(allocator) catch |err| {
        handleErrorFn(err);
    };
}
