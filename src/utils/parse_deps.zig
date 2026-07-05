const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap(void);
const config = @import("config.zig");
const errors = @import("errors.zig");
const output = @import("output.zig");
const toml = @import("toml");

// Helper to check if a string is a common metadata field, not a dependency
fn isLikelyPythonPackageName(package_name: []const u8) bool {
    // Skip common metadata fields
    const meta_fields = [_][]const u8{ "name", "version", "description", "authors", "license", "keywords", "classifiers", "readme", "homepage", "repository", "documentation", "requires-python", "python-requires", "url", "project", "tool", "build-system", "dev-dependencies" };

    // If it's a known metadata field, it's not a package
    for (meta_fields) |field| {
        if (std.mem.eql(u8, package_name, field)) {
            return false;
        }
    }

    // If the string starts with a bracket or brace, not a package name
    if (package_name.len > 0 and (package_name[0] == '{' or package_name[0] == '[')) {
        return false;
    }

    // If the string has spaces but no version operator or extras bracket, it's
    // prose (e.g. a description or classifier), not a package. A real requirement
    // may legitimately contain a space, as in "numpy>=1.26.0, <2.0" or
    // "mkdocstrings[python] >= 0.19" — those always carry an operator or '['.
    // (Keying on the comma instead would mis-accept prose like "Fast, simple".)
    if (std.mem.indexOf(u8, package_name, " ") != null and
        std.mem.indexOfAny(u8, package_name, "<>=~[") == null)
    {
        return false;
    }

    return true;
}

/// Extracts the bare package name from a PEP 508 requirement spec, dropping any
/// version constraint, extras, marker, or surrounding whitespace. Used for
/// case-insensitive duplicate detection — e.g. "Flask[async] >= 2.0; python_version<'3.12'"
/// and "flask==3.1" both reduce to a name that compares equal via `samePackage`.
/// The returned slice points INTO `spec` (no allocation).
pub fn packageBaseName(spec: []const u8) []const u8 {
    // The name ends at the first version operator, extras bracket, marker
    // separator, URL ('@'), or whitespace.
    const end = std.mem.indexOfAny(u8, spec, "<>=~!@;[ \t") orelse spec.len;
    return std.mem.trim(u8, spec[0..end], " \t");
}

/// True when two requirement specs name the same package (case-insensitive,
/// ignoring version/extras/markers). Allocation-free.
pub fn samePackage(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(packageBaseName(a), packageBaseName(b));
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
    content: []const u8,
    deps_list: *std.array_list.Managed([]const u8),
) !usize {
    output.print(allocator, "Parsing pyproject.toml for dependencies...", .{}) catch {};

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    var parsed = parser.parseString(content) catch |err| {
        output.printError(allocator, "Failed to parse pyproject.toml: {s}", .{@errorName(err)}) catch {};
        return 0;
    };
    // The parse arena owns every parsed string; dupe what we keep before it is freed.
    defer parsed.deinit();

    // Navigate to [project].dependencies, bailing out (non-fatally) if absent or mistyped.
    const project_tbl = switch (parsed.value.get("project") orelse {
        output.print(allocator, "No [project] table found in pyproject.toml", .{}) catch {};
        return 0;
    }) {
        .table => |t| t,
        else => return 0,
    };

    const deps_arr = switch (project_tbl.get("dependencies") orelse {
        output.print(allocator, "No [project].dependencies found in pyproject.toml", .{}) catch {};
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
        if (!isLikelyPythonPackageName(spec)) {
            output.print(allocator, "  - Skipping non-package entry: {s}", .{spec}) catch {};
            continue;
        }
        const dep = try allocator.dupe(u8, spec);
        output.print(allocator, "  - TOML dependency: {s}", .{dep}) catch {};
        try deps_list.append(dep);
        count += 1;
    }

    if (count > 0) {
        output.print(allocator, "Found {d} dependencies in pyproject.toml", .{count}) catch {};
    } else {
        output.print(allocator, "Processed pyproject.toml but found no valid dependencies", .{}) catch {};
    }
    return count;
}

// Parse dependencies from requirements.txt format content
// Returns the number of dependencies found
pub fn parseRequirementsTxt(
    allocator: Allocator,
    content: []const u8,
    deps_list: *std.array_list.Managed([]const u8),
) !usize {
    output.print(allocator, "Parsing requirements.txt for dependencies...", .{}) catch {};
    var count: usize = 0;

    // Split lines more efficiently with iterator directly
    var line_iter = std.mem.splitScalar(u8, content, '\n');

    while (line_iter.next()) |line| {
        // Skip empty lines and comments early
        if (line.len == 0) continue;

        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') {
            continue;
        }

        // For valid dependencies, add directly
        output.print(allocator, "  - Requirements file dependency: {s}", .{trimmed_line}) catch {};

        // Create a duplicate of the trimmed line
        const trimmed_dupe = try allocator.dupe(u8, trimmed_line);

        // Add the dependency
        try deps_list.append(trimmed_dupe);
        count += 1;
    }
    output.print(allocator, "Found {d} dependencies in requirements.txt format", .{count}) catch {};
    return count;
}

