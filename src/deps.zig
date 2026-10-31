const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const output = @import("output.zig");
const toml = @import("toml");

/// Extracts the bare package name from a PEP 508 requirement spec, dropping any
/// version constraint, extras, marker, or surrounding whitespace. Used for
/// case-insensitive duplicate detection — e.g. "Flask[async] >= 2.0; python_version<'3.12'"
/// and "flask==3.1" both reduce to a name that compares equal via `samePackage`.
/// Empty for a line without a name: an option (`-r base.txt`), or a bare URL
/// or path (`git+ssh://git@host/repo.git`, `./pkg`). The returned slice
/// points INTO `spec` (no allocation).
fn packageBaseName(spec: []const u8) []const u8 {
    const s = std.mem.trim(u8, spec, " \t\r");
    if (s.len == 0 or !std.ascii.isAlphanumeric(s[0])) return "";
    var end: usize = 0;
    while (end < s.len and (std.ascii.isAlphanumeric(s[end]) or isNameSeparator(s[end]))) end += 1;
    // `git+https://...`, `https://...`, `pkg/sub`: a URL or path, not a name.
    if (end < s.len and (s[end] == ':' or s[end] == '+' or s[end] == '/')) return "";
    return s[0..end];
}

/// The environment marker of a requirement (after `;`), or "".
fn markerOf(spec: []const u8) []const u8 {
    const i = std.mem.findScalar(u8, spec, ';') orelse return "";
    return std.mem.trim(u8, spec[i + 1 ..], " \t\r");
}

/// Whether two markers are the same text, ignoring whitespace.
fn sameMarker(x: []const u8, y: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < x.len and std.ascii.isWhitespace(x[i])) i += 1;
        while (j < y.len and std.ascii.isWhitespace(y[j])) j += 1;
        if (i == x.len or j == y.len) return i == x.len and j == y.len;
        if (x[i] != y[j]) return false;
        i += 1;
        j += 1;
    }
}

/// True when two requirement specs name the same package, ignoring
/// version/extras/markers. Names compare as PEP 503 normalizes them:
/// case-insensitively, with any run of '-', '_' and '.' equal to one '-'
/// (`Flask_Login` is `flask-login`). Lines without a name never match.
/// Allocation-free.
pub fn samePackage(a: []const u8, b: []const u8) bool {
    const x = packageBaseName(a);
    return x.len > 0 and sameName(x, packageBaseName(b));
}

