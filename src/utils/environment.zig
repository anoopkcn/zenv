const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const errors = @import("errors.zig");
const process = std.process;
const fs = std.fs;

const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const RegistryEntry = config_module.RegistryEntry;


// Normalizes a hostname for better matching
// Handles common variations like ".local" suffix on macOS
fn normalizeHostname(hostname: []const u8) []const u8 {
    // Remove ".local" suffix common in macOS environments
    if (std.mem.endsWith(u8, hostname, ".local")) {
        return hostname[0 .. hostname.len - 6];
    }
    return hostname;
}

// Checks if pattern with wildcards matches a string
// Supports * (any characters) and ? (single character)
fn patternMatches(pattern: []const u8, str: []const u8) bool {
    // Empty pattern only matches empty string
    if (pattern.len == 0) return str.len == 0;

    // Special case: single * matches anything
    if (pattern.len == 1 and pattern[0] == '*') return true;

    // Empty string only matches if pattern is just asterisks
    if (str.len == 0) {
        for (pattern) |c| {
            if (c != '*') return false;
        }
        return true;
    }

    // Handle common prefix pattern: "compute-*"
    if (pattern.len >= 2 and pattern[pattern.len - 1] == '*') {
        // Check if it's a simple prefix pattern without other wildcards
        var has_other_wildcards = false;
        for (pattern[0 .. pattern.len - 1]) |c| {
            if (c == '*' or c == '?') {
                has_other_wildcards = true;
                break;
            }
        }

        if (!has_other_wildcards) {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, str, prefix);
        }
    }

    // Handle common suffix pattern: "*.example.com"
    if (pattern.len >= 2 and pattern[0] == '*') {
        // Check if it's a simple suffix pattern without other wildcards
        var has_other_wildcards = false;
        for (pattern[1..]) |c| {
            if (c == '*' or c == '?') {
                has_other_wildcards = true;
                break;
            }
        }

        if (!has_other_wildcards) {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, str, suffix);
        }
    }

    // For other patterns, use a more general algorithm (recursive)
    if (pattern[0] == '*') {
        // '*' can match 0 or more characters
        // Try matching rest of pattern with current string, or
        // keep the asterisk and match with next character of string
        return (str.len > 0 and patternMatches(pattern, str[1..])) or patternMatches(pattern[1..], str);
    } else if (pattern[0] == '?') {
        // '?' matches any single character
        return str.len > 0 and patternMatches(pattern[1..], str[1..]);
    } else if (pattern[0] == str[0]) {
         // Match exact character
         return str.len > 0 and patternMatches(pattern[1..], str[1..]);
    }

    return false;
}


// Splits a hostname into domain components and checks if any match the target
fn matchDomainComponent(hostname: []const u8, target: []const u8) bool {
    var parts = std.mem.splitScalar(u8, hostname, '.');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, target)) {
            return true;
        }
    }
    return false;
}

// Internal function to validate environment for a specific hostname
fn validateEnvironmentForMachine(env_config: *const EnvironmentConfig, hostname: []const u8) bool {
    // Special case: No target machines means any machine is valid
    if (env_config.target_machines.items.len == 0) {
        return true;
    }

    // Check against each target machine in the list
    for (env_config.target_machines.items) |target| {
        // Special cases for universal targets
        if (std.mem.eql(u8, target, "localhost") or
            std.mem.eql(u8, target, "any") or
            std.mem.eql(u8, target, "*"))
        {
            return true;
        }

        // Normalize the hostname
        const norm_hostname = normalizeHostname(hostname);

        // Check if the target contains wildcard characters
        const has_wildcards = std.mem.indexOfAny(u8, target, "*?") != null;

        // If target has wildcards, use pattern matching
        if (has_wildcards) {
            if (patternMatches(target, norm_hostname)) {
                return true;
            }
            continue; // Try next target
        }

        // Otherwise, try various matching strategies in order of specificity

        // 1. Exact match (most specific)
        if (std.mem.eql(u8, norm_hostname, target)) {
            return true;
        }

        // 2. Domain component match (e.g., matching "jureca" in "jrlogin08.jureca")
        if (matchDomainComponent(norm_hostname, target)) {
            return true;
        }

        // 3. Check if target is a domain suffix like ".example.com"
        // (Ensuring hostname is longer than the suffix)
        if (target.len > 0 and target[0] == '.' and norm_hostname.len > target.len and
            std.mem.endsWith(u8, norm_hostname, target))
        {
            return true;
        }

        // 4. Domain suffix match (e.g., node123.cluster matches target cluster)
        if (norm_hostname.len > target.len + 1 and norm_hostname[norm_hostname.len - target.len - 1] == '.') {
            const suffix = norm_hostname[norm_hostname.len - target.len ..];
            if (std.mem.eql(u8, suffix, target)) {
                return true;
            }
        }
    }

    // No match found with any target machine
    return false;
}

