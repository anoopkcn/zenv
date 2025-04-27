const std = @import("std");
const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const utils = @import("utils.zig");
// const process = std.process; // No longer needed here
// const fs = std.fs; // No longer needed here
const Allocator = std.mem.Allocator;

pub fn handleSetupCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) anyerror!void {
    const env_config = utils.getAndValidateEnvironment(allocator, config, args, handleErrorFn) orelse return;
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

    // 1. Combine Dependencies
    var all_required_deps = std.ArrayList([]const u8).init(allocator);
    // Ensure deinit happens even if parsing fails later
    defer {
        // We need to free duped lines from parseRequirementsTxt if they exist
        // Since parseRequirementsTxt now appends dupes, we free them here.
        // Dependencies from config are assumed to be string literals or owned by config.
        // Dependencies from parsePyprojectToml are also duped.
        // TODO: Improve memory ownership clarity - maybe have parsers return owned lists?
        for (all_required_deps.items) |item| {
            // This is imperfect; we don't know which ones were duped.
            // Assuming parse* functions always dupe for now.
            // A better approach would be a struct { ptr: []const u8, owned: bool }
            allocator.free(item); // Potential double-free if item came from config.dependencies
        }
        all_required_deps.deinit();
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
            handleErrorFn(ZenvError.PathResolutionFailed); // Use specific error
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

    // 2. Create sc_venv base directory structure
    try utils.createScVenvDir(allocator, env_name);

    // 3. Perform the main environment setup using the utility function
    //    This now includes dependency validation, script generation, and execution.
    //    Pass the combined list of dependencies.
    try utils.setupEnvironment(allocator, env_config, env_name, all_required_deps.items, force_deps);

    // 4. Create the final activation script (using a separate utility)
    try utils.createActivationScript(allocator, env_config, env_name);

    std.log.info("Environment '{s}' setup complete.", .{env_name});
}

// setupEnvironment moved to utils.zig

pub fn handleActivateCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) void {
    const env_config = utils.getAndValidateEnvironment(allocator, config, args, handleErrorFn) orelse return;
    const env_name = args[2];

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = std.fs.cwd().realpath(".", &abs_path_buf) catch |err| {
        std.log.err("Could not get current working directory: {s}", .{@errorName(err)});
        handleErrorFn(err);
        return;
    };

    const writer = std.io.getStdOut().writer(); // Use constant for clarity

    writer.print(
        \\# To activate environment '{s}', run the following commands:
        \\# ---------------------------------------------------------
        \\# Option 1: Use the activation script (recommended)
        \\source {s}/sc_venv/{s}/activate.sh
        \\
        \\# Option 2: Manual activation
        \\
    , .{ env_name, cwd_path, env_name }) catch |e| {
        std.log.err("Error writing to stdout: {s}", .{@errorName(e)});
        return;
    };

    // Print module load commands using the utility
    utils.printManualActivationModuleCommands(allocator, writer, env_config) catch |e| {
        std.log.err("Error writing module commands: {s}", .{@errorName(e)});
        return;
    };

    // Print virtual environment activation with absolute path
    writer.print("source {s}/sc_venv/{s}/venv/bin/activate\n", .{ cwd_path, env_name }) catch |e| {
        std.log.err("Error writing to stdout: {s}", .{@errorName(e)});
        return;
    };

    // Print custom environment variables
    if (env_config.custom_activate_vars.count() > 0) {
        writer.print("# Custom environment variables:\n", .{}) catch {};
        var vars_iter = env_config.custom_activate_vars.iterator();
        while (vars_iter.next()) |entry| {
            // Basic shell escaping for value
            // Replace single quote with '\''
            var escaped_value_list = std.ArrayList(u8).init(allocator);
            defer escaped_value_list.deinit();
            for (entry.value_ptr.*) |char| {
                if (char == '\'') {
                    escaped_value_list.appendSlice("'\\''") catch |e| {
                        std.log.err("Failed to allocate for escaping: {s}", .{@errorName(e)});
                        return;
                    };
                } else {
                    escaped_value_list.append(char) catch |e| {
                        std.log.err("Failed to allocate for escaping: {s}", .{@errorName(e)});
                        return;
                    };
                }
            }
            writer.print("export {s}='{s}'\n", .{ entry.key_ptr.*, escaped_value_list.items }) catch |e| {
                std.log.err("Error writing to stdout: {s}", .{@errorName(e)});
                return;
            };
        }
    }

    // Print footer and metadata
    writer.print("# ---------------------------------------------------------\n", .{}) catch {};
    if (env_config.description) |desc| {
        writer.print("# Description: {s}\n", .{desc}) catch {};
    }
    writer.print("# Target Machine: {s}\n", .{env_config.target_machine}) catch {};
}

