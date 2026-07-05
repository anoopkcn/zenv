//! Writers that record a dependency added by `zenv add` into the project's
//! manifest files. Three destinations, each kept small and unit-testable:
//!   - requirements.txt  : append/replace a line.
//!   - pyproject.toml     : surgical text edit (zig-toml is read-only, so we
//!                          can't round-trip; we preserve the file otherwise).
//!   - zenv.json          : parse -> mutate the Value tree -> re-stringify,
//!                          the same pattern EnvironmentRegistry.save uses.
//!
//! De-duplication is by bare package name (case-insensitive) via
//! `parse_deps.samePackage`: re-adding a package replaces its spec (so the pin
//! updates) instead of appending a duplicate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Value = json.Value;
const Array = json.Array;
const runtime = @import("runtime.zig");
const output = @import("output.zig");
const parse_deps = @import("parse_deps.zig");

const MAX_FILE = 10 * 1024 * 1024;

// =======================================================================
// requirements.txt
// =======================================================================

/// Appends `spec` to the requirements file at `path` (creating it if absent),
/// or replaces the existing line for the same package. Preserves all other
/// lines (comments, blanks, ordering) verbatim.
pub fn addToRequirementsTxt(allocator: Allocator, path: []const u8, spec: []const u8) !void {
    const content = runtime.readFileAlloc(allocator, path, MAX_FILE) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(content);

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var replaced = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (it.next()) |line| {
        // Drop a pure trailing-empty segment so we don't accumulate blank lines
        // on every rewrite; real blank lines between entries are preserved.
        if (it.peek() == null and line.len == 0) break;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        const is_entry = trimmed.len > 0 and trimmed[0] != '#';
        if (is_entry and !replaced and parse_deps.samePackage(trimmed, spec)) {
            if (!first) try out.append('\n');
            try out.appendSlice(spec);
            replaced = true;
        } else {
            if (!first) try out.append('\n');
            try out.appendSlice(line);
        }
        first = false;
    }

    if (!replaced) {
        if (!first) try out.append('\n');
        try out.appendSlice(spec);
    }
    try out.append('\n');

    try runtime.writeFileAtomic(allocator, path, out.items);
}

// =======================================================================
// zenv.json
// =======================================================================

