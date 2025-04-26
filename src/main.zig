const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const testing = std.testing;
const Allocator = mem.Allocator;
const json = std.json;

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
    // Errors propagated from std.process
    EnvironmentVariableNotFound, // From getEnvVarOwned
    InvalidWtf8,                // From getEnvVarOwned
};

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
    dependencies: std.ArrayList([]const u8),
    config_base_dir: []const u8, // Directory where zenv.json lives

    fn deinitStringList(self: *ActiveConfig, list: *std.ArrayList([]const u8)) void {
        for (list.items) |item| {
            self.allocator.free(item);
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
        self.deinitStringList(&self.dependencies);
        self.deinitStringMap(&self.custom_activate_vars);
        self.allocator.free(self.config_base_dir);
    }
};

// Defines structs for holding parsed zenv.json configuration

const EnvironmentConfig = struct {
    target: ?[]const u8 = null,
    python_executable: ?[]const u8 = null,
    modules_to_load: std.ArrayListUnmanaged([]const u8) = .{},
    custom_setup_commands: std.ArrayListUnmanaged([]const u8) = .{},
    custom_activate_vars: std.StringHashMapUnmanaged([]const u8) = .{},
    dependencies: std.ArrayListUnmanaged([]const u8) = .{},

    fn deinit(self: *EnvironmentConfig, allocator: Allocator) void {
        allocator.free(self.target orelse ""); // Free if not null
        allocator.free(self.python_executable orelse ""); // Free if not null

        for (self.modules_to_load.items) |item| allocator.free(item);
        self.modules_to_load.deinit(allocator);

        for (self.custom_setup_commands.items) |item| allocator.free(item);
        self.custom_setup_commands.deinit(allocator);

        var var_iter = self.custom_activate_vars.iterator();
        while (var_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.custom_activate_vars.deinit(allocator);

        for (self.dependencies.items) |item| allocator.free(item);
        self.dependencies.deinit(allocator);
    }
};

const CommonConfig = struct {
    parent_envs_dir: []const u8,
    requirements_file: []const u8,
    python_executable: ?[]const u8 = null,
    modules_to_load: std.ArrayListUnmanaged([]const u8) = .{},
    custom_setup_commands: std.ArrayListUnmanaged([]const u8) = .{},
    custom_activate_vars: std.StringHashMapUnmanaged([]const u8) = .{},
    dependencies: std.ArrayListUnmanaged([]const u8) = .{},

    fn deinit(self: *CommonConfig, allocator: Allocator) void {
        allocator.free(self.parent_envs_dir);
        allocator.free(self.requirements_file);
        allocator.free(self.python_executable orelse ""); // Free if not null

        for (self.modules_to_load.items) |item| allocator.free(item);
        self.modules_to_load.deinit(allocator);

        for (self.custom_setup_commands.items) |item| allocator.free(item);
        self.custom_setup_commands.deinit(allocator);

        var var_iter = self.custom_activate_vars.iterator();
        while (var_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.custom_activate_vars.deinit(allocator);

        for (self.dependencies.items) |item| allocator.free(item);
        self.dependencies.deinit(allocator);
    }
};

// Represents the entire parsed zenv.json configuration
const ZenvConfig = struct {
    allocator: Allocator,
    config_base_dir: []const u8,
    common: CommonConfig,
    environments: std.StringHashMapUnmanaged(EnvironmentConfig), // key = env_name

    // Helper function to parse a string array from JSON, allocating copies
    fn parseStringArray(
        alloc: Allocator,
        json_val: json.Value,
    ) ZenvError!std.ArrayListUnmanaged([]const u8) {
        if (json_val != .array) return ZenvError.ConfigInvalid;
        var list = std.ArrayListUnmanaged([]const u8){};
        errdefer list.deinit(alloc); // Clean up partially filled list on error
        try list.ensureTotalCapacity(alloc, json_val.array.items.len);
        for (json_val.array.items) |item| {
            if (item != .string) return ZenvError.ConfigInvalid;
            list.appendAssumeCapacity(try alloc.dupe(u8, item.string));
        }
        return list;
    }

    // Helper function to parse a string map from JSON, allocating copies
    fn parseStringMap(
        alloc: Allocator,
        json_val: json.Value,
    ) ZenvError!std.StringHashMapUnmanaged([]const u8) {
        if (json_val != .object) return ZenvError.ConfigInvalid;
        var map = std.StringHashMapUnmanaged([]const u8){};
        errdefer map.deinit(alloc); // Clean up partially filled map on error
        var iter = json_val.object.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .string) return ZenvError.ConfigInvalid;
            const map_key = try alloc.dupe(u8, entry.key_ptr.*);
            errdefer alloc.free(map_key);
            const map_val = try alloc.dupe(u8, entry.value_ptr.*.string);
            errdefer alloc.free(map_val);
            try map.put(alloc, map_key, map_val);
        }
        return map;
    }

    // Helper function to parse an optional string, allocating a copy if present
    fn parseOptionalString(
        alloc: Allocator,
        json_val: json.Value,
    ) ZenvError!?[]const u8 {
        switch (json_val) {
            .string => return @as(?[]const u8, try alloc.dupe(u8, json_val.string)),
            .null => return null,
            else => return ZenvError.ConfigInvalid,
        }
    }

    // Helper function to parse a required string, allocating a copy
    fn parseRequiredString(
        alloc: Allocator,
        json_val: json.Value,
    ) ZenvError![]const u8 {
        if (json_val != .string) return ZenvError.ConfigInvalid;
        return alloc.dupe(u8, json_val.string);
    }

    // Parses the zenv.json file content
    pub fn parse(allocator: Allocator, config_path: []const u8) ZenvError!ZenvConfig {
        const config_base_dir = fs.path.dirname(config_path) orelse ".";
        const config_content = fs.cwd().readFileAlloc(allocator, config_path, 1 * 1024 * 1024) catch |err| {
            std.debug.print("Failed to read config file '{s}': {s}\n", .{ config_path, @errorName(err) });
            if (err == error.FileNotFound) return ZenvError.ConfigFileNotFound;
            return ZenvError.ConfigFileReadError;
        };
        defer allocator.free(config_content);

        const tree = json.parseFromSlice(json.Value, allocator, config_content, .{}) catch |err| {
            std.debug.print("Failed to parse JSON in '{s}': {s}\n", .{ config_path, @errorName(err) });
            return ZenvError.JsonParseError;
        };
        defer tree.deinit();

        if (tree.value != .object) return ZenvError.ConfigInvalid;
        const root_object = tree.value.object;

        // Parse "common" section
        const common_val = root_object.get("common") orelse return ZenvError.ConfigInvalid;
        if (common_val != .object) return ZenvError.ConfigInvalid;
        const common_obj = common_val.object;

        var common_config = CommonConfig{
            .parent_envs_dir = try parseRequiredString(allocator, common_obj.get("parent_envs_dir") orelse return ZenvError.ConfigInvalid),
            .requirements_file = try parseRequiredString(allocator, common_obj.get("requirements_file") orelse return ZenvError.ConfigInvalid),
            .python_executable = if (common_obj.get("python_executable")) |v| try parseOptionalString(allocator, v) else null,
            .modules_to_load = if (common_obj.get("modules_to_load")) |v| try parseStringArray(allocator, v) else .{},
            .custom_setup_commands = if (common_obj.get("custom_setup_commands")) |v| try parseStringArray(allocator, v) else .{},
            .custom_activate_vars = if (common_obj.get("custom_activate_vars")) |v| try parseStringMap(allocator, v) else .{},
            .dependencies = if (common_obj.get("dependencies")) |v| try parseStringArray(allocator, v) else .{},
        };
        errdefer common_config.deinit(allocator); // Deinit if environment parsing fails

        // Parse environments
        var environments_map = std.StringHashMapUnmanaged(EnvironmentConfig){};
        errdefer { // Deinit partially built map on error
            var env_iter = environments_map.iterator();
            while(env_iter.next()) |entry| entry.value_ptr.deinit(allocator);
            environments_map.deinit(allocator);
        }

        var root_iter = root_object.iterator();
        while (root_iter.next()) |entry| {
            const env_name = entry.key_ptr.*;
            const env_val = entry.value_ptr.*;

            if (mem.eql(u8, env_name, "common")) continue; // Skip common section
            if (env_val != .object) {
                std.debug.print("Warning: Skipping non-object entry '{s}' in config root.\n", .{env_name});
                continue;
            }
            const env_obj = env_val.object;

            const env_config = EnvironmentConfig{
                 .target = if (env_obj.get("target")) |v| try parseOptionalString(allocator, v) else null,
                 .python_executable = if (env_obj.get("python_executable")) |v| try parseOptionalString(allocator, v) else null,
                 .modules_to_load = if (env_obj.get("modules_to_load")) |v| try parseStringArray(allocator, v) else .{},
                 .custom_setup_commands = if (env_obj.get("custom_setup_commands")) |v| try parseStringArray(allocator, v) else .{},
                 .custom_activate_vars = if (env_obj.get("custom_activate_vars")) |v| try parseStringMap(allocator, v) else .{},
                 .dependencies = if (env_obj.get("dependencies")) |v| try parseStringArray(allocator, v) else .{},
            };
            // Need to store env_name permanently as map key
            const map_key = try allocator.dupe(u8, env_name);
            errdefer allocator.free(map_key); // Free key if put fails (unlikely for new map)

            // Put the config and take ownership of map_key
            try environments_map.put(allocator, map_key, env_config);
        }

        // Success, transfer ownership
        return ZenvConfig{
            .allocator = allocator,
            .config_base_dir = try allocator.dupe(u8, config_base_dir),
            .common = common_config,
            .environments = environments_map,
        };
    }

    // Deinitializes the configuration structure, freeing all allocated memory
    pub fn deinit(self: *ZenvConfig) void {
        // Deinit common config
        self.common.deinit(self.allocator);

        // Deinit each environment config and the map itself
        var env_iter = self.environments.iterator();
        while (env_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*); // Free the duplicated env name (key)
            entry.value_ptr.deinit(self.allocator); // Deinit the EnvironmentConfig struct
        }
        self.environments.deinit(self.allocator);

        // Free base dir
        self.allocator.free(self.config_base_dir);
    }
};


