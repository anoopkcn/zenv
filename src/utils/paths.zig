const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("output.zig");
const runtime = @import("runtime.zig");

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

/// The zenv directory: $ZENV_DIR if set, otherwise ~/.zenv.
pub fn getZenvDir(allocator: Allocator) ![]const u8 {
    // Try to get ZENV_DIR environment variable
    if (runtime.env("ZENV_DIR")) |zenv_dir| {
        return allocator.dupe(u8, zenv_dir);
    }

    // Fallback to home directory
    const home_dir = runtime.env("HOME") orelse {
        output.printError(allocator, "Failed to get HOME environment variable", .{}) catch {};
        return error.HomeDirectoryNotFound;
    };

    return std.Io.Dir.path.join(allocator, &[_][]const u8{ home_dir, ".zenv" });
}

/// `<zenv dir>/<name>`. Caller owns the result.
pub fn zenvPath(allocator: Allocator, name: []const u8) ![]const u8 {
    const dir = try getZenvDir(allocator);
    defer allocator.free(dir);
    return std.Io.Dir.path.join(allocator, &[_][]const u8{ dir, name });
}

/// Like `zenvPath`, creating the zenv directory first.
pub fn ensureZenvPath(allocator: Allocator, name: []const u8) ![]const u8 {
    const dir = try getZenvDir(allocator);
    defer allocator.free(dir);
    runtime.makePath(dir) catch |err| {
        output.printError(allocator, "Failed to create zenv directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    return std.Io.Dir.path.join(allocator, &[_][]const u8{ dir, name });
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
    if (std.Io.Dir.path.isAbsolute(base_dir)) {
        return std.Io.Dir.path.join(allocator, &[_][]const u8{ base_dir, env_name });
    }
    return std.Io.Dir.path.join(allocator, &[_][]const u8{ project_dir, base_dir, env_name });
}

/// Resolves a config-relative path against `anchor_dir`; absolute paths are
/// left untouched. Caller owns the result.
pub fn resolvePath(allocator: Allocator, anchor_dir: []const u8, rel: []const u8) ![]u8 {
    if (std.Io.Dir.path.isAbsolute(rel)) return allocator.dupe(u8, rel);
    return std.Io.Dir.path.join(allocator, &[_][]const u8{ anchor_dir, rel });
}

/// The nearest directory at or above `start` (an absolute path) that holds a
/// zenv.json, or null if none does. Caller owns the result. The nearest file
/// wins even if its project has no registered environment, matching how
/// direnv treats .envrc: a nested project shadows the one around it.
pub fn findProjectRoot(allocator: Allocator, start: []const u8) !?[]u8 {
    var dir: []const u8 = start;
    while (true) {
        const candidate = try std.Io.Dir.path.join(allocator, &[_][]const u8{ dir, "zenv.json" });
        defer allocator.free(candidate);
        if (runtime.access(candidate)) |_| {
            return try allocator.dupe(u8, dir);
        } else |_| {}
        dir = std.Io.Dir.path.dirname(dir) orelse return null;
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
    project_dir: []const u8,
    base_dir: []const u8,
    zenv_dir: []const u8,
) !bool {
    // resolve restarts at an absolute base_dir, dropping project_dir.
    const base_abs = try std.Io.Dir.path.resolve(allocator, &[_][]const u8{ project_dir, base_dir });
    defer allocator.free(base_abs);

    const zenv_abs = try std.Io.Dir.path.resolve(allocator, &[_][]const u8{zenv_dir});
    defer allocator.free(zenv_abs);

    if (std.mem.eql(u8, base_abs, zenv_abs)) return true;

    // Lexically different paths can still be the same directory through a
    // symlink. Compare realpaths when both exist; if either is missing there is
    // nothing to overwrite, so treat them as distinct.
    const base_real = runtime.realpathAlloc(allocator, base_abs) catch return false;
    defer allocator.free(base_real);
    const zenv_real = runtime.realpathAlloc(allocator, zenv_abs) catch return false;
    defer allocator.free(zenv_real);

    return std.mem.eql(u8, base_real, zenv_real);
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");

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
    test_support.setupRuntime();
    const a = testing.allocator;
    try testing.expect(try baseDirIsZenvDir(a, "/home/u", ".zenv", "/home/u/.zenv"));
}

test "baseDirIsZenvDir allows a project elsewhere" {
    test_support.setupRuntime();
    const a = testing.allocator;
    try testing.expect(!try baseDirIsZenvDir(a, "/home/u/proj", ".zenv", "/home/u/.zenv"));
}

test "baseDirIsZenvDir flags an absolute base_dir pointing at the zenv home" {
    test_support.setupRuntime();
    const a = testing.allocator;
    try testing.expect(try baseDirIsZenvDir(a, "/home/u/proj", "/home/u/.zenv", "/home/u/.zenv"));
}

test "baseDirIsZenvDir allows a custom base_dir name in the home dir" {
    test_support.setupRuntime();
    const a = testing.allocator;
    try testing.expect(!try baseDirIsZenvDir(a, "/home/u", "venvs", "/home/u/.zenv"));
}

test "baseDirIsZenvDir ignores a trailing slash on base_dir" {
    test_support.setupRuntime();
    const a = testing.allocator;
    try testing.expect(try baseDirIsZenvDir(a, "/home/u", ".zenv/", "/home/u/.zenv"));
}

test "findProjectRoot finds the nearest zenv.json at or above start" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const base = try std.Io.Dir.path.join(a, &[_][]const u8{ runtime.env("TMPDIR") orelse "/tmp", "zenv_paths_test" });
    defer a.free(base);
    runtime.deleteTree(base) catch {};
    defer runtime.deleteTree(base) catch {};

    const outer = try std.Io.Dir.path.join(a, &[_][]const u8{ base, "outer" });
    defer a.free(outer);
    const inner = try std.Io.Dir.path.join(a, &[_][]const u8{ outer, "src", "inner" });
    defer a.free(inner);
    const deep = try std.Io.Dir.path.join(a, &[_][]const u8{ inner, "pkg" });
    defer a.free(deep);
    try runtime.makePath(deep);

    const outer_cfg = try std.Io.Dir.path.join(a, &[_][]const u8{ outer, "zenv.json" });
    defer a.free(outer_cfg);
    try runtime.writeFile(outer_cfg, "{}");

    const from_deep = (try findProjectRoot(a, deep)).?;
    defer a.free(from_deep);
    try testing.expectEqualStrings(outer, from_deep);

    const inner_cfg = try std.Io.Dir.path.join(a, &[_][]const u8{ inner, "zenv.json" });
    defer a.free(inner_cfg);
    try runtime.writeFile(inner_cfg, "{}");

    const nested = (try findProjectRoot(a, deep)).?;
    defer a.free(nested);
    try testing.expectEqualStrings(inner, nested);
}
