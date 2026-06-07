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

const StrList = std.array_list.Managed([]const u8);
const ErrorList = std.array_list.Managed(ValidationError);

/// Outcome of the single parse-and-validate seam: either the built config or the
/// full list of positioned errors, never both.
pub const LoadResult = union(enum) {
    config: config_module.ZenvConfig,
    errors: ErrorList,
};

/// THE parse-and-validate seam. Parses `content` once (an owned tree, with
/// Diagnostics for syntax positions), then walks it a single time to BOTH
/// validate and build the typed `ZenvConfig`. The schema — every field name,
/// type, required-ness, and the environment whitelist — is described exactly
/// here and nowhere else. A passing result therefore guarantees the config also
/// builds, which is the whole point of unifying the two former encodings.
pub fn loadConfig(allocator: Allocator, content: []const u8) !LoadResult {
    var errors = ErrorList.init(allocator);
    errdefer {
        for (errors.items) |*e| e.deinit(allocator);
        errors.deinit();
    }

    var scanner = json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();
    var diag: json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);

    var parsed = json.parseFromTokenSource(json.Value, allocator, &scanner, .{
        .allocate = .alloc_always,
    }) catch |err| {
        try errors.append(ValidationError{
            .line = diag.getLine(),
            .column = diag.getColumn(),
            .message = try std.fmt.allocPrint(allocator, "Invalid JSON syntax: {s}", .{@errorName(err)}),
            .context = getContextAroundPosition(allocator, content, diag.getLine()) catch null,
            // field_path left null: a syntax error has no schema path.
        });
        return .{ .errors = errors };
    };
    // Every built field is duped, so the tree is not needed beyond this walk.
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try errors.append(ValidationError{
            .message = try allocator.dupe(u8, "Root configuration must be a JSON object"),
            .field_path = try allocator.dupe(u8, ""),
        });
        return .{ .errors = errors };
    }

    var config = config_module.ZenvConfig{
        .allocator = allocator,
        .environments = std.StringHashMap(config_module.EnvironmentConfig).init(allocator),
        .base_dir = try allocator.dupe(u8, "zenv"), // safe default; always deinit-able
    };
    errdefer config.deinit();

    // base_dir: required string.
    if (root.object.get("base_dir")) |bd| {
        if (bd == .string) {
            const dup = try allocator.dupe(u8, bd.string);
            allocator.free(config.base_dir);
            config.base_dir = dup;
        } else {
            try errors.append(ValidationError{
                .message = try allocator.dupe(u8, "'base_dir' must be a string"),
                .field_path = try allocator.dupe(u8, "base_dir"),
            });
        }
    } else {
        try errors.append(ValidationError{
            .message = try allocator.dupe(u8, "Missing required 'base_dir' field"),
            .field_path = try allocator.dupe(u8, ""),
        });
    }

    // Environments: every top-level key except base_dir.
    var has_envs = false;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "base_dir")) continue;
        has_envs = true;

        if (try validateAndBuildEnvironment(allocator, &errors, entry.value_ptr.*, key)) |env| {
            var env_mut = env;
            const env_key = allocator.dupe(u8, key) catch {
                env_mut.deinit();
                return error.OutOfMemory;
            };
            config.environments.put(env_key, env_mut) catch {
                allocator.free(env_key);
                env_mut.deinit();
                return error.OutOfMemory;
            };
        }
    }

    if (!has_envs) {
        try errors.append(ValidationError{
            .message = try allocator.dupe(u8, "At least one environment must be defined"),
            .field_path = try allocator.dupe(u8, ""),
        });
    }

    if (errors.items.len > 0) {
        fillPositions(allocator, content, errors.items) catch {}; // positions are best-effort
        config.deinit();
        return .{ .errors = errors };
    }

    errors.deinit();
    return .{ .config = config };
}

