const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const errors = @import("errors.zig");
const flags_module = @import("flags.zig");
const process = std.process;
const fs = std.fs;

const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const RegistryEntry = config_module.RegistryEntry;
const CommandFlags = flags_module.CommandFlags;

// Normalizes a hostname for better matching
// Handles common variations like ".local" suffix on macOS
fn normalizeHostname(hostname: []const u8) []const u8 {
    // When the target pattern is explicitly "local", we want to keep the ".local" suffix
    // to allow for pattern matching "local" to match hosts with ".local" suffix
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

// Validate environment for a specific hostname
pub fn validateEnvironmentForMachine(env_config: *const EnvironmentConfig, hostname: []const u8) bool {
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
        
        // Special case for "local" which should match any hostname with ".local" suffix
        if (std.mem.eql(u8, target, "local") and std.mem.endsWith(u8, hostname, ".local")) {
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
    errors.debugLog(allocator, "Executing 'hostname' command", .{});
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

    // Check if the command was successful
    const success = blk: {
        if (term != .Exited) break :blk false;
        if (term.Exited != 0) break :blk false;
        break :blk true;
    };

    if (!success) {
        std.log.err("`hostname` command failed. Term: {?} Stderr: {s}", .{ term, stderr });
        return error.ProcessError;
    }

    const trimmed_hostname = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (trimmed_hostname.len == 0) {
        std.log.err("`hostname` command returned empty output.", .{});
        return error.MissingHostname;
    }
    errors.debugLog(allocator, "Got hostname from command: '{s}'", .{trimmed_hostname});
    // Return a duplicate of the trimmed hostname
    return allocator.dupe(u8, trimmed_hostname);
}

// Get hostname using environment variables or fallback to command
pub fn getSystemHostname(allocator: Allocator) ![]const u8 {
    errors.debugLog(allocator, "Attempting to get hostname from environment variable...", .{});

    // Try HOSTNAME first
    const hostname_env = std.process.getEnvVarOwned(allocator, "HOSTNAME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            // Try HOST if HOSTNAME is not found
            errors.debugLog(allocator, "HOSTNAME not set, trying HOST...", .{});
            const host_env = std.process.getEnvVarOwned(allocator, "HOST") catch |err2| {
                if (err2 == error.EnvironmentVariableNotFound) {
                    // Fallback to command if neither env var is set
                    errors.debugLog(allocator, "HOST not set, falling back to 'hostname' command...", .{});
                    return getHostnameFromCommand(allocator);
                } else {
                    // Use our new error helper for consistent logging
                    return errors.logAndReturn(err2, "Failed to get HOST environment variable: {s}", .{@errorName(err2)});
                }
            };
            // Check if HOST was empty
            if (host_env.len == 0) {
                allocator.free(host_env);
                errors.debugLog(allocator, "HOST was empty, falling back to 'hostname' command...", .{});
                return getHostnameFromCommand(allocator);
            }
            errors.debugLog(allocator, "Got hostname from HOST: '{s}'", .{host_env});
            return host_env; // Return hostname from HOST
        } else {
            // Use our new error helper for consistent logging
            return errors.logAndReturn(err, "Failed to get HOSTNAME environment variable: {s}", .{@errorName(err)});
        }
    };

    // Check if HOSTNAME was empty
    if (hostname_env.len == 0) {
        allocator.free(hostname_env);
        errors.debugLog(allocator, "HOSTNAME was empty, falling back to 'hostname' command...", .{});
        return getHostnameFromCommand(allocator);
    }

    errors.debugLog(allocator, "Got hostname from HOSTNAME: '{s}'", .{hostname_env});
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
    
    // Special case for "local" which should match any hostname with ".local" suffix
    if (std.mem.eql(u8, target_machine, "local") and std.mem.endsWith(u8, hostname, ".local")) {
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

/// Gets and validates environment configuration based on command-line arguments and current hostname.
/// This is a key utility function used by most commands to get the environment configuration.
///
/// Params:
///   - allocator: Memory allocator for temporary allocations
///   - config: ZenvConfig containing all available environments
///   - args: Command-line arguments including the environment name at args[2]
///   - handleErrorFn: Callback function to handle errors
///
/// Returns: Validated environment configuration or null if validation failed
pub fn getAndValidateEnvironment(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: []const []const u8,
    flags: CommandFlags,
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

    // Check if hostname validation is needed
    if (flags.skip_hostname_check) {
        errors.debugLog(allocator, "Hostname validation bypassed for environment '{s}'.", .{env_name});
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
    errors.debugLog(allocator, "Comparing current hostname '{s}' with target machines for env '{s}'", .{ hostname, env_name });

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

    errors.debugLog(allocator, "Hostname validation passed for env '{s}'.", .{env_name});
    return env_config;
}

/// Helper function to look up a registry entry by name or ID, handling ambiguity.
/// This function provides user-friendly error messages for common lookup issues.
///
/// Params:
///   - registry: The environment registry to search in
///   - identifier: The name or ID to look up (can be a partial ID if 7+ characters)
///   - handleErrorFn: Callback function to handle errors
///
/// Returns: The registry entry if found, null otherwise (after calling handleErrorFn)
pub fn lookupRegistryEntry(
    registry: *const config_module.EnvironmentRegistry,
    identifier: []const u8,
    handleErrorFn: fn (anyerror) void,
) ?RegistryEntry {
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

// pub fn checkModulesAvailability(
//     allocator: Allocator,
//     modules: []const []const u8,
// ) !struct { available: bool, missing: ?[]const []const u8 } {
//     // First check if module command exists
//     const check_cmd = "command -v module";
//     const check_argv = [_][]const u8{ "sh", "-c", check_cmd };
//     var check_child = std.process.Child.init(&check_argv, allocator);
//     check_child.stdout_behavior = .Ignore;
//     check_child.stderr_behavior = .Ignore;
//     try check_child.spawn();
//     const check_term = try check_child.wait();

//     // Check if module command exists
//     const module_exists = blk: {
//         if (check_term != .Exited) break :blk false;
//         if (check_term.Exited != 0) break :blk false;
//         break :blk true;
//     };

//     if (!module_exists) {
//         std.log.warn("'module' command not found, skipping module availability check.", .{});
//         return .{ .available = false, .missing = null };
//     }

//     // Check if any modules are already loaded
//     var modules_loaded = false;
//     {
//         const list_cmd = "module list 2>&1";
//         const list_argv = [_][]const u8{ "sh", "-c", list_cmd };
//         var list_child = std.process.Child.init(&list_argv, allocator);
//         list_child.stdout_behavior = .Pipe;
//         list_child.stderr_behavior = .Pipe;
//         try list_child.spawn();

//         var list_output: []const u8 = "";
//         var has_output = false;
//         defer if (has_output) allocator.free(list_output);

//         if (list_child.stdout) |stdout_pipe| {
//             list_output = try stdout_pipe.reader().readAllAlloc(allocator, 10 * 1024);
//             has_output = true;
//         }

//         const list_term = try list_child.wait();

//         // Check if any modules are loaded
//         if (list_term.Exited == 0 and has_output) {
//             // Module list output usually contains "No modules loaded" when empty
//             // or the list of modules if any are loaded
//             const no_modules_str = std.mem.indexOf(u8, list_output, "No modules loaded");
//             modules_loaded = no_modules_str == null;
//             errors.debugLog(allocator, "Current modules loaded: {}", .{modules_loaded});
//         }
//     }

//     // If modules list is empty, nothing to check
//     if (modules.len == 0) {
//         return .{ .available = true, .missing = null };
//     }

//     // Create list to track missing modules
//     var missing_modules = std.ArrayList([]const u8).init(allocator);
//     defer missing_modules.deinit();

//     // Track if we loaded the first module ourselves during this check
//     var we_loaded_first_module = false;

//     // If no modules are loaded, we need to try loading the first module
//     if (!modules_loaded and modules.len > 0) {
//         const first_module = modules[0];
//         std.log.info("No modules currently loaded. Attempting to load first module '{s}' to verify dependencies...", .{first_module});

//         // Try to load the first module
//         const load_cmd = try std.fmt.allocPrint(allocator, "module load {s} 2>&1", .{first_module});
//         defer allocator.free(load_cmd);

//         const load_argv = [_][]const u8{ "sh", "-c", load_cmd };
//         var load_child = std.process.Child.init(&load_argv, allocator);
//         load_child.stdout_behavior = .Pipe;
//         load_child.stderr_behavior = .Pipe;
//         try load_child.spawn();

//         var load_output: []const u8 = "";
//         var has_load_output = false;
//         defer if (has_load_output) allocator.free(load_output);

//         if (load_child.stdout) |stdout_pipe| {
//             load_output = try stdout_pipe.reader().readAllAlloc(allocator, 10 * 1024);
//             has_load_output = true;
//         }

//         const load_term = try load_child.wait();

//         // Check if the first module loaded successfully
//         // We consider success if exit code is 0 and there's no ERROR in the output
//         const error_in_output = has_load_output and std.mem.indexOf(u8, load_output, "ERROR") != null;
//         const first_module_loaded = load_term.Exited == 0 and !error_in_output;

//         errors.debugLog(allocator, "First module '{s}' load status: {}", .{ first_module, first_module_loaded });

//         if (!first_module_loaded) {
//             std.log.err("Failed to load first module '{s}'. This is required to check dependent modules.", .{first_module});
//             try missing_modules.append(first_module);
//             const missing = try missing_modules.toOwnedSlice();
//             return .{ .available = false, .missing = missing };
//         }

//         // First module loaded successfully, now we can check the other modules
//         we_loaded_first_module = true;
//     }

//     // Check each module's availability
//     for (modules) |module_name| {
//         // If we just loaded the first module for testing and this is that module,
//         // skip checking it again as we know it's available
//         if (we_loaded_first_module and std.mem.eql(u8, module_name, modules[0])) {
//             errors.debugLog(allocator, "Skipping availability check for first module '{s}' as we already loaded it", .{module_name});
//             continue;
//         }

//         const avail_cmd = try std.fmt.allocPrint(allocator, "module --terse avail {s} 2>&1", .{module_name});
//         defer allocator.free(avail_cmd);
//         errors.debugLog(allocator, "Checking module: {s}", .{avail_cmd});

//         const avail_argv = [_][]const u8{ "sh", "-c", avail_cmd };
//         var avail_child = std.process.Child.init(&avail_argv, allocator);
//         avail_child.stdout_behavior = .Pipe;
//         avail_child.stderr_behavior = .Pipe;
//         try avail_child.spawn();

//         var stdout_content: []const u8 = "";
//         var has_stdout = false;
//         defer if (has_stdout) allocator.free(stdout_content);

//         if (avail_child.stdout) |stdout_pipe| {
//             stdout_content = try stdout_pipe.reader().readAllAlloc(allocator, 10 * 1024);
//             has_stdout = true;
//         }

//         const term = try avail_child.wait();

//         errors.debugLog(allocator, "stdout for module '{s}': '{s}'", .{ module_name, stdout_content });
//         errors.debugLog(allocator, "Module '{s}' command exit code: {}", .{ module_name, term.Exited });

//         // Based on observed behavior: for --terse avail
//         // 1. If module exists: Returns output with module info
//         // 2. If module doesn't exist: Returns no output (exit code 0)
//         const module_available = stdout_content.len > 0;

//         if (!module_available) {
//             try missing_modules.append(module_name);
//         }
//     }

//     // Return results
//     if (missing_modules.items.len > 0) {
//         const missing = try missing_modules.toOwnedSlice();
//         return .{ .available = false, .missing = missing };
//     }

//     return .{ .available = true, .missing = null };
// }

// pub fn validateModules(
//     allocator: Allocator,
//     env_config: *const EnvironmentConfig,
//     force_deps: bool,
// ) !bool {
//     const modules = env_config.modules.items;
//     if (modules.len == 0) {
//         // No modules required, that's fine
//         return true;
//     }

//     std.log.info("Step 0: Checking availability of {} required modules...", .{modules.len});
//     const result = try checkModulesAvailability(allocator, modules);

//     if (!result.available) {
//         // If force_deps is true, we can continue even with missing modules
//         if (force_deps) {
//             std.log.warn("The following modules are not available but will be skipped due to --force-deps:", .{});
//             for (result.missing.?) |module| {
//                 std.log.warn("  - {s}", .{module});
//             }
//             return true;
//         }

//         // Otherwise, error out
//         std.log.err("The following modules are not available:", .{});
//         for (result.missing.?) |module| {
//             std.log.err("  - {s}", .{module});
//         }
//         std.log.err("Aborting setup because required modules are not available.", .{});
//         std.log.err("Please ensure the specified modules are installed on this system.", .{});
//         return error.ModuleLoadError;
//     }

//     return true;
// }

pub fn validateModules(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    force_deps: bool,
) !bool {
    // Skip all module validation and always return true
    _ = allocator;
    _ = env_config;
    _ = force_deps;

    std.log.info("Module validation has been disabled. Assuming all modules are available.", .{});
    return true;
}
