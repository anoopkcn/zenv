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
const json = std.json;
const runtime = @import("runtime.zig");
const output = @import("output.zig");

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
pub fn query(a: Allocator, python: []const u8, venv_dir: []const u8, env: ?*const std.process.Environ.Map) !Interpreter {
    const res = runtime.run(a, &[_][]const u8{ python, "-I", "-c", QUERY_SCRIPT, venv_dir }, .{
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .environ_map = env,
    }) catch |err| {
        output.printError(a, "Could not run Python '{s}': {s}", .{ python, @errorName(err) }) catch {};
        return error.PythonQueryFailed;
    };
    if (res.term != .exited or res.term.exited != 0) {
        output.printError(a, "Python '{s}' failed to describe itself:\n{s}", .{ python, res.stderr }) catch {};
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

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime.io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn symlinkIfMissing(target: []const u8, link_path: []const u8, is_dir: bool) !void {
    if (exists(link_path)) return;
    try std.Io.Dir.cwd().symLink(runtime.io, target, link_path, .{ .is_directory = is_dir });
}

/// Creates the venv at `venv_dir` (absolute) for interpreter `python` (an
/// absolute path), querying it in `env`. Idempotent: existing links are kept,
/// pyvenv.cfg and the shims are rewritten.
pub fn create(allocator: Allocator, python: []const u8, venv_dir: []const u8, env: ?*const std.process.Environ.Map) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (!std.Io.Dir.path.isAbsolute(venv_dir)) return error.VenvPathNotAbsolute;
    try runtime.makePath(venv_dir);
    const info = try query(a, python, venv_dir, env);

    // `venv` creates a plain include/ whatever the scheme says.
    const include = try std.Io.Dir.path.join(a, &[_][]const u8{ venv_dir, "include" });
    for ([_][]const u8{ info.scripts, info.purelib, info.platlib, include }) |dir| try runtime.makePath(dir);
    if (info.lib64_link) {
        try symlinkIfMissing("lib", try std.Io.Dir.path.join(a, &[_][]const u8{ venv_dir, "lib64" }), true);
    }

    // bin/<exe> -> base interpreter; python, python3, python3.X -> <exe>.
    const exe_name = std.Io.Dir.path.basename(info.base_executable);
    try symlinkIfMissing(info.base_executable, try std.Io.Dir.path.join(a, &[_][]const u8{ info.scripts, exe_name }), false);
    for (try linkNames(a, &info, exe_name)) |name| {
        try symlinkIfMissing(exe_name, try std.Io.Dir.path.join(a, &[_][]const u8{ info.scripts, name }), false);
    }

    const join = std.Io.Dir.path.join;
    try runtime.writeFile(try join(a, &[_][]const u8{ venv_dir, "pyvenv.cfg" }), try pyvenvCfg(a, &info, runtime.version));
    try runtime.writeFile(try join(a, &[_][]const u8{ venv_dir, ".gitignore" }), "# Created by zenv\n*\n");
    try runtime.writeFile(try join(a, &[_][]const u8{ info.scripts, "activate" }), try a.print(
        \\# Created by zenv. Sourcing bin/activate (IDEs, scripts) runs zenv's activation.
        \\. '{s}/activate.sh'
        \\
    , .{venv_dir}));
    try runtime.writeFile(try join(a, &[_][]const u8{ info.scripts, "activate.csh" }), try a.print(
        \\# Created by zenv. Sourcing bin/activate.csh runs zenv's activation.
        \\source '{s}/activate.csh'
        \\
    , .{venv_dir}));

    output.print(allocator, "Created virtual environment {s} (Python {s}, from {s})", .{ venv_dir, info.version, info.base_executable }) catch {};
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