/// Validates one environment AND builds its `EnvironmentConfig` in the same pass.
/// Records positioned errors for any problem and returns the always-deinit-safe
/// env (the caller discards it if the overall config has any errors), or null
/// when the value isn't an object.
fn validateAndBuildEnvironment(
    allocator: Allocator,
    errors: *ErrorList,
    value: json.Value,
    env_name: []const u8,
) !?config_module.EnvironmentConfig {
    if (value != .object) {
        try errors.append(ValidationError{
            .message = try std.fmt.allocPrint(allocator, "Environment '{s}' must be an object", .{env_name}),
            .field_path = try allocator.dupe(u8, env_name),
        });
        return null;
    }

    var env = config_module.EnvironmentConfig.init(allocator);
    errdefer env.deinit();

    // target_machines: required, non-empty array of strings.
    if (value.object.get("target_machines")) |tm| {
        if (tm != .array) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(allocator, "In environment '{s}', 'target_machines' must be an array", .{env_name}),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.target_machines", .{env_name}),
            });
        } else {
            if (tm.array.items.len == 0) {
                try errors.append(ValidationError{
                    .message = try std.fmt.allocPrint(allocator, "In environment '{s}', 'target_machines' must not be empty", .{env_name}),
                    .field_path = try std.fmt.allocPrint(allocator, "{s}.target_machines", .{env_name}),
                });
            }
            for (tm.array.items, 0..) |m, i| {
                if (m != .string) {
                    try errors.append(ValidationError{
                        .message = try std.fmt.allocPrint(allocator, "In environment '{s}', 'target_machines[{d}]' must be a string", .{ env_name, i }),
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.target_machines[{d}]", .{ env_name, i }),
                    });
                }
            }
            const built = try config_module.Parse.getStringArray(allocator, tm);
            env.target_machines.deinit();
            env.target_machines = built;
        }
    } else {
        try errors.append(ValidationError{
            .message = try std.fmt.allocPrint(allocator, "Environment '{s}' is missing required 'target_machines' field", .{env_name}),
            .field_path = try allocator.dupe(u8, env_name),
        });
    }

    // Optional string fields.
    try buildOptString(allocator, errors, value, env_name, "description", &env.description);
    try buildOptString(allocator, errors, value, env_name, "fallback_python", &env.fallback_python);
    try buildOptString(allocator, errors, value, env_name, "modules_file", &env.modules_file);
    try buildOptString(allocator, errors, value, env_name, "dependency_file", &env.dependency_file);

    // Optional string arrays.
    try buildOptStringArray(allocator, errors, value, env_name, "modules", &env.modules);
    try buildOptStringArray(allocator, errors, value, env_name, "dependencies", &env.dependencies);

    // module_cache: optional boolean.
    if (value.object.get("module_cache")) |mc| {
        if (mc == .bool) {
            env.module_cache = mc.bool;
        } else if (mc != .null) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(allocator, "In environment '{s}', 'module_cache' must be a boolean or null", .{env_name}),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.module_cache", .{env_name}),
            });
        }
    }

    // setup / activate: optional script objects.
    env.setup = try validateAndBuildScriptObject(allocator, errors, value, env_name, "setup");
    env.activate = try validateAndBuildScriptObject(allocator, errors, value, env_name, "activate");

    // Whitelist: every other field is unrecognized.
    const allowed = [_][]const u8{
        "target_machines", "description",     "modules", "modules_file", "dependencies",
        "dependency_file", "fallback_python", "setup",   "activate",     "module_cache",
    };
    var fi = value.object.iterator();
    while (fi.next()) |e| {
        const fname = e.key_ptr.*;
        var ok = false;
        for (allowed) |a| {
            if (std.mem.eql(u8, fname, a)) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(allocator, "In environment '{s}', '{s}' is not a recognized field.", .{ env_name, fname }),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ env_name, fname }),
            });
        }
    }

    return env;
}

// Validates+builds an optional string field directly into `out`.
fn buildOptString(
    allocator: Allocator,
    errors: *ErrorList,
    value: json.Value,
    env_name: []const u8,
    field: []const u8,
    out: *?[]const u8,
) !void {
    const v = value.object.get(field) orelse return;
    switch (v) {
        .string => |s| out.* = try allocator.dupe(u8, s),
        .null => {},
        else => try errors.append(ValidationError{
            .message = try std.fmt.allocPrint(allocator, "In environment '{s}', '{s}' must be a string or null", .{ env_name, field }),
            .field_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ env_name, field }),
        }),
    }
}

