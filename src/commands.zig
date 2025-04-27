const std = @import("std");
const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const utils = @import("utils.zig");
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

    // 2. Create zenv base directory structure
    try utils.createVenvDir(allocator, env_name);

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
    //    This now includes dependency validation, script generation, and execution.
    //    Pass the slice of dependencies.
    try utils.setupEnvironment(allocator, env_config, env_name, deps_slice, force_deps);

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
    // We only use env_config for validation, not for output
    _ = utils.getAndValidateEnvironment(allocator, config, args, handleErrorFn) orelse return;
    const env_name = args[2];

    // Get absolute path of current working directory
    var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = std.fs.cwd().realpath(".", &abs_path_buf) catch |err| {
        std.log.err("Could not get current working directory: {s}", .{@errorName(err)});
        handleErrorFn(err);
        return;
    };

    const writer = std.io.getStdOut().writer(); // Use constant for clarity

    // Simply output the path to the activation script
    // Ensure there's a newline at the end to avoid shell prompt appearing on the same line
    writer.print("{s}/zenv/{s}/activate.sh\n", .{ cwd_path, env_name }) catch |e| {
        std.log.err("Error writing to stdout: {s}", .{@errorName(e)});
        return;
    };
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
        current_hostname = config.getHostname() catch |err| {
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

    var iter = config.environments.iterator();
    var count: usize = 0;
    while (iter.next()) |entry| {
        const env_name = entry.key_ptr.*;
        const env_config = entry.value_ptr.*;

        // Filter by target machine if requested and hostname was successfully obtained
        if (use_hostname_filter and current_hostname != null) {
            // Use the same enhanced matching logic as getAndValidateEnvironment for consistency
            // Use the pure hostname validation function
            const hostname_matches = utils.validateEnvironmentForMachine(env_config, current_hostname.?);

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
