const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const output = @import("output.zig");
const toml = @import("toml");

/// Extracts the bare package name from a PEP 508 requirement spec, dropping any
/// version constraint, extras, marker, or surrounding whitespace. Used for
/// case-insensitive duplicate detection — e.g. "Flask[async] >= 2.0; python_version<'3.12'"
/// and "flask==3.1" both reduce to a name that compares equal via `samePackage`.
/// The returned slice points INTO `spec` (no allocation).
pub fn packageBaseName(spec: []const u8) []const u8 {
    // The name ends at the first version operator, extras bracket, marker
    // separator, URL ('@'), or whitespace.
    const end = std.mem.findAny(u8, spec, "<>=~!@;[ \t") orelse spec.len;
    return std.mem.trim(u8, spec[0..end], " \t");
}

/// True when two requirement specs name the same package, ignoring
/// version/extras/markers. Names compare as PEP 503 normalizes them:
/// case-insensitively, with any run of '-', '_' and '.' equal to one '-'
/// (`Flask_Login` is `flask-login`). Allocation-free.
pub fn samePackage(a: []const u8, b: []const u8) bool {
    const x = packageBaseName(a);
    const y = packageBaseName(b);
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const cx = nextNormalized(x, &i);
        if (cx != nextNormalized(y, &j)) return false;
        if (cx == null) return true;
    }
}

fn isNameSeparator(c: u8) bool {
    return c == '-' or c == '_' or c == '.';
}

/// The next byte of `name` from `i.*` in PEP 503 normal form, advancing `i`.
fn nextNormalized(name: []const u8, i: *usize) ?u8 {
    if (i.* >= name.len) return null;
    const c = name[i.*];
    i.* += 1;
    if (!isNameSeparator(c)) return std.ascii.toLower(c);
    while (i.* < name.len and isNameSeparator(name[i.*])) i.* += 1;
    return '-';
}

/// PEP 503 normalised project name: lowercase, runs of `-_.` become `-`.
/// Caller owns the result.
pub fn canonicalName(a: Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (nextNormalized(name, &i)) |c| try out.append(a, c);
    return out.toOwnedSlice(a);
}

// Parse a pyproject.toml file and extract PEP 621 dependencies.
//
// Reads `[project].dependencies` (an array of PEP 508 requirement strings) using a
// real TOML parser (zig-toml) instead of the old line-by-line scanner. Each string is
// kept verbatim (version specifiers and extras preserved) and duped into `allocator`;
// the caller owns the appended strings. Returns the number of dependencies appended.
//
// zig-toml is strict: a malformed document fails as a whole. We keep that non-fatal
// here (warn and return 0) so `zenv setup` still proceeds, matching prior behavior.
pub fn parsePyprojectToml(
    allocator: Allocator,
    io: Io,
    content: []const u8,
    deps_list: *std.ArrayList([]const u8),
) !usize {
    output.print(io, "Parsing pyproject.toml for dependencies...", .{});

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    var parsed = parser.parseString(content) catch |err| {
        output.printError(io, "Failed to parse pyproject.toml: {t}", .{err});
        return 0;
    };
    // The parse arena owns every parsed string; dupe what we keep before it is freed.
    defer parsed.deinit();

    // Navigate to [project].dependencies, bailing out (non-fatally) if absent or mistyped.
    const project_tbl = switch (parsed.value.get("project") orelse {
        output.print(io, "No [project] table found in pyproject.toml", .{});
        return 0;
    }) {
        .table => |t| t,
        else => return 0,
    };

    const deps_arr = switch (project_tbl.get("dependencies") orelse {
        output.print(io, "No [project].dependencies found in pyproject.toml", .{});
        return 0;
    }) {
        .array => |arr| arr,
        else => return 0,
    };

    var count: usize = 0;
    for (deps_arr.items) |item| {
        const spec = switch (item) {
            .string => |s| s, // e.g. "numpy>=1.26.0, <2.0" — kept verbatim
            else => continue,
        };
        const dep = try allocator.dupe(u8, spec);
        output.print(io, "  - TOML dependency: {s}", .{dep});
        try deps_list.append(allocator, dep);
        count += 1;
    }

    if (count > 0) {
        output.print(io, "Found {d} dependencies in pyproject.toml", .{count});
    } else {
        output.print(io, "Processed pyproject.toml but found no valid dependencies", .{});
    }
    return count;
}

