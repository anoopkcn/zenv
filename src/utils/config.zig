const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const StringHashMap = std.StringHashMap;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const mem = std.mem;
const json = std.json;
const paths = @import("paths.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");

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

    const timestamp_str = try std.fmt.allocPrint(arena.allocator(), "{d}", .{runtime.nowMillis()});
    sha1.update(timestamp_str);

    var hash: [20]u8 = undefined;
    sha1.final(&hash);

    // Efficient hex conversion (no intermediate format pass)
    const hex = std.fmt.bytesToHex(hash, .lower);
    return allocator.dupe(u8, &hex);
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
    // When true (default), setup snapshots the environment that `module load`
    // produces and activate replays it instead of re-running Lmod. Only has an
    // effect when `modules` is non-empty.
    module_cache: bool = true,

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
            .module_cache = true,
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

    pub fn deinit(self: *ZenvConfig) void {
        var iter = self.environments.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.environments.deinit();
        self.value_tree.deinit();
        self.allocator.free(self.base_dir);
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
};

// =======================
// Parsing Helpers
// =======================

const Parse = struct {
    fn getBool(value: json.Value, default: bool) bool {
        return switch (value) {
            .bool => |b| b,
            else => default,
        };
    }

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
    // Read the whole config file, then parse the bytes.
    const json_content = try runtime.readFileAlloc(allocator, config_path, 10 * 1024 * 1024);
    defer allocator.free(json_content);
    return parseFromContent(allocator, json_content);
}

/// Parses already-read config bytes into a ZenvConfig. Callers that have already
/// read the file (e.g. validateAndParse, which validates the very same bytes) use
/// this to avoid a redundant read+parse. The returned config owns its data through
/// an internal parsed value tree (alloc_always), so `json_content` may be freed
/// once this returns.
pub fn parseFromContent(allocator: Allocator, json_content: []const u8) !ZenvConfig {
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

        env.module_cache = Parse.getBool(env_value.object.get("module_cache") orelse json.Value{ .null = {} }, true);

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

// Python interpreter that built a venv, read from <venv>/pyvenv.cfg.
pub const VenvPythonInfo = struct {
    version: []const u8,
    path: ?[]const u8, // best-available interpreter path; may be null

    pub fn deinit(self: *VenvPythonInfo, allocator: Allocator) void {
        allocator.free(self.version);
        if (self.path) |p| allocator.free(p);
    }
};

// Fields extracted from a pyvenv.cfg body. Slices point INTO the input.
const PyvenvFields = struct { version: ?[]const u8, path: ?[]const u8 };

// Pure parser for pyvenv.cfg contents. `version` is the `version =` value.
// `path` is the best-available interpreter path across Python versions:
// `executable =` (3.11+) -> first token of `command =` (3.x, incl. zenv's
// default 3.10) -> `home =` (the bin dir). Returns nulls when absent.
fn parsePyvenvCfg(content: []const u8) PyvenvFields {
    var version: ?[]const u8 = null;
    var executable: ?[]const u8 = null;
    var home: ?[]const u8 = null;
    var command: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "version")) {
            version = val;
        } else if (std.mem.eql(u8, key, "executable")) {
            executable = val;
        } else if (std.mem.eql(u8, key, "home")) {
            home = val;
        } else if (std.mem.eql(u8, key, "command")) {
            command = val;
        }
    }

    var path: ?[]const u8 = executable;
    if (path == null) {
        if (command) |cmd| {
            const first = std.mem.sliceTo(cmd, ' ');
            if (first.len > 0) path = first;
        }
    }
    if (path == null) path = home;

    return .{ .version = version, .path = path };
}

