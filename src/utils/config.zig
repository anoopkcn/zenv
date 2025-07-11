const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const environment = @import("environment.zig");
const mem = std.mem;
const json = std.json;
const paths = @import("paths.zig");
const output = @import("output.zig");

fn generateSHA1ID(
    allocator: Allocator,
    env_name: []const u8,
    project_dir: []const u8,
    target_machines_str: []const u8,
) ![]const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(env_name);
    sha1.update(project_dir);
    sha1.update(target_machines_str);

    // Use ArenaAllocator for temporary allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const timestamp_str = try std.fmt.allocPrint(arena.allocator(), "{d}", .{std.time.milliTimestamp()});
    sha1.update(timestamp_str);

    var hash: [20]u8 = undefined;
    sha1.final(&hash);

    // Efficient hex conversion
    return try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash)});
}

// =======================
// Config Structs
// =======================

pub const ScriptConfig = struct {
    commands: ?ArrayList([]const u8) = null,
    script: ?[]const u8 = null,

    pub fn init() ScriptConfig {
        return .{
            .commands = null,
            .script = null,
        };
    }

    pub fn deinit(self: *ScriptConfig, allocator: Allocator) void {
        if (self.commands) |*cmds| {
            for (cmds.items) |item| allocator.free(item);
            cmds.deinit();
        }
        if (self.script) |script_path| allocator.free(script_path);
    }
};

pub const EnvironmentConfig = struct {
    target_machines: ArrayList([]const u8),
    description: ?[]const u8 = null,
    modules: ArrayList([]const u8),
    modules_file: ?[]const u8 = null,
    dependency_file: ?[]const u8 = null,
    dependencies: ArrayList([]const u8),
    fallback_python: ?[]const u8 = null,
    setup: ?ScriptConfig = null,
    activate: ?ScriptConfig = null,

    pub fn init(allocator: Allocator) EnvironmentConfig {
        return .{
            .target_machines = ArrayList([]const u8).init(allocator),
            .modules = ArrayList([]const u8).init(allocator),
            .dependencies = ArrayList([]const u8).init(allocator),
            .description = null,
            .modules_file = null,
            .dependency_file = null,
            .fallback_python = null,
            .setup = null,
            .activate = null,
        };
    }

    pub fn deinit(self: *EnvironmentConfig) void {
        for (self.target_machines.items) |item| self.target_machines.allocator.free(item);
        self.target_machines.deinit();

        for (self.modules.items) |item| self.modules.allocator.free(item);
        self.modules.deinit();

        for (self.dependencies.items) |item| self.dependencies.allocator.free(item);
        self.dependencies.deinit();

        if (self.description) |desc| self.target_machines.allocator.free(desc);
        if (self.modules_file) |mfile| self.target_machines.allocator.free(mfile);
        if (self.dependency_file) |req| self.target_machines.allocator.free(req);

        if (self.setup) |*setup_config| {
            setup_config.deinit(self.target_machines.allocator);
        }

        if (self.activate) |*activate_config| {
            activate_config.deinit(self.target_machines.allocator);
        }

        if (self.fallback_python) |py_exec| self.target_machines.allocator.free(py_exec);
    }
};

pub const ZenvConfig = struct {
    allocator: Allocator,
    environments: StringHashMap(EnvironmentConfig),
    value_tree: json.Parsed(json.Value),
    base_dir: []const u8,
    cached_hostname: ?[]const u8 = null,

    pub fn deinit(self: *ZenvConfig) void {
        var iter = self.environments.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
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
        // python_executable is now optional, no validation needed
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
    fn getString(allocator: Allocator, value: json.Value, default: ?[]const u8) !?[]const u8 {
        return switch (value) {
            .string => |str| try allocator.dupe(u8, str),
            .null => default,
            else => if (default) |def|
                try allocator.dupe(u8, def)
            else
                error.ConfigInvalid,
        };
    }

    fn getStringArray(allocator: Allocator, value: json.Value) !ArrayList([]const u8) {
        var result = ArrayList([]const u8).init(allocator);
        errdefer {
            for (result.items) |item| allocator.free(item);
            result.deinit();
        }

        switch (value) {
            .array => |array| {
                try result.ensureTotalCapacityPrecise(array.items.len);
                for (array.items) |item| {
                    if (item == .string) {
                        try result.append(try allocator.dupe(u8, item.string));
                    }
                }
            },
            .string => |str| {
                try result.append(try allocator.dupe(u8, str));
            },
            else => {},
        }

        return result;
    }

    fn getStringMap(allocator: Allocator, value: json.Value) !StringHashMap([]const u8) {
        var result = StringHashMap([]const u8).init(allocator);
        errdefer {
            var it = result.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            result.deinit();
        }

        if (value == .object) {
            var it = value.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    const key_dupe = try allocator.dupe(u8, entry.key_ptr.*);
                    const value_dupe = try allocator.dupe(u8, entry.value_ptr.string);
                    try result.put(key_dupe, value_dupe);
                }
            }
        }

        return result;
    }
};

