const std = @import("std");
const Allocator = std.mem.Allocator;
const Json = std.json;
const fs = std.fs;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const ZenvErrorWithContext = errors.ZenvErrorWithContext;
const ErrorContext = errors.ErrorContext;

// Helper function to parse a required string field
fn parseRequiredString(allocator: Allocator, v: *const Json.Value, field_name: []const u8, env_name: []const u8) ![]const u8 {
    if (v.* != .string) { // Dereference pointer for comparison
        std.log.err("Expected string for field '{s}' in environment '{s}', found {s}", .{ field_name, env_name, @tagName(v.*) });
        return error.ConfigInvalid;
    }
    // Duplicate the string to ensure we own the memory
    return try allocator.dupe(u8, v.string);
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

// Add required field validation at compile-time
const REQUIRED_ENV_FIELDS = [_][]const u8{
    "target_machine", 
    "python_executable"
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

// Helper function to get hostname using the `hostname` command
fn getHostnameFromCommand(allocator: Allocator) ![]const u8 {
    std.log.debug("Executing 'hostname' command", .{});
    const argv = [_][]const u8{"hostname"};
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe; // Capture stderr as well
    try child.spawn();

    const stdout = child.stdout.?.readToEndAlloc(allocator, 128) // Limit size for hostname
        catch |err| {
            std.log.err("Failed to read stdout from `hostname` command: {s}", .{@errorName(err)});
            _ = child.wait() catch {}; // Ensure child process is waited on
            return error.ProcessError;
        };
    errdefer allocator.free(stdout);

    const stderr = child.stderr.?.readToEndAlloc(allocator, 512) // Limit stderr size
        catch |err| {
            std.log.err("Failed to read stderr from `hostname` command: {s}", .{@errorName(err)});
            _ = child.wait() catch {};
            return error.ProcessError;
        };
    defer allocator.free(stderr);

    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        std.log.err("`hostname` command failed. Term: {?} Stderr: {s}", .{ term, stderr });
        return error.ProcessError;
    }

    const trimmed_hostname = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (trimmed_hostname.len == 0) {
        std.log.err("`hostname` command returned empty output.", .{});
        return error.MissingHostname;
    }
    std.log.debug("Got hostname from command: '{s}'", .{trimmed_hostname});
    // Return a duplicate of the trimmed hostname
    return allocator.dupe(u8, trimmed_hostname);
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
            const version = try allocator.dupe(u8, module_string[slash_idx + 1..]);
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
    target_machine: []const u8,
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
            .target_machine = undefined, // Will be assigned during parsing
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
    pub fn deinit(self: *EnvironmentConfig) void { // Removed allocator param
        // Free strings owned by the struct only if they were copied (they are not in current impl)
        // If using allocator.dupe in parsing, uncomment these:
        // allocator.free(self.target_machine);
        // allocator.free(self.python_executable);
        // if (self.description) |d| allocator.free(d);
        // if (self.requirements_file) |f| allocator.free(f);

        // Deinitialize ArrayLists
        // Items are slices, no need to free individually if not duped
        // If using allocator.dupe in parsing, uncomment the inner free calls:
        // for (self.modules.items) |item| allocator.free(item);
        self.modules.deinit();
        // for (self.dependencies.items) |item| allocator.free(item);
        self.dependencies.deinit();

        // Deinitialize HashMap
        var iter = self.custom_activate_vars.iterator();
        while (iter.next()) |entry| {
            // Free keys/values only if duped during parsing
            // allocator.free(entry.key_ptr.*);
            // allocator.free(entry.value_ptr.*);
            _ = entry; // Avoid unused var warning if not freeing
        }
        self.custom_activate_vars.deinit();

        // Deinitialize optional setup_commands ArrayList
        if (self.setup_commands) |*commands_list| {
            // Free items only if duped during parsing
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
        };
        errdefer config.deinit(); // Ensure cleanup on error during parsing loop

        var env_map_iter = root.object.iterator(); // Access the iterator via the .object payload
        while (env_map_iter.next()) |entry| {
            const env_name = entry.key_ptr.*; // Use pointer
            const env_obj_ptr = entry.value_ptr; // Value is already a pointer

            if (env_obj_ptr.* != .object) { // Dereference pointer
                std.log.warn("Skipping non-object value for environment '{s}' in '{s}'", .{ env_name, config_path });
                continue;
            }
            const env_obj = env_obj_ptr.object; // Get the actual object map
            
            // Validate required fields at compile time before parsing
            validateRequiredFields(env_obj, env_name) catch {
                std.log.err("Environment '{s}' is missing required fields", .{env_name});
                continue;  // Skip this environment if it's missing required fields
            };

            var env_config = EnvironmentConfig.init(allocator);
            // If parsing this entry fails, ensure its partially allocated fields are cleaned up
            errdefer env_config.deinit(); // Use updated deinit

            var env_data_iter = env_obj.iterator(); // Iterate the inner object map
            var success = true; // Flag to track if parsing this entry works

            while (env_data_iter.next()) |field| {
                const key = field.key_ptr.*; // Use pointer
                const value_ptr = field.value_ptr; // Value is already pointer

                if (std.mem.eql(u8, key, "target_machine")) {
                    env_config.target_machine = parseRequiredString(allocator, value_ptr, key, env_name) catch |e| {
                        std.log.debug("Parse error on field '{s}': {s}", .{ key, @errorName(e) });
                        success = false;
                        continue;
                    };
                    // Removed: if (env_config.target_machine == undefined) success = false;
                } else if (std.mem.eql(u8, key, "description")) {
                    env_config.description = parseOptionalString(allocator, value_ptr, key, env_name) catch |e| {
                        std.log.debug("Parse error on field '{s}': {s}", .{ key, @errorName(e) });
                        success = false;
                        continue;
                    };
                } else if (std.mem.eql(u8, key, "modules")) {
                    // Pass allocator explicitly for parseStringArray
                    parseStringArray(allocator, &env_config.modules, value_ptr, key, env_name) catch |e| {
                        std.log.debug("Parse error on field '{s}': {s}", .{ key, @errorName(e) });
                        success = false;
                        continue;
                    };
                } else if (std.mem.eql(u8, key, "requirements_file")) {
                    env_config.requirements_file = parseOptionalString(allocator, value_ptr, key, env_name) catch |e| {
                        std.log.debug("Parse error on field '{s}': {s}", .{ key, @errorName(e) });
                        success = false;
                        continue;
                    };
                } else if (std.mem.eql(u8, key, "dependencies")) {
                    // Pass allocator explicitly for parseStringArray
                    parseStringArray(allocator, &env_config.dependencies, value_ptr, key, env_name) catch |e| {
                        std.log.debug("Parse error on field '{s}': {s}", .{ key, @errorName(e) });
                        success = false;
                        continue;
                    };
                } else if (std.mem.eql(u8, key, "python_executable")) {
                    env_config.python_executable = parseRequiredString(allocator, value_ptr, key, env_name) catch |e| {
                        std.log.debug("Parse error on field '{s}': {s}", .{ key, @errorName(e) });
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
                        std.log.debug("Parse error on field '{s}': {s}", .{ key, @errorName(e) });
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
                env_config.deinit(); // Clean up what was allocated for this entry
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
            entry.value_ptr.deinit(); // Deinit the EnvironmentConfig struct (uses updated signature)
        }
        self.environments.deinit();

        // Now that all references to the value tree are gone, deinit it.
        self.value_tree.deinit(); // Use deinit without allocator
        
        // Free the cached hostname if one exists
        if (self.cached_hostname != null) {
            self.allocator.free(self.cached_hostname.?);
            self.cached_hostname = null;
        }

        // Note: We don't own the allocator itself, so we don't deinit it here.
    }

    // Helper to get an environment config by name
    pub fn getEnvironment(self: *const ZenvConfig, env_name: []const u8) ?*const EnvironmentConfig {
        return self.environments.getPtr(env_name);
    }
    
    // Validate environment configuration fields for correctness
    pub fn validateEnvironment(env_config: *const EnvironmentConfig, env_name: []const u8) ?ZenvErrorWithContext {
        // Check target_machine (required)
        if (env_config.target_machine.len == 0) {
            return ZenvErrorWithContext.init(
                ZenvError.ConfigInvalid,
                ErrorContext.environmentName(env_name)
            );
        }
        
        // Check python_executable (required)
        if (env_config.python_executable.len == 0) {
            return ZenvErrorWithContext.init(
                ZenvError.MissingPythonExecutable,
                ErrorContext.environmentName(env_name)
            );
        }
        
        // All validation passed
        return null;
    }

    // Helper to get the current machine's hostname
    // Uses cached value if available
    pub fn getHostname(self: *const ZenvConfig) ![]const u8 {
        // If we've already cached the hostname, return it
        if (self.cached_hostname != null) {
            return self.cached_hostname.?;
        }
        
        // For non-const self, need to cast to get mutable access
        var mutable_self = @constCast(self);
        
        // Using getEnvVarOwned requires freeing the result later
        std.log.debug("Attempting to get hostname from environment variable", .{});
        const hostname = std.process.getEnvVarOwned(mutable_self.allocator, "HOSTNAME") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                // Fallback to `hostname` command if HOSTNAME env var is not set
                std.log.debug("HOSTNAME not set, attempting 'hostname' command.", .{});
                const cmd_hostname = try getHostnameFromCommand(mutable_self.allocator);
                mutable_self.cached_hostname = cmd_hostname;  // Cache the result
                return cmd_hostname;
            }
            std.log.err("Failed to get HOSTNAME environment variable: {s}", .{@errorName(err)});
            return error.MissingHostname;
        };
        // If HOSTNAME is empty, also fallback
        if (hostname.len == 0) {
            std.log.warn("HOSTNAME environment variable is empty, attempting 'hostname' command.", .{});
            mutable_self.allocator.free(hostname); // Free the empty string
            const cmd_hostname = try getHostnameFromCommand(mutable_self.allocator);
            mutable_self.cached_hostname = cmd_hostname;  // Cache the result
            return cmd_hostname;
        }
        std.log.debug("Got hostname: '{s}'", .{hostname});
        mutable_self.cached_hostname = hostname;  // Cache the result
        return hostname;
    }
};
