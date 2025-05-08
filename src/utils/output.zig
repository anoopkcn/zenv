const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

// Global state for logging
var log_file: ?fs.File = null;
var log_enabled: bool = false;

/// Starts logging to the specified file path
/// If the file exists, it will be appended to
pub fn startLogging(path: []const u8) !void {
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

    try print("Logging started: output will be saved to {s}", .{path});
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

/// Prints a formatted message to stdout with a newline appended
/// Use this instead of std.log.info for user-visible output
pub fn print(comptime fmt: []const u8, args: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    const message = try std.fmt.allocPrint(std.heap.page_allocator, "Info: " ++ fmt ++ "\n", args);
    defer std.heap.page_allocator.free(message);

    try stdout.writeAll(message);
    try logMessage(message);
}

/// Prints a formatted error message to stderr with a newline appended
pub fn printError(comptime fmt: []const u8, args: anytype) !void {
    const stderr = std.io.getStdErr().writer();
    const message = try std.fmt.allocPrint(std.heap.page_allocator, "Error: " ++ fmt ++ "\n", args);
    defer std.heap.page_allocator.free(message);

    try stderr.writeAll(message);
    try logMessage(message);
}

/// Prints a formatted message to stdout, and doesn't append a newline
pub fn printNoNewline(comptime fmt: []const u8, args: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    const message = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(message);

    try stdout.writeAll(message);
    try logMessage(message);
}
