const std = @import("std");
const Allocator = std.mem.Allocator;

/// Prints a formatted message to stdout with a newline appended
/// Use this instead of std.log.info for user-visible output
pub fn print(comptime fmt: []const u8, args: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("info: " ++ fmt ++ "\n", args);
}

/// Prints a formatted error message to stderr with a newline appended
pub fn printError(comptime fmt: []const u8, args: anytype) !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("error: " ++  fmt ++ "\n", args);
}

/// Prints a formatted message to stdout, and doesn't append a newline
pub fn printNoNewline(comptime fmt: []const u8, args: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(fmt, args);
}
