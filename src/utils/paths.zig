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
