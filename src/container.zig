//! Container support. An env with `container` in zenv.json runs inside that
//! image: its venv is built on the image's Python with the image's packages
//! visible (include-system-site-packages), and `zenv run` starts commands in
//! the image. zenv itself always stays on the host and only starts commands in
//! the image through the runtime, Apptainer or Docker: setup's steps
//! (envbuild.zig) and the command of `zenv run` (launch.zig). The venv lives
//! in the env directory on the host, which is bound into the image at the
//! same path.
//!
//! Apptainer passes the host environment in, except PATH (the image's own)
//! and LD_LIBRARY_PATH, and binds $HOME, /tmp and the working directory by
//! default. Docker passes nothing in and binds nothing. zenv binds the paths
//! it needs itself with both, so a site's bind configuration is a convenience
//! it does not rely on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Map = std.process.Environ.Map;
const config = @import("config.zig");
const runtime = @import("runtime.zig");

/// The program that runs the image.
pub const Runtime = config.Container.Runtime;

/// The container part of `zenv-env.json`: the image and the env's extra
/// options and binds.
pub const Image = struct {
    runtime: Runtime = .apptainer,
    /// For Apptainer a path, resolved against the project directory, or a URI
    /// (`docker://...`); for Docker an image reference as written.
    image: []const u8,
    options: []const []const u8 = &.{},
    bind: []const []const u8 = &.{},
    /// The env's project directory, bound so commands can reach its files.
    project_dir: []const u8 = "",
};

/// `cfg` with its image resolved. A Docker reference, a URI (`docker://...`)
/// and an absolute path stay as written; a relative Apptainer path is taken
/// against `project_dir`.
pub fn fromConfig(a: Allocator, cfg: *const config.Container, project_dir: []const u8) !Image {
    const as_written = cfg.runtime == .docker or isUri(cfg.image) or
        Io.Dir.path.isAbsolute(cfg.image);
    return .{
        .runtime = cfg.runtime,
        .image = if (as_written) cfg.image else try Io.Dir.path.resolve(a, &.{ project_dir, cfg.image }),
        .options = cfg.options.items,
        .bind = cfg.bind.items,
        .project_dir = project_dir,
    };
}

pub fn isUri(image: []const u8) bool {
    return std.mem.find(u8, image, "://") != null;
}

/// One command to run in an image.
pub const Command = struct {
    /// Host paths the command needs, bound at the same path. One that does
    /// not exist, or lies inside an earlier one, is left out.
    paths: []const []const u8 = &.{},
    /// The working directory inside. Null: the runtime's own choice, which is
    /// the host's working directory for Apptainer and the image's for Docker.
    cwd: ?[]const u8 = null,
    /// Docker only: connect the command to zenv's stdin, and to its terminal.
    /// Apptainer always does both.
    stdin: bool = false,
    tty: bool = false,
    /// Docker only: `NAME` or `NAME=value` variables to set inside.
    env: []const []const u8 = &.{},
    argv: []const []const u8,
};

/// The host argv that runs `cmd` in `img`. The runtime's name is argv[0], to
/// be resolved on the host's PATH. The env's own options and binds come after
/// zenv's, so they win where the runtime lets the last one win.
pub fn hostArgv(a: Allocator, io: Io, img: Image, cmd: Command) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    var bound: std.ArrayList([]const u8) = .empty;
    for (cmd.paths) |p| {
        // Both runtimes refuse or misread a missing source.
        if (covered(bound.items, p) or !runtime.exists(io, p)) continue;
        try bound.append(a, p);
    }
    switch (img.runtime) {
        .apptainer => {
            try argv.appendSlice(a, &.{ "apptainer", "exec" });
            if (cmd.cwd) |dir| try argv.appendSlice(a, &.{ "--pwd", dir });
            for (bound.items) |p| try argv.appendSlice(a, &.{ "--bind", p });
            try argv.appendSlice(a, img.options);
            for (img.bind) |b| try argv.appendSlice(a, &.{ "--bind", b });
        },
        .docker => {
            // --init: the command would otherwise be PID 1, which ignores
            // SIGINT and SIGTERM unless it handles them. The empty entrypoint
            // makes the image run the command itself, as `apptainer exec`
            // does, not hand it to the image's entrypoint script.
            try argv.appendSlice(a, &.{ "docker", "run", "--rm", "--init", "--entrypoint", "" });
            if (cmd.stdin) try argv.append(a, "-i");
            if (cmd.tty) try argv.append(a, "-t");
            if (cmd.cwd) |dir| try argv.appendSlice(a, &.{ "-w", dir });
            for (bound.items) |p| {
                try argv.appendSlice(a, &.{ "-v", try std.fmt.allocPrint(a, "{s}:{s}", .{ p, p }) });
            }
            for (cmd.env) |e| try argv.appendSlice(a, &.{ "-e", e });
            try argv.appendSlice(a, img.options);
            for (img.bind) |b| {
                // A bare path is a bind at the same path for Apptainer, but
                // an anonymous volume for Docker.
                const spec = if (std.mem.findScalar(u8, b, ':') == null)
                    try std.fmt.allocPrint(a, "{s}:{s}", .{ b, b })
                else
                    b;
                try argv.appendSlice(a, &.{ "-v", spec });
            }
        },
    }
    try argv.append(a, img.image);
    try argv.appendSlice(a, cmd.argv);
    return argv.items;
}