/// The string `[project].<key>` of the pyproject.toml `content` (e.g.
/// "description", "requires-python"), trimmed and duped into `allocator`;
/// null when absent, empty, not a string or the document does not parse.
pub fn pyprojectField(allocator: Allocator, content: []const u8, key: []const u8) !?[]u8 {
    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    var parsed = parser.parseString(content) catch return null;
    defer parsed.deinit();
    const project = parsed.value.get("project") orelse return null;
    if (project != .table) return null;
    const value = project.table.get(key) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

// Parse dependencies from requirements.txt format content
// Returns the number of dependencies found
pub fn parseRequirementsTxt(
    allocator: Allocator,
    io: Io,
    content: []const u8,
    deps_list: *std.ArrayList([]const u8),
) !usize {
    output.print(io, "Parsing requirements.txt for dependencies...", .{});
    var count: usize = 0;

    // Split lines more efficiently with iterator directly
    var line_iter = std.mem.splitScalar(u8, content, '\n');

    while (line_iter.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
            continue;
        }

        // For valid dependencies, add directly
        output.print(io, "  - Requirements file dependency: {s}", .{trimmed_line});

        // Create a duplicate of the trimmed line
        const trimmed_dupe = try allocator.dupe(u8, trimmed_line);

        // Add the dependency
        try deps_list.append(allocator, trimmed_dupe);
        count += 1;
    }
    output.print(io, "Found {d} dependencies in requirements.txt format", .{count});
    return count;
}

/// Drops empty entries, entries without a project name, and later duplicates
/// of a package (by `samePackage`). The returned list borrows from `raw_deps`.
pub fn validateDependencies(
    allocator: Allocator,
    io: Io,
    raw_deps: []const []const u8,
    env_name: []const u8,
) !std.ArrayList([]const u8) {
    output.print(io, "Validating dependencies for '{s}':", .{env_name});
    var valid_deps: std.ArrayList([]const u8) = .empty;
    errdefer valid_deps.deinit(allocator);

    next: for (raw_deps) |dep| {
        if (dep.len == 0) {
            output.print(io, "Warning: Skipping empty dependency", .{});
            continue;
        }

        // Only the project name is checked here; the rest of the PEP 508 line
        // (specifiers like `!=1.0` or `==1.0.*`, extras, markers, `name @ url`)
        // is left for pip/uv, which validate it properly at install time.
        const name = packageBaseName(dep);
        if (name.len == 0 or !std.ascii.isAlphanumeric(name[0])) {
            output.print(io, "Warning: Skipping invalid dependency (no project name): '{s}'", .{dep});
            continue;
        }

        for (valid_deps.items) |seen| {
            if (!samePackage(seen, dep)) continue;
            output.print(io, "Warning: Skipping duplicate package '{s}' (already included in dependencies)", .{dep});
            continue :next;
        }

        output.print(io, "Including dependency: '{s}'", .{dep});
        try valid_deps.append(allocator, dep);
    }

    return valid_deps;
}

// ============================ Tests ============================

const testing = std.testing;

test "parsePyprojectToml: extracts deps from a standalone dependencies array" {
    const a = testing.allocator;
    const content =
        \\[project]
        \\name = "x"
        \\dependencies = [
        \\    "requests",
        \\    "flask>=2.0",
        \\]
    ;
    var deps: std.ArrayList([]const u8) = .empty;
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit(a);
    }
    const count = try parsePyprojectToml(a, testing.io, content, &deps);
    try testing.expect(count >= 2);
    var has_req = false;
    var has_flask = false;
    for (deps.items) |d| {
        if (std.mem.find(u8, d, "requests") != null) has_req = true;
        if (std.mem.find(u8, d, "flask") != null) has_flask = true;
    }
    try testing.expect(has_req and has_flask);
}

