const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const errors = @import("errors.zig");

/// Validates a path to prevent path traversal attacks and ensure safety.
/// Returns an error if the path contains suspicious elements.
///
/// Params:
///   - path: The path to validate
///
/// Returns: An error if validation fails, void if the path is safe
pub fn validatePath(path: []const u8) !void {
    // Check for path traversal attempts
    if (std.mem.indexOf(u8, path, "..") != null) {
        std.log.err("Path traversal attempt detected in path: '{s}'", .{path});
        return errors.ZenvError.PathTraversalAttempt;
    }
    
    // Check for absolute paths when not expected
    if (std.fs.path.isAbsolute(path)) {
        // Allow common root directories pattern (e.g., /home, /tmp, /usr)
        if (!std.mem.startsWith(u8, path, "/home") and
            !std.mem.startsWith(u8, path, "/tmp") and
            !std.mem.startsWith(u8, path, "/usr")) {
            std.log.warn("Potentially unsafe absolute path: '{s}'", .{path});
            // We'll allow this but warn about it
        }
    }
    
    // Check for empty path
    if (path.len == 0) {
        std.log.err("Empty path provided", .{});
        return errors.ZenvError.IoError;
    }
    
    // Path is valid
    return;
}

/// Joins path components safely, ensures the result is cleaned (no .. or // sequences)
/// and validates the final path.
///
/// Params:
///   - allocator: Memory allocator for temporary allocations
///   - components: Array of path components to join
///
/// Returns: A newly allocated path string, caller owns the memory
pub fn safePathJoin(allocator: Allocator, components: []const []const u8) ![]const u8 {
    // Join the components
    const joined_path = try std.fs.path.join(allocator, components);
    errdefer allocator.free(joined_path);
    
    // Validate the joined path
    try validatePath(joined_path);
    
    return joined_path;
}

// Create a virtual environment directory structure ({base_dir}/{env_name})
pub fn createVenvDir(allocator: Allocator, base_dir: []const u8, env_name: []const u8) !void {
    try validatePath(base_dir);
    try validatePath(env_name);
    
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
        
        // Create environment-specific directory using absolute path and safe path joining
        const env_dir_path = try safePathJoin(allocator, &[_][]const u8{base_dir, env_name});
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
        
        // Create environment-specific directory with safe path joining
        const env_dir_path = try safePathJoin(allocator, &[_][]const u8{base_dir, env_name});
        defer allocator.free(env_dir_path);
        
        std.log.info("Creating environment directory '{s}'...", .{env_dir_path});
        try fs.cwd().makePath(env_dir_path);
    }
}

/// Creates a normalized path from the provided path components.
/// This handles cleaning up path separators, resolving '..' and '.' segments,
/// and ensures consistent representation across platforms.
/// 
/// Params:
///   - allocator: Memory allocator for the result
///   - path: Input path to normalize
///
/// Returns: A newly allocated, normalized path. Caller owns the memory.
pub fn normalizePath(allocator: Allocator, path: []const u8) ![]const u8 {
    // First, resolve and validate the path
    try validatePath(path);
    
    // Handle empty path
    if (path.len == 0) {
        return allocator.dupe(u8, ".");
    }
    
    // Clean up path separators and resolve . and .. segments
    var normalized = std.ArrayList(u8).init(allocator);
    defer normalized.deinit();
    
    // If it's an absolute path, start with root
    if (std.fs.path.isAbsolute(path)) {
        try normalized.append('/');
    }
    
    var path_segments = std.mem.split(u8, path, "/\\");
    var segments = std.ArrayList([]const u8).init(allocator);
    defer segments.deinit();
    
    // Skip empty segments, handle . and ..
    while (path_segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            continue; // Skip empty segments and current directory
        } else if (std.mem.eql(u8, segment, "..")) {
            // Remove last segment if possible (parent directory)
            if (segments.items.len > 0 and !std.mem.eql(u8, segments.items[segments.items.len - 1], "..")) {
                _ = segments.pop();
            } else if (!std.fs.path.isAbsolute(path)) {
                // If relative path, keep .. segments
                try segments.append("..");
            }
            // If absolute path, just skip .. (can't go above root)
        } else {
            try segments.append(segment);
        }
    }
    
    // Rebuild the path
    for (segments.items, 0..) |segment, i| {
        if (i > 0) try normalized.append('/');
        try normalized.appendSlice(segment);
    }
    
    // If nothing left, return "." or "/" for absolute paths
    if (normalized.items.len == 0) {
        try normalized.append('.');
    } else if (normalized.items.len == 1 and normalized.items[0] == '/') {
        return allocator.dupe(u8, "/");
    }
    
    return normalized.toOwnedSlice();
}
