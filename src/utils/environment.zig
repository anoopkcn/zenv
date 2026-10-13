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

        // Read modules with the config's own allocator so the list can be moved
        // into env_config as-is, without copying each name.
        const modules_from_file = readModulesFromFile(env_config.allocator, modules_file_path) catch |err| {
            output.printError(allocator, "Failed to read modules from file '{s}': {s}", .{ modules_file_path, @errorName(err) }) catch {};
            return err;
        };

        // If env_config is a const pointer, we need to create a mutable version
        const mutable_env_config = @constCast(env_config);

        // Replace the existing modules (ignoring them as specified)
        if (mutable_env_config.modules.items.len > 0) {
            output.print(allocator, "Ignoring {d} modules defined in zenv.json in favor of modules_file", .{mutable_env_config.modules.items.len}) catch {};
        }
        for (mutable_env_config.modules.items) |module| env_config.allocator.free(module);
        mutable_env_config.modules.deinit(env_config.allocator);
        mutable_env_config.modules = modules_from_file;

        output.print(allocator, "Loaded {d} modules from file for environment '{s}'", .{ mutable_env_config.modules.items.len, env_name }) catch {};
    }

    // Check if hostname validation is needed
    if (flags.skip_hostname_check) {
        errors.debugLog(allocator, "Hostname validation bypassed for environment '{s}'.", .{env_name});
        return env_config;
    }

    const hostname = getSystemHostname(allocator) catch |err| {
        output.printError(allocator, "Failed to get current hostname: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(hostname);

    errors.debugLog(allocator, "Comparing current hostname '{s}' with target machines for env '{s}'", .{ hostname, env_name });
    if (!validateEnvironmentForMachine(env_config, hostname)) {
        var targets: std.Io.Writer.Allocating = .init(allocator);
        defer targets.deinit();
        for (env_config.target_machines.items, 0..) |target, i| {
            targets.writer.print("{s}\"{s}\"", .{ if (i > 0) ", " else "", target }) catch {};
        }
        output.printError(allocator, "Current machine ('{s}') does not match target machines ([{s}]) specified for environment '{s}'.", .{ hostname, targets.written(), env_name }) catch {};
        output.printError(allocator, "Use '--no-host' flag to bypass this check if needed.", .{}) catch {};
        return error.TargetMachineMismatch;
    }

    errors.debugLog(allocator, "Hostname validation passed for env '{s}'.", .{env_name});
    return env_config;
}

/// Module names from `file_path`, one per line, in first-seen order without
/// duplicates. Blank lines and `#` comments are skipped; CRLF line ends and a
/// UTF-8 BOM are accepted. Names are owned by `allocator`.
pub fn readModulesFromFile(allocator: Allocator, file_path: []const u8) !std.ArrayList([]const u8) {
    var modules_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (modules_list.items) |item| allocator.free(item);
        modules_list.deinit(allocator);
    }

    const file_content = try runtime.readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(file_content);
    const bom = "\xEF\xBB\xBF";
    const content = if (std.mem.startsWith(u8, file_content, bom)) file_content[bom.len..] else file_content;

    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    next: while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (name.len == 0 or name[0] == '#') continue;
        for (modules_list.items) |seen| if (std.mem.eql(u8, seen, name)) continue :next;
        try modules_list.ensureUnusedCapacity(allocator, 1);
        modules_list.appendAssumeCapacity(try allocator.dupe(u8, name));
        errors.debugLog(allocator, "  - Found module: '{s}'", .{name});
    }

    if (modules_list.items.len == 0) {
        output.print(allocator, "Warning: No valid modules found in file. Ensure it contains valid module names.", .{}) catch {};
    } else {
        output.print(allocator, "Found {d} unique modules in file.", .{modules_list.items.len}) catch {};
    }
    return modules_list;
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");

test "readModulesFromFile: BOM, CRLF, comments and duplicates" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const path = ".zig-cache/tmp/zenv-modules-file.txt";
    try runtime.makePath(".zig-cache/tmp");
    defer runtime.deleteFile(path) catch {};
    try runtime.writeFile(path, "\xEF\xBB\xBFStages/2026\r\n# a comment\r\n\r\n  GCC  \nPython/3.13.5\nGCC\n");

    var list = try readModulesFromFile(a, path);
    defer {
        for (list.items) |m| a.free(m);
        list.deinit(a);
    }
    const want = [_][]const u8{ "Stages/2026", "GCC", "Python/3.13.5" };
    try testing.expectEqual(want.len, list.items.len);
    for (want, list.items) |w, got| try testing.expectEqualStrings(w, got);
}

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
