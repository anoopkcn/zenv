const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const output = @import("output.zig");
const config_module = @import("config.zig");
const runtime = @import("runtime.zig");

/// Represents an error found during validation
pub const ValidationError = struct {
    line: usize = 0,
    column: usize = 0,
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
pub fn validateConfigFile(allocator: Allocator, file_path: []const u8) !?std.array_list.Managed(ValidationError) {
    // Read the file content
    const file_content = runtime.readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            var errors = std.array_list.Managed(ValidationError).init(allocator);
            try errors.append(ValidationError{
                .line = 0,
                .column = 0,
                .message = try allocator.dupe(u8, "Configuration file not found"),
                .context = try allocator.dupe(u8, file_path),
            });

            // Print the error and return it
            printValidationErrors(allocator, errors);
            return errors;
        }
        return err;
    };
    defer allocator.free(file_content);

    // Validate the JSON content
    const validation_result = try validateJsonContent(allocator, file_content);

    // If there are validation errors, print them
    if (validation_result != null) {
        printValidationErrors(allocator, validation_result.?);
        return validation_result;
    }

    return null;
}

/// Validates JSON content and returns a list of validation errors
pub fn validateJsonContent(allocator: Allocator, content: []const u8) !?std.array_list.Managed(ValidationError) {
    var errors = std.array_list.Managed(ValidationError).init(allocator);
    errdefer {
        for (errors.items) |*err| {
            err.deinit(allocator);
        }
        errors.deinit();
    }

    // Parse with a Scanner whose Diagnostics tracks exact line/column during
    // the parse itself, so a syntax error reports the precise position from the
    // parser (no second hand-rolled scan).
    var scanner = json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();
    var diag: json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);

    var parsed = json.parseFromTokenSource(json.Value, allocator, &scanner, .{}) catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "Invalid JSON syntax: {s}", .{@errorName(err)});

        try errors.append(ValidationError{
            .line = diag.getLine(),
            .column = diag.getColumn(),
            .message = err_msg,
            .context = getContextAroundPosition(allocator, content, diag.getLine()) catch null,
            // field_path left null: a syntax error has no schema path, and a
            // non-null empty string would be freed by deinit (it isn't owned).
        });

        return errors;
    };
    defer parsed.deinit();

    // Validate the structure of the JSON. Each semantic error is recorded with
    // its dotted field path; exact line/column/context are backfilled below.
    try validateZenvConfig(allocator, &errors, parsed.value, "");

    // If there are no errors, return null
    if (errors.items.len == 0) {
        errors.deinit();
        return null;
    }

    // Backfill accurate positions for every semantic error from a single pass
    // over the token stream (keyed by field path).
    try fillPositions(allocator, content, errors.items);

    return errors;
}

/// Validates the structure of a zenv.json configuration
fn validateZenvConfig(
    allocator: Allocator,
    errors: *std.array_list.Managed(ValidationError),
    value: json.Value,
    path: []const u8,
) !void {
    // The root must be an object
    if (value != .object) {
        try errors.append(ValidationError{
            .message = try allocator.dupe(u8, "Root configuration must be a JSON object"),
            .field_path = try allocator.dupe(u8, path),
        });
        return;
    }

    // Check for required base_dir field
    if (!value.object.contains("base_dir")) {
        try errors.append(ValidationError{
            .message = try allocator.dupe(u8, "Missing required 'base_dir' field"),
            .field_path = try allocator.dupe(u8, path),
        });
    } else {
        const base_dir = value.object.get("base_dir") orelse unreachable;
        if (base_dir != .string) {
            try errors.append(ValidationError{
                .message = try allocator.dupe(u8, "'base_dir' must be a string"),
                .field_path = try allocator.dupe(u8, "base_dir"),
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
            if (path.len > 0) try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, key }) else key,
        );
    }

    if (!has_envs) {
        try errors.append(ValidationError{
            .message = try allocator.dupe(u8, "At least one environment must be defined"),
            .field_path = try allocator.dupe(u8, path),
        });
    }
}

/// Validates an environment configuration
fn validateEnvironment(
    allocator: Allocator,
    errors: *std.array_list.Managed(ValidationError),
    value: json.Value,
    env_name: []const u8,
    path: []const u8,
) !void {
    if (value != .object) {
        try errors.append(ValidationError{
            .message = try std.fmt.allocPrint(allocator, "Environment '{s}' must be an object", .{env_name}),
            .field_path = try allocator.dupe(u8, path),
        });
        return;
    }

    // Check for required 'target_machines' field
    if (!value.object.contains("target_machines")) {
        try errors.append(ValidationError{
            .message = try std.fmt.allocPrint(
                allocator,
                "Environment '{s}' is missing required 'target_machines' field",
                .{env_name},
            ),
            .field_path = try allocator.dupe(u8, path),
        });
    } else {
        const target_machines = value.object.get("target_machines") orelse unreachable;
        if (target_machines != .array) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'target_machines' must be an array",
                    .{env_name},
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.target_machines", .{path}),
            });
        } else {
            // Validate all items in target_machines are strings
            for (target_machines.array.items, 0..) |machine, i| {
                if (machine != .string) {
                    try errors.append(ValidationError{
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'target_machines[{d}]' must be a string",
                            .{ env_name, i },
                        ),
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
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'description' must be a string or null",
                    .{env_name},
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.description", .{path}),
            });
        }
    }

    // fallback_python: optional string
    if (value.object.get("fallback_python")) |python| {
        if (python != .string and python != .null) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'fallback_python' must be a string or null",
                    .{env_name},
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.fallback_python", .{path}),
            });
        }
    }

    // modules: array of strings
    if (value.object.get("modules")) |modules| {
        if (modules != .array) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'modules' must be an array",
                    .{env_name},
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.modules", .{path}),
            });
        } else {
            for (modules.array.items, 0..) |module, i| {
                if (module != .string) {
                    try errors.append(ValidationError{
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'modules[{d}]' must be a string",
                            .{ env_name, i },
                        ),
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.modules[{d}]", .{ path, i }),
                    });
                }
            }
        }
    }

    // modules_file: optional string
    if (value.object.get("modules_file")) |modules_file| {
        if (modules_file != .string and modules_file != .null) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'modules_file' must be a string or null",
                    .{env_name},
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.modules_file", .{path}),
            });
        }
    }

    // dependencies: array of strings
    if (value.object.get("dependencies")) |dependencies| {
        if (dependencies != .array) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'dependencies' must be an array",
                    .{env_name},
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.dependencies", .{path}),
            });
        } else {
            for (dependencies.array.items, 0..) |dep, i| {
                if (dep != .string) {
                    try errors.append(ValidationError{
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'dependencies[{d}]' must be a string",
                            .{ env_name, i },
                        ),
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.dependencies[{d}]", .{ path, i }),
                    });
                }
            }
        }
    }

    // dependency_file: optional string
    if (value.object.get("dependency_file")) |dep_file| {
        if (dep_file != .string and dep_file != .null) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'dependency_file' must be a string or null",
                    .{env_name},
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.dependency_file", .{path}),
            });
        }
    }

    // setup: optional object with commands and script
    if (value.object.get("setup")) |setup_obj| {
        if (setup_obj != .object and setup_obj != .null) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'setup' must be an object or null",
                    .{env_name},
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.setup", .{path}),
            });
        } else if (setup_obj == .object) {
            // Validate script field
            if (setup_obj.object.get("script")) |script| {
                if (script != .string and script != .null) {
                    try errors.append(ValidationError{
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'setup.script' must be a string or null",
                            .{env_name},
                        ),
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.setup.script", .{path}),
                    });
                }
            }

            // Validate commands field
            if (setup_obj.object.get("commands")) |commands| {
                if (commands != .array and commands != .null) {
                    try errors.append(ValidationError{
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'setup.commands' must be an array or null",
                            .{env_name},
                        ),
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.setup.commands", .{path}),
                    });
                } else if (commands == .array) {
                    for (commands.array.items, 0..) |cmd, i| {
                        if (cmd != .string) {
                            try errors.append(ValidationError{
                                .message = try std.fmt.allocPrint(
                                    allocator,
                                    "In environment '{s}', 'setup.commands[{d}]' must be a string",
                                    .{ env_name, i },
                                ),
                                .field_path = try std.fmt.allocPrint(allocator, "{s}.setup.commands[{d}]", .{ path, i }),
                            });
                        }
                    }
                }
            }
        }
    }

    // activate: optional object with commands and script
    if (value.object.get("activate")) |activate_obj| {
        if (activate_obj != .object and activate_obj != .null) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', 'activate' must be an object or null",
                    .{env_name},
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.activate", .{path}),
            });
        } else if (activate_obj == .object) {
            // Validate script field
            if (activate_obj.object.get("script")) |script| {
                if (script != .string and script != .null) {
                    try errors.append(ValidationError{
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'activate.script' must be a string or null",
                            .{env_name},
                        ),
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.activate.script", .{path}),
                    });
                }
            }

            // Validate commands field
            if (activate_obj.object.get("commands")) |commands| {
                if (commands != .array and commands != .null) {
                    try errors.append(ValidationError{
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "In environment '{s}', 'activate.commands' must be an array or null",
                            .{env_name},
                        ),
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.activate.commands", .{path}),
                    });
                } else if (commands == .array) {
                    for (commands.array.items, 0..) |cmd, i| {
                        if (cmd != .string) {
                            try errors.append(ValidationError{
                                .message = try std.fmt.allocPrint(
                                    allocator,
                                    "In environment '{s}', 'activate.commands[{d}]' must be a string",
                                    .{ env_name, i },
                                ),
                                .field_path = try std.fmt.allocPrint(allocator, "{s}.activate.commands[{d}]", .{ path, i }),
                            });
                        }
                    }
                }
            }
        }
    }

    // Whitelist approach: only allow specific fields in environment configuration
    const allowed_fields = [_][]const u8{
        "target_machines",
        "description",
        "modules",
        "modules_file",
        "dependencies",
        "dependency_file",
        "fallback_python",
        "setup",
        "activate",
    };

    // Check each field in the environment config
    var field_iter = value.object.iterator();
    while (field_iter.next()) |entry| {
        const field_name = entry.key_ptr.*;

        // Check if field is in the allowed list
        var is_allowed = false;
        for (allowed_fields) |allowed| {
            if (std.mem.eql(u8, field_name, allowed)) {
                is_allowed = true;
                break;
            }
        }

        // If not allowed, add validation error
        if (!is_allowed) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "In environment '{s}', '{s}' is not a recognized field.",
                    .{ env_name, field_name },
                ),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, field_name }),
            });
        }
    }
}

