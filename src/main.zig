const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const testing = std.testing;
const Allocator = mem.Allocator;
const json = std.json;

const ActiveConfig = struct {
    allocator: Allocator,
    env_name: []const u8,
    target_cluster: []const u8,
    parent_envs_dir: []const u8,
    requirements_file: []const u8,
    python_executable: []const u8,
    modules_to_load: std.ArrayList([]const u8),
    custom_setup_commands: std.ArrayList([]const u8),
    custom_activate_vars: std.StringHashMap([]const u8),
    config_base_dir: []const u8, // Directory where zenv.json lives

    fn deinitStringList(self: *ActiveConfig, list: *std.ArrayList([]const u8)) void {
        for (list.items) |item| {
            self.allocator.free(item);
            list.deinit();
    }
        list.deinit();
    }

    fn deinitStringMap(self: *ActiveConfig, map: *std.StringHashMap([]const u8)) void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    fn deinit(self: *ActiveConfig) void {
        self.allocator.free(self.env_name);
        self.allocator.free(self.target_cluster);
        self.allocator.free(self.parent_envs_dir);
        self.allocator.free(self.requirements_file);
        self.allocator.free(self.python_executable);
        self.deinitStringList(&self.modules_to_load);
        self.deinitStringList(&self.custom_setup_commands);
        self.deinitStringMap(&self.custom_activate_vars);
        self.allocator.free(self.config_base_dir);
    }
};

const ZenvError = error{
    MissingHostname,
    HostnameParseError,
    ConfigFileNotFound,
    ConfigFileReadError,
    JsonParseError,
    ConfigInvalid,
    ClusterNotFound,
    EnvironmentNotFound,
    IoError,
    ProcessError,
    MissingPythonExecutable,
    PathResolutionFailed,
    OutOfMemory,
};


const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

fn execAllowFail(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8, _: anytype) !ExecResult {
    var result = ExecResult{
        .term = undefined,
        .stdout = "",
        .stderr = "",
    };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    if (cwd) |dir| {
        child.cwd = dir;
    }

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stderr);

    result.term = try child.wait();
    result.stdout = stdout;
    result.stderr = stderr;

    return result;
}

fn runCommand(allocator: Allocator, args: []const []const u8, env_map: ?*const std.process.EnvMap) !void {
    if (args.len == 0) {
        std.debug.print("Warning: runCommand called with empty arguments.\n", .{});
        return;
    }
    std.debug.print("Running command: {s}\n", .{args});
    var child = std.process.Child.init(args, allocator);

    // Don't manipulate environment directly, let the child inherit parent's environment
    // This avoids alignment issues with the environment map
    if (env_map) |map| {
        // Only set specific environment variables when explicitly requested
        child.env_map = map;
    }

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("Failed to spawn/wait for '{s}': {s}\n", .{ args[0], @errorName(err) });
        return ZenvError.ProcessError;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Command '{s}' exited with code {d}\n", .{ args[0], code });
                return ZenvError.ProcessError;
            }
            std.debug.print("Command '{s}' finished successfully.\n", .{args[0]});
        },
        .Signal => |sig| {
            std.debug.print("Command '{s}' terminated by signal {d}\n", .{ args[0], sig });
            return ZenvError.ProcessError;
        },
        .Stopped => |sig| {
            std.debug.print("Command '{s}' stopped by signal {d}\n", .{ args[0], sig });
            return ZenvError.ProcessError;
        },
        else => {
            std.debug.print("Command '{s}' terminated unexpectedly: {?}\n", .{ args[0], term });
            return ZenvError.ProcessError;
        },
    }
}

fn getClusterName(allocator: Allocator) ![]const u8 {
    const hostname = std.process.getEnvVarOwned(allocator, "HOSTNAME") catch |err| {
        std.debug.print("Error reading HOSTNAME: {s}\n", .{@errorName(err)});
        if (err == error.EnvironmentVariableNotFound) return ZenvError.MissingHostname;
        return err; // Propagate other errors like OOM
    };

    // For hostname formats like jrlogin04.jureca, extract 'jureca'
    // This handles both jrlogin04.jureca and login01.jureca.fz-juelich.de
    if (mem.indexOfScalar(u8, hostname, '.')) |first_dot| {
        // Check if there's a second dot
        if (mem.indexOfScalarPos(u8, hostname, first_dot + 1, '.')) |second_dot| {
            // Extract the part between first and second dot (e.g., 'jureca' from login01.jureca.fz-juelich.de)
            return allocator.dupe(u8, hostname[first_dot + 1..second_dot]);
        } else {
            // Only one dot, extract the part after the dot (e.g., 'jureca' from jrlogin04.jureca)
            return allocator.dupe(u8, hostname[first_dot + 1..]);
        }
    } else {
        std.debug.print("Warning: HOSTNAME '{s}' does not contain '.', using full name as cluster name.\n", .{hostname});
        return hostname;
    }
}

