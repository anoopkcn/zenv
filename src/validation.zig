//! Validates a zenv.json and builds its `config.Project` in one pass, with
//! every problem reported at its line and field.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;
const paths = @import("paths.zig");
const output = @import("output.zig");
const config = @import("config.zig");
const envspec = @import("envspec.zig");

/// One problem found in a zenv.json, with its position when known.
pub const Problem = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8,
    context: ?[]const u8 = null,
    field_path: ?[]const u8 = null,

    pub fn deinit(self: *Problem, allocator: Allocator) void {
        allocator.free(self.message);
        if (self.context) |ctx| allocator.free(ctx);
        if (self.field_path) |path| allocator.free(path);
    }
};

const StrList = std.ArrayList([]const u8);
const ErrorList = std.ArrayList(Problem);

/// Records a problem whose message and field path are formatted from
/// `message`/`message_args` and `path`/`path_args`.
fn addProblem(
    allocator: Allocator,
    errors: *ErrorList,
    comptime message: []const u8,
    message_args: anytype,
    comptime path: []const u8,
    path_args: anytype,
) !void {
    const owned_message = try allocator.print(message, message_args);
    errdefer allocator.free(owned_message);
    const owned_path = try allocator.print(path, path_args);
    errdefer allocator.free(owned_path);
    try errors.append(allocator, .{ .message = owned_message, .field_path = owned_path });
}

/// Outcome of the single parse-and-validate seam: either the built config or the
/// full list of positioned errors, never both.
pub const LoadResult = union(enum) {
    config: config.Project,
    errors: ErrorList,
};

/// THE parse-and-validate seam. Parses `content` once (an owned tree, with
/// Diagnostics for syntax positions), then walks it a single time to BOTH
/// validate and build the typed `config.Project`. The schema — every field name,
/// type, required-ness, and the environment whitelist — is described exactly
/// here and nowhere else. A passing result therefore guarantees the config also
/// builds, which is the whole point of unifying the two former encodings.
pub fn loadConfig(allocator: Allocator, content: []const u8) !LoadResult {
    var errors: ErrorList = .empty;
    errdefer freeErrors(allocator, &errors);

    var scanner = json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();
    var diag: json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);

    var parsed = json.parseFromTokenSource(
        json.Value,
        allocator,
        &scanner,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try errors.append(allocator, Problem{
                .line = diag.getLine(),
                .column = diag.getColumn(),
                .message = try allocator.print("Invalid JSON syntax: {t}", .{err}),
                .context = lineAt(allocator, content, diag.getLine()) catch null,
                // field_path left null: a syntax error has no schema path.
            });
            return .{ .errors = errors };
        },
    };
    // Every built field is duped, so the tree is not needed beyond this walk.
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try addProblem(
            allocator,
            &errors,
            "Root configuration must be a JSON object",
            .{},
            "",
            .{},
        );
        return .{ .errors = errors };
    }

    var project = config.Project{
        .allocator = allocator,
        .base_dir = try allocator.dupe(u8, ".zenv"), // the default when absent
    };
    errdefer project.deinit();

    // base_dir: optional string.
    if (root.object.get("base_dir")) |bd| {
        if (bd == .string) {
            const dup = try allocator.dupe(u8, bd.string);
            allocator.free(project.base_dir);
            project.base_dir = dup;
        } else {
            try addProblem(allocator, &errors, "'base_dir' must be a string", .{}, "base_dir", .{});
        }
    }

    // Environments: every top-level key except base_dir.
    var has_envs = false;
    for (root.object.keys(), root.object.values()) |key, env_value| {
        if (std.mem.eql(u8, key, "base_dir")) continue;
        has_envs = true;
        if (!paths.isValidEnvName(key)) {
            try addProblem(
                allocator,
                &errors,
                "Invalid environment name '{s}': use letters, digits, '_', '-' and '.' (not '.' or '..')",
                .{key},
                "{s}",
                .{key},
            );
            continue;
        }

        if (try buildEnv(allocator, &errors, env_value, key)) |built| {
            var env = built;
            errdefer env.deinit();
            const env_key = try allocator.dupe(u8, key);
            errdefer allocator.free(env_key);
            try project.environments.put(allocator, env_key, env);
        }
    }

    if (!has_envs) {
        try addProblem(
            allocator,
            &errors,
            "At least one environment must be defined",
            .{},
            "",
            .{},
        );
    }

    if (errors.items.len > 0) {
        fillPositions(allocator, content, errors.items);
        project.deinit();
        return .{ .errors = errors };
    }

    errors.deinit(allocator);
    return .{ .config = project };
}

