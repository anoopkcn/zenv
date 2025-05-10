const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const fs = std.fs;
const output = @import("output.zig");
const config_module = @import("config.zig");

/// Represents an error found during validation
pub const ValidationError = struct {
    line: usize,
    column: usize,
    message: []const u8,
    context: ?[]const u8 = null,
    field_path: ?[]const u8 = null,

    pub fn deinit(self: *ValidationError, allocator: Allocator) void {
        allocator.free(self.message);
        if (self.context) |ctx| allocator.free(ctx);
        if (self.field_path) |path| allocator.free(path);
    }
};

/// Validates a JSON configuration file and returns a list of validation errors
/// or null if no errors are found. If validation errors are found, they will
/// be printed to stderr.
pub fn validateConfigFile(allocator: Allocator, file_path: []const u8) !?std.ArrayList(ValidationError) {
    // Try to open the file
    const file = fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            var errors = std.ArrayList(ValidationError).init(allocator);
            try errors.append(ValidationError{
                .line = 0,
                .column = 0,
                .message = try allocator.dupe(u8, "Configuration file not found"),
                .context = try allocator.dupe(u8, file_path),
            });

            // Print the error and return it
            printValidationErrors(errors);
            return errors;
        }
        return err;
    };
    defer file.close();

    // Read the file content
    const file_content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(file_content);

    // Validate the JSON content
    const validation_result = try validateJsonContent(allocator, file_content);

    // If there are validation errors, print them
    if (validation_result != null) {
        printValidationErrors(validation_result.?);
        return validation_result;
    }

    return null;
}

/// Validates JSON content and returns a list of validation errors
pub fn validateJsonContent(allocator: Allocator, content: []const u8) !?std.ArrayList(ValidationError) {
    var errors = std.ArrayList(ValidationError).init(allocator);
    errdefer {
        for (errors.items) |*err| {
            err.deinit(allocator);
        }
        errors.deinit();
    }

    // First, check if the JSON is valid
    var parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch |err| {
        // Create a descriptive error message based on the error name
        const err_name = @errorName(err);
        const err_msg = try std.fmt.allocPrint(allocator, "Invalid JSON syntax: {s}", .{err_name});

        // Find position information
        const position = findErrorPosition(content, err_name) catch Position{ .line = 0, .column = 0 };

        // Get context around the error
        const context = getContextAroundPosition(allocator, content, position.line) catch null;

        try errors.append(ValidationError{
            .line = position.line,
            .column = position.column,
            .message = err_msg,
            .context = context,
            .field_path = "",
        });

        return errors;
    };
    defer parsed.deinit();

    // Now validate the structure of the JSON
    try validateZenvConfig(allocator, &errors, parsed.value, content, "");

    // If there are no errors, return null
    if (errors.items.len == 0) {
        errors.deinit();
        return null;
    }

    return errors;
}

/// Validates the structure of a zenv.json configuration
fn validateZenvConfig(
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
    value: json.Value,
    content: []const u8,
    path: []const u8,
) !void {
    // The root must be an object
    if (value != .object) {
        const position = try findValuePosition(content, value);
        const context = getContextAroundPosition(allocator, content, position.line) catch null;

        try errors.append(ValidationError{
            .line = position.line,
            .column = position.column,
            .message = try allocator.dupe(u8, "Root configuration must be a JSON object"),
            .context = context,
            .field_path = try allocator.dupe(u8, path),
        });
        return;
    }

    // Check for required base_dir field
    if (!value.object.contains("base_dir")) {
        const position = try findObjectPosition(content, value.object);
        const context = getContextAroundPosition(allocator, content, position.line) catch null;

        try errors.append(ValidationError{
            .line = position.line,
            .column = position.column,
            .message = try allocator.dupe(u8, "Missing required 'base_dir' field"),
            .context = context,
            .field_path = try allocator.dupe(u8, path),
        });
    } else {
        const base_dir = value.object.get("base_dir") orelse unreachable;
        if (base_dir != .string) {
            const position = try findValuePosition(content, base_dir);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try allocator.dupe(u8, "'base_dir' must be a string"),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.base_dir", .{path}),
            });
        }
    }

    // Check that we have at least one environment
    var has_envs = false;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "base_dir")) continue;

        has_envs = true;
        // Validate each environment definition
        try validateEnvironment(
            allocator,
            errors,
            entry.value_ptr.*,
            key,
            content,
            if (path.len > 0) try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, key }) else key,
        );
    }

    if (!has_envs) {
        const position = try findObjectPosition(content, value.object);
        const context = getContextAroundPosition(allocator, content, position.line) catch null;

        try errors.append(ValidationError{
            .line = position.line,
            .column = position.column,
            .message = try allocator.dupe(u8, "At least one environment must be defined"),
            .context = context,
            .field_path = try allocator.dupe(u8, path),
        });
    }
}