// Refactored main function and helper for environment resolution

// Attempts to resolve the environment name based on args or auto-detection
fn resolveEnvironmentName(
    allocator: Allocator, // Allocator for potentially duplicating the result
    config: *const ZenvConfig,
    args: []const []const u8, // Command line arguments [exec_path, command, maybe_env_name, ...]
    command_name: []const u8, // e.g., "setup" or "activate"
) ZenvError![]const u8 {
    if (args.len >= 3) {
        // Environment name provided explicitly
        const requested_env = args[2];
        if (!config.environments.contains(requested_env)) {
            std.debug.print("Error: Environment '{s}' not found in '{s}'.\n", .{ requested_env, "zenv.json" }); // Assuming config path is zenv.json
            return ZenvError.EnvironmentNotFound;
        }
        // Return a duplicated string as the caller will own it
        return allocator.dupe(u8, requested_env);
    } else {
        // Attempt auto-detection based on current cluster
        std.debug.print("No environment name specified, attempting auto-detection...\n", .{});
        const current_cluster = getClusterName(allocator) catch |err| {
             std.debug.print("Failed to get cluster name for auto-detection: {s}\n", .{@errorName(err)});
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
        std.debug.print("Current cluster detected as: {s}\n", .{current_cluster});


        var matching_envs = std.ArrayList([]const u8).init(allocator);
        // We don't need to deinit matching_envs items as they are slices from ZenvConfig keys
        defer matching_envs.deinit();

        var iter = config.environments.iterator();
        while (iter.next()) |entry| {
            // Match if target exists and equals current cluster
            if (entry.value_ptr.target) |target| {
                if (mem.eql(u8, target, current_cluster)) {
                    // entry.key_ptr.* is the environment name string owned by ZenvConfig
                    try matching_envs.append(entry.key_ptr.*);
                }
            }
            // Note: Environments without a "target" field are NOT considered for auto-detection
        }

        if (matching_envs.items.len == 0) {
            std.io.getStdErr().writer().print(
                \\Error: Auto-detection failed. No environments found targeting your cluster '{s}'.
                \\Please specify environment name: zenv {s} <environment_name>
                \\Use 'zenv list --all' to see available environments.
            , .{ current_cluster, command_name }) catch {};
            return ZenvError.EnvironmentNotFound; // Or a more specific error?
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
            return ZenvError.EnvironmentNotFound; // Or a more specific error?
        } else {
            // Exactly one match found
            const resolved_env = matching_envs.items[0];
            std.debug.print("Auto-selected environment '{s}' based on your cluster\n", .{resolved_env});
            // Return a duplicated string as the caller will own it
            return allocator.dupe(u8, resolved_env);
        }
    }
}




// Helper to merge two lists of strings into a destination list,
// allocating copies of the strings.
fn mergeList(
    dest: *std.ArrayList([]const u8),
    list1: std.ArrayListUnmanaged([]const u8),
    list2: std.ArrayListUnmanaged([]const u8),
    alloc: Allocator,
) ZenvError!void {
     try dest.ensureTotalCapacity(list1.items.len + list2.items.len);
     for (list1.items) |item| try dest.append(try alloc.dupe(u8, item));
     for (list2.items) |item| try dest.append(try alloc.dupe(u8, item));
}

// Creates the ActiveConfig by merging common and environment-specific settings
// Takes ownership of env_name if successful, frees it on error.
fn createActiveConfig(
    allocator: Allocator,
    config: *const ZenvConfig,
    env_name: []const u8, // Takes ownership on success
) ZenvError!ActiveConfig {
    errdefer allocator.free(env_name); // Free env_name if any part of this function fails

    const env_config = config.environments.get(env_name) orelse return ZenvError.EnvironmentNotFound; // Should not happen if resolveEnvironmentName was used
    const common_config = config.common;

    // Check target cluster if specified in the env_config
    var target_cluster_final: []const u8 = undefined; // Will be owned by ActiveConfig
    if (env_config.target) |target| {
        const current_cluster = try getClusterName(allocator);
        defer allocator.free(current_cluster);
        if (!mem.eql(u8, target, current_cluster)) {
            std.debug.print("Error: Environment '{s}' targets cluster '{s}', but you are on '{s}'.\n",
                           .{ env_name, target, current_cluster });
            std.debug.print("Please run this command on the correct cluster or update the target in your config.\n", .{});
            return ZenvError.ClusterNotFound;
        }
        target_cluster_final = try allocator.dupe(u8, target);
    } else {
        // No target specified, use current cluster name
        target_cluster_final = try getClusterName(allocator);
    }
    errdefer allocator.free(target_cluster_final); // Free if subsequent steps fail


    // Determine final python executable (env > common > default)
    var python_exec_final: []const u8 = undefined; // Will be owned by ActiveConfig
    if (env_config.python_executable) |py| {
        python_exec_final = try allocator.dupe(u8, py);
    } else if (common_config.python_executable) |py| {
        python_exec_final = try allocator.dupe(u8, py);
    } else {
        python_exec_final = try allocator.dupe(u8, "python3");
    }
    errdefer allocator.free(python_exec_final); // Free if subsequent steps fail


    // Initialize ActiveConfig, duplicating necessary fields from ZenvConfig
    var active_config = ActiveConfig{
        .allocator = allocator,
        .env_name = env_name, // Ownership transferred
        .target_cluster = target_cluster_final, // Ownership transferred
        .parent_envs_dir = try allocator.dupe(u8, common_config.parent_envs_dir),
        .requirements_file = try allocator.dupe(u8, common_config.requirements_file),
        .python_executable = python_exec_final, // Ownership transferred
        .modules_to_load = std.ArrayList([]const u8).init(allocator),
        .custom_setup_commands = std.ArrayList([]const u8).init(allocator),
        .custom_activate_vars = std.StringHashMap([]const u8).init(allocator),
        .dependencies = std.ArrayList([]const u8).init(allocator),
        .config_base_dir = try allocator.dupe(u8, config.config_base_dir),
    };

    // If anything below fails, ActiveConfig.deinit will be called by the caller's errdefer
    // It needs to handle partially populated fields.


    // Merge lists
    try mergeList(&active_config.modules_to_load, common_config.modules_to_load, env_config.modules_to_load, allocator);
    try mergeList(&active_config.custom_setup_commands, common_config.custom_setup_commands, env_config.custom_setup_commands, allocator);
    try mergeList(&active_config.dependencies, common_config.dependencies, env_config.dependencies, allocator);


    // Merge activate vars (env overrides common, requires copying keys and values)
    var common_iter = common_config.custom_activate_vars.iterator();
    while (common_iter.next()) |entry| {
        const key_dupe = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_dupe);
        const val_dupe = try allocator.dupe(u8, entry.value_ptr.*);
        errdefer allocator.free(val_dupe);
        try active_config.custom_activate_vars.put(key_dupe, val_dupe);
    }

    var env_iter = env_config.custom_activate_vars.iterator();
    while (env_iter.next()) |entry| {
        const key_dupe = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_dupe);
        const val_dupe = try allocator.dupe(u8, entry.value_ptr.*);
        errdefer allocator.free(val_dupe);

        // Check if the key already exists (from common_config)
        // If it does, free the old value before putting the new one.
        if (active_config.custom_activate_vars.getEntry(key_dupe)) |old_entry_ptr| {
            allocator.free(old_entry_ptr.value_ptr.*); // Free the previously allocated value
        }
        // Now put the new value (takes ownership of key_dupe, val_dupe)
        try active_config.custom_activate_vars.put(key_dupe, val_dupe);
    }

    return active_config; // Success! Ownership transferred
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


