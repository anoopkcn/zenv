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

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var replaced = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        // Drop a pure trailing-empty segment so we don't accumulate blank lines
        // on every rewrite; real blank lines between entries are preserved.
        if (it.peek() == null and line.len == 0) break;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        const is_entry = trimmed.len > 0 and trimmed[0] != '#';
        if (is_entry and !replaced and parse_deps.samePackage(trimmed, spec)) {
            try out.appendSlice(allocator, spec);
            // Keep an inline comment (`pkg==1.0  # why`); pip needs the
            // whitespace before '#', so it is kept too.
            if (std.mem.find(u8, line, " #") orelse std.mem.find(u8, line, "\t#")) |c| {
                const start = std.mem.trimEnd(u8, line[0 .. c + 1], " \t").len;
                try out.appendSlice(allocator, std.mem.trimEnd(u8, line[start..], "\r"));
            }
            replaced = true;
        } else {
            try out.appendSlice(allocator, line);
        }
        try out.append(allocator, '\n');
    }

    if (!replaced) {
        try out.appendSlice(allocator, spec);
        try out.append(allocator, '\n');
    }

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

    // Get-or-create the target array on the environment object (a value of
    // the wrong type is replaced). `key` is a literal, so it outlives the map.
    const gop = try env_ptr.object.getOrPut(a, key);
    if (!gop.found_existing or gop.value_ptr.* != .array) gop.value_ptr.* = Value{ .array = Array.init(a) };
    const arr_ptr = gop.value_ptr;

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

    try writeJson(allocator, path, parsed.value);
}

/// Writes `value` to `path` atomically as 2-space-indented JSON with a final
/// newline, the layout `zenv init` writes.
pub fn writeJson(allocator: Allocator, path: []const u8, value: Value) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try runtime.writeFileAtomic(allocator, path, out.written());
}

/// Adds environment `env_name` to the zenv.json at `path`, taking its object
/// from `template`, a zenv.json document that defines it (as `zenv init`
/// writes). Returns false, writing nothing, when the file already has that
/// environment. Re-emits the document like addToZenvJson.
pub fn addEnvToZenvJson(allocator: Allocator, path: []const u8, env_name: []const u8, template: []const u8) !bool {
    const content = try runtime.readFileAlloc(allocator, path, MAX_FILE);
    defer allocator.free(content);

    var parsed = json.parseFromSlice(json.Value, allocator, content, .{ .allocate = .alloc_always }) catch return error.InvalidFormat;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFormat;
    if (parsed.value.object.contains(env_name)) return false;

    // Parsed into the same arena, so the new entry lives as long as the document.
    const a = parsed.arena.allocator();
    const tmpl = try json.parseFromSliceLeaky(json.Value, a, template, .{ .allocate = .alloc_always });
    if (tmpl != .object) return error.InvalidFormat;
    const env_value = tmpl.object.get(env_name) orelse return error.InvalidFormat;
    try parsed.value.object.put(a, try a.dupe(u8, env_name), env_value);

    try writeJson(allocator, path, parsed.value);
    return true;
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

const LineList = std.ArrayList([]const u8);

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
    const eq = std.mem.findScalar(u8, t, '=') orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, t[0..eq], " \t"), key);
}

/// Returns the leading-whitespace slice of `line`.
fn indentOf(line: []const u8) []const u8 {
    const end = std.mem.findNone(u8, line, " \t") orelse line.len;
    return line[0..end];
}

/// The first TOML string in `line` ("basic" with backslash escapes, or
/// 'literal'): `start`/`end` bound its text, so the opening quote is at
/// `start - 1` and the closing one at `end`. Null when there is none. Reads
/// array entries such as `    "flask>=2.0",  # why`.
const Quoted = struct { start: usize, end: usize };
fn quotedSpan(line: []const u8) ?Quoted {
    const open = std.mem.findAny(u8, line, "\"'") orelse return null;
    const q = line[open];
    var i = open + 1;
    while (i < line.len) : (i += 1) {
        if (q == '"' and line[i] == '\\') {
            i += 1;
        } else if (line[i] == q) {
            return .{ .start = open + 1, .end = i };
        }
    }
    return null;
}

