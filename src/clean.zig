//! `zenv clean`: removes the Python bytecode an env left behind. Bytecode is a
//! cache, so everything removed here is written again by the next import.
//!
//! Two layouts hold it. Without PYTHONPYCACHEPREFIX, Python writes a
//! `__pycache__` directory next to each source directory. With it, Python
//! mirrors each source file's absolute path under the prefix, so the part of
//! a shared prefix that belongs to one directory is the subtree at
//! `<prefix>/<that directory>`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const runtime = @import("runtime.zig");

/// What a sweep found (and, unless it was a dry run, removed).
pub const Found = struct {
    /// Bytecode files and whatever else lay in a `__pycache__` directory.
    files: usize = 0,
    /// `__pycache__` directories.
    dirs: usize = 0,
    /// Entries that could not be removed, such as files another user owns.
    failed: usize = 0,

    pub fn add(self: *Found, other: Found) void {
        self.files += other.files;
        self.dirs += other.dirs;
        self.failed += other.failed;
    }
};

/// Directory names a sweep never enters: version control data.
const never_entered = [_][]const u8{ ".git", ".hg", ".svn" };

/// Removes every `__pycache__` directory under `root`, or only counts them
/// for `dry_run`. Symlinks are not followed. A directory in `skip` (absolute
/// paths) is left alone, and so is, with `skip_venvs`, a directory below
/// `root` that holds a `pyvenv.cfg`: another venv's bytecode is not this
/// env's to remove. A missing `root` finds nothing.
pub fn sweepPycache(
    a: Allocator,
    io: Io,
    root: []const u8,
    skip: []const []const u8,
    skip_venvs: bool,
    dry_run: bool,
) !Found {
    var found: Found = .{};
    var dir = Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return found;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const kind = runtime.kindOf(io, dir, entry, .{ .follow_symlinks = false }) catch continue;
        if (kind != .directory) continue;
        const path = try Dir.path.join(a, &.{ root, entry.name });
        defer a.free(path);
        if (std.mem.eql(u8, entry.name, "__pycache__")) {
            found.dirs += 1;
            found.files += countFiles(io, path);
            if (!dry_run) Dir.cwd().deleteTree(io, path) catch {
                found.failed += 1;
            };
            continue;
        }
        if (isOneOf(entry.name, &never_entered) or isOneOf(path, skip)) continue;
        if (skip_venvs) {
            const cfg = try Dir.path.join(a, &.{ path, "pyvenv.cfg" });
            defer a.free(cfg);
            if (runtime.lexists(io, cfg)) continue;
        }
        found.add(try sweepPycache(a, io, path, skip, skip_venvs, dry_run));
    }
    return found;
}

/// The directory under `prefix` (a PYTHONPYCACHEPREFIX) that mirrors
/// `source_dir`. Null when either is not absolute, or the prefix is the
/// filesystem root, where the mirror would be `source_dir` itself.
pub fn mirrorOf(a: Allocator, prefix: []const u8, source_dir: []const u8) !?[]const u8 {
    const base = std.mem.trimEnd(u8, prefix, "/");
    if (base.len == 0 or !Dir.path.isAbsolute(base) or !Dir.path.isAbsolute(source_dir)) return null;
    return try Dir.path.join(a, &.{ base, std.mem.trimStart(u8, source_dir, "/") });
}

/// Removes the `.pyc` files under `root`, a mirror inside a bytecode prefix,
/// and the directories that become empty, `root` included; or only counts
/// the files for `dry_run`. Other files stay, so a prefix that was pointed at
/// a directory with other content loses nothing but bytecode. Symlinks are
/// not followed. A missing `root` finds nothing.
pub fn sweepMirror(a: Allocator, io: Io, root: []const u8, dry_run: bool) !Found {
    var found: Found = .{};
    {
        var dir = Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return found;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            const kind = runtime.kindOf(io, dir, entry, .{ .follow_symlinks = false }) catch continue;
            if (kind == .directory) {
                const path = try Dir.path.join(a, &.{ root, entry.name });
                defer a.free(path);
                found.add(try sweepMirror(a, io, path, dry_run));
            } else if (kind == .file and std.mem.endsWith(u8, entry.name, ".pyc")) {
                found.files += 1;
                if (!dry_run) dir.deleteFile(io, entry.name) catch {
                    found.failed += 1;
                };
            }
        }
    }
    // Fails for a directory that still holds something, which then stays.
    if (!dry_run) Dir.cwd().deleteDir(io, root) catch {};
    return found;
}

/// Removes the directories above `path` that are empty, up to but not
/// including `stop`: what leads to a mirror that `sweepMirror` removed.
pub fn pruneEmptyParents(io: Io, path: []const u8, stop: []const u8) void {
    const top = std.mem.trimEnd(u8, stop, "/");
    var dir = Dir.path.dirname(path) orelse return;
    while (dir.len > top.len and std.mem.startsWith(u8, dir, top) and dir[top.len] == '/') {
        // Fails for a directory that holds something, which ends the walk.
        Dir.cwd().deleteDir(io, dir) catch return;
        dir = Dir.path.dirname(dir) orelse return;
    }
}

/// The number of files under `path`, at any depth.
fn countFiles(io: Io, path: []const u8) usize {
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const kind = runtime.kindOf(io, dir, entry, .{ .follow_symlinks = false }) catch continue;
        if (kind == .directory) {
            var buf: [Dir.max_path_bytes]u8 = undefined;
            const sub = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, entry.name }) catch continue;
            n += countFiles(io, sub);
        } else n += 1;
    }
    return n;
}

