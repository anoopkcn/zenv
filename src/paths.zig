//! Paths zenv derives: ZENV_DIR, a project's root and venv directory, and the
//! check on names that become directories.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const path = std.Io.Dir.path;
const Environ = std.process.Environ;

/// Environment names and aliases become directory names and command-line
/// identifiers: 1-255 of `[A-Za-z0-9_.-]`, and not `.` (the current-directory
/// shortcut) or `..`.
pub fn isValidEnvName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    }
    return true;
}

test "isValidEnvName" {
    try std.testing.expect(isValidEnvName("my-env_1.2"));
    for ([_][]const u8{ "", ".", "..", "a b", "a/b", "../x", "x\n" }) |bad| try std.testing.expect(
        !isValidEnvName(bad),
    );
}

/// The zenv directory: $ZENV_DIR if set, otherwise ~/.zenv. Caller owns it.
pub fn getZenvDir(allocator: Allocator, env: *const Environ.Map) ![]const u8 {
    if (env.get("ZENV_DIR")) |zenv_dir| return allocator.dupe(u8, zenv_dir);
    const home_dir = env.get("HOME") orelse return error.HomeDirectoryNotFound;
    return path.join(allocator, &.{ home_dir, ".zenv" });
}

/// `<zenv dir>/<name>`. Caller owns the result.
pub fn zenvPath(allocator: Allocator, env: *const Environ.Map, name: []const u8) ![]const u8 {
    const dir = try getZenvDir(allocator, env);
    defer allocator.free(dir);
    return path.join(allocator, &.{ dir, name });
}

/// THE rule for where an environment lives: `<base_dir>/<env_name>`, where a
/// relative `base_dir` is anchored at `project_dir` (the directory holding
/// zenv.json). Every venv path in the program — registry entries, generated
/// scripts, setup directories — must come from here so they can never
/// disagree. Caller owns the returned slice.
pub fn venvPath(
    allocator: Allocator,
    project_dir: []const u8,
    base_dir: []const u8,
    env_name: []const u8,
) ![]const u8 {
    if (path.isAbsolute(base_dir)) return path.join(allocator, &.{ base_dir, env_name });
    return path.join(allocator, &.{ project_dir, base_dir, env_name });
}

/// Resolves a config-relative path against `anchor_dir`; absolute paths are
/// left untouched. Caller owns the result.
pub fn resolvePath(allocator: Allocator, anchor_dir: []const u8, rel: []const u8) ![]u8 {
    if (path.isAbsolute(rel)) return allocator.dupe(u8, rel);
    return path.join(allocator, &.{ anchor_dir, rel });
}

/// The nearest directory at or above `start` (an absolute path) that holds a
/// zenv.json, or null if none does. Caller owns the result. The nearest file
/// wins even if its project has no registered environment, matching how
/// direnv treats .envrc: a nested project shadows the one around it.
pub fn findProjectRoot(allocator: Allocator, io: Io, start: []const u8) !?[]u8 {
    var dir: []const u8 = start;
    while (true) {
        const candidate = try path.join(allocator, &.{ dir, "zenv.json" });
        defer allocator.free(candidate);
        if (Io.Dir.cwd().access(io, candidate, .{})) |_| {
            return try allocator.dupe(u8, dir);
        } else |_| {}
        dir = path.dirname(dir) orelse return null;
    }
}

/// What an env directory would clobber (see `envDirOverlap`).
pub const Overlap = enum {
    /// It is the project directory, or contains it.
    project_dir,
    /// It is ZENV_DIR or contains it, sits directly in it (next to
    /// registry.json), or inside its Python installs.
    zenv_dir,
};

/// Whether the env directory `env_dir` is or holds something that is not the
/// env's own, so that setup would write over it and `zenv rm` would delete
/// it: the project directory, or zenv's global state in `zenv_dir`. An env
/// elsewhere inside ZENV_DIR (e.g. `$ZENV_DIR/envs/<name>`) is fine. Paths
/// are compared with symlinks resolved as far as they exist (macOS
/// /var -> /private/var, a symlinked $HOME). Allocates with `allocator`, an arena.
pub fn envDirOverlap(
    allocator: Allocator,
    io: Io,
    env_dir: []const u8,
    project_dir: []const u8,
    zenv_dir: []const u8,
) !?Overlap {
    const env = try canonical(allocator, io, env_dir);
    if (within(try canonical(allocator, io, project_dir), env)) return .project_dir;
    const zenv = try canonical(allocator, io, zenv_dir);
    if (within(zenv, env)) return .zenv_dir;
    if (std.mem.eql(u8, path.dirname(env) orelse env, zenv)) return .zenv_dir;
    if (within(env, try path.join(allocator, &.{ zenv, "python" }))) return .zenv_dir;
    return null;
}

