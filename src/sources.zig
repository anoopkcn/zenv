//! An env's dependency sources: the project files its packages come from.
//!
//! One module answers the three questions zenv asks about them, so the
//! answers cannot drift apart:
//!   - what setup installs (`collect`): zenv.json `dependencies` and
//!     `dev_dependencies`, the `dependency_file`, the `--group` dependency
//!     groups, and the project's requires-python;
//!   - which files the rebuild gate must watch besides the `dependency_file`
//!     (`readsProjectPyproject`);
//!   - where `zenv add` records a package (`recordTarget`, `record`), and so
//!     where `zenv remove` takes it out again (`unrecord`, `recordedIn`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const deps = @import("deps.zig");
const manifest = @import("manifest.zig");
const output = @import("output.zig");
const paths = @import("paths.zig");
const runtime = @import("runtime.zig");
const Ctx = runtime.Ctx;

/// The project's own pyproject.toml, relative to the project directory: what
/// `--dev` installs and, without a pyproject `dependency_file`, where
/// dependency groups live.
const project_pyproject = "pyproject.toml";

/// Whether dependency file `path` is a pyproject.toml rather than a
/// requirements file.
pub fn isPyproject(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".toml");
}

/// The pyproject.toml that holds an env's dependency groups, relative to the
/// project directory: its `dependency_file` when that is a pyproject.toml,
/// else `pyproject.toml`.
fn groupsFile(dep_file: ?[]const u8) []const u8 {
    if (dep_file) |df| if (isPyproject(df)) return df;
    return project_pyproject;
}

/// Whether a build of `env` with `groups` (and `--dev` when `dev`) reads the
/// project's ./pyproject.toml although it is not the env's `dependency_file`:
/// for the groups when the `dependency_file` is no pyproject.toml, and for
/// `--dev`, which installs the project. The rebuild gate watches it then.
pub fn readsProjectPyproject(env: *const config.Env, groups: []const []const u8, dev: bool) bool {
    const df = env.dependency_file orelse return groups.len > 0 or dev;
    if (groups.len > 0 and !isPyproject(df)) return true;
    if (!dev) return false;
    const plain = if (std.mem.startsWith(u8, df, "./")) df[2..] else df;
    return !std.mem.eql(u8, plain, project_pyproject);
}

pub const RequiresPython = struct {
    /// PEP 440 specifiers, e.g. ">=3.10, <4".
    spec: []const u8,
    /// The pyproject.toml it came from, for messages.
    file: []const u8,
};

/// What setup installs for an env.
pub const Collected = struct {
    /// Dependency lines, in requirements.txt syntax, in source order.
    deps: []const []const u8,
    /// The project's requires-python, from a pyproject.toml dependency file;
    /// with `--dev`, ./pyproject.toml (the project pip installs) takes
    /// precedence. Null when neither sets it.
    requires_python: ?RequiresPython,
};

