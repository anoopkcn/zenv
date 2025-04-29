const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

// Create a virtual environment directory structure ({base_dir}/{env_name})
pub fn createVenvDir(allocator: Allocator, base_dir: []const u8, env_name: []const u8) !void {
    if (std.fs.path.isAbsolute(base_dir)) {
        std.log.info("Ensuring absolute virtual environment base directory '{s}' exists...", .{base_dir});
        
        // For absolute paths, create the directory directly
        std.fs.makeDirAbsolute(base_dir) catch |err| {
            if (err == error.PathAlreadyExists) {
                // Ignore this error, directory already exists
            } else {
                return err;
            }
        };
        
        // Create environment-specific directory using absolute path
        const env_dir_path = try std.fs.path.join(allocator, &[_][]const u8{base_dir, env_name});
        defer allocator.free(env_dir_path);
        
        std.log.info("Creating environment directory '{s}'...", .{env_dir_path});
        std.fs.makeDirAbsolute(env_dir_path) catch |err| {
            if (err == error.PathAlreadyExists) {
                // Ignore this error, directory already exists
            } else {
                return err;
            }
        };
    } else {
        std.log.info("Ensuring relative virtual environment base directory '{s}' exists...", .{base_dir});
        
        // For relative paths, create the directory relative to cwd
        try fs.cwd().makePath(base_dir);
        
        // Create environment-specific directory
        const env_dir_path = try std.fs.path.join(allocator, &[_][]const u8{base_dir, env_name});
        defer allocator.free(env_dir_path);
        
        std.log.info("Creating environment directory '{s}'...", .{env_dir_path});
        try fs.cwd().makePath(env_dir_path);
    }
}