/// Position in the JSON text
const Position = struct {
    line: usize,
    column: usize,
};

/// Builds a map from dotted field path (e.g. "myenv.target_machines[0]") to the
/// position of that value in the source, by walking the token stream once.
/// Container values record the position of their opening token; the empty
/// string key "" is the document root. Positions come from the parser's own
/// `Diagnostics`, so they are exact and repeat-proof.
fn buildPositionMap(allocator: Allocator, content: []const u8) !std.StringHashMap(Position) {
    var map = std.StringHashMap(Position).init(allocator);
    errdefer map.deinit();

    var scanner = json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();
    var diag: json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);

    const Frame = struct { is_object: bool, expecting_key: bool, index: usize, base_len: usize };
    var frames = std.array_list.Managed(Frame).init(allocator);
    defer frames.deinit();
    var path = std.array_list.Managed(u8).init(allocator);
    defer path.deinit();
    var have_root = false;

    while (true) {
        // Captured before consuming the token, this sits at the token's start
        // (Diagnostics otherwise reports the end of the just-consumed token).
        const before = Position{ .line = diag.getLine(), .column = diag.getColumn() };
        const tok = try scanner.nextAlloc(allocator, .alloc_if_needed);
        if (tok == .end_of_document) break;

        if (frames.items.len == 0) {
            // Document root value.
            if (!have_root) {
                have_root = true;
                try map.put("", before);
                switch (tok) {
                    .object_begin => try frames.append(.{ .is_object = true, .expecting_key = true, .index = 0, .base_len = 0 }),
                    .array_begin => try frames.append(.{ .is_object = false, .expecting_key = false, .index = 0, .base_len = 0 }),
                    else => {},
                }
            }
            continue;
        }

        const ti = frames.items.len - 1;
        if (frames.items[ti].is_object) {
            if (frames.items[ti].expecting_key) {
                switch (tok) {
                    .object_end => {
                        _ = frames.pop();
                    },
                    .string, .allocated_string => |key| {
                        path.shrinkRetainingCapacity(frames.items[ti].base_len);
                        if (frames.items[ti].base_len > 0) try path.append('.');
                        try path.appendSlice(key);
                        frames.items[ti].expecting_key = false;
                    },
                    else => {},
                }
            } else {
                // Value for the current key; `path` already holds its full path.
                try map.put(try allocator.dupe(u8, path.items), before);
                frames.items[ti].expecting_key = true;
                switch (tok) {
                    .object_begin => try frames.append(.{ .is_object = true, .expecting_key = true, .index = 0, .base_len = path.items.len }),
                    .array_begin => try frames.append(.{ .is_object = false, .expecting_key = false, .index = 0, .base_len = path.items.len }),
                    else => {},
                }
            }
        } else {
            switch (tok) {
                .array_end => {
                    _ = frames.pop();
                },
                else => {
                    path.shrinkRetainingCapacity(frames.items[ti].base_len);
                    try path.print("[{d}]", .{frames.items[ti].index});
                    try map.put(try allocator.dupe(u8, path.items), before);
                    frames.items[ti].index += 1;
                    switch (tok) {
                        .object_begin => try frames.append(.{ .is_object = true, .expecting_key = true, .index = 0, .base_len = path.items.len }),
                        .array_begin => try frames.append(.{ .is_object = false, .expecting_key = false, .index = 0, .base_len = path.items.len }),
                        else => {},
                    }
                },
            }
        }
    }

    return map;
}