fn loadAndMergeConfig(allocator: Allocator, config_path: []const u8, env_name: []const u8) !ActiveConfig {
    const config_base_dir = fs.path.dirname(config_path) orelse ".";

    const config_content = fs.cwd().readFileAlloc(allocator, config_path, 1 * 1024 * 1024) catch |err| {
        std.debug.print("Failed to read config file '{s}': {s}\n", .{ config_path, @errorName(err) });
        if (err == error.FileNotFound) return ZenvError.ConfigFileNotFound;
        return ZenvError.ConfigFileReadError;
    };
    defer allocator.free(config_content);

    var tree = json.parseFromSlice(json.Value, allocator, config_content, .{}) catch |err| {
        std.debug.print("Failed to parse JSON in '{s}': {s}\n", .{ config_path, @errorName(err) });
        return ZenvError.JsonParseError;
    };
    defer tree.deinit();

    const root_value = tree.value;
    if (root_value != .object) return ZenvError.ConfigInvalid;
    const root_object = root_value.object;

    const common_value = root_object.get("common") orelse return ZenvError.ConfigInvalid;
    if (common_value != .object) return ZenvError.ConfigInvalid;
    const common_object = common_value.object;

    const env_config_value = root_object.get(env_name) orelse {
        std.debug.print("Error: Environment '{s}' not found in '{s}'.\n", .{ env_name, config_path });
        return ZenvError.EnvironmentNotFound;
    };
    if (env_config_value != .object) return ZenvError.ConfigInvalid;
    const env_config_object = env_config_value.object;

    const current_cluster = try getClusterName(allocator);
    defer allocator.free(current_cluster);

    var target_cluster: []const u8 = undefined;
    const has_target = env_config_object.get("target") != null;

    if (has_target) {
        const target_value = env_config_object.get("target") orelse unreachable;
        if (target_value != .string) return ZenvError.ConfigInvalid;
        const specified_target = target_value.string;

        if (!mem.eql(u8, specified_target, current_cluster)) {
            std.debug.print("Error: Environment '{s}' targets cluster '{s}', but you are on '{s}'.\n",
                           .{ env_name, specified_target, current_cluster });
            std.debug.print("Please run this command on the correct cluster or update the target in your config.\n", .{});
            return ZenvError.ClusterNotFound;
        }

        target_cluster = try allocator.dupe(u8, specified_target);
    } else {
        target_cluster = try allocator.dupe(u8, current_cluster);
    }

    var active_config = ActiveConfig{
        .allocator = allocator,
        .env_name = try allocator.dupe(u8, env_name),
        .target_cluster = target_cluster,
        .parent_envs_dir = undefined,
        .requirements_file = undefined,
        .python_executable = undefined,
        .modules_to_load = std.ArrayList([]const u8).init(allocator),
        .custom_setup_commands = std.ArrayList([]const u8).init(allocator),
        .custom_activate_vars = std.StringHashMap([]const u8).init(allocator),
        .config_base_dir = undefined,
    };
    errdefer active_config.deinit();

    active_config.config_base_dir = try allocator.dupe(u8, config_base_dir);

    const getString = struct {
        pub fn func(obj: json.ObjectMap, key: []const u8) ZenvError![]const u8 {
            const val = obj.get(key) orelse return ZenvError.ConfigInvalid;
            if (val != .string) return ZenvError.ConfigInvalid;
            return val.string;
        }
    }.func;

    const getOptionalString = struct {
        pub fn func(obj: json.ObjectMap, key: []const u8) ZenvError!?[]const u8 {
            if (obj.get(key)) |val| {
                if (val == .string) return val.string;
                if (val == .null) return null;
                return ZenvError.ConfigInvalid;
            }
            return null;
        }
    }.func;

    const fillStringArray = struct {
        pub fn func(list: *std.ArrayList([]const u8), alloc: Allocator, obj: json.ObjectMap, key: []const u8) ZenvError!void {
            if (obj.get(key)) |val| {
                if (val != .array) return ZenvError.ConfigInvalid;
                try list.ensureTotalCapacity(list.items.len + val.array.items.len);
                for (val.array.items) |item| {
                    if (item != .string) return ZenvError.ConfigInvalid;
                    list.appendAssumeCapacity(try alloc.dupe(u8, item.string));
                }
            }
        }
    }.func;

    const fillStringMap = struct {
        pub fn func(map: *std.StringHashMap([]const u8), alloc: Allocator, obj: json.ObjectMap, key: []const u8, clobber: bool) ZenvError!void {
            if (obj.get(key)) |val| {
                if (val != .object) return ZenvError.ConfigInvalid;
                var iter = val.object.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* != .string) return ZenvError.ConfigInvalid;
                    const map_key = try alloc.dupe(u8, entry.key_ptr.*);
                    errdefer alloc.free(map_key);
                    const map_val = try alloc.dupe(u8, entry.value_ptr.*.string);
                    errdefer alloc.free(map_val);

                    if (clobber) {
                        const existing = map.get(map_key);
                        try map.put(map_key, map_val);
                        if (existing) |old| alloc.free(old);
                    } else {
                        if (!map.contains(map_key)) {
                             try map.put(map_key, map_val);
                        } else {
                             std.debug.print("Warning: Duplicate key '{s}' in JSON map ignored (no clobber).\n", .{map_key});
                             alloc.free(map_key);
                             alloc.free(map_val);
                        }
                    }
                }
            }
        }
    }.func;

    active_config.parent_envs_dir = try allocator.dupe(u8, try getString(common_object, "parent_envs_dir"));
    active_config.requirements_file = try allocator.dupe(u8, try getString(common_object, "requirements_file"));
    const common_python = try getOptionalString(common_object, "python_executable");
    try fillStringArray(&active_config.modules_to_load, allocator, common_object, "modules_to_load");
    try fillStringArray(&active_config.custom_setup_commands, allocator, common_object, "custom_setup_commands");
    try fillStringMap(&active_config.custom_activate_vars, allocator, common_object, "custom_activate_vars", false);

    const env_python = try getOptionalString(env_config_object, "python_executable");
    try fillStringArray(&active_config.modules_to_load, allocator, env_config_object, "modules_to_load");
    try fillStringArray(&active_config.custom_setup_commands, allocator, env_config_object, "custom_setup_commands");
    try fillStringMap(&active_config.custom_activate_vars, allocator, env_config_object, "custom_activate_vars", true);


    if (env_python) |pypath| {
        active_config.python_executable = try allocator.dupe(u8, pypath);
    } else if (common_python) |pypath| {
        active_config.python_executable = try allocator.dupe(u8, pypath);
    } else {
        active_config.python_executable = try allocator.dupe(u8, "python3");
    }

    return active_config;
}