test "parseRequirementsTxt: skips comments and blank lines" {
    const a = testing.allocator;
    const content =
        \\# a comment
        \\
        \\requests
        \\flask>=2.0
        \\   # indented comment
    ;
    var deps: std.ArrayList([]const u8) = .empty;
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit(a);
    }
    const count = try parseRequirementsTxt(a, testing.io, content, &deps);
    try testing.expectEqual(@as(usize, 2), count);
}

test "packageBaseName strips versions, extras, and markers" {
    try testing.expectEqualStrings("flask", packageBaseName("flask"));
    try testing.expectEqualStrings("flask", packageBaseName("flask>=2.0"));
    try testing.expectEqualStrings("flask", packageBaseName("flask==3.1"));
    try testing.expectEqualStrings("flask", packageBaseName("flask!=2.0"));
    try testing.expectEqualStrings("numpy", packageBaseName("numpy>=1.26.0, <2.0"));
    try testing.expectEqualStrings("mkdocstrings", packageBaseName("mkdocstrings[python]>=0.19"));
    try testing.expectEqualStrings("requests", packageBaseName("requests ; python_version < '3.12'"));
}

test "samePackage is case-insensitive and ignores constraints" {
    try testing.expect(samePackage("Flask", "flask==3.1"));
    try testing.expect(samePackage("flask[async]>=2", "FLASK"));
    try testing.expect(!samePackage("flask", "flask-login"));
    try testing.expect(!samePackage("requests", "httpx"));
    // PEP 503: '-', '_' and '.' runs are one separator.
    try testing.expect(samePackage("flask_login>=0.6", "Flask-Login"));
    try testing.expect(samePackage("zope.interface", "zope__interface"));
    try testing.expect(!samePackage("flasklogin", "flask-login"));
}

test "validateDependencies keeps any PEP 508 line that starts with a name" {
    const a = std.testing.allocator;
    const raw = [_][]const u8{
        "flask!=2.0",
        "numpy==1.26.*",
        "torch==2.1+cu121",
        "requests ; python_version<'3.12'",
        "pkg @ https://example.com/pkg-1.0-py3-none-any.whl",
        "FLASK>=1", // duplicate of flask (case-insensitive)
        "-e .", // not a requirement name
        "",
        "flask_login",
        "Flask.Login>=0.6", // duplicate of flask_login (PEP 503)
    };
    var valid = try validateDependencies(a, testing.io, &raw, "test");
    defer valid.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), valid.items.len);
    try std.testing.expectEqualStrings("flask!=2.0", valid.items[0]);
    try std.testing.expectEqualStrings("pkg @ https://example.com/pkg-1.0-py3-none-any.whl", valid.items[4]);
    try std.testing.expectEqualStrings("flask_login", valid.items[5]);
}

test "validateDependencies keeps multi-constraint specifiers" {
    const a = testing.allocator;
    const raw = [_][]const u8{
        "numpy>=1.26.0,<2.0",
        "requests>=2.8.1, <3.0",
    };
    var valid = try validateDependencies(a, testing.io, &raw, "test");
    defer valid.deinit(a);
    try testing.expectEqual(@as(usize, 2), valid.items.len);
    try testing.expectEqualStrings("numpy>=1.26.0,<2.0", valid.items[0]);
    try testing.expectEqualStrings("requests>=2.8.1, <3.0", valid.items[1]);
}

test "parsePyprojectToml: single-line dependencies array does not swallow later keys" {
    const a = testing.allocator;
    // Regression: a single-line `dependencies = [...]` used to leave the parser
    // stuck in the in_deps_array state, so following lines like `name = "proj"`
    // were captured as bogus dependencies.
    const content =
        \\[project]
        \\dependencies = ["requests", "flask>=2.0"]
        \\name = "proj"
        \\version = "1.2.3"
    ;
    var deps: std.ArrayList([]const u8) = .empty;
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit(a);
    }
    const count = try parsePyprojectToml(a, testing.io, content, &deps);
    try testing.expectEqual(@as(usize, 2), count);
    for (deps.items) |d| {
        try testing.expect(std.mem.find(u8, d, "proj") == null);
        try testing.expect(std.mem.find(u8, d, "1.2.3") == null);
    }
}