// Reads <venv_path>/pyvenv.cfg and returns the Python version + interpreter path
// used to build the venv. Returns null if the file is absent/unreadable (env not
// built) or has no `version`. Caller owns the returned strings (call deinit).
pub fn readVenvPythonInfo(allocator: Allocator, venv_path: []const u8) !?VenvPythonInfo {
    const cfg_path = try std.fs.path.join(allocator, &[_][]const u8{ venv_path, "pyvenv.cfg" });
    defer allocator.free(cfg_path);

    const content = runtime.readFileAlloc(allocator, cfg_path, 64 * 1024) catch {
        // Missing or unreadable -> treat as "not built"; list output stays robust.
        return null;
    };
    defer allocator.free(content);

    const fields = parsePyvenvCfg(content);
    const version = fields.version orelse return null;

    return VenvPythonInfo{
        .version = try allocator.dupe(u8, version),
        .path = if (fields.path) |p| try allocator.dupe(u8, p) else null,
    };
}

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
    entries: std.array_list.Managed(RegistryEntry),

    pub fn init(allocator: Allocator) EnvironmentRegistry {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(RegistryEntry).init(allocator),
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

        // Read the registry file (creating an empty one if it does not exist yet)
        const file_content = runtime.readFileAlloc(allocator, registry_path, 10 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                try registry.save(); // Create an empty registry
                return registry;
            }
            output.printError(allocator, "Failed to open registry file: {s}", .{@errorName(err)}) catch {};
            return err;
        };
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

        // Build a plain serializable view of the registry and let std.json
        // stringify it directly (no manual Value-tree construction).
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const entries = try a.alloc(RegistryJSON.RegistryEntryJSON, self.entries.items.len);
        for (self.entries.items, 0..) |entry, i| {
            entries[i] = .{
                .id = entry.id,
                .name = entry.env_name,
                .project_dir = entry.project_dir,
                .target_machine = entry.target_machines_str,
                .venv_path = entry.venv_path,
                .description = entry.description,
                .aliases = entry.aliases.items,
            };
        }
        const registry_json = RegistryJSON{ .environments = entries };

        // Serialize to JSON text and write it out in one shot.
        const json_text = try std.json.Stringify.valueAlloc(
            self.allocator,
            registry_json,
            .{ .whitespace = .indent_2 },
        );
        defer self.allocator.free(json_text);

        try runtime.writeFile(registry_path, json_text);
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

    /// Structural removal by ref. CONSUMES the ref and RETURNS the owned,
    /// detached entry so the caller can read env_name/venv_path AFTER removal
    /// with no dupe-before-mutate. Persists registry.json on success; on save
    /// failure the entry is freed and the error returned (no leak).
    pub fn deregister(self: *EnvironmentRegistry, ref: EnvRef) !RegistryEntry {
        const removed = self.entries.orderedRemove(ref.idx);
        self.save() catch |err| {
            var tmp = removed;
            tmp.deinit(self.allocator);
            return err;
        };
        return removed;
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

    /// Opaque, stable handle to a resolved environment. Index-keyed: valid
    /// across a field mutation of its entry (rename), consumed by structural
    /// removal (deregister), and does not outlive a reload of the registry.
    pub const EnvRef = struct { idx: usize };

    /// Pure resolution core (internal seam). No I/O, no printing. Maps an
    /// identifier to exactly one entry index, applying the load-bearing order:
    ///   "." (project_dir == cwd) -> name -> alias -> exact id -> unique 7+ prefix.
    /// `cwd` must be non-null when `identifier` is "."; pass null otherwise.
    /// Ambiguity (a prefix or "." matching >1 entry) is distinct from not-found.
    fn resolveAgainstCwd(
        self: *const EnvironmentRegistry,
        identifier: []const u8,
        cwd: ?[]const u8,
    ) error{ EnvironmentNotRegistered, AmbiguousIdentifier }!EnvRef {
        // 1. "." -> the unique entry whose project_dir == cwd
        if (std.mem.eql(u8, identifier, ".")) {
            const dir = cwd orelse return error.EnvironmentNotRegistered;
            var found: ?usize = null;
            var count: usize = 0;
            for (self.entries.items, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.project_dir, dir)) {
                    count += 1;
                    if (found == null) found = i;
                }
            }
            if (count == 0) return error.EnvironmentNotRegistered;
            if (count > 1) return error.AmbiguousIdentifier;
            return .{ .idx = found.? };
        }

        // 2. exact env_name
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.env_name, identifier)) return .{ .idx = i };
        }

        // 3. alias -> its entry
        for (self.entries.items, 0..) |entry, i| {
            for (entry.aliases.items) |alias| {
                if (std.mem.eql(u8, alias, identifier)) return .{ .idx = i };
            }
        }

        // 4. exact id
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, identifier)) return .{ .idx = i };
        }

        // 5. unique 7+ char id prefix (>1 match -> ambiguous)
        if (identifier.len >= 7) {
            var found: ?usize = null;
            var count: usize = 0;
            for (self.entries.items, 0..) |entry, i| {
                if (entry.id.len >= identifier.len and
                    std.mem.eql(u8, entry.id[0..identifier.len], identifier))
                {
                    count += 1;
                    if (found == null) found = i;
                }
            }
            if (count == 1) return .{ .idx = found.? };
            if (count > 1) return error.AmbiguousIdentifier;
        }

        return error.EnvironmentNotRegistered;
    }

    /// Handler-facing entry point. Resolves a raw <name|id|.> to a stable EnvRef.
    /// Touches the filesystem only for the "." branch (cwd realpath + zenv.json
    /// presence); every other branch is pure. Prints nothing — failures are typed
    /// errors that the caller renders (see commands.present) and main.zig maps.
    pub fn resolve(self: *const EnvironmentRegistry, allocator: Allocator, identifier: []const u8) !EnvRef {
        if (std.mem.eql(u8, identifier, ".")) {
            runtime.access("zenv.json") catch |err| {
                if (err == error.FileNotFound) return error.ConfigFileNotFound;
                return err;
            };
            const cwd = try runtime.cwdRealpath(allocator);
            defer allocator.free(cwd);
            return self.resolveAgainstCwd(identifier, cwd);
        }
        return self.resolveAgainstCwd(identifier, null);
    }

    /// Just-in-time borrow through a handle. The returned pointer/slices are
    /// registry-owned and live until the entry is mutated/removed; do not stash.
    pub fn get(self: *const EnvironmentRegistry, ref: EnvRef) *const RegistryEntry {
        return &self.entries.items[ref.idx];
    }

    /// Names the candidates an ambiguous identifier matched, for the call-site
    /// error message. Mirrors resolve's "." shell so it lists both ambiguity
    /// kinds. Returns borrowed env_names; caller frees the outer slice only.
    pub fn candidates(self: *const EnvironmentRegistry, allocator: Allocator, identifier: []const u8) ![]const []const u8 {
        var list = std.array_list.Managed([]const u8).init(allocator);
        errdefer list.deinit();

        if (std.mem.eql(u8, identifier, ".")) {
            const cwd = runtime.cwdRealpath(allocator) catch return list.toOwnedSlice();
            defer allocator.free(cwd);
            for (self.entries.items) |entry| {
                if (std.mem.eql(u8, entry.project_dir, cwd)) try list.append(entry.env_name);
            }
        } else if (identifier.len >= 7) {
            for (self.entries.items) |entry| {
                if (entry.id.len >= identifier.len and
                    std.mem.eql(u8, entry.id[0..identifier.len], identifier))
                {
                    try list.append(entry.env_name);
                }
            }
        }
        return list.toOwnedSlice();
    }

    // Alias management methods
    pub fn addAlias(self: *EnvironmentRegistry, alias_name: []const u8, env_name: []const u8) !void {
        // Reject an alias that would shadow an existing environment name. Resolution
        // is name-first, so without this guard such an alias would be unreachable
        // and confusing; forbidding it keeps name and alias namespaces disjoint.
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.env_name, alias_name)) return error.AliasAlreadyExists;
        }

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

    /// Field-mutates the entry at `ref` (env_name, venv_path, recomputed id) in
    /// place and persists. The ref STAYS VALID (no structural change), so a
    /// caller's rollback is `rename(ref, old_name)`. Transactional w.r.t. the
    /// in-memory registry: if the save fails, the in-memory mutation is rolled
    /// back and the error returned. Does NOT move the venv directory or touch
    /// Jupyter kernels — that orchestration stays in the command.
    pub fn rename(self: *EnvironmentRegistry, ref: EnvRef, new_name: []const u8) !void {
        if (new_name.len == 0 or new_name.len > 255) return error.InvalidEnvironmentName;
        for (new_name) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-' and char != '.') {
                return error.InvalidEnvironmentName;
            }
        }
        // Uniqueness: new_name must not already resolve to an entry (name, alias,
        // exact id, or unique prefix), mirroring the old lookup() != null check.
        if (self.resolveAgainstCwd(new_name, null)) |_| {
            return error.EnvironmentAlreadyExists;
        } else |_| {}

        const entry = &self.entries.items[ref.idx];
        const parent_dir = std.fs.path.dirname(entry.venv_path) orelse return error.InvalidPath;

        const new_venv = try std.fs.path.join(self.allocator, &[_][]const u8{ parent_dir, new_name });
        errdefer self.allocator.free(new_venv);
        const new_id = try generateSHA1ID(self.allocator, new_name, entry.project_dir, entry.target_machines_str);
        errdefer self.allocator.free(new_id);
        const new_name_owned = try self.allocator.dupe(u8, new_name);
        errdefer self.allocator.free(new_name_owned);

        // Swap in the new strings, keeping the old pointers for rollback.
        const old_name_ptr = entry.env_name;
        const old_venv_ptr = entry.venv_path;
        const old_id_ptr = entry.id;
        entry.env_name = new_name_owned;
        entry.venv_path = new_venv;
        entry.id = new_id;

        self.save() catch |err| {
            // Restore the in-memory state; the errdefers free the orphaned new_*.
            entry.env_name = old_name_ptr;
            entry.venv_path = old_venv_ptr;
            entry.id = old_id_ptr;
            return err;
        };

        // Persisted: the entry owns the new strings now; free the replaced olds.
        self.allocator.free(old_name_ptr);
        self.allocator.free(old_venv_ptr);
        self.allocator.free(old_id_ptr);
    }
};

