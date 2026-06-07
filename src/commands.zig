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
const runtime = @import("utils/runtime.zig");
const template = @import("utils/template.zig");
const ZenvConfig = configurations.ZenvConfig;
const EnvironmentConfig = configurations.EnvironmentConfig;
const EnvironmentRegistry = configurations.EnvironmentRegistry;

pub fn handleInitCommand(
    allocator: Allocator,
    args: []const []const u8,
) void {
    const config_path = "zenv.json";

    // Check if file exists
    const file_exists = blk: {
        runtime.access(config_path) catch |err| {
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

    // The init config is a plain template: build the replacements below and run
    // them through the shared engine directly (no per-template wrapper needed).
    const JSON_CONFIG_TEMPLATE = @embedFile("utils/templates/zenv.json.template");

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
        if (runtime.access("requirements.txt")) |_| {
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
        if (runtime.access("pyproject.toml")) |_| {
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
    const processed_content = template.processTemplateString(allocator, JSON_CONFIG_TEMPLATE, replacements) catch |err| {
        output.printError(allocator, "Processing custom template: {s}", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    defer allocator.free(processed_content);

    // Write template to file
    var file = runtime.createFile(config_path, .{}) catch |err| {
        output.printError(allocator, "Creating {s}: {s}", .{ config_path, @errorName(err) }) catch {};
        std.process.exit(1);
    };
    defer file.close(runtime.io);

    file.writeStreamingAll(runtime.io, processed_content) catch |err| {
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
    const env_config = try env.getAndValidateEnvironment(allocator, config, args, flags);
    const env_name = args[2];

    const display_target = if (env_config.target_machines.items.len > 0) env_config.target_machines.items[0] else "any";

    // Set up logging to a file inside the environment directory
    const base_dir_path = if (std.fs.path.isAbsolute(config.base_dir))
        config.base_dir
    else
        try std.fs.path.join(allocator, &[_][]const u8{ try runtime.cwdRealpath(allocator), config.base_dir });
    defer if (!std.fs.path.isAbsolute(config.base_dir)) allocator.free(base_dir_path);

    const env_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir_path, env_name });
    defer allocator.free(env_dir_path);

    const log_path = try std.fs.path.join(allocator, &[_][]const u8{ env_dir_path, "zenv_setup.log" });
    defer allocator.free(log_path);

    try output.startLogging(allocator, log_path);
    defer output.stopLogging();

    // Log the command that was used to start the setup
    var command_str = std.array_list.Managed(u8).init(allocator);
    // Note: don't free command_str until after installation is complete
    for (args, 0..) |arg, i| {
        if (i > 0) {
            command_str.print(" ", .{}) catch {};
        }
        if (std.mem.indexOf(u8, arg, " ") != null) {
            // Quote arguments with spaces
            command_str.print("\"{s}\"", .{arg}) catch {};
        } else {
            command_str.print("{s}", .{arg}) catch {};
        }
    }
    output.print(allocator, "Command: {s}", .{command_str.items}) catch {};
    output.print(allocator, "Setting up environment: {s} (Target: {s})", .{ env_name, display_target }) catch {};

    // 0. Check the availability of modules
    var modules_verified = false;
    if (env_config.modules.items.len > 0) {
        // Use the improved validateModules function
        const modules_available = env.validateModules(allocator, env_config) catch |err| {
            output.printError(allocator, "Failed to validate modules: {s}", .{@errorName(err)}) catch {};
            return error.ModuleLoadError;
        };

        if (!modules_available) {
            // Error messages already printed by validateModules
            return error.ModuleLoadError;
        }

        output.print(allocator, "All modules appear to be available.", .{}) catch {};
        modules_verified = true;
    }

    // 1. Combine Dependencies
    var all_required_deps = std.array_list.Managed([]const u8).init(allocator);
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
        runtime.access(req_file) catch |err| {
            if (err == error.FileNotFound) {
                output.printError(allocator, "Requirements file specified in configuration ('{s}') not found.", .{req_file}) catch {};
                return err; // Exit setup command
            } else {
                // Handle other potential access errors
                output.printError(allocator, "Error accessing requirements file '{s}': {s}", .{ req_file, @errorName(err) }) catch {};
                return err;
            }
        };

        output.print(allocator, "Reading dependencies from file: '{s}'", .{req_file}) catch {};

        // Read the file content - use temp_allocator since we're done with it after parsing
        const req_content = runtime.readFileAlloc(temp_allocator, req_file, 1 * 1024 * 1024) catch |err| {
            output.printError(allocator, "Failed to read file '{s}': {s}", .{ req_file, @errorName(err) }) catch {};
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
        flags,
        modules_verified,
        command_str.items,
    ) catch |err| {
        command_str.deinit();
        return err;
    };
    deps_need_cleanup = false;
    command_str.deinit();

    // 4. Create the final activation script (using a separate utility)
    try aux.createActivationScript(allocator, env_config, env_name, base_dir);

    // 5. Register the environment in the global registry
    const cwd_path = runtime.cwdRealpath(allocator) catch |err| {
        output.printError(allocator, "Failed to get current working directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(cwd_path);

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

/// Renders a resolution failure at the call site — preserving the ambiguous
/// candidate list — and returns the error for main.zig to map to an exit
/// message. Mirrors the messages the deleted lookupRegistryEntry printed.
fn present(allocator: Allocator, registry: *const EnvironmentRegistry, identifier: []const u8, err: anyerror) anyerror {
    if (err == error.AmbiguousIdentifier) {
        const cands = registry.candidates(allocator, identifier) catch return err;
        defer allocator.free(cands);

        output.rawErr(allocator, "ERROR: '{s}' matches multiple environments:\n", .{identifier}) catch {};

        // Host framing applies only to the host-aware branches ("." and a shared
        // alias). A non-unique id-prefix is host-irrelevant — advise more characters.
        var host_relevant = std.mem.eql(u8, identifier, ".");
        if (!host_relevant) {
            outer: for (registry.entries.items) |entry| {
                for (entry.aliases.items) |a| {
                    if (std.mem.eql(u8, a, identifier)) {
                        host_relevant = true;
                        break :outer;
                    }
                }
            }
        }
        if (!host_relevant) {
            for (cands) |c| output.rawErr(allocator, "  - {s}\n", .{c.env_name}) catch {};
            output.rawErr(allocator, "Use more characters of the id, or the exact env name.\n", .{}) catch {};
            return err;
        }

        // Best-effort current host so we can explain WHY the tie wasn't broken:
        // either none of the candidates target this host, or several do.
        const current_host: ?[]const u8 = env.getSystemHostname(allocator) catch null;
        defer if (current_host) |h| allocator.free(h);
        var host_matches: usize = 0;
        for (cands) |c| {
            const m = if (current_host) |h| env.hostMatchesTargets(h, c.target_machines) else false;
            if (m) host_matches += 1;
            const mark = if (m) "  <- matches this host" else "";
            output.rawErr(allocator, "  - {s} (target: {s}){s}\n", .{ c.env_name, c.target_machines, mark }) catch {};
        }
        if (current_host) |h| {
            if (host_matches == 0) {
                output.rawErr(allocator, "None of these target the current host '{s}'. Add this machine to one env's target_machines, or use the exact env name / id.\n", .{h}) catch {};
            } else {
                output.rawErr(allocator, "{d} target the current host '{s}'. Use the exact env name or id to choose one.\n", .{ host_matches, h }) catch {};
            }
        } else {
            output.rawErr(allocator, "Could not determine the current host. Use the exact env name or id.\n", .{}) catch {};
        }
    } else if (err == error.EnvironmentNotRegistered) {
        output.rawErr(allocator, "ERROR: Environment with name or ID '{s}' not found in registry.\n", .{identifier}) catch {};
        output.rawErr(allocator, "Use 'zenv list' to see all available environments with their IDs.\n", .{}) catch {};
    }
    return err;
}

pub fn handleActivateCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        output.printError(allocator, "Missing environment name or ID argument. Usage: zenv activate <name|id>", .{}) catch {};
        return error.EnvironmentNotFound;
    }

    const ref = registry.resolve(allocator, args[2]) catch |e| return present(allocator, registry, args[2], e);

    output.rawOut(allocator, "{s}/activate.sh\n", .{registry.get(ref).venv_path}) catch |e| {
        output.printError(allocator, "Error writing to stdout: {s}", .{@errorName(e)}) catch {};
        return;
    };
}

pub fn handleListCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writerStreaming(runtime.io, &stdout_buf);
    const stdout = &stdout_fw.interface; // special case for using standard writer
    defer stdout.flush() catch {};
    const list_all = args.len > 2 and std.mem.eql(u8, args[2], "--all");

    var current_hostname: ?[]const u8 = null;
    var hostname_allocd = false; // Track if hostname was allocated
    var use_hostname_filter = !list_all; // New variable to track if we should use hostname filter

    if (use_hostname_filter) {
        // Get hostname directly using the utility function
        current_hostname = env.getSystemHostname(allocator) catch |err| blk: {
            output.print(allocator,
                \\Could not determine current hostname for filtering: {s}
                \\Listing all registered environments instead.
            , .{@errorName(err)}) catch {};
            use_hostname_filter = false;
            break :blk null; // fall through and list everything
        };
        // This part only runs if the catch block wasn't executed
        if (current_hostname != null) {
            hostname_allocd = true; // Mark that we need to free it
        }
    }
    // Ensure hostname is freed if allocated using optional chaining
    defer if (hostname_allocd) if (current_hostname) |hostname| allocator.free(hostname);

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

        // Print environment name, ID, and target machine string
        stdout.print("- {s}", .{env_name}) catch {};
        stdout.print("\n  id      : {s}", .{entry.id}) catch {};
        stdout.print("\n  target  : {s}", .{target_machines_str}) catch {};
        stdout.print("\n  project : {s}", .{entry.project_dir}) catch {};
        stdout.print("\n  venv    : {s}", .{entry.venv_path}) catch {};

        // Show the Python that built the venv, read from <venv>/pyvenv.cfg.
        // Omitted entirely when the env isn't built (no pyvenv.cfg).
        if (configurations.readVenvPythonInfo(allocator, entry.venv_path) catch null) |info_val| {
            var info = info_val;
            defer info.deinit(allocator);
            if (info.path) |p| {
                stdout.print("\n  python  : {s}  ({s})", .{ info.version, p }) catch {};
            } else {
                stdout.print("\n  python  : {s}", .{info.version}) catch {};
            }
        }

        // Print aliases if any exist
        if (entry.aliases.items.len > 0) {
            stdout.print("\n  aliases : ", .{}) catch {};
            for (entry.aliases.items, 0..) |alias, i| {
                if (i > 0) {
                    stdout.print(", ", .{}) catch {};
                }
                stdout.print("{s}", .{alias}) catch {};
            }
        }

        // Optionally print description
        if (entry.description) |desc| {
            stdout.print("\n  desc    : {s}\n\n", .{desc}) catch {};
        } else {
            stdout.print("\n\n", .{}) catch {};
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
) !void {
    if (args.len < 3) {
        output.printError(allocator, "Missing environment name argument. Usage: zenv register <n>", .{}) catch {};
        return error.EnvironmentNotFound;
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
        return error.EnvironmentNotFound;
    };

    // Validate the environment config
    if (ZenvConfig.validateEnvironment(env_config, env_name)) |err| {
        output.printError(allocator, "Invalid configuration for '{s}': {s}", .{ env_name, @errorName(err) }) catch {};
        return err;
    }

    // Check hostname validation if needed
    if (!flags.skip_hostname_check) {
        const hostname = env.getSystemHostname(allocator) catch |err| {
            output.printError(allocator, "Failed to get current hostname: {s}", .{@errorName(err)}) catch {};
            return err;
        };
        defer allocator.free(hostname);

        // Use the dedicated function for hostname validation
        const hostname_matches = env.validateEnvironmentForMachine(env_config, hostname);

        if (!hostname_matches) {
            output.printError(allocator,
                \\Current machine ('{s}') does not match target machines specified for environment '{s}'
                \\Use '--no-host' flag to bypass this check if needed
            , .{ hostname, env_name }) catch {};
            return error.TargetMachineMismatch;
        }
    }

    // Get absolute path of current working directory
    const cwd_path = runtime.cwdRealpath(allocator) catch |err| {
        output.printError(allocator, "Could not get current working directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(cwd_path);

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
        return err;
    };

    // Save the registry
    registry.save() catch |err| {
        output.printError(allocator, "Failed to save registry: {s}", .{@errorName(err)}) catch {};
        return err;
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
) !void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing environment name or ID argument.
            \\Usage: zenv deregister <name|id|.>
        , .{}) catch {};
        return error.EnvironmentNotFound;
    }

    const ref = registry.resolve(allocator, args[2]) catch |e| return present(allocator, registry, args[2], e);

    // Resolve once, then remove by handle. deregister returns the owned, detached
    // entry (and persists), so the success message reads a valid name post-removal.
    var removed = registry.deregister(ref) catch |err| {
        output.printError(allocator, "Failed to unregister environment: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer removed.deinit(allocator);

    output.print(allocator, "Environment '{s}' unregistered successfully.", .{removed.env_name}) catch {};
}

pub fn handleCdCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing environment name or ID argument
            \\Usage: zenv cd <name|id|.>
        , .{}) catch {};
        return error.EnvironmentNotFound;
    }

    const ref = registry.resolve(allocator, args[2]) catch |e| return present(allocator, registry, args[2], e);

    // Output just the project directory path
    output.rawOut(allocator, "{s}\n", .{registry.get(ref).project_dir}) catch |e| {
        output.printError(allocator, "Error writing to stdout: {s}", .{@errorName(e)}) catch {};
        return;
    };
}

pub fn handlePythonCommand(
    allocator: Allocator,
    args: []const []const u8,
) !void {
    // Check if we have a subcommand
    if (args.len < 3) {
        output.printError(allocator, "Missing subcommand for 'python' command", .{}) catch {};
        output.print(allocator, "Available subcommands: install, use, list", .{}) catch {};
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
            return err;
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
        return error.ArgsError;
    }
}

pub fn handleRmCommand(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing environment name or ID argument.
            \\Usage: zenv rm <name|id>
        , .{}) catch {};
        return error.EnvironmentNotFound;
    }

    const ref = registry.resolve(allocator, args[2]) catch |e| return present(allocator, registry, args[2], e);

    // Owned, detached entry: no raw identifier reaches the mutator (the old
    // ambiguity bug is unrepresentable), and venv_path is read AFTER removal.
    var removed = registry.deregister(ref) catch |err| {
        output.printError(allocator, "Failed to deregister environment: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer removed.deinit(allocator);

    output.print(allocator, "Environment '{s}' deregistered successfully.", .{removed.env_name}) catch {};

    output.print(allocator, "Attempting to remove: {s}", .{removed.venv_path}) catch {};
    runtime.deleteTree(removed.venv_path) catch |err| {
        output.printError(allocator, "Failed to remove '{s}': {s}", .{ removed.venv_path, @errorName(err) }) catch {};
        output.printError(allocator, "You may need to remove it manually.", .{}) catch {};
        return err;
    };

    output.print(allocator, "Directory '{s}' removed successfully.", .{removed.venv_path}) catch {};
    output.print(allocator, "Environment '{s}' removed.", .{removed.env_name}) catch {};
}

pub fn handleRunCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    // Need at least 4 args: zenv run <env> <command>
    if (args.len < 4) {
        output.printError(allocator, "Missing environment name or command. Usage: zenv run <name|id> <command> [args...]", .{}) catch {};
        return error.ArgsError;
    }

    const command = args[3];
    const command_args = args[4..];

    const ref = registry.resolve(allocator, args[2]) catch |e| return present(allocator, registry, args[2], e);
    const venv_path = registry.get(ref).venv_path;

    const activate_path = std.fs.path.join(allocator, &[_][]const u8{ venv_path, "activate.sh" }) catch |err| {
        output.printError(allocator, "Failed to construct activation script path: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(activate_path);

    // Build the argv that runs the command inside the activated environment
    // without any temp file (see `buildRunArgv`).
    const argv = buildRunArgv(allocator, activate_path, command, command_args) catch |err| {
        output.printError(allocator, "Failed to build command: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(argv);

    const term = runtime.exec(argv, .{}) catch |err| {
        output.printError(allocator, "Failed to run command: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    // Propagate the child's exit status as zenv's own, so callers (CI, scripts)
    // see the real result instead of a flattened 0/1. A signalled child maps to
    // the conventional 128 + signo.
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal, .stopped => |sig| {
            const signo: u8 = @truncate(@intFromEnum(sig));
            output.printError(allocator, "Command terminated by signal {d}", .{signo}) catch {};
            std.process.exit(128 +| signo);
        },
        .unknown => |status| {
            output.printError(allocator, "Command terminated abnormally (status {d})", .{status}) catch {};
            std.process.exit(1);
        },
    }
}

/// Shell snippet passed to `bash -c`. It sources the activation script (passed
/// as the first positional parameter `$1`), drops it from the positionals, then
/// `exec`s the user command (`$@`) so the command replaces the shell. Sourcing
/// honors `module load` and any activate hooks; `exec` makes the command's exit
/// status and signal disposition propagate directly back to zenv.
const run_runner = "set -e; source \"$1\"; shift; exec \"$@\"";

/// Builds the argv for `zenv run`: the user command and its arguments are passed
/// to `bash -c` as positional parameters, never interpolated into a script. Because
/// bash receives them as distinct argv entries it never re-parses them, so there is
/// no quoting/escaping or command-injection surface (e.g. a backtick or `$VAR` in an
/// argument stays literal). Caller owns the returned slice (free with `allocator.free`);
/// the element strings are borrowed from the inputs and must outlive it.
fn buildRunArgv(
    allocator: Allocator,
    activate_path: []const u8,
    command: []const u8,
    command_args: []const []const u8,
) ![]const []const u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    errdefer argv.deinit();
    // `zenv` becomes $0 (used only in any bash error message); activate_path is $1.
    try argv.appendSlice(&[_][]const u8{ "/bin/bash", "-c", run_runner, "zenv", activate_path, command });
    try argv.appendSlice(command_args);
    return argv.toOwnedSlice();
}

test "buildRunArgv passes command and args through verbatim" {
    const allocator = std.testing.allocator;
    // An argument crafted to trigger shell expansion if it were ever re-parsed.
    const nasty = "`whoami`$HOME \"q\" ; rm -rf /";
    const args = [_][]const u8{ "pip", "install", nasty };
    const argv = try buildRunArgv(allocator, "/envs/foo/activate.sh", "uv", &args);
    defer allocator.free(argv);

    const expected = [_][]const u8{
        "/bin/bash", "-c", run_runner, "zenv",
        "/envs/foo/activate.sh", // $1: sourced
        "uv", // the command
        "pip", "install", nasty, // args, untouched
    };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try std.testing.expectEqualStrings(e, a);
}

test "buildRunArgv handles a command with no extra args" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{};
    const argv = try buildRunArgv(allocator, "/a.sh", "python", &args);
    defer allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expectEqualStrings("python", argv[5]);
}

pub fn handleLogCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing environment name or ID argument.
            \\Usage: zenv log <name|id>
        , .{}) catch {};
        return error.EnvironmentNotFound;
    }

    const ref = registry.resolve(allocator, args[2]) catch |e| return present(allocator, registry, args[2], e);
    const entry = registry.get(ref);

    // Construct the path to the log file
    const log_file_path = std.fs.path.join(allocator, &[_][]const u8{ entry.venv_path, "zenv_setup.log" }) catch |err| {
        output.printError(allocator, "Failed to construct log file path: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(log_file_path);

    // Check if the log file exists
    runtime.access(log_file_path) catch |err| {
        if (err == error.FileNotFound) {
            output.printError(allocator, "No setup log found for environment '{s}'", .{entry.env_name}) catch {};
            output.printError(allocator, "The log file should be at: {s}", .{log_file_path}) catch {};
            return error.FileNotFound;
        } else {
            output.printError(allocator, "Error accessing log file '{s}': {s}", .{ log_file_path, @errorName(err) }) catch {};
            return err;
        }
    };

    // Read and print the log file
    const log_content = runtime.readFileAlloc(allocator, log_file_path, 10 * 1024 * 1024) catch |err| {
        output.printError(allocator, "Failed to read log file '{s}': {s}", .{ log_file_path, @errorName(err) }) catch {};
        return err;
    };
    defer allocator.free(log_content);

    // Output the log content
    output.rawOut(allocator, "{s}", .{log_content}) catch |err| {
        output.printError(allocator, "Error writing log to stdout: {s}", .{@errorName(err)}) catch {};
        return err;
    };
}

pub fn handleValidateCommand(
    allocator: Allocator,
    config_path: []const u8,
    args: []const []const u8,
) !void {

    // Use custom config path if provided as an argument
    var validate_config_path: []const u8 = config_path;

    if (args.len > 2) {
        validate_config_path = args[2];
        output.print(allocator, "Using provided file path: {s}", .{validate_config_path}) catch {};
    } else {
        output.print(allocator, "Using default config path: {s}", .{validate_config_path}) catch {};
    }

    // Check if file exists before validating
    if (runtime.access(validate_config_path)) |_| {
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
                else => std.process.exit(1),
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
) !void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing alias subcommand.
            \\Usage: zenv alias <create|remove|list|show> [arguments]
        , .{}) catch {};
        return error.ArgsError;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "create")) {
        try handleAliasCreate(allocator, registry, args);
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        try handleAliasRemove(allocator, registry, args);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try handleAliasList(allocator, registry, args);
    } else if (std.mem.eql(u8, subcommand, "show")) {
        try handleAliasShow(allocator, registry, args);
    } else {
        output.printError(allocator,
            \\Unknown alias subcommand '{s}'.
            \\Usage: zenv alias <create|remove|list|show> [arguments]
        , .{subcommand}) catch {};
        return error.ArgsError;
    }
}

fn handleAliasCreate(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 5) {
        output.printError(allocator,
            \\Missing arguments for alias create.
            \\Usage: zenv alias create <alias_name> <env_name|env_id>
        , .{}) catch {};
        return error.ArgsError;
    }

    const alias_name = args[3];
    const env_identifier = args[4];

    // Check if alias name would conflict with existing commands
    const reserved_names = [_][]const u8{ "setup", "activate", "list", "register", "deregister", "cd", "init", "rm", "python", "log", "run", "validate", "alias", "jupyter", "help", "version" };
    for (reserved_names) |reserved| {
        if (std.mem.eql(u8, alias_name, reserved)) {
            output.printError(allocator, "Alias name '{s}' conflicts with existing command.", .{alias_name}) catch {};
            return error.ArgsError;
        }
    }

    // Check if alias name is "." (reserved for current directory)
    if (std.mem.eql(u8, alias_name, ".")) {
        output.printError(allocator, "Alias name '.' is reserved for current directory notation.", .{}) catch {};
        return error.ArgsError;
    }

    // Resolve environment identifier to get the actual environment name
    const target_ref = registry.resolve(allocator, env_identifier) catch |e| return present(allocator, registry, env_identifier, e);
    const target_env_name = registry.get(target_ref).env_name;

    // Add alias to registry
    registry.addAlias(alias_name, target_env_name) catch |err| {
        switch (err) {
            error.EnvironmentNotFound => {
                output.printError(allocator, "Environment '{s}' not found.", .{env_identifier}) catch {};
                return err;
            },
            error.AliasAlreadyExists => {
                output.printError(allocator, "Alias '{s}' already exists.", .{alias_name}) catch {};
                return err;
            },
            else => {
                output.printError(allocator, "Failed to create alias: {s}", .{@errorName(err)}) catch {};
                return err;
            },
        }
    };

    // Save registry
    registry.save() catch |err| {
        output.printError(allocator, "Failed to save registry: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    output.print(allocator, "Alias '{s}' created for environment '{s}'.", .{ alias_name, target_env_name }) catch {};
}

fn handleAliasRemove(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing alias name.
            \\Usage: zenv alias remove <alias_name>
        , .{}) catch {};
        return error.ArgsError;
    }

    const alias_name = args[3];

    if (registry.removeAlias(alias_name)) {
        // Save registry
        registry.save() catch |err| {
            output.printError(allocator, "Failed to save registry: {s}", .{@errorName(err)}) catch {};
            return err;
        };

        output.print(allocator, "Alias '{s}' removed.", .{alias_name}) catch {};
    } else {
        output.printError(allocator, "Alias '{s}' not found.", .{alias_name}) catch {};
        return error.AliasNotFound;
    }
}

fn handleAliasList(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    _ = args;

    const aliases = registry.listAliases(allocator) catch |err| {
        output.printError(allocator, "Failed to list aliases: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer aliases.deinit();

    if (aliases.items.len == 0) {
        output.print(allocator, "No aliases defined.", .{}) catch {};
        return;
    }

    output.print(allocator, "Defined aliases:", .{}) catch {};
    for (aliases.items) |alias_entry| {
        output.print(allocator, "  {s} -> {s}", .{ alias_entry.alias, alias_entry.env_name }) catch {};
    }
}

fn handleAliasShow(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing alias name.
            \\Usage: zenv alias show <alias_name>
        , .{}) catch {};
        return error.ArgsError;
    }

    const alias_name = args[3];

    // An alias may be shared across several per-machine environments, so list
    // every holder with its target machines (resolution picks by current host).
    var found = false;
    for (registry.entries.items) |entry| {
        for (entry.aliases.items) |alias| {
            if (std.mem.eql(u8, alias, alias_name)) {
                if (!found) {
                    output.print(allocator, "Alias '{s}' resolves to:", .{alias_name}) catch {};
                    found = true;
                }
                output.print(allocator, "  {s} (target: {s})", .{ entry.env_name, entry.target_machines_str }) catch {};
                break;
            }
        }
    }
    if (!found) {
        output.printError(allocator, "Alias '{s}' not found.", .{alias_name}) catch {};
        return error.AliasNotFound;
    }
}

pub fn handleJupyterCommand(
    allocator: Allocator,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing jupyter subcommand.
            \\Usage: zenv jupyter <create|remove|list|check> [arguments]
        , .{}) catch {};
        return error.ArgsError;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "create")) {
        try handleJupyterCreate(allocator, args);
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        try handleJupyterRemove(allocator, args);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        try handleJupyterList(allocator);
    } else if (std.mem.eql(u8, subcommand, "check")) {
        try handleJupyterCheck(allocator);
    } else {
        output.printError(allocator,
            \\Unknown jupyter subcommand '{s}'.
            \\Usage: zenv jupyter <create|remove|list|check> [arguments]
        , .{subcommand}) catch {};
        return error.ArgsError;
    }
}