/// Index of the first `target` in `s` at or after `from` that is outside TOML
/// strings, or null (also when a `#` comment starts first). Finds the `]` that
/// closes an array whose entries may hold brackets (`"uvicorn[standard]"`) and
/// the commas between entries that may hold commas (`"numpy>=1.26, <2"`).
fn findUnquoted(s: []const u8, from: usize, target: u8) ?usize {
    var quote: ?u8 = null;
    var i = from;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote) |q| {
            if (q == '"' and c == '\\') {
                i += 1;
            } else if (c == q) {
                quote = null;
            }
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == target) {
            return i;
        } else if (c == '#') {
            return null;
        }
    }
    return null;
}

/// `spec` as a TOML basic string, quotes included: a marker such as
/// `python_version < "3.12"` holds double quotes.
fn tomlString(a: Allocator, spec: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (spec) |c| {
        if (c == '"' or c == '\\') try out.append(a, '\\');
        try out.append(a, c);
    }
    try out.append(a, '"');
    return out.items;
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
    var lines: LineList = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    const trailing_newline = std.mem.endsWith(u8, content, "\n");
    while (it.next()) |line| try lines.append(a, line);
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
        } else {
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
    const lb = findUnquoted(lines.items[kl], 0, '[') orelse return null;
    if (findUnquoted(lines.items[kl], lb + 1, ']')) |rb| {
        try editInlineArray(a, &lines, kl, lb, rb, spec);
    } else {
        try editMultilineArray(a, &lines, kl, sec_end, spec);
    }
    return try joinLines(a, &lines, trailing_newline);
}

fn joinLines(a: Allocator, lines: *LineList, trailing_newline: bool) ![]const u8 {
    const body = try std.mem.join(a, "\n", lines.items);
    if (trailing_newline) return a.print("{s}\n", .{body});
    return body;
}

/// Appends `\n[section]\nkey = [\n    "spec",\n]` at the end of the document.
fn appendNewBlock(a: Allocator, lines: *LineList, section: []const u8, key: []const u8, spec: []const u8) !void {
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len != 0) {
        try lines.append(a, ""); // blank separator line
    }
    try lines.append(a, try a.print("[{s}]", .{section}));
    try insertKeyBlock(a, lines, lines.items.len, key, spec);
}

/// Inserts `key = [\n    "spec",\n]` at line index `at`.
fn insertKeyBlock(a: Allocator, lines: *LineList, at: usize, key: []const u8, spec: []const u8) !void {
    try lines.insert(a, at, try a.print("{s} = [", .{key}));
    try lines.insert(a, at + 1, try a.print("    {s},", .{try tomlString(a, spec)}));
    try lines.insert(a, at + 2, "]");
}

/// Edits a single-line array `key = [ ... ]` on line `kl`; `lb`/`rb` are the
/// indexes of its brackets. Entries other than a replaced one keep their text.
fn editInlineArray(a: Allocator, lines: *LineList, kl: usize, lb: usize, rb: usize, spec: []const u8) !void {
    const line = lines.items[kl];
    const inner = line[lb + 1 .. rb];
    const new_entry = try tomlString(a, spec);

    var entries: std.ArrayList([]const u8) = .empty;
    var replaced = false;
    var start: usize = 0;
    while (start <= inner.len) {
        const end = findUnquoted(inner, start, ',') orelse inner.len;
        const p = std.mem.trim(u8, inner[start..end], " \t");
        start = end + 1;
        if (p.len == 0) continue;
        const val = if (quotedSpan(p)) |q| p[q.start..q.end] else p;
        if (!replaced and parse_deps.samePackage(val, spec)) {
            try entries.append(a, new_entry);
            replaced = true;
        } else {
            try entries.append(a, p);
        }
    }
    if (!replaced) try entries.append(a, new_entry);

    const joined = try std.mem.join(a, ", ", entries.items);
    lines.items[kl] = try a.print("{s}{s}{s}", .{ line[0 .. lb + 1], joined, line[rb..] });
}