// ============================ Tests ============================

const testing = std.testing;
const test_support = @import("../test_support.zig");

test "generateSHA1ID returns 40-char lowercase hex" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const id = try generateSHA1ID(a, "env", "/proj", "*");
    defer a.free(id);
    try testing.expectEqual(@as(usize, 40), id.len);
    for (id) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
}

test "registry lookup by name, alias, and id prefix" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();

    try reg.entries.append(.{
        .id = try a.dupe(u8, "0123456789abcdef0123456789abcdef01234567"),
        .env_name = try a.dupe(u8, "myenv"),
        .project_dir = try a.dupe(u8, "/p"),
        .description = null,
        .target_machines_str = try a.dupe(u8, "*"),
        .venv_path = try a.dupe(u8, "/p/zenv/myenv"),
        .aliases = std.array_list.Managed([]const u8).init(a),
    });

    try testing.expect(reg.lookup("myenv") != null);
    try testing.expect(reg.lookup("nope") == null);
    try testing.expect(reg.lookup("0123456789abcdef") != null); // id prefix

    try reg.addAlias("me", "myenv");
    try testing.expect(reg.lookup("me") != null);
    try testing.expectEqualStrings("myenv", reg.resolveAlias("me").?);
    try testing.expect(reg.removeAlias("me"));
    try testing.expect(reg.resolveAlias("me") == null);
}

