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