fn isOneOf(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// ============================ Tests ============================
const testing = std.testing;

fn touch(io: Io, comptime path: []const u8) !void {
    try Dir.cwd().createDirPath(io, Dir.path.dirname(path).?);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "x" });
}

test "sweepPycache removes __pycache__ directories and nothing else" {
    const a = testing.allocator;
    const io = testing.io;
    const root = ".zig-cache/tmp/zenv-clean-pycache";
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};
    try touch(io, root ++ "/pkg/mod.py");
    try touch(io, root ++ "/pkg/__pycache__/mod.cpython-313.pyc");
    try touch(io, root ++ "/pkg/__pycache__/other.cpython-313.pyc");
    try touch(io, root ++ "/pkg/sub/__pycache__/deep.cpython-313.pyc");
    try touch(io, root ++ "/.git/__pycache__/x.pyc");
    try touch(io, root ++ "/.venv/pyvenv.cfg");
    try touch(io, root ++ "/.venv/lib/__pycache__/v.pyc");
    try touch(io, root ++ "/envs/e/lib/__pycache__/e.pyc");

    const dry = try sweepPycache(a, io, root, &.{root ++ "/envs"}, true, true);
    try testing.expectEqual(@as(usize, 2), dry.dirs);
    try testing.expectEqual(@as(usize, 3), dry.files);
    try testing.expect(runtime.exists(io, root ++ "/pkg/__pycache__/mod.cpython-313.pyc"));

    const done = try sweepPycache(a, io, root, &.{root ++ "/envs"}, true, false);
    try testing.expectEqual(@as(usize, 2), done.dirs);
    try testing.expectEqual(@as(usize, 3), done.files);
    try testing.expectEqual(@as(usize, 0), done.failed);
    try testing.expect(!runtime.exists(io, root ++ "/pkg/__pycache__"));
    try testing.expect(!runtime.exists(io, root ++ "/pkg/sub/__pycache__"));
    try testing.expect(runtime.exists(io, root ++ "/pkg/mod.py"));
    // Version control data, another venv and a skipped directory stay.
    try testing.expect(runtime.exists(io, root ++ "/.git/__pycache__/x.pyc"));
    try testing.expect(runtime.exists(io, root ++ "/.venv/lib/__pycache__/v.pyc"));
    try testing.expect(runtime.exists(io, root ++ "/envs/e/lib/__pycache__/e.pyc"));

    // An env's own directory is swept whole: it is the venv.
    const venv = try sweepPycache(a, io, root ++ "/.venv", &.{}, false, false);
    try testing.expectEqual(@as(usize, 1), venv.dirs);

    const none = try sweepPycache(a, io, root ++ "/missing", &.{}, true, false);
    try testing.expectEqual(@as(usize, 0), none.dirs);
}

test "mirrorOf joins the prefix and the source directory, and refuses the root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/s/pyc/p/proj/.zenv/e", (try mirrorOf(a, "/s/pyc/", "/p/proj/.zenv/e")).?);
    try testing.expect(try mirrorOf(a, "/", "/p/proj") == null);
    try testing.expect(try mirrorOf(a, "", "/p/proj") == null);
    try testing.expect(try mirrorOf(a, "rel/pyc", "/p/proj") == null);
    try testing.expect(try mirrorOf(a, "/s/pyc", "proj") == null);
}

test "sweepMirror removes .pyc files and emptied directories, keeps other files" {
    const a = testing.allocator;
    const io = testing.io;
    const root = ".zig-cache/tmp/zenv-clean-mirror";
    Dir.cwd().deleteTree(io, root) catch {};
    defer Dir.cwd().deleteTree(io, root) catch {};
    try touch(io, root ++ "/p/proj/a.cpython-313.pyc");
    try touch(io, root ++ "/p/proj/pkg/b.cpython-313.pyc");
    try touch(io, root ++ "/p/proj/keep/notes.txt");
    try touch(io, root ++ "/p/other/c.cpython-313.pyc");

    const dry = try sweepMirror(a, io, root ++ "/p/proj", true);
    try testing.expectEqual(@as(usize, 2), dry.files);
    try testing.expect(runtime.exists(io, root ++ "/p/proj/a.cpython-313.pyc"));

    const done = try sweepMirror(a, io, root ++ "/p/proj", false);
    try testing.expectEqual(@as(usize, 2), done.files);
    try testing.expectEqual(@as(usize, 0), done.failed);
    try testing.expect(!runtime.exists(io, root ++ "/p/proj/pkg"));
    try testing.expect(runtime.exists(io, root ++ "/p/proj/keep/notes.txt"));
    // Another project's part of the prefix is untouched.
    try testing.expect(runtime.exists(io, root ++ "/p/other/c.cpython-313.pyc"));

    const all = try sweepMirror(a, io, root ++ "/p/other", false);
    try testing.expectEqual(@as(usize, 1), all.files);
    try testing.expect(!runtime.exists(io, root ++ "/p/other"));

    // The emptied way to a mirror goes too, but not past the prefix or a
    // directory that holds something.
    try touch(io, root ++ "/q/deep/er/x.pyc");
    _ = try sweepMirror(a, io, root ++ "/q/deep/er", false);
    pruneEmptyParents(io, root ++ "/q/deep/er", root);
    try testing.expect(!runtime.exists(io, root ++ "/q"));
    try testing.expect(runtime.exists(io, root));
    pruneEmptyParents(io, root ++ "/p/proj/keep/gone", root);
    try testing.expect(runtime.exists(io, root ++ "/p/proj/keep/notes.txt"));
}