/// Collects what setup installs for `env`, whose relative files are anchored
/// at `project_dir`, logging each source as it goes. `groups` are the
/// `--group` names; `dev` is `--dev`. Allocates with `ctx.arena`; config
/// strings are borrowed.
pub fn collect(
    ctx: Ctx,
    env: *const config.Env,
    project_dir: []const u8,
    groups: []const []const u8,
    dev: bool,
) !Collected {
    const io = ctx.io;
    const allocator = ctx.arena;
    var all: std.ArrayList([]const u8) = .empty;

    if (env.dependencies.items.len > 0) {
        output.print(
            io,
            "Adding {d} dependencies from configuration:",
            .{env.dependencies.items.len},
        );
        for (env.dependencies.items) |dep| {
            output.print(io, "  - Config dependency: {s}", .{dep});
        }
        try all.appendSlice(allocator, env.dependencies.items);
    } else {
        output.print(io, "No dependencies specified in configuration.", .{});
    }

    // Development dependencies from config (e.g. those recorded by
    // `zenv add --dev`).
    if (env.dev_dependencies.items.len > 0) {
        output.print(
            io,
            "Adding {d} development dependencies from configuration:",
            .{env.dev_dependencies.items.len},
        );
        for (env.dev_dependencies.items) |dep| {
            output.print(io, "  - Dev dependency: {s}", .{dep});
        }
        try all.appendSlice(allocator, env.dev_dependencies.items);
    }

    var requires_python: ?RequiresPython = null;

    if (env.dependency_file) |req_file| {
        const req_content = readProjectFile(ctx, project_dir, req_file, 1 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                output.printError(
                    io,
                    "Requirements file specified in configuration ('{s}') not found.",
                    .{req_file},
                );
                return err;
            }
            output.printError(io, "Failed to read file '{s}': {t}", .{ req_file, err });
            return error.PathResolutionFailed;
        };
        output.print(io, "Reading dependencies from file: '{s}'", .{req_file});
        output.print(
            io,
            "Successfully read file ({d} bytes). Parsing dependencies...",
            .{req_content.len},
        );

        const is_toml = isPyproject(req_file);
        output.print(
            io,
            "{s}",
            .{
                if (is_toml) "Detected TOML file format, parsing as pyproject.toml" else "Parsing as requirements.txt format",
            },
        );
        const count = if (is_toml)
            try deps.parsePyprojectToml(allocator, io, req_content, req_file, &all)
        else
            try deps.parseRequirementsTxt(
                allocator,
                io,
                req_content,
                Io.Dir.path.dirname(try paths.resolvePath(allocator, project_dir, req_file)) orelse project_dir,
                &all,
            );
        if (is_toml) if (try deps.pyprojectField(
            allocator,
            req_content,
            "requires-python",
        )) |spec| {
            requires_python = .{ .spec = spec, .file = req_file };
        };

        if (count > 0) {
            output.print(io, "Added {d} dependencies from file '{s}'", .{ count, req_file });
        } else {
            output.printWarning(io, "No valid dependencies found in file '{s}'", .{req_file});
        }
    } else {
        output.print(io, "No requirements file specified in configuration.", .{});
    }

    // Dependency groups named with --group (PEP 735).
    if (groups.len > 0) {
        const file = groupsFile(env.dependency_file);
        const content = readProjectFile(ctx, project_dir, file, 10 * 1024 * 1024) catch |err| {
            if (err != error.FileNotFound) return err;
            output.printError(
                io,
                "--group reads [dependency-groups] from '{s}', which does not exist.",
                .{file},
            );
            return error.DependencyGroupNotFound;
        };
        const count = try deps.parseDependencyGroups(allocator, io, content, file, groups, &all);
        output.print(
            io,
            "Added {d} dependencies from dependency groups in '{s}'",
            .{ count, file },
        );
    }

    if (dev) {
        if (readProjectFile(ctx, project_dir, project_pyproject, 10 * 1024 * 1024)) |content| {
            if (try deps.pyprojectField(
                allocator,
                content,
                "requires-python",
            )) |spec| requires_python = .{ .spec = spec, .file = project_pyproject };
        } else |_| {}
    }

    return .{ .deps = all.items, .requires_python = requires_python };
}

/// The content of `rel`, a path relative to `project_dir` (or absolute).
fn readProjectFile(ctx: Ctx, project_dir: []const u8, rel: []const u8, limit: usize) ![]u8 {
    const path = try paths.resolvePath(ctx.arena, project_dir, rel);
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(limit));
}

