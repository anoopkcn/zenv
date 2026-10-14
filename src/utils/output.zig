//! Messages for the user: INFO/WARNING/ERROR lines, raw stdout/stderr text,
//! debug output, and the setup log that mirrors them. Like `std.debug.print`,
//! the functions format straight into a buffered writer (no allocation) and
//! ignore write errors: a message that cannot be shown is not a reason to fail
//! the command.

const std = @import("std");
const Io = std.Io;
const File = Io.File;

/// The setup log, when logging is on (see startLogging).
var log_file: ?File = null;

/// When true, all stdout/stderr writes are skipped, so tests do not corrupt
/// the `zig build test` runner's stdout protocol. The setup log still works.
pub var silent: bool = @import("builtin").is_test;

/// Whether `debug` prints. `main` turns it on for ZENV_DEBUG=1|true|yes.
pub var debug_enabled: bool = false;

/// Starts logging to `path`, appending to an existing log.
pub fn startLogging(io: Io, path: []const u8) !void {
    stopLogging(io);
    const cwd = Io.Dir.cwd();
    if (Io.Dir.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    log_file = try cwd.createFile(io, path, .{ .truncate = false });
    print(io, "Logging started: output will be saved to {s}", .{path});
}

/// Stops logging and closes the log file if open.
pub fn stopLogging(io: Io) void {
    if (log_file) |file| {
        file.close(io);
        log_file = null;
    }
}

/// Formats to `file` (stdout or stderr) and, when `log`, to the setup log.
/// Log writes go to the file's current end rather than a remembered position:
/// a re-run appends to the previous log, and anything else appending to it
/// meanwhile (a setup hook redirecting into it) must not be overwritten.
fn emit(io: Io, file: File, comptime fmt: []const u8, args: anytype, log: bool) void {
    var buf: [4096]u8 = undefined;
    if (!silent) {
        var w = file.writerStreaming(io, &buf);
        w.interface.print(fmt, args) catch {};
        w.interface.flush() catch {};
    }
    if (!log) return;
    const lf = log_file orelse return;
    var w = lf.writer(io, &buf);
    w.seekTo(lf.length(io) catch return) catch return;
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

/// Writes formatted text to stdout verbatim (no prefix, no newline, not
/// logged): data for a shell to capture, e.g. `source $(zenv activate ...)`.
pub fn rawOut(io: Io, comptime fmt: []const u8, args: anytype) void {
    emit(io, File.stdout(), fmt, args, false);
}

/// Like `rawOut` but writes to stderr.
pub fn rawErr(io: Io, comptime fmt: []const u8, args: anytype) void {
    emit(io, File.stderr(), fmt, args, false);
}

/// Prints an "INFO:" line to stdout (and the log).
pub fn print(io: Io, comptime fmt: []const u8, args: anytype) void {
    emit(io, File.stdout(), "INFO: " ++ fmt ++ "\n", args, true);
}

/// Prints a "WARNING:" line to stderr (and the log).
pub fn printWarning(io: Io, comptime fmt: []const u8, args: anytype) void {
    emit(io, File.stderr(), "WARNING: " ++ fmt ++ "\n", args, true);
}

/// Prints an "ERROR:" line to stderr (and the log).
pub fn printError(io: Io, comptime fmt: []const u8, args: anytype) void {
    emit(io, File.stderr(), "ERROR: " ++ fmt ++ "\n", args, true);
}

/// Copies a child process's output verbatim to stdout and the log, as the
/// old setup script did with `tee`.
pub fn passthrough(io: Io, bytes: []const u8) void {
    emit(io, File.stdout(), "{s}", .{bytes}, true);
}

/// A "DEBUG:" line on stderr when `debug_enabled`. Not `std.log.debug`, which
/// release builds compile out.
pub fn debug(io: Io, comptime fmt: []const u8, args: anytype) void {
    if (debug_enabled) emit(io, File.stderr(), "DEBUG: " ++ fmt ++ "\n", args, false);
}

// ============================ Tests ============================

const testing = std.testing;

test "logging appends to an existing log and never overwrites other writers" {
    const io = testing.io;
    const a = testing.allocator;
    const cwd = Io.Dir.cwd();
    const dir = ".zig-cache/tmp/zenv-output-log-test";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    const path = dir ++ "/zenv_setup.log";

    const previous = "previous run: a line long enough to outlive a short overwrite\n";
    try cwd.writeFile(io, .{ .sub_path = path, .data = previous });

    try startLogging(io, path);
    print(io, "second run", .{});

    // Another process appends while zenv holds the log open; zenv's next
    // message must land after it, not on top of it.
    {
        var other = try cwd.openFile(io, path, .{ .mode = .read_write });
        defer other.close(io);
        try other.writePositionalAll(io, "script output\n", try other.length(io));
    }
    print(io, "after script", .{});
    stopLogging(io);

    const content = try cwd.readFileAlloc(io, path, a, .limited(1024 * 1024));
    defer a.free(content);
    try testing.expectStringStartsWith(content, previous);
    const tail = content[previous.len..];
    const expected_tail = "INFO: Logging started: output will be saved to " ++ path ++ "\n" ++
        "INFO: second run\n" ++ "script output\n" ++ "INFO: after script\n";
    try testing.expectEqualStrings(expected_tail, tail);
}
