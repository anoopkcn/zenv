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
const query_script =
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
pub fn query(
    a: Allocator,
    io: Io,
    python: []const u8,
    venv_dir: []const u8,
    env: ?*const std.process.Environ.Map,
) !Interpreter {
    const res = runtime.run(a, io, &.{ python, "-I", "-c", query_script, venv_dir }, .{
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .environ_map = env,
    }) catch |err| {
        output.printError(io, "Could not run Python '{s}': {t}", .{ python, err });
        return error.PythonQueryFailed;
    };
    if (!res.term.success()) {
        output.printError(
            io,
            "Python '{s}' failed to describe itself:\n{s}",
            .{ python, res.stderr },
        );
        return error.PythonQueryFailed;
    }
    return parseQuery(a, res.stdout);
}

fn parseQuery(a: Allocator, text: []const u8) !Interpreter {
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
fn linkNames(a: Allocator, info: *const Interpreter, exe_name: []const u8) ![]const []const u8 {
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
/// `system_site` lets the venv import the base interpreter's packages.
fn pyvenvCfg(
    a: Allocator,
    info: *const Interpreter,
    zenv_version: []const u8,
    system_site: bool,
) ![]u8 {
    return a.print(
        \\home = {s}
        \\include-system-site-packages = {}
        \\version = {s}
        \\executable = {s}
        \\zenv = {s}
        \\
    , .{
        std.Io.Dir.path.dirname(info.base_executable) orelse "/",
        system_site,
        info.version,
        info.real_executable,
        zenv_version,
    });
}

/// Whether the venv's pyvenv.cfg lets it import the base interpreter's
/// packages. False when the file is missing or unreadable.
pub fn includesSystemSite(a: Allocator, io: Io, venv_dir: []const u8) bool {
    const path = Io.Dir.path.join(a, &.{ venv_dir, "pyvenv.cfg" }) catch return false;
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024)) catch return false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const key, const value = std.mem.cutScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, key, " \t\r"), "include-system-site-packages")) continue;
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r"), "true");
    }
    return false;
}

/// Creates the link unless something (even a dangling link) is already there.
/// Keeps everything in `venv_dir` out of git.
pub fn writeGitignore(a: Allocator, io: Io, venv_dir: []const u8) !void {
    const path = try Io.Dir.path.join(a, &.{ venv_dir, ".gitignore" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "# Created by zenv\n*\n" });
}

fn symlinkIfMissing(io: Io, target: []const u8, link_path: []const u8, is_dir: bool) !void {
    Io.Dir.cwd().symLink(
        io,
        target,
        link_path,
        .{ .is_directory = is_dir },
    ) catch |err| switch (err) {
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
        const text = try a.print(
            "# Created by zenv. Sourcing bin/" ++ s[0] ++ s[1] ++ " runs zenv's activation.\n" ++ s[2] ++ " '{f}/" ++ s[3] ++ "'\n",
            .{s[4](venv_dir)},
        );
        try Io.Dir.cwd().writeFile(
            io,
            .{ .sub_path = try Io.Dir.path.join(a, &.{ scripts, s[0] }), .data = text },
        );
    }
}

/// Creates the venv at `venv_dir` (absolute) for interpreter `python` (an
/// absolute path), querying it in `env`. Idempotent: existing links are kept,
/// pyvenv.cfg and the shims are rewritten. `system_site` lets the venv import
/// the interpreter's own packages. Allocates with `a` (use an arena).
pub fn create(
    a: Allocator,
    io: Io,
    python: []const u8,
    venv_dir: []const u8,
    env: ?*const std.process.Environ.Map,
    system_site: bool,
) !void {
    const cwd = Io.Dir.cwd();
    const join = Io.Dir.path.join;
    if (!Io.Dir.path.isAbsolute(venv_dir)) return error.VenvPathNotAbsolute;
    try cwd.createDirPath(io, venv_dir);
    const info = try query(a, io, python, venv_dir, env);

    // `venv` creates a plain include/ whatever the scheme says.
    const include = try join(a, &.{ venv_dir, "include" });
    for ([_][]const u8{
        info.scripts,
        info.purelib,
        info.platlib,
        include,
    }) |dir| try cwd.createDirPath(
        io,
        dir,
    );
    if (info.lib64_link) {
        try symlinkIfMissing(io, "lib", try join(a, &.{ venv_dir, "lib64" }), true);
    }

    // bin/<exe> -> base interpreter; python, python3, python3.X -> <exe>.
    const exe_name = Io.Dir.path.basename(info.base_executable);
    try symlinkIfMissing(
        io,
        info.base_executable,
        try join(a, &.{ info.scripts, exe_name }),
        false,
    );
    for (try linkNames(a, &info, exe_name)) |name| {
        try symlinkIfMissing(io, exe_name, try join(a, &.{ info.scripts, name }), false);
    }

    try cwd.writeFile(
        io,
        .{
            .sub_path = try join(a, &.{ venv_dir, "pyvenv.cfg" }),
            .data = try pyvenvCfg(a, &info, options.version, system_site),
        },
    );
    try writeGitignore(a, io, venv_dir);
    try writeShims(a, io, info.scripts, venv_dir);

    output.print(
        io,
        "Created virtual environment {s} (Python {s}, from {s})",
        .{ venv_dir, info.version, info.base_executable },
    );
}

/// Fields extracted from a pyvenv.cfg body. Slices point INTO the input.
const PyvenvFields = struct { version: ?[]const u8, path: ?[]const u8 };

