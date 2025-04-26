const std = @import("std");
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
// Import the errors module
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

// Executes a command, allows failure, captures stdout/stderr.
// Note: The `_: anytype` parameter seems unused and can likely be removed.
// Consider if it was intended for future use (e.g., logging context).
pub fn execAllowFail(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8, _: anytype) !ExecResult {
    var result = ExecResult{
        .term = undefined,
        .stdout = "",
        .stderr = "",
    };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    if (cwd) |dir| {
        child.cwd = dir;
    }

    try child.spawn();

    // Consider adding error handling for readToEndAlloc failure specifically
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stderr);

    result.term = try child.wait();
    result.stdout = stdout;
    result.stderr = stderr;

    return result;
}

// Executes a command, streams output, returns error on failure.
pub fn runCommand(allocator: Allocator, args: []const []const u8, env_map: ?*const std.process.EnvMap) !void {
    if (args.len == 0) {
        std.log.warn("runCommand called with empty arguments.", .{});
        return; // Or perhaps return an error?
    }
    std.debug.print("Running command: {s}\n", .{args}); // Use std.log.debug for verbose output?
    var child = std.process.Child.init(args, allocator);

    // Inherit parent environment by default (current behavior)
    if (env_map) |map| {
        child.env_map = map;
    }

    // Consider if streaming stdout/stderr to parent is desired instead of ignoring
    // child.stdout_behavior = .Inherit;
    // child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.log.err("Failed to spawn/wait for '{s}': {s}", .{ args[0], @errorName(err) });
        return ZenvError.ProcessError;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("Command '{s}' exited with code {d}", .{ args[0], code });
                return ZenvError.ProcessError;
            }
            std.log.info("Command '{s}' finished successfully.", .{args[0]}); // Use std.log.info?
        },
        .Signal => |sig| {
            std.log.err("Command '{s}' terminated by signal {d}", .{ args[0], sig });
            return ZenvError.ProcessError;
        },
        .Stopped => |sig| {
            std.log.err("Command '{s}' stopped by signal {d}", .{ args[0], sig });
            return ZenvError.ProcessError;
        },
        else => {
            std.log.err("Command '{s}' terminated unexpectedly: {?}", .{ args[0], term });
            return ZenvError.ProcessError;
        },
    }
}