/// Where `zenv add` records a package, and `zenv remove` removes it from.
pub const Record = union(enum) {
    /// zenv.json `dependencies`, or `dev_dependencies` when true.
    zenv_json: bool,
    /// A requirements file (absolute path), for runtime dependencies.
    requirements: struct { path: []const u8, label: []const u8 },
    /// `[project].dependencies` when `group` is null, else that dependency group.
    pyproject: struct { path: []const u8, label: []const u8, group: ?[]const u8 },

    /// The manifest file it writes besides zenv.json (which a pyproject
    /// record falls back to), or null.
    pub fn file(self: Record) ?[]const u8 {
        return switch (self) {
            .zenv_json => null,
            .requirements => |r| r.path,
            .pyproject => |p| p.path,
        };
    }

    /// The dependency group it records into, when that is one rebuilds must
    /// install (`--group` replay): any group of a pyproject.toml.
    pub fn group(self: Record) ?[]const u8 {
        return switch (self) {
            .pyproject => |p| p.group,
            else => null,
        };
    }

    /// The place in words, for messages: `pyproject.toml ([project].dependencies)`.
    pub fn describe(self: Record, a: Allocator) ![]const u8 {
        switch (self) {
            .zenv_json => |dev| return if (dev) "zenv.json (dev_dependencies)" else "zenv.json (dependencies)",
            .requirements => |r| return r.label,
            .pyproject => |p| {
                if (p.group) |g| return a.print("{s} ([dependency-groups].{s})", .{ p.label, g });
                return a.print("{s} ([project].dependencies)", .{p.label});
            },
        }
    }
};

/// Picks the manifest for a package added to `group` (null: a runtime
/// dependency; "dev" for `--dev`):
///
/// | dependency_file   | runtime            | --dev                    | --group <other>      |
/// |-------------------|--------------------|--------------------------|----------------------|
/// | pyproject.toml    | [project]          | [dependency-groups].dev  | [dependency-groups]  |
/// | requirements.txt  | requirements.txt   | zenv.json dev_deps       | ./pyproject.toml     |
/// | none              | zenv.json deps     | zenv.json dev_deps       | ./pyproject.toml     |
///
/// `zenv_only` (`--zenv`) sends runtime and dev packages to zenv.json and
/// refuses another group, as does a project without the pyproject.toml it
/// would go to. Prints why it refuses.
pub fn recordTarget(
    allocator: Allocator,
    io: Io,
    project_dir: []const u8,
    dep_file: ?[]const u8,
    group: ?[]const u8,
    zenv_only: bool,
) !Record {
    const dev = if (group) |g| deps.sameName(g, "dev") else false;
    const toml_dep_file = if (dep_file) |df| isPyproject(df) else false;

    if (group != null and !dev) {
        if (zenv_only) {
            output.printError(
                io,
                "zenv.json has no dependency groups besides dev_dependencies, so '--zenv' cannot record into group '{s}'.",
                .{group.?},
            );
            return error.ArgsError;
        }
        const label = groupsFile(dep_file);
        const path = try paths.resolvePath(allocator, project_dir, label);
        if (!runtime.exists(io, path)) {
            output.printError(
                io,
                "Dependency group '{s}' is recorded in pyproject.toml, but '{s}' does not exist.",
                .{ group.?, path },
            );
            return error.ArgsError;
        }
        return .{ .pyproject = .{ .path = path, .label = label, .group = group } };
    }
    if (zenv_only or dep_file == null) return .{ .zenv_json = dev };
    const path = try paths.resolvePath(allocator, project_dir, dep_file.?);
    if (toml_dep_file) return .{
        .pyproject = .{ .path = path, .label = dep_file.?, .group = group },
    };
    // requirements files have no dev concept; dev deps live in zenv.json.
    if (dev) return .{ .zenv_json = true };
    return .{ .requirements = .{ .path = path, .label = dep_file.? } };
}