/// True when two project or dependency group names are equal once PEP 503
/// normalizes them. Allocation-free.
pub fn sameName(x: []const u8, y: []const u8) bool {
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

/// Parse a pyproject.toml file and extract PEP 621 dependencies.
///
/// Reads `[project].dependencies` (an array of PEP 508 requirement strings) using a
/// real TOML parser (zig-toml) instead of the old line-by-line scanner. Each string is
/// kept verbatim (version specifiers and extras preserved) and duped into `allocator`;
/// the caller owns the appended strings. Returns the number of dependencies appended.
///
/// zig-toml is strict: a malformed document fails as a whole, and so does
/// setup (error.InvalidPyproject, after saying so). Going on would build the
/// env without the project's dependencies and skip its requires-python.
/// `file` names it in messages.
pub fn parsePyprojectToml(
    allocator: Allocator,
    io: Io,
    content: []const u8,
    file: []const u8,
    deps_list: *std.ArrayList([]const u8),
) !usize {
    output.print(io, "Parsing pyproject.toml for dependencies...", .{});

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    var parsed = parser.parseString(content) catch |err| {
        output.printError(
            io,
            "Failed to parse {s}: {t}. Setup stops rather than build the environment without its dependencies.",
            .{ file, err },
        );
        return error.InvalidPyproject;
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

/// Appends the requirements of each PEP 735 dependency group in `names` from
/// the `[dependency-groups]` table of pyproject.toml `content` (`file` names it
/// in messages), following `{include-group = "..."}` entries. Names compare
/// normalized, so `--group Dev` selects `dev = [...]`. Unlike the project
/// dependencies, a group that is absent, malformed or includes itself is an
/// error: it was asked for by name. Returns the number of requirements appended.
pub fn parseDependencyGroups(
    allocator: Allocator,
    io: Io,
    content: []const u8,
    file: []const u8,
    names: []const []const u8,
    deps_list: *std.ArrayList([]const u8),
) !usize {
    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();
    var parsed = parser.parseString(content) catch |err| {
        output.printError(io, "Failed to parse {s}: {t}", .{ file, err });
        return error.InvalidDependencyGroup;
    };
    defer parsed.deinit();

    const table: ?*const toml.Table = if (parsed.value.get("dependency-groups")) |v| switch (v) {
        .table => |t| t,
        else => null,
    } else null;

    var chain: std.ArrayList([]const u8) = .empty;
    defer chain.deinit(allocator);
    var count: usize = 0;
    for (names) |name| {
        output.print(io, "Reading dependency group '{s}' from {s}", .{ name, file });
        count += try appendGroup(allocator, io, file, table, name, &chain, deps_list);
    }
    return count;
}

/// Appends group `name` and the groups it includes; `chain` holds the groups
/// being expanded, to refuse an include cycle.
fn appendGroup(
    allocator: Allocator,
    io: Io,
    file: []const u8,
    table: ?*const toml.Table,
    name: []const u8,
    chain: *std.ArrayList([]const u8),
    deps_list: *std.ArrayList([]const u8),
) !usize {
    const key, const value = findGroup(table, name) orelse {
        output.printError(
            io,
            "Dependency group '{s}' is not in [dependency-groups] of {s}.",
            .{ name, file },
        );
        if (table) |t| if (t.count() > 0) {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(allocator);
            var it = t.keyIterator();
            while (it.next()) |k| try keys.append(allocator, k.*);
            std.mem.sort([]const u8, keys.items, {}, lessThan);
            const joined = try std.mem.join(allocator, ", ", keys.items);
            defer allocator.free(joined);
            output.printError(io, "Groups defined there: {s}", .{joined});
        };
        return error.DependencyGroupNotFound;
    };
    for (chain.items) |seen| if (sameName(seen, key)) {
        output.printError(io, "Dependency group '{s}' in {s} includes itself.", .{ key, file });
        return error.InvalidDependencyGroup;
    };
    const items = switch (value) {
        .array => |arr| arr.items,
        else => {
            output.printError(io, "Dependency group '{s}' in {s} is not an array.", .{ key, file });
            return error.InvalidDependencyGroup;
        },
    };

    try chain.append(allocator, key);
    defer _ = chain.pop();
    var count: usize = 0;
    for (items) |item| switch (item) {
        .string => |spec| {
            output.print(io, "  - Group dependency ({s}): {s}", .{ key, spec });
            try deps_list.append(allocator, try allocator.dupe(u8, spec));
            count += 1;
        },
        .table => |t| {
            const include = if (t.get("include-group")) |v| switch (v) {
                .string => |inc| inc,
                else => null,
            } else null;
            const inc = include orelse {
                output.printError(
                    io,
                    "Dependency group '{s}' in {s} has a table entry without include-group.",
                    .{ key, file },
                );
                return error.InvalidDependencyGroup;
            };
            count += try appendGroup(allocator, io, file, table, inc, chain, deps_list);
        },
        else => {
            output.printError(
                io,
                "Dependency group '{s}' in {s} has an entry that is neither a string nor an include-group table.",
                .{ key, file },
            );
            return error.InvalidDependencyGroup;
        },
    };
    return count;
}

/// The key and value of the group in `table` whose name is `name` once normalized.
fn findGroup(table: ?*const toml.Table, name: []const u8) ?struct { []const u8, toml.Value } {
    var it = (table orelse return null).iterator();
    while (it.next()) |e| if (sameName(e.key_ptr.*, name)) return .{ e.key_ptr.*, e.value_ptr.* };
    return null;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
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

/// Appends the lines of requirements file `content` to `deps_list`, duped
/// into `allocator`, and returns how many. Lines continued with a trailing
/// `\` (hash-pinned files) are joined. Option lines (`-r`, `-c`, `-e`,
/// `--index-url`, ...) are kept, since pip and uv read them from the install
/// file too; the local paths of `-r`/`-c`/`-e`/`-f` are anchored at `base_dir`,
/// the file's directory, because the install file lives in the venv.
pub fn parseRequirementsTxt(
    allocator: Allocator,
    io: Io,
    content: []const u8,
    base_dir: []const u8,
    deps_list: *std.ArrayList([]const u8),
) !usize {
    output.print(io, "Parsing requirements.txt for dependencies...", .{});
    var count: usize = 0;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (std.mem.endsWith(u8, line, "\\")) {
            try joined.appendSlice(allocator, line[0 .. line.len - 1]);
            try joined.append(allocator, ' ');
            if (line_iter.peek() != null) continue;
        } else try joined.appendSlice(allocator, line);

        const entry = std.mem.trim(u8, joined.items, " \t");
        defer joined.clearRetainingCapacity();
        if (entry.len == 0 or entry[0] == '#') continue;

        const dep = if (entry[0] == '-')
            try anchorOption(allocator, entry, base_dir)
        else
            try allocator.dupe(u8, entry);
        output.print(io, "  - Requirements file {s}: {s}", .{
            if (entry[0] == '-') "option" else "dependency",
            dep,
        });
        try deps_list.append(allocator, dep);
        count += 1;
    }
    output.print(io, "Found {d} dependencies in requirements.txt format", .{count});
    return count;
}

/// Option line `line` of a requirements file in `base_dir`, with the local
/// path of `-r`/`--requirement`, `-c`/`--constraint`, `-e`/`--editable` and
/// `-f`/`--find-links` made absolute. URLs and absolute paths stay.
fn anchorOption(allocator: Allocator, line: []const u8, base_dir: []const u8) ![]const u8 {
    const options = [_][2][]const u8{
        .{ "-r", "--requirement" },
        .{ "-c", "--constraint" },
        .{ "-e", "--editable" },
        .{ "-f", "--find-links" },
    };
    for (options) |names| for (names) |name| {
        if (!std.mem.startsWith(u8, line, name)) continue;
        const rest = line[name.len..];
        // `-r x`, `-rx`, `--requirement x`, `--requirement=x`
        const sep: []const u8 = if (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t' or rest[0] == '='))
            rest[0..1]
        else if (name.len == 2) "" else continue;
        const value = std.mem.trim(u8, rest[sep.len..], " \t");
        if (value.len == 0 or std.fs.path.isAbsolute(value) or
            std.mem.find(u8, value, "://") != null or std.mem.startsWith(u8, value, "git+"))
            return allocator.dupe(u8, line);
        const abs = try std.fs.path.join(allocator, &.{ base_dir, value });
        return std.mem.concat(allocator, u8, &.{ name, if (sep.len == 0) " " else sep, abs });
    };
    return allocator.dupe(u8, line);
}

/// Drops empty entries, entries without a project name, and later duplicates
/// of a package: the same name (by `samePackage`) with the same environment
/// marker, so `numpy<2; python_version<'3.9'` and `numpy>=2; python_version>='3.9'`
/// both stay. Option lines (`-r`, `--index-url`, ...) and bare URLs or paths
/// are kept unless repeated exactly. The returned list borrows from `raw_deps`.
pub fn validateDependencies(
    allocator: Allocator,
    io: Io,
    raw_deps: []const []const u8,
    env_name: []const u8,
) !std.ArrayList([]const u8) {
    output.print(io, "Validating dependencies for '{s}':", .{env_name});
    var valid_deps: std.ArrayList([]const u8) = .empty;
    errdefer valid_deps.deinit(allocator);

    next: for (raw_deps) |raw| {
        const dep = std.mem.trim(u8, raw, " \t\r");
        if (dep.len == 0) {
            output.printWarning(io, "Skipping empty dependency", .{});
            continue;
        }

        // Only the project name is checked here; the rest of the PEP 508 line
        // (specifiers like `!=1.0` or `==1.0.*`, extras, markers, `name @ url`)
        // is left for pip/uv, which validate it properly at install time.
        const name = packageBaseName(dep);
        const unnamed = dep[0] == '-' or std.mem.find(u8, dep, "://") != null or
            dep[0] == '.' or dep[0] == '/';
        if (name.len == 0 and !unnamed) {
            output.printWarning(
                io,
                "Skipping invalid dependency (no project name): '{s}'",
                .{dep},
            );
            continue;
        }

        for (valid_deps.items) |seen| {
            const duplicate = if (name.len == 0)
                std.mem.eql(u8, seen, dep)
            else
                samePackage(seen, dep) and sameMarker(markerOf(seen), markerOf(dep));
            if (!duplicate) continue;
            output.printWarning(
                io,
                "Skipping duplicate package '{s}' (already included in dependencies)",
                .{dep},
            );
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
    const count = try parsePyprojectToml(a, testing.io, content, "pyproject.toml", &deps);
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
    const count = try parseRequirementsTxt(a, testing.io, content, "/proj", &deps);
    try testing.expectEqual(@as(usize, 2), count);
}

test "packageBaseName strips versions, extras, and markers" {
    try testing.expectEqualStrings("flask", packageBaseName("flask"));
    try testing.expectEqualStrings("flask", packageBaseName("flask>=2.0"));
    try testing.expectEqualStrings("flask", packageBaseName("flask==3.1"));
    try testing.expectEqualStrings("flask", packageBaseName("flask!=2.0"));
    try testing.expectEqualStrings("numpy", packageBaseName("numpy>=1.26.0, <2.0"));
    try testing.expectEqualStrings("mkdocstrings", packageBaseName("mkdocstrings[python]>=0.19"));
    try testing.expectEqualStrings(
        "requests",
        packageBaseName("requests ; python_version < '3.12'"),
    );
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
        "-e .", // an option line: kept for pip/uv
        "",
        "flask_login",
        "Flask.Login>=0.6", // duplicate of flask_login (PEP 503)
        "=bad", // no name
    };
    var valid = try validateDependencies(a, testing.io, &raw, "test");
    defer valid.deinit(a);
    try std.testing.expectEqual(@as(usize, 7), valid.items.len);
    try std.testing.expectEqualStrings("flask!=2.0", valid.items[0]);
    try std.testing.expectEqualStrings(
        "pkg @ https://example.com/pkg-1.0-py3-none-any.whl",
        valid.items[4],
    );
    try std.testing.expectEqualStrings("-e .", valid.items[5]);
    try std.testing.expectEqualStrings("flask_login", valid.items[6]);
}

test "validateDependencies keeps marker-split pins and distinct URLs" {
    const a = testing.allocator;
    const raw = [_][]const u8{
        "numpy<2; python_version < '3.9'",
        "numpy>=2; python_version >= '3.9'",
        "numpy>=2 ; python_version>='3.9'", // same marker, spacing aside
        "git+ssh://git@github.com/org/repo1.git",
        "git+ssh://git@github.com/org/repo2.git",
        "git+ssh://git@github.com/org/repo2.git",
        "--extra-index-url https://download.pytorch.org/whl/cu121",
    };
    var valid = try validateDependencies(a, testing.io, &raw, "test");
    defer valid.deinit(a);
    try testing.expectEqual(@as(usize, 5), valid.items.len);
    try testing.expectEqualStrings("numpy>=2; python_version >= '3.9'", valid.items[1]);
    try testing.expectEqualStrings("git+ssh://git@github.com/org/repo2.git", valid.items[3]);
}

test "parseRequirementsTxt joins continuations and anchors option paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\six==1.16.0 \
        \\    --hash=sha256:aaa \
        \\    --hash=sha256:bbb
        \\-r base.txt
        \\--constraint=c.txt
        \\-e ./pkg
        \\-e git+https://example.com/x.git#egg=x
        \\--index-url https://download.pytorch.org/whl/cu121
        \\-r /abs/other.txt
        \\
    ;
    var deps: std.ArrayList([]const u8) = .empty;
    try testing.expectEqual(@as(usize, 7), try parseRequirementsTxt(a, testing.io, content, "/proj", &deps));
    try testing.expectEqualStrings("six==1.16.0      --hash=sha256:aaa      --hash=sha256:bbb", deps.items[0]);
    try testing.expectEqualStrings("-r /proj/base.txt", deps.items[1]);
    try testing.expectEqualStrings("--constraint=/proj/c.txt", deps.items[2]);
    try testing.expectEqualStrings("-e /proj/./pkg", deps.items[3]);
    try testing.expectEqualStrings("-e git+https://example.com/x.git#egg=x", deps.items[4]);
    try testing.expectEqualStrings("--index-url https://download.pytorch.org/whl/cu121", deps.items[5]);
    try testing.expectEqualStrings("-r /abs/other.txt", deps.items[6]);
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
    const count = try parsePyprojectToml(a, testing.io, content, "pyproject.toml", &deps);
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
    const count = try parsePyprojectToml(a, testing.io, content, "pyproject.toml", &deps);
    try testing.expect(count >= 1);
    var found = false;
    for (deps.items) |d| {
        if (std.mem.find(
            u8,
            d,
            "numpy",
        ) != null and std.mem.find(u8, d, "<2.0") != null) found = true;
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
    const count = try parsePyprojectToml(a, testing.io, content, "pyproject.toml", &deps);
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
    try std.testing.expect(
        (try pyprojectField(a, "[project]\nname = \"x\"\n", "description")) == null,
    );
    try std.testing.expect(
        (try pyprojectField(a, "[project]\ndescription = \"\"\n", "description")) == null,
    );
    try std.testing.expect((try pyprojectField(a, "not = = toml", "description")) == null);
}

test "canonicalName normalises case and separator runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("zope-interface", try canonicalName(a, "Zope.Interface"));
    try std.testing.expectEqualStrings("a-b", try canonicalName(a, "A__.-b"));
}

test "parseDependencyGroups: named groups, normalized names, include-group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content =
        \\[project]
        \\name = "demo"
        \\dependencies = ["requests"]
        \\
        \\[dependency-groups]
        \\dev = ["pytest>=9"]
        \\# notebooks
        \\demo = [
        \\    "openai>=1.50",
        \\    "ipykernel>=6",
        \\]
        \\Docs_Build = [{include-group = "dev"}, "mkdocs"]
    ;
    var list: std.ArrayList([]const u8) = .empty;
    const n = try parseDependencyGroups(
        a,
        testing.io,
        content,
        "pyproject.toml",
        &.{ "demo", "docs-build" },
        &list,
    );
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("openai>=1.50", list.items[0]);
    try testing.expectEqualStrings("ipykernel>=6", list.items[1]);
    try testing.expectEqualStrings("pytest>=9", list.items[2]);
    try testing.expectEqualStrings("mkdocs", list.items[3]);
}

test "parseDependencyGroups: missing group, missing table and cycles are errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    const groups_toml =
        \\[dependency-groups]
        \\dev = ["pytest"]
        \\a = [{include-group = "b"}]
        \\b = [{include-group = "A"}]
        \\bad = "pytest"
    ;
    try testing.expectError(
        error.DependencyGroupNotFound,
        parseDependencyGroups(a, testing.io, groups_toml, "pyproject.toml", &.{"test"}, &list),
    );
    try testing.expectError(
        error.DependencyGroupNotFound,
        parseDependencyGroups(
            a,
            testing.io,
            "[project]\nname = \"x\"\n",
            "pyproject.toml",
            &.{"dev"},
            &list,
        ),
    );
    try testing.expectError(
        error.InvalidDependencyGroup,
        parseDependencyGroups(a, testing.io, groups_toml, "pyproject.toml", &.{"a"}, &list),
    );
    try testing.expectError(
        error.InvalidDependencyGroup,
        parseDependencyGroups(a, testing.io, groups_toml, "pyproject.toml", &.{"bad"}, &list),
    );
    try testing.expectError(
        error.InvalidDependencyGroup,
        parseDependencyGroups(
            a,
            testing.io,
            "[dependency-groups\n",
            "pyproject.toml",
            &.{"dev"},
            &list,
        ),
    );
}

test "parsePyprojectToml: a document that does not parse is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var deps: std.ArrayList([]const u8) = .empty;
    try testing.expectError(
        error.InvalidPyproject,
        parsePyprojectToml(a, testing.io, "[project\ndependencies = [\"six\"]\n", "pyproject.toml", &deps),
    );
}
