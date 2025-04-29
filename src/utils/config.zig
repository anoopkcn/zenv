const std = @import("std");
const Allocator = std.mem.Allocator;
const Json = std.json;
const fs = std.fs;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const environment = @import("environment.zig");

// Helper function to parse a required string field
fn parseRequiredString(allocator: Allocator, v: *const Json.Value, field_name: []const u8, env_name: []const u8) ![]const u8 {
    if (v.* != .string) { // Dereference pointer for comparison
        std.log.err("Expected string for field '{s}' in environment '{s}', found {s}", .{ field_name, env_name, @tagName(v.*) });
        return error.ConfigInvalid;
    }
    // Duplicate the string to ensure we own the memory
    return try allocator.dupe(u8, v.string);
}

// Helper function to handle parse errors with debug logging
fn debugParseError(allocator: Allocator, field_name: []const u8, env_name: []const u8, err: anyerror) void {
    errors.debugLog(allocator, "Parse error on field '{s}' in environment '{s}': {s}", .{ field_name, env_name, @errorName(err) });
}

// Helper function to parse an optional string field
fn parseOptionalString(allocator: Allocator, v: *const Json.Value, field_name: []const u8, env_name: []const u8) !?[]const u8 {
    if (v.* == .null) return null; // Dereference pointer
    if (v.* != .string) { // Dereference pointer
        std.log.err("Expected string or null for field '{s}' in environment '{s}', found {s}", .{ field_name, env_name, @tagName(v.*) });
        return error.ConfigInvalid;
    }
    // Duplicate optional string if present
    return try allocator.dupe(u8, v.string);
}

// Helper function to parse a string array field
fn parseStringArray(allocator: Allocator, list: *ArrayList([]const u8), v: *const Json.Value, field_name: []const u8, env_name: []const u8) !void {
    if (v.* != .array) { // Dereference pointer
        std.log.err("Expected array for field '{s}' in environment '{s}', found {s}", .{ field_name, env_name, @tagName(v.*) });
        return error.ConfigInvalid;
    }
    // ensureTotalCapacity uses the list's allocator implicitly
    try list.ensureTotalCapacity(v.array.items.len);
    for (v.array.items) |item_val| { // Use a different var name
        const item = &item_val; // Take address if needed by called funcs, or use directly
        if (item.* != .string) { // Dereference pointer
            std.log.err("Expected string elements in array '{s}' for environment '{s}'", .{ field_name, env_name });
            return error.ConfigInvalid;
        }
        // Duplicate the string to ensure we own the memory
        const duped_string = try allocator.dupe(u8, item.string);
        list.appendAssumeCapacity(duped_string);
    }
}

// Registry entry for a single environment
pub const RegistryEntry = struct {
    id: []const u8, // SHA-1 unique identifier
    env_name: []const u8,
    project_dir: []const u8,
    description: ?[]const u8 = null,
    target_machines_str: []const u8, // Renamed: String representation stored in registry
    venv_path: []const u8, // Absolute path to the virtual environment directory

    pub fn deinit(self: *RegistryEntry, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.env_name);
        allocator.free(self.project_dir);
        if (self.description) |desc| {
            allocator.free(desc);
        }
        allocator.free(self.target_machines_str); // Renamed
        allocator.free(self.venv_path); // Free new field
    }
};

