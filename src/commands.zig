const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const config_module = @import("config.zig");
const ZenvConfig = config_module.ZenvConfig;
const ActiveConfig = config_module.ActiveConfig;
const env_utils = @import("env_utils.zig");
const process_utils = @import("process_utils.zig");

const EnvInfo = struct {
    name: []const u8,
    target: ?[]const u8,
    matches_current: bool,
};

fn doActivate(allocator: Allocator, config: *const ActiveConfig) !void {
    const parent_dir_abs = try fs.path.resolve(allocator, &[_][]const u8{ config.config_base_dir, config.parent_envs_dir });
    defer allocator.free(parent_dir_abs);

    const venv_path_abs = try fs.path.join(allocator, &[_][]const u8{ parent_dir_abs, config.env_name });
    defer allocator.free(venv_path_abs);

    const activate_sh_path = try fs.path.join(allocator, &[_][]const u8{ venv_path_abs, "activate.sh" });
    defer allocator.free(activate_sh_path);

    const activate_sh_exists = (fs.cwd().access(activate_sh_path, .{}) catch null) != null;

    const err_writer = std.io.getStdErr().writer();

    if (activate_sh_exists) {
        const out_writer = std.io.getStdOut().writer();
        try out_writer.print("source {s}\n", .{activate_sh_path});
    } else {
        try err_writer.print("No activation script found for environment '{s}'\n", .{config.env_name});
        try err_writer.print("Run 'zenv setup {s}' first to create the virtual environment\n", .{config.env_name});
        return ZenvError.ConfigInvalid; // Or a more specific ActivationScriptNotFound error?
    }
}

fn doSetup(allocator: Allocator, config: *const ActiveConfig) !void {
    _ = allocator; // Use params to avoid unused errors
    _ = config;
    std.log.warn("doSetup temporarily disabled for debugging", .{});
    return;
}