/// A script for `/bin/sh -c` in an image, with the script to run as its "$0"
/// and that script's arguments after it. It hands over to bash when the image
/// has one, since hooks are written for bash, and to sh otherwise. The script
/// then finds "zenv" as its own "$0".
pub const pick_shell = "if command -v bash >/dev/null 2>&1; then exec bash -c \"$0\" zenv \"$@\"; " ++
    "else exec sh -c \"$0\" zenv \"$@\"; fi";

/// Whether `path` is one of `dirs` or inside one.
pub fn covered(dirs: []const []const u8, path: []const u8) bool {
    for (dirs) |d| {
        const rest = std.mem.cutPrefix(u8, path, d) orelse continue;
        if (rest.len == 0 or rest[0] == '/' or std.mem.endsWith(u8, d, "/")) return true;
    }
    return false;
}

/// The variables of a host environment that stay outside the container:
/// PYTHONPATH would carry host (module) packages into the image's Python,
/// VIRTUAL_ENV and its prompt belong to a venv activated on the host, and
/// BASH_ENV (Lmod's init) would have every bash in the image start the host's
/// module system, which cannot run there.
const host_only = [_][]const u8{
    "PYTHONPATH",
    "PYTHONHOME",
    "VIRTUAL_ENV",
    "VIRTUAL_ENV_PROMPT",
    "BASH_ENV",
};

/// `env` without the host-only variables, nor the bash functions the host
/// exports (`BASH_FUNC_module%%`, Lmod's `module`): what the runtime is
/// started with. Apptainer passes it on into the container.
pub fn hostEnv(a: Allocator, env: *const Map) !Map {
    var out = try env.clone(a);
    for (host_only) |name| _ = out.orderedRemove(name);
    var functions: std.ArrayList([]const u8) = .empty;
    defer functions.deinit(a);
    for (out.keys()) |name| {
        if (std.mem.startsWith(u8, name, "BASH_FUNC_")) try functions.append(a, name);
    }
    // Removing frees the key, so remove copies of the names.
    for (functions.items) |name| {
        const copy = try a.dupe(u8, name);
        defer a.free(copy);
        _ = out.orderedRemove(copy);
    }
    return out;
}

/// A cheap identity of an image for the rebuild check, so a replaced image
/// rebuilds the env. For a local Apptainer image file it is the size and
/// modification time (hashing a multi-gigabyte image on every `zenv run`
/// would be too slow), for a Docker image the ID its reference stands for
/// now. Null for an Apptainer URI, a file that cannot be read, and a Docker
/// image that is not pulled or a daemon that does not answer.
pub fn fingerprint(a: Allocator, io: Io, kind: Runtime, image: []const u8) !?[]const u8 {
    switch (kind) {
        .apptainer => {
            if (isUri(image)) return null;
            const st = Io.Dir.cwd().statFile(io, image, .{}) catch return null;
            return try std.fmt.allocPrint(a, "{d}:{d}", .{ st.size, st.mtime.nanoseconds });
        },
        .docker => {
            const res = runtime.run(a, io, &.{ "docker", "image", "inspect", "--format", "{{.Id}}", image }, .{
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(64 * 1024),
            }) catch return null;
            defer a.free(res.stdout);
            defer a.free(res.stderr);
            const id = std.mem.trim(u8, res.stdout, " \r\n");
            if (!res.term.success() or id.len == 0) return null;
            return try a.dupe(u8, id);
        },
    }
}

// ============================ Tests ============================
const testing = std.testing;