/// Records `spec` in the `dependencies` (or `dev_dependencies` when `dev`)
/// array of environment `env_name` inside the zenv.json at `path`. Re-emits the
/// whole document with 2-space indentation; key order is preserved because
/// `json.ObjectMap` is an insertion-ordered array hash map. The target array is
/// created if it does not yet exist.
pub fn addToZenvJson(
    allocator: Allocator,
    path: []const u8,
    env_name: []const u8,
    spec: []const u8,
    dev: bool,
) !void {
    const content = try runtime.readFileAlloc(allocator, path, MAX_FILE);
    defer allocator.free(content);

    var parsed = try json.parseFromSlice(json.Value, allocator, content, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const a = parsed.arena.allocator();

    if (parsed.value != .object) return error.InvalidFormat;
    const env_ptr = parsed.value.object.getPtr(env_name) orelse return error.EnvironmentNotFound;
    if (env_ptr.* != .object) return error.InvalidFormat;

    const key: []const u8 = if (dev) "dev_dependencies" else "dependencies";

    // Get-or-create the target array on the environment object.
    const arr_ptr: *Value = blk: {
        if (env_ptr.object.getPtr(key)) |p| {
            if (p.* == .array) break :blk p;
            p.* = Value{ .array = Array.init(a) }; // wrong type -> replace
            break :blk p;
        }
        const owned_key = try a.dupe(u8, key);
        const gop = try env_ptr.object.getOrPut(a, owned_key);
        gop.value_ptr.* = Value{ .array = Array.init(a) };
        break :blk gop.value_ptr;
    };

    // De-dup by package name: replace an existing spec, else append.
    const owned_spec = try a.dupe(u8, spec);
    var replaced = false;
    for (arr_ptr.array.items) |*item| {
        if (item.* == .string and parse_deps.samePackage(item.string, spec)) {
            item.* = Value{ .string = owned_spec };
            replaced = true;
            break;
        }
    }
    if (!replaced) try arr_ptr.array.append(Value{ .string = owned_spec });

    const out = try json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(out);
    try runtime.writeFileAtomic(allocator, path, out);
}

// =======================================================================
// pyproject.toml
// =======================================================================

/// Records `spec` in pyproject.toml. Runtime deps go to `[project].dependencies`
/// (PEP 621); dev deps (`dev = true`) go to `[dependency-groups].dev` (PEP 735).
/// Returns false when the runtime target can't be located/created (no `[project]`
/// table) so the caller can fall back to zenv.json; dev targets are always
/// created if missing. The edit is textual to preserve comments, key order, and
/// unrelated tables (zig-toml has no serializer to round-trip through).
pub fn addToPyproject(allocator: Allocator, path: []const u8, spec: []const u8, dev: bool) !bool {
    const content = runtime.readFileAlloc(allocator, path, MAX_FILE) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const section: []const u8 = if (dev) "dependency-groups" else "project";
    const key: []const u8 = if (dev) "dev" else "dependencies";

    const new_content = (try editPyproject(a, content, section, key, spec, dev)) orelse return false;
    try runtime.writeFileAtomic(allocator, path, new_content);
    return true;
}

const LineList = std.array_list.Managed([]const u8);

/// True if `t` (a trimmed line) is a TOML table header like `[project]` or
/// `[[tool.x]]`. `headerName` returns the inner text (e.g. "project").
fn isHeader(t: []const u8) bool {
    return t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']';
}
fn headerName(t: []const u8) []const u8 {
    return std.mem.trim(u8, t, "[] \t");
}

/// True if trimmed line `t` is the `key = ...` assignment for `key`.
fn isKeyLine(t: []const u8, key: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, t[0..eq], " \t"), key);
}

/// Returns the leading-whitespace slice of `line`.
fn indentOf(line: []const u8) []const u8 {
    const end = std.mem.indexOfNone(u8, line, " \t") orelse line.len;
    return line[0..end];
}

/// Extracts the string between the first pair of double quotes in `line`, or
/// null. Used to read existing array entries (`    "flask>=2.0",`).
fn quotedValue(line: []const u8) ?[]const u8 {
    const lq = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const rest = line[lq + 1 ..];
    const rq = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..rq];
}

/// Core text edit. Returns the rewritten document (arena-owned) or null when the
/// runtime target is absent and must not be auto-created (caller falls back).
fn editPyproject(
    a: Allocator,
    content: []const u8,
    section: []const u8,
    key: []const u8,
    spec: []const u8,
    create_section: bool,
) !?[]const u8 {
    var lines = LineList.init(a);
    var it = std.mem.splitScalar(u8, content, '\n');
    const trailing_newline = std.mem.endsWith(u8, content, "\n");
    while (it.next()) |line| try lines.append(line);
    // A trailing '\n' yields a final empty element; drop it and re-add on join.
    if (trailing_newline and lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }

    // 1. Locate the [section] header and the span of lines belonging to it.
    var sec_start: ?usize = null;
    var sec_end: usize = lines.items.len;
    for (lines.items, 0..) |line, i| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!isHeader(t)) continue;
        if (sec_start == null) {
            if (std.mem.eql(u8, headerName(t), section)) sec_start = i;
        } else if (i > sec_start.?) {
            sec_end = i;
            break;
        }
    }

    if (sec_start == null) {
        if (!create_section) return null;
        // Append a fresh section + key block at EOF.
        try appendNewBlock(a, &lines, section, key, spec);
        return try joinLines(a, &lines, trailing_newline);
    }

    // 2. Within the section, find the `key = ...` line.
    var key_line: ?usize = null;
    {
        var i = sec_start.? + 1;
        while (i < sec_end) : (i += 1) {
            const t = std.mem.trim(u8, lines.items[i], " \t\r");
            if (isKeyLine(t, key)) {
                key_line = i;
                break;
            }
        }
    }

    if (key_line == null) {
        // Section exists but the array key doesn't: insert it right after header.
        try insertKeyBlock(a, &lines, sec_start.? + 1, key, spec);
        return try joinLines(a, &lines, trailing_newline);
    }

    // 3. Edit the existing array (inline or multi-line).
    const kl = key_line.?;
    const lb = std.mem.indexOfScalar(u8, lines.items[kl], '[') orelse return null;
    const has_close_on_line = std.mem.indexOfScalarPos(u8, lines.items[kl], lb + 1, ']') != null;

    if (has_close_on_line) {
        try editInlineArray(a, &lines, kl, lb, spec);
    } else {
        try editMultilineArray(a, &lines, kl, sec_end, spec);
    }
    return try joinLines(a, &lines, trailing_newline);
}