// Helper function to get hostname using the `hostname` command (internal)
pub fn getHostnameFromCommand(allocator: Allocator) ![]const u8 {
    std.log.debug("Executing 'hostname' command", .{});
    const argv = [_][]const u8{"hostname"};
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe; // Capture stderr as well
    try child.spawn();

    const stdout = child.stdout.?.readToEndAlloc(allocator, 128) // Limit size for hostname
        catch |err| {
            std.log.err("Failed to read stdout from `hostname` command: {s}", .{@errorName(err)});
            _ = child.wait() catch {}; // Ensure child process is waited on
            return error.ProcessError;
        };
    errdefer allocator.free(stdout);

    const stderr = child.stderr.?.readToEndAlloc(allocator, 512) // Limit stderr size
        catch |err| {
            std.log.err("Failed to read stderr from `hostname` command: {s}", .{@errorName(err)});
            _ = child.wait() catch {};
            return error.ProcessError;
        };
    defer allocator.free(stderr);

    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        std.log.err("`hostname` command failed. Term: {?} Stderr: {s}", .{ term, stderr });
        return error.ProcessError;
    }

    const trimmed_hostname = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (trimmed_hostname.len == 0) {
        std.log.err("`hostname` command returned empty output.", .{});
        return error.MissingHostname;
    }
    std.log.debug("Got hostname from command: '{s}'", .{trimmed_hostname});
    // Return a duplicate of the trimmed hostname
    return allocator.dupe(u8, trimmed_hostname);
}

// Get hostname using environment variables or fallback to command
pub fn getSystemHostname(allocator: Allocator) ![]const u8 {
    std.log.debug("Attempting to get hostname from environment variable...", .{});

    // Try HOSTNAME first
    const hostname_env = std.process.getEnvVarOwned(allocator, "HOSTNAME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            // Try HOST if HOSTNAME is not found
            std.log.debug("HOSTNAME not set, trying HOST...", .{});
            const host_env = std.process.getEnvVarOwned(allocator, "HOST") catch |err2| {
                if (err2 == error.EnvironmentVariableNotFound) {
                    // Fallback to command if neither env var is set
                    std.log.debug("HOST not set, falling back to 'hostname' command...", .{});
                    return getHostnameFromCommand(allocator);
                } else {
                    // Propagate other errors from getting HOST
                    std.log.err("Failed to get HOST environment variable: {s}", .{@errorName(err2)});
                    return err2;
                }
            };
            // Check if HOST was empty
            if (host_env.len == 0) {
                allocator.free(host_env);
                std.log.debug("HOST was empty, falling back to 'hostname' command...", .{});
                return getHostnameFromCommand(allocator);
            }
            std.log.debug("Got hostname from HOST: '{s}'", .{host_env});
            return host_env; // Return hostname from HOST
        } else {
            // Propagate other errors from getting HOSTNAME
            std.log.err("Failed to get HOSTNAME environment variable: {s}", .{@errorName(err)});
            return err;
        }
    };

    // Check if HOSTNAME was empty
    if (hostname_env.len == 0) {
        allocator.free(hostname_env);
        std.log.debug("HOSTNAME was empty, falling back to 'hostname' command...", .{});
        return getHostnameFromCommand(allocator);
    }

    std.log.debug("Got hostname from HOSTNAME: '{s}'", .{hostname_env});
    return hostname_env;
}

