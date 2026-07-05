//! Process-wide I/O context for Zig 0.16.
//!
//! Zig 0.16 threads an `std.Io` instance through every filesystem, process and
//! environment operation. Rather than thread it as a parameter through every
//! function in the codebase, we set it once from `main` and expose it here,
//! mirroring the existing global-state pattern used by `output.zig`.
//!
//! This module is a leaf: it imports only `std`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

/// The process-wide I/O instance. Set by `main` before any command runs.
pub var io: Io = undefined;

/// The process environment, parsed once by the std bootstrap. Set by `main`.
pub var environ_map: *std.process.Environ.Map = undefined;

/// Looks up an environment variable. Returns a borrowed slice (owned by the
/// environment block, no need to free) or null if unset. Replaces the removed
/// `std.process.getEnvVarOwned`.
pub fn env(name: []const u8) ?[]const u8 {
    return environ_map.get(name);
}

/// Current wall-clock time in milliseconds since the Unix epoch.
/// Replaces the removed `std.time.milliTimestamp`.
pub fn nowMillis() i64 {
    return Io.Clock.now(.real, io).toMilliseconds();
}

// --- Filesystem helpers ------------------------------------------------------
//
// These wrap `std.Io.Dir.cwd()` with the global `io`. Using cwd() works for
// both relative and absolute `path` arguments on the platforms zenv targets
// (macOS, Linux), so a single set of helpers replaces the old relative/absolute
// `std.fs` split.

/// Reads an entire file into a freshly allocated buffer (caller owns it).
/// Replaces `file.readToEndAlloc`.
pub fn readFileAlloc(allocator: Allocator, path: []const u8, max: usize) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, allocator, .limited(max));
}

/// Writes `data` to `path`, creating/truncating the file. Replaces the
/// open+writeAll+close dance for whole-file writes.
pub fn writeFile(path: []const u8, data: []const u8) !void {
    return Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Atomically replaces `path` with `data`: writes a temp file in the same
/// directory, syncs it, then renames it over the target. A crash mid-write
/// can leave a stale temp file behind but never a truncated target. Use for
/// state files (registry.json, zenv.json) where truncate-then-write would
/// risk losing the whole file.
pub fn writeFileAtomic(allocator: Allocator, path: []const u8, data: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.zenv-tmp", .{path});
    defer allocator.free(tmp_path);
    errdefer deleteFile(tmp_path) catch {};

    {
        var file = try createFile(tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, data);
        try file.sync(io);
    }
    try rename(tmp_path, path);
}

/// Recursively creates `path` (idempotent). Replaces `makePath` /
/// `makeDirAbsolute` (with the old PathAlreadyExists handling folded in).
pub fn makePath(path: []const u8) !void {
    return Dir.cwd().createDirPath(io, path);
}

/// Checks that `path` is accessible. Replaces `std.fs.cwd().access`.
pub fn access(path: []const u8) !void {
    return Dir.cwd().access(io, path, .{});
}

/// Deletes a file. Replaces `std.fs.cwd().deleteFile` / `deleteFileAbsolute`.
pub fn deleteFile(path: []const u8) !void {
    return Dir.cwd().deleteFile(io, path);
}

/// Recursively deletes a directory tree. Replaces `deleteTree` /
/// `deleteTreeAbsolute`.
pub fn deleteTree(path: []const u8) !void {
    return Dir.cwd().deleteTree(io, path);
}

/// Renames `old_path` to `new_path` (both relative to cwd, or absolute).
/// Replaces `std.fs.cwd().rename` / `renameAbsolute`.
pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    const cwd = Dir.cwd();
    return cwd.rename(old_path, cwd, new_path, io);
}

/// Opens a file. Caller must `file.close(runtime.io)`.
pub fn openFile(path: []const u8, options: Dir.OpenFileOptions) !File {
    return Dir.cwd().openFile(io, path, options);
}

/// Creates a file. Caller must `file.close(runtime.io)`.
pub fn createFile(path: []const u8, flags: Dir.CreateFileOptions) !File {
    return Dir.cwd().createFile(io, path, flags);
}

