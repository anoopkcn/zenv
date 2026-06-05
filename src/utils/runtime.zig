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
