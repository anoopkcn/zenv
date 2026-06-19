const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("output.zig");
const runtime = @import("runtime.zig");

// Gets the zenv directory path, respecting ZENV_DIR environment variable
// if set, otherwise uses ~/.zenv
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

    return std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".zenv" });
}

// Creates the zenv directory if it doesn't exist
pub fn ensureZenvDir(allocator: Allocator) ![]const u8 {
    const zenv_dir_path = try getZenvDir(allocator);
    errdefer allocator.free(zenv_dir_path);

    runtime.makePath(zenv_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            output.printError(allocator, "Failed to create zenv directory: {s}", .{@errorName(err)}) catch {};
            return err;
        }
    };

    return zenv_dir_path;
}

// Gets the path to the registry.json file
pub fn getRegistryPath(allocator: Allocator) ![]const u8 {
    const zenv_dir_path = try getZenvDir(allocator);
    defer allocator.free(zenv_dir_path);

    return std.fs.path.join(allocator, &[_][]const u8{ zenv_dir_path, "registry.json" });
}

// Gets the path to the default-python file
pub fn getDefaultPythonFilePath(allocator: Allocator) ![]const u8 {
    const zenv_dir_path = try getZenvDir(allocator);
    defer allocator.free(zenv_dir_path);

    return std.fs.path.join(allocator, &[_][]const u8{ zenv_dir_path, "default-python" });
}

// Gets the default python installation directory
pub fn getPythonInstallDir(allocator: Allocator) ![]const u8 {
    const zenv_dir_path = try getZenvDir(allocator);
    defer allocator.free(zenv_dir_path);

    return std.fs.path.join(allocator, &[_][]const u8{ zenv_dir_path, "python" });
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
    if (std.fs.path.isAbsolute(base_dir)) {
        return std.fs.path.join(allocator, &[_][]const u8{ base_dir, env_name });
    }
    return std.fs.path.join(allocator, &[_][]const u8{ project_dir, base_dir, env_name });
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
    const base_abs = if (std.fs.path.isAbsolute(base_dir))
        try std.fs.path.resolve(allocator, &[_][]const u8{base_dir})
    else
        try std.fs.path.resolve(allocator, &[_][]const u8{ project_dir, base_dir });
    defer allocator.free(base_abs);

    const zenv_abs = try std.fs.path.resolve(allocator, &[_][]const u8{zenv_dir});
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
