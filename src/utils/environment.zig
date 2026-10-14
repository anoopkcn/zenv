const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config_module = @import("config.zig");
const flags_module = @import("flags.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const host = @import("host.zig");

const Ctx = runtime.Ctx;
const ZenvConfig = config_module.ZenvConfig;
const EnvironmentConfig = config_module.EnvironmentConfig;
const CommandFlags = flags_module.CommandFlags;

// Validate environment for a specific hostname. An environment matches when ANY
// of its target_machines matches the hostname; an empty target list matches any
// machine. The per-target rules live in checkHostnameMatch (single source of truth).
pub fn validateEnvironmentForMachine(env_config: *const EnvironmentConfig, hostname: []const u8) bool {
    if (env_config.target_machines.items.len == 0) return true;
    for (env_config.target_machines.items) |target| {
        if (host.checkHostnameMatch(hostname, target)) return true;
    }
    return false;
}

/// The config of the environment named by the first positional argument, with
/// its `modules_file` (if any) read into `modules`, after checking the current
/// host against its target_machines unless `--no-host` was given. Prints why
/// and returns an error when any step fails.
pub fn getAndValidateEnvironment(
    ctx: Ctx,
    config: *ZenvConfig,
    args: []const []const u8,
    flags: CommandFlags,
) !*const EnvironmentConfig {
    const io = ctx.io;
    // First positional after the command — NOT args[2], which may be a flag
    // (e.g. `zenv setup --init myenv`).
    const env_name = flags_module.positional(args, 0) orelse {
        output.printError(io, "Missing environment name argument for command '{s}'", .{args[1]});
        return error.ArgsError;
    };

    const env_config = config.environments.getPtr(env_name) orelse {
        output.printError(io, "Environment '{s}' not found in configuration.", .{env_name});
        return error.EnvironmentNotFound;
    };

    // If modules_file is specified, read modules from the file
    if (env_config.modules_file) |modules_file_path| {
        output.debug(io, "Modules file specified: {s}", .{modules_file_path});

        // Read modules with the config's own allocator so the list can be moved
        // into env_config as-is, without copying each name.
        const modules_from_file = readModulesFromFile(env_config.allocator, io, modules_file_path) catch |err| {
            if (err == error.FileNotFound) {
                output.printError(io, "Modules file '{s}' not found.", .{modules_file_path});
            } else {
                output.printError(io, "Failed to read modules from file '{s}': {t}", .{ modules_file_path, err });
            }
            return err;
        };

        // Replace the existing modules (ignoring them as specified)
        if (env_config.modules.items.len > 0) {
            output.print(io, "Ignoring {d} modules defined in zenv.json in favor of modules_file", .{env_config.modules.items.len});
        }
        for (env_config.modules.items) |module| env_config.allocator.free(module);
        env_config.modules.deinit(env_config.allocator);
        env_config.modules = modules_from_file;

        output.print(io, "Loaded {d} modules from file for environment '{s}'", .{ env_config.modules.items.len, env_name });
    }

    // Check if hostname validation is needed
    if (flags.skip_hostname_check) {
        output.debug(io, "Hostname validation bypassed for environment '{s}'.", .{env_name});
        return env_config;
    }

    try checkHost(ctx, env_config, env_name);
    output.debug(io, "Hostname validation passed for env '{s}'.", .{env_name});
    return env_config;
}

/// Checks the current host against the target_machines of `env_config`. On a
/// mismatch, says so (naming the targets) and returns TargetMachineMismatch.
pub fn checkHost(ctx: Ctx, env_config: *const EnvironmentConfig, env_name: []const u8) !void {
    const io = ctx.io;
    const hostname = host.getSystemHostname(ctx.arena, io, ctx.env) catch |err| {
        output.printError(io, "Failed to get current hostname: {t}", .{err});
        return err;
    };

    output.debug(io, "Comparing current hostname '{s}' with target machines for env '{s}'", .{ hostname, env_name });
    if (validateEnvironmentForMachine(env_config, hostname)) return;

    var targets: std.Io.Writer.Allocating = .init(ctx.arena);
    for (env_config.target_machines.items, 0..) |target, i| {
        targets.writer.print("{s}\"{s}\"", .{ if (i > 0) ", " else "", target }) catch {};
    }
    output.printError(io, "Current machine ('{s}') does not match target machines ([{s}]) specified for environment '{s}'.", .{ hostname, targets.written(), env_name });
    output.printError(io, "Use '--no-host' flag to bypass this check if needed.", .{});
    return error.TargetMachineMismatch;
}

/// Module names from `file_path`, one per line, in first-seen order without
/// duplicates. Blank lines and `#` comments are skipped; CRLF line ends and a
/// UTF-8 BOM are accepted. Names are owned by `allocator`.
pub fn readModulesFromFile(allocator: Allocator, io: Io, file_path: []const u8) !std.ArrayList([]const u8) {
    var modules_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (modules_list.items) |item| allocator.free(item);
        modules_list.deinit(allocator);
    }

    const file_content = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(1024 * 1024));
    defer allocator.free(file_content);
    const content = std.mem.cutPrefix(u8, file_content, "\xEF\xBB\xBF") orelse file_content; // UTF-8 BOM

    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    next: while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (name.len == 0 or name[0] == '#') continue;
        for (modules_list.items) |seen| if (std.mem.eql(u8, seen, name)) continue :next;
        try modules_list.ensureUnusedCapacity(allocator, 1);
        modules_list.appendAssumeCapacity(try allocator.dupe(u8, name));
        output.debug(io, "  - Found module: '{s}'", .{name});
    }

    if (modules_list.items.len == 0) {
        output.print(io, "Warning: No valid modules found in file. Ensure it contains valid module names.", .{});
    } else {
        output.print(io, "Found {d} unique modules in file.", .{modules_list.items.len});
    }
    return modules_list;
}

// ============================ Tests ============================
const testing = std.testing;

test "readModulesFromFile: BOM, CRLF, comments and duplicates" {
    const a = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const path = ".zig-cache/tmp/zenv-modules-file.txt";
    try cwd.createDirPath(io, ".zig-cache/tmp");
    defer cwd.deleteFile(io, path) catch {};
    try cwd.writeFile(io, .{ .sub_path = path, .data = "\xEF\xBB\xBFStages/2026\r\n# a comment\r\n\r\n  GCC  \nPython/3.13.5\nGCC\n" });

    var list = try readModulesFromFile(a, io, path);
    defer {
        for (list.items) |m| a.free(m);
        list.deinit(a);
    }
    const want = [_][]const u8{ "Stages/2026", "GCC", "Python/3.13.5" };
    try testing.expectEqual(want.len, list.items.len);
    for (want, list.items) |w, got| try testing.expectEqualStrings(w, got);
}
