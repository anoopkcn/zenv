//! Creates a Python virtual environment (PEP 405 layout) without the `venv`
//! module or `ensurepip`.
//!
//! The interpreter recognises a venv by itself at startup: it finds
//! `pyvenv.cfg` one level above its executable. A venv is therefore just that
//! file, `bin/python*` symlinks to the base interpreter, and empty
//! site-packages directories. The directory layout comes from the chosen
//! interpreter's own `sysconfig` `venv` scheme (Python 3.11+), or the layout
//! the `venv` module hard-codes on older versions, so distro patches (Debian,
//! Fedora's lib64) give the same result as `python -m venv`.
//!
//! pip is not installed here; setup installs it afterwards (uv, ensurepip or
//! the base interpreter's pip). `bin/activate` is a shim that sources zenv's
//! own activate.sh, so tools that source it (IDE terminals) get the full zenv
//! activation, modules included.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;
const options = @import("options");
const runtime = @import("runtime.zig");
const output = @import("output.zig");
const shell = @import("shell.zig");

/// Run by the base interpreter (with `-I`) to describe itself and the venv
/// layout for `sys.argv[1]`. Mirrors venv.EnvBuilder.ensure_directories.
const QUERY_SCRIPT =
    \\import json, os, sys, sysconfig
    \\venv = sys.argv[1]
    \\exe = getattr(sys, "_base_executable", None) or sys.executable
    \\if "venv" in sysconfig.get_scheme_names():
    \\    v = {"base": venv, "platbase": venv, "installed_base": venv, "installed_platbase": venv}
    \\    p = sysconfig.get_paths(scheme="venv", vars=v)
    \\    scripts, purelib, platlib = p["scripts"], p["purelib"], p["platlib"]
    \\else:
    \\    purelib = platlib = os.path.join(venv, "lib", "python%d.%d" % sys.version_info[:2], "site-packages")
    \\    scripts = os.path.join(venv, "bin")
    \\print(json.dumps({
    \\    "major": sys.version_info[0],
    \\    "minor": sys.version_info[1],
    \\    "version": "%d.%d.%d" % sys.version_info[:3],
    \\    "abiflags": getattr(sys, "abiflags", ""),
    \\    "base_executable": os.path.abspath(exe),
    \\    "real_executable": os.path.realpath(sys.executable),
    \\    "lib64_link": sys.maxsize > 2**32 and os.name == "posix" and sys.platform != "darwin",
    \\    "scripts": scripts, "purelib": purelib, "platlib": platlib,
    \\}))
;

/// What the base interpreter reports about itself and the venv layout.
pub const Interpreter = struct {
    major: u32,
    minor: u32,
    version: []const u8,
    abiflags: []const u8 = "",
    /// The interpreter the venv links to (`sys._base_executable`), unresolved,
    /// as `python -m venv` uses it.
    base_executable: []const u8,
    real_executable: []const u8,
    /// Create `lib64 -> lib` (64-bit POSIX except macOS), as `venv` does.
    lib64_link: bool,
    scripts: []const u8,
    purelib: []const u8,
    platlib: []const u8,
};

/// Asks `python` for its version and the venv layout under `venv_dir`.
/// Results are allocated with `a` (use an arena).
/// `env` is the environment to run it in (a module Python may need the
/// module's LD_LIBRARY_PATH); null means zenv's own.
pub fn query(a: Allocator, io: Io, python: []const u8, venv_dir: []const u8, env: ?*const std.process.Environ.Map) !Interpreter {
    const res = runtime.run(a, io, &.{ python, "-I", "-c", QUERY_SCRIPT, venv_dir }, .{
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .environ_map = env,
    }) catch |err| {
        output.printError(io, "Could not run Python '{s}': {t}", .{ python, err });
        return error.PythonQueryFailed;
    };
    if (!res.term.success()) {
        output.printError(io, "Python '{s}' failed to describe itself:\n{s}", .{ python, res.stderr });
        return error.PythonQueryFailed;
    }
    return parseQuery(a, res.stdout);
}