// Validates+builds an optional array-of-strings field directly into `out`.
fn buildOptStringArray(
    allocator: Allocator,
    errors: *ErrorList,
    value: json.Value,
    env_name: []const u8,
    field: []const u8,
    out: *StrList,
) !void {
    const v = value.object.get(field) orelse return;
    if (v != .array) {
        try errors.append(ValidationError{
            .message = try std.fmt.allocPrint(allocator, "In environment '{s}', '{s}' must be an array", .{ env_name, field }),
            .field_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ env_name, field }),
        });
        return;
    }
    for (v.array.items, 0..) |item, i| {
        if (item != .string) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(allocator, "In environment '{s}', '{s}[{d}]' must be a string", .{ env_name, field, i }),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.{s}[{d}]", .{ env_name, field, i }),
            });
        }
    }
    const built = try config_module.Parse.getStringArray(allocator, v);
    out.deinit();
    out.* = built;
}

// Validates+builds an optional `setup`/`activate` object into a ScriptConfig.
fn validateAndBuildScriptObject(
    allocator: Allocator,
    errors: *ErrorList,
    value: json.Value,
    env_name: []const u8,
    field: []const u8,
) !?config_module.ScriptConfig {
    const v = value.object.get(field) orelse return null;
    if (v == .null) return null;
    if (v != .object) {
        try errors.append(ValidationError{
            .message = try std.fmt.allocPrint(allocator, "In environment '{s}', '{s}' must be an object or null", .{ env_name, field }),
            .field_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ env_name, field }),
        });
        return null;
    }

    var sc = config_module.ScriptConfig.init();
    errdefer sc.deinit(allocator);

    if (v.object.get("script")) |script| {
        switch (script) {
            .string => |s| sc.script = try allocator.dupe(u8, s),
            .null => {},
            else => try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(allocator, "In environment '{s}', '{s}.script' must be a string or null", .{ env_name, field }),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.{s}.script", .{ env_name, field }),
            }),
        }
    }

    if (v.object.get("commands")) |cmds| {
        if (cmds == .array) {
            for (cmds.array.items, 0..) |c, i| {
                if (c != .string) {
                    try errors.append(ValidationError{
                        .message = try std.fmt.allocPrint(allocator, "In environment '{s}', '{s}.commands[{d}]' must be a string", .{ env_name, field, i }),
                        .field_path = try std.fmt.allocPrint(allocator, "{s}.{s}.commands[{d}]", .{ env_name, field, i }),
                    });
                }
            }
            sc.commands = try config_module.Parse.getStringArray(allocator, cmds);
        } else if (cmds != .null) {
            try errors.append(ValidationError{
                .message = try std.fmt.allocPrint(allocator, "In environment '{s}', '{s}.commands' must be an array or null", .{ env_name, field }),
                .field_path = try std.fmt.allocPrint(allocator, "{s}.{s}.commands", .{ env_name, field }),
            });
        }
    }

    return sc;
}

