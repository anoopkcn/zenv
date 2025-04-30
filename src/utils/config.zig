const std = @import("std");
const Allocator = std.mem.Allocator;
const Json = std.json;
const fs = std.fs;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const environment = @import("environment.zig");

fn generateSHA1ID(allocator: Allocator, env_name: []const u8, project_dir: []const u8, target_machines_str: []const u8) ![]const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(env_name);
    sha1.update(project_dir);
    sha1.update(target_machines_str);
    var timestamp_buf: [20]u8 = undefined;
    const timestamp_str = try std.fmt.bufPrint(&timestamp_buf, "{d}", .{std.time.milliTimestamp()});
    sha1.update(timestamp_str);
    var hash: [20]u8 = undefined;
    sha1.final(&hash);
    var hex_buf: [40]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 15];
    }
    return try allocator.dupe(u8, &hex_buf);
}

// =======================
// Config Structs
// =======================

pub const EnvironmentConfig = struct {
    target_machines: ArrayList([]const u8),
    description: ?[]const u8 = null,
    modules: ArrayList([]const u8),
    requirements_file: ?[]const u8 = null,
    dependencies: ArrayList([]const u8),
    python_executable: []const u8,
    custom_activate_vars: StringHashMap([]const u8),
    setup_commands: ?ArrayList([]const u8) = null,

    pub fn init(allocator: Allocator) EnvironmentConfig {
        return .{
            .target_machines = ArrayList([]const u8).init(allocator),
            .modules = ArrayList([]const u8).init(allocator),
            .dependencies = ArrayList([]const u8).init(allocator),
            .custom_activate_vars = StringHashMap([]const u8).init(allocator),
            .description = null,
            .requirements_file = null,
            .setup_commands = null,
            .python_executable = undefined,
        };
    }

    pub fn deinit(self: *EnvironmentConfig) void {
        self.target_machines.deinit();
        self.modules.deinit();
        self.dependencies.deinit();
        self.custom_activate_vars.deinit();
        if (self.setup_commands) |*cmds| cmds.deinit();
    }
};

pub const ZenvConfig = struct {
    allocator: Allocator,
    environments: StringHashMap(EnvironmentConfig),
    value_tree: Json.Parsed(Json.Value),
    base_dir: []const u8,
    cached_hostname: ?[]const u8 = null,

    pub fn deinit(self: *ZenvConfig) void {
        var iter = self.environments.iterator();
        while (iter.next()) |entry| entry.value_ptr.deinit();
        self.environments.deinit();
        self.value_tree.deinit();
        self.allocator.free(self.base_dir);
        if (self.cached_hostname) |h| self.allocator.free(h);
    }

    pub fn getEnvironment(self: *const ZenvConfig, env_name: []const u8) ?*const EnvironmentConfig {
        return self.environments.getPtr(env_name);
    }

    pub fn validateEnvironment(env_config: *const EnvironmentConfig, env_name: []const u8) ?ZenvError {
        _ = env_name;
        if (env_config.target_machines.items.len == 0) return ZenvError.ConfigInvalid;
        if (env_config.python_executable.len == 0) return ZenvError.MissingPythonExecutable;
        return null;
    }

    pub fn getHostname(self: *const ZenvConfig) ![]const u8 {
        if (self.cached_hostname) |cached| {
            return try self.allocator.dupe(u8, cached);
        }
        var mutable_self = @constCast(self);
        const hostname = environment.getSystemHostname(mutable_self.allocator) catch |err| {
            return errors.logAndReturn(err, "Failed to get system hostname: {s}", .{@errorName(err)});
        };
        errdefer mutable_self.allocator.free(hostname);
        mutable_self.cached_hostname = try mutable_self.allocator.dupe(u8, hostname);
        return hostname;
    }
};

// =======================
// Parsing Helpers
// =======================