// Simple check for hostname matching target machine (used by list command)
pub fn checkHostnameMatch(hostname: []const u8, target_machine: []const u8) bool {
    // This function is only for the simplified registry case of a single target machine
    // Use the same matching logic for consistency

    // Special cases for universal targets
    if (std.mem.eql(u8, target_machine, "localhost") or
        std.mem.eql(u8, target_machine, "any") or
        std.mem.eql(u8, target_machine, "*"))
    {
        return true;
    }

    // Normalize the hostname
    const norm_hostname = normalizeHostname(hostname);

    // Check if the target contains wildcard characters
    const has_wildcards = std.mem.indexOfAny(u8, target_machine, "*?") != null;

    // If target has wildcards, use pattern matching
    if (has_wildcards) {
        return patternMatches(target_machine, norm_hostname);
    }

    // Try various matching strategies

    // 1. Exact match
    if (std.mem.eql(u8, norm_hostname, target_machine)) {
        return true;
    }

    // 2. Domain component match
    if (matchDomainComponent(norm_hostname, target_machine)) {
        return true;
    }

    // 3. Domain suffix like ".example.com"
    if (target_machine.len > 0 and target_machine[0] == '.' and norm_hostname.len > target_machine.len and
        std.mem.endsWith(u8, norm_hostname, target_machine))
    {
        return true;
    }

    // 4. Domain suffix match (e.g., node123.cluster matches target cluster)
    if (norm_hostname.len > target_machine.len + 1 and
        norm_hostname[norm_hostname.len - target_machine.len - 1] == '.')
    {
        const suffix = norm_hostname[norm_hostname.len - target_machine.len ..];
        if (std.mem.eql(u8, suffix, target_machine)) {
            return true;
        }
    }

    return false;
}

// Get and validate environment configuration based on args and current hostname
pub fn getAndValidateEnvironment(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: [][]const u8,
    handleErrorFn: fn (anyerror) void,
) ?*const EnvironmentConfig {
    if (args.len < 3) {
        std.log.err("Missing environment name argument for command '{s}'", .{args[1]});
        handleErrorFn(error.ArgsError); // Use a more specific error
        return null;
    }
    const env_name = args[2];

    const env_config = config.getEnvironment(env_name) orelse {
        std.log.err("Environment '{s}' not found in configuration.", .{env_name});
        handleErrorFn(error.EnvironmentNotFound);
        return null;
    };

    // Use validation function from config module (already validates required fields)
    if (config_module.ZenvConfig.validateEnvironment(env_config, env_name)) |err| {
        std.log.err("Invalid environment configuration for '{s}': {s}", .{ env_name, @errorName(err) });
        handleErrorFn(err);
        return null;
    }

    // Check for --no-host flag to bypass hostname validation
    var skip_hostname_check = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-host")) {
            skip_hostname_check = true;
            std.log.info("'--no-host' flag detected. Skipping hostname validation.", .{});
            break;
        }
    }

    if (skip_hostname_check) {
        std.log.info("Hostname validation bypassed for environment '{s}'.", .{env_name});
        return env_config;
    }

    // Get current hostname
    var hostname: []const u8 = undefined;
    hostname = getSystemHostname(allocator) catch |err| { // Call the local function
        std.log.err("Failed to get current hostname: {s}", .{@errorName(err)});
        handleErrorFn(err);
        return null;
    };
    defer allocator.free(hostname);

    // Validate hostname against target_machines using the internal helper
    std.log.debug("Comparing current hostname '{s}' with target machines for env '{s}'", .{ hostname, env_name });

    const hostname_matches = validateEnvironmentForMachine(env_config, hostname);

    if (!hostname_matches) {
        // Format the target machines for the error message, handle OOM gracefully
        var formatted_targets: []const u8 = undefined;
        var formatted_targets_allocated = false;
        format_block: {
            var targets_buffer = std.ArrayList(u8).init(allocator);
            defer targets_buffer.deinit();

            // Attempt to format the string
            targets_buffer.appendSlice("[") catch |err| {
                std.log.err("Failed to format target machines for error message: {s}", .{@errorName(err)});
                handleErrorFn(err); // Report the underlying error
                break :format_block; // Use placeholder
            };
            for (env_config.target_machines.items, 0..) |target, i| {
                if (i > 0) {
                    targets_buffer.appendSlice(", ") catch |err| {
                         std.log.err("Failed to format target machines for error message: {s}", .{@errorName(err)});
                         handleErrorFn(err);
                         break :format_block;
                    };
                }
                targets_buffer.writer().print("\"{s}\"", .{target}) catch |err| {
                    std.log.err("Failed to format target machines for error message: {s}", .{@errorName(err)});
                    handleErrorFn(err);
                    break :format_block;
                };
            }
            targets_buffer.appendSlice("]") catch |err| {
                 std.log.err("Failed to format target machines for error message: {s}", .{@errorName(err)});
                 handleErrorFn(err);
                 break :format_block;
            };

            // If formatting succeeded, duplicate the result
            formatted_targets = allocator.dupe(u8, targets_buffer.items) catch |err| {
                std.log.err("Failed to allocate memory for formatted target machines: {s}", .{@errorName(err)});
                handleErrorFn(err); // Report the underlying error
                break :format_block; // Use placeholder
            };
            formatted_targets_allocated = true; // Mark that we need to free this later
        }

        // If formatting failed (OOM before allocation), use a placeholder
        if (!formatted_targets_allocated) {
            formatted_targets = "<...>";
        }

        std.log.err("Current machine ('{s}') does not match target machines ('{s}') specified for environment '{s}'.", .{ hostname, formatted_targets, env_name });
        std.log.err("Use '--no-host' flag to bypass this check if needed.", .{});

        // Free the allocated string if it exists
        if (formatted_targets_allocated) {
            allocator.free(formatted_targets);
        }

        handleErrorFn(error.TargetMachineMismatch);
        return null;
    }

    std.log.debug("Hostname validation passed for env '{s}'.", .{env_name});
    return env_config;
}