fn doSetup(allocator: Allocator, config: *const ActiveConfig) !void {
    const parent_dir_abs = try fs.path.resolve(allocator, &[_][]const u8{ config.config_base_dir, config.parent_envs_dir });
    defer allocator.free(parent_dir_abs);
    const venv_path_abs = try fs.path.join(allocator, &[_][]const u8{ parent_dir_abs, config.env_name });
    defer allocator.free(venv_path_abs);
    const req_path_abs = try fs.path.resolve(allocator, &[_][]const u8{ config.config_base_dir, config.requirements_file });
    defer allocator.free(req_path_abs);

    std.debug.print("Target venv path: {s}\n", .{venv_path_abs});
    std.debug.print("Requirements path: {s}\n", .{req_path_abs});

    fs.cwd().makePath(parent_dir_abs) catch |err| {
        std.debug.print("Failed to create dir '{s}': {s}\n", .{ parent_dir_abs, @errorName(err) });
        return err;
    };
    fs.cwd().makePath(venv_path_abs) catch |err| {
        std.debug.print("Failed to create dir '{s}': {s}\n", .{ venv_path_abs, @errorName(err) });
        return err;
    };

    if (config.modules_to_load.items.len > 0) {
        std.debug.print("Loading modules: {s}\n", .{config.modules_to_load.items});

        var cmd_parts = std.ArrayList(u8).init(allocator);
        defer cmd_parts.deinit();

        try cmd_parts.appendSlice("module load");
        for (config.modules_to_load.items) |module_name| {
            try cmd_parts.append(' ');
            try cmd_parts.appendSlice(module_name);
        }

        const result = execAllowFail(allocator,
            &[_][]const u8{ "sh", "-c", cmd_parts.items },
            null,
            .{}) catch |err| {
            std.debug.print("Module load failed: {s}\n", .{@errorName(err)});
            return ZenvError.ProcessError;
        };
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("Module load failed with status: {any}\n", .{result.term});
            if (result.stderr.len > 0) {
                std.debug.print("Error: {s}\n", .{result.stderr});
            }
            return ZenvError.ProcessError;
        }

        std.debug.print("Modules loaded.\n", .{});
    } else {
        std.debug.print("No modules specified to load.\n", .{});
    }

    std.debug.print("Creating venv using Python: {s}\n", .{config.python_executable});
    const venv_args = [_][]const u8{ config.python_executable, "-m", "venv", venv_path_abs };
    try runCommand(allocator, &venv_args, null);
    std.debug.print("Venv created at: {s}\n", .{venv_path_abs});

    const pip_path = try fs.path.join(allocator, &[_][]const u8{ venv_path_abs, "bin", "pip" });
    defer allocator.free(pip_path);

    std.debug.print("Checking if requirements file exists: {s}\n", .{req_path_abs});
    const req_file_exists = (fs.cwd().access(req_path_abs, .{}) catch null) != null;
    if (req_file_exists) {
        std.debug.print("Installing requirements from: {s}\n", .{req_path_abs});
        const pip_args = [_][]const u8{ pip_path, "install", "-r", req_path_abs };
        try runCommand(allocator, &pip_args, null);
        std.debug.print("Requirements installed.\n", .{});
    } else {
        std.debug.print("Requirements file '{s}' not found, skipping pip install.\n", .{req_path_abs});
    }

    if (config.custom_setup_commands.items.len > 0) {
        std.debug.print("Running custom setup commands...\n", .{});
        for (config.custom_setup_commands.items) |cmd_str| {
            std.debug.print("Executing custom command: {s}\n", .{cmd_str});
            var parts = std.ArrayList([]const u8).init(allocator);
            errdefer parts.deinit();
            var iter = mem.splitScalar(u8, cmd_str, ' ');
            while (iter.next()) |part| {
                if (part.len > 0) try parts.append(part);
            }
            if (parts.items.len > 0) {
                try runCommand(allocator, parts.items, null);
            }
            parts.deinit();
        }
        std.debug.print("Custom setup commands finished.\n", .{});
    }

    std.debug.print("Creating activate.sh script...\n", .{});

    var activate_content = std.ArrayList(u8).init(allocator);
    defer activate_content.deinit();

    try activate_content.appendSlice("#!/bin/bash\n\n");
    try activate_content.appendSlice("# Generated by zenv for environment: ");
    try activate_content.appendSlice(config.env_name);
    try activate_content.appendSlice(" (target: ");
    try activate_content.appendSlice(config.target_cluster);
    try activate_content.appendSlice(")\n\n");

    if (config.modules_to_load.items.len > 0) {
        try activate_content.appendSlice("# Load required modules\n");
        try activate_content.appendSlice("module purge 2>/dev/null\n");
        for (config.modules_to_load.items) |module_name| {
            try activate_content.appendSlice("module load ");
            try activate_content.appendSlice(module_name);
            try activate_content.appendSlice("\n");
        }
        try activate_content.appendSlice("\n");
    }

    try activate_content.appendSlice("# Activate the virtual environment\n");
    try activate_content.appendSlice("SCRIPT_DIR=$(dirname \"${BASH_SOURCE[0]:-${(%):-%x}}\")\n");
    try activate_content.appendSlice("VENV_DIR=$(realpath \"${SCRIPT_DIR}\")\n");
    try activate_content.appendSlice("source \"${VENV_DIR}\"/bin/activate\n\n");

    if (config.custom_activate_vars.count() > 0) {
        try activate_content.appendSlice("# Set custom environment variables\n");
        var iter = config.custom_activate_vars.iterator();
        while (iter.next()) |entry| {
            try activate_content.appendSlice("export ");
            try activate_content.appendSlice(entry.key_ptr.*);
            try activate_content.appendSlice("=\"");

            var i: usize = 0;
            while (i < entry.value_ptr.*.len) : (i += 1) {
                const c = entry.value_ptr.*[i];
                if (c == '"') {
                    try activate_content.appendSlice("\\");
                }
                try activate_content.append(c);
            }

            try activate_content.appendSlice("\"\n");
        }
        try activate_content.appendSlice("\n");
    }

    try activate_content.appendSlice("# Reminder: This script must be sourced, not executed\n");
    try activate_content.appendSlice("echo \"Environment activated: ");
    try activate_content.appendSlice(config.env_name);
    try activate_content.appendSlice(" (target: ");
    try activate_content.appendSlice(config.target_cluster);
    try activate_content.appendSlice(")\"\n");

    const activate_path = try fs.path.join(allocator, &[_][]const u8{ venv_path_abs, "activate.sh" });
    defer allocator.free(activate_path);

    var activate_file = try fs.cwd().createFile(activate_path, .{ .mode = 0o755 });
    defer activate_file.close();

    try activate_file.writeAll(activate_content.items);

    std.debug.print("Created activate.sh at: {s}\n", .{activate_path});
    std.debug.print("Usage: source {s}\n", .{activate_path});

    std.debug.print("Setup for environment '{s}' (target: {s}) complete.\n", .{config.env_name, config.target_cluster});
}