// Global registry of environments
/// Generates a SHA-1 based ID for an environment using its name, project directory, and target machine
/// Adds a timestamp to ensure uniqueness even if the other parameters are identical
fn generateSHA1ID(allocator: Allocator, env_name: []const u8, project_dir: []const u8, target_machines_str: []const u8) ![]const u8 {
    // Create a SHA-1 hasher
    var sha1 = std.crypto.hash.Sha1.init(.{});

    // Add uniqueness factors to the hash
    sha1.update(env_name);
    sha1.update(project_dir);
    sha1.update(target_machines_str); // Use the string representation for ID consistency

    // Add a timestamp for additional uniqueness
    var timestamp_buf: [20]u8 = undefined;
    const timestamp_str = try std.fmt.bufPrint(&timestamp_buf, "{d}", .{std.time.milliTimestamp()});
    sha1.update(timestamp_str);

    // Finalize the hash
    var hash: [20]u8 = undefined; // SHA-1 produces a 20-byte hash
    sha1.final(&hash);

    // Convert to hex string (40 characters)
    var hex_buf: [40]u8 = undefined;
    const hex_chars = "0123456789abcdef";

    for (hash, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 15];
    }

    return try allocator.dupe(u8, &hex_buf);
}
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
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    // Load registry from file, creating it if it doesn't exist
    pub fn load(allocator: Allocator) !EnvironmentRegistry {
        var registry = EnvironmentRegistry.init(allocator);
        errdefer registry.deinit();

        // Determine home directory
        const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
            std.log.err("Failed to get HOME environment variable: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(home_dir);

        // Ensure .zenv directory exists
        const zenv_dir_path = try std.fmt.allocPrint(allocator, "{s}/.zenv", .{home_dir});
        defer allocator.free(zenv_dir_path);

        std.fs.makeDirAbsolute(zenv_dir_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.log.err("Failed to create .zenv directory: {s}", .{@errorName(err)});
                return err;
            }
        };

        // Construct registry file path
        const registry_path = try std.fmt.allocPrint(allocator, "{s}/registry.json", .{zenv_dir_path});
        defer allocator.free(registry_path);

        // Try to open the registry file
        const file = std.fs.openFileAbsolute(registry_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // Registry doesn't exist yet, create an empty one
                try registry.save();
                return registry;
            }
            std.log.err("Failed to open registry file: {s}", .{@errorName(err)});
            return err;
        };
        defer file.close();

        // Read file contents
        const file_content = file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch |err| {
            std.log.err("Failed to read registry file: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(file_content);

        // Parse JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, file_content, .{}) catch |err| {
            std.log.err("Failed to parse registry JSON: {s}", .{@errorName(err)});
            return err;
        };
        defer parsed.deinit();

        // Process entries
        const root = parsed.value;
        if (root.object.get("environments")) |environments| {
            if (environments != .array) {
                std.log.err("Expected 'environments' to be an array, found {s}", .{@tagName(environments)});
                return error.InvalidRegistryFormat;
            }

            for (environments.array.items) |entry_value| {
                if (entry_value != .object) {
                    std.log.err("Expected environment entry to be an object", .{});
                    continue;
                }

                const entry_obj = entry_value.object;

                // Extract required fields
                const env_name = entry_obj.get("name") orelse {
                    std.log.err("Missing 'name' field in environment entry", .{});
                    continue;
                };
                if (env_name != .string) {
                    std.log.err("Expected 'name' to be a string", .{});
                    continue;
                }

                const project_dir = entry_obj.get("project_dir") orelse {
                    std.log.err("Missing 'project_dir' field in environment entry", .{});
                    continue;
                };
                if (project_dir != .string) {
                    std.log.err("Expected 'project_dir' to be a string", .{});
                    continue;
                }

                const target_machines_str = entry_obj.get("target_machine") orelse { // Still reads old field name for compatibility
                    std.log.err("Missing 'target_machine' field in environment entry", .{});
                    continue;
                };
                if (target_machines_str != .string) {
                    std.log.err("Expected 'target_machine' to be a string", .{});
                    continue;
                }

                // Extract optional description field
                var description: ?[]const u8 = null;
                if (entry_obj.get("description")) |desc_value| {
                    if (desc_value == .string) {
                        description = try allocator.dupe(u8, desc_value.string);
                    }
                }

                // Check for ID or generate one if not present (backward compatibility)
                var id_owned: []const u8 = undefined;
                if (entry_obj.get("id")) |id_value| {
                    if (id_value == .string) { // Use value type check (no dereference needed)
                        id_owned = try allocator.dupe(u8, id_value.string);
                    } else {
                        id_owned = try generateSHA1ID(allocator, env_name.string, project_dir.string, target_machines_str.string);
                        std.log.info("Generated new SHA-1 ID for environment with invalid ID type: {s}", .{env_name.string});
                    }
                } else {
                    id_owned = try generateSHA1ID(allocator, env_name.string, project_dir.string, target_machines_str.string);
                    std.log.info("Generated new SHA-1 ID for existing environment: {s}", .{env_name.string});
                }
                errdefer allocator.free(id_owned); // Free ID if adding entry fails

                // Get venv_path or reconstruct for backward compatibility
                var venv_path_owned: []const u8 = undefined;
                var venv_path_found_or_reconstructed = false;
                if (entry_obj.get("venv_path")) |venv_path_val| {
                    if (venv_path_val == .string) { // Check value type (no dereference needed)
                        venv_path_owned = try allocator.dupe(u8, venv_path_val.string);
                        venv_path_found_or_reconstructed = true;
                    } else {
                        std.log.warn("Registry entry for '{s}' has invalid 'venv_path' type, reconstructing...", .{env_name.string});
                        // Fall through to reconstruction
                    }
                } else {
                     std.log.info("Registry entry for '{s}' missing 'venv_path', reconstructing assuming default 'zenv' base...", .{env_name.string});
                     // Fall through to reconstruction
                }

                // Reconstruction logic (if needed)
                if (!venv_path_found_or_reconstructed) {
                    std.log.info("Attempting to reconstruct venv_path for '{s}' assuming default 'zenv' base...", .{env_name.string});
                    // Assume default base "zenv"
                    venv_path_owned = std.fs.path.join(allocator, &[_][]const u8{
                        project_dir.string, // Use the string directly from JSON
                        "zenv",
                        env_name.string, // Use the string directly from JSON
                    }) catch |err| {
                         std.log.err("Failed to reconstruct venv_path for '{s}': {s}", .{env_name.string, @errorName(err)});
                         continue; // Skip this entry if reconstruction fails
                    };
                    venv_path_found_or_reconstructed = true; // Mark as successful
                }
                // Free venv_path if appending fails (ownership isn't transferred)
                errdefer allocator.free(venv_path_owned);

                // Create entry (strings are duplicated for ownership by entry)
                try registry.entries.append(.{
                    .id = id_owned, // Ownership transferred
                    .env_name = try allocator.dupe(u8, env_name.string),
                    .project_dir = try allocator.dupe(u8, project_dir.string),
                    .description = description, // Already duplicated or null
                    .target_machines_str = try allocator.dupe(u8, target_machines_str.string),
                    .venv_path = venv_path_owned, // Ownership transferred
                });
            }
        }

        return registry;
    }

    // Save registry to file
    pub fn save(self: *const EnvironmentRegistry) !void {
        // Determine home directory
        const home_dir = std.process.getEnvVarOwned(self.allocator, "HOME") catch |err| {
            std.log.err("Failed to get HOME environment variable: {s}", .{@errorName(err)});
            return err;
        };
        defer self.allocator.free(home_dir);

        // Ensure .zenv directory exists
        const zenv_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/.zenv", .{home_dir});
        defer self.allocator.free(zenv_dir_path);

        std.fs.makeDirAbsolute(zenv_dir_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.log.err("Failed to create .zenv directory: {s}", .{@errorName(err)});
                return err;
            }
        };

        // Construct registry file path
        const registry_path = try std.fmt.allocPrint(self.allocator, "{s}/registry.json", .{zenv_dir_path});
        defer self.allocator.free(registry_path);

        // Create root object with environments array
        var root = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer root.object.deinit();

        // Create environments array
        var environments = std.json.Value{ .array = std.json.Array.init(self.allocator) };
        defer environments.array.deinit();

        // Add each entry to the environments array
        for (self.entries.items) |entry| {
            var entry_obj = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };

            // Add required fields
            try entry_obj.object.put("id", std.json.Value{ .string = entry.id });
            try entry_obj.object.put("name", std.json.Value{ .string = entry.env_name });
            try entry_obj.object.put("project_dir", std.json.Value{ .string = entry.project_dir });
            try entry_obj.object.put("target_machine", std.json.Value{ .string = entry.target_machines_str }); // Reads/writes old key for now
            try entry_obj.object.put("venv_path", std.json.Value{ .string = entry.venv_path }); // Add new field

            // Add optional description field
            if (entry.description) |desc| {
                try entry_obj.object.put("description", std.json.Value{ .string = desc });
            }

            // Add to environments array
            try environments.array.append(entry_obj);
        }

        // Add environments array to root object
        try root.object.put("environments", environments);

        // Convert to JSON string
        const json_string = try std.json.stringifyAlloc(self.allocator, root, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_string);

        // Write to file
        const file = try std.fs.createFileAbsolute(registry_path, .{});
        defer file.close();

        try file.writeAll(json_string);
    }

    // Register a new environment
    pub fn register(self: *EnvironmentRegistry, env_name: []const u8, project_dir: []const u8, base_dir: []const u8, description: ?[]const u8, target_machines: []const []const u8) !void {
        // For registry purposes, create a single string representation of target machines
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
        // We need to free this string later if it's not used to update an entry
        errdefer self.allocator.free(registry_target_machines_str);

        // Calculate the absolute venv_path
        var venv_path: []const u8 = undefined;
        if (std.fs.path.isAbsolute(base_dir)) {
            // For absolute base_dir, join directly with env_name
            venv_path = try std.fs.path.join(self.allocator, &[_][]const u8{base_dir, env_name});
        } else {
            // For relative base_dir, join with project_dir first
            venv_path = try std.fs.path.join(self.allocator, &[_][]const u8{project_dir, base_dir, env_name});
        }
        // Free this path later if not used to update/create an entry
        errdefer self.allocator.free(venv_path);

        // Check if environment already exists
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.env_name, env_name)) {
                // Update existing entry
                self.allocator.free(entry.project_dir);
                entry.project_dir = try self.allocator.dupe(u8, project_dir);

                if (entry.description) |desc| {
                    self.allocator.free(desc);
                }
                entry.description = if (description) |desc| try self.allocator.dupe(u8, desc) else null;

                // Free the old target machine string and assign the new one
                self.allocator.free(entry.target_machines_str); // Renamed field
                entry.target_machines_str = registry_target_machines_str; // Assign ownership

                // Free the old venv_path and assign the new one
                self.allocator.free(entry.venv_path);
                entry.venv_path = venv_path; // Assign ownership

                // Ownership transferred, so no need to free later
                return; // Successfully updated
            }
        }

        // If the environment doesn't exist, create a new entry
        // Generate a SHA-1 ID for the new entry using the registry string
        const id = try generateSHA1ID(self.allocator, env_name, project_dir, registry_target_machines_str);
        errdefer self.allocator.free(id); // Free ID if appending fails

        // Add new entry (transfer ownership of strings)
        try self.entries.append(.{
            .id = id,
            .env_name = try self.allocator.dupe(u8, env_name),
            .project_dir = try self.allocator.dupe(u8, project_dir),
            .description = if (description) |desc| try self.allocator.dupe(u8, desc) else null,
            .target_machines_str = registry_target_machines_str, // Renamed field, ownership transferred
            .venv_path = venv_path, // Ownership transferred
        });
    }

    // Unregister an environment
    /// Removes an environment from the registry based on name or ID.
    /// Returns true if the environment was successfully removed, false otherwise.
    ///
    /// Params:
    ///   - identifier: The environment name or ID (can be a partial ID if long enough)
    ///
    /// Returns: Whether the environment was successfully removed
    pub fn deregister(self: *EnvironmentRegistry, identifier: []const u8) bool {
        // Try to look up the entry first using our existing method which handles IDs
        if (self.lookup(identifier)) |entry| {
            // We found an entry, now find its index
            for (self.entries.items, 0..) |reg_entry, i| {
                if (std.mem.eql(u8, reg_entry.env_name, entry.env_name)) {
                    // Free memory for the removed entry
                    var removed_entry = self.entries.orderedRemove(i);
                    removed_entry.deinit(self.allocator);
                    return true;
                }
            }
        }
        return false;
    }

    // Look up an environment by name
    pub fn lookup(self: *const EnvironmentRegistry, identifier: []const u8) ?RegistryEntry {
        // First try exact match (for names and full IDs)
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.env_name, identifier) or std.mem.eql(u8, entry.id, identifier)) {
                return entry;
            }
        }

        // If no exact match, try partial ID matching (if identifier is at least 7 chars)
        // SHA-1 IDs are 40 chars, so 7 should be enough to be unique in most cases
        if (identifier.len >= 7) {
            var matching_entry: ?RegistryEntry = null;
            var match_count: usize = 0;

            for (self.entries.items) |entry| {
                // Check if the identifier is a prefix of entry's ID
                if (entry.id.len >= identifier.len and std.mem.eql(u8, entry.id[0..identifier.len], identifier)) {
                    matching_entry = entry;
                    match_count += 1;
                }
            }

            // If exactly one match found, return it
            if (match_count == 1) {
                return matching_entry;
            } else if (match_count > 1) {
                // If multiple matches, log ambiguity but don't return anything
                std.log.err("Ambiguous ID prefix '{s}' matches multiple environments", .{identifier});
            }
        }

        return null;
    }
};

