//! Helpers for the shell code zenv still generates or runs: quoting values
//! into generated scripts, and copying the user's hook scripts into the venv.

const std = @import("std");
const Allocator = std.mem.Allocator;
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

/// Like `appendSqEscaped`, for csh/tcsh: also writes `!` as `\!`. tcsh applies
/// history expansion inside single quotes, even in sourced files, so a bare
/// `!` would abort the script with "Event not found".
pub fn appendCshSqEscaped(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |c| switch (c) {
        '\'' => try w.writeAll("'\\''"),
        '!' => try w.writeAll("\\!"),
        else => try w.writeByte(c),
    };
}

/// Like `appendSqEscaped`, for fish: inside fish single quotes only `\` and
/// `'` are special, and are escaped with a backslash. Newlines are allowed.
pub fn appendFishSqEscaped(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\'' => try w.writeAll("\\'"),
        else => try w.writeByte(c),
    };
}

fn accessFile(path: []const u8) bool {
    runtime.access(path) catch return false;
    return true;
}

/// Copies a user hook script to `<venv_dir>/scripts/<dest_name>` with mode
/// 0755, creating scripts/, and returns that path. Shared by setup and
/// activate. A relative `hook_path` is tried relative to `cwd_path` (where
/// zenv.json is), then relative to the process cwd. Allocates with `a` (use an
/// arena).
pub fn copyHookScript(a: Allocator, hook_path: []const u8, venv_dir: []const u8, dest_name: []const u8, cwd_path: []const u8) ![]const u8 {
    const src = if (std.Io.Dir.path.isAbsolute(hook_path)) hook_path else blk: {
        const rel_path = try std.Io.Dir.path.join(a, &[_][]const u8{ cwd_path, hook_path });
        if (accessFile(rel_path)) break :blk rel_path;
        if (accessFile(hook_path)) break :blk hook_path;
        output.printError(a, "Hook script not found: tried '{s}' and '{s}'", .{ hook_path, rel_path }) catch {};
        return error.FileNotFound;
    };
    const dest = try std.Io.Dir.path.join(a, &[_][]const u8{ venv_dir, "scripts", dest_name });
    output.print(a, "Copying hook script {s} -> {s}", .{ src, dest }) catch {};
    const cwd = std.Io.Dir.cwd();
    try cwd.copyFile(src, cwd, dest, runtime.io, .{ .permissions = .fromMode(0o755), .make_path = true });
    return dest;
}

test "copyHookScript resolves against cwd_path and creates scripts/ with mode 0755" {
    const test_support = @import("../test_support.zig");
    test_support.setupRuntime();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".zig-cache/tmp/zenv-copy-hook-test";
    runtime.deleteTree(root) catch {};
    defer runtime.deleteTree(root) catch {};
    try runtime.makePath(root ++ "/project");
    try runtime.writeFile(root ++ "/project/hook.sh", "echo hi\n");

    const dest = try copyHookScript(a, "hook.sh", root ++ "/venv", "activate_hook.sh", root ++ "/project");
    try std.testing.expectEqualStrings(root ++ "/venv/scripts/activate_hook.sh", dest);
    try std.testing.expectEqualStrings("echo hi\n", try runtime.readFileAlloc(a, dest, 1024));
    const st = try std.Io.Dir.cwd().statFile(runtime.io, dest, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), st.permissions.toMode() & 0o777);

    try std.testing.expectError(error.FileNotFound, copyHookScript(a, "missing.sh", root ++ "/venv", "x.sh", root ++ "/project"));
}
