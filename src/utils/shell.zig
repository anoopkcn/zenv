//! Helpers for the shell code zenv still generates or runs: quoting values
//! into generated scripts, and copying the user's hook scripts into the venv.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const output = @import("output.zig");
const runtime = @import("runtime.zig");

pub const Flavour = enum { sh, csh, fish };

/// `value` as the body of a single-quoted string in `flavour`, printed with
/// `{f}`; the caller writes the quotes around it: `print("X='{f}'", .{sq(v)})`.
/// Use this for any config-sourced value (venv paths, module names)
/// interpolated into generated shell, so a stray `'` cannot break or rewrite
/// the script.
pub const Quoted = struct {
    flavour: Flavour,
    value: []const u8,

    pub fn format(q: Quoted, w: *Writer) Writer.Error!void {
        for (q.value) |c| switch (q.flavour) {
            // The classic `'\''`: close the quote, an escaped quote, reopen.
            .sh => if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c),
            // tcsh also applies history expansion inside single quotes, even
            // in sourced files, so a bare `!` would abort with "Event not found".
            .csh => switch (c) {
                '\'' => try w.writeAll("'\\''"),
                '!' => try w.writeAll("\\!"),
                else => try w.writeByte(c),
            },
            // Inside fish single quotes only `\` and `'` are special.
            .fish => switch (c) {
                '\\', '\'' => try w.print("\\{c}", .{c}),
                else => try w.writeByte(c),
            },
        };
    }
};

pub fn sq(value: []const u8) Quoted {
    return .{ .flavour = .sh, .value = value };
}

pub fn csq(value: []const u8) Quoted {
    return .{ .flavour = .csh, .value = value };
}

pub fn fsq(value: []const u8) Quoted {
    return .{ .flavour = .fish, .value = value };
}

/// Copies a user hook script to `<venv_dir>/scripts/<dest_name>` with mode
/// 0755, creating scripts/, and returns that path. Shared by setup and
/// activate. A relative `hook_path` is tried relative to `cwd_path` (where
/// zenv.json is), then relative to the process cwd. Allocates with `a` (use an
/// arena).
pub fn copyHookScript(a: Allocator, io: Io, hook_path: []const u8, venv_dir: []const u8, dest_name: []const u8, cwd_path: []const u8) ![]const u8 {
    const src = if (Io.Dir.path.isAbsolute(hook_path)) hook_path else blk: {
        const rel_path = try Io.Dir.path.join(a, &.{ cwd_path, hook_path });
        if (runtime.exists(io, rel_path)) break :blk rel_path;
        if (runtime.exists(io, hook_path)) break :blk hook_path;
        output.printError(io, "Hook script not found: tried '{s}' and '{s}'", .{ hook_path, rel_path });
        return error.FileNotFound;
    };
    const dest = try Io.Dir.path.join(a, &.{ venv_dir, "scripts", dest_name });
    output.print(io, "Copying hook script {s} -> {s}", .{ src, dest });
    const cwd = Io.Dir.cwd();
    try cwd.copyFile(src, cwd, dest, io, .{ .permissions = .fromMode(0o755), .make_path = true });
    return dest;
}

test "Quoted escapes for each shell" {
    var buf: [128]u8 = undefined;
    const v = "it's \\ and !";
    try std.testing.expectEqualStrings("it'\\''s \\ and !", try std.fmt.bufPrint(&buf, "{f}", .{sq(v)}));
    try std.testing.expectEqualStrings("it'\\''s \\ and \\!", try std.fmt.bufPrint(&buf, "{f}", .{csq(v)}));
    try std.testing.expectEqualStrings("it\\'s \\\\ and !", try std.fmt.bufPrint(&buf, "{f}", .{fsq(v)}));
}

test "copyHookScript resolves against cwd_path and creates scripts/ with mode 0755" {
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".zig-cache/tmp/zenv-copy-hook-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/project");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/project/hook.sh", .data = "echo hi\n" });

    const dest = try copyHookScript(a, io, "hook.sh", root ++ "/venv", "activate_hook.sh", root ++ "/project");
    try std.testing.expectEqualStrings(root ++ "/venv/scripts/activate_hook.sh", dest);
    try std.testing.expectEqualStrings("echo hi\n", try cwd.readFileAlloc(io, dest, a, .limited(1024)));
    const st = try cwd.statFile(io, dest, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), st.permissions.toMode() & 0o777);

    try std.testing.expectError(error.FileNotFound, copyHookScript(a, io, "missing.sh", root ++ "/venv", "x.sh", root ++ "/project"));
}