const Parse = struct {
    fn requiredString(allocator: Allocator, v: *const Json.Value) ![]const u8 {
        if (v.* != .string) return error.ConfigInvalid;
        return try allocator.dupe(u8, v.string);
    }

    fn optionalString(allocator: Allocator, v: *const Json.Value) !?[]const u8 {
        return if (v.* == .null) null else if (v.* == .string) try allocator.dupe(u8, v.string) else error.ConfigInvalid;
    }
    fn stringArray(allocator: Allocator, arr: *ArrayList([]const u8), v: *const Json.Value) !void {
        if (v.* != .array) return error.ConfigInvalid;
        try arr.ensureTotalCapacity(v.array.items.len);
        for (v.array.items) |item| {
            if (item != .string) return error.ConfigInvalid;
            try arr.append(try allocator.dupe(u8, item.string));
        }
    }
    fn stringHashMap(allocator: Allocator, map: *StringHashMap([]const u8), v: *const Json.Value) !void {
        if (v.* != .object) return error.ConfigInvalid;
        var it = v.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            try map.put(entry.key_ptr.*, try allocator.dupe(u8, entry.value_ptr.string));
        }
    }
    fn optionalStringArray(allocator: Allocator, v: *const Json.Value) !?ArrayList([]const u8) {
        if (v.* == .null) return null;
        if (v.* != .array) return error.ConfigInvalid;
        var arr = ArrayList([]const u8).init(allocator);
        for (v.array.items) |item| {
            if (item != .string) continue;
            try arr.append(try allocator.dupe(u8, item.string));
        }
        return arr;
    }
};

// =======================
// Main Parse Function
// =======================

pub fn parse(allocator: Allocator, config_path: []const u8) !ZenvConfig {
    const file = try fs.cwd().openFile(config_path, .{});
    defer file.close();
    const json_string = try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(json_string);

    const value_tree = try std.json.parseFromSlice(Json.Value, allocator, json_string, .{});
    const root = value_tree.value;
    if (root != .object) return error.ConfigInvalid;

    var config = ZenvConfig{
        .allocator = allocator,
        .environments = StringHashMap(EnvironmentConfig).init(allocator),
        .value_tree = value_tree,
        .base_dir = undefined,
    };
    errdefer config.deinit();

    // Parse base_dir
    config.base_dir = if (root.object.get("base_dir")) |v|
        if (v == .string) try allocator.dupe(u8, v.string) else try allocator.dupe(u8, "zenv")
    else
        try allocator.dupe(u8, "zenv");

    // Parse environments
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const env_name = entry.key_ptr.*;
        const v = entry.value_ptr;
        if (std.mem.eql(u8, env_name, "base_dir")) continue;
        if (v.* != .object) continue;

        var env = EnvironmentConfig.init(allocator);
        errdefer env.deinit();

        // Required: target_machines (array or string)
        if (v.object.get("target_machines")) |tm_val| {
            if (tm_val == .string) {
                try env.target_machines.append(try allocator.dupe(u8, tm_val.string));
            } else {
                try Parse.stringArray(allocator, &env.target_machines, &tm_val);
            }
        } else return error.ConfigInvalid;

        // Required: python_executable
        env.python_executable = try Parse.requiredString(allocator, &(v.object.get("python_executable") orelse return error.ConfigInvalid));

        // Optional fields
        if (v.object.get("description")) |desc| env.description = try Parse.optionalString(allocator, &desc);
        if (v.object.get("modules")) |mods| try Parse.stringArray(allocator, &env.modules, &mods);
        if (v.object.get("requirements_file")) |req| env.requirements_file = try Parse.optionalString(allocator, &req);
        if (v.object.get("dependencies")) |deps| try Parse.stringArray(allocator, &env.dependencies, &deps);
        if (v.object.get("custom_activate_vars")) |vars| try Parse.stringHashMap(allocator, &env.custom_activate_vars, &vars);
        if (v.object.get("setup_commands")) |cmds| env.setup_commands = try Parse.optionalStringArray(allocator, &cmds);

        try config.environments.put(env_name, env);
    }

    if (config.environments.count() == 0) return error.ConfigInvalid;
    return config;
}

// =======================
// RegistryEntry & Registry
// =======================

pub const RegistryEntry = struct {
    id: []const u8, // SHA-1 unique identifier
    env_name: []const u8,
    project_dir: []const u8,
    description: ?[]const u8 = null,
    target_machines_str: []const u8,
    venv_path: []const u8,

    pub fn deinit(self: *RegistryEntry, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.env_name);
        allocator.free(self.project_dir);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.target_machines_str);
        allocator.free(self.venv_path);
    }
};

