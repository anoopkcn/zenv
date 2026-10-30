//! Test-only helpers. Not imported by `main.zig`, so it is compiled only for
//! `zig build test`.

const std = @import("std");
const runtime = @import("runtime.zig");

/// A context over `std.testing.io` with `env` as the environment.
pub fn ctx(arena: std.mem.Allocator, env: *const std.process.Environ.Map) runtime.Ctx {
    return .{ .arena = arena, .io = std.testing.io, .env = env };
}

/// An empty environment for tests that need none.
pub const no_env: std.process.Environ.Map = .{
    .array_hash_map = .empty,
    .allocator = std.testing.failing_allocator,
};

// --- Fake process-execution backend -----------------------------------------
// Set the canned values, install with useFakeExec(), and restore the returned
// previous backend with `defer` (the test runner shares one process, so a leaked
// fake would break later tests that exec). The fake dupes its output so the
// caller's `defer allocator.free(result.stdout/stderr)` works exactly as it does
// against the real backend.
pub var fake_run_stdout: []const u8 = "";
pub var fake_run_stderr: []const u8 = "";
pub var fake_run_exit: u8 = 0;
pub var fake_exec_exit: u8 = 0;

fn fakeRun(
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const []const u8,
    _: runtime.RunOptions,
) anyerror!runtime.RunResult {
    return .{
        .term = .{ .exited = fake_run_exit },
        .stdout = try allocator.dupe(u8, fake_run_stdout),
        .stderr = try allocator.dupe(u8, fake_run_stderr),
    };
}

fn fakeExec(_: std.Io, _: []const []const u8, _: runtime.ExecOptions) anyerror!runtime.Term {
    return .{ .exited = fake_exec_exit };
}

/// Installs the fake exec backend, returning the previous one to restore:
///   const prev = test_support.useFakeExec(); defer runtime.exec_backend = prev;
pub fn useFakeExec() runtime.ExecBackend {
    const prev = runtime.exec_backend;
    runtime.exec_backend = .{ .run = fakeRun, .exec = fakeExec };
    return prev;
}
