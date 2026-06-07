//! Test-only helpers. Not imported by `main.zig`, so it is compiled only for
//! `zig build test`.

const std = @import("std");
const runtime = @import("utils/runtime.zig");
const output = @import("utils/output.zig");

var threaded: std.Io.Threaded = undefined;
var env_map: std.process.Environ.Map = undefined;
var ready = false;

/// Initializes the process-wide I/O context (`runtime.io` / `runtime.environ_map`)
/// so tests can exercise code that logs, reads the clock, or queries the
/// environment. Idempotent; safe to call from every test. Uses the page
/// allocator for the process-lifetime backing state so it doesn't trip the
/// testing allocator's leak checks.
pub fn setupRuntime() void {
    if (ready) return;
    threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    runtime.io = threaded.io();
    env_map = std.process.Environ.Map.init(std.heap.page_allocator);
    runtime.environ_map = &env_map;
    output.silent = true; // don't write to the test runner's stdout
    ready = true;
}

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

fn fakeRun(allocator: std.mem.Allocator, argv: []const []const u8, opts: runtime.RunOptions) anyerror!runtime.RunResult {
    _ = argv;
    _ = opts;
    return .{
        .term = .{ .exited = fake_run_exit },
        .stdout = try allocator.dupe(u8, fake_run_stdout),
        .stderr = try allocator.dupe(u8, fake_run_stderr),
    };
}

fn fakeExec(argv: []const []const u8, opts: runtime.ExecOptions) anyerror!runtime.Term {
    _ = argv;
    _ = opts;
    return .{ .exited = fake_exec_exit };
}

/// Installs the fake exec backend, returning the previous one to restore:
///   const prev = test_support.useFakeExec(); defer runtime.exec_backend = prev;
pub fn useFakeExec() runtime.ExecBackend {
    const prev = runtime.exec_backend;
    runtime.exec_backend = .{ .run = fakeRun, .exec = fakeExec };
    return prev;
}