// Main function using the new structure
pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);
    // No need to free args items individually as argsAlloc uses the allocator

    if (args.len < 2 or mem.eql(u8, args[1], "help") or mem.eql(u8, args[1], "--help")) {
        printUsage();
        process.exit(0);
    }

    const command = args[1];
    const config_path = "zenv.json"; // Keep this fixed for now

    // Centralized error handler
    const handleError = struct {
        pub fn func(err: anyerror) void {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
            // Add more specific context based on the error type
            switch (@as(ZenvError, @errorCast(err))) {
                ZenvError.ConfigFileNotFound => stderr.print(" -> Configuration file '{s}' not found.\n", .{config_path}) catch {},
                ZenvError.ClusterNotFound => stderr.print(" -> Target cluster doesn't match current hostname or config target mismatch.\n", .{}) catch {},
                ZenvError.EnvironmentNotFound => stderr.print(" -> Environment not found or auto-detection failed. Check name or specify explicitly.\n", .{}) catch {},
                ZenvError.JsonParseError => stderr.print(" -> Invalid JSON format in '{s}'. Check syntax.\n", .{config_path}) catch {},
                ZenvError.ConfigInvalid => stderr.print(" -> Invalid configuration structure in '{s}'. Check keys/types.\n", .{config_path}) catch {},
                ZenvError.ProcessError => stderr.print(" -> An external command failed. See output above for details.\n", .{}) catch {},
                ZenvError.MissingHostname => stderr.print(" -> HOSTNAME environment variable not set or inaccessible. Needed for cluster detection.\n", .{}) catch {},
                ZenvError.PathResolutionFailed => stderr.print(" -> Failed to resolve a required file path.\n", .{}) catch {},
                else => { // Handle other potential errors like OutOfMemory, IoError
                    stderr.print(" -> Unexpected error details: {s}\n", .{@errorName(err)}) catch {};
                },
            }
            process.exit(1);
        }
    }.func;

    // Parse the configuration ONCE
    var config = ZenvConfig.parse(allocator, config_path) catch |err| {
        // Handle specific parsing errors early
         handleError(err);
         return; // Needed because handleError exits
    };
    defer config.deinit(); // Ensure config is cleaned up


    // --- Command Dispatch ---
    if (mem.eql(u8, command, "setup")) {
        const resolved_env_name = resolveEnvironmentName(allocator, &config, args, "setup") catch |err| {
             handleError(err); return;
        };
        // createActiveConfig takes ownership of resolved_env_name on success
        var active_config = createActiveConfig(allocator, &config, resolved_env_name) catch |err| {
             handleError(err); return;
        };
        defer active_config.deinit(); // Deinit active config when setup scope ends

        doSetup(allocator, &active_config) catch |err| {
            handleError(err); return;
        };

    } else if (mem.eql(u8, command, "activate")) {
         const resolved_env_name = resolveEnvironmentName(allocator, &config, args, "activate") catch |err| {
             handleError(err); return;
        };
        // createActiveConfig takes ownership of resolved_env_name on success
        var active_config = createActiveConfig(allocator, &config, resolved_env_name) catch |err| {
             handleError(err); return;
        };
        defer active_config.deinit(); // Deinit active config when activate scope ends

        doActivate(allocator, &active_config) catch |err| {
            handleError(err); return;
        };

    } else if (mem.eql(u8, command, "list")) {
        const show_all = args.len >= 3 and mem.eql(u8, args[2], "--all");
        if (show_all) {
            // Pass the parsed config to the list function
            doListConfiguredEnvs(allocator, &config) catch |err| {
                handleError(err); return;
            };
        } else {
            // Pass the parsed config to the list function
            doListExistingEnvs(allocator, &config) catch |err| {
                handleError(err); return;
            };
        }
    } else {
        std.io.getStdErr().writer().print("Error: Unknown command '{s}'\n\n", .{command}) catch {};
        printUsage();
        process.exit(1);
    }
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
        // Output to stdout so it can be captured by `eval $(zenv activate ...)` or similar
        const out_writer = std.io.getStdOut().writer();
        try out_writer.print("source {s}\n", .{activate_sh_path});
    } else {
        try err_writer.print("No activation script found for environment '{s}'\n", .{config.env_name});
        try err_writer.print("Run 'zenv setup {s}' first to create the virtual environment\n", .{config.env_name});
        return ZenvError.ConfigInvalid; // Use an existing error, or maybe a new one like ActivationScriptNotFound
    }
}