// Appends a minimal entry for resolution tests (venv_path mirrors the dir; not asserted on).
fn tAppend(reg: *EnvironmentRegistry, id: []const u8, name: []const u8, dir: []const u8) !void {
    const a = reg.allocator;
    try reg.entries.append(.{
        .id = try a.dupe(u8, id),
        .env_name = try a.dupe(u8, name),
        .project_dir = try a.dupe(u8, dir),
        .description = null,
        .target_machines_str = try a.dupe(u8, "*"),
        .venv_path = try a.dupe(u8, dir),
        .aliases = std.array_list.Managed([]const u8).init(a),
    });
}

test "resolveAgainstCwd: name, alias, exact id, unique prefix, not-found" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppend(&reg, "aaaaaaa1111111111111111111111111111111111", "web", "/p/web");
    try tAppend(&reg, "bbbbbbb2222222222222222222222222222222222", "api", "/p/api");
    try reg.addAlias("w", "web");

    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("web", null)).idx);
    try testing.expectEqual(@as(usize, 1), (try reg.resolveAgainstCwd("api", null)).idx);
    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("w", null)).idx); // alias
    try testing.expectEqual(@as(usize, 1), (try reg.resolveAgainstCwd("bbbbbbb2222222222222222222222222222222222", null)).idx); // exact id
    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("aaaaaaa", null)).idx); // unique 7-char prefix
    try testing.expectError(error.EnvironmentNotRegistered, reg.resolveAgainstCwd("nope", null));
}

test "resolveAgainstCwd: ambiguous id prefix is distinct from not-found" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppend(&reg, "abcdef0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "one", "/p/one");
    try tAppend(&reg, "abcdef0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "two", "/p/two");

    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd("abcdef0", null));
}