fn joinLines(a: Allocator, lines: *LineList, trailing_newline: bool) ![]const u8 {
    const body = try std.mem.join(a, "\n", lines.items);
    if (trailing_newline) return std.fmt.allocPrint(a, "{s}\n", .{body});
    return body;
}

/// Appends `\n[section]\nkey = [\n    "spec",\n]` at the end of the document.
fn appendNewBlock(a: Allocator, lines: *LineList, section: []const u8, key: []const u8, spec: []const u8) !void {
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len != 0) {
        try lines.append(""); // blank separator line
    }
    try lines.append(try std.fmt.allocPrint(a, "[{s}]", .{section}));
    try lines.append(try std.fmt.allocPrint(a, "{s} = [", .{key}));
    try lines.append(try std.fmt.allocPrint(a, "    \"{s}\",", .{spec}));
    try lines.append("]");
}

/// Inserts `key = [\n    "spec",\n]` at line index `at`.
fn insertKeyBlock(a: Allocator, lines: *LineList, at: usize, key: []const u8, spec: []const u8) !void {
    try lines.insert(at, try std.fmt.allocPrint(a, "{s} = [", .{key}));
    try lines.insert(at + 1, try std.fmt.allocPrint(a, "    \"{s}\",", .{spec}));
    try lines.insert(at + 2, "]");
}

/// Edits a single-line array `key = [ ... ]` on line `kl`, `lb` = index of '['.
fn editInlineArray(a: Allocator, lines: *LineList, kl: usize, lb: usize, spec: []const u8) !void {
    const line = lines.items[kl];
    const rb = std.mem.indexOfScalarPos(u8, line, lb + 1, ']').?;
    const inner = std.mem.trim(u8, line[lb + 1 .. rb], " \t");

    var entries = std.array_list.Managed([]const u8).init(a);
    var replaced = false;
    if (inner.len > 0) {
        var parts = std.mem.splitScalar(u8, inner, ',');
        while (parts.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len == 0) continue;
            const val = quotedValue(p) orelse p;
            if (!replaced and parse_deps.samePackage(val, spec)) {
                try entries.append(try std.fmt.allocPrint(a, "\"{s}\"", .{spec}));
                replaced = true;
            } else {
                try entries.append(p);
            }
        }
    }
    if (!replaced) try entries.append(try std.fmt.allocPrint(a, "\"{s}\"", .{spec}));

    const joined = try std.mem.join(a, ", ", entries.items);
    lines.items[kl] = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ line[0 .. lb + 1], joined, line[rb..] });
}