// Add required field validation at compile-time
const REQUIRED_ENV_FIELDS = [_][]const u8{
    "target_machines", // Updated from target_machine
    "python_executable",
};

// Validate that an environment has all required fields
pub fn validateRequiredFields(env_obj: Json.ObjectMap, env_name: []const u8) !void {
    inline for (REQUIRED_ENV_FIELDS) |field| {
        if (env_obj.get(field) == null) {
            std.log.err("Missing required field '{s}' in environment '{s}'", .{ field, env_name });
            return error.ConfigInvalid;
        }
    }
}

// Helper function to parse an optional string array field
fn parseOptionalStringArray(list_ptr: *?ArrayList([]const u8), v: *const Json.Value, field_name: []const u8, env_name: []const u8, allocator: Allocator) !void {
    if (v.* == .null) { // Dereference pointer
        list_ptr.* = null; // Explicitly set to null
        return;
    }
    if (v.* != .array) { // Dereference pointer
        std.log.err("Expected array or null for field '{s}' in environment '{s}', found {s}", .{ field_name, env_name, @tagName(v.*) });
        return error.ConfigInvalid;
    }
    // If it's an array, initialize the optional list if it's null
    if (list_ptr.* == null) {
        list_ptr.* = ArrayList([]const u8).init(allocator);
    }
    var list = list_ptr.*.?; // Get the initialized list
    // ensureTotalCapacity uses the list's allocator implicitly
    try list.ensureTotalCapacity(v.array.items.len);
    for (v.array.items) |item_val| { // Use different var name
        const item = &item_val; // Take address if needed by called funcs, or use directly
        if (item.* != .string) { // Dereference pointer
            std.log.err("Expected string elements in array '{s}' for environment '{s}'", .{ field_name, env_name });
            // Clean up partially filled list if needed
            if (list_ptr.*) |*l| l.deinit();
            list_ptr.* = null;
            return error.ConfigInvalid;
        }
        // Append slice directly
        // Use try allocator.dupe(u8, item.string) if copying is needed
        list.appendAssumeCapacity(item.string);
    }
}

