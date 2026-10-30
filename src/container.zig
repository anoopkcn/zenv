//! Apptainer support. An env with `container` in zenv.json runs inside that
//! image: its venv is built on the image's Python with the image's packages
//! visible (include-system-site-packages), and `zenv run` starts commands in
//! the image. zenv stays on the host for what needs no Python (registry,
//! activation files, rebuild checks) and re-runs itself inside the image for
//! the rest: `zenv __build` for setup (envbuild.zig) and `zenv __exec` for
//! commands (commands.zig). Inside, those take the same code paths as an env
//! without a container.
//!
//! Apptainer passes the host environment in, except PATH (the image's own) and
//! LD_LIBRARY_PATH. It binds $HOME, /tmp and the working directory by default;
//! zenv binds the other paths it needs itself, so a site's bind configuration
//! is a convenience it does not rely on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Map = std.process.Environ.Map;
const config = @import("config.zig");
const runtime = @import("runtime.zig");

/// The container part of `zenv-env.json`: the image, resolved against the
/// project directory, and the env's extra options and binds.
pub const Image = struct {
    image: []const u8,
    options: []const []const u8 = &.{},
    bind: []const []const u8 = &.{},
    /// The env's project directory, bound so commands can reach its files.
    project_dir: []const u8 = "",
};

/// Whether this process runs inside an Apptainer container, which sets
/// APPTAINER_CONTAINER to the image.
pub fn inside(env: *const Map) bool {
    return env.get("APPTAINER_CONTAINER") != null;
}

/// `cfg` with its image resolved: a URI (`docker://...`) or an absolute path
/// as written, a relative path against `project_dir`.
pub fn fromConfig(a: Allocator, cfg: *const config.Container, project_dir: []const u8) !Image {
    const image = if (isUri(cfg.image) or Io.Dir.path.isAbsolute(cfg.image))
        cfg.image
    else
        try Io.Dir.path.resolve(a, &.{ project_dir, cfg.image });
    return .{
        .image = image,
        .options = cfg.options.items,
        .bind = cfg.bind.items,
        .project_dir = project_dir,
    };
}

pub fn isUri(image: []const u8) bool {
    return std.mem.find(u8, image, "://") != null;
}

/// The argv that runs `inner` in `img`: `apptainer exec`, the env's options,
/// a bind for each of `paths` that exists (Apptainer refuses a missing
/// source) and is not inside an earlier one, the env's own binds, the image,
/// then `inner`.
pub fn execArgv(
    a: Allocator,
    io: Io,
    img: Image,
    paths: []const []const u8,
    inner: []const []const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "apptainer", "exec" });
    try argv.appendSlice(a, img.options);
    var bound: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        if (covered(bound.items, p) or !runtime.exists(io, p)) continue;
        try bound.append(a, p);
        try argv.appendSlice(a, &.{ "--bind", p });
    }
    for (img.bind) |b| try argv.appendSlice(a, &.{ "--bind", b });
    try argv.append(a, img.image);
    try argv.appendSlice(a, inner);
    return argv.items;
}

/// Whether `path` is one of `dirs` or inside one.
fn covered(dirs: []const []const u8, path: []const u8) bool {
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
/// exports (`BASH_FUNC_module%%`, Lmod's `module`): what a container is
/// started with.
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

/// A cheap identity of a local image file for the rebuild check: its size
/// and modification time (hashing a multi-gigabyte image on every `zenv run`
/// would be too slow). Null for a URI or a file that cannot be read.
pub fn fingerprint(a: Allocator, io: Io, image: []const u8) !?[]const u8 {
    if (isUri(image)) return null;
    const st = Io.Dir.cwd().statFile(io, image, .{}) catch return null;
    return try std.fmt.allocPrint(a, "{d}:{d}", .{ st.size, st.mtime.nanoseconds });
}

// ============================ Tests ============================
const testing = std.testing;

test "fromConfig resolves a relative image against the project" {
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

test "execArgv binds existing paths once, then the env's binds and the image" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const root = ".zig-cache/tmp/zenv-container-argv-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/proj/.zenv/e");

    const img: Image = .{
        .image = "/img.sif",
        .options = &.{"--nv"},
        .bind = &.{"/data:/data:ro"},
    };
    const argv = try execArgv(
        a,
        io,
        img,
        &.{ root ++ "/proj", root ++ "/proj/.zenv/e", root ++ "/missing", root ++ "/proj" },
        &.{ "/zenv", "__exec" },
    );
    const want = [_][]const u8{
        "apptainer", "exec",           "--nv",     "--bind", root ++ "/proj",
        "--bind",    "/data:/data:ro", "/img.sif", "/zenv",  "__exec",
    };
    try testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try testing.expectEqualStrings(w, g);
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
