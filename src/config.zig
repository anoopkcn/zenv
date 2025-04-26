const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;

const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const env_utils = @import("env_utils.zig");

pub const ActiveConfig = struct {
    allocator: Allocator,
    env_name: []const u8,
    target_cluster: []const u8,
    parent_envs_dir: []const u8,
    requirements_file: []const u8,
    python_executable: []const u8,
    modules_to_load: ArrayList([]const u8),
    custom_setup_commands: ArrayList([]const u8),
    custom_activate_vars: StringHashMap([]const u8),
    dependencies: ArrayList([]const u8),
    config_base_dir: []const u8, // Directory where zenv.json lives

    fn deinitStringList(self: *ActiveConfig, list: *ArrayList([]const u8)) void {
        for (list.items) |item| {
            self.allocator.free(item);
        }
        list.deinit();
    }

    fn deinitStringMap(self: *ActiveConfig, map: *StringHashMap([]const u8)) void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    pub fn deinit(self: *ActiveConfig) void {
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

// Represents a single environment's config within zenv.json (excluding "common")
pub const EnvironmentConfig = struct {
    target: ?[]const u8 = null,
    python_executable: ?[]const u8 = null,
    modules_to_load: ArrayListUnmanaged([]const u8) = .{},
    custom_setup_commands: ArrayListUnmanaged([]const u8) = .{},
    custom_activate_vars: StringHashMapUnmanaged([]const u8) = .{},
    dependencies: ArrayListUnmanaged([]const u8) = .{},

    // Note: Using Unmanaged collections here because ZenvConfig owns the allocator
    // and manages deinitialization centrally.
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

// Represents the "common" section of zenv.json
pub const CommonConfig = struct {
    parent_envs_dir: []const u8,
    requirements_file: []const u8,
    python_executable: ?[]const u8 = null,
    modules_to_load: ArrayListUnmanaged([]const u8) = .{},
    custom_setup_commands: ArrayListUnmanaged([]const u8) = .{},
    custom_activate_vars: StringHashMapUnmanaged([]const u8) = .{},
    dependencies: ArrayListUnmanaged([]const u8) = .{},

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
pub const ZenvConfig = struct {
    allocator: Allocator,
    config_base_dir: []const u8,
    common: CommonConfig,
    environments: StringHashMapUnmanaged(EnvironmentConfig), // key = env_name

    // Helper function to parse a string array from JSON, allocating copies
    fn parseStringArray(
        alloc: Allocator,
        json_val: json.Value,
    ) ZenvError!ArrayListUnmanaged([]const u8) {
        if (json_val != .array) return ZenvError.ConfigInvalid;
        var list = ArrayListUnmanaged([]const u8){};
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
    ) ZenvError!StringHashMapUnmanaged([]const u8) {
        if (json_val != .object) return ZenvError.ConfigInvalid;
        var map = StringHashMapUnmanaged([]const u8){};
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
            std.log.err("Failed to read config file '{s}': {s}", .{ config_path, @errorName(err) });
            if (err == error.FileNotFound) return ZenvError.ConfigFileNotFound;
            return ZenvError.ConfigFileReadError;
        };
        defer allocator.free(config_content);

        const tree = json.parseFromSlice(json.Value, allocator, config_content, .{}) catch |err| {
            std.log.err("Failed to parse JSON in '{s}': {s}", .{ config_path, @errorName(err) });
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
        // If environment parsing fails, ensure common_config is cleaned up
        errdefer common_config.deinit(allocator);

        // Parse environments
        var environments_map = StringHashMapUnmanaged(EnvironmentConfig){};
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
                std.log.warn("Skipping non-object entry '{s}' in config root.", .{env_name});
                continue;
            }
            const env_obj = env_val.object;

            // Create the EnvironmentConfig for this entry
            var env_config = EnvironmentConfig{
                 .target = if (env_obj.get("target")) |v| try parseOptionalString(allocator, v) else null,
                 .python_executable = if (env_obj.get("python_executable")) |v| try parseOptionalString(allocator, v) else null,
                 .modules_to_load = if (env_obj.get("modules_to_load")) |v| try parseStringArray(allocator, v) else .{},
                 .custom_setup_commands = if (env_obj.get("custom_setup_commands")) |v| try parseStringArray(allocator, v) else .{},
                 .custom_activate_vars = if (env_obj.get("custom_activate_vars")) |v| try parseStringMap(allocator, v) else .{},
                 .dependencies = if (env_obj.get("dependencies")) |v| try parseStringArray(allocator, v) else .{},
            };
            // Deinit this specific env_config if putting it into the map fails
            errdefer env_config.deinit(allocator);

            const map_key = try allocator.dupe(u8, env_name);
            // If put fails, free the key we just allocated
            errdefer allocator.free(map_key);

            try environments_map.putNoClobber(allocator, map_key, env_config);
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

// --- Config Merging Logic ---

// Helper to merge two lists of strings into a destination list,
// allocating copies of the strings.
fn mergeList(
    dest: *ArrayList([]const u8),
    list1: ArrayListUnmanaged([]const u8),
    list2: ArrayListUnmanaged([]const u8),
    alloc: Allocator,
) ZenvError!void {
     try dest.ensureTotalCapacity(list1.items.len + list2.items.len); // Use list's allocator implicitly
     for (list1.items) |item| try dest.append(try alloc.dupe(u8, item));
     for (list2.items) |item| try dest.append(try alloc.dupe(u8, item));
}

// Creates the ActiveConfig by merging common and environment-specific settings
// Takes ownership of env_name if successful, frees it on error.
pub fn createActiveConfig(
    allocator: Allocator,
    config: *const ZenvConfig,
    env_name: []const u8, // Takes ownership on success
) ZenvError!ActiveConfig {
    // Ensure env_name is freed if any subsequent operation fails
    errdefer allocator.free(env_name);

    const env_config = config.environments.get(env_name) orelse return ZenvError.EnvironmentNotFound;
    const common_config = config.common;

    // Check target cluster if specified in the env_config
    var target_cluster_final: []const u8 = undefined;
    // errdefer if (@ptrToInt(target_cluster_final) != @ptrToInt(undefined)) allocator.free(target_cluster_final); // REMOVED
    if (env_config.target) |target| {
        const current_cluster = try env_utils.getClusterName(allocator);
        defer allocator.free(current_cluster);
        if (!mem.eql(u8, target, current_cluster)) {
            std.log.err("Environment '{s}' targets cluster '{s}', but you are on '{s}'.",
                       .{ env_name, target, current_cluster });
            return ZenvError.ClusterNotFound;
        }
        target_cluster_final = try allocator.dupe(u8, target);
    } else {
        // No target specified, use current cluster name
        target_cluster_final = try env_utils.getClusterName(allocator);
    }

    // Determine final python executable (env > common > default)
    var python_exec_final: []const u8 = undefined;
    // errdefer if (@ptrToInt(python_exec_final) != @ptrToInt(undefined)) allocator.free(python_exec_final); // REMOVED
    if (env_config.python_executable) |py| {
        python_exec_final = try allocator.dupe(u8, py);
    } else if (common_config.python_executable) |py| {
        python_exec_final = try allocator.dupe(u8, py);
    } else {
        // Default to "python3"
        python_exec_final = try allocator.dupe(u8, "python3");
    }

    // Initialize ActiveConfig, duplicating necessary fields from ZenvConfig
    // Use errdefer to ensure ActiveConfig is deinitialized if subsequent merges fail
    var active_config = ActiveConfig{
        .allocator = allocator,
        .env_name = env_name, // Ownership transferred here
        .target_cluster = target_cluster_final, // Ownership transferred here
        .parent_envs_dir = try allocator.dupe(u8, common_config.parent_envs_dir),
        .requirements_file = try allocator.dupe(u8, common_config.requirements_file),
        .python_executable = python_exec_final, // Ownership transferred here
        .modules_to_load = ArrayList([]const u8).init(allocator),
        .custom_setup_commands = ArrayList([]const u8).init(allocator),
        .custom_activate_vars = StringHashMap([]const u8).init(allocator),
        .dependencies = ArrayList([]const u8).init(allocator),
        .config_base_dir = try allocator.dupe(u8, config.config_base_dir),
    };
    errdefer active_config.deinit();

    // Merge lists (errors handled by the main errdefer)
    try mergeList(&active_config.modules_to_load, common_config.modules_to_load, env_config.modules_to_load, allocator);
    try mergeList(&active_config.custom_setup_commands, common_config.custom_setup_commands, env_config.custom_setup_commands, allocator);
    try mergeList(&active_config.dependencies, common_config.dependencies, env_config.dependencies, allocator);

    // Merge activate vars (env overrides common)
    var common_iter = common_config.custom_activate_vars.iterator();
    while (common_iter.next()) |entry| {
        try active_config.custom_activate_vars.putNoClobber(
            try allocator.dupe(u8, entry.key_ptr.*),
            try allocator.dupe(u8, entry.value_ptr.*)
        );
    }

    var env_iter = env_config.custom_activate_vars.iterator();
    while (env_iter.next()) |entry| {
        try active_config.custom_activate_vars.put(
            try allocator.dupe(u8, entry.key_ptr.*),
            try allocator.dupe(u8, entry.value_ptr.*)
        );
    }

    return active_config;
}