// =======================
// Main Parse Function
// =======================

pub fn parse(allocator: Allocator, config_path: []const u8) !ZenvConfig {
    // Use ArenaAllocator only for the JSON parsing phase
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Open the file only once and read it directly into the parser
    const file = try fs.cwd().openFile(config_path, .{});
    defer file.close();

    // Parse JSON using the standard method
    const json_content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(json_content);

    const value_tree = try json.parseFromSlice(json.Value, allocator, json_content, .{
        .allocate = .alloc_always,
    });

    var config = ZenvConfig{
        .allocator = allocator,
        .environments = StringHashMap(EnvironmentConfig).init(allocator),
        .value_tree = value_tree,
        .base_dir = undefined,
    };
    errdefer config.deinit();

    const root = value_tree.value;
    if (root != .object) return error.ConfigInvalid;

    // Parse base_dir
    if (root.object.get("base_dir")) |base_dir| {
        config.base_dir = try Parse.getString(allocator, base_dir, "zenv") orelse try allocator.dupe(u8, "zenv");
    } else {
        config.base_dir = try allocator.dupe(u8, "zenv");
    }

    // Pre-calculate the capacity for environments
    try config.environments.ensureTotalCapacity(@intCast(root.object.count()));

    // Parse environments
    var env_iter = root.object.iterator();
    while (env_iter.next()) |entry| {
        const env_name = entry.key_ptr.*;
        const env_value = entry.value_ptr.*;

        if (std.mem.eql(u8, env_name, "base_dir")) continue;
        if (env_value != .object) continue;

        var env = EnvironmentConfig.init(allocator);
        errdefer env.deinit();

        // Required fields
        if (env_value.object.get("target_machines")) |tm_val| {
            env.target_machines = try Parse.getStringArray(allocator, tm_val);
            if (env.target_machines.items.len == 0) return error.ConfigInvalid;
        } else return error.ConfigInvalid;

        // Optional fields with direct retrieval
        env.fallback_python = try Parse.getString(allocator, env_value.object.get("fallback_python") orelse json.Value{ .null = {} }, null);

        env.description = try Parse.getString(allocator, env_value.object.get("description") orelse json.Value{ .null = {} }, null);

        env.modules_file = try Parse.getString(allocator, env_value.object.get("modules_file") orelse json.Value{ .null = {} }, null);

        env.dependency_file = try Parse.getString(allocator, env_value.object.get("dependency_file") orelse json.Value{ .null = {} }, null);

        // Parse setup and activate script configs
        if (env_value.object.get("setup")) |setup_value| {
            if (setup_value == .object) {
                var setup_config = ScriptConfig.init();

                // Parse script field
                if (setup_value.object.get("script")) |script_value| {
                    setup_config.script = try Parse.getString(allocator, script_value, null);
                }

                // Parse commands array
                if (setup_value.object.get("commands")) |cmds_value| {
                    if (cmds_value != .null) {
                        setup_config.commands = try Parse.getStringArray(allocator, cmds_value);
                    }
                }

                env.setup = setup_config;
            }
        }

        if (env_value.object.get("activate")) |activate_value| {
            if (activate_value == .object) {
                var activate_config = ScriptConfig.init();

                // Parse script field
                if (activate_value.object.get("script")) |script_value| {
                    activate_config.script = try Parse.getString(allocator, script_value, null);
                }

                // Parse commands array
                if (activate_value.object.get("commands")) |cmds_value| {
                    if (cmds_value != .null) {
                        activate_config.commands = try Parse.getStringArray(allocator, cmds_value);
                    }
                }

                env.activate = activate_config;
            }
        }

        // Optional arrays
        if (env_value.object.get("modules")) |mods| {
            env.modules = try Parse.getStringArray(allocator, mods);
        }

        if (env_value.object.get("dependencies")) |deps| {
            env.dependencies = try Parse.getStringArray(allocator, deps);
        }

        // Setup and activate fields are now handled by the ScriptConfig parsing above

        // Add to environments with duped key
        const env_key = try allocator.dupe(u8, env_name);
        try config.environments.put(env_key, env);
    }

    if (config.environments.count() == 0) return error.ConfigInvalid;
    return config;
}