/// Edits a multi-line array opened on line `kl`: replaces the entry for the
/// same package in place (keeping its comma and comment), else appends one
/// before the `]`, which may share a line with the last entry.
fn editMultilineArray(a: Allocator, lines: *LineList, kl: usize, sec_end: usize, spec: []const u8) !void {
    const new_entry = try tomlString(a, spec);

    // The closing-bracket line and the bracket's column in it.
    var close: usize = kl + 1;
    var close_col: usize = 0;
    while (close < sec_end) : (close += 1) {
        if (findUnquoted(lines.items[close], 0, ']')) |col| {
            close_col = col;
            break;
        }
    } else return error.UnterminatedArray; // leave the file alone

    // Try to replace an existing entry with the same package.
    var last_entry: ?usize = null;
    var i = kl + 1;
    while (i <= close) : (i += 1) {
        const line = lines.items[i];
        const q = quotedSpan(line) orelse continue;
        if (i == close and q.start > close_col) break;
        last_entry = i;
        if (parse_deps.samePackage(line[q.start..q.end], spec)) {
            lines.items[i] = try a.print("{s}{s}{s}", .{ line[0 .. q.start - 1], new_entry, line[q.end + 1 ..] });
            return;
        }
    }

    // No match: append a new entry. Use the indentation of an existing entry,
    // or the key-line indent + 4 spaces.
    const indent = if (last_entry != null and last_entry.? != close)
        indentOf(lines.items[last_entry.?])
    else
        try a.print("{s}    ", .{indentOf(lines.items[kl])});

    const close_line = lines.items[close];
    const head = std.mem.trimEnd(u8, close_line[0..close_col], " \t");
    if (std.mem.trim(u8, head, " \t").len > 0) {
        // The last entry shares its line with ']' (`    "b"]`): give the
        // bracket a line of its own after the new entry.
        lines.items[close] = if (std.mem.endsWith(u8, head, ",")) head else try a.print("{s},", .{head});
        try lines.insert(a, close + 1, try a.print("{s}{s},", .{ indent, new_entry }));
        try lines.insert(a, close + 2, try a.print("{s}{s}", .{ indentOf(lines.items[kl]), close_line[close_col..] }));
        return;
    }

    // Ensure the previous last entry carries a trailing comma (before any
    // comment) so the array stays valid once another element follows it.
    if (last_entry) |le| {
        const line = lines.items[le];
        const q = quotedSpan(line).?;
        const after = line[q.end + 1 ..];
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, after, " \t"), ",")) {
            lines.items[le] = try a.print("{s},{s}", .{ line[0 .. q.end + 1], after });
        }
    }

    try lines.insert(a, close, try a.print("{s}{s},", .{ indent, new_entry }));
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
    try testing.expect(std.mem.find(u8, out, "\"flask>=3.0\",") != null);
    try testing.expect(std.mem.find(u8, out, "\"requests>=2.28\",") != null);
    // Unrelated table preserved.
    try testing.expect(std.mem.find(u8, out, "line-length = 100") != null);
    // Appended after the existing entry but still inside the [project] table
    // (before the [tool.ruff] section).
    try testing.expect(std.mem.find(u8, out, "requests>=2.28").? < std.mem.find(u8, out, "flask>=3.0").?);
    try testing.expect(std.mem.find(u8, out, "flask>=3.0").? < std.mem.find(u8, out, "[tool.ruff]").?);
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
    try testing.expect(std.mem.find(u8, out, "flask==3.1") != null);
    try testing.expect(std.mem.find(u8, out, "flask>=2.0") == null);
    try testing.expect(std.mem.find(u8, out, "\"numpy\"") != null);
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
    try testing.expect(std.mem.find(u8, out, "dependencies = [\"rich\"]") != null);
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
    try testing.expect(std.mem.find(u8, out, "[dependency-groups]") != null);
    try testing.expect(std.mem.find(u8, out, "dev = [") != null);
    try testing.expect(std.mem.find(u8, out, "\"pytest>=8\",") != null);
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
    const first = std.mem.find(u8, out, "[dependency-groups]").?;
    try testing.expect(std.mem.findPos(u8, out, first + 1, "[dependency-groups]") == null);
    try testing.expect(std.mem.find(u8, out, "dev = [") != null);
    try testing.expect(std.mem.find(u8, out, "coverage") != null);
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
    try testing.expect(std.mem.find(u8, out, "\"requests\",") != null);
    try testing.expect(std.mem.find(u8, out, "\"flask\",") != null);
}

