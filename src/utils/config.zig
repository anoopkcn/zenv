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
        for (self.target_machines.items) |item| self.target_machines.allocator.free(item);
        self.target_machines.deinit();
        
        for (self.modules.items) |item| self.modules.allocator.free(item);
        self.modules.deinit();
        
        for (self.dependencies.items) |item| self.dependencies.allocator.free(item);
        self.dependencies.deinit();
        
        var iter = self.custom_activate_vars.iterator();
        while (iter.next()) |entry| {
            self.custom_activate_vars.allocator.free(entry.key_ptr.*);
            self.custom_activate_vars.allocator.free(entry.value_ptr.*);
        }
        self.custom_activate_vars.deinit();
        
        if (self.description) |desc| self.target_machines.allocator.free(desc);
        if (self.requirements_file) |req| self.target_machines.allocator.free(req);
        
        if (self.setup_commands) |*cmds| {
            for (cmds.items) |item| cmds.allocator.free(item);
            cmds.deinit();
        }
        
        self.target_machines.allocator.free(self.python_executable);
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
    // Use arena allocator ONLY for temporary allocations during parsing
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    
    const file = try fs.cwd().openFile(config_path, .{});
    defer file.close();
    const json_string = try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(json_string);

    // Parse JSON using the main allocator, not the arena
    // This ensures the value_tree can be properly freed later
    const value_tree = try json.parseFromSlice(json.Value, allocator, json_string, .{
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
        config.base_dir = try Parse.getString(
            allocator, 
            base_dir, 
            "zenv"
        ) orelse try allocator.dupe(u8, "zenv");
    } else {
        config.base_dir = try allocator.dupe(u8, "zenv");
    }

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

        if (env_value.object.get("python_executable")) |py_exec| {
            env.python_executable = (try Parse.getString(allocator, py_exec, null)) orelse 
                return error.ConfigInvalid;
        } else return error.ConfigInvalid;

        // Optional fields
        if (env_value.object.get("description")) |desc| {
            env.description = try Parse.getString(allocator, desc, null);
        }
        
        if (env_value.object.get("modules")) |mods| {
            env.modules = try Parse.getStringArray(allocator, mods);
        }
        
        if (env_value.object.get("requirements_file")) |req| {
            env.requirements_file = try Parse.getString(allocator, req, null);
        }
        
        if (env_value.object.get("dependencies")) |deps| {
            env.dependencies = try Parse.getStringArray(allocator, deps);
        }
        
        if (env_value.object.get("custom_activate_vars")) |vars| {
            env.custom_activate_vars = try Parse.getStringMap(allocator, vars);
        }
        
        if (env_value.object.get("setup_commands")) |cmds| {
            if (cmds != .null) {
                env.setup_commands = try Parse.getStringArray(allocator, cmds);
            }
        }

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

        // Create a temporary arena for parsing
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

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

        const file_content = file.readToEndAlloc(arena.allocator(), 1 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read registry file: {s}", .{@errorName(err)});
            return err;
        };

        // Parse JSON using the allocator directly, not the arena, to properly clean up
        // This makes sure all parsed JSON data can be properly freed
        const parsed = json.parseFromSlice(json.Value, allocator, file_content, .{
            .allocate = .alloc_always,
        }) catch |err| {
            std.log.err("Failed to parse registry JSON: {s}", .{@errorName(err)});
            return err;
        };
        // Since we're using the main allocator, make sure we clean up
        defer parsed.deinit();

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
                
                const project_dir_val = entry_obj.get("project_dir") orelse continue;
                if (project_dir_val != .string) continue;
                
                const target_machines_val = entry_obj.get("target_machine") orelse continue;
                if (target_machines_val != .string) continue;
                
                // Make duplicates for the registry
                const env_name = try allocator.dupe(u8, env_name_val.string);
                errdefer allocator.free(env_name);
                
                const project_dir = try allocator.dupe(u8, project_dir_val.string);
                errdefer allocator.free(project_dir);
                
                const target_machines_str = try allocator.dupe(u8, target_machines_val.string);
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
                        id_owned = try generateSHA1ID(allocator, env_name, project_dir, target_machines_str);
                    }
                } else {
                    id_owned = try generateSHA1ID(allocator, env_name, project_dir, target_machines_str);
                }
                errdefer allocator.free(id_owned);
                
                const venv_path_owned: []const u8 = blk: {
                    if (entry_obj.get("venv_path")) |venv_path_val| {
                        if (venv_path_val == .string) {
                            break :blk try allocator.dupe(u8, venv_path_val.string);
                        }
                    }
                    
                    // Default reconstruction
                    break :blk try std.fs.path.join(allocator, &[_][]const u8{
                        project_dir, "zenv", env_name,
                    });
                };
                errdefer allocator.free(venv_path_owned);
                
                // Add entry to registry
                try registry.entries.append(.{
                    .id = id_owned,
                    .env_name = env_name,
                    .project_dir = project_dir,
                    .description = description,
                    .target_machines_str = target_machines_str,
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
        // Fast lookup by name or id
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.env_name, identifier) or std.mem.eql(u8, entry.id, identifier)) {
                return entry;
            }
        }
        
        // Lookup by prefix if long enough
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