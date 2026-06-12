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