fn doListConfiguredEnvs(allocator: Allocator, config: *const ZenvConfig) !void {
    const current_cluster = env_utils.getClusterName(allocator) catch |err| {
        std.log.warn("Could not get cluster name for list comparison: {s}. Assuming no matches.", .{@errorName(err)});
        if (err == ZenvError.MissingHostname) return ZenvError.MissingHostname;
        return err;
    };
    defer allocator.free(current_cluster);

    var envs = std.ArrayList(EnvInfo).init(allocator);
    defer {
        for (envs.items) |item| {
            if (item.target) |target| allocator.free(target);
        }
        envs.deinit();
    }

    var env_iter = config.environments.iterator();
    while (env_iter.next()) |entry| {
        const env_name = entry.key_ptr.*;
        const env_cfg = entry.value_ptr.*;
        var target_dupe: ?[]const u8 = null;
        var matches_current = false;
        if (env_cfg.target) |target| {
            target_dupe = try allocator.dupe(u8, target);
            matches_current = mem.eql(u8, target, current_cluster);
        }
        try envs.append(.{
            .name = env_name,
            .target = target_dupe,
            .matches_current = matches_current,
        });
    }

    std.sort.heap(EnvInfo, envs.items, {}, struct {
        pub fn lessThan(_: void, a: EnvInfo, b: EnvInfo) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\nAvailable environments in {s}:\n\n", .{config.config_base_dir});
    var matching_count: usize = 0;
    for (envs.items) |item| {
        if (item.matches_current) matching_count += 1;
    }

    if (envs.items.len == 0) {
        try stdout.print("No environments found in configuration.\n", .{});
    } else {
        try stdout.print("NAME\tTARGET\tMATCHES CURRENT\n", .{});
        try stdout.print("----\t------\t--------------\n", .{});
        for (envs.items) |item| {
            try stdout.print("{s}\t{s}\t{s}\n", .{
                item.name,
                item.target orelse "(any)",
                if (item.matches_current) "YES" else "no",
            });
        }
    }

    try stdout.print("\nTotal: {d} environment(s) defined in config.\n", .{envs.items.len});
    if (matching_count > 0) {
        try stdout.print("Found {d} environment(s) matching your current cluster '{s}'\n", .{matching_count, current_cluster});
    } else {
        try stdout.print("No environments explicitly target your current cluster '{s}'\n", .{current_cluster});
    }
}

fn doListExistingEnvs(allocator: Allocator, config: *const ZenvConfig) !void {
    const parent_dir_abs = blk: {
        const parent_envs_dir_rel = config.common.parent_envs_dir;
        const config_base_dir = config.config_base_dir;
        const parent_dir_maybe_rel = fs.path.join(allocator, &[_][]const u8{ config_base_dir, parent_envs_dir_rel }) catch |err| {
             std.log.err("Failed to join path for parent env dir: {s}", .{@errorName(err)});
             return ZenvError.PathResolutionFailed;
        };
        defer allocator.free(parent_dir_maybe_rel);
        break :blk fs.cwd().realpathAlloc(allocator, parent_dir_maybe_rel) catch |err| {
            if (err == error.FileNotFound or err == error.PathNotFound) {
                 break :blk null;
            }
             std.log.err("Failed to resolve real path for parent env dir '{s}': {s}", .{ parent_dir_maybe_rel, @errorName(err)});
             return ZenvError.PathResolutionFailed;
        };
    } orelse {
        std.io.getStdOut().writer().print("Environment parent directory not found. No existing environments.\n", .{}) catch {};
        return; // Not an application error
    };
    defer allocator.free(parent_dir_abs);

    std.log.debug("Looking for existing environments in absolute path: {s}", .{parent_dir_abs});

    var dir = fs.openDirAbsolute(parent_dir_abs, .{ .iterate = true }) catch |err| {
        std.log.err("Error opening directory '{s}': {s}", .{parent_dir_abs, @errorName(err)});
        if (err == error.FileNotFound or err == error.PathNotFound) {
             std.io.getStdOut().writer().print(
                \\Environment directory '{s}' does not exist or is not accessible.
                \\No existing environments found.
            , .{parent_dir_abs}) catch {};
            return;
        }
        return ZenvError.IoError;
    };
    defer dir.close();

    var env_dirs = std.ArrayList([]const u8).init(allocator);
    defer {
        for (env_dirs.items) |item| allocator.free(item);
        env_dirs.deinit();
    }

    var iter = dir.iterate();
    while (iter.next() catch |err| {
        std.log.warn("Error reading directory entry in '{s}': {s}. Aborting list.", .{ parent_dir_abs, @errorName(err) });
        return err; // Return the error instead of trying to continue
    }) |entry| {
        if (entry.kind == .directory) {
            const env_path = fs.path.join(allocator, &[_][]const u8{parent_dir_abs, entry.name}) catch |e| {
                 std.log.warn("Failed to join path for dir entry '{s}': {s}. Skipping.", .{ entry.name, @errorName(e) });
                 continue;
            };
            defer allocator.free(env_path);
            const activate_path = fs.path.join(allocator, &[_][]const u8{env_path, "activate.sh"}) catch |e| {
                 std.log.warn("Failed to join path for activate script in '{s}': {s}. Skipping.", .{ entry.name, @errorName(e) });
                 continue;
            };
            defer allocator.free(activate_path);

            if (fs.cwd().access(activate_path, .{}) catch null) |_| {
                try env_dirs.append(try allocator.dupe(u8, entry.name));
            } else {
                 std.log.debug("Directory '{s}' found, but missing '{s}'. Skipping.", .{entry.name, "activate.sh"});
            }
        }
    }

    std.sort.heap([]const u8, env_dirs.items, {}, struct {
        pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\nExisting environments found in {s}:\n\n", .{parent_dir_abs});

    if (env_dirs.items.len == 0) {
        try stdout.print("No existing environments found. Run 'zenv setup [env_name]' first.\n", .{});
    } else {
        for (env_dirs.items) |name| {
            try stdout.print("- {s}\n", .{name});
        }
        try stdout.print("\nTotal: {d} existing environment(s)\n", .{env_dirs.items.len});
    }
    try stdout.print("\nUse 'zenv list --all' to see all environments defined in the configuration.\n", .{});
}

const CommandError = ZenvError || error{ ArgsError };

pub fn handleSetupCommand(allocator: Allocator, config: *const ZenvConfig, args: []const []const u8, handleError: *const fn(anyerror) void) void {
    const resolved_env_name = env_utils.resolveEnvironmentName(allocator, config, args, "setup") catch |err| {
        handleError(err);
        return; // Exit function on error
    };
    var active_config = config_module.createActiveConfig(allocator, config, resolved_env_name) catch |err| {
        handleError(err);
        return;
    };
    defer active_config.deinit(); // Deinit active config when setup scope ends

    doSetup(allocator, &active_config) catch |err| {
        handleError(err);
        return;
    };
    std.log.info("Setup completed successfully for environment '{s}'.", .{active_config.env_name});
}

pub fn handleActivateCommand(allocator: Allocator, config: *const ZenvConfig, args: []const []const u8, handleError: *const fn(anyerror) void) void {
    const resolved_env_name = env_utils.resolveEnvironmentName(allocator, config, args, "activate") catch |err| {
        handleError(err);
        return;
    };
    var active_config = config_module.createActiveConfig(allocator, config, resolved_env_name) catch |err| {
        handleError(err);
        return;
    };
    defer active_config.deinit(); // Deinit active config when activate scope ends

    doActivate(allocator, &active_config) catch |err| {
        handleError(err);
        return;
    };
}

pub fn handleListCommand(allocator: Allocator, config: *const ZenvConfig, args: []const []const u8, handleError: *const fn(anyerror) void) void {
    var show_all = false;
    for (args[1..]) |arg| {
        if (mem.eql(u8, arg, "--all")) {
            show_all = true;
            break;
        }
    }

    if (show_all) {
        doListConfiguredEnvs(allocator, config) catch |err| {
            handleError(err);
            return;
        };
    } else {
        doListExistingEnvs(allocator, config) catch |err| {
            handleError(err);
            return;
        };
    }
}
