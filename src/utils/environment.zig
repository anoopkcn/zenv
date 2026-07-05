const std = @import("std");
const Allocator = std.mem.Allocator;
const config_module = @import("config.zig");
const errors = @import("errors.zig");
const flags_module = @import("flags.zig");
const process = std.process;
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const host = @import("host.zig");

const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const RegistryEntry = config_module.RegistryEntry;
const CommandFlags = flags_module.CommandFlags;

// Host / hostname matching primitives now live in host.zig — a leaf module that
// config.zig can also import without a circular dependency (environment.zig
// imports config.zig). Re-exported here so existing `environment.<fn>` /
// `env.<fn>` callers (e.g. in commands.zig) are unchanged.
pub const getSystemHostname = host.getSystemHostname;
pub const getHostnameFromCommand = host.getHostnameFromCommand;
pub const checkHostnameMatch = host.checkHostnameMatch;
pub const hostMatchesTargets = host.hostMatchesTargets;

// Validate environment for a specific hostname. An environment matches when ANY
// of its target_machines matches the hostname; an empty target list matches any
// machine. The per-target rules live in checkHostnameMatch (single source of truth).
pub fn validateEnvironmentForMachine(env_config: *const EnvironmentConfig, hostname: []const u8) bool {
    if (env_config.target_machines.items.len == 0) return true;
    for (env_config.target_machines.items) |target| {
        if (checkHostnameMatch(hostname, target)) return true;
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
///
/// Returns: Validated environment configuration or null if validation failed
// Get and validate environment config
pub fn getAndValidateEnvironment(
    allocator: Allocator,
    config: *const ZenvConfig,
    args: []const []const u8,
    flags: CommandFlags,
) !*const EnvironmentConfig {
    // First positional after the command — NOT args[2], which may be a flag
    // (e.g. `zenv setup --init myenv`).
    const env_name = flags_module.positional(args, 0) orelse {
        output.printError(allocator, "Missing environment name argument for command '{s}'", .{args[1]}) catch {};
        return error.ArgsError;
    };

    const env_config = config.getEnvironment(env_name) orelse {
        output.printError(allocator, "Environment '{s}' not found in configuration.", .{env_name}) catch {};
        return error.EnvironmentNotFound;
    };

    // Use validation function from config module (already validates required fields)
    if (config_module.ZenvConfig.validateEnvironment(env_config, env_name)) |err| {
        output.printError(allocator, "Invalid environment configuration for '{s}': {s}", .{ env_name, @errorName(err) }) catch {};
        return err;
    }

    // If modules_file is specified, read modules from the file
    if (env_config.modules_file) |modules_file_path| {
        errors.debugLog(allocator, "Modules file specified: {s}", .{modules_file_path});

        // Check if the file exists
        runtime.access(modules_file_path) catch |err| {
            if (err == error.FileNotFound) {
                output.printError(allocator, "Modules file '{s}' not found.", .{modules_file_path}) catch {};
                return err;
            } else {
                output.printError(allocator, "Error accessing modules file '{s}': {s}", .{ modules_file_path, @errorName(err) }) catch {};
                return err;
            }
        };

        // Read modules from the file
        var modules_from_file = readModulesFromFile(allocator, modules_file_path) catch |err| {
            output.printError(allocator, "Failed to read modules from file '{s}': {s}", .{ modules_file_path, @errorName(err) }) catch {};
            return err;
        };

        // If env_config is a const pointer, we need to create a mutable version
        var mutable_env_config = @constCast(env_config);

        // Clear existing modules (ignoring them as specified)
        if (mutable_env_config.modules.items.len > 0) {
            output.print(allocator, "Ignoring {d} modules defined in zenv.json in favor of modules_file", .{mutable_env_config.modules.items.len}) catch {};
            for (mutable_env_config.modules.items) |module| {
                mutable_env_config.modules.allocator.free(module);
            }
            mutable_env_config.modules.clearRetainingCapacity();
        }

        // Transfer ownership of modules from file to env_config
        mutable_env_config.modules.ensureTotalCapacity(modules_from_file.items.len) catch {};
        for (modules_from_file.items) |module| {
            // Create new duplicate to avoid any potential memory corruption
            const module_copy = mutable_env_config.modules.allocator.dupe(u8, module) catch continue;
            mutable_env_config.modules.append(module_copy) catch {};

            // Now we need to free the original since we made a copy
            allocator.free(module);
        }

        // Just deinit the ArrayList, but the items have been freed above
        modules_from_file.deinit();

        output.print(allocator, "Loaded {d} modules from file for environment '{s}'", .{ mutable_env_config.modules.items.len, env_name }) catch {};

        // Debug: Print actual loaded modules to verify content
        for (mutable_env_config.modules.items, 0..) |module, i| {
            errors.debugLog(allocator, "Module #{d} loaded: '{s}' (len={d})", .{ i + 1, module, module.len });
        }
    }

    // Check if hostname validation is needed
    if (flags.skip_hostname_check) {
        errors.debugLog(allocator, "Hostname validation bypassed for environment '{s}'.", .{env_name});
        return env_config;
    }

    // Get current hostname
    var hostname: []const u8 = undefined;
    hostname = getSystemHostname(allocator) catch |err| { // Call the local function
        output.printError(allocator, "Failed to get current hostname: {s}", .{@errorName(err)}) catch {};
        return err;
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
            var targets_buffer = std.array_list.Managed(u8).init(allocator);
            defer targets_buffer.deinit();

            // Attempt to format the string
            targets_buffer.appendSlice("[") catch |err| {
                output.printError(allocator, "Failed to format target machines for error message: {s}", .{@errorName(err)}) catch {};
                break :format_block; // Use placeholder
            };
            for (env_config.target_machines.items, 0..) |target, i| {
                if (i > 0) {
                    targets_buffer.appendSlice(", ") catch |err| {
                        output.printError(allocator, "Failed to format target machines for error message: {s}", .{@errorName(err)}) catch {};
                        break :format_block;
                    };
                }
                targets_buffer.print("\"{s}\"", .{target}) catch |err| {
                    output.printError(allocator, "Failed to format target machines for error message: {s}", .{@errorName(err)}) catch {};
                    break :format_block;
                };
            }
            targets_buffer.appendSlice("]") catch |err| {
                output.printError(allocator, "Failed to format target machines for error message: {s}", .{@errorName(err)}) catch {};
                break :format_block;
            };

            // If formatting succeeded, duplicate the result
            formatted_targets = allocator.dupe(u8, targets_buffer.items) catch |err| {
                output.printError(allocator, "Failed to allocate memory for formatted target machines: {s}", .{@errorName(err)}) catch {};
                break :format_block; // Use placeholder
            };
            formatted_targets_allocated = true; // Mark that we need to free this later
        }

        // If formatting failed (OOM before allocation), use a placeholder
        if (!formatted_targets_allocated) {
            formatted_targets = "<...>";
        }

        output.printError(allocator, "Current machine ('{s}') does not match target machines ('{s}') specified for environment '{s}'.", .{ hostname, formatted_targets, env_name }) catch {};
        output.printError(allocator, "Use '--no-host' flag to bypass this check if needed.", .{}) catch {};

        // Free the allocated string if it exists
        if (formatted_targets_allocated) {
            allocator.free(formatted_targets);
        }

        return error.TargetMachineMismatch;
    }

    errors.debugLog(allocator, "Hostname validation passed for env '{s}'.", .{env_name});
    return env_config;
}

// Function to read modules from a file
pub fn readModulesFromFile(
    allocator: Allocator,
    file_path: []const u8,
) !std.array_list.Managed([]const u8) {
    var modules_list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (modules_list.items) |item| {
            allocator.free(item);
        }
        modules_list.deinit();
    }

    // Open and read the file
    const file_content = try runtime.readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(file_content);

    errors.debugLog(allocator, "Reading modules from file: {s}", .{file_path});

    // Debug the file content with hex representation for all bytes (debug only)
    if (errors.isDebugEnabled(allocator) and file_content.len > 0) {
        const debug_len = @min(file_content.len, 100);
        var hex_buf = std.array_list.Managed(u8).init(allocator);
        defer hex_buf.deinit();

        for (file_content[0..debug_len]) |byte| {
            hex_buf.print("{X:0>2} ", .{byte}) catch {};
        }
        errors.debugLog(allocator, "File content (up to 100 bytes): {s}", .{hex_buf.items});
    }

    // Skip BOM if present
    var content_to_process = file_content;
    if (file_content.len >= 3 and file_content[0] == 0xEF and file_content[1] == 0xBB and file_content[2] == 0xBF) {
        content_to_process = file_content[3..];
        errors.debugLog(allocator, "UTF-8 BOM detected and skipped", .{});
    }

    // Create a hashmap to ensure uniqueness and avoid duplicates
    var modules_set = std.StringHashMap(void).init(allocator);
    defer {
        var keys_iter = modules_set.keyIterator();
        while (keys_iter.next()) |key| {
            allocator.free(key.*);
        }
        modules_set.deinit();
    }

    // Process the file line by line using straightforward approach
    var line_start: usize = 0;
    var line_number: usize = 0;

    while (line_start < content_to_process.len) {
        line_number += 1;

        // Find end of line
        var line_end: usize = line_start;
        while (line_end < content_to_process.len and
            content_to_process[line_end] != '\n' and
            content_to_process[line_end] != '\r')
        {
            line_end += 1;
        }

        // Extract the line
        const line = content_to_process[line_start..line_end];

        // Skip empty lines and comments
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') {
            // Move to next line
            line_start = skipNewline(content_to_process, line_end);
            continue;
        }

        // Process this line as a single module name without tokenizing
        if (trimmed.len > 0) {
            // Debug output for every line
            errors.debugLog(allocator, "Line {d}: '{s}' (len={d})", .{ line_number, trimmed, trimmed.len });

            // Create a fresh copy of the module name
            const module_name = try allocator.dupe(u8, trimmed);

            // Check if module contains special characters
            var is_valid = true;
            for (module_name) |char| {
                if (char < 32 or char > 126) {
                    is_valid = false;
                    break;
                }
            }

            if (!is_valid) {
                // Only log the issue but still use the name
                output.print(allocator, "Warning: Module name contains non-printable characters: '{s}'", .{module_name}) catch {};
            }

            // Check if we've already seen this module
            if (!modules_set.contains(module_name)) {
                const key_copy = try allocator.dupe(u8, module_name);
                try modules_set.put(key_copy, {});

                // Add module to the list
                try modules_list.append(module_name);
                errors.debugLog(allocator, "  - Found module: '{s}'", .{module_name});
            } else {
                // Free the duplicate since we already have this module
                allocator.free(module_name);
            }
        }

        // Move to next line
        line_start = skipNewline(content_to_process, line_end);
    }

    if (modules_list.items.len == 0) {
        output.print(allocator, "Warning: No valid modules found in file. Ensure it contains valid module names.", .{}) catch {};
    } else {
        output.print(allocator, "Found {d} unique modules in file.", .{modules_list.items.len}) catch {};

        // Additional debug: print the module list again to confirm what we're returning
        for (modules_list.items, 0..) |module, i| {
            errors.debugLog(allocator, "Module #{d}: '{s}' (len={d})", .{ i + 1, module, module.len });
        }
    }
    return modules_list;
}