// Represents the configuration for a single named environment
// Specific type for module information
pub const Module = struct {
    name: []const u8,
    version: ?[]const u8 = null,

    pub fn format(self: Module, writer: anytype) !void {
        if (self.version) |ver| {
            try writer.print("{s}/{s}", .{ self.name, ver });
        } else {
            try writer.print("{s}", .{self.name});
        }
    }

    pub fn parse(allocator: Allocator, module_string: []const u8) !Module {
        // Check for version specification like "name/version"
        if (std.mem.indexOf(u8, module_string, "/")) |slash_idx| {
            const name = try allocator.dupe(u8, module_string[0..slash_idx]);
            const version = try allocator.dupe(u8, module_string[slash_idx + 1 ..]);
            return Module{ .name = name, .version = version };
        } else {
            const name = try allocator.dupe(u8, module_string);
            return Module{ .name = name };
        }
    }

    pub fn deinit(self: *Module, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.version) |ver| {
            allocator.free(ver);
            self.version = null;
        }
    }
};

// Specific type for dependency information
pub const Dependency = struct {
    name: []const u8,
    version_constraint: ?[]const u8 = null,

    pub fn format(self: Dependency, writer: anytype) !void {
        if (self.version_constraint) |vc| {
            try writer.print("{s}{s}", .{ self.name, vc });
        } else {
            try writer.print("{s}", .{self.name});
        }
    }

    pub fn parse(allocator: Allocator, dep_string: []const u8) !Dependency {
        // Find first version operator (>=, ==, <=, >, <, ~=, etc)
        // We could add an enhanced parser here eventually, but for now do a simple split
        for (dep_string, 0..) |c, i| {
            if (c == '>' or c == '<' or c == '=' or c == '~') {
                const name = try allocator.dupe(u8, std.mem.trim(u8, dep_string[0..i], " \t"));
                const ver_constraint = try allocator.dupe(u8, dep_string[i..]);
                return Dependency{ .name = name, .version_constraint = ver_constraint };
            }
        }

        // No version constraint found
        const name = try allocator.dupe(u8, dep_string);
        return Dependency{ .name = name };
    }

    pub fn deinit(self: *Dependency, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.version_constraint) |vc| {
            allocator.free(vc);
            self.version_constraint = null;
        }
    }
};

