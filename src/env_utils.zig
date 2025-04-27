const std = @import("std");
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const process_utils = @import("process_utils.zig");

// Helper function to parse cluster name from raw hostname (handles dot logic)
// Returns an owned string.
fn parseClusterFromHostname(allocator: Allocator, hostname: []const u8) ![]const u8 {
    // For hostname formats like jrlogin04.jureca, extract 'jureca'
    // Handles both jrlogin04.jureca and login01.jureca.fz-juelich.de
    if (mem.indexOfScalar(u8, hostname, '.')) |first_dot| {
        // Check if there's a second dot
        if (mem.indexOfScalarPos(u8, hostname, first_dot + 1, '.')) |second_dot| {
            // Extract the part between first and second dot
            return allocator.dupe(u8, hostname[first_dot + 1 .. second_dot]);
        } else {
            // Only one dot, extract the part after the dot
            return allocator.dupe(u8, hostname[first_dot + 1 ..]);
        }
    } else {
        std.log.warn("Hostname '{s}' does not contain '.', using full name as cluster name.", .{hostname});
        // Return a duplicate of the full hostname
        return allocator.dupe(u8, hostname);
    }
}

// Gets the logical cluster name.
// Tries HOSTNAME env var first, then falls back to the `hostname` command.
pub fn getClusterName(allocator: Allocator) ![]const u8 {
    var hostname_raw: ?[]const u8 = null;
    var hostname_needs_freeing = false;
    var stdout_to_free: ?[]const u8 = null;
    var stderr_to_free: ?[]const u8 = null;

    // Defer block ensures allocated memory is freed in all return paths
    defer {
        if (hostname_needs_freeing and hostname_raw != null) {
            allocator.free(hostname_raw.?);
        }
        if (stdout_to_free) |s| allocator.free(s);
        if (stderr_to_free) |s| allocator.free(s);
    }

    var hostname_from_env_tmp: ?[]const u8 = null; // Temporary holder

    // Attempt to get the env var
    const env_result = std.process.getEnvVarOwned(allocator, "HOSTNAME");

    // Check the result
    if (env_result) |h_env| {
        // Success!
        hostname_from_env_tmp = h_env;
        hostname_needs_freeing = true; // Set flag early, it will be freed by defer if not used
    } else |err| {
        // Handle the error
        if (err == error.EnvironmentVariableNotFound) {
            std.log.debug("HOSTNAME not set, attempting 'hostname' command.", .{});
            // Do nothing, hostname_from_env_tmp remains null
        } else {
            std.log.err("Error reading HOSTNAME: {s}", .{@errorName(err)});
            // Make sure allocated memory is freed before returning error
             if (hostname_needs_freeing and hostname_from_env_tmp != null) {
                 allocator.free(hostname_from_env_tmp.?);
             }
            return err; // Propagate other errors like OOM
        }
    }

    // Now check if hostname_from_env_tmp is set and non-empty
    if (hostname_from_env_tmp) |h_env_val| {
        if (h_env_val.len > 0) {
            hostname_raw = h_env_val;
            // hostname_needs_freeing is already true
            std.log.debug("Using HOSTNAME from environment: {s}", .{hostname_raw.?});
        } else {
            // HOSTNAME is set but empty
            allocator.free(h_env_val); // Free the empty string
            hostname_needs_freeing = false; // It's freed now
            // hostname_raw remains null
            std.log.warn("HOSTNAME environment variable is set but empty. Attempting 'hostname' command.", .{});
        }
    } else {
        // hostname_from_env_tmp was null (either not found or error handled)
        // hostname_raw remains null
    }

    // If hostname_raw is still null, execute the 'hostname' command
    if (hostname_raw == null) {
        const argv = [_][]const u8{"hostname"};
        const result = process_utils.execAllowFail(allocator, &argv, null, .{}) catch |err| {
            std.log.err("Failed to execute 'hostname' command: {s}", .{@errorName(err)});
            return ZenvError.ProcessError;
        };

        // Store command output buffers to be freed by the defer block
        stdout_to_free = result.stdout;
        stderr_to_free = result.stderr;

        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    // Use result.stderr for potentially useful error info
                    std.log.err("'hostname' command failed with code {d}. Stderr: {s}", .{ code, result.stderr });
                    return ZenvError.ProcessError;
                }
                std.log.debug("'hostname' command succeeded.", .{});
            },
            else => |term| {
                std.log.err("'hostname' command terminated unexpectedly: {?}. Stderr: {s}", .{ term, result.stderr });
                return ZenvError.ProcessError;
            },
        }

        const trimmed_hostname = mem.trim(u8, result.stdout, &std.ascii.whitespace);
        if (trimmed_hostname.len == 0) {
            std.log.err("'hostname' command returned empty output after trimming.", .{});
            return ZenvError.MissingHostname;
        }
        hostname_raw = trimmed_hostname; // Use the trimmed slice for parsing
        hostname_needs_freeing = false; // Handled by stdout_to_free in defer
        std.log.debug("Using hostname from command output: {s}", .{hostname_raw.?});
    }

    // At this point, hostname_raw MUST be non-null and contain the raw hostname
    if (hostname_raw == null) {
        // This should be unreachable
        std.log.err("Internal logic error: hostname_raw is null after checks.", .{});
        return ZenvError.MissingHostname;
    }

    // Parse the cluster name from the raw hostname (returns an owned string)
    return try parseClusterFromHostname(allocator, hostname_raw.?);
}