// Validate raw dependencies, remove duplicates and invalid entries
pub fn validateDependencies(
    allocator: Allocator,
    raw_deps: []const []const u8,
    env_name: []const u8,
) !std.array_list.Managed([]const u8) {
    output.print(allocator, "Validating dependencies for '{s}':", .{env_name}) catch {};
    var valid_deps = std.array_list.Managed([]const u8).init(allocator);
    // Improved error handling with explicit cleanup of any added items
    errdefer {
        // Only free items we owned and added to valid_deps
        valid_deps.deinit();
    }

    // Create a hashmap to track seen package names (case-insensitive). The keys
    // are owned dupes (see below), so free them before tearing down the table.
    var seen_packages = StringHashMap.init(allocator);
    defer {
        var key_it = seen_packages.keyIterator();
        while (key_it.next()) |k| allocator.free(k.*);
        seen_packages.deinit();
    }

    // Reuse a buffer for lowercase string conversion to reduce allocations
    var lowercase_buf = std.array_list.Managed(u8).init(allocator);
    defer lowercase_buf.deinit();

    for (raw_deps) |dep| {
        if (dep.len == 0) {
            output.print(allocator, "Warning: Skipping empty dependency", .{}) catch {};
            continue;
        }

        // Skip deps that look like file paths
        if (std.mem.indexOf(u8, dep, "/") != null) {
            output.print(allocator, "Warning: Skipping dependency that looks like a path: '{s}'", .{dep}) catch {};
            continue;
        }

        // Skip deps without a valid package name (only allow common Python package name chars)
        var valid = true;
        var has_alpha = false;
        for (dep) |c| {
            // Allow alphanumeric, hyphen, underscore, dot, comparison operators/brackets,
            // and comma (separates multiple version constraints, e.g. ">=1.26.0,<2.0").
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                has_alpha = true;
            } else if (!((c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or
                c == '>' or c == '<' or c == '=' or c == '~' or c == ' ' or c == '[' or c == ']' or c == ','))
            {
                valid = false;
                break;
            }
        }

        if (!valid or !has_alpha) {
            output.print(allocator, "Warning: Skipping invalid dependency: '{s}'", .{dep}) catch {};
            continue;
        }

        // Extract the package name to check for duplicates (case-insensitive check)
        const package_name_raw = packageBaseName(dep);

        // Convert package name to lowercase for case-insensitive duplicate check
        // Reuse the same buffer to avoid repeated allocations
        lowercase_buf.clearRetainingCapacity();
        try lowercase_buf.ensureTotalCapacity(package_name_raw.len);
        for (package_name_raw) |c| {
            try lowercase_buf.append(std.ascii.toLower(c));
        }

        // Check if we've already seen this package (case-insensitive)
        if (seen_packages.contains(lowercase_buf.items)) {
            output.print(allocator, "Warning: Skipping duplicate package '{s}' (already included in dependencies)", .{dep}) catch {};
            continue;
        }

        // Accept this dependency as valid
        output.print(allocator, "Including dependency: '{s}'", .{dep}) catch {};
        try valid_deps.append(dep);

        // Add the lowercase name to the seen set using a key we create and own
        const lowercase_key = try allocator.dupe(u8, lowercase_buf.items);
        errdefer allocator.free(lowercase_key);
        try seen_packages.put(lowercase_key, {});
    }

    return valid_deps;
}

// Helper function to determine if a dependency was provided in the config
// Used for memory management to avoid double freeing strings
// Requires access to EnvironmentConfig, which needs to be imported by the caller.
pub fn isConfigProvidedDependency(env_config: *const config.EnvironmentConfig, dep: []const u8) bool {
    for (env_config.dependencies.items) |config_dep| {
        if (std.mem.eql(u8, config_dep, dep)) {
            return true;
        }
    }
    // dev_dependencies are appended into the setup dep list the same way
    // (borrowed, not duped), so they must be recognized here too — otherwise
    // setup's cleanup would free config-owned strings and double-free them.
    for (env_config.dev_dependencies.items) |config_dep| {
        if (std.mem.eql(u8, config_dep, dep)) {
            return true;
        }
    }
    return false;
}