/// Edits a multi-line array opened on line `kl`, closed by a line whose trimmed
/// text starts with ']' before `sec_end`.
fn editMultilineArray(a: Allocator, lines: *LineList, kl: usize, sec_end: usize, spec: []const u8) !void {
    // Find the closing-bracket line.
    var close: usize = kl + 1;
    while (close < sec_end) : (close += 1) {
        const t = std.mem.trim(u8, lines.items[close], " \t\r");
        if (t.len > 0 and t[0] == ']') break;
    }

    // Try to replace an existing entry with the same package.
    var i = kl + 1;
    var last_entry: ?usize = null;
    while (i < close) : (i += 1) {
        const val = quotedValue(lines.items[i]) orelse continue;
        last_entry = i;
        if (parse_deps.samePackage(val, spec)) {
            lines.items[i] = try std.fmt.allocPrint(a, "{s}\"{s}\",", .{ indentOf(lines.items[i]), spec });
            return;
        }
    }

    // No match: append a new entry just before the closing bracket. Use the
    // indentation of an existing entry, or the key-line indent + 4 spaces.
    const indent = if (last_entry) |le| indentOf(lines.items[le]) else try std.fmt.allocPrint(a, "{s}    ", .{indentOf(lines.items[kl])});

    // Ensure the previous last entry carries a trailing comma so the array stays
    // valid once another element follows it.
    if (last_entry) |le| {
        const t = std.mem.trimEnd(u8, lines.items[le], " \t\r");
        if (!std.mem.endsWith(u8, t, ",")) {
            lines.items[le] = try std.fmt.allocPrint(a, "{s},", .{t});
        }
    }

    try lines.insert(close, try std.fmt.allocPrint(a, "{s}\"{s}\",", .{ indent, spec }));
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");

// --- pyproject (pure, no I/O) ---

test "pyproject: appends a runtime dep to a multi-line [project].dependencies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\[project]
        \\name = "demo"
        \\dependencies = [
        \\    "requests>=2.28",
        \\]
        \\
        \\[tool.ruff]
        \\line-length = 100
        \\
    ;
    const out = (try editPyproject(a, src, "project", "dependencies", "flask>=3.0", false)).?;
    try testing.expect(std.mem.indexOf(u8, out, "\"flask>=3.0\",") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"requests>=2.28\",") != null);
    // Unrelated table preserved.
    try testing.expect(std.mem.indexOf(u8, out, "line-length = 100") != null);
    // Appended after the existing entry but still inside the [project] table
    // (before the [tool.ruff] section).
    try testing.expect(std.mem.indexOf(u8, out, "requests>=2.28").? < std.mem.indexOf(u8, out, "flask>=3.0").?);
    try testing.expect(std.mem.indexOf(u8, out, "flask>=3.0").? < std.mem.indexOf(u8, out, "[tool.ruff]").?);
}

test "pyproject: replaces an existing runtime dep (updates the pin)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\[project]
        \\dependencies = [
        \\    "flask>=2.0",
        \\    "numpy",
        \\]
        \\
    ;
    const out = (try editPyproject(a, src, "project", "dependencies", "flask==3.1", false)).?;
    try testing.expect(std.mem.indexOf(u8, out, "flask==3.1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "flask>=2.0") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"numpy\"") != null);
}

test "pyproject: fills an empty inline array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\[project]
        \\dependencies = []
        \\
    ;
    const out = (try editPyproject(a, src, "project", "dependencies", "rich", false)).?;
    try testing.expect(std.mem.indexOf(u8, out, "dependencies = [\"rich\"]") != null);
}

test "pyproject: dev dep creates [dependency-groups] at EOF when absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\[project]
        \\name = "demo"
        \\dependencies = []
        \\
    ;
    const out = (try editPyproject(a, src, "dependency-groups", "dev", "pytest>=8", true)).?;
    try testing.expect(std.mem.indexOf(u8, out, "[dependency-groups]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "dev = [") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"pytest>=8\",") != null);
}

test "pyproject: dev dep adds the dev key under an existing [dependency-groups]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\[project]
        \\name = "demo"
        \\
        \\[dependency-groups]
        \\test = ["coverage"]
        \\
    ;
    const out = (try editPyproject(a, src, "dependency-groups", "dev", "pytest", true)).?;
    // Only one [dependency-groups] header (no duplicate table).
    const first = std.mem.indexOf(u8, out, "[dependency-groups]").?;
    try testing.expect(std.mem.indexOfPos(u8, out, first + 1, "[dependency-groups]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "dev = [") != null);
    try testing.expect(std.mem.indexOf(u8, out, "coverage") != null);
}

test "pyproject: runtime fallback returns null when no [project] table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\[build-system]
        \\requires = ["hatchling"]
        \\
    ;
    const out = try editPyproject(a, src, "project", "dependencies", "flask", false);
    try testing.expect(out == null);
}

test "pyproject: appends a comma to a comma-less last entry before inserting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\[project]
        \\dependencies = [
        \\    "requests"
        \\]
        \\
    ;
    const out = (try editPyproject(a, src, "project", "dependencies", "flask", false)).?;
    try testing.expect(std.mem.indexOf(u8, out, "\"requests\",") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"flask\",") != null);
}