/// Validates an environment configuration
fn validateEnvironment(
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
    value: json.Value,
    env_name: []const u8,
    content: []const u8,
    path: []const u8,
) !void {
    if (value != .object) {
        const position = try findValuePosition(content, value);
        const context = getContextAroundPosition(allocator, content, position.line) catch null;

        try errors.append(ValidationError{
            .line = position.line,
            .column = position.column,
            .message = try std.fmt.allocPrint(allocator, "Environment '{s}' must be an object", .{env_name}),
            .context = context,
            .field_path = try allocator.dupe(u8, path),
        });
        return;
    }

    // Check for required 'target_machines' field
    if (!value.object.contains("target_machines")) {
        const position = try findObjectPosition(content, value.object);
        const context = getContextAroundPosition(allocator, content, position.line) catch null;

        try errors.append(ValidationError{
            .line = position.line,
            .column = position.column,
            .message = try std.fmt.allocPrint(
                allocator,
                "Environment '{s}' is missing required 'target_machines' field",
                .{env_name},
            ),
            .context = context,
            .field_path = try allocator.dupe(u8, path),
        });
    } else {
        const target_machines = value.object.get("target_machines") orelse unreachable;
        if (target_machines != .array) {
            const position = try findValuePosition(content, target_machines);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'target_machines' must be an array",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.target_machines", .{path}),
            });
        } else {
            // Validate all items in target_machines are strings
            for (target_machines.array.items, 0..) |machine, i| {
                if (machine != .string) {
                    const position = try findValuePosition(content, machine);
                    const context = getContextAroundPosition(allocator, content, position.line) catch null;

                    try errors.append(ValidationError{
                        .line = position.line,
                        .column = position.column,
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'target_machines[{d}]' must be a string",
                            .{ env_name, i },
                        ),
                        .context = context,
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.target_machines[{d}]", .{ path, i }),
                    });
                }
            }
        }
    }

    // Validate optional fields
    // description: optional string
    if (value.object.get("description")) |desc| {
        if (desc != .string and desc != .null) {
            const position = try findValuePosition(content, desc);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'description' must be a string or null",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.description", .{path}),
            });
        }
    }

    // fallback_python: optional string
    if (value.object.get("fallback_python")) |python| {
        if (python != .string and python != .null) {
            const position = try findValuePosition(content, python);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'fallback_python' must be a string or null",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.fallback_python", .{path}),
            });
        }
    }

    // modules: array of strings
    if (value.object.get("modules")) |modules| {
        if (modules != .array) {
            const position = try findValuePosition(content, modules);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'modules' must be an array",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.modules", .{path}),
            });
        } else {
            for (modules.array.items, 0..) |module, i| {
                if (module != .string) {
                    const position = try findValuePosition(content, module);
                    const context = getContextAroundPosition(allocator, content, position.line) catch null;

                    try errors.append(ValidationError{
                        .line = position.line,
                        .column = position.column,
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'modules[{d}]' must be a string",
                            .{ env_name, i },
                        ),
                        .context = context,
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.modules[{d}]", .{ path, i }),
                    });
                }
            }
        }
    }

    // modules_file: optional string
    if (value.object.get("modules_file")) |modules_file| {
        if (modules_file != .string and modules_file != .null) {
            const position = try findValuePosition(content, modules_file);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'modules_file' must be a string or null",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.modules_file", .{path}),
            });
        }
    }

    // dependencies: array of strings
    if (value.object.get("dependencies")) |dependencies| {
        if (dependencies != .array) {
            const position = try findValuePosition(content, dependencies);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'dependencies' must be an array",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.dependencies", .{path}),
            });
        } else {
            for (dependencies.array.items, 0..) |dep, i| {
                if (dep != .string) {
                    const position = try findValuePosition(content, dep);
                    const context = getContextAroundPosition(allocator, content, position.line) catch null;

                    try errors.append(ValidationError{
                        .line = position.line,
                        .column = position.column,
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'dependencies[{d}]' must be a string",
                            .{ env_name, i },
                        ),
                        .context = context,
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.dependencies[{d}]", .{ path, i }),
                    });
                }
            }
        }
    }

    // dependency_file: optional string
    if (value.object.get("dependency_file")) |dep_file| {
        if (dep_file != .string and dep_file != .null) {
            const position = try findValuePosition(content, dep_file);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'dependency_file' must be a string or null",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.dependency_file", .{path}),
            });
        }
    }

    // setup_commands: optional array of strings
    if (value.object.get("setup_commands")) |commands| {
        if (commands != .array and commands != .null) {
            const position = try findValuePosition(content, commands);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'setup_commands' must be an array or null",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.setup_commands", .{path}),
            });
        } else if (commands == .array) {
            for (commands.array.items, 0..) |cmd, i| {
                if (cmd != .string) {
                    const position = try findValuePosition(content, cmd);
                    const context = getContextAroundPosition(allocator, content, position.line) catch null;

                    try errors.append(ValidationError{
                        .line = position.line,
                        .column = position.column,
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'setup_commands[{d}]' must be a string",
                            .{ env_name, i },
                        ),
                        .context = context,
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.setup_commands[{d}]", .{ path, i }),
                    });
                }
            }
        }
    }

    // activate_commands: optional array of strings
    if (value.object.get("activate_commands")) |commands| {
        if (commands != .array and commands != .null) {
            const position = try findValuePosition(content, commands);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'activate_commands' must be an array or null",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.activate_commands", .{path}),
            });
        } else if (commands == .array) {
            for (commands.array.items, 0..) |cmd, i| {
                if (cmd != .string) {
                    const position = try findValuePosition(content, cmd);
                    const context = getContextAroundPosition(allocator, content, position.line) catch null;

                    try errors.append(ValidationError{
                        .line = position.line,
                        .column = position.column,
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'activate_commands[{d}]' must be a string",
                            .{ env_name, i },
                        ),
                        .context = context,
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.activate_commands[{d}]", .{ path, i }),
                    });
                }
            }
        }
    }

    // custom_activate_vars: object with string values
    if (value.object.get("custom_activate_vars")) |vars| {
        if (vars != .object) {
            const position = try findValuePosition(content, vars);
            const context = getContextAroundPosition(allocator, content, position.line) catch null;

            try errors.append(ValidationError{
                .line = position.line,
                .column = position.column,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'custom_activate_vars' must be an object",
                    .{env_name},
                ),
                .context = context,
                .field_path = try std.fmt.allocPrint(allocator, "{s}.custom_activate_vars", .{path}),
            });
        } else {
            var var_it = vars.object.iterator();
            while (var_it.next()) |var_entry| {
                const var_name = var_entry.key_ptr.*;
                const var_value = var_entry.value_ptr.*;

                if (var_value != .string) {
                    const position = try findValuePosition(content, var_value);
                    const context = getContextAroundPosition(allocator, content, position.line) catch null;

                    try errors.append(ValidationError{
                        .line = position.line,
                        .column = position.column,
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', custom_activate_vars.{s} must be a string",
                            .{ env_name, var_name },
                        ),
                        .context = context,
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.custom_activate_vars.{s}", .{ path, var_name }),
                    });
                }
            }
        }
    }
}