/// Validates JSON content and returns positioned errors, or null when valid.
/// The validate-only path (`zenv validate`): a thin shim over `loadConfig` that
/// builds-and-discards, so a clean result is a real guarantee the config parses.
pub fn validateJsonContent(allocator: Allocator, content: []const u8) !?ErrorList {
    switch (try loadConfig(allocator, content)) {
        .config => |c| {
            var cfg = c;
            cfg.deinit();
            return null;
        },
        .errors => |errs| return errs,
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

/// Reads `config_path` and returns the built `ZenvConfig`, or prints positioned
/// errors and fails. The production parse path (setup/register): a single call
/// to the parse-and-validate seam — one read, one parse, one walk.
pub fn validateAndParse(allocator: Allocator, config_path: []const u8) !config_module.ZenvConfig {
    const content = runtime.readFileAlloc(allocator, config_path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            var errors = std.array_list.Managed(ValidationError).init(allocator);
            defer {
                for (errors.items) |*e| e.deinit(allocator);
                errors.deinit();
            }
            try errors.append(ValidationError{
                .message = try allocator.dupe(u8, "Configuration file not found"),
                .context = try allocator.dupe(u8, config_path),
            });
            printValidationErrors(allocator, errors);
            return error.InvalidFormat;
        }
        return err;
    };
    defer allocator.free(content);

    switch (try loadConfig(allocator, content)) {
        .errors => |errs| {
            var e = errs;
            defer {
                for (e.items) |*x| x.deinit(allocator);
                e.deinit();
            }
            printValidationErrors(allocator, e);
            return error.InvalidFormat;
        },
        .config => |c| return c,
    }
}

// ============================ Tests ============================

const testing = std.testing;

fn freeErrors(a: Allocator, errs: *std.array_list.Managed(ValidationError)) void {
    for (errs.items) |*e| e.deinit(a);
    errs.deinit();
}

test "loadConfig builds a valid config (the formerly-untested build path)" {
    const a = testing.allocator;
    const content =
        \\{
        \\  "base_dir": "venvs",
        \\  "dev": {
        \\    "target_machines": ["*", "jureca"],
        \\    "description": "d",
        \\    "modules": ["Python", "GCC"],
        \\    "module_cache": false,
        \\    "setup": { "commands": ["echo hi"], "script": "s.sh" }
        \\  }
        \\}
    ;
    var result = try loadConfig(a, content);
    switch (result) {
        .errors => |*e| {
            freeErrors(a, e);
            return error.TestUnexpectedResult;
        },
        .config => |*cfg| {
            defer cfg.deinit();
            try testing.expectEqualStrings("venvs", cfg.base_dir);
            const env = cfg.getEnvironment("dev").?;
            try testing.expectEqual(@as(usize, 2), env.target_machines.items.len);
            try testing.expectEqualStrings("*", env.target_machines.items[0]);
            try testing.expectEqual(@as(usize, 2), env.modules.items.len);
            try testing.expectEqual(false, env.module_cache);
            try testing.expect(env.setup != null);
            try testing.expectEqualStrings("s.sh", env.setup.?.script.?);
            try testing.expectEqual(@as(usize, 1), env.setup.?.commands.?.items.len);
        },
    }
}

test "loadConfig: empty target_machines is now an error (validate == setup)" {
    const a = testing.allocator;
    const content =
        \\{ "base_dir": "z", "e": { "target_machines": [] } }
    ;
    var result = try loadConfig(a, content);
    switch (result) {
        .config => |*cfg| {
            cfg.deinit();
            return error.TestUnexpectedResult;
        },
        .errors => |*e| {
            defer freeErrors(a, e);
            try testing.expect(e.items.len >= 1);
        },
    }
}

test "loadConfig: a non-string array item is rejected (strict; was silently skipped)" {
    const a = testing.allocator;
    const content =
        \\{ "base_dir": "z", "e": { "target_machines": ["ok"], "modules": ["a", 5, "b"] } }
    ;
    var result = try loadConfig(a, content);
    switch (result) {
        .config => |*cfg| {
            cfg.deinit();
            return error.TestUnexpectedResult;
        },
        .errors => |*e| {
            defer freeErrors(a, e);
            var found = false;
            for (e.items) |it| {
                if (std.mem.indexOf(u8, it.message, "modules[1]") != null) found = true;
            }
            try testing.expect(found);
        },
    }
}

test "loadConfig: an unknown environment field is rejected by the whitelist" {
    const a = testing.allocator;
    const content =
        \\{ "base_dir": "z", "e": { "target_machines": ["*"], "bogus": 1 } }
    ;
    var result = try loadConfig(a, content);
    switch (result) {
        .config => |*cfg| {
            cfg.deinit();
            return error.TestUnexpectedResult;
        },
        .errors => |*e| {
            defer freeErrors(a, e);
            var found = false;
            for (e.items) |it| {
                if (std.mem.indexOf(u8, it.message, "bogus") != null) found = true;
            }
            try testing.expect(found);
        },
    }
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

test "validateJsonContent: module_cache must be boolean" {
    const a = testing.allocator;
    const content =
        \\{
        \\  "base_dir": "zenv",
        \\  "good": { "target_machines": ["*"], "module_cache": false },
        \\  "bad": { "target_machines": ["*"], "module_cache": "yes" }
        \\}
    ;
    var errs = (try validateJsonContent(a, content)).?;
    defer freeErrors(a, &errs);
    try testing.expectEqual(@as(usize, 1), errs.items.len);
    try testing.expectEqualStrings("bad.module_cache", errs.items[0].field_path.?);
}

test "validateJsonContent: module_cache true/absent is valid" {
    const a = testing.allocator;
    const content =
        \\{ "base_dir": "zenv", "e1": { "target_machines": ["*"], "module_cache": true } }
    ;
    try testing.expect((try validateJsonContent(a, content)) == null);
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