// Helper function to skip newline characters (handles both LF and CRLF)
fn skipNewline(content: []const u8, pos: usize) usize {
    if (pos >= content.len) return content.len;

    if (content[pos] == '\r') {
        if (pos + 1 < content.len and content[pos + 1] == '\n') {
            return pos + 2; // Skip CRLF
        }
        return pos + 1; // Skip CR
    } else if (content[pos] == '\n') {
        return pos + 1; // Skip LF
    }

    return pos; // No newline to skip
}

pub fn validateModules(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
) !bool {
    // Module availability is no longer probed at setup time (Lmod is slow and
    // unreliable to query); modules are loaded lazily at activation instead. This
    // always reports success and only logs.
    const modules = env_config.modules.items;
    if (modules.len == 0) {
        output.print(allocator, "No modules to validate.", .{}) catch {};
        return true;
    }

    errors.debugLog(allocator, "Module validation has been disabled. Assuming all {d} modules are available.", .{modules.len});

    // Log the modules being loaded from file for debugging purposes
    if (env_config.modules_file != null) {
        errors.debugLog(allocator, "Modules loaded from file: {s}", .{env_config.modules_file.?});
        for (modules) |module| {
            errors.debugLog(allocator, "  - {s}", .{module});
        }
    }

    return true;
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");

test "getHostnameFromCommand trims output and rejects empty/failed runs" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const prev = test_support.useFakeExec();
    defer runtime.exec_backend = prev;

    // happy path: surrounding whitespace is trimmed off the captured stdout
    test_support.fake_run_stdout = "  jrlogin01.jureca \n";
    test_support.fake_run_stderr = "";
    test_support.fake_run_exit = 0;
    const h = try getHostnameFromCommand(a);
    defer a.free(h);
    try testing.expectEqualStrings("jrlogin01.jureca", h);

    // whitespace-only output -> MissingHostname
    test_support.fake_run_stdout = "   \n";
    try testing.expectError(error.MissingHostname, getHostnameFromCommand(a));

    // non-zero exit -> ProcessError
    test_support.fake_run_stdout = "ignored";
    test_support.fake_run_exit = 1;
    try testing.expectError(error.ProcessError, getHostnameFromCommand(a));
}