/// Backfills accurate line/column/context for each semantic error from the
/// position map, keyed by each error's `field_path`. Errors whose path is not
/// found keep their default (0, 0) position.
fn fillPositions(allocator: Allocator, content: []const u8, errors: []ValidationError) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var map = buildPositionMap(arena.allocator(), content) catch return;

    for (errors) |*e| {
        const key = e.field_path orelse "";
        if (map.get(key)) |pos| {
            e.line = pos.line;
            e.column = pos.column;
            if (e.context) |old| allocator.free(old);
            e.context = getContextAroundPosition(allocator, content, pos.line) catch null;
        }
    }
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
pub fn printValidationErrors(allocator: Allocator, errors: std.array_list.Managed(ValidationError)) void {
    for (errors.items, 0..) |err, i| {
        if (i > 0) {
            output.printError(allocator, "", .{}) catch {};
        }

        if (err.line > 0) {
            output.printError(allocator, "at line {d}, column {d}: {s}", .{ err.line, err.column, err.message }) catch {};
        } else {
            output.printError(allocator, "{s}", .{err.message}) catch {};
        }

        if (err.field_path) |path| {
            if (path.len > 0) {
                output.printError(allocator, "In field: {s}", .{path}) catch {};
            }
        }

        if (err.context) |ctx| {
            output.printError(allocator, "Context: {s}", .{ctx}) catch {};

            // Print a marker pointing to the column
            if (err.column > 0) {
                var marker = std.array_list.Managed(u8).init(std.heap.page_allocator);
                defer marker.deinit();

                // Create spaces up to the column
                const spaces = @min(err.column - 1, ctx.len);
                for (0..spaces) |_| {
                    marker.append(' ') catch break;
                }

                // Add the marker
                marker.append('^') catch {};

                output.printError(allocator, "         {s}", .{marker.items}) catch {};
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

// ============================ Tests ============================

const testing = std.testing;

fn freeErrors(a: Allocator, errs: *std.array_list.Managed(ValidationError)) void {
    for (errs.items) |*e| e.deinit(a);
    errs.deinit();
}

test "validateJsonContent: valid config returns null" {
    const a = testing.allocator;
    const content =
        \\{ "base_dir": "zenv", "e1": { "target_machines": ["*"] } }
    ;
    try testing.expect((try validateJsonContent(a, content)) == null);
}

test "validateJsonContent: syntax error is located past the early lines (not line 1)" {
    const a = testing.allocator;
    const content =
        \\{
        \\  "base_dir": "zenv",
        \\  "e1": {
        \\    "target_machines": ["*"],
        \\  }
    ;
    var errs = (try validateJsonContent(a, content)).?;
    defer freeErrors(a, &errs);
    try testing.expect(errs.items.len >= 1);
    // The old hand-rolled scanner mislocated this to line 1; the parser's
    // Diagnostics points into the latter half of the document.
    try testing.expect(errs.items[0].line >= 4);
}

test "validateJsonContent: wrong-typed field gives exact path and line (repeat-proof)" {
    const a = testing.allocator;
    const content =
        \\{
        \\  "base_dir": "zenv",
        \\  "good": { "target_machines": ["*"] },
        \\  "bad": { "target_machines": "*" }
        \\}
    ;
    var errs = (try validateJsonContent(a, content)).?;
    defer freeErrors(a, &errs);
    try testing.expectEqual(@as(usize, 1), errs.items.len);
    const e = errs.items[0];
    try testing.expectEqualStrings("bad.target_machines", e.field_path.?);
    // Must point at line 4 (the "bad" env), not the identical ["*"] on line 3
    // that the old indexOf search would have matched.
    try testing.expectEqual(@as(usize, 4), e.line);
}

test "validateJsonContent: missing required base_dir is reported" {
    const a = testing.allocator;
    const content =
        \\{ "e1": { "target_machines": ["*"] } }
    ;
    var errs = (try validateJsonContent(a, content)).?;
    defer freeErrors(a, &errs);
    var found = false;
    for (errs.items) |e| {
        if (std.mem.indexOf(u8, e.message, "base_dir") != null) found = true;
    }
    try testing.expect(found);
}