// --- requirements.txt (I/O via runtime) ---

test "requirements: append then replace de-dups by package name" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const path = ".zig-cache/tmp/zenv-manifest-req.txt";
    runtime.deleteFile(path) catch {};
    defer runtime.deleteFile(path) catch {};

    try runtime.writeFile(path, "# deps\nrequests\n");
    try addToRequirementsTxt(a, path, "flask>=3.0");
    {
        const c = try runtime.readFileAlloc(a, path, MAX_FILE);
        defer a.free(c);
        try testing.expect(std.mem.indexOf(u8, c, "# deps") != null);
        try testing.expect(std.mem.indexOf(u8, c, "requests") != null);
        try testing.expect(std.mem.indexOf(u8, c, "flask>=3.0") != null);
    }
    // Re-add flask with a different pin: replace, not duplicate.
    try addToRequirementsTxt(a, path, "flask==3.1");
    {
        const c = try runtime.readFileAlloc(a, path, MAX_FILE);
        defer a.free(c);
        try testing.expect(std.mem.indexOf(u8, c, "flask==3.1") != null);
        try testing.expect(std.mem.indexOf(u8, c, "flask>=3.0") == null);
        // exactly one flask line
        try testing.expect(std.mem.indexOf(u8, c, "flask") == std.mem.lastIndexOf(u8, c, "flask"));
    }
}

test "requirements: creates the file when missing" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const path = ".zig-cache/tmp/zenv-manifest-req-new.txt";
    runtime.deleteFile(path) catch {};
    defer runtime.deleteFile(path) catch {};

    try addToRequirementsTxt(a, path, "numpy");
    const c = try runtime.readFileAlloc(a, path, MAX_FILE);
    defer a.free(c);
    try testing.expectEqualStrings("numpy\n", c);
}

// --- zenv.json (I/O via runtime) ---

test "zenv.json: adds to dependencies and dev_dependencies, preserving order" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const path = ".zig-cache/tmp/zenv-manifest.json";
    runtime.deleteFile(path) catch {};
    defer runtime.deleteFile(path) catch {};

    try runtime.writeFile(path,
        \\{
        \\  "base_dir": ".zenv",
        \\  "demo": {
        \\    "target_machines": ["*"],
        \\    "dependencies": ["requests"]
        \\  }
        \\}
    );

    try addToZenvJson(a, path, "demo", "flask>=3.0", false);
    try addToZenvJson(a, path, "demo", "pytest", true);
    // Re-add flask with a new pin -> replace in place.
    try addToZenvJson(a, path, "demo", "flask==3.1", false);

    const c = try runtime.readFileAlloc(a, path, MAX_FILE);
    defer a.free(c);
    try testing.expect(std.mem.indexOf(u8, c, "\"requests\"") != null);
    try testing.expect(std.mem.indexOf(u8, c, "\"flask==3.1\"") != null);
    try testing.expect(std.mem.indexOf(u8, c, "flask>=3.0") == null);
    try testing.expect(std.mem.indexOf(u8, c, "\"dev_dependencies\"") != null);
    try testing.expect(std.mem.indexOf(u8, c, "\"pytest\"") != null);
    // base_dir still precedes the env (key order preserved).
    try testing.expect(std.mem.indexOf(u8, c, "base_dir").? < std.mem.indexOf(u8, c, "demo").?);

    // Re-parse to confirm it's still valid JSON with the expected shape.
    var parsed = try json.parseFromSlice(json.Value, a, c, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const demo = parsed.value.object.get("demo").?;
    try testing.expectEqual(@as(usize, 2), demo.object.get("dependencies").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), demo.object.get("dev_dependencies").?.array.items.len);
}