test "pyproject: inline array entries may hold brackets and commas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "[project]\ndependencies = [\"uvicorn[standard]>=0.20\", 'numpy>=1.26, <2'] # pinned\n";

    const replaced = (try editPyproject(a, src, "project", "dependencies", "numpy>=2", false)).?;
    try testing.expectEqualStrings("[project]\ndependencies = [\"uvicorn[standard]>=0.20\", \"numpy>=2\"] # pinned\n", replaced);

    const extra = (try editPyproject(a, src, "project", "dependencies", "uvicorn>=0.30", false)).?;
    try testing.expectEqualStrings("[project]\ndependencies = [\"uvicorn>=0.30\", 'numpy>=1.26, <2'] # pinned\n", extra);

    const appended = (try editPyproject(a, src, "project", "dependencies", "flask", false)).?;
    try testing.expectEqualStrings("[project]\ndependencies = [\"uvicorn[standard]>=0.20\", 'numpy>=1.26, <2', \"flask\"] # pinned\n", appended);
}

test "pyproject: replacing a multi-line entry keeps its comma and comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\[project]
        \\dependencies = [
        \\    "torch==2.1",  # cu121 on this node
        \\    "numpy"  # last, no comma
        \\]
        \\
    ;
    const torch = (try editPyproject(a, src, "project", "dependencies", "torch==2.2", false)).?;
    try testing.expect(std.mem.find(u8, torch, "    \"torch==2.2\",  # cu121 on this node\n") != null);

    // Appending gives the comma-less last entry a comma before its comment.
    const flask = (try editPyproject(a, src, "project", "dependencies", "flask", false)).?;
    try testing.expect(std.mem.find(u8, flask, "    \"numpy\",  # last, no comma\n    \"flask\",\n]") != null);
}

test "pyproject: a ']' sharing the last entry's line gets its own line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "[project]\ndependencies = [\n    \"requests\",\n    \"six\"]\n";
    const out = (try editPyproject(a, src, "project", "dependencies", "flask", false)).?;
    try testing.expectEqualStrings("[project]\ndependencies = [\n    \"requests\",\n    \"six\",\n    \"flask\",\n]\n", out);

    // An entry on the ']' line can still be replaced in place.
    const six = (try editPyproject(a, src, "project", "dependencies", "six>=1.16", false)).?;
    try testing.expectEqualStrings("[project]\ndependencies = [\n    \"requests\",\n    \"six>=1.16\"]\n", six);
}

test "pyproject: specs with double quotes are escaped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = (try editPyproject(a, "[project]\ndependencies = []\n", "project", "dependencies", "tomli; python_version < \"3.11\"", false)).?;
    try testing.expectEqualStrings("[project]\ndependencies = [\"tomli; python_version < \\\"3.11\\\"\"]\n", out);
}

test "pyproject: an unterminated array is left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "[project]\ndependencies = [\n    \"requests\",\n";
    try testing.expectError(error.UnterminatedArray, editPyproject(arena.allocator(), src, "project", "dependencies", "flask", false));
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
        try testing.expect(std.mem.find(u8, c, "# deps") != null);
        try testing.expect(std.mem.find(u8, c, "requests") != null);
        try testing.expect(std.mem.find(u8, c, "flask>=3.0") != null);
    }
    // Re-add flask with a different pin: replace, not duplicate.
    try addToRequirementsTxt(a, path, "flask==3.1");
    {
        const c = try runtime.readFileAlloc(a, path, MAX_FILE);
        defer a.free(c);
        try testing.expect(std.mem.find(u8, c, "flask==3.1") != null);
        try testing.expect(std.mem.find(u8, c, "flask>=3.0") == null);
        // exactly one flask line
        try testing.expect(std.mem.find(u8, c, "flask") == std.mem.findLast(u8, c, "flask"));
    }
}