/// Pure parser for pyvenv.cfg contents. `version` is the `version =` value.
/// `path` is the best-available interpreter path across Python versions:
/// `executable =` (3.11+) -> first token of `command =` (3.x, incl. zenv's
/// default 3.10) -> `home =` (the bin dir). Returns nulls when absent.
fn parsePyvenvCfg(content: []const u8) PyvenvFields {
    var version: ?[]const u8 = null;
    var executable: ?[]const u8 = null;
    var home: ?[]const u8 = null;
    var command: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const raw_key, const raw_val = std.mem.cutScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, raw_key, " \t\r");
        const val = std.mem.trim(u8, raw_val, " \t\r");
        if (std.mem.eql(u8, key, "version")) {
            version = val;
        } else if (std.mem.eql(u8, key, "executable")) {
            executable = val;
        } else if (std.mem.eql(u8, key, "home")) {
            home = val;
        } else if (std.mem.eql(u8, key, "command")) {
            command = val;
        }
    }

    var path: ?[]const u8 = executable;
    if (path == null) {
        if (command) |cmd| {
            const first = std.mem.sliceTo(cmd, ' ');
            if (first.len > 0) path = first;
        }
    }
    if (path == null) path = home;

    return .{ .version = version, .path = path };
}

/// Reads <venv_path>/pyvenv.cfg and returns the Python that built the venv: its
/// interpreter path, or its version when no path is recorded. Returns null if
/// the file is absent/unreadable (env not built) or has no `version`. Caller
/// owns the result.
pub fn readPython(allocator: Allocator, io: Io, venv_path: []const u8) !?[]u8 {
    const cfg_path = try Io.Dir.path.join(allocator, &.{ venv_path, "pyvenv.cfg" });
    defer allocator.free(cfg_path);

    const content = Io.Dir.cwd().readFileAlloc(io, cfg_path, allocator, .limited(64 * 1024)) catch {
        // Missing or unreadable -> treat as "not built"; list output stays robust.
        return null;
    };
    defer allocator.free(content);

    const fields = parsePyvenvCfg(content);
    const version = fields.version orelse return null;
    return try allocator.dupe(u8, fields.path orelse version);
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
    const cfg = try pyvenvCfg(a, &info, "1.2.3", false);
    try testing.expectEqualStrings(
        \\home = /opt/py/bin
        \\include-system-site-packages = false
        \\version = 3.13.1
        \\executable = /opt/py/bin/python3.13t
        \\zenv = 1.2.3
        \\
    , cfg);
    const shared = try pyvenvCfg(a, &info, "1.2.3", true);
    try testing.expect(std.mem.find(u8, shared, "include-system-site-packages = true\n") != null);
}

test "includesSystemSite reads pyvenv.cfg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const root = ".zig-cache/tmp/zenv-system-site-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);

    try testing.expect(!includesSystemSite(a, io, root));
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/pyvenv.cfg",
        .data = "home = /usr/bin\ninclude-system-site-packages = True\n",
    });
    try testing.expect(includesSystemSite(a, io, root));
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/pyvenv.cfg",
        .data = "include-system-site-packages = false\n",
    });
    try testing.expect(!includesSystemSite(a, io, root));
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
    try testing.expectEqualStrings(
        "# Created by zenv. Sourcing bin/activate (IDEs, scripts) runs zenv's activation.\n. '/p/it'\\''s!/activate.sh'\n",
        sh,
    );
    const csh = try cwd.readFileAlloc(io, root ++ "/activate.csh", a, .limited(1024));
    try testing.expectEqualStrings(
        "# Created by zenv. Sourcing bin/activate.csh runs zenv's activation.\nsource '/p/it'\\''s\\!/activate.csh'\n",
        csh,
    );
    const fish = try cwd.readFileAlloc(io, root ++ "/activate.fish", a, .limited(1024));
    try testing.expectEqualStrings(
        "# Created by zenv. Sourcing bin/activate.fish runs zenv's activation.\nsource '/p/it\\'s!/activate.fish'\n",
        fish,
    );
}

test "parsePyvenvCfg: 3.11-style uses executable path" {
    const content =
        \\home = /opt/python/3.11/bin
        \\include-system-site-packages = false
        \\version = 3.11.5
        \\executable = /opt/python/3.11/bin/python3.11
        \\command = /opt/python/3.11/bin/python3.11 -m venv /p/zenv/e
    ;
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.11.5", f.version.?);
    try testing.expectEqualStrings("/opt/python/3.11/bin/python3.11", f.path.?);
}

test "parsePyvenvCfg: 3.10-style (no executable) falls back to command's first token" {
    const content =
        \\home = /opt/python/3.10/bin
        \\include-system-site-packages = false
        \\version = 3.10.8
        \\command = /opt/python/3.10/bin/python3.10 -m venv /p/zenv/e
    ;
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.10.8", f.version.?);
    try testing.expectEqualStrings("/opt/python/3.10/bin/python3.10", f.path.?);
}

test "parsePyvenvCfg: only version + home falls back to home" {
    const content =
        \\home = /usr/bin
        \\version = 3.9.2
    ;
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.9.2", f.version.?);
    try testing.expectEqualStrings("/usr/bin", f.path.?);
}

test "parsePyvenvCfg: missing version yields null (caller omits the line)" {
    const content =
        \\home = /usr/bin
        \\include-system-site-packages = false
    ;
    const f = parsePyvenvCfg(content);
    try testing.expect(f.version == null);
}

test "parsePyvenvCfg: tolerates CRLF and irregular spacing around '='" {
    const content = "version=3.12.1\r\nexecutable   =   /x/py\r\n";
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.12.1", f.version.?);
    try testing.expectEqualStrings("/x/py", f.path.?);
}