pub fn handleListCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
) void {
    const stdout = std.io.getStdOut().writer();
    const list_all = args.len > 2 and std.mem.eql(u8, args[2], "--all");

    var current_hostname: ?[]const u8 = null;
    var hostname_allocd = false; // Track if hostname was allocated
    var use_hostname_filter = !list_all; // New variable to track if we should use hostname filter

    if (use_hostname_filter) {
        current_hostname = config_module.ZenvConfig.getHostname(allocator) catch |err| {
            std.log.warn("Could not determine current hostname for filtering: {s}. Listing all environments.", .{@errorName(err)});
            // Don't apply hostname filter if we can't get the hostname
            use_hostname_filter = false;
            return;
        };
        if (current_hostname != null) {
            hostname_allocd = true; // Mark that we need to free it
        }
    }
    // Ensure hostname is freed if allocated
    defer if (hostname_allocd and current_hostname != null) allocator.free(current_hostname.?);

    stdout.print("Available zenv environments:\n", .{}) catch {};
    stdout.print("----------------------------\n", .{}) catch {};

    var iter = config.environments.iterator();
    var count: usize = 0;
    while (iter.next()) |entry| {
        const env_name = entry.key_ptr.*;
        const env_config = entry.value_ptr.*;

        // Filter by target machine if requested and hostname was successfully obtained
        if (use_hostname_filter and current_hostname != null) {
            // Use the same enhanced matching logic as getAndValidateEnvironment for consistency
            const target = env_config.target_machine;
            const hostname = current_hostname.?;
            const hostname_matches = blk: {
                if (std.mem.eql(u8, hostname, target)) break :blk true; // Exact
                if (hostname.len > target.len + 1 and hostname[hostname.len - target.len - 1] == '.') {
                    const suffix = hostname[hostname.len - target.len ..];
                    if (std.mem.eql(u8, suffix, target)) break :blk true; // Domain suffix
                }
                if (std.mem.indexOf(u8, hostname, target) != null) break :blk true; // Substring fallback
                break :blk false;
            };

            if (!hostname_matches) {
                continue; // Skip this environment
            }
        }

        // Print environment name and target machine
        stdout.print("- {s} (Target: {s}", .{ env_name, env_config.target_machine }) catch {};
        // Optionally print description
        if (env_config.description) |desc| {
            stdout.print(" - {s}", .{desc}) catch {};
        }
        stdout.print(")\n", .{}) catch {};
        count += 1;
    }
    stdout.print("----------------------------\n", .{}) catch {};

    // Print summary message
    if (count == 0) {
        if (!list_all and current_hostname != null) {
            stdout.print("No environments found configured for the current machine ('{s}'). Use 'zenv list --all' to see all configured environments.\n", .{current_hostname.?}) catch {};
        } else if (!list_all and current_hostname == null) {
            stdout.print("No environments found. (Could not determine current hostname for filtering).\n", .{}) catch {};
        } else { // Listing all or hostname failed
            stdout.print("No environments found in the configuration file.\n", .{}) catch {};
        }
    } else {
        if (!list_all and current_hostname != null) {
            stdout.print("Found {d} environment(s) for the current machine ('{s}').\n", .{ count, current_hostname.? }) catch {};
        } else { // Listing all or hostname failed
            stdout.print("Found {d} total environment(s).\n", .{count}) catch {};
        }
    }
}

// ** Removed helper function placeholder for shell escaping **
// It's handled inline in handleActivateCommand now.
