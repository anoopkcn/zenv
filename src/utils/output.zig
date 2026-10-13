const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.Io.File;
const runtime = @import("runtime.zig");

/// The setup log, when logging is on (see startLogging).
var log_file: ?File = null;

/// When true, all stdout/stderr writes are skipped. Tests set this so logging
/// does not corrupt the `zig build test` runner's stdout protocol. Off (and
/// zero-cost) in normal runs.
pub var silent: bool = false;

/// Starts logging to the specified file path
/// If the file exists, it will be appended to
pub fn startLogging(allocator: Allocator, path: []const u8) !void {
    stopLogging();

    const dir_path = std.Io.Dir.path.dirname(path) orelse ".";
    try runtime.makePath(dir_path);

    log_file = try runtime.createFile(path, .{ .truncate = false, .read = true });

    try print(allocator, "Logging started: output will be saved to {s}", .{path});
}

/// Stops logging and closes the log file if open
pub fn stopLogging() void {
    if (log_file) |*file| {
        file.close(runtime.io);
        log_file = null;
    }
}

/// Appends a message to the log file if logging is enabled. Writes go to the
/// file's current end rather than a remembered position: the setup shell script
/// appends to the same log (`>>`) while zenv holds it open, and a re-run must
/// add to the previous log, so any cached offset would overwrite real output.
fn logMessage(message: []const u8) !void {
    const file = log_file orelse return;
    try file.writePositionalAll(runtime.io, message, try file.length(runtime.io));
}

/// Writes `message` to the given standard stream.
fn writeStd(file: File, message: []const u8) !void {
    if (silent) return;
    try file.writeStreamingAll(runtime.io, message);
}

/// Formats into a stack buffer, falling back to the heap when the *formatted*
/// output doesn't fit (a long argument such as a venv path), then writes it to
/// `file` and, when `log`, to the setup log.
fn emit(allocator: Allocator, file: File, comptime fmt: []const u8, args: anytype, log: bool) !void {
    var buf: [1024]u8 = undefined;
    const message = std.mem.print(&buf, fmt, args) catch try allocator.print(fmt, args);
    defer if (message.ptr != &buf) allocator.free(message);
    try writeStd(file, message);
    if (log) try logMessage(message);
}

/// Writes formatted text to stdout verbatim (no "Info:" prefix, no newline,
/// no logging). For data output meant to be captured by a shell, e.g.
/// `source $(zenv activate ...)`.
pub fn rawOut(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    return emit(allocator, File.stdout(), fmt, args, false);
}

/// Like `rawOut` but writes to stderr.
pub fn rawErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    return emit(allocator, File.stderr(), fmt, args, false);
}

/// Prints a formatted "INFO:" line to stdout (and the log).
pub fn print(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    return emit(allocator, File.stdout(), "INFO: " ++ fmt ++ "\n", args, true);
}

/// Prints a formatted warning to stderr (and the log) with a newline appended.
pub fn printWarning(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    return emit(allocator, File.stderr(), "WARNING: " ++ fmt ++ "\n", args, true);
}

/// Copies a child process's output verbatim to stdout and the log. Used by
/// setup to tee installer output, as the old setup script did with `tee`.
pub fn passthrough(bytes: []const u8) !void {
    try writeStd(File.stdout(), bytes);
    try logMessage(bytes);
}

/// Prints a formatted error message to stderr (and the log) with a newline appended
pub fn printError(allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    return emit(allocator, File.stderr(), "ERROR: " ++ fmt ++ "\n", args, true);
}

// ============================ Tests ============================

const testing = std.testing;
const test_support = @import("../test_support.zig");

test "logging appends to an existing log and never overwrites other writers" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const dir = ".zig-cache/tmp/zenv-output-log-test";
    runtime.deleteTree(dir) catch {};
    defer runtime.deleteTree(dir) catch {};
    try runtime.makePath(dir);
    const path = dir ++ "/zenv_setup.log";

    const previous = "previous run: a line long enough to outlive a short overwrite\n";
    try runtime.writeFile(path, previous);

    try startLogging(a, path);
    try print(a, "second run", .{});

    // Another process (the setup script, via `>>`) appends while zenv holds
    // the log open; zenv's next message must land after it, not on top of it.
    {
        var other = try runtime.openFile(path, .{ .mode = .read_write });
        defer other.close(runtime.io);
        try other.writePositionalAll(runtime.io, "script output\n", try other.length(runtime.io));
    }
    try print(a, "after script", .{});
    stopLogging();

    const content = try runtime.readFileAlloc(a, path, 1024 * 1024);
    defer a.free(content);
    try testing.expect(std.mem.startsWith(u8, content, previous));
    const tail = content[previous.len..];
    const expected_tail = "INFO: Logging started: output will be saved to " ++ path ++ "\n" ++
        "INFO: second run\n" ++ "script output\n" ++ "INFO: after script\n";
    try testing.expectEqualStrings(expected_tail, tail);
}