/// Position in the JSON text
const Position = struct {
    line: usize,
    column: usize,
};

/// Find the position of an error in the JSON text
fn findErrorPosition(content: []const u8, _: []const u8) !Position {
    // For syntax errors, we need to scan the file to find the approximate location
    // This approach attempts to locate common JSON syntax errors

    var line: usize = 1;
    var column: usize = 1;
    var in_string = false;
    var escape_next = false;

    // Track brackets and braces for balance checking
    var stack = std.ArrayList(struct { char: u8, pos: Position }).init(std.heap.page_allocator);
    defer stack.deinit();

    for (content) |c| {
        const current_pos = Position{ .line = line, .column = column };

        if (c == '\n') {
            line += 1;
            column = 1;
            // Newline in a string is invalid in JSON
            if (in_string) {
                return current_pos;
            }
        } else {
            column += 1;
        }

        if (escape_next) {
            escape_next = false;
        } else if (c == '\\') {
            escape_next = true;
        } else if (c == '"') {
            in_string = !in_string;
        } else if (!in_string) {
            // Check for balanced brackets
            if (c == '{' or c == '[') {
                try stack.append(.{ .char = c, .pos = current_pos });
            } else if (c == '}') {
                if (stack.items.len == 0 or stack.items[stack.items.len - 1].char != '{') {
                    return current_pos;
                }
                _ = stack.pop();
            } else if (c == ']') {
                if (stack.items.len == 0 or stack.items[stack.items.len - 1].char != '[') {
                    return current_pos;
                }
                _ = stack.pop();
            }

            // Check for invalid characters outside of strings
            if (!(std.ascii.isWhitespace(c) or
                c == '{' or c == '}' or c == '[' or c == ']' or
                c == ':' or c == ',' or c == '"' or
                std.ascii.isDigit(c) or c == '-' or c == '.' or c == '+' or
                c == 't' or c == 'r' or c == 'u' or c == 'e' or
                c == 'f' or c == 'a' or c == 'l' or c == 's' or
                c == 'n'))
            {
                return current_pos;
            }
        }
    }

    // Check for unclosed string
    if (in_string) {
        return Position{ .line = line, .column = column };
    }

    // Check for unbalanced brackets
    if (stack.items.len > 0) {
        return stack.items[stack.items.len - 1].pos;
    }

    // If no specific issue found, return the end position
    return Position{ .line = line, .column = column };
}