/// Validates one environment AND builds its `config.Env` in the same pass.
/// Records positioned errors for any problem and returns the always-deinit-safe
/// env (the caller discards it if the overall config has any errors), or null
/// when the value isn't an object.
fn buildEnv(
    allocator: Allocator,
    errors: *ErrorList,
    value: json.Value,
    env_name: []const u8,
) !?config.Env {
    if (value != .object) {
        try addProblem(
            allocator,
            errors,
            "Environment '{s}' must be an object",
            .{env_name},
            "{s}",
            .{env_name},
        );
        return null;
    }

    var env = config.Env.init(allocator);
    errdefer env.deinit();

    // target_machines: required, non-empty array of strings.
    if (value.object.get("target_machines")) |tm| {
        if (tm == .array and tm.array.items.len == 0) {
            try addProblem(
                allocator,
                errors,
                "In environment '{s}', 'target_machines' must not be empty",
                .{env_name},
                "{s}.target_machines",
                .{env_name},
            );
        }
    } else {
        try addProblem(
            allocator,
            errors,
            "Environment '{s}' is missing required 'target_machines' field",
            .{env_name},
            "{s}",
            .{env_name},
        );
    }
    // The typed fields, in the order their errors are reported.
    inline for (.{
        "target_machines", "description",  "fallback_python",  "modules_file", "dependency_file",
        "modules",         "dependencies", "dev_dependencies", "module_cache", "python",
    }) |field| try buildField(allocator, errors, value, env_name, field, &@field(env, field));

    // A Python-free env has nothing to install into.
    if (!env.python) {
        const fields = [_]struct { name: []const u8, set: bool }{
            .{ .name = "dependencies", .set = env.dependencies.items.len > 0 },
            .{ .name = "dev_dependencies", .set = env.dev_dependencies.items.len > 0 },
            .{ .name = "dependency_file", .set = env.dependency_file != null },
        };
        for (fields) |f| {
            if (!f.set) continue;
            try addProblem(
                allocator,
                errors,
                "In environment '{s}', '{s}' needs Python, but 'python' is false. Set \"python\": true or remove '{s}'.",
                .{ env_name, f.name, f.name },
                "{s}.{s}",
                .{ env_name, f.name },
            );
        }
    }

    try buildEnvVars(allocator, errors, value, env_name, &env.env);

    env.setup = try buildHook(allocator, errors, value, env_name, "setup");
    env.activate = try buildHook(allocator, errors, value, env_name, "activate");

    // Whitelist: every other field is unrecognized.
    const allowed = [_][]const u8{
        "target_machines", "description",      "modules",         "modules_file", "dependencies",
        "dependency_file", "dev_dependencies", "fallback_python", "setup",        "activate",
        "module_cache",    "python",           "env",
    };
    for (value.object.keys()) |fname| {
        for (allowed) |a| {
            if (std.mem.eql(u8, fname, a)) break;
        } else try addProblem(
            allocator,
            errors,
            "In environment '{s}', '{s}' is not a recognized field.",
            .{ env_name, fname },
            "{s}.{s}",
            .{ env_name, fname },
        );
    }

    return env;
}