/// Records the installed `package` where `target` says; `zenv_json_path` is
/// the project's zenv.json, holding env `env_name`.
pub fn record(
    allocator: Allocator,
    io: Io,
    zenv_json_path: []const u8,
    env_name: []const u8,
    target: Record,
    package: []const u8,
) !void {
    switch (target) {
        .zenv_json => |dev| {
            try manifest.addToZenvJson(allocator, io, zenv_json_path, env_name, package, dev);
            output.print(
                io,
                "Recorded in zenv.json ({s}).",
                .{if (dev) "dev_dependencies" else "dependencies"},
            );
        },
        .requirements => |r| {
            try manifest.addToRequirementsTxt(allocator, io, r.path, package);
            output.print(io, "Recorded in {s}.", .{r.label});
        },
        .pyproject => |p| {
            if (try manifest.addToPyproject(allocator, io, p.path, package, p.group)) {
                if (p.group) |g|
                    output.print(io, "Recorded in {s} ([dependency-groups].{s}).", .{ p.label, g })
                else
                    output.print(io, "Recorded in {s} ([project].dependencies).", .{p.label});
            } else {
                // Runtime case with no [project] table: fall back to zenv.json.
                output.print(
                    io,
                    "Could not locate [project] in {s}; recording in zenv.json instead.",
                    .{p.label},
                );
                try manifest.addToZenvJson(allocator, io, zenv_json_path, env_name, package, false);
            }
        },
    }
}

/// Removes `package` from where `target` says; `zenv_json_path` is the
/// project's zenv.json, holding env `env_name`. Returns the place it was
/// removed from, or null when it is not recorded there. Like `record`, a
/// runtime package that pyproject.toml does not list is looked for in
/// zenv.json. With `.check` nothing is written.
pub fn unrecord(
    allocator: Allocator,
    io: Io,
    zenv_json_path: []const u8,
    env_name: []const u8,
    target: Record,
    package: []const u8,
    mode: manifest.Removal,
) !?Record {
    const in_zenv_json: Record = .{ .zenv_json = false };
    const found = switch (target) {
        .zenv_json => |dev| try manifest.removeFromZenvJson(
            allocator,
            io,
            zenv_json_path,
            env_name,
            package,
            dev,
            mode,
        ),
        .requirements => |r| try manifest.removeFromRequirementsTxt(allocator, io, r.path, package, mode),
        .pyproject => |p| found: {
            if (try manifest.removeFromPyproject(allocator, io, p.path, package, p.group, mode)) break :found true;
            if (p.group != null) break :found false;
            return unrecord(allocator, io, zenv_json_path, env_name, in_zenv_json, package, mode);
        },
    };
    return if (found) target else null;
}

/// A place a package is recorded in, with the `zenv remove` flags that reach it.
pub const Recorded = struct {
    /// `Record.describe` of the place.
    where: []const u8,
    /// "" for the place the command reaches without flags.
    flags: []const u8,
};

/// Every place the env's packages come from that records `package`: the ones
/// `--dev` and `--zenv` choose between, and each of `groups`, the dependency
/// groups its rebuilds install. Allocates with `a`, an arena.
pub fn recordedIn(
    a: Allocator,
    io: Io,
    project_dir: []const u8,
    zenv_json_path: []const u8,
    env_name: []const u8,
    dep_file: ?[]const u8,
    groups: []const []const u8,
    package: []const u8,
) ![]const Recorded {
    const Choice = struct { group: ?[]const u8, zenv_only: bool, flags: []const u8 };
    var choices: std.ArrayList(Choice) = .empty;
    try choices.appendSlice(a, &.{
        .{ .group = null, .zenv_only = false, .flags = "" },
        .{ .group = "dev", .zenv_only = false, .flags = "--dev" },
        .{ .group = null, .zenv_only = true, .flags = "--zenv" },
        .{ .group = "dev", .zenv_only = true, .flags = "--dev --zenv" },
    });
    for (groups) |g| {
        if (deps.sameName(g, "dev")) continue;
        // recordTarget refuses (loudly) a group without its pyproject.toml.
        if (!runtime.exists(io, try paths.resolvePath(a, project_dir, groupsFile(dep_file)))) continue;
        try choices.append(a, .{
            .group = g,
            .zenv_only = false,
            .flags = try a.print("--group {s}", .{g}),
        });
    }

    var found: std.ArrayList(Recorded) = .empty;
    for (choices.items) |c| {
        const target = try recordTarget(a, io, project_dir, dep_file, c.group, c.zenv_only);
        const place = try unrecord(a, io, zenv_json_path, env_name, target, package, .check) orelse continue;
        const where = try place.describe(a);
        for (found.items) |f| {
            if (std.mem.eql(u8, f.where, where)) break;
        } else try found.append(a, .{ .where = where, .flags = c.flags });
    }
    return found.items;
}

