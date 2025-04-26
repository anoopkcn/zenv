const std = @import("std");
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
// Import errors and config types
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
// We need ZenvConfig definition to check environments
const config_module = @import("config.zig"); 
const ZenvConfig = config_module.ZenvConfig;

// Gets the logical cluster name from the HOSTNAME environment variable.
pub fn getClusterName(allocator: Allocator) ![]const u8 {
    const hostname = std.process.getEnvVarOwned(allocator, "HOSTNAME") catch |err| {
        std.log.err("Error reading HOSTNAME: {s}", .{@errorName(err)});
        if (err == error.EnvironmentVariableNotFound) return ZenvError.MissingHostname;
        return err; // Propagate other errors like OOM
    };
    defer allocator.free(hostname); // Free the original hostname string after use

    // For hostname formats like jrlogin04.jureca, extract 'jureca'
    // Handles both jrlogin04.jureca and login01.jureca.fz-juelich.de
    if (mem.indexOfScalar(u8, hostname, '.')) |first_dot| {
        // Check if there's a second dot
        if (mem.indexOfScalarPos(u8, hostname, first_dot + 1, '.')) |second_dot| {
            // Extract the part between first and second dot
            return allocator.dupe(u8, hostname[first_dot + 1..second_dot]);
        } else {
            // Only one dot, extract the part after the dot
            return allocator.dupe(u8, hostname[first_dot + 1..]);
        }
    } else {
        std.log.warn("HOSTNAME '{s}' does not contain '.', using full name as cluster name.", .{hostname});
        // Return a duplicate since the original hostname is freed by the defer
        return allocator.dupe(u8, hostname);
    }
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
             if (err == ZenvError.MissingHostname) {
                 std.io.getStdErr().writer().print(
                     \\Error: Could not auto-detect environment. HOSTNAME not set.
                     \\Please specify environment name: zenv {s} <environment_name>
                 , .{command_name}) catch {};
             } else {
                 std.io.getStdErr().writer().print(
                      \\Error: Could not auto-detect environment due to error getting cluster name.
                      \\Please specify environment name: zenv {s} <environment_name>
                 , .{command_name}) catch {};
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
            if (entry.value_ptr.target) |target| {
                if (mem.eql(u8, target, current_cluster)) {
                    try matching_envs.append(entry.key_ptr.*);
                }
            }
        }

        if (matching_envs.items.len == 0) {
            std.io.getStdErr().writer().print(
                \\Error: Auto-detection failed. No environments found targeting your cluster '{s}'.
                \\Please specify environment name: zenv {s} <environment_name>
                \\Use 'zenv list --all' to see available environments.
            , .{ current_cluster, command_name }) catch {};
            return ZenvError.EnvironmentNotFound;
        } else if (matching_envs.items.len > 1) {
            std.io.getStdErr().writer().print(
                \\Error: Auto-detection failed. Multiple environments found targeting your cluster '{s}':
            , .{current_cluster}) catch {};
            for (matching_envs.items) |item| {
                std.io.getStdErr().writer().print("  - {s}\n", .{item}) catch {};
            }
            std.io.getStdErr().writer().print(
                \\Please specify which one to use: zenv {s} <environment_name>
            , .{command_name}) catch {};
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