fn findMatchingEnvs(allocator: Allocator, config_path: []const u8) !std.ArrayList([]const u8) {
    const config_content = fs.cwd().readFileAlloc(allocator, config_path, 1 * 1024 * 1024) catch |err| {
        std.debug.print("Failed to read config file '{s}': {s}\n", .{ config_path, @errorName(err) });
        if (err == error.FileNotFound) return ZenvError.ConfigFileNotFound;
        return ZenvError.ConfigFileReadError;
    };
    defer allocator.free(config_content);

    var tree = json.parseFromSlice(json.Value, allocator, config_content, .{}) catch |err| {
        std.debug.print("Failed to parse JSON in '{s}': {s}\n", .{ config_path, @errorName(err) });
        return ZenvError.JsonParseError;
    };
    defer tree.deinit();

    const root_value = tree.value;
    if (root_value != .object) return ZenvError.ConfigInvalid;
    const root_object = root_value.object;

    const current_cluster = try getClusterName(allocator);
    defer allocator.free(current_cluster);

    var matching_envs = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (matching_envs.items) |env_name| {
            allocator.free(env_name);
        }
        matching_envs.deinit();
    }

    var root_iter = root_object.iterator();
    while (root_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Skip "common" and non-object entries
        if (mem.eql(u8, key, "common") or value != .object) {
            continue;
        }

        const env_object = value.object;

        if (env_object.get("target")) |target_value| {
            if (target_value != .string) continue;
            const target = target_value.string;

            // If target matches current cluster, add to matches
            if (mem.eql(u8, target, current_cluster)) {
                try matching_envs.append(try allocator.dupe(u8, key));
            }
        } else {
            // No target field means it could run anywhere
            // Optionally, you could include these too
            // try matching_envs.append(try allocator.dupe(u8, key));
        }
    }

    return matching_envs;
}
// Define a struct type for environment info
const EnvInfo = struct {
    name: []const u8,
    target: ?[]const u8,
    matches_current: bool,
};