test "fromConfig resolves a relative Apptainer image against the project" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: config.Container = .{ .image = "images/py.sif" };
    try testing.expectEqualStrings("/p/proj/images/py.sif", (try fromConfig(a, &cfg, "/p/proj")).image);
    cfg.image = "../shared/py.sif";
    try testing.expectEqualStrings("/p/shared/py.sif", (try fromConfig(a, &cfg, "/p/proj")).image);
    cfg.image = "/abs/py.sif";
    try testing.expectEqualStrings("/abs/py.sif", (try fromConfig(a, &cfg, "/p/proj")).image);
    cfg.image = "docker://python:3.13-slim";
    try testing.expectEqualStrings(cfg.image, (try fromConfig(a, &cfg, "/p/proj")).image);
}

test "fromConfig keeps a Docker image reference as written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg: config.Container = .{ .runtime = .docker, .image = "pytorch/pytorch:2.5.1" };
    const img = try fromConfig(arena.allocator(), &cfg, "/p/proj");
    try testing.expectEqual(Runtime.docker, img.runtime);
    try testing.expectEqualStrings("pytorch/pytorch:2.5.1", img.image);
}

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "hostArgv binds existing paths once, then the env's options, binds and the image" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const root = ".zig-cache/tmp/zenv-container-argv-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/proj/.zenv/e");
    const paths: []const []const u8 = &.{ root ++ "/proj", root ++ "/proj/.zenv/e", root ++ "/missing", root ++ "/proj" };

    try expectArgv(&.{
        "apptainer", "exec",           "--pwd",    "/w", "--bind", root ++ "/proj", "--nv",
        "--bind",    "/data:/data:ro", "/img.sif", "sh", "-c",     "true",
    }, try hostArgv(a, io, .{
        .image = "/img.sif",
        .options = &.{"--nv"},
        .bind = &.{"/data:/data:ro"},
    }, .{ .paths = paths, .cwd = "/w", .stdin = true, .tty = true, .argv = &.{ "sh", "-c", "true" } }));

    try expectArgv(&.{
        "docker", "run",               "--rm",   "--init", "--entrypoint", "",
        "-i",     "-t",                "-w",     "/w",     "-v",           root ++ "/proj:" ++ root ++ "/proj",
        "-e",     "TERM",              "--gpus", "all",    "-v",           "/data:/data:ro",
        "-v",     "/scratch:/scratch", "py:3",   "python",
    }, try hostArgv(a, io, .{
        .runtime = .docker,
        .image = "py:3",
        .options = &.{ "--gpus", "all" },
        .bind = &.{ "/data:/data:ro", "/scratch" },
    }, .{ .paths = paths, .cwd = "/w", .stdin = true, .tty = true, .env = &.{"TERM"}, .argv = &.{"python"} }));

    try expectArgv(
        &.{ "docker", "run", "--rm", "--init", "--entrypoint", "", "py:3", "python" },
        try hostArgv(a, io, .{ .runtime = .docker, .image = "py:3" }, .{ .argv = &.{"python"} }),
    );
}

test "fingerprint of an Apptainer image: null for a URI or a missing file" {
    try testing.expect(try fingerprint(testing.allocator, testing.io, .apptainer, "docker://python:3") == null);
    try testing.expect(try fingerprint(testing.allocator, testing.io, .apptainer, "/no/such/image.sif") == null);
}

test "covered matches a directory and its children, not a sibling prefix" {
    try testing.expect(covered(&.{"/p/proj"}, "/p/proj"));
    try testing.expect(covered(&.{"/p/proj"}, "/p/proj/.zenv"));
    try testing.expect(!covered(&.{"/p/proj"}, "/p/project2"));
    try testing.expect(covered(&.{"/"}, "/anything"));
}

test "hostEnv leaves the host's Python settings outside" {
    var env = Map.init(testing.allocator);
    defer env.deinit();
    try env.put("PYTHONPATH", "/modules/site");
    try env.put("VIRTUAL_ENV", "/host/venv");
    try env.put("SLURM_JOB_ID", "42");
    try env.put("BASH_ENV", "/p/software/lmod/init/bash");
    try env.put("BASH_FUNC_module%%", "() {  eval $($LMOD_CMD bash \"$@\")\n}");
    try env.put("BASH_FUNC_ml%%", "() {  eval $($LMOD_DIR/ml_cmd \"$@\")\n}");
    var out = try hostEnv(testing.allocator, &env);
    defer out.deinit();
    try testing.expect(out.get("PYTHONPATH") == null);
    try testing.expect(out.get("VIRTUAL_ENV") == null);
    try testing.expect(out.get("BASH_ENV") == null);
    try testing.expect(out.get("BASH_FUNC_module%%") == null);
    try testing.expect(out.get("BASH_FUNC_ml%%") == null);
    try testing.expectEqualStrings("42", out.get("SLURM_JOB_ID").?);
}