// ============================ Tests ============================

const testing = std.testing;
const test_support = @import("test_support.zig");

test "readsProjectPyproject: only when the build reads a pyproject.toml it does not track" {
    var env = config.Env.init(testing.allocator);
    try testing.expect(!readsProjectPyproject(&env, &.{}, false));
    try testing.expect(readsProjectPyproject(&env, &.{"demo"}, false));
    try testing.expect(readsProjectPyproject(&env, &.{}, true));

    env.dependency_file = "requirements.txt";
    try testing.expect(!readsProjectPyproject(&env, &.{}, false));
    try testing.expect(readsProjectPyproject(&env, &.{"demo"}, false));
    try testing.expect(readsProjectPyproject(&env, &.{}, true));

    env.dependency_file = "./pyproject.toml";
    try testing.expect(!readsProjectPyproject(&env, &.{"demo"}, true));

    // Groups come from this file; --dev still reads ./pyproject.toml.
    env.dependency_file = "sub/pyproject.toml";
    try testing.expect(!readsProjectPyproject(&env, &.{"demo"}, false));
    try testing.expect(readsProjectPyproject(&env, &.{}, true));
}

test "recordTarget follows the table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const base = try cwd.realPathFileAlloc(io, ".zig-cache", a);
    const dir = try Io.Dir.path.join(a, &.{ base, "tmp", "zenv-sources-record" });
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);

    try testing.expectEqual(Record{ .zenv_json = false }, try recordTarget(a, io, dir, null, null, false));
    try testing.expectEqual(Record{ .zenv_json = true }, try recordTarget(a, io, dir, null, "dev", false));
    try testing.expectEqual(Record{ .zenv_json = true }, try recordTarget(a, io, dir, "r.txt", "dev", false));
    try testing.expectEqual(Record{ .zenv_json = false }, try recordTarget(a, io, dir, "r.txt", null, true));

    const req = try recordTarget(a, io, dir, "r.txt", null, false);
    try testing.expectEqualStrings("r.txt", req.requirements.label);
    try testing.expect(req.group() == null);

    const toml = try recordTarget(a, io, dir, "pyproject.toml", "dev", false);
    try testing.expectEqualStrings("dev", toml.group().?);

    // Another group needs ./pyproject.toml to exist, and is never zenv.json.
    try testing.expectError(error.ArgsError, recordTarget(a, io, dir, "r.txt", "demo", false));
    try testing.expectError(error.ArgsError, recordTarget(a, io, dir, null, "demo", true));
    try cwd.writeFile(io, .{
        .sub_path = try Io.Dir.path.join(a, &.{ dir, "pyproject.toml" }),
        .data = "[project]\n",
    });
    const grp = try recordTarget(a, io, dir, "r.txt", "demo", false);
    try testing.expectEqualStrings("pyproject.toml", grp.pyproject.label);
    try testing.expectEqualStrings("demo", grp.group().?);
}

