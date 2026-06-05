const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.Io.File;
const runtime = @import("runtime.zig");

// Global state for logging
var log_file: ?File = null;
var log_enabled: bool = false;

/// When true, all stdout/stderr writes are skipped. Tests set this so logging
/// does not corrupt the `zig build test` runner's stdout protocol. Off (and
/// zero-cost) in normal runs.
pub var silent: bool = false;

/// Starts logging to the specified file path
/// If the file exists, it will be appended to
pub fn startLogging(allocator: Allocator, path: []const u8) !void {
    if (log_enabled) {
        stopLogging();
    }

    const dir_path = std.fs.path.dirname(path) orelse ".";
    runtime.makePath(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    log_file = try runtime.createFile(path, .{ .truncate = false, .read = true });
    log_enabled = true;

    try print(allocator, "Logging started: output will be saved to {s}", .{path});
}

/// Stops logging and closes the log file if open
pub fn stopLogging() void {
    if (log_file) |*file| {
        file.close(runtime.io);
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
        try log_file.?.writeStreamingAll(runtime.io, message);
    }
}

/// Writes `message` to the given standard stream and flushes it.
fn writeStd(file: File, message: []const u8) !void {
    if (silent) return;
    var buf: [512]u8 = undefined;
    var fw = file.writerStreaming(runtime.io, &buf);
    const w = &fw.interface;
    try w.writeAll(message);
    try w.flush();
}

/// Writes formatted text to stdout verbatim (no "Info:" prefix, no newline,
/// no logging). For data output meant to be captured by a shell, e.g.
/// `source $(zenv activate ...)`.
pub fn rawOut(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch try std.fmt.allocPrint(allocator, fmt, args);
    defer if (msg.ptr != &buf) allocator.free(msg);
    try writeStd(File.stdout(), msg);
}

/// Like `rawOut` but writes to stderr.
pub fn rawErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch try std.fmt.allocPrint(allocator, fmt, args);
    defer if (msg.ptr != &buf) allocator.free(msg);
    try writeStd(File.stderr(), msg);
}

pub fn print(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const message = if (fmt.len + 50 < buf.len) blk: {
        // Use stack buffer for small messages
        break :blk try std.fmt.bufPrint(&buf, "INFO: " ++ fmt ++ "\n", args);
    } else {
        // Use allocator for larger messages
        try std.fmt.allocPrint(allocator, "INFO: " ++ fmt ++ "\n", args);
    };
    defer if (message.ptr != &buf) allocator.free(message);

    try writeStd(File.stdout(), message);
    try logMessage(message);
}

/// Prints a formatted error message to stderr with a newline appended
pub fn printError(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const message = if (fmt.len + 50 < buf.len) blk: {
        // Use stack buffer for small messages
        break :blk try std.fmt.bufPrint(&buf, "ERROR: " ++ fmt ++ "\n", args);
    } else {
        // Use allocator for larger messages
        try std.fmt.allocPrint(allocator, "ERROR: " ++ fmt ++ "\n", args);
    };
    defer if (message.ptr != &buf) allocator.free(message);

    try writeStd(File.stderr(), message);
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

    try writeStd(File.stdout(), message);
    try logMessage(message);
}