fn handleJupyterCreate(
    allocator: Allocator,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing environment name argument.
            \\Usage: zenv jupyter create <env_name> [--name <kernel_name>] [--display-name <display_name>]
        , .{}) catch {};
        return error.ArgsError;
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
            return error.ArgsError;
        }
    }

    try jupyter.createKernel(allocator, env_name, custom_name, custom_display_name);
}

fn handleJupyterRemove(
    allocator: Allocator,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing environment name argument.
            \\Usage: zenv jupyter remove <env_name>
        , .{}) catch {};
        return error.ArgsError;
    }

    const env_name = args[3];
    try jupyter.removeKernel(allocator, env_name);
}

fn handleJupyterList(
    allocator: Allocator,
) !void {
    try jupyter.listKernels(allocator);
}

fn handleJupyterCheck(
    allocator: Allocator,
) !void {
    try jupyter.checkJupyter(allocator);
}

pub fn handleRenameCommand(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator, "Usage: zenv rename <old_name|id> <new_name>", .{}) catch {};
        return error.ArgsError;
    }

    const old_identifier = args[2];
    const new_name = args[3];

    const ref = registry.resolve(allocator, old_identifier) catch |e| return present(allocator, registry, old_identifier, e);

    // Owned copies: the FS orchestration and rollback messages need old_name /
    // old_venv_path to outlive registry.rename (which frees the entry's copies).
    const old_name = try allocator.dupe(u8, registry.get(ref).env_name);
    defer allocator.free(old_name);

    const old_venv_path = try allocator.dupe(u8, registry.get(ref).venv_path);
    defer allocator.free(old_venv_path);
    const parent_dir = std.fs.path.dirname(old_venv_path) orelse {
        output.printError(allocator, "Invalid virtual environment path", .{}) catch {};
        return error.InvalidPath;
    };

    const new_venv_path = std.fs.path.join(allocator, &[_][]const u8{ parent_dir, new_name }) catch {
        output.printError(allocator, "Failed to construct new environment path", .{}) catch {};
        return error.OutOfMemory;
    };
    defer allocator.free(new_venv_path);

    runtime.access(new_venv_path) catch |err| {
        if (err != error.FileNotFound) {
            output.printError(allocator, "New environment directory already exists: {s}", .{new_venv_path}) catch {};
            return error.PathAlreadyExists;
        }
    };

    const has_jupyter_kernel = jupyter.hasKernel(allocator, old_name);

    output.print(allocator, "Renaming environment '{s}' to '{s}'...", .{ old_name, new_name }) catch {};

    // === ATOMIC OPERATIONS START ===

    runtime.rename(old_venv_path, new_venv_path) catch |err| {
        output.printError(allocator, "Failed to rename environment directory: {s}", .{@errorName(err)}) catch {};
        return error.IoError;
    };

    updateGeneratedScripts(allocator, old_name, new_name, old_venv_path, new_venv_path) catch |err| {
        runtime.rename(new_venv_path, old_venv_path) catch {};

        output.printError(allocator, "Failed to update generated scripts: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    registry.rename(ref, new_name) catch |err| {
        _ = updateGeneratedScripts(allocator, new_name, old_name, new_venv_path, old_venv_path) catch {};
        runtime.rename(new_venv_path, old_venv_path) catch {};

        switch (err) {
            error.EnvironmentAlreadyExists => {
                output.printError(allocator, "Environment name '{s}' already exists", .{new_name}) catch {};
            },
            error.InvalidEnvironmentName => {
                output.printError(allocator, "Invalid environment name '{s}'. Use only alphanumeric characters, hyphens, and underscores", .{new_name}) catch {};
            },
            else => {
                output.printError(allocator, "Failed to update registry: {s}", .{@errorName(err)}) catch {};
            },
        }
        return err;
    };

    if (has_jupyter_kernel) {
        jupyter.renameKernel(allocator, old_name, new_name, new_venv_path) catch |err| {
            registry.rename(ref, old_name) catch {}; // ref stays valid; re-saves
            _ = updateGeneratedScripts(allocator, new_name, old_name, new_venv_path, old_venv_path) catch {};
            runtime.rename(new_venv_path, old_venv_path) catch {};

            switch (err) {
                error.KernelExists => {
                    output.printError(allocator, "Jupyter kernel '{s}' already exists", .{new_name}) catch {};
                },
                else => {
                    output.printError(allocator, "Failed to rename Jupyter kernel: {s}", .{@errorName(err)}) catch {};
                },
            }
            return err;
        };
    }

    // registry.rename above already persisted; no separate save step.
    // === ATOMIC OPERATIONS END ===

    output.print(allocator, "Environment renamed successfully!", .{}) catch {};
    output.print(allocator, "  Name: {s} → {s}", .{ old_name, new_name }) catch {};
    output.print(allocator, "  Directory: {s} → {s}", .{ old_venv_path, new_venv_path }) catch {};

    if (has_jupyter_kernel) {
        output.print(allocator, "  Jupyter kernel: zenv-{s} → zenv-{s}", .{ old_name, new_name }) catch {};
    }

    output.print(allocator, "  Generated scripts updated", .{}) catch {};

    updateLocalConfigs(allocator, old_name, new_name, registry.get(ref).project_dir) catch |err| {
        output.printError(allocator, "Environment renamed successfully, but failed to update local config files: {s}", .{@errorName(err)}) catch {};
    };
}