/// Validates+builds the optional field at `path` of `obj` into `out`: a
/// string or a boolean (null keeps the default), or an array of strings. `path`
/// names the field in messages ("description", "setup.script"); its last
/// segment is the key in `obj`.
fn buildField(
    allocator: Allocator,
    errors: *ErrorList,
    obj: json.Value,
    env_name: []const u8,
    comptime path: []const u8,
    out: anytype,
) !void {
    const key = comptime path[if (std.mem.findScalarLast(u8, path, '.')) |dot| dot + 1 else 0..];
    const v = obj.object.get(key) orelse return;
    switch (@TypeOf(out)) {
        *?[]const u8 => switch (v) {
            .string => |s| out.* = try allocator.dupe(u8, s),
            .null => {},
            else => try addProblem(
                allocator,
                errors,
                "In environment '{s}', '{s}' must be a string or null",
                .{ env_name, path },
                "{s}.{s}",
                .{ env_name, path },
            ),
        },
        *bool => switch (v) {
            .bool => |b| out.* = b,
            .null => {},
            else => try addProblem(
                allocator,
                errors,
                "In environment '{s}', '{s}' must be a boolean or null",
                .{ env_name, path },
                "{s}.{s}",
                .{ env_name, path },
            ),
        },
        *StrList => if (v == .array)
            try takeStrings(allocator, errors, v.array.items, env_name, path, out)
        else
            try addProblem(
                allocator,
                errors,
                "In environment '{s}', '{s}' must be an array",
                .{ env_name, path },
                "{s}.{s}",
                .{ env_name, path },
            ),
        else => @compileError("no builder for " ++ @typeName(@TypeOf(out))),
    }
}

/// Appends a copy of every string in `items` to `out` and records an error for
/// each item that is not a string. `path` names the array in messages.
fn takeStrings(
    allocator: Allocator,
    errors: *ErrorList,
    items: []const json.Value,
    env_name: []const u8,
    path: []const u8,
    out: *StrList,
) !void {
    try out.ensureUnusedCapacity(allocator, items.len);
    for (items, 0..) |item, i| {
        if (item == .string) {
            out.appendAssumeCapacity(try allocator.dupe(u8, item.string));
        } else try addProblem(
            allocator,
            errors,
            "In environment '{s}', '{s}[{d}]' must be a string",
            .{ env_name, path, i },
            "{s}.{s}[{d}]",
            .{ env_name, path, i },
        );
    }
}

/// Variables zenv's activation owns. Setting them from `env` would break the
/// venv or the prompt, or (PYTHONHOME, kept by the venv convention) would not
/// be unset again by deactivate.
const reserved_env_names = [_][]const u8{
    "VIRTUAL_ENV",
    "VIRTUAL_ENV_PROMPT",
    "ZENV_ENV_DIR",
    "PYTHONHOME",
    "PS1",
};
/// Prefixes of the variables activation saves old values in.
const reserved_env_prefixes = [_][]const u8{ "_ZENV_", "_OLD_VIRTUAL_" };

/// Why `name` cannot be set from `env` with `kind`, or null when it can.
fn envNameProblem(name: []const u8, kind: config.EnvVar.Kind) ?[]const u8 {
    if (!envspec.isIdentifier(name)) return "is not a valid variable name";
    for (reserved_env_names) |r| if (std.mem.eql(
        u8,
        name,
        r,
    )) return "is managed by zenv's activation";
    for (reserved_env_prefixes) |r| if (std.mem.startsWith(
        u8,
        name,
        r,
    )) return "is managed by zenv's activation";
    if (kind == .set and std.mem.eql(
        u8,
        name,
        "PATH",
    )) return "can only be extended: use {\"prepend\": ...} or {\"append\": ...}";
    return null;
}

