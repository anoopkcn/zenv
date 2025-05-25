const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

// Global state for logging
var log_file: ?fs.File = null;
var log_enabled: bool = false;

/// Starts logging to the specified file path
/// If the file exists, it will be appended to
pub fn startLogging(allocator: Allocator, path: []const u8) !void {
    if (log_enabled) {
        stopLogging();
    }

    const dir_path = std.fs.path.dirname(path) orelse ".";
    std.fs.cwd().makePath(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    log_file = try fs.cwd().createFile(path, .{ .truncate = false, .read = true });
    log_enabled = true;

    try print(allocator, "Logging started: output will be saved to {s}", .{path});
}

/// Stops logging and closes the log file if open
pub fn stopLogging() void {
    if (log_file) |*file| {
        file.close();
        log_file = null;
        log_enabled = false;
    }
}

/// Returns whether logging is currently enabled
pub fn isLoggingEnabled() bool {
    return log_enabled;
}

/// Writes a message to the log file if logging is enabled
fn logMessage(message: []const u8) !void {
    if (log_enabled and log_file != null) {
        try log_file.?.writeAll(message);
    }
}

pub fn print(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const message = if (fmt.len + 50 < buf.len) blk: {
        // Use stack buffer for small messages
        break :blk try std.fmt.bufPrint(&buf, "Info: " ++ fmt ++ "\n", args);
    } else {
        // Use allocator for larger messages
        try std.fmt.allocPrint(allocator, "Info: " ++ fmt ++ "\n", args);
    };
    defer if (message.ptr != &buf) allocator.free(message);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(message);
    try logMessage(message);
}

/// Prints a formatted error message to stderr with a newline appended
pub fn printError(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const message = if (fmt.len + 50 < buf.len) blk: {
        // Use stack buffer for small messages
        break :blk try std.fmt.bufPrint(&buf, "Error: " ++ fmt ++ "\n", args);
    } else {
        // Use allocator for larger messages
        try std.fmt.allocPrint(allocator, "Error: " ++ fmt ++ "\n", args);
    };
    defer if (message.ptr != &buf) allocator.free(message);

    const stderr = std.io.getStdErr().writer();
    try stderr.writeAll(message);
    try logMessage(message);
}

/// Prints a formatted message to stdout, and doesn't append a newline
pub fn printNoNewline(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const message = if (fmt.len + 50 < buf.len) blk: {
        // Use stack buffer for small messages
        break :blk try std.fmt.bufPrint(&buf, fmt, args);
    } else {
        // Use allocator for larger messages
        try std.fmt.allocPrint(allocator, fmt, args);
    };
    defer if (message.ptr != &buf) allocator.free(message);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(message);
    try logMessage(message);
}