test "requirements: a replaced line keeps its comment; names match per PEP 503" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const path = ".zig-cache/tmp/zenv-manifest-req-comment.txt";
    runtime.deleteFile(path) catch {};
    defer runtime.deleteFile(path) catch {};

    try runtime.writeFile(path, "Flask_Login==0.5  # auth\nrequests\n");
    try addToRequirementsTxt(a, path, "flask-login>=0.6");
    const c = try runtime.readFileAlloc(a, path, MAX_FILE);
    defer a.free(c);
    try testing.expectEqualStrings("flask-login>=0.6  # auth\nrequests\n", c);
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

    // Blank lines are kept; a missing final newline is added.
    try runtime.writeFile(path, "a\n\nb");
    try addToRequirementsTxt(a, path, "c");
    const c2 = try runtime.readFileAlloc(a, path, MAX_FILE);
    defer a.free(c2);
    try testing.expectEqualStrings("a\n\nb\nc\n", c2);
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
    try testing.expect(std.mem.find(u8, c, "\"requests\"") != null);
    try testing.expect(std.mem.find(u8, c, "\"flask==3.1\"") != null);
    try testing.expect(std.mem.find(u8, c, "flask>=3.0") == null);
    try testing.expect(std.mem.find(u8, c, "\"dev_dependencies\"") != null);
    try testing.expect(std.mem.find(u8, c, "\"pytest\"") != null);
    // base_dir still precedes the env (key order preserved).
    try testing.expect(std.mem.find(u8, c, "base_dir").? < std.mem.find(u8, c, "demo").?);

    // Re-parse to confirm it's still valid JSON with the expected shape.
    var parsed = try json.parseFromSlice(json.Value, a, c, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const demo = parsed.value.object.get("demo").?;
    try testing.expectEqual(@as(usize, 2), demo.object.get("dependencies").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), demo.object.get("dev_dependencies").?.array.items.len);
}

test "zenv.json: a non-array dependencies value is replaced by the new array" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const path = ".zig-cache/tmp/zenv-manifest-bad-deps.json";
    runtime.deleteFile(path) catch {};
    defer runtime.deleteFile(path) catch {};

    try runtime.writeFile(path,
        \\{ "base_dir": ".zenv", "demo": { "dependencies": "requests", "target_machines": ["*"] } }
    );
    try addToZenvJson(a, path, "demo", "flask", false);
    const c = try runtime.readFileAlloc(a, path, MAX_FILE);
    defer a.free(c);
    var parsed = try json.parseFromSlice(json.Value, a, c, .{});
    defer parsed.deinit();
    const demo = parsed.value.object.get("demo").?.object;
    try testing.expectEqualStrings("dependencies", demo.keys()[0]); // stays in place
    try testing.expectEqualStrings("flask", demo.get("dependencies").?.array.items[0].string);
}

test "zenv.json: addEnvToZenvJson appends a new env and refuses an existing one" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const path = ".zig-cache/tmp/zenv-manifest-add-env.json";
    runtime.deleteFile(path) catch {};
    defer runtime.deleteFile(path) catch {};

    const original =
        \\{ "base_dir": "envs", "old": { "target_machines": ["*"], "dependencies": ["requests"] } }
    ;
    try runtime.writeFile(path, original);
    const template =
        \\{ "base_dir": ".zenv", "new": { "target_machines": ["*"], "description": "d" } }
    ;

    try testing.expect(!try addEnvToZenvJson(a, path, "old", template));
    const unchanged = try runtime.readFileAlloc(a, path, MAX_FILE);
    defer a.free(unchanged);
    try testing.expectEqualStrings(original, unchanged);

    try testing.expect(try addEnvToZenvJson(a, path, "new", template));
    const c = try runtime.readFileAlloc(a, path, MAX_FILE);
    defer a.free(c);
    var parsed = try json.parseFromSlice(json.Value, a, c, .{});
    defer parsed.deinit();
    const keys = parsed.value.object.keys();
    try testing.expectEqual(@as(usize, 3), keys.len);
    try testing.expectEqualStrings("new", keys[2]); // appended after the existing envs
    try testing.expectEqualStrings("envs", parsed.value.object.get("base_dir").?.string); // file's own base_dir kept
    try testing.expectEqualStrings("d", parsed.value.object.get("new").?.object.get("description").?.string);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("old").?.object.get("dependencies").?.array.items.len);

    try runtime.writeFile(path, "[1, 2]");
    try testing.expectError(error.InvalidFormat, addEnvToZenvJson(a, path, "new", template));
}