/// Validates+builds the optional `env` object: NAME -> "value" (set), or
/// NAME -> {"prepend": "value"} / {"append": "value"}.
fn buildEnvVars(
    allocator: Allocator,
    errors: *ErrorList,
    value: json.Value,
    env_name: []const u8,
    out: *std.ArrayList(config.EnvVar),
) !void {
    const v = value.object.get("env") orelse return;
    if (v == .null) return;
    if (v != .object) {
        try addProblem(
            allocator,
            errors,
            "In environment '{s}', 'env' must be an object or null",
            .{env_name},
            "{s}.env",
            .{env_name},
        );
        return;
    }
    for (v.object.keys(), v.object.values()) |name, entry| {
        var kind: config.EnvVar.Kind = .set;
        const text: ?[]const u8 = switch (entry) {
            .string => |s| s,
            .object => |o| blk: {
                if (o.count() != 1) break :blk null;
                const key = o.keys()[0];
                kind = if (std.mem.eql(
                    u8,
                    key,
                    "prepend",
                )) .prepend else if (std.mem.eql(u8, key, "append")) .append else break :blk null;
                break :blk if (o.values()[0] == .string) o.values()[0].string else null;
            },
            else => null,
        };
        const problem: ?[]const u8 = if (text == null)
            "must be a string, {\"prepend\": \"...\"} or {\"append\": \"...\"}"
        else
            envNameProblem(name, kind);
        if (problem) |p| {
            try addProblem(
                allocator,
                errors,
                "In environment '{s}', env variable '{s}' {s}",
                .{ env_name, name, p },
                "{s}.env.{s}",
                .{ env_name, name },
            );
            continue;
        }
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_value = try allocator.dupe(u8, text.?);
        errdefer allocator.free(owned_value);
        try out.append(allocator, .{ .name = owned_name, .value = owned_value, .kind = kind });
    }
}

/// Validates+builds an optional `setup`/`activate` object; absent or null is
/// an empty hook.
fn buildHook(
    allocator: Allocator,
    errors: *ErrorList,
    value: json.Value,
    env_name: []const u8,
    comptime field: []const u8,
) !config.Hook {
    const v = value.object.get(field) orelse return .{};
    if (v == .null) return .{};
    if (v != .object) {
        try addProblem(
            allocator,
            errors,
            "In environment '{s}', '{s}' must be an object or null",
            .{ env_name, field },
            "{s}.{s}",
            .{ env_name, field },
        );
        return .{};
    }

    var hook: config.Hook = .{};
    errdefer hook.deinit(allocator);

    try buildField(allocator, errors, v, env_name, field ++ ".script", &hook.script);

    if (v.object.get("commands")) |cmds| {
        if (cmds == .array) {
            try takeStrings(
                allocator,
                errors,
                cmds.array.items,
                env_name,
                field ++ ".commands",
                &hook.commands,
            );
        } else if (cmds != .null) {
            try addProblem(
                allocator,
                errors,
                "In environment '{s}', '{s}.commands' must be an array or null",
                .{ env_name, field },
                "{s}.{s}.commands",
                .{ env_name, field },
            );
        }
    }

    return hook;
}

const Position = struct {
    line: usize,
    column: usize,
};