// Attempts to resolve the environment name based on args or auto-detection by cluster.
pub fn resolveEnvironmentName(
    allocator: Allocator, // Allocator for duplicating the result
    config: *const ZenvConfig,
    args: []const []const u8, // Command line arguments [exec_path, command, maybe_env_name, ...]
    command_name: []const u8, // e.g., "setup" or "activate"
) ZenvError![]const u8 {
    if (args.len >= 3) {
        // Environment name provided explicitly
        const requested_env = args[2];
        if (!config.environments.contains(requested_env)) {
            std.log.err("Environment '{s}' not found in '{s}'.", .{ requested_env, "zenv.json" }); // Assuming config path is zenv.json
            return ZenvError.EnvironmentNotFound;
        }
        // Return a duplicated string as the caller will own it
        return allocator.dupe(u8, requested_env);
    } else {
        // Attempt auto-detection based on current cluster
        std.log.info("No environment name specified, attempting auto-detection...", .{});
        const current_cluster = getClusterName(allocator) catch |err| {
             std.log.err("Failed to get cluster name for auto-detection: {s}", .{@errorName(err)});
             // Use std.log.err for user-facing messages here instead of direct print
             if (err == ZenvError.MissingHostname) {
                 // Format the message separately
                 const msg = std.fmt.allocPrint(allocator,
                    "Error: Could not auto-detect environment. HOSTNAME not set." ++
                    " Please specify environment name: zenv {s} <environment_name>",
                    .{command_name}
                 ) catch |e| blk: {
                     std.log.err("Failed to format MissingHostname error message: {s}", .{@errorName(e)});
                     break :blk "<Failed to format error message>"; // Yield the literal
                 };
                 defer if (!std.mem.eql(u8, msg, "<Failed to format error message>")) allocator.free(msg);
                 // Log the pre-formatted message
                 std.log.err("{s}", .{msg});
             } else {
                 // Format the message separately
                 const msg = std.fmt.allocPrint(allocator,
                    "Error: Could not auto-detect environment due to error getting cluster name." ++
                    " Please specify environment name: zenv {s} <environment_name>",
                    .{command_name}
                 ) catch |e| blk: {
                     std.log.err("Failed to format ClusterName error message: {s}", .{@errorName(e)});
                     break :blk "<Failed to format error message>"; // Yield the literal
                 };
                 defer if (!std.mem.eql(u8, msg, "<Failed to format error message>")) allocator.free(msg);
                 // Log the pre-formatted message
                 std.log.err("{s}", .{msg});
             }
             return err; // Propagate the error
        };
        defer allocator.free(current_cluster);
        std.log.debug("Current cluster detected as: {s}", .{current_cluster});

        var matching_envs = std.ArrayList([]const u8).init(allocator);
        defer matching_envs.deinit(); // Items are slices from config, no need to free them here

        var iter = config.environments.iterator();
        while (iter.next()) |entry| {
            // Match if target exists and equals current cluster
            if (entry.value_ptr.target_machine) |target| { // Updated field name
                if (mem.eql(u8, target, current_cluster)) {
                    try matching_envs.append(entry.key_ptr.*);
                }
            }
        }

        if (matching_envs.items.len == 0) {
            // Format the error string first
            const err_msg = std.fmt.allocPrint(allocator,
                "Error: Auto-detection failed. No environments found targeting your cluster '{s}'." ++
                " Please specify environment name: zenv {s} <environment_name>" ++
                " Use 'zenv list --all' to see available environments.",
                .{ current_cluster, command_name }
            ) catch |e| {
                // Fallback log if formatting fails
                std.log.err("Failed to format auto-detection error message: {s}", .{@errorName(e)});
                return ZenvError.EnvironmentNotFound;
            };
            defer allocator.free(err_msg);
            // Log the pre-formatted string
            std.log.err("{s}", .{err_msg});
            return ZenvError.EnvironmentNotFound;
        } else if (matching_envs.items.len > 1) {
            // Use std.log.err for this user-facing failure message
            std.log.err("Error: Auto-detection failed. Multiple environments found targeting your cluster '{s}':", .{current_cluster});
            for (matching_envs.items) |item| {
                 // Keep printing the list items to stderr for clarity, but use log for the main error
                 std.io.getStdErr().writer().print("  - {s}\n", .{item}) catch {};
            }
             std.log.err("Please specify which one to use: zenv {s} <environment_name>", .{command_name});
            return ZenvError.EnvironmentNotFound;
        } else {
            // Exactly one match found
            const resolved_env = matching_envs.items[0];
            std.log.info("Auto-selected environment '{s}' based on cluster.", .{resolved_env});
            // Return a duplicated string as the caller will own it
            return allocator.dupe(u8, resolved_env);
        }
    }
}