// =======================
// RegistryEntry & Registry
// =======================

pub const AliasEntry = struct {
    alias: []const u8,
    env_name: []const u8,
};

pub const RegistryEntry = struct {
    id: []const u8, // SHA-1 unique identifier
    env_name: []const u8,
    project_dir: []const u8,
    description: ?[]const u8 = null,
    target_machines_str: []const u8,
    venv_path: []const u8,
    aliases: ArrayList([]const u8),

    pub fn deinit(self: *RegistryEntry, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.env_name);
        allocator.free(self.project_dir);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.target_machines_str);
        allocator.free(self.venv_path);
        for (self.aliases.items) |alias| {
            allocator.free(alias);
        }
        self.aliases.deinit();
    }
};

// Helper struct for JSON serialization
const RegistryJSON = struct {
    environments: []const RegistryEntryJSON,

    const RegistryEntryJSON = struct {
        id: []const u8,
        name: []const u8,
        project_dir: []const u8,
        target_machine: []const u8,
        venv_path: []const u8,
        description: ?[]const u8 = null,
        aliases: []const []const u8,
    };
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

        const zenv_dir_path = try paths.ensureZenvDir(allocator);
        defer allocator.free(zenv_dir_path);

        const registry_path = try std.fmt.allocPrint(allocator, "{s}/registry.json", .{zenv_dir_path});
        defer allocator.free(registry_path);

        // Try opening the registry file
        const file = std.fs.openFileAbsolute(registry_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try registry.save(); // Create an empty registry
                return registry;
            }
            output.printError(allocator, "Failed to open registry file: {s}", .{@errorName(err)}) catch {};
            return err;
        };
        defer file.close();

        // Parse the JSON content from the file
        const file_content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(file_content);

        // Use parsed value with proper error handling
        const parsed = try json.parseFromSlice(json.Value, allocator, file_content, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        // Process the parsed data
        const root = parsed.value;
        if (root.object.get("environments")) |environments| {
            if (environments != .array) return error.InvalidRegistryFormat;

            try registry.entries.ensureTotalCapacityPrecise(environments.array.items.len);

            for (environments.array.items) |entry_value| {
                if (entry_value != .object) continue;

                const entry_obj = entry_value.object;

                // Extract required fields
                const env_name_val = entry_obj.get("name") orelse continue;
                if (env_name_val != .string) continue;
                const env_name = env_name_val.string;

                const project_dir_val = entry_obj.get("project_dir") orelse continue;
                if (project_dir_val != .string) continue;
                const project_dir = project_dir_val.string;

                const target_machines_val = entry_obj.get("target_machine") orelse continue;
                if (target_machines_val != .string) continue;
                const target_machines = target_machines_val.string;

                // Make duplicates for the registry
                const env_name_owned = try allocator.dupe(u8, env_name);
                errdefer allocator.free(env_name_owned);

                const project_dir_owned = try allocator.dupe(u8, project_dir);
                errdefer allocator.free(project_dir_owned);

                const target_machines_str = try allocator.dupe(u8, target_machines);
                errdefer allocator.free(target_machines_str);

                // Handle optional description
                var description: ?[]const u8 = null;
                if (entry_obj.get("description")) |desc_value| {
                    if (desc_value == .string) {
                        description = try allocator.dupe(u8, desc_value.string);
                    }
                }
                errdefer if (description) |desc| allocator.free(desc);

                // Get or generate ID
                var id_owned: []const u8 = undefined;
                if (entry_obj.get("id")) |id_value| {
                    if (id_value == .string) {
                        id_owned = try allocator.dupe(u8, id_value.string);
                    } else {
                        id_owned = try generateSHA1ID(allocator, env_name_owned, project_dir_owned, target_machines_str);
                    }
                } else {
                    id_owned = try generateSHA1ID(allocator, env_name_owned, project_dir_owned, target_machines_str);
                }
                errdefer allocator.free(id_owned);

                // Get venv_path
                const venv_path_owned: []const u8 = blk: {
                    if (entry_obj.get("venv_path")) |venv_path_val| {
                        if (venv_path_val == .string) {
                            break :blk try allocator.dupe(u8, venv_path_val.string);
                        }
                    }

                    // Default reconstruction
                    break :blk try std.fs.path.join(allocator, &[_][]const u8{
                        project_dir_owned, "zenv", env_name_owned,
                    });
                };
                errdefer allocator.free(venv_path_owned);

                // Initialize aliases list for this entry
                var aliases = ArrayList([]const u8).init(allocator);

                // Load aliases if they exist for this entry
                if (entry_obj.get("aliases")) |aliases_value| {
                    if (aliases_value == .array) {
                        for (aliases_value.array.items) |alias_value| {
                            if (alias_value == .string) {
                                const alias_owned = try allocator.dupe(u8, alias_value.string);
                                errdefer allocator.free(alias_owned);
                                try aliases.append(alias_owned);
                            }
                        }
                    }
                }

                // Add entry to registry
                try registry.entries.append(.{
                    .id = id_owned,
                    .env_name = env_name_owned,
                    .project_dir = project_dir_owned,
                    .description = description,
                    .target_machines_str = target_machines_str,
                    .venv_path = venv_path_owned,
                    .aliases = aliases,
                });
            }
        }

        return registry;
    }

    pub fn save(self: *const EnvironmentRegistry) !void {
        const zenv_dir_path = try paths.ensureZenvDir(self.allocator);
        defer self.allocator.free(zenv_dir_path);

        const registry_path = try std.fmt.allocPrint(self.allocator, "{s}/registry.json", .{zenv_dir_path});
        defer self.allocator.free(registry_path);

        // Create registry JSON object using helpers for structure
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // More efficient JSON creation using StringArrayHashMap
        var root = json.ObjectMap.init(arena.allocator());
        var entries_array = json.Array.init(arena.allocator());

        for (self.entries.items) |entry| {
            var entry_obj = json.ObjectMap.init(arena.allocator());
            try entry_obj.put("id", json.Value{ .string = entry.id });
            try entry_obj.put("name", json.Value{ .string = entry.env_name });
            try entry_obj.put("project_dir", json.Value{ .string = entry.project_dir });
            try entry_obj.put("target_machine", json.Value{ .string = entry.target_machines_str });
            try entry_obj.put("venv_path", json.Value{ .string = entry.venv_path });

            if (entry.description) |desc| {
                try entry_obj.put("description", json.Value{ .string = desc });
            }

            // Add aliases array for this entry
            var aliases_array = json.Array.init(arena.allocator());
            for (entry.aliases.items) |alias| {
                try aliases_array.append(json.Value{ .string = alias });
            }
            try entry_obj.put("aliases", json.Value{ .array = aliases_array });

            try entries_array.append(json.Value{ .object = entry_obj });
        }

        try root.put("environments", json.Value{ .array = entries_array });

        // StringBuffer for creating the JSON string
        var string_buffer = std.ArrayList(u8).init(self.allocator);
        defer string_buffer.deinit();

        try json.stringify(
            json.Value{ .object = root },
            .{ .whitespace = .indent_2 },
            string_buffer.writer(),
        );

        // Write to file
        const file = try std.fs.createFileAbsolute(registry_path, .{});
        defer file.close();
        try file.writeAll(string_buffer.items);
    }

    pub fn register(
        self: *EnvironmentRegistry,
        env_name: []const u8,
        project_dir: []const u8,
        base_dir: []const u8,
        description: ?[]const u8,
        target_machines: []const []const u8,
    ) !void {
        var registry_target_machines_str: []const u8 = undefined;
        if (target_machines.len == 0) {
            registry_target_machines_str = try self.allocator.dupe(u8, "any");
        } else if (target_machines.len == 1) {
            registry_target_machines_str = try self.allocator.dupe(u8, target_machines[0]);
        } else {
            // Use efficient string joining
            registry_target_machines_str = try std.mem.join(self.allocator, ", ", target_machines);
        }
        errdefer self.allocator.free(registry_target_machines_str);

        // Get virtual env path
        var venv_path: []const u8 = undefined;
        if (std.fs.path.isAbsolute(base_dir)) {
            venv_path = try std.fs.path.join(self.allocator, &[_][]const u8{ base_dir, env_name });
        } else {
            venv_path = try std.fs.path.join(self.allocator, &[_][]const u8{ project_dir, base_dir, env_name });
        }
        errdefer self.allocator.free(venv_path);

        // Check for existing entry
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.env_name, env_name)) {
                // Update existing entry
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

        // Create new entry
        const id = try generateSHA1ID(self.allocator, env_name, project_dir, registry_target_machines_str);
        errdefer self.allocator.free(id);

        try self.entries.append(.{
            .id = id,
            .env_name = try self.allocator.dupe(u8, env_name),
            .project_dir = try self.allocator.dupe(u8, project_dir),
            .description = if (description) |desc| try self.allocator.dupe(u8, desc) else null,
            .target_machines_str = registry_target_machines_str,
            .venv_path = venv_path,
            .aliases = ArrayList([]const u8).init(self.allocator),
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
        // Fast path: Direct lookup by env_name
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.env_name, identifier)) {
                return entry;
            }
        }

        // Check for alias match
        for (self.entries.items) |entry| {
            for (entry.aliases.items) |alias| {
                if (std.mem.eql(u8, alias, identifier)) {
                    return entry;
                }
            }
        }

        // Check for exact ID match
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.id, identifier)) {
                return entry;
            }
        }

        // Lookup by ID prefix if it's long enough (7+ chars)
        if (identifier.len >= 7) {
            var matching_entry: ?RegistryEntry = null;
            var match_count: usize = 0;

            for (self.entries.items) |entry| {
                if (entry.id.len >= identifier.len and
                    std.mem.eql(u8, entry.id[0..identifier.len], identifier))
                {
                    matching_entry = entry;
                    match_count += 1;

                    // If we find more than one match, we can't uniquely identify
                    if (match_count > 1) break;
                }
            }

            // Return only if we found exactly one match
            if (match_count == 1) return matching_entry;
        }

        return null;
    }

    // Alias management methods
    pub fn addAlias(self: *EnvironmentRegistry, alias_name: []const u8, env_name: []const u8) !void {
        // Check if alias already exists across all entries
        for (self.entries.items) |entry| {
            for (entry.aliases.items) |alias| {
                if (std.mem.eql(u8, alias, alias_name)) {
                    return error.AliasAlreadyExists;
                }
            }
        }

        // Find the environment entry and add alias to it
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.env_name, env_name)) {
                const alias_name_owned = try self.allocator.dupe(u8, alias_name);
                errdefer self.allocator.free(alias_name_owned);

                try entry.aliases.append(alias_name_owned);
                return;
            }
        }

        // Environment not found
        return error.EnvironmentNotFound;
    }

    pub fn removeAlias(self: *EnvironmentRegistry, alias_name: []const u8) bool {
        for (self.entries.items) |*entry| {
            for (entry.aliases.items, 0..) |alias, i| {
                if (std.mem.eql(u8, alias, alias_name)) {
                    self.allocator.free(entry.aliases.orderedRemove(i));
                    return true;
                }
            }
        }
        return false;
    }

    pub fn resolveAlias(self: *const EnvironmentRegistry, identifier: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            for (entry.aliases.items) |alias| {
                if (std.mem.eql(u8, alias, identifier)) {
                    return entry.env_name;
                }
            }
        }
        return null;
    }

    pub fn listAliases(self: *const EnvironmentRegistry, allocator: Allocator) !ArrayList(AliasEntry) {
        var aliases = ArrayList(AliasEntry).init(allocator);

        for (self.entries.items) |entry| {
            for (entry.aliases.items) |alias| {
                try aliases.append(.{ .alias = alias, .env_name = entry.env_name });
            }
        }

        return aliases;
    }

    pub fn renameEnvironment(self: *EnvironmentRegistry, old_identifier: []const u8, new_name: []const u8) !void {
        const old_entry = self.lookup(old_identifier) orelse return error.EnvironmentNotFound;

        if (self.lookup(new_name) != null) {
            return error.EnvironmentAlreadyExists;
        }

        if (new_name.len == 0 or new_name.len > 255) {
            return error.InvalidEnvironmentName;
        }

        for (new_name) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-' and char != '.') {
                return error.InvalidEnvironmentName;
            }
        }

        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.env_name, old_entry.env_name)) {
                self.allocator.free(entry.env_name);
                entry.env_name = try self.allocator.dupe(u8, new_name);

                const old_venv_path = entry.venv_path;
                const parent_dir = std.fs.path.dirname(old_venv_path) orelse return error.InvalidPath;

                self.allocator.free(entry.venv_path);
                entry.venv_path = try std.fs.path.join(self.allocator, &[_][]const u8{ parent_dir, new_name });

                const new_id = try generateSHA1ID(self.allocator, new_name, entry.project_dir, entry.target_machines_str);
                self.allocator.free(entry.id);
                entry.id = new_id;

                return;
            }
        }

        return error.EnvironmentNotFound;
    }
};