/// Find the position of a JSON value in the text
fn findValuePosition(content: []const u8, value: json.Value) !Position {
    // This is a simplistic implementation that just scans for the value
    // A more sophisticated implementation would track positions during parsing

    const value_str = switch (value) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{i}) catch "0",
        .float => |f| std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{f}) catch "0",
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        .array => "[",
        .object => "{",
        else => "value",
    };

    var line: usize = 1;
    var column: usize = 1;

    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }

        // Try to match the value at this position
        if (i + value_str.len <= content.len and std.mem.eql(u8, content[i .. i + value_str.len], value_str)) {
            return Position{ .line = line, .column = column };
        }
    }

    // If we can't find the value, return position 1,1
    return Position{ .line = 1, .column = 1 };
}

/// Find the position of a JSON object in the text
fn findObjectPosition(content: []const u8, object: json.ObjectMap) !Position {
    // For simplicity, just find the opening brace
    return findValuePosition(content, json.Value{ .object = object });
}

/// Get context (the line) around a specific position
fn getContextAroundPosition(allocator: Allocator, content: []const u8, line_number: usize) !?[]const u8 {
    var current_line: usize = 1;
    var line_start: usize = 0;

    for (content, 0..) |c, i| {
        if (c == '\n') {
            if (current_line == line_number) {
                // Found the line, extract it
                return try allocator.dupe(u8, content[line_start..i]);
            }
            current_line += 1;
            line_start = i + 1;
        }
    }

    // Handle the last line
    if (current_line == line_number) {
        return try allocator.dupe(u8, content[line_start..]);
    }

    return null;
}

/// Prints validation errors to stderr
pub fn printValidationErrors(errors: std.ArrayList(ValidationError)) void {
    for (errors.items, 0..) |err, i| {
        if (i > 0) {
            output.printError("", .{}) catch {};
        }

        if (err.line > 0) {
            output.printError("Error approximately at line {d}, column {d}: {s}", .{ err.line, err.column, err.message }) catch {};
        } else {
            output.printError("Error: {s}", .{err.message}) catch {};
        }

        if (err.field_path) |path| {
            if (path.len > 0) {
                output.printError("In field: {s}", .{path}) catch {};
            }
        }

        if (err.context) |ctx| {
            output.printError("Context: {s}", .{ctx}) catch {};

            // Print a marker pointing to the column
            if (err.column > 0) {
                var marker = std.ArrayList(u8).init(std.heap.page_allocator);
                defer marker.deinit();

                // Create spaces up to the column
                const spaces = @min(err.column - 1, ctx.len);
                for (0..spaces) |_| {
                    marker.append(' ') catch break;
                }

                // Add the marker
                marker.append('^') catch {};

                output.printError("         {s}", .{marker.items}) catch {};
            }
        }
    }
}

/// Validates a JSON configuration file and returns a ZenvConfig if valid
pub fn validateAndParse(allocator: Allocator, config_path: []const u8) !config_module.ZenvConfig {
    // First validate the configuration
    const validation_errors = try validateConfigFile(allocator, config_path);

    if (validation_errors) |errors| {
        defer {
            for (errors.items) |*err| {
                err.deinit(allocator);
            }
            errors.deinit();
        }

        // Error messages already printed in validateConfigFile
        return error.InvalidFormat;
    }

    // If validation passed, parse the configuration
    return config_module.parse(allocator, config_path);
}
