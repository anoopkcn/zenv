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
    for ([_][]const u8{ "", ".", "..", "a b", "a/b", "../x", "x\n" }) |bad| try std.testing.expect(!isValidEnvName(bad));
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

/// True when `base_dir`, resolved against `project_dir` the way `venvPath`
/// resolves it (a relative base_dir is anchored at project_dir), refers to the
/// same directory as `zenv_dir` — the global ZENV_DIR holding registry.json,
/// the python installs and default-python. Creating an environment there would
/// overwrite global state — e.g. `zenv setup` run from $HOME with the default
/// base_dir `.zenv` and ZENV_DIR unset (which defaults to $HOME/.zenv).
///
/// Compares on normalized absolute paths first, then falls back to realpath
/// identity when both directories exist on disk, so symlinked roots (e.g. macOS
/// /var -> /private/var, or a symlinked $HOME) still compare equal. No
/// allocations escape.
pub fn baseDirIsZenvDir(
    allocator: Allocator,
    io: Io,
    project_dir: []const u8,
    base_dir: []const u8,
    zenv_dir: []const u8,
) !bool {
    // resolveAlloc restarts at an absolute base_dir, dropping project_dir.
    const base_abs = try path.resolveAlloc(allocator, &.{ project_dir, base_dir });
    defer allocator.free(base_abs);

    const zenv_abs = try path.resolveAlloc(allocator, &.{zenv_dir});
    defer allocator.free(zenv_abs);

    if (std.mem.eql(u8, base_abs, zenv_abs)) return true;

    // Lexically different paths can still be the same directory through a
    // symlink. Compare realpaths when both exist; if either is missing there is
    // nothing to overwrite, so treat them as distinct.
    const cwd = Io.Dir.cwd();
    const base_real = cwd.realPathFileAlloc(io, base_abs, allocator) catch return false;
    defer allocator.free(base_real);
    const zenv_real = cwd.realPathFileAlloc(io, zenv_abs, allocator) catch return false;
    defer allocator.free(zenv_real);

    return std.mem.eql(u8, base_real, zenv_real);
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

test "baseDirIsZenvDir flags the default base_dir in the zenv home" {
    try testing.expect(try baseDirIsZenvDir(testing.allocator, testing.io, "/home/u", ".zenv", "/home/u/.zenv"));
}

test "baseDirIsZenvDir allows a project elsewhere" {
    try testing.expect(!try baseDirIsZenvDir(testing.allocator, testing.io, "/home/u/proj", ".zenv", "/home/u/.zenv"));
}

test "baseDirIsZenvDir flags an absolute base_dir pointing at the zenv home" {
    try testing.expect(try baseDirIsZenvDir(testing.allocator, testing.io, "/home/u/proj", "/home/u/.zenv", "/home/u/.zenv"));
}

test "baseDirIsZenvDir allows a custom base_dir name in the home dir" {
    try testing.expect(!try baseDirIsZenvDir(testing.allocator, testing.io, "/home/u", "venvs", "/home/u/.zenv"));
}

test "baseDirIsZenvDir ignores a trailing slash on base_dir" {
    try testing.expect(try baseDirIsZenvDir(testing.allocator, testing.io, "/home/u", ".zenv/", "/home/u/.zenv"));
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