/// Builds a map from dotted field path (e.g. "myenv.target_machines[0]") to the
/// position of that value in the source, by walking the token stream once.
/// Container values record the position of their opening token; the empty
/// string key "" is the document root. Positions come from the parser's own
/// `Diagnostics`, so they are exact and repeat-proof. Nothing is freed
/// individually: `allocator` is an arena.
fn buildPositionMap(
    allocator: Allocator,
    content: []const u8,
) !std.StringHashMapUnmanaged(Position) {
    var map: std.StringHashMapUnmanaged(Position) = .empty;
    var scanner = json.Scanner.initCompleteInput(allocator, content);
    var diag: json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);

    // One frame per open container; `base_len` is the length of its path.
    const Frame = struct {
        is_object: bool,
        expecting_key: bool,
        index: usize = 0,
        base_len: usize,
    };
    var frames: std.ArrayList(Frame) = .empty;
    var path: std.ArrayList(u8) = .empty;

    while (true) {
        // Peeking skips the whitespace, ',' and ':' before the next token, so
        // the position is the token's start (Diagnostics otherwise reports the
        // end of the token just consumed).
        _ = try scanner.peekNextTokenType();
        const before = Position{ .line = diag.getLine(), .column = diag.getColumn() };
        const tok = try scanner.nextAlloc(allocator, .alloc_if_needed);
        switch (tok) {
            .end_of_document => break,
            .object_end, .array_end => {
                _ = frames.pop();
                continue;
            },
            else => {},
        }

        // Point `path` at this value (the root's is ""), or take an object key.
        if (frames.lastPtr()) |top| {
            if (top.expecting_key) {
                path.shrinkRetainingCapacity(top.base_len);
                if (top.base_len > 0) try path.append(allocator, '.');
                switch (tok) {
                    .string, .allocated_string => |key| try path.appendSlice(allocator, key),
                    else => {},
                }
                top.expecting_key = false;
                continue;
            }
            if (top.is_object) {
                top.expecting_key = true; // `path` already holds the key
            } else {
                path.shrinkRetainingCapacity(top.base_len);
                try path.print(allocator, "[{d}]", .{top.index});
                top.index += 1;
            }
        }
        try map.put(allocator, try allocator.dupe(u8, path.items), before);

        switch (tok) {
            .object_begin, .array_begin => try frames.append(allocator, .{
                .is_object = tok == .object_begin,
                .expecting_key = tok == .object_begin,
                .base_len = path.items.len,
            }),
            else => {},
        }
    }
    return map;
}

/// Backfills accurate line/column/context for each semantic error from the
/// position map, keyed by each error's `field_path`. Errors whose path is not
/// found keep their default (0, 0) position.
fn fillPositions(allocator: Allocator, content: []const u8, errors: []Problem) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var map = buildPositionMap(arena.allocator(), content) catch return;

    for (errors) |*e| {
        const key = e.field_path orelse "";
        if (map.get(key)) |pos| {
            e.line = pos.line;
            e.column = pos.column;
            if (e.context) |old| allocator.free(old);
            e.context = lineAt(allocator, content, pos.line) catch null;
        }
    }
}

/// The text of line `line_number` (1-based) of `content`, or null past its end.
fn lineAt(allocator: Allocator, content: []const u8, line_number: usize) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var n: usize = 1;
    while (lines.next()) |line| : (n += 1) {
        if (n == line_number) return try allocator.dupe(u8, line);
    }
    return null;
}

fn printProblems(io: Io, errors: []const Problem) void {
    for (errors, 0..) |err, i| {
        if (i > 0) output.printError(io, "", .{});

        if (err.line > 0) {
            output.printError(
                io,
                "at line {d}, column {d}: {s}",
                .{ err.line, err.column, err.message },
            );
        } else {
            output.printError(io, "{s}", .{err.message});
        }

        if (err.field_path) |path| {
            if (path.len > 0) output.printError(io, "In field: {s}", .{path});
        }

        if (err.context) |ctx| {
            output.printError(io, "Context: {s}", .{ctx});
            // A '^' under the column ("" padded to the column with spaces).
            if (err.column > 0) output.printError(
                io,
                "         {s:[1]}^",
                .{ "", @min(err.column - 1, ctx.len) },
            );
        }
    }
}

/// Reads `config_path` and returns the built `config.Project`, or prints positioned
/// errors and fails. The production parse path (setup/register): a single call
/// to the parse-and-validate seam — one read, one parse, one walk.
pub fn validateAndParse(allocator: Allocator, io: Io, config_path: []const u8) !config.Project {
    const content = Io.Dir.cwd().readFileAlloc(
        io,
        config_path,
        allocator,
        .limited(10 * 1024 * 1024),
    ) catch |err| {
        if (err == error.FileNotFound) {
            output.printError(io, "Configuration file not found", .{});
            output.printError(io, "Context: {s}", .{config_path});
            return error.InvalidFormat;
        }
        return err;
    };
    defer allocator.free(content);

    switch (try loadConfig(allocator, content)) {
        .errors => |errs| {
            var e = errs;
            defer freeErrors(allocator, &e);
            printProblems(io, e.items);
            return error.InvalidFormat;
        },
        .config => |c| return c,
    }
}