fn updateGeneratedScripts(allocator: Allocator, old_name: []const u8, new_name: []const u8, old_venv_path: []const u8, new_venv_path: []const u8) !void {
    const activate_script_path = try std.fs.path.join(allocator, &[_][]const u8{ new_venv_path, "activate.sh" });
    defer allocator.free(activate_script_path);

    updateScriptFile(allocator, activate_script_path, old_name, new_name, old_venv_path, new_venv_path) catch |err| {
        output.printError(allocator, "Failed to update activate.sh: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    const setup_script_path = try std.fs.path.join(allocator, &[_][]const u8{ new_venv_path, "setup.sh" });
    defer allocator.free(setup_script_path);

    updateScriptFile(allocator, setup_script_path, old_name, new_name, old_venv_path, new_venv_path) catch |err| {
        if (err != error.FileNotFound) {
            output.printError(allocator, "Failed to update setup.sh: {s}", .{@errorName(err)}) catch {};
            return err;
        }
    };

    updateScriptsDirectory(allocator, new_venv_path, old_name, new_name, old_venv_path, new_venv_path) catch |err| {
        output.printError(allocator, "Failed to update scripts directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    // The module cache embeds absolute paths captured at setup; rather than
    // rewrite them, drop it. Next activate falls back to `module load` and the
    // next `zenv setup` regenerates a correct cache.
    for ([_][]const u8{ template.MODULE_CACHE_FILE, template.MODULE_CACHE_STAMP }) |name| {
        const cache_path = try std.fs.path.join(allocator, &[_][]const u8{ new_venv_path, name });
        defer allocator.free(cache_path);
        runtime.deleteFile(cache_path) catch {}; // best-effort; missing is fine
    }
}

fn updateScriptFile(allocator: Allocator, script_path: []const u8, old_name: []const u8, new_name: []const u8, old_venv_path: []const u8, new_venv_path: []const u8) !void {
    const content = try runtime.readFileAlloc(allocator, script_path, 1024 * 1024); // 1MB max
    defer allocator.free(content);

    var updated_content = std.array_list.Managed(u8).init(allocator);
    defer updated_content.deinit();

    var i: usize = 0;
    while (i < content.len) {
        if (i + old_name.len <= content.len and std.mem.eql(u8, content[i .. i + old_name.len], old_name)) {
            // Check if this is a standalone reference to the old environment name
            const before_ok = i == 0 or !std.ascii.isAlphanumeric(content[i - 1]);
            const after_ok = i + old_name.len == content.len or !std.ascii.isAlphanumeric(content[i + old_name.len]);

            if (before_ok and after_ok) {
                // Replace with new name
                try updated_content.appendSlice(new_name);
                i += old_name.len;
                continue;
            }
        }

        if (i + old_venv_path.len <= content.len and std.mem.eql(u8, content[i .. i + old_venv_path.len], old_venv_path)) {
            try updated_content.appendSlice(new_venv_path);
            i += old_venv_path.len;
            continue;
        }

        try updated_content.append(content[i]);
        i += 1;
    }

    try runtime.writeFile(script_path, updated_content.items);
}

fn updateScriptsDirectory(allocator: Allocator, venv_path: []const u8, old_name: []const u8, new_name: []const u8, old_venv_path: []const u8, new_venv_path: []const u8) !void {
    const scripts_dir = try std.fs.path.join(allocator, &[_][]const u8{ venv_path, "scripts" });
    defer allocator.free(scripts_dir);

    var dir = runtime.openDir(scripts_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return; // Scripts directory doesn't exist, that's fine
        return err;
    };
    defer dir.close(runtime.io);

    var iterator = dir.iterate();
    while (try iterator.next(runtime.io)) |entry| {
        if (entry.kind != .file) continue;

        if (std.mem.endsWith(u8, entry.name, ".sh") or
            std.mem.endsWith(u8, entry.name, ".py") or
            std.mem.endsWith(u8, entry.name, ".bash"))
        {
            const script_path = try std.fs.path.join(allocator, &[_][]const u8{ scripts_dir, entry.name });
            defer allocator.free(script_path);

            updateScriptFile(allocator, script_path, old_name, new_name, old_venv_path, new_venv_path) catch |err| {
                output.printError(allocator, "Failed to update script {s}: {s}", .{ entry.name, @errorName(err) }) catch {};
                return err;
            };
        }
    }
}

fn updateLocalConfigs(allocator: Allocator, old_name: []const u8, new_name: []const u8, project_dir: []const u8) !void {
    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ project_dir, "zenv.json" });
    defer allocator.free(config_path);

    output.print(allocator, "Updating local config: {s}", .{config_path}) catch {};

    const config_contents = runtime.readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            output.print(allocator, "No local config file found, skipping update", .{}) catch {};
            return; // No config file, that's fine
        }
        output.printError(allocator, "Failed to open config file: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(config_contents);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_contents, .{}) catch |err| {
        output.printError(allocator, "Failed to parse local config JSON: {s}", .{@errorName(err)}) catch {};
        return;
    };
    defer parsed.deinit();

    if (parsed.value.object.get(old_name)) |_| {
        output.print(allocator, "Found environment '{s}' in local config, updating to '{s}'", .{ old_name, new_name }) catch {};

        const old_key_pattern = try std.fmt.allocPrint(allocator, "\"{s}\":", .{old_name});
        defer allocator.free(old_key_pattern);

        const new_key_pattern = try std.fmt.allocPrint(allocator, "\"{s}\":", .{new_name});
        defer allocator.free(new_key_pattern);

        if (std.mem.indexOf(u8, config_contents, old_key_pattern)) |_| {
            const updated_contents = try std.mem.replaceOwned(u8, allocator, config_contents, old_key_pattern, new_key_pattern);
            defer allocator.free(updated_contents);

            try runtime.writeFile(config_path, updated_contents);

            output.print(allocator, "Successfully updated local config file", .{}) catch {};
        } else {
            output.printError(allocator, "Could not find key pattern in config file", .{}) catch {};
        }
    } else {
        output.print(allocator, "Environment '{s}' not found in local config, skipping update", .{old_name}) catch {};
    }
}
