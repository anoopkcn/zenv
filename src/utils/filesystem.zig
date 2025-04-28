const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

// Create a virtual environment directory structure ({base_dir}/{env_name})
pub fn createVenvDir(allocator: Allocator, base_dir: []const u8, env_name: []const u8) !void {
    std.log.info("Ensuring virtual environment base directory '{s}' exists...", .{base_dir});

    // Create base directory if it doesn't exist
    try fs.cwd().makePath(base_dir);

    // Create environment-specific directory
    const env_dir_path = try std.fs.path.join(allocator, &[_][]const u8{base_dir, env_name});
    defer allocator.free(env_dir_path);

    std.log.info("Creating environment directory '{s}'...", .{env_dir_path});
    try fs.cwd().makePath(env_dir_path);
}