pub const EnvironmentRegistry = struct {
    allocator: Allocator,
    entries: std.ArrayList(RegistryEntry),

    pub fn init(allocator: Allocator) EnvironmentRegistry {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(RegistryEntry).init(allocator),
        };
    }

    pub fn deinit(self: *EnvironmentRegistry) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit();
    }

    pub fn load(allocator: Allocator) !EnvironmentRegistry {
        var registry = EnvironmentRegistry.init(allocator);
        errdefer registry.deinit();

        const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
            std.log.err("Failed to get HOME environment variable: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(home_dir);

        const zenv_dir_path = try std.fmt.allocPrint(allocator, "{s}/.zenv", .{home_dir});
        defer allocator.free(zenv_dir_path);

        std.fs.makeDirAbsolute(zenv_dir_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.log.err("Failed to create .zenv directory: {s}", .{@errorName(err)});
                return err;
            }
        };

        const registry_path = try std.fmt.allocPrint(allocator, "{s}/registry.json", .{zenv_dir_path});
        defer allocator.free(registry_path);

        const file = std.fs.openFileAbsolute(registry_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try registry.save();
                return registry;
            }
            std.log.err("Failed to open registry file: {s}", .{@errorName(err)});
            return err;
        };
        defer file.close();

        const file_content = file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read registry file: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(file_content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, file_content, .{}) catch |err| {
            std.log.err("Failed to parse registry JSON: {s}", .{@errorName(err)});
            return err;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root.object.get("environments")) |environments| {
            if (environments != .array) return error.InvalidRegistryFormat;
            for (environments.array.items) |entry_value| {
                if (entry_value != .object) continue;
                const entry_obj = entry_value.object;
                const env_name = entry_obj.get("name") orelse continue;
                if (env_name != .string) continue;
                const project_dir = entry_obj.get("project_dir") orelse continue;
                if (project_dir != .string) continue;
                const target_machines_str = entry_obj.get("target_machine") orelse continue;
                if (target_machines_str != .string) continue;
                var description: ?[]const u8 = null;
                if (entry_obj.get("description")) |desc_value| {
                    if (desc_value == .string) description = try allocator.dupe(u8, desc_value.string);
                }
                var id_owned: []const u8 = undefined;
                if (entry_obj.get("id")) |id_value| {
                    if (id_value == .string) {
                        id_owned = try allocator.dupe(u8, id_value.string);
                    } else {
                        id_owned = try generateSHA1ID(allocator, env_name.string, project_dir.string, target_machines_str.string);
                    }
                } else {
                    id_owned = try generateSHA1ID(allocator, env_name.string, project_dir.string, target_machines_str.string);
                }
                errdefer allocator.free(id_owned);
                var venv_path_owned: []const u8 = undefined;
                var venv_path_found_or_reconstructed = false;
                if (entry_obj.get("venv_path")) |venv_path_val| {
                    if (venv_path_val == .string) {
                        venv_path_owned = try allocator.dupe(u8, venv_path_val.string);
                        venv_path_found_or_reconstructed = true;
                    }
                }
                if (!venv_path_found_or_reconstructed) {
                    venv_path_owned = std.fs.path.join(allocator, &[_][]const u8{
                        project_dir.string, "zenv", env_name.string,
                    }) catch continue;
                }
                errdefer allocator.free(venv_path_owned);
                try registry.entries.append(.{
                    .id = id_owned,
                    .env_name = try allocator.dupe(u8, env_name.string),
                    .project_dir = try allocator.dupe(u8, project_dir.string),
                    .description = description,
                    .target_machines_str = try allocator.dupe(u8, target_machines_str.string),
                    .venv_path = venv_path_owned,
                });
            }
        }
        return registry;
    }

    pub fn save(self: *const EnvironmentRegistry) !void {
        const home_dir = std.process.getEnvVarOwned(self.allocator, "HOME") catch |err| {
            std.log.err("Failed to get HOME environment variable: {s}", .{@errorName(err)});
            return err;
        };
        defer self.allocator.free(home_dir);

        const zenv_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/.zenv", .{home_dir});
        defer self.allocator.free(zenv_dir_path);

        std.fs.makeDirAbsolute(zenv_dir_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.log.err("Failed to create .zenv directory: {s}", .{@errorName(err)});
                return err;
            }
        };

        const registry_path = try std.fmt.allocPrint(self.allocator, "{s}/registry.json", .{zenv_dir_path});
        defer self.allocator.free(registry_path);

        var root = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer root.object.deinit();

        var environments = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer environments.array.deinit();

        for (self.entries.items) |entry| {
            var entry_obj = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
            try entry_obj.object.put("id", std.json.Value{ .string = entry.id });
            try entry_obj.object.put("name", std.json.Value{ .string = entry.env_name });
            try entry_obj.object.put("project_dir", std.json.Value{ .string = entry.project_dir });
            try entry_obj.object.put("target_machine", std.json.Value{ .string = entry.target_machines_str });
            try entry_obj.object.put("venv_path", std.json.Value{ .string = entry.venv_path });
            if (entry.description) |desc| {
                try entry_obj.object.put("description", std.json.Value{ .string = desc });
            }
            try environments.array.append(entry_obj);
        }
        try root.object.put("environments", environments);

        const json_string = try std.json.stringifyAlloc(self.allocator, root, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_string);

        const file = try std.fs.createFileAbsolute(registry_path, .{});
        defer file.close();
        try file.writeAll(json_string);
    }

    pub fn register(self: *EnvironmentRegistry, env_name: []const u8, project_dir: []const u8, base_dir: []const u8, description: ?[]const u8, target_machines: []const []const u8) !void {
        var registry_target_machines_str: []const u8 = undefined;
        if (target_machines.len == 0) {
            registry_target_machines_str = try self.allocator.dupe(u8, "any");
        } else if (target_machines.len == 1) {
            registry_target_machines_str = try self.allocator.dupe(u8, target_machines[0]);
        } else {
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();
            for (target_machines, 0..) |machine, i| {
                if (i > 0) try buffer.appendSlice(", ");
                try buffer.appendSlice(machine);
            }
            registry_target_machines_str = try self.allocator.dupe(u8, buffer.items);
        }
        errdefer self.allocator.free(registry_target_machines_str);

        var venv_path: []const u8 = undefined;
        if (std.fs.path.isAbsolute(base_dir)) {
            venv_path = try std.fs.path.join(self.allocator, &[_][]const u8{ base_dir, env_name });
        } else {
            venv_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_dir, base_dir, env_name });
        }
        errdefer self.allocator.free(venv_path);

        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.env_name, env_name)) {
                self.allocator.free(entry.project_dir);
                entry.project_dir = try self.allocator.dupe(u8, project_dir);
                if (entry.description) |desc| self.allocator.free(desc);
                entry.description = if (description) |desc| try self.allocator.dupe(u8, desc) else null;
                self.allocator.free(entry.target_machines_str);
                entry.target_machines_str = registry_target_machines_str;
                self.allocator.free(entry.venv_path);
                entry.venv_path = venv_path;
                return;
            }
        }
        const id = try generateSHA1ID(self.allocator, env_name, project_dir, registry_target_machines_str);
        errdefer self.allocator.free(id);
        try self.entries.append(.{
            .id = id,
            .env_name = try self.allocator.dupe(u8, env_name),
            .project_dir = try self.allocator.dupe(u8, project_dir),
            .description = if (description) |desc| try self.allocator.dupe(u8, desc) else null,
            .target_machines_str = registry_target_machines_str,
            .venv_path = venv_path,
        });
    }

    pub fn deregister(self: *EnvironmentRegistry, identifier: []const u8) bool {
        if (self.lookup(identifier)) |entry| {
            for (self.entries.items, 0..) |reg_entry, i| {
                if (std.mem.eql(u8, reg_entry.env_name, entry.env_name)) {
                    var removed_entry = self.entries.orderedRemove(i);
                    removed_entry.deinit(self.allocator);
                    return true;
                }
            }
        }
        return false;
    }

    pub fn lookup(self: *const EnvironmentRegistry, identifier: []const u8) ?RegistryEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.env_name, identifier) or std.mem.eql(u8, entry.id, identifier)) {
                return entry;
            }
        }
        if (identifier.len >= 7) {
            var matching_entry: ?RegistryEntry = null;
            var match_count: usize = 0;
            for (self.entries.items) |entry| {
                if (entry.id.len >= identifier.len and std.mem.eql(u8, entry.id[0..identifier.len], identifier)) {
                    matching_entry = entry;
                    match_count += 1;
                }
            }
            if (match_count == 1) return matching_entry;
        }
        return null;
    }
};