// Define a struct type for environment info
const EnvInfo = struct {
    name: []const u8,
    target: ?[]const u8,
    matches_current: bool,
};

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

    // Check if we have any dependencies in the config
    if (req_file_exists or config.dependencies.items.len > 0) {
        if (config.dependencies.items.len > 0) {
            std.debug.print("Found {d} dependencies in config, creating all_dependencies.txt\n", .{config.dependencies.items.len});

            // Create a combined dependencies file in the venv directory
            const all_deps_path = try fs.path.join(allocator, &[_][]const u8{ venv_path_abs, "all_dependencies.txt" });
            defer allocator.free(all_deps_path);

            var deps_file = try fs.cwd().createFile(all_deps_path, .{});
            defer deps_file.close();

            // First add contents from requirements.txt if it exists
            if (req_file_exists) {
                const req_content: ?[]const u8 = blk: {
                    break :blk fs.cwd().readFileAlloc(allocator, req_path_abs, 1 * 1024 * 1024) catch |err| {
                        std.debug.print("Warning: Could not read requirements file: {s}\n", .{@errorName(err)});
                        break :blk null; // Return null from block on error
                    };
                };
                // Check if block returned content or null
                if (req_content) |content| {
                    // Free the content when done (whether block completed or not)
                    // Using errdefer might be safer if subsequent writes fail
                    defer allocator.free(content);
                    try deps_file.writeAll(content);
                    try deps_file.writeAll("\n");
                }
            }

            // Then add dependencies from config
            for (config.dependencies.items) |dep| {
                try deps_file.writeAll(dep);
                try deps_file.writeAll("\n");
            }

            std.debug.print("Installing dependencies from: {s}\n", .{all_deps_path});
            const pip_args = [_][]const u8{ pip_path, "install", "-r", all_deps_path };
            try runCommand(allocator, &pip_args, null);
            std.debug.print("Dependencies installed.\n", .{});
        } else {
            std.debug.print("Installing requirements from: {s}\n", .{req_path_abs});
            const pip_args = [_][]const u8{ pip_path, "install", "-r", req_path_abs };
            try runCommand(allocator, &pip_args, null);
            std.debug.print("Requirements installed.\n", .{});
        }
    } else {
        std.debug.print("Requirements file '{s}' not found and no dependencies in config, skipping pip install.\n", .{req_path_abs});
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

    if (config.dependencies.items.len > 0) {
        try activate_content.appendSlice("# This environment includes dependencies from zenv.json\n");
        try activate_content.appendSlice("# Dependencies list: \n");
        for (config.dependencies.items) |dep| {
            try activate_content.appendSlice("#   - ");
            try activate_content.appendSlice(dep);
            try activate_content.appendSlice("\n");
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


// --- Need to update doListConfiguredEnvs and doListExistingEnvs ---
// --- to accept *const ZenvConfig instead of config_path      ---

// Updated function signature and logic for doListConfiguredEnvs
fn doListConfiguredEnvs(allocator: Allocator, config: *const ZenvConfig) !void {
    // Get the current hostname-based cluster for highlighting matching environments
    const current_cluster = getClusterName(allocator) catch |err| {
        std.debug.print("Warning: Could not get cluster name for list comparison: {s}. Assuming no matches.\n", .{@errorName(err)});
        // Proceed without highlighting if getting cluster name fails
        if (err == ZenvError.MissingHostname) return error.MissingHostname; // Propagate critical error
         return err; // Propagate other errors
    };
    defer allocator.free(current_cluster);

    // Collect EnvInfo from the parsed config
    var envs = std.ArrayList(EnvInfo).init(allocator);
    defer { // Deinit EnvInfo list - only free target if it was allocated (duped)
        for (envs.items) |item| {
            if (item.target) |target| allocator.free(target); // Free the duplicated target string
        }
        envs.deinit();
    }

    var env_iter = config.environments.iterator();
    while (env_iter.next()) |entry| {
        const env_name = entry.key_ptr.*; // Slice owned by config
        const env_cfg = entry.value_ptr.*; // Pointer to EnvironmentConfig owned by config

        var target_dupe: ?[]const u8 = null;
        var matches_current = false;

        if (env_cfg.target) |target| {
            target_dupe = try allocator.dupe(u8, target); // Need to dupe for EnvInfo ownership
            matches_current = mem.eql(u8, target, current_cluster);
        }

        try envs.append(.{
            .name = env_name, // Name is still just a slice pointing to config data
            .target = target_dupe, // Takes ownership of the duplicated string
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
    try stdout.print("\nAvailable environments in {s}:\n\n", .{config.config_base_dir}); // Use config_base_dir maybe? Or just "zenv.json"?

    // Count environments that match the current cluster
    var matching_count: usize = 0;
    for (envs.items) |item| {
        if (item.matches_current) matching_count += 1;
    }

    if (envs.items.len == 0) {
        try stdout.print("No environments found in configuration.\n", .{});
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

    try stdout.print("\nTotal: {d} environment(s) defined in config.\n", .{envs.items.len});
    if (matching_count > 0) {
        try stdout.print("Found {d} environment(s) matching your current cluster '{s}'\n", .{matching_count, current_cluster});
    } else {
        try stdout.print("No environments explicitly target your current cluster '{s}'\n", .{current_cluster});
    }
}


// Updated function signature and logic for doListExistingEnvs
fn doListExistingEnvs(allocator: Allocator, config: *const ZenvConfig) !void {
    // Get parent_envs_dir relative to config file location
    const parent_envs_dir_rel = config.common.parent_envs_dir;
    const config_base_dir = config.config_base_dir;

    // Construct the potentially relative path
    const parent_dir_maybe_rel = try fs.path.join(allocator, &[_][]const u8{ config_base_dir, parent_envs_dir_rel });
    defer allocator.free(parent_dir_maybe_rel);

    // Resolve to an absolute path using the current working directory
    const parent_dir_abs = try fs.cwd().realpathAlloc(allocator, parent_dir_maybe_rel);
    defer allocator.free(parent_dir_abs);

    std.debug.print("Looking for existing environments in absolute path: {s}\n", .{parent_dir_abs});

    // Now list all directories in the guaranteed absolute parent_dir_abs
    var dir = fs.openDirAbsolute(parent_dir_abs, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.PathNotFound) {
             std.io.getStdOut().writer().print(
                \\Environment directory '{s}' does not exist or is not accessible.
                \\No existing environments found. Run 'zenv setup [env_name]' first.
            , .{parent_dir_abs}) catch {};
            // Return gracefully, not an application error state
            return;
        }
        std.debug.print("Error opening directory '{s}': {s}\n", .{parent_dir_abs, @errorName(err)});
        return ZenvError.IoError; // Propagate other FS errors
    };
    defer dir.close();

    // Get list of all directories and check if they have an activate.sh script
    var env_dirs = std.ArrayList([]const u8).init(allocator);
    defer { // Free duplicated directory names
        for (env_dirs.items) |item| {
            allocator.free(item);
        }
        env_dirs.deinit();
    }

    var iter = dir.iterate();
    while (iter.next() catch |err| {
        std.debug.print("Error reading directory '{s}': {s}\n", .{parent_dir_abs, @errorName(err)});
        // Continue if possible, maybe log and skip entry? For now, return error.
        return ZenvError.IoError;
    }) |entry| {
        if (entry.kind == .directory) {
            // Check if this directory looks like a zenv environment (has activate.sh)
            const env_path = try fs.path.join(allocator, &[_][]const u8{parent_dir_abs, entry.name});
            defer allocator.free(env_path);

            const activate_path = try fs.path.join(allocator, &[_][]const u8{env_path, "activate.sh"});
            defer allocator.free(activate_path);

            // Use access to check existence and readability
            const access_result = fs.cwd().access(activate_path, .{}) catch null;
            if (access_result != null) {
                // Found a valid environment, add its name (duplicated)
                try env_dirs.append(try allocator.dupe(u8, entry.name));
            } else {
                 std.debug.print("Directory '{s}' found, but missing '{s}'. Skipping.\n", .{entry.name, "activate.sh"});
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
    try stdout.print("\nExisting environments found in {s}:\n\n", .{parent_dir_abs});

    if (env_dirs.items.len == 0) {
        try stdout.print("No existing environments found. Run 'zenv setup [env_name]' first.\n", .{});
    } else {
        for (env_dirs.items) |name| {
            try stdout.print("- {s}\n", .{name});
        }
        try stdout.print("\nTotal: {d} existing environment(s)\n", .{env_dirs.items.len});
    }

    // Optional: Hint to list all configured envs
     try stdout.print("\nUse 'zenv list --all' to see all environments defined in the configuration.\n", .{});
}

// --- Remove old loadAndMergeConfig and findMatchingEnvs ---
// The functionality is now covered by ZenvConfig.parse, resolveEnvironmentName, and createActiveConfig