pub const EnvironmentConfig = struct {
    target_machines: ArrayList([]const u8), // Updated to array format
    description: ?[]const u8 = null,
    modules: ArrayList([]const u8),
    requirements_file: ?[]const u8 = null,
    dependencies: ArrayList([]const u8),
    python_executable: []const u8,
    custom_activate_vars: StringHashMap([]const u8),
    setup_commands: ?ArrayList([]const u8) = null, // Optional list of commands

    // Initialize ArrayLists and HashMap
    pub fn init(allocator: Allocator) EnvironmentConfig {
        return EnvironmentConfig{
            // Initialize fields that need it
            .target_machines = ArrayList([]const u8).init(allocator),
            .python_executable = undefined, // Will be assigned during parsing
            .modules = ArrayList([]const u8).init(allocator),
            .dependencies = ArrayList([]const u8).init(allocator),
            .custom_activate_vars = StringHashMap([]const u8).init(allocator),
            // Optional fields start as null
            .description = null,
            .requirements_file = null,
            .setup_commands = null,
        };
    }

    // Deinitialize allocated memory within the struct
    pub fn deinit(self: *EnvironmentConfig) void {
        // Free strings owned by the struct IF they were copied using allocator.dupe
        // during parsing. Current implementation uses slices, so these are commented out.

        // Free individual target machines IF they were duped
        // for (self.target_machines.items) |machine| allocator.free(machine);
        self.target_machines.deinit();

        // Free python_executable IF duped
        // allocator.free(self.python_executable);

        // Free description IF duped
        // if (self.description) |d| allocator.free(d);

        // Free requirements_file IF duped
        // if (self.requirements_file) |f| allocator.free(f);

        // Deinitialize module ArrayList
        // Free individual modules IF they were duped
        // for (self.modules.items) |item| allocator.free(item);
        self.modules.deinit();

        // Deinitialize dependency ArrayList
        // Free individual dependencies IF they were duped
        // for (self.dependencies.items) |item| allocator.free(item);
        self.dependencies.deinit();

        // Deinitialize HashMap
        var iter = self.custom_activate_vars.iterator();
        while (iter.next()) |entry| {
            // Free keys/values IF they were duped during parsing
            // allocator.free(entry.key_ptr.*);
            // allocator.free(entry.value_ptr.*);
            _ = entry; // Avoid unused var warning if not freeing
        }
        self.custom_activate_vars.deinit();

        // Deinitialize optional setup_commands ArrayList
        if (self.setup_commands) |*commands_list| {
            // Free individual commands IF they were duped during parsing
            // for (commands_list.items) |cmd| allocator.free(cmd);
            commands_list.deinit();
        }
    }
};