test "parsePyprojectToml: keeps comma+space multi-constraint specifier" {
    const a = testing.allocator;
    const content =
        \\[project]
        \\name = "x"
        \\dependencies = [
        \\    "numpy>=1.26.0, <2.0",
        \\]
    ;
    var deps: std.ArrayList([]const u8) = .empty;
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit(a);
    }
    const count = try parsePyprojectToml(a, testing.io, content, &deps);
    try testing.expect(count >= 1);
    var found = false;
    for (deps.items) |d| {
        if (std.mem.find(u8, d, "numpy") != null and std.mem.find(u8, d, "<2.0") != null) found = true;
    }
    try testing.expect(found);
}

test "parsePyprojectToml: extracts [project].dependencies from a realistic full file" {
    const a = testing.allocator;
    // A real-world pyproject.toml carries many sections beyond dependencies. The strict
    // TOML parser must read the whole document without tripping over build-system, tool
    // tables, arrays of tables, dotted keys, or multi-line strings — and still extract
    // only [project].dependencies, ignoring optional-dependencies and tool config.
    const content =
        \\[build-system]
        \\requires = ["hatchling>=1.0"]
        \\build-backend = "hatchling.build"
        \\
        \\[project]
        \\name = "demo"
        \\version = "0.1.0"
        \\readme = "README.md"
        \\requires-python = ">=3.10"
        \\dependencies = [
        \\    "requests>=2.28.0",
        \\    "numpy>=1.26.0, <2.0",
        \\    "mkdocstrings[python]>=0.19",
        \\]
        \\
        \\[project.optional-dependencies]
        \\dev = ["pytest>=7.0", "ruff"]
        \\
        \\[project.urls]
        \\Homepage = "https://example.com"
        \\
        \\[[tool.mypy.overrides]]
        \\module = "foo.*"
        \\ignore_missing_imports = true
        \\
        \\[tool.ruff]
        \\line-length = 100
        \\
        \\[tool.poetry]
        \\description = """
        \\multi-line
        \\description
        \\"""
    ;
    var deps: std.ArrayList([]const u8) = .empty;
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit(a);
    }
    const count = try parsePyprojectToml(a, testing.io, content, &deps);
    // Exactly the three [project].dependencies entries — not the optional-deps or tool config.
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("requests>=2.28.0", deps.items[0]);
    try testing.expectEqualStrings("numpy>=1.26.0, <2.0", deps.items[1]);
    try testing.expectEqualStrings("mkdocstrings[python]>=0.19", deps.items[2]);
    for (deps.items) |d| {
        try testing.expect(std.mem.find(u8, d, "pytest") == null);
        try testing.expect(std.mem.find(u8, d, "ruff") == null);
    }
}

test "pyprojectField reads [project] strings only" {
    const a = std.testing.allocator;
    const content =
        \\[tool.x]
        \\description = "not this"
        \\[project]
        \\name = "demo"
        \\description = "  A demo project  "
        \\requires-python = ">=3.10"
        \\version = 1
    ;
    const d = (try pyprojectField(a, content, "description")).?;
    defer a.free(d);
    try std.testing.expectEqualStrings("A demo project", d);
    const rp = (try pyprojectField(a, content, "requires-python")).?;
    defer a.free(rp);
    try std.testing.expectEqualStrings(">=3.10", rp);
    try std.testing.expect((try pyprojectField(a, content, "version")) == null); // not a string
    try std.testing.expect((try pyprojectField(a, "[project]\nname = \"x\"\n", "description")) == null);
    try std.testing.expect((try pyprojectField(a, "[project]\ndescription = \"\"\n", "description")) == null);
    try std.testing.expect((try pyprojectField(a, "not = = toml", "description")) == null);
}

test "canonicalName normalises case and separator runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("zope-interface", try canonicalName(a, "Zope.Interface"));
    try std.testing.expectEqualStrings("a-b", try canonicalName(a, "A__.-b"));
}