// List available environments in the config file
fn doListConfiguredEnvs(allocator: Allocator, config_path: []const u8) !void {
    const config_content = fs.cwd().readFileAlloc(allocator, config_path, 1 * 1024 * 1024) catch |err| {
        std.debug.print("Failed to read config file '{s}': {s}\n", .{ config_path, @errorName(err) });
        if (err == error.FileNotFound) return ZenvError.ConfigFileNotFound;
        return ZenvError.ConfigFileReadError;
    };
    defer allocator.free(config_content);

    var tree = json.parseFromSlice(json.Value, allocator, config_content, .{}) catch |err| {
        std.debug.print("Failed to parse JSON in '{s}': {s}\n", .{ config_path, @errorName(err) });
        return ZenvError.JsonParseError;
    };
    defer tree.deinit();

    const root_value = tree.value;
    if (root_value != .object) return ZenvError.ConfigInvalid;
    const root_object = root_value.object;

    // Get the current hostname-based cluster for highlighting matching environments
    const current_cluster = try getClusterName(allocator);
    defer allocator.free(current_cluster);

    // Collect all environments and their targets
    var envs = std.ArrayList(EnvInfo).init(allocator);
    defer {
        for (envs.items) |item| {
            if (item.target) |target| {
                allocator.free(target);
            }
        }
        envs.deinit();
    }

    var root_iter = root_object.iterator();
    while (root_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        // Skip "common" and non-object entries
        if (mem.eql(u8, key, "common") or value != .object) {
            continue;
        }

        const env_object = value.object;
        var target: ?[]const u8 = null;
        var matches_current = false;

        // Check if this environment has a target field
        if (env_object.get("target")) |target_value| {
            if (target_value == .string) {
                target = try allocator.dupe(u8, target_value.string);
                matches_current = mem.eql(u8, target_value.string, current_cluster);
            }
        }

        try envs.append(.{
            .name = key,
            .target = target,
            .matches_current = matches_current,
        });
    }

    // Sort environments by name
    std.sort.heap(EnvInfo, envs.items, {}, comptime struct {
        pub fn lessThan(_: void, a: EnvInfo, b: EnvInfo) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\nAvailable environments in {s}:\n\n", .{config_path});

    // Count environments that match the current cluster
    var matching_count: usize = 0;
    for (envs.items) |item| {
        if (item.matches_current) matching_count += 1;
    }

    if (envs.items.len == 0) {
        try stdout.print("No environments found.\n", .{});
    } else {
        // Header
        try stdout.print("NAME\tTARGET\tMATCHES CURRENT\n", .{});
        try stdout.print("----\t------\t--------------\n", .{});

        // Environment rows
        for (envs.items) |item| {
            try stdout.print("{s}\t", .{item.name});

            if (item.target) |target| {
                try stdout.print("{s}\t", .{target});
            } else {
                try stdout.print("(any)\t", .{});
            }

            if (item.matches_current) {
                try stdout.print("YES\n", .{});
            } else {
                try stdout.print("no\n", .{});
            }
        }
    }

    try stdout.print("\nTotal: {d} environment(s)\n", .{envs.items.len});
    if (matching_count > 0) {
        try stdout.print("Found {d} environment(s) matching your current cluster '{s}'\n", .{matching_count, current_cluster});
    } else {
        try stdout.print("No environments match your current cluster '{s}'\n", .{current_cluster});
    }

    // try stdout.print("\nTo set up an environment:\n  zenv setup [env_name]\n", .{});
    // try stdout.print("To activate an environment:\n  zenv activate [env_name]\n", .{});
    // try stdout.print("\nIf you omit the environment name, zenv will try to auto-detect\nbased on your current cluster name.\n", .{});
}

// List actual environment directories in parent_envs_dir
fn doListExistingEnvs(allocator: Allocator, config_path: []const u8) !void {
    // First read the configuration to get the parent_envs_dir path
    const config_content = fs.cwd().readFileAlloc(allocator, config_path, 1 * 1024 * 1024) catch |err| {
        std.debug.print("Failed to read config file '{s}': {s}\n", .{ config_path, @errorName(err) });
        if (err == error.FileNotFound) return ZenvError.ConfigFileNotFound;
        return ZenvError.ConfigFileReadError;
    };
    defer allocator.free(config_content);

    var tree = json.parseFromSlice(json.Value, allocator, config_content, .{}) catch |err| {
        std.debug.print("Failed to parse JSON in '{s}': {s}\n", .{ config_path, @errorName(err) });
        return ZenvError.JsonParseError;
    };
    defer tree.deinit();

    const root_value = tree.value;
    if (root_value != .object) return ZenvError.ConfigInvalid;
    const root_object = root_value.object;

    const common_value = root_object.get("common") orelse return ZenvError.ConfigInvalid;
    if (common_value != .object) return ZenvError.ConfigInvalid;
    const common_object = common_value.object;

    // Get parent_envs_dir from common section
    const parent_envs_dir_value = common_object.get("parent_envs_dir") orelse return ZenvError.ConfigInvalid;
    if (parent_envs_dir_value != .string) return ZenvError.ConfigInvalid;
    const parent_envs_dir = parent_envs_dir_value.string;

    const config_base_dir = fs.path.dirname(config_path) orelse ".";

    // We need to ensure we're using an absolute path
    const cwd = try fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const config_base_abs = if (fs.path.isAbsolute(config_base_dir))
        try allocator.dupe(u8, config_base_dir)
    else
        try fs.path.join(allocator, &[_][]const u8{cwd, config_base_dir});
    defer allocator.free(config_base_abs);

    const parent_dir_abs = try fs.path.join(allocator, &[_][]const u8{config_base_abs, parent_envs_dir});
    defer allocator.free(parent_dir_abs);

    // Verify this is an absolute path
    if (!fs.path.isAbsolute(parent_dir_abs)) {
        std.debug.print("Error: Could not determine absolute path for '{s}'\n", .{parent_dir_abs});
        return ZenvError.PathResolutionFailed;
    }

    // Now list all directories in parent_envs_dir
    var dir = fs.openDirAbsolute(parent_dir_abs, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Environment directory '{s}' does not exist. Run 'zenv setup' first.\n", .{parent_dir_abs});
            return ZenvError.IoError;
        }
        std.debug.print("Error opening directory '{s}': {s}\n", .{parent_dir_abs, @errorName(err)});
        return ZenvError.IoError;
    };
    defer dir.close();

    // Get list of all directories and check if they have an activate.sh script
    var env_dirs = std.ArrayList([]const u8).init(allocator);
    defer {
        for (env_dirs.items) |item| {
            allocator.free(item);
        }
        env_dirs.deinit();
    }

    var iter = dir.iterate();
    while (iter.next() catch |err| {
        std.debug.print("Error reading directory: {s}\n", .{@errorName(err)});
        return ZenvError.IoError;
    }) |entry| {
        if (entry.kind == .directory) {
            const env_path = try fs.path.join(allocator, &[_][]const u8{parent_dir_abs, entry.name});
            defer allocator.free(env_path);

            // Check if this directory has an activate.sh script
            const activate_path = try fs.path.join(allocator, &[_][]const u8{env_path, "activate.sh"});
            defer allocator.free(activate_path);

            const has_activate = (fs.cwd().access(activate_path, .{}) catch null) != null;
            if (has_activate) {
                try env_dirs.append(try allocator.dupe(u8, entry.name));
            }
        }
    }

    // Sort the environment names
    std.sort.heap([]const u8, env_dirs.items, {}, comptime struct {
        pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Print results
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\nExisting environments in {s}:\n\n", .{parent_dir_abs});

    if (env_dirs.items.len == 0) {
        try stdout.print("No environments found. Run 'zenv setup' first.\n", .{});
    } else {
        for (env_dirs.items) |name| {
            try stdout.print("- {s}\n", .{name});
        }
        try stdout.print("\nTotal: {d} environment(s)\n", .{env_dirs.items.len});
    }

    // Show hint
    // try stdout.print("\nUse 'zenv list --all' to see all available environments in the config.\n", .{});
    // try stdout.print("To set up an environment:\n  zenv setup [env_name]\n", .{});
    // try stdout.print("To activate an environment:\n  zenv activate [env_name]\n", .{});
}
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
        try err_writer.print("To activate this environment, run:\n", .{});
        try err_writer.print("source {s}\n", .{activate_sh_path});
    } else {
        try err_writer.print("No activation script found for environment '{s}'\n", .{config.env_name});
        try err_writer.print("Run 'zenv setup {s}' first to create the virtual environment\n", .{config.env_name});
        return ZenvError.ConfigInvalid;
    }
}


fn printUsage() void {
    const usage = comptime
        \\Usage: zenv <command>
        \\
        \\Commands:
        \\  setup [env_name]     Set up a virtual environment. If env_name is omitted,
        \\                       it will try to auto-detect based on hostname.
        \\  activate [env_name]  Print instructions to activate an environment. If env_name
        \\                       is omitted, it will try to auto-detect based on hostname.
        \\  list                 List existing environments that have been set up.
        \\  list --all           List all available environments from the config file.
        \\  help                 Show this help message.
        \\
    ;
    std.io.getStdErr().writer().print("{s}", .{usage}) catch {};
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);

    if (args.len < 2 or mem.eql(u8, args[1], "help") or mem.eql(u8, args[1], "--help")) {
        printUsage();
        process.exit(0);
    }

    const command = args[1];
    const config_path = "zenv.json";

    const handleError = struct {
        pub fn func(err: anyerror) void {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
            switch (@as(ZenvError, @errorCast(err))) {
                ZenvError.ConfigFileNotFound => stderr.print(" -> Configuration file '{s}' not found.\n", .{config_path}) catch {},
                ZenvError.ClusterNotFound => stderr.print(" -> Target cluster doesn't match current hostname.\n", .{}) catch {},
                ZenvError.EnvironmentNotFound => stderr.print(" -> Environment not found in '{s}'.\n", .{config_path}) catch {},
                ZenvError.JsonParseError => stderr.print(" -> Invalid JSON format in '{s}'. Check syntax.\n", .{config_path}) catch {},
                ZenvError.ConfigInvalid => stderr.print(" -> Invalid configuration structure in '{s}'. Check keys/types.\n", .{config_path}) catch {},
                ZenvError.ProcessError => stderr.print(" -> An external command failed. See output above for details.\n", .{}) catch {},
                ZenvError.MissingHostname => stderr.print(" -> HOSTNAME environment variable not set or inaccessible.\n", .{}) catch {},
                else => {
                    stderr.print(" -> Unexpected error: {s}\n", .{@errorName(err)}) catch {};
                },
            }
            process.exit(1);
        }
    }.func;

    // Environment name auto-detection is now handled in the command implementations
    // No validation needed here as both commands now support auto-detection

    if (mem.eql(u8, command, "setup")) {
        var env_name: []const u8 = undefined;
        var env_name_needs_free = false;
        defer if (env_name_needs_free) allocator.free(env_name);

        if (args.len >= 3) {
            env_name = args[2];
        } else {
            var matching_envs = findMatchingEnvs(allocator, config_path) catch |err| {
                handleError(err);
                return error.CommandFailed;
            };
            defer {
                for (matching_envs.items) |item| {
                    allocator.free(item);
                }
                matching_envs.deinit();
            }

            if (matching_envs.items.len == 0) {
                std.io.getStdErr().writer().print("Error: No environments found targeting your cluster '{s}'\n", .{try getClusterName(allocator)}) catch {};
                std.io.getStdErr().writer().print("Please specify environment name: zenv setup <environment_name>\n", .{}) catch {};
                process.exit(1);
            } else if (matching_envs.items.len > 1) {
                std.io.getStdErr().writer().print("Error: Multiple environments found targeting your cluster:\n", .{}) catch {};
                for (matching_envs.items) |item| {
                    std.io.getStdErr().writer().print("  - {s}\n", .{item}) catch {};
                }
                std.io.getStdErr().writer().print("Please specify which one to use: zenv setup <environment_name>\n", .{}) catch {};
                process.exit(1);
            } else {
                env_name = try allocator.dupe(u8, matching_envs.items[0]);
                env_name_needs_free = true;
                std.debug.print("Auto-selected environment '{s}' based on your cluster\n", .{env_name});
            }
        }

        var active_config = loadAndMergeConfig(allocator, config_path, env_name) catch |err| {
            handleError(err);
            return error.CommandFailed;
        };
        doSetup(allocator, &active_config) catch |err| {
            handleError(err);
            return error.CommandFailed;
        };
    } else if (mem.eql(u8, command, "activate")) {
        var env_name: []const u8 = undefined;
        var env_name_needs_free = false;
        defer if (env_name_needs_free) allocator.free(env_name);

        if (args.len >= 3) {
            env_name = args[2];
        } else {
            var matching_envs = findMatchingEnvs(allocator, config_path) catch |err| {
                handleError(err);
                return error.CommandFailed;
            };
            defer {
                for (matching_envs.items) |item| {
                    allocator.free(item);
                }
                matching_envs.deinit();
            }

            if (matching_envs.items.len == 0) {
                std.io.getStdErr().writer().print("Error: No environments found targeting your cluster '{s}'\n", .{try getClusterName(allocator)}) catch {};
                std.io.getStdErr().writer().print("Please specify environment name: zenv activate <environment_name>\n", .{}) catch {};
                process.exit(1);
            } else if (matching_envs.items.len > 1) {
                std.io.getStdErr().writer().print("Error: Multiple environments found targeting your cluster:\n", .{}) catch {};
                for (matching_envs.items) |item| {
                    std.io.getStdErr().writer().print("  - {s}\n", .{item}) catch {};
                }
                std.io.getStdErr().writer().print("Please specify which one to use: zenv activate <environment_name>\n", .{}) catch {};
                process.exit(1);
            } else {
                env_name = try allocator.dupe(u8, matching_envs.items[0]);
                env_name_needs_free = true;
                std.debug.print("Auto-selected environment '{s}' based on your cluster\n", .{env_name});
            }
        }

        var active_config = loadAndMergeConfig(allocator, config_path, env_name) catch |err| {
            handleError(err);
            return error.CommandFailed;
        };
        doActivate(allocator, &active_config) catch |err| {
            handleError(err);
            return error.CommandFailed;
        };
    } else if (mem.eql(u8, command, "list")) {
        // Check if --all flag is present
        const show_all = args.len >= 3 and mem.eql(u8, args[2], "--all");

        if (show_all) {
            // Show all available environments from config
            doListConfiguredEnvs(allocator, config_path) catch |err| {
                handleError(err);
                return error.CommandFailed;
            };
        } else {
            // Show only existing environments
            doListExistingEnvs(allocator, config_path) catch |err| {
                handleError(err);
                return error.CommandFailed;
            };
        }
    } else {
        std.io.getStdErr().writer().print("Error: Unknown command '{s}'\n\n", .{command}) catch {};
        printUsage();
        process.exit(1);
    }
}


test "getClusterName" {
    const allocator = testing.allocator;
    try std.process.setEnvVar("HOSTNAME", "login01.jureca.fz-juelich.de");
    var cluster_name = try getClusterName(allocator);
    defer allocator.free(cluster_name);
    try testing.expectEqualStrings("jureca", cluster_name);

    try std.process.setEnvVar("HOSTNAME", "jrlogin04.jureca");
    cluster_name = try getClusterName(allocator);
    defer allocator.free(cluster_name);
    try testing.expectEqualStrings("jureca", cluster_name);

    try std.process.setEnvVar("HOSTNAME", "booster-01");
    cluster_name = try getClusterName(allocator);
    defer allocator.free(cluster_name);
    try testing.expectEqualStrings("booster-01", cluster_name);
}

test "JSON config parsing and merging" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const mock_json_content = comptime
        \\{
        \\  "common": {
        \\    "parent_envs_dir": "venvs",
        \\    "requirements_file": "reqs.txt",
        \\    "python_executable": "/usr/bin/python3.9",
        \\    "custom_activate_vars": { "COMMON_VAR": "common_val", "ONLY_COMMON": "yes" }
        \\  },
        \\  "sc": {
        \\    "testcluster": {
        \\      "modules_to_load": ["gcc/11", "python/3.10"],
        \\      "python_executable": "/opt/python/3.10/bin/python",
        \\      "custom_activate_vars": { "CLUSTER_VAR": "cluster_val", "COMMON_VAR": "override_val" }
        \\    }
        \\  }
        \\}
    ;

    const tree = try json.parseFromSlice(json.Value, allocator, mock_json_content, .{});

    const root_object = tree.value.object;
    const common_object = root_object.get("common").?.object;
    const sc_object = root_object.get("sc").?.object;
    const cluster_object = sc_object.get("testcluster").?.object;

    const mock_cluster_name = "testcluster";
    var active_config = ActiveConfig{
        .allocator = allocator,
        .cluster_name = try allocator.dupe(u8, mock_cluster_name),
        .parent_envs_dir = undefined,
        .requirements_file = undefined,
        .python_executable = undefined,
        .modules_to_load = std.ArrayList([]const u8).init(allocator),
        .custom_setup_commands = std.ArrayList([]const u8).init(allocator),
        .custom_activate_vars = std.StringHashMap([]const u8).init(allocator),
        .config_base_dir = try allocator.dupe(u8, "."),
    };

    const getString = main.getString;
    const getOptionalString = main.getOptionalString;
    const fillStringArray = main.fillStringArray;
    const fillStringMap = main.fillStringMap;

    active_config.parent_envs_dir = try allocator.dupe(u8, try getString(common_object, "parent_envs_dir"));
    active_config.requirements_file = try allocator.dupe(u8, try getString(common_object, "requirements_file"));
    const common_python = try getOptionalString(common_object, "python_executable");
    try fillStringArray(&active_config.modules_to_load, allocator, common_object, "modules_to_load");
    try fillStringArray(&active_config.custom_setup_commands, allocator, common_object, "custom_setup_commands");
    try fillStringMap(&active_config.custom_activate_vars, allocator, common_object, "custom_activate_vars", false);

    const cluster_python = try getOptionalString(cluster_object, "python_executable");
    try fillStringArray(&active_config.modules_to_load, allocator, cluster_object, "modules_to_load");
    try fillStringArray(&active_config.custom_setup_commands, allocator, cluster_object, "custom_setup_commands");
    try fillStringMap(&active_config.custom_activate_vars, allocator, cluster_object, "custom_activate_vars", true);

    if (cluster_python) |pypath| {
        active_config.python_executable = try allocator.dupe(u8, pypath);
    } else if (common_python) |pypath| {
        active_config.python_executable = try allocator.dupe(u8, pypath);
    } else {
        active_config.python_executable = try allocator.dupe(u8, "python3");
    }

    try testing.expectEqualStrings("venvs", active_config.parent_envs_dir);
    try testing.expectEqualStrings("reqs.txt", active_config.requirements_file);
    try testing.expectEqualStrings("/opt/python/3.10/bin/python", active_config.python_executable);
    try testing.expectEqual(@as(usize, 2), active_config.modules_to_load.items.len);
    try testing.expectEqualStrings("gcc/11", active_config.modules_to_load.items[0]);
    try testing.expectEqualStrings("python/3.10", active_config.modules_to_load.items[1]);
    try testing.expectEqual(@as(usize, 3), active_config.custom_activate_vars.count());
    try testing.expectEqualStrings("override_val", active_config.custom_activate_vars.get("COMMON_VAR").?);
    try testing.expectEqualStrings("cluster_val", active_config.custom_activate_vars.get("CLUSTER_VAR").?);
    try testing.expectEqualStrings("yes", active_config.custom_activate_vars.get("ONLY_COMMON").?);
}