// Helper function to look up a registry entry by name or ID, handling ambiguity
pub fn lookupRegistryEntry(registry: *const config_module.EnvironmentRegistry, identifier: []const u8, handleErrorFn: fn (anyerror) void) ?RegistryEntry {
    const is_potential_id_prefix = identifier.len >= 7 and identifier.len < 40;

    // Look up environment in registry (returns a copy)
    const entry_copy = registry.lookup(identifier) orelse {
        // Special handling for ambiguous ID prefixes
        if (is_potential_id_prefix) {
            var matching_envs = std.ArrayList([]const u8).init(registry.allocator);
            defer matching_envs.deinit();
            var match_count: usize = 0;

            for (registry.entries.items) |reg_entry| {
                if (reg_entry.id.len >= identifier.len and std.mem.eql(u8, reg_entry.id[0..identifier.len], identifier)) {
                    match_count += 1;
                    // Collect names only if we find more than one match
                    if (match_count > 1) {
                        matching_envs.append(reg_entry.env_name) catch |err| {
                            std.log.err("Failed to allocate memory for ambiguous env list: {s}", .{@errorName(err)});
                            handleErrorFn(error.OutOfMemory);
                            return null;
                        };
                    }
                    // If it's the first match, store its name in case it's the only one
                    else if (match_count == 1) {
                         matching_envs.append(reg_entry.env_name) catch |err| {
                            std.log.err("Failed to allocate memory for ambiguous env list: {s}", .{@errorName(err)});
                            handleErrorFn(error.OutOfMemory);
                            return null;
                        };
                    }
                }
            }

            if (match_count > 1) {
                std.io.getStdErr().writer().print("Error: Ambiguous ID prefix '{s}' matches multiple environments:\n", .{identifier}) catch {};
                // Print the collected names
                for (matching_envs.items) |env_name| {
                    std.io.getStdErr().writer().print("  - {s}\n", .{env_name}) catch {};
                }
                std.io.getStdErr().writer().print("Please use more characters to make the ID unique.\n", .{}) catch {};
                handleErrorFn(error.AmbiguousIdentifier);
                return null;
            }
            // If match_count is 1, the lookup call below will handle it.
            // If match_count is 0, the default error below is fine.
        }

        // Default error for no matches (exact or unique prefix)
        std.io.getStdErr().writer().print("Error: Environment with name or ID '{s}' not found in registry.\n", .{identifier}) catch {};
        std.io.getStdErr().writer().print("Use 'zenv list' to see all available environments with their IDs.\n", .{}) catch {};
        handleErrorFn(error.EnvironmentNotRegistered);
        return null;
    };

    return entry_copy;
}
