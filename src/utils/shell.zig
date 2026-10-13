//! Helpers for the shell code zenv still generates or runs: quoting values
//! into generated scripts, and copying the user's hook scripts into the venv.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");

/// Writes `value` to `w` as the body of a shell single-quoted string,
/// escaping any embedded single quotes with the classic `'\''` trick. The
/// caller writes the wrapping single quotes around the call. Use this for any
/// config-sourced value (venv paths, module names) interpolated into generated
/// shell so a stray `'` can't break or rewrite the script.
pub fn appendSqEscaped(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    var rest = value;
    while (std.mem.findScalar(u8, rest, '\'')) |q| {
        try w.writeAll(rest[0..q]);
        try w.writeAll("'\\''");
        rest = rest[q + 1 ..];
    }
    try w.writeAll(rest);
}

fn accessFile(path: []const u8) bool {
    runtime.access(path) catch return false;
    return true;
}

/// Copies a user hook script into the environment's scripts directory and returns
/// the absolute destination path (caller owns it). Shared by setup and activate.
///
/// Source resolution tries, in order: `hook_path` as-is when absolute, then
/// `cwd_path/hook_path`, then the bare `hook_path` (relative to the process cwd).
/// `dest_dir` MUST already be the absolute scripts directory (callers resolve any
/// cwd join before calling); the script is written to `dest_dir/dest_filename`
/// with mode 0755.
pub fn copyHookScript(
    allocator: Allocator,
    hook_path: []const u8,
    dest_dir: []const u8,
    dest_filename: []const u8,
    cwd_path: []const u8,
) ![]const u8 {
    var source_path: []const u8 = undefined;
    var path_allocd = false;

    if (std.Io.Dir.path.isAbsolute(hook_path)) {
        source_path = hook_path;
    } else {
        // Try relative to cwd (where zenv.json is), then the bare filename.
        const rel_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ cwd_path, hook_path });
        defer allocator.free(rel_path);

        if (accessFile(rel_path)) {
            source_path = try allocator.dupe(u8, rel_path);
            path_allocd = true;
        } else if (accessFile(hook_path)) {
            source_path = hook_path;
        } else {
            output.printError(allocator, "Hook script not found: tried '{s}' and '{s}'", .{ hook_path, rel_path }) catch {};
            return error.FileNotFound;
        }
    }
    defer if (path_allocd) allocator.free(source_path);

    if (!accessFile(source_path)) {
        output.printError(allocator, "Hook script found but cannot be read: {s}", .{source_path}) catch {};
        return error.FileNotFound;
    }

    const dest_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ dest_dir, dest_filename });
    errdefer allocator.free(dest_path);

    output.print(allocator, "Copying hook script {s} -> {s}", .{ source_path, dest_path }) catch {};
    const content = runtime.readFileAlloc(allocator, source_path, 10 * 1024 * 1024) catch |err| {
        output.printError(allocator, "Failed to read source hook script '{s}': {s}", .{ source_path, @errorName(err) }) catch {};
        return error.FileNotFound;
    };
    defer allocator.free(content);

    var dest_file = runtime.createFile(dest_path, .{ .permissions = .fromMode(0o755) }) catch |err| {
        output.printError(allocator, "Failed to create destination file '{s}': {s}", .{ dest_path, @errorName(err) }) catch {};
        return error.FileNotFound;
    };
    defer dest_file.close(runtime.io);

    dest_file.writeStreamingAll(runtime.io, content) catch |err| {
        output.printError(allocator, "Error writing to destination file '{s}': {s}", .{ dest_path, @errorName(err) }) catch {};
        return error.FileNotFound;
    };

    output.print(allocator, "Copied hook script from {s} to {s}", .{ source_path, dest_path }) catch {};
    return dest_path;
}
