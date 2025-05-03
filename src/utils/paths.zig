const std = @import("std");
const Allocator = std.mem.Allocator;
const process = std.process;
const fs = std.fs;

// Gets the zenv directory path, respecting ZENV_DIR environment variable
// if set, otherwise uses ~/.zenv
pub fn getZenvDir(allocator: Allocator) ![]const u8 {
    // Try to get ZENV_DIR environment variable
    const zenv_dir = process.getEnvVarOwned(allocator, "ZENV_DIR") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            // Fallback to home directory
            const home_dir = process.getEnvVarOwned(allocator, "HOME") catch |home_err| {
                std.log.err("Failed to get HOME environment variable: {s}", .{@errorName(home_err)});
                return error.HomeDirectoryNotFound;
            };
            defer allocator.free(home_dir);
            
            return std.fs.path.join(allocator, &[_][]const u8{home_dir, ".zenv"});
        }
        std.log.err("Failed to get ZENV_DIR environment variable: {s}", .{@errorName(err)});
        return err;
    };
    
    return zenv_dir;
}

// Creates the zenv directory if it doesn't exist
pub fn ensureZenvDir(allocator: Allocator) ![]const u8 {
    const zenv_dir_path = try getZenvDir(allocator);
    errdefer allocator.free(zenv_dir_path);
    
    fs.makeDirAbsolute(zenv_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.err("Failed to create zenv directory: {s}", .{@errorName(err)});
            return err;
        }
    };
    
    return zenv_dir_path;
}

// Gets the path to the registry.json file
pub fn getRegistryPath(allocator: Allocator) ![]const u8 {
    const zenv_dir_path = try getZenvDir(allocator);
    defer allocator.free(zenv_dir_path);
    
    return std.fs.path.join(allocator, &[_][]const u8{zenv_dir_path, "registry.json"});
}

// Gets the path to the default-python file
pub fn getDefaultPythonFilePath(allocator: Allocator) ![]const u8 {
    const zenv_dir_path = try getZenvDir(allocator);
    defer allocator.free(zenv_dir_path);
    
    return std.fs.path.join(allocator, &[_][]const u8{zenv_dir_path, "default-python"});
}

// Gets the default python installation directory
pub fn getPythonInstallDir(allocator: Allocator) ![]const u8 {
    const zenv_dir_path = try getZenvDir(allocator);
    defer allocator.free(zenv_dir_path);
    
    return std.fs.path.join(allocator, &[_][]const u8{zenv_dir_path, "python"});
}