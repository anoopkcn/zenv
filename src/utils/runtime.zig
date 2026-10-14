//! What zenv takes from the process, and the one seam for running programs.
//!
//! `main` builds a `Ctx` once and passes it down: the I/O implementation and
//! the environment are parameters, not globals, as Zig 0.16+ intends. Leaf
//! helpers take just the `io` (or the values) they need.
//!
//! This module is a leaf: it imports only `std`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const Environ = std.process.Environ;

/// What a command needs from the process.
pub const Ctx = struct {
    /// The process arena: everything allocated from it lives until zenv exits.
    arena: Allocator,
    io: Io,
    /// zenv's own environment.
    env: *const Environ.Map,

    /// The value of environment variable `name`, or null if unset.
    pub fn getEnv(ctx: Ctx, name: []const u8) ?[]const u8 {
        return ctx.env.get(name);
    }
};

pub const WriteOptions = struct {
    permissions: Io.File.Permissions = .default_file,
};

/// Atomically replaces `path` with `data`: a temp file in the same directory
/// is written, synced, then renamed over the target, so a crash leaves the old
/// file or the new one, never a truncated one. std's temp names are random and
/// created exclusively, so concurrent writers (other zenv processes, other
/// nodes of a shared filesystem) cannot collide.
pub fn writeFileAtomic(io: Io, path: []const u8, data: []const u8, options: WriteOptions) !void {
    var file = try Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .permissions = options.permissions });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, data);
    try file.file.sync(io);
    try file.replace(io);
}

/// Atomically replaces `path` with `value` as 2-space-indented JSON (see
/// `writeFileAtomic`), streamed into the file; `newline` ends it with '\n'.
pub fn writeJsonAtomic(io: Io, path: []const u8, value: anytype, newline: bool) !void {
    var file = try Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    var buf: [4096]u8 = undefined;
    var w = file.file.writer(io, &buf);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &w.interface);
    if (newline) try w.interface.writeByte('\n');
    try w.interface.flush();
    try file.file.sync(io);
    try file.replace(io);
}

/// Whether `path` itself exists; a dangling symlink counts.
pub fn lexists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// Whether `path` is accessible (following symlinks).
pub fn exists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Whether `path` is a regular file (following symlinks).
pub fn isFile(io: Io, path: []const u8) bool {
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// The kind of directory entry `entry` of `dir`, a symlink's target's kind
/// when `options` follow symlinks. Some filesystems do not report kinds while
/// iterating; std then says `.unknown` and this asks the filesystem.
pub fn kindOf(io: Io, dir: Dir, entry: Dir.Entry, options: Dir.StatFileOptions) !Io.File.Kind {
    if (entry.kind != .unknown and !(entry.kind == .sym_link and options.follow_symlinks)) return entry.kind;
    const st = dir.statFile(io, entry.name, options) catch |err| switch (err) {
        error.FileNotFound => return .unknown, // a dangling link
        else => return err,
    };
    return st.kind;
}

/// $TMPDIR, else /tmp.
pub fn tempDir(env: *const Environ.Map) []const u8 {
    if (env.get("TMPDIR")) |t| if (t.len > 0) return t;
    return "/tmp";
}

// --- Process execution -------------------------------------------------------
//
// Tests replace `exec_backend` to fake child processes. Faking them through
// `io` is possible too (spawn is in the Io vtable), but a fake child would
// need real pipes for its output; two function pointers are simpler.

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
    /// Replaces the child environment when set. `argv[0]` is still resolved
    /// against this process's PATH, so pass an absolute path when it matters.
    environ_map: ?*const Environ.Map = null,
};

pub const ExecOptions = struct {
    cwd: ?[]const u8 = null,
    /// Replaces the child environment when set.
    environ_map: ?*const Environ.Map = null,
    /// Executable to run, while `argv[0]` stays as given. Needed when the
    /// command was resolved against a PATH other than this process's own:
    /// the std spawn resolves `argv[0]` against the parent PATH only.
    exe_path: ?[]const u8 = null,
};

pub const ExecBackend = struct {
    run: *const fn (allocator: Allocator, io: Io, argv: []const []const u8, opts: RunOptions) anyerror!RunResult,
    exec: *const fn (io: Io, argv: []const []const u8, opts: ExecOptions) anyerror!Term,
};

/// The active backend. Set once to the real impl; tests swap it and restore.
pub var exec_backend: ExecBackend = .{ .run = realRun, .exec = realExec };

/// Runs `argv` to completion capturing stdout/stderr (caller owns both), like
/// `std.process.run`.
pub fn run(allocator: Allocator, io: Io, argv: []const []const u8, opts: RunOptions) !RunResult {
    return exec_backend.run(allocator, io, argv, opts);
}

/// Runs `argv` to completion with inherited stdio, returning the child's `Term`.
pub fn exec(io: Io, argv: []const []const u8, opts: ExecOptions) !Term {
    return exec_backend.exec(io, argv, opts);
}

/// Replaces this process with `argv` (exec); returns only on failure. Not in
/// `exec_backend`: a test that reached it would replace the test runner.
pub fn replace(io: Io, argv: []const []const u8, opts: ExecOptions) anyerror {
    return std.process.replace(io, .{
        .exe = exeOf(opts.exe_path),
        .argv = argv,
        .cwd = cwdOf(opts.cwd),
        .environ_map = opts.environ_map,
    });
}

fn exeOf(exe_path: ?[]const u8) std.process.ReplaceOptions.Exe {
    return if (exe_path) |p| .{ .explicit = .{ .dir = Dir.cwd(), .path = p } } else .detect;
}

fn cwdOf(cwd: ?[]const u8) std.process.Child.Cwd {
    return if (cwd) |c| .{ .path = c } else .inherit;
}

fn realRun(allocator: Allocator, io: Io, argv: []const []const u8, opts: RunOptions) anyerror!RunResult {
    const r = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = opts.stdout_limit,
        .stderr_limit = opts.stderr_limit,
        .cwd = cwdOf(opts.cwd),
        .environ_map = opts.environ_map,
    });
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

fn realExec(io: Io, argv: []const []const u8, opts: ExecOptions) anyerror!Term {
    var child = try std.process.spawn(io, .{
        .exe = exeOf(opts.exe_path),
        .argv = argv,
        .cwd = cwdOf(opts.cwd),
        .environ_map = opts.environ_map,
    });
    return child.wait(io);
}