test "collect gathers config, file and group dependencies in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const base = try cwd.realPathFileAlloc(io, ".zig-cache", a);
    const dir = try Io.Dir.path.join(a, &.{ base, "tmp", "zenv-sources-collect" });
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = try Io.Dir.path.join(a, &.{ dir, "r.txt" }), .data = "six\n" });
    try cwd.writeFile(io, .{
        .sub_path = try Io.Dir.path.join(a, &.{ dir, "pyproject.toml" }),
        .data = "[project]\nname = \"p\"\nrequires-python = \">=3.9\"\n\n[dependency-groups]\ndemo = [\"idna\"]\n",
    });

    var env = config.Env.init(a);
    try env.dependencies.append(a, "numpy");
    env.dependency_file = "r.txt";
    const ctx = test_support.ctx(a, &test_support.no_env);

    const got = try collect(ctx, &env, dir, &.{"demo"}, true);
    try testing.expectEqual(@as(usize, 3), got.deps.len);
    try testing.expectEqualStrings("numpy", got.deps[0]);
    try testing.expectEqualStrings("six", got.deps[1]);
    try testing.expectEqualStrings("idna", got.deps[2]);
    try testing.expectEqualStrings(">=3.9", got.requires_python.?.spec);

    try testing.expectError(error.DependencyGroupNotFound, collect(ctx, &env, dir, &.{"nope"}, false));
}

test "unrecord removes from the target, and recordedIn names every place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const base = try cwd.realPathFileAlloc(io, ".zig-cache", a);
    const dir = try Io.Dir.path.join(a, &.{ base, "tmp", "zenv-sources-unrecord" });
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    const zenv_json = try Io.Dir.path.join(a, &.{ dir, "zenv.json" });
    const pyproject = try Io.Dir.path.join(a, &.{ dir, "pyproject.toml" });
    try cwd.writeFile(io, .{ .sub_path = zenv_json, .data =
        \\{ "e": { "target_machines": ["*"], "dependencies": ["six", "idna"], "dev_dependencies": ["six"] } }
    });
    try cwd.writeFile(io, .{
        .sub_path = pyproject,
        .data = "[project]\ndependencies = [\"six\"]\n\n[dependency-groups]\ndev = [\"ruff\"]\ndemo = [\"six\"]\n",
    });

    const places = try recordedIn(a, io, dir, zenv_json, "e", "pyproject.toml", &.{ "demo", "dev" }, "Six>=1");
    try testing.expectEqual(@as(usize, 4), places.len);
    try testing.expectEqualStrings("pyproject.toml ([project].dependencies)", places[0].where);
    try testing.expectEqualStrings("", places[0].flags);
    try testing.expectEqualStrings("zenv.json (dependencies)", places[1].where);
    try testing.expectEqualStrings("--zenv", places[1].flags);
    try testing.expectEqualStrings("zenv.json (dev_dependencies)", places[2].where);
    try testing.expectEqualStrings("--dev --zenv", places[2].flags);
    try testing.expectEqualStrings("pyproject.toml ([dependency-groups].demo)", places[3].where);
    try testing.expectEqualStrings("--group demo", places[3].flags);

    // A runtime package pyproject.toml lacks is taken from zenv.json, where
    // `record` puts one when there is no [project] table.
    const runtime_target = try recordTarget(a, io, dir, "pyproject.toml", null, false);
    const idna = (try unrecord(a, io, zenv_json, "e", runtime_target, "idna", .remove)).?;
    try testing.expectEqualStrings("zenv.json (dependencies)", try idna.describe(a));
    try testing.expect(try unrecord(a, io, zenv_json, "e", runtime_target, "idna", .remove) == null);

    // A group has no such fallback.
    const dev_target = try recordTarget(a, io, dir, "pyproject.toml", "dev", false);
    try testing.expect(try unrecord(a, io, zenv_json, "e", dev_target, "six", .remove) == null);
    try testing.expect(try unrecord(a, io, zenv_json, "e", dev_target, "ruff", .remove) != null);
    try testing.expectEqual(
        @as(usize, 0),
        (try recordedIn(a, io, dir, zenv_json, "e", "pyproject.toml", &.{}, "ruff")).len,
    );
}