pub fn parseQuery(a: Allocator, text: []const u8) !Interpreter {
    const info = json.parseFromSliceLeaky(Interpreter, a, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.PythonQueryFailed;
    if (info.major < 3) return error.UnsupportedPython;
    return info;
}

/// Names linked in `bin/`, after the interpreter's own basename: `python`,
/// `python3`, `python3.X`, plus `python3.Xt` for free-threaded builds, as
/// `venv` creates them. Excludes `exe_name` itself.
pub fn linkNames(a: Allocator, info: *const Interpreter, exe_name: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const candidates = [_][]const u8{
        "python",
        "python3",
        try a.print("python{d}.{d}", .{ info.major, info.minor }),
        if (std.mem.findScalar(u8, info.abiflags, 't') != null)
            try a.print("python{d}.{d}t", .{ info.major, info.minor })
        else
            "",
    };
    for (candidates) |n| {
        if (n.len == 0 or std.mem.eql(u8, n, exe_name)) continue;
        try names.append(a, n);
    }
    return names.toOwnedSlice(a);
}

/// The `pyvenv.cfg` contents. `home` is the base interpreter's directory,
/// which is what the interpreter uses to find its standard library.
pub fn pyvenvCfg(a: Allocator, info: *const Interpreter, zenv_version: []const u8) ![]u8 {
    return a.print(
        \\home = {s}
        \\include-system-site-packages = false
        \\version = {s}
        \\executable = {s}
        \\zenv = {s}
        \\
    , .{ std.Io.Dir.path.dirname(info.base_executable) orelse "/", info.version, info.real_executable, zenv_version });
}

/// Creates the link unless something (even a dangling link) is already there.
fn symlinkIfMissing(io: Io, target: []const u8, link_path: []const u8, is_dir: bool) !void {
    Io.Dir.cwd().symLink(io, target, link_path, .{ .is_directory = is_dir }) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Writes the `activate*` shims into `scripts` (the venv's bin/): each sources
/// the zenv script for its shell from `venv_dir`, quoted for that shell.
fn writeShims(a: Allocator, io: Io, scripts: []const u8, venv_dir: []const u8) !void {
    inline for (.{
        .{ "activate", " (IDEs, scripts)", ".", "activate.sh", shell.sq },
        .{ "activate.csh", "", "source", "activate.csh", shell.csq },
        .{ "activate.fish", "", "source", "activate.fish", shell.fsq },
    }) |s| {
        const text = try a.print("# Created by zenv. Sourcing bin/" ++ s[0] ++ s[1] ++ " runs zenv's activation.\n" ++ s[2] ++ " '{f}/" ++ s[3] ++ "'\n", .{s[4](venv_dir)});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try Io.Dir.path.join(a, &.{ scripts, s[0] }), .data = text });
    }
}

/// Creates the venv at `venv_dir` (absolute) for interpreter `python` (an
/// absolute path), querying it in `env`. Idempotent: existing links are kept,
/// pyvenv.cfg and the shims are rewritten. Allocates with `a` (use an arena).
pub fn create(a: Allocator, io: Io, python: []const u8, venv_dir: []const u8, env: ?*const std.process.Environ.Map) !void {
    const cwd = Io.Dir.cwd();
    const join = Io.Dir.path.join;
    if (!Io.Dir.path.isAbsolute(venv_dir)) return error.VenvPathNotAbsolute;
    try cwd.createDirPath(io, venv_dir);
    const info = try query(a, io, python, venv_dir, env);

    // `venv` creates a plain include/ whatever the scheme says.
    const include = try join(a, &.{ venv_dir, "include" });
    for ([_][]const u8{ info.scripts, info.purelib, info.platlib, include }) |dir| try cwd.createDirPath(io, dir);
    if (info.lib64_link) {
        try symlinkIfMissing(io, "lib", try join(a, &.{ venv_dir, "lib64" }), true);
    }

    // bin/<exe> -> base interpreter; python, python3, python3.X -> <exe>.
    const exe_name = Io.Dir.path.basename(info.base_executable);
    try symlinkIfMissing(io, info.base_executable, try join(a, &.{ info.scripts, exe_name }), false);
    for (try linkNames(a, &info, exe_name)) |name| {
        try symlinkIfMissing(io, exe_name, try join(a, &.{ info.scripts, name }), false);
    }

    try cwd.writeFile(io, .{ .sub_path = try join(a, &.{ venv_dir, "pyvenv.cfg" }), .data = try pyvenvCfg(a, &info, options.version) });
    try cwd.writeFile(io, .{ .sub_path = try join(a, &.{ venv_dir, ".gitignore" }), .data = "# Created by zenv\n*\n" });
    try writeShims(a, io, info.scripts, venv_dir);

    output.print(io, "Created virtual environment {s} (Python {s}, from {s})", .{ venv_dir, info.version, info.base_executable });
}

// ============================ Tests ============================
const testing = std.testing;

const sample =
    \\{"major": 3, "minor": 13, "version": "3.13.1", "abiflags": "t",
    \\ "base_executable": "/opt/py/bin/python3.13t", "real_executable": "/opt/py/bin/python3.13t",
    \\ "lib64_link": true, "scripts": "/v/bin", "purelib": "/v/lib/python3.13t/site-packages",
    \\ "platlib": "/v/lib64/python3.13t/site-packages", "extra": 1}
;

test "parseQuery reads the interpreter description and rejects Python 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info = try parseQuery(a, sample);
    try testing.expectEqualStrings("3.13.1", info.version);
    try testing.expect(info.lib64_link);
    try testing.expectEqualStrings("/v/lib64/python3.13t/site-packages", info.platlib);

    try testing.expectError(error.UnsupportedPython, parseQuery(a,
        \\{"major": 2, "minor": 7, "version": "2.7.18", "base_executable": "/p", "real_executable": "/p",
        \\ "lib64_link": false, "scripts": "/v/bin", "purelib": "/v/l", "platlib": "/v/l"}
    ));
    try testing.expectError(error.PythonQueryFailed, parseQuery(a, "not json"));
}