/// `p` made absolute and normalized, with its longest existing prefix
/// replaced by that prefix's realpath.
fn canonical(allocator: Allocator, io: Io, p: []const u8) ![]const u8 {
    const abs = try path.resolveAlloc(allocator, &.{p});
    var head: []const u8 = abs;
    while (true) {
        if (Io.Dir.cwd().realPathFileAlloc(io, head, allocator)) |real| {
            const rest = std.mem.trimStart(u8, abs[head.len..], "/");
            return if (rest.len == 0) real else path.join(allocator, &.{ real, rest });
        } else |_| {}
        head = path.dirname(head) orelse return abs;
    }
}

/// Whether `child` is `parent` or lies below it (both canonical).
fn within(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    return std.mem.endsWith(u8, parent, "/") or child[parent.len] == '/';
}

// ============================ Tests ============================
const testing = std.testing;

test "venvPath anchors a relative base_dir at the project dir" {
    const a = testing.allocator;
    const p = try venvPath(a, "/proj", "zenv", "test");
    defer a.free(p);
    try testing.expectEqualStrings("/proj/zenv/test", p);
}

test "venvPath leaves an absolute base_dir alone" {
    const a = testing.allocator;
    const p = try venvPath(a, "/proj", "/data/envs", "test");
    defer a.free(p);
    try testing.expectEqualStrings("/data/envs/test", p);
}

test "venvPath normalizes a trailing slash on base_dir" {
    const a = testing.allocator;
    const p = try venvPath(a, "/proj", "zenv/", "test");
    defer a.free(p);
    try testing.expectEqualStrings("/proj/zenv/test", p);
}

test "envDirOverlap refuses the project dir and zenv's own state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const z = "/nonexistent-zenv-test/home/u/.zenv";
    const home = "/nonexistent-zenv-test/home/u";
    // The default layout: <project>/.zenv/<name>.
    try testing.expect(try envDirOverlap(a, io, home ++ "/proj/.zenv/e", home ++ "/proj", z) == null);
    // base_dir "..": the env dir is the project dir; ".." with another name contains it not.
    try testing.expectEqual(Overlap.project_dir, (try envDirOverlap(a, io, home ++ "/proj", home ++ "/proj", z)).?);
    try testing.expectEqual(Overlap.project_dir, (try envDirOverlap(a, io, home, home ++ "/proj", z)).?);
    // From $HOME with the default base_dir: <home>/.zenv/<name>, next to registry.json.
    try testing.expectEqual(Overlap.zenv_dir, (try envDirOverlap(a, io, z ++ "/e", home, z)).?);
    // The env named after ZENV_DIR in its parent.
    try testing.expectEqual(Overlap.zenv_dir, (try envDirOverlap(a, io, z, home ++ "/p", z)).?);
    try testing.expectEqual(Overlap.zenv_dir, (try envDirOverlap(a, io, z ++ "/python/3.12.0", home ++ "/p", z)).?);
    // A dedicated envs dir inside ZENV_DIR is fine, as is a trailing slash.
    try testing.expect(try envDirOverlap(a, io, z ++ "/envs/e", home ++ "/p", z) == null);
    try testing.expectEqual(Overlap.zenv_dir, (try envDirOverlap(a, io, z ++ "/e/", home, z ++ "/")).?);
    // A sibling whose name only starts like the project's.
    try testing.expect(try envDirOverlap(a, io, home ++ "/projx", home ++ "/proj", z) == null);
}

test "findProjectRoot finds the nearest zenv.json at or above start" {
    const a = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const base = try cwd.realPathFileAlloc(io, ".zig-cache", a);
    defer a.free(base);
    const outer = try path.join(a, &.{ base, "tmp", "zenv_paths_test", "outer" });
    defer a.free(outer);
    cwd.deleteTree(io, outer) catch {};
    defer cwd.deleteTree(io, outer) catch {};

    const inner = try path.join(a, &.{ outer, "src", "inner" });
    defer a.free(inner);
    const deep = try path.join(a, &.{ inner, "pkg" });
    defer a.free(deep);
    try cwd.createDirPath(io, deep);

    const outer_cfg = try path.join(a, &.{ outer, "zenv.json" });
    defer a.free(outer_cfg);
    try cwd.writeFile(io, .{ .sub_path = outer_cfg, .data = "{}" });

    const from_deep = (try findProjectRoot(a, io, deep)).?;
    defer a.free(from_deep);
    try testing.expectEqualStrings(outer, from_deep);

    const inner_cfg = try path.join(a, &.{ inner, "zenv.json" });
    defer a.free(inner_cfg);
    try cwd.writeFile(io, .{ .sub_path = inner_cfg, .data = "{}" });

    const nested = (try findProjectRoot(a, io, deep)).?;
    defer a.free(nested);
    try testing.expectEqualStrings(inner, nested);
}