/// Frees an error list returned by `loadConfig` or `validateJsonContent`.
pub fn freeErrors(allocator: Allocator, errors: *ErrorList) void {
    for (errors.items) |*e| e.deinit(allocator);
    errors.deinit(allocator);
}

// ============================ Tests ============================

const testing = std.testing;

/// The errors `loadConfig` finds in `content`, or null for a valid config.
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

test "validateJsonContent: script and string-array errors keep their messages and paths" {
    const a = testing.allocator;
    const content =
        \\{ "base_dir": "z", "e": { "target_machines": [1], "module_cache": "x",
        \\  "setup": { "script": 5, "commands": ["ok", 2] } } }
    ;
    var errs = (try validateJsonContent(a, content)).?;
    defer freeErrors(a, &errs);
    const want = [_][2][]const u8{
        .{ "e.target_machines[0]", "In environment 'e', 'target_machines[0]' must be a string" },
        .{ "e.module_cache", "In environment 'e', 'module_cache' must be a boolean or null" },
        .{ "e.setup.script", "In environment 'e', 'setup.script' must be a string or null" },
        .{ "e.setup.commands[1]", "In environment 'e', 'setup.commands[1]' must be a string" },
    };
    try testing.expectEqual(want.len, errs.items.len);
    for (want, errs.items) |w, e| {
        try testing.expectEqualStrings(w[0], e.field_path.?);
        try testing.expectEqualStrings(w[1], e.message);
    }
    try testing.expectEqual(@as(usize, 2), errs.items[3].line);
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
            try testing.expectEqualStrings("s.sh", env.setup.script.?);
            try testing.expectEqual(@as(usize, 1), env.setup.commands.items.len);
        },
    }
}