/// Opens a directory for iteration. Caller must `dir.close(runtime.io)`.
pub fn openDir(path: []const u8, options: Dir.OpenOptions) !Dir {
    return Dir.cwd().openDir(io, path, options);
}

/// Returns the absolute path of the current working directory (caller owns it).
/// Replaces `std.fs.cwd().realpath(".", &buf)`.
pub fn cwdRealpath(allocator: Allocator) ![]u8 {
    return std.process.currentPathAlloc(io, allocator);
}

/// Returns the canonical absolute path of an existing `path` (caller owns it),
/// resolving symlinks along the way. Errors (e.g. FileNotFound) if the path
/// does not exist. Sentinel-terminated — keep the `[:0]u8` type so
/// `allocator.free` accounts for the trailing byte.
pub fn realpathAlloc(allocator: Allocator, path: []const u8) ![:0]u8 {
    return Dir.cwd().realPathFileAlloc(io, path, allocator);
}

/// Returns the absolute path of the running zenv binary (caller owns it).
/// Follows symlinks. Used to re-invoke `zenv` as a subprocess (auto-setup).
/// Note: `std.fs.selfExePathAlloc` does not exist in Zig 0.16; the API lives
/// on the `std.process`/`Io` seam. The result is sentinel-terminated — keep the
/// `[:0]u8` type so `allocator.free` accounts for the trailing byte.
pub fn selfExePath(allocator: Allocator) ![:0]u8 {
    return std.process.executablePathAlloc(io, allocator);
}

// --- Process execution -------------------------------------------------------
//
// One seam for spawning child processes. Concentrates the stdio/cwd policy and,
// crucially, is swappable: unlike the filesystem (fakeable by pointing `io` at a
// temp dir), an OS process spawn cannot be faked through `io`, so tests install a
// fake `exec_backend` and restore it after. Two adapters — the real one below and
// the test fake — make this a genuine seam rather than mere indirection.

pub const Term = std.process.Child.Term;

/// Result of a captured run. Caller owns `stdout` and `stderr`.
pub const RunResult = struct {
    term: Term,
    stdout: []u8,
    stderr: []u8,
};

pub const RunOptions = struct {
    stdout_limit: Io.Limit = .unlimited,
    stderr_limit: Io.Limit = .unlimited,
    cwd: ?[]const u8 = null,
};

pub const ExecOptions = struct {
    cwd: ?[]const u8 = null,
};

pub const ExecBackend = struct {
    run: *const fn (allocator: Allocator, argv: []const []const u8, opts: RunOptions) anyerror!RunResult,
    exec: *const fn (argv: []const []const u8, opts: ExecOptions) anyerror!Term,
};

/// The active backend. Set once to the real impl; tests swap it and restore.
pub var exec_backend: ExecBackend = .{ .run = realRun, .exec = realExec };

/// Runs `argv` to completion capturing stdout/stderr (caller owns both).
/// Mirrors `std.process.run`. Dispatches through `exec_backend`.
pub fn run(allocator: Allocator, argv: []const []const u8, opts: RunOptions) !RunResult {
    return exec_backend.run(allocator, argv, opts);
}

/// Runs `argv` to completion with inherited stdio, returning the child's `Term`
/// for the caller to interpret (check `.exited`, propagate a signal, etc.).
/// Dispatches through `exec_backend`.
pub fn exec(argv: []const []const u8, opts: ExecOptions) !Term {
    return exec_backend.exec(argv, opts);
}

fn toCwd(cwd: ?[]const u8) std.process.Child.Cwd {
    return if (cwd) |c| .{ .path = c } else .inherit;
}

fn realRun(allocator: Allocator, argv: []const []const u8, opts: RunOptions) anyerror!RunResult {
    const r = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = opts.stdout_limit,
        .stderr_limit = opts.stderr_limit,
        .cwd = toCwd(opts.cwd),
    });
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

fn realExec(argv: []const []const u8, opts: ExecOptions) anyerror!Term {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = toCwd(opts.cwd),
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return child.wait(io);
}