test "linkNames adds the free-threaded name and skips the executable itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info = try parseQuery(a, sample);

    const ft = try linkNames(a, &info, "python3.13t");
    try testing.expectEqual(@as(usize, 3), ft.len);
    try testing.expectEqualStrings("python", ft[0]);
    try testing.expectEqualStrings("python3", ft[1]);
    try testing.expectEqualStrings("python3.13", ft[2]);

    info.abiflags = "";
    const plain = try linkNames(a, &info, "python3");
    try testing.expectEqual(@as(usize, 2), plain.len);
    try testing.expectEqualStrings("python3.13", plain[1]);
}

test "pyvenvCfg points home at the base interpreter's directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info = try parseQuery(a, sample);
    const cfg = try pyvenvCfg(a, &info, "1.2.3");
    try testing.expectEqualStrings(
        \\home = /opt/py/bin
        \\include-system-site-packages = false
        \\version = 3.13.1
        \\executable = /opt/py/bin/python3.13t
        \\zenv = 1.2.3
        \\
    , cfg);
}

test "writeShims quote the venv path for each shell" {
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".zig-cache/tmp/zenv-venv-shims-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    try writeShims(a, io, root, "/p/it's!");

    const sh = try cwd.readFileAlloc(io, root ++ "/activate", a, .limited(1024));
    try testing.expectEqualStrings("# Created by zenv. Sourcing bin/activate (IDEs, scripts) runs zenv's activation.\n. '/p/it'\\''s!/activate.sh'\n", sh);
    const csh = try cwd.readFileAlloc(io, root ++ "/activate.csh", a, .limited(1024));
    try testing.expectEqualStrings("# Created by zenv. Sourcing bin/activate.csh runs zenv's activation.\nsource '/p/it'\\''s\\!/activate.csh'\n", csh);
    const fish = try cwd.readFileAlloc(io, root ++ "/activate.fish", a, .limited(1024));
    try testing.expectEqualStrings("# Created by zenv. Sourcing bin/activate.fish runs zenv's activation.\nsource '/p/it\\'s!/activate.fish'\n", fish);
}