test "resolveAgainstCwd: '.' matches by cwd, ambiguous when two share a project_dir" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppend(&reg, "id1aaaa0000000000000000000000000000000000", "web", "/proj");

    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd(".", "/proj")).idx);
    try testing.expectError(error.EnvironmentNotRegistered, reg.resolveAgainstCwd(".", "/elsewhere"));
    try testing.expectError(error.EnvironmentNotRegistered, reg.resolveAgainstCwd(".", null));

    try tAppend(&reg, "id2bbbb0000000000000000000000000000000000", "worker", "/proj");
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd(".", "/proj"));
}

test "deregister(ref) transfers ownership; rename(ref) keeps the ref valid" {
    test_support.setupRuntime();
    const a = testing.allocator;

    // Point ZENV_DIR at a scratch dir so the folded save() writes there, not ~/.zenv.
    // (Map.put copies the strings.) The testing allocator then leak-checks the
    // entries' own allocations — catching any double-free/leak in the mutators.
    const zdir = ".zig-cache/tmp/zenv-registry-test";
    runtime.environ_map.put("ZENV_DIR", zdir) catch unreachable;
    runtime.deleteTree(zdir) catch {};
    defer runtime.deleteTree(zdir) catch {};

    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppend(&reg, "aaaaaaa1111111111111111111111111111111111", "web", "/p/web");
    try tAppend(&reg, "bbbbbbb2222222222222222222222222222222222", "api", "/p/api");

    // rename: in-place field mutation keeps the ref valid and frees the old strings once.
    const ref_web = try reg.resolveAgainstCwd("web", null);
    try reg.rename(ref_web, "web2");
    try testing.expectEqualStrings("web2", reg.get(ref_web).env_name);
    try testing.expectEqual(ref_web.idx, (try reg.resolveAgainstCwd("web2", null)).idx);

    // deregister: the owned, detached entry is readable after removal, then freed once.
    const ref_api = try reg.resolveAgainstCwd("api", null);
    var removed = try reg.deregister(ref_api);
    try testing.expectEqualStrings("api", removed.env_name);
    removed.deinit(a);
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try testing.expectEqualStrings("web2", reg.get(.{ .idx = 0 }).env_name);
}

test "parsePyvenvCfg: 3.11-style uses executable path" {
    const content =
        \\home = /opt/python/3.11/bin
        \\include-system-site-packages = false
        \\version = 3.11.5
        \\executable = /opt/python/3.11/bin/python3.11
        \\command = /opt/python/3.11/bin/python3.11 -m venv /p/zenv/e
    ;
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.11.5", f.version.?);
    try testing.expectEqualStrings("/opt/python/3.11/bin/python3.11", f.path.?);
}

test "parsePyvenvCfg: 3.10-style (no executable) falls back to command's first token" {
    const content =
        \\home = /opt/python/3.10/bin
        \\include-system-site-packages = false
        \\version = 3.10.8
        \\command = /opt/python/3.10/bin/python3.10 -m venv /p/zenv/e
    ;
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.10.8", f.version.?);
    try testing.expectEqualStrings("/opt/python/3.10/bin/python3.10", f.path.?);
}

test "parsePyvenvCfg: only version + home falls back to home" {
    const content =
        \\home = /usr/bin
        \\version = 3.9.2
    ;
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.9.2", f.version.?);
    try testing.expectEqualStrings("/usr/bin", f.path.?);
}

test "parsePyvenvCfg: missing version yields null (caller omits the line)" {
    const content =
        \\home = /usr/bin
        \\include-system-site-packages = false
    ;
    const f = parsePyvenvCfg(content);
    try testing.expect(f.version == null);
}

test "parsePyvenvCfg: tolerates CRLF and irregular spacing around '='" {
    const content = "version=3.12.1\r\nexecutable   =   /x/py\r\n";
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.12.1", f.version.?);
    try testing.expectEqualStrings("/x/py", f.path.?);
}

test "Parse.getBool reads booleans and falls back on non-bool" {
    try testing.expectEqual(true, Parse.getBool(json.Value{ .bool = true }, false));
    try testing.expectEqual(false, Parse.getBool(json.Value{ .bool = false }, true));
    // Missing / null / wrong-typed values fall back to the default.
    try testing.expectEqual(true, Parse.getBool(json.Value{ .null = {} }, true));
    try testing.expectEqual(false, Parse.getBool(json.Value{ .null = {} }, false));
    try testing.expectEqual(true, Parse.getBool(json.Value{ .string = "yes" }, true));
}