test "loadConfig: base_dir is optional and defaults to .zenv" {
    const a = testing.allocator;
    var result = try loadConfig(a,
        \\{ "e": { "target_machines": ["*"] } }
    );
    switch (result) {
        .errors => |*errs| {
            freeErrors(a, errs);
            return error.TestUnexpectedResult;
        },
        .config => |*cfg| {
            defer cfg.deinit();
            try testing.expectEqualStrings(".zenv", cfg.base_dir);
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
                if (std.mem.find(u8, it.message, "modules[1]") != null) found = true;
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
                if (std.mem.find(u8, it.message, "bogus") != null) found = true;
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

test "validateJsonContent: a value is located at its own line and column, not the separator before it" {
    const a = testing.allocator;
    const content =
        \\{
        \\  "base_dir": "zenv",
        \\  "e": {
        \\    "target_machines": ["*"],
        \\    "modules": [
        \\      "a",
        \\      5
        \\    ],
        \\    "module_cache":
        \\      "yes"
        \\  }
        \\}
    ;
    var errs = (try validateJsonContent(a, content)).?;
    defer freeErrors(a, &errs);
    try testing.expectEqual(@as(usize, 2), errs.items.len);
    try testing.expectEqualStrings("e.modules[1]", errs.items[0].field_path.?);
    try testing.expectEqual(@as(usize, 7), errs.items[0].line);
    try testing.expectEqual(@as(usize, 7), errs.items[0].column);
    try testing.expectEqualStrings("e.module_cache", errs.items[1].field_path.?);
    try testing.expectEqual(@as(usize, 10), errs.items[1].line);
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

test "validateJsonContent: python must be boolean and false forbids dependencies" {
    const a = testing.allocator;
    const content =
        \\{
        \\  "base_dir": "zenv",
        \\  "plain": { "target_machines": ["*"], "python": false, "dependencies": [], "dependency_file": null },
        \\  "bad": { "target_machines": ["*"], "python": "no" },
        \\  "deps": { "target_machines": ["*"], "python": false, "dependencies": ["numpy"], "dependency_file": "requirements.txt" }
        \\}
    ;
    var errs = (try validateJsonContent(a, content)).?;
    defer freeErrors(a, &errs);
    try testing.expectEqual(@as(usize, 3), errs.items.len);
    for ([_][]const u8{ "bad.python", "deps.dependencies", "deps.dependency_file" }) |want| {
        const found = for (errs.items) |e| {
            if (std.mem.eql(u8, e.field_path.?, want)) break true;
        } else false;
        try testing.expect(found);
    }
}

test "loadConfig: python defaults to true and reads false" {
    const a = testing.allocator;
    const content =
        \\{ "base_dir": "zenv", "on": { "target_machines": ["*"] }, "off": { "target_machines": ["*"], "python": false } }
    ;
    var result = try loadConfig(a, content);
    switch (result) {
        .errors => |*e| {
            freeErrors(a, e);
            return error.TestUnexpectedResult;
        },
        .config => |*cfg| {
            defer cfg.deinit();
            try testing.expect(cfg.getEnvironment("on").?.python);
            try testing.expect(!cfg.getEnvironment("off").?.python);
        },
    }
}

test "loadConfig: env keeps file order, kinds and raw values" {
    const a = testing.allocator;
    const content =
        \\{ "base_dir": "zenv", "e": { "target_machines": ["*"], "env": {
        \\  "DATA": "${ZENV_PROJECT_DIR}/data",
        \\  "PATH": { "prepend": "${ZENV_ENV_DIR}/tools" },
        \\  "LD_LIBRARY_PATH": { "append": "/opt/x/lib" },
        \\  "EMPTY": ""
        \\} } }
    ;
    var result = try loadConfig(a, content);
    switch (result) {
        .errors => |*e| {
            freeErrors(a, e);
            return error.TestUnexpectedResult;
        },
        .config => |*cfg| {
            defer cfg.deinit();
            const vars = cfg.getEnvironment("e").?.env.items;
            try testing.expectEqual(@as(usize, 4), vars.len);
            try testing.expectEqualStrings("DATA", vars[0].name);
            try testing.expectEqualStrings("${ZENV_PROJECT_DIR}/data", vars[0].value);
            try testing.expectEqual(config.EnvVar.Kind.set, vars[0].kind);
            try testing.expectEqual(config.EnvVar.Kind.prepend, vars[1].kind);
            try testing.expectEqual(config.EnvVar.Kind.append, vars[2].kind);
            try testing.expectEqualStrings("", vars[3].value);
        },
    }
}

test "validateJsonContent: bad env entries are reported by name" {
    const a = testing.allocator;
    const content =
        \\{ "base_dir": "zenv", "e": { "target_machines": ["*"], "env": {
        \\  "OK": "1",
        \\  "1BAD": "x",
        \\  "VIRTUAL_ENV": "/x",
        \\  "_ZENV_ACTIVE": "1",
        \\  "PATH": "/x",
        \\  "NUM": 3,
        \\  "BOTH": { "prepend": "a", "append": "b" },
        \\  "WHAT": { "insert": "a" }
        \\} } }
    ;
    var errs = (try validateJsonContent(a, content)).?;
    defer freeErrors(a, &errs);
    const want = [_][]const u8{
        "e.env.1BAD",
        "e.env.VIRTUAL_ENV",
        "e.env._ZENV_ACTIVE",
        "e.env.PATH",
        "e.env.NUM",
        "e.env.BOTH",
        "e.env.WHAT",
    };
    try testing.expectEqual(want.len, errs.items.len);
    for (want, errs.items) |w, e| try testing.expectEqualStrings(w, e.field_path.?);
}

test "validateJsonContent: a missing base_dir is not a problem" {
    const content =
        \\{ "e1": { "target_machines": ["*"] } }
    ;
    try testing.expect((try validateJsonContent(testing.allocator, content)) == null);
}