// Main configuration structure holding all environments
pub const ZenvConfig = struct {
    allocator: Allocator,
    // Map from environment name (e.g., "pytorch-gpu-jureca") to its config
    environments: StringHashMap(EnvironmentConfig),
    // Store the parsed value tree to manage its lifetime
    value_tree: Json.Parsed(Json.Value), // Explicit type needed here
    // Base directory for virtual environments (relative to project)
    base_dir: []const u8, // Default is "zenv"
    // Cache the hostname to avoid repeated lookups
    cached_hostname: ?[]const u8 = null,

    // Parses the zenv.json file
    pub fn parse(allocator: Allocator, config_path: []const u8) !ZenvConfig {
        const file = fs.cwd().openFile(config_path, .{}) catch |err| {
            std.log.err("Failed to open config file '{s}': {s}", .{ config_path, @errorName(err) });
            return error.ConfigFileNotFound;
        };
        defer file.close();

        const json_string = file.readToEndAlloc(allocator, 1 * 1024 * 1024) catch |err| { // Limit size
            std.log.err("Failed to read config file '{s}': {s}", .{ config_path, @errorName(err) });
            // Return error directly
            return error.ConfigFileReadError;
        };
        defer allocator.free(json_string);

        // Parse using parseFromSlice
        const value_tree = std.json.parseFromSlice(Json.Value, allocator, json_string, .{}) catch |err| {
            std.log.err("Failed to parse JSON from '{s}': {s}", .{ config_path, @errorName(err) });
            std.debug.print("JSON parsing error: {any}\n", .{err});
            return error.JsonParseError;
        };
        // IMPORTANT: Defer destroy/deinit only AFTER ZenvConfig is fully used and deinitialized
        // because EnvironmentConfig currently holds slices into the value_tree's data.
        // If EnvironmentConfig owned copies (using allocator.dupe), this defer could be here.

        const root = value_tree.value;
        if (root != .object) { // Check union variant tag (lowercase)
            std.log.err("Expected root JSON element to be an Object in '{s}'", .{config_path});
            value_tree.deinit(); // Use deinit without allocator
            return error.ConfigInvalid;
        }

        var config = ZenvConfig{
            .allocator = allocator,
            .environments = StringHashMap(EnvironmentConfig).init(allocator),
            .value_tree = value_tree, // Store the tree to manage its lifetime
            .base_dir = undefined, // Initialize, will be set below
        };
        errdefer config.deinit(); // Ensure cleanup on error during parsing loop

        // Parse top-level base_dir first
        if (root.object.get("base_dir")) |base_dir_val_ptr| {
            if (base_dir_val_ptr == .string) { // No dereference needed
                // Duplicate the string for ownership
                config.base_dir = try allocator.dupe(u8, base_dir_val_ptr.string);
            } else if (base_dir_val_ptr == .null) { // No dereference needed
                 std.log.info("'base_dir' is null, using default 'zenv'", .{});
                 config.base_dir = try allocator.dupe(u8, "zenv"); // Default
            } else {
                std.log.warn("Ignoring non-string value for 'base_dir', using default 'zenv'", .{});
                config.base_dir = try allocator.dupe(u8, "zenv"); // Default
            }
        } else {
            // If field doesn't exist, use default
            std.log.info("'base_dir' not found, using default 'zenv'", .{});
            config.base_dir = try allocator.dupe(u8, "zenv");
        }

        // Log if base_dir is an absolute path
        if (std.fs.path.isAbsolute(config.base_dir)) {
            std.log.info("Using absolute path for virtual environment base directory: {s}", .{config.base_dir});
        } else {
            errors.debugLog(allocator, "Using relative virtual environment base directory: {s}", .{config.base_dir});
        }

        var env_map_iter = root.object.iterator(); // Access the iterator via the .object payload
        while (env_map_iter.next()) |entry| {
            const env_name = entry.key_ptr.*; // Use pointer
            const env_obj_ptr = entry.value_ptr; // Value is already a pointer

            // Skip known top-level configuration keys (like base_dir)
            if (std.mem.eql(u8, env_name, "base_dir")) {
                continue; // Skip base_dir, it's already handled
            }

            if (env_obj_ptr.* != .object) { // Dereference pointer
                std.log.warn("Skipping non-object value for environment '{s}' in '{s}'", .{ env_name, config_path });
                continue;
            }
            const env_obj = env_obj_ptr.object; // Get the actual object map

            // Validate required fields at compile time before parsing
            validateRequiredFields(env_obj, env_name) catch {
                std.log.err("Environment '{s}' is missing required fields", .{env_name});
                continue; // Skip this environment if it's missing required fields
            };

            var env_config = EnvironmentConfig.init(allocator);
            // If parsing this entry fails, ensure its partially allocated fields are cleaned up
            errdefer env_config.deinit(); // No allocator needed now

            var env_data_iter = env_obj.iterator(); // Iterate the inner object map
            var success = true; // Flag to track if parsing this entry works

            while (env_data_iter.next()) |field| {
                const key = field.key_ptr.*; // Use pointer
                const value_ptr = field.value_ptr; // Value is already pointer

                if (std.mem.eql(u8, key, "target_machines")) { // Updated field name here
                    // Handle both string and array formats for backward compatibility
                    if (value_ptr.* == .string) {
                        // For backward compatibility: Single string target
                        const target = parseRequiredString(allocator, value_ptr, key, env_name) catch |e| {
                            debugParseError(allocator, key, env_name, e);
                            success = false;
                            continue;
                        };
                        try env_config.target_machines.append(target);
                    } else if (value_ptr.* == .array) {
                        // New format: Array of target machines
                        for (value_ptr.array.items) |target_item_val| {
                            const target_item = &target_item_val;
                            if (target_item.* != .string) {
                                std.log.err("Expected string elements in target_machine array for environment '{s}'", .{env_name});
                                success = false;
                                continue;
                            }
                            const target = try allocator.dupe(u8, target_item.string);
                            try env_config.target_machines.append(target);
                        }
                    } else {
                        std.log.err("Expected string or array for field '{s}' in environment '{s}', found {s}", .{ key, env_name, @tagName(value_ptr.*) });
                        success = false;
                        continue;
                    }
                } else if (std.mem.eql(u8, key, "description")) {
                    env_config.description = parseOptionalString(allocator, value_ptr, key, env_name) catch |e| {
                        debugParseError(allocator, key, env_name, e);
                        success = false;
                        continue;
                    };
                } else if (std.mem.eql(u8, key, "modules")) {
                    // Pass allocator explicitly for parseStringArray
                    parseStringArray(allocator, &env_config.modules, value_ptr, key, env_name) catch |e| {
                        debugParseError(allocator, key, env_name, e);
                        success = false;
                        continue;
                    };
                } else if (std.mem.eql(u8, key, "requirements_file")) {
                    env_config.requirements_file = parseOptionalString(allocator, value_ptr, key, env_name) catch |e| {
                        debugParseError(allocator, key, env_name, e);
                        success = false;
                        continue;
                    };
                } else if (std.mem.eql(u8, key, "dependencies")) {
                    // Pass allocator explicitly for parseStringArray
                    parseStringArray(allocator, &env_config.dependencies, value_ptr, key, env_name) catch |e| {
                        debugParseError(allocator, key, env_name, e);
                        success = false;
                        continue;
                    };
                } else if (std.mem.eql(u8, key, "python_executable")) {
                    env_config.python_executable = parseRequiredString(allocator, value_ptr, key, env_name) catch |e| {
                        debugParseError(allocator, key, env_name, e);
                        success = false;
                        continue;
                    };
                    // Removed: if (env_config.python_executable == undefined) success = false;
                } else if (std.mem.eql(u8, key, "custom_activate_vars")) {
                    if (value_ptr.* != .object) { // Dereference pointer
                        std.log.err("Expected object for field 'custom_activate_vars' in environment '{s}'", .{env_name});
                        success = false;
                        continue;
                    }
                    var vars_iter = value_ptr.object.iterator(); // Iterate inner object
                    while (vars_iter.next()) |var_entry| {
                        const var_key = var_entry.key_ptr.*; // Use pointer
                        const var_value_ptr = var_entry.value_ptr; // Value is already pointer
                        if (var_value_ptr.* != .string) { // Dereference pointer
                            std.log.warn("Skipping non-string value for activation variable '{s}' in environment '{s}'", .{ var_key, env_name });
                            continue;
                        }
                        // Store slices directly. Use allocator.dupe if copies are needed.
                        // Use try without catch; errdefer in parse() handles cleanup on OOM.
                        try env_config.custom_activate_vars.put(var_key, var_value_ptr.string);
                    }
                    // Removed unnecessary check: if (!success) continue;
                } else if (std.mem.eql(u8, key, "setup_commands")) {
                    parseOptionalStringArray(&env_config.setup_commands, value_ptr, key, env_name, allocator) catch |e| {
                        debugParseError(allocator, key, env_name, e);
                        success = false;
                        continue;
                    };
                } else {
                    std.log.warn("Ignoring unknown field '{s}' in environment '{s}'", .{ key, env_name });
                }
            }

            // Basic validation: Rely on the 'success' flag determined during field parsing.
            if (!success) {
                // Don't log here again, previous parsing function would have logged.
                // Just clean up and skip this environment.
                std.log.err("Skipping environment '{s}' due to parsing errors.", .{env_name});
                env_config.deinit(); // No allocator needed now
                continue; // Skip putting this entry into the map
            }

            // If success is true, we assume all required fields were parsed without error.
            // Note: The original `if (success)` check was technically redundant here
            // because of the `continue` in the `if (!success)` block above.
            // Store the successfully parsed config. Use allocator.dupe for env_name if copy needed.
            try config.environments.put(env_name, env_config);
            // No else needed here, cleanup is handled by errdefer if put fails,
            // or by the continue above if success was false.
        }

        // Check if any environments were successfully parsed
        // Note: Changed the condition slightly to handle empty root object gracefully
        if (config.environments.count() == 0 and root == .object and root.object.count() > 0) {
            std.log.err("No valid environment configurations found in '{s}'", .{config_path});
            // config.deinit() will be called by the higher level defer or errdefer
            return error.ConfigInvalid;
        }

        return config;
    }

    // Deinitialize the entire config structure
    pub fn deinit(self: *ZenvConfig) void {
        var iter = self.environments.iterator();
        while (iter.next()) |entry| {
            // Key was likely referenced from JSON string, no need to free unless copied
            // If key was copied: self.allocator.free(entry.key_ptr.*); // Adjusted comment
            entry.value_ptr.deinit(); // No allocator needed now
        }
        self.environments.deinit();

        // Now that all references to the value tree are gone, deinit it.
        self.value_tree.deinit(); // Use deinit without allocator

        // Free the base_dir string
        self.allocator.free(self.base_dir);

        // Free the cached hostname if one exists using optional chaining
        if (self.cached_hostname) |hostname| {
            self.allocator.free(hostname);
            self.cached_hostname = null;
        }

        // Note: We don't own the allocator itself, so we don't deinit it here.
    }

    // Helper to get an environment config by name
    pub fn getEnvironment(self: *const ZenvConfig, env_name: []const u8) ?*const EnvironmentConfig {
        return self.environments.getPtr(env_name);
    }

    // Validate environment configuration fields for correctness
    pub fn validateEnvironment(env_config: *const EnvironmentConfig, env_name: []const u8) ?ZenvError {
        _ = env_name; // env_name no longer needed for context
        // Check target_machines (required)
        if (env_config.target_machines.items.len == 0) {
            return ZenvError.ConfigInvalid;
        }

        // Check python_executable (required)
        if (env_config.python_executable.len == 0) {
            return ZenvError.MissingPythonExecutable;
        }

        // All validation passed
        return null;
    }

    // Helper to get the current machine's hostname
    // Uses cached value if available
    pub fn getHostname(self: *const ZenvConfig) ![]const u8 {
        // If we've already cached the hostname, return it using optional chaining
        if (self.cached_hostname) |cached| {
            // Return a duplicate so the caller owns it and can free it
            return try self.allocator.dupe(u8, cached);
        }

        // For non-const self, need to cast to get mutable access
        var mutable_self = @constCast(self);

        // Get hostname using the utility function with better error handling
        const hostname = environment.getSystemHostname(mutable_self.allocator) catch |err| {
            return errors.logAndReturn(err, "Failed to get system hostname: {s}", .{@errorName(err)});
        };
        errdefer mutable_self.allocator.free(hostname); // Free if caching fails

        // Cache the result (we need to dupe it again for the cache)
        mutable_self.cached_hostname = try mutable_self.allocator.dupe(u8, hostname);

        // Return the initially retrieved hostname (caller owns this copy)
        return hostname;
    }
};