// ============================ Tests ============================

const testing = std.testing;
const test_support = @import("../test_support.zig");

test "parsePyprojectToml: extracts deps from a standalone dependencies array" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const content =
        \\[project]
        \\name = "x"
        \\dependencies = [
        \\    "requests",
        \\    "flask>=2.0",
        \\]
    ;
    var deps = std.array_list.Managed([]const u8).init(a);
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit();
    }
    const count = try parsePyprojectToml(a, content, &deps);
    try testing.expect(count >= 2);
    var has_req = false;
    var has_flask = false;
    for (deps.items) |d| {
        if (std.mem.indexOf(u8, d, "requests") != null) has_req = true;
        if (std.mem.indexOf(u8, d, "flask") != null) has_flask = true;
    }
    try testing.expect(has_req and has_flask);
}

test "parseRequirementsTxt: skips comments and blank lines" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const content =
        \\# a comment
        \\
        \\requests
        \\flask>=2.0
        \\   # indented comment
    ;
    var deps = std.array_list.Managed([]const u8).init(a);
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit();
    }
    const count = try parseRequirementsTxt(a, content, &deps);
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
}

test "isLikelyPythonPackageName filters TOML metadata fields" {
    try testing.expect(isLikelyPythonPackageName("requests"));
    try testing.expect(!isLikelyPythonPackageName("name"));
    try testing.expect(!isLikelyPythonPackageName("version"));
    // A multi-constraint specifier may contain a space and is still a package.
    try testing.expect(isLikelyPythonPackageName("numpy>=1.26.0, <2.0"));
    // Prose with spaces but no version operators is not a package.
    try testing.expect(!isLikelyPythonPackageName("Programming Language :: Python :: 3"));
}

test "validateDependencies keeps multi-constraint specifiers" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const raw = [_][]const u8{
        "numpy>=1.26.0,<2.0",
        "requests>=2.8.1, <3.0",
    };
    var valid = try validateDependencies(a, &raw, "test");
    defer valid.deinit();
    try testing.expectEqual(@as(usize, 2), valid.items.len);
    try testing.expectEqualStrings("numpy>=1.26.0,<2.0", valid.items[0]);
    try testing.expectEqualStrings("requests>=2.8.1, <3.0", valid.items[1]);
}

test "parsePyprojectToml: single-line dependencies array does not swallow later keys" {
    test_support.setupRuntime();
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
    var deps = std.array_list.Managed([]const u8).init(a);
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit();
    }
    const count = try parsePyprojectToml(a, content, &deps);
    try testing.expectEqual(@as(usize, 2), count);
    for (deps.items) |d| {
        try testing.expect(std.mem.indexOf(u8, d, "proj") == null);
        try testing.expect(std.mem.indexOf(u8, d, "1.2.3") == null);
    }
}

test "parsePyprojectToml: keeps comma+space multi-constraint specifier" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const content =
        \\[project]
        \\name = "x"
        \\dependencies = [
        \\    "numpy>=1.26.0, <2.0",
        \\]
    ;
    var deps = std.array_list.Managed([]const u8).init(a);
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit();
    }
    const count = try parsePyprojectToml(a, content, &deps);
    try testing.expect(count >= 1);
    var found = false;
    for (deps.items) |d| {
        if (std.mem.indexOf(u8, d, "numpy") != null and std.mem.indexOf(u8, d, "<2.0") != null) found = true;
    }
    try testing.expect(found);
}

test "parsePyprojectToml: extracts [project].dependencies from a realistic full file" {
    test_support.setupRuntime();
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
    var deps = std.array_list.Managed([]const u8).init(a);
    defer {
        for (deps.items) |d| a.free(d);
        deps.deinit();
    }
    const count = try parsePyprojectToml(a, content, &deps);
    // Exactly the three [project].dependencies entries — not the optional-deps or tool config.
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("requests>=2.28.0", deps.items[0]);
    try testing.expectEqualStrings("numpy>=1.26.0, <2.0", deps.items[1]);
    try testing.expectEqualStrings("mkdocstrings[python]>=0.19", deps.items[2]);
    for (deps.items) |d| {
        try testing.expect(std.mem.indexOf(u8, d, "pytest") == null);
        try testing.expect(std.mem.indexOf(u8, d, "ruff") == null);
    }
}
