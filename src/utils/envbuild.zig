//! Builds an environment's venv: module loading, interpreter choice, venv
//! creation, pip/uv installs and the user's setup hooks.
//!
//! This replaces the bash setup script zenv used to generate and run. Two
//! steps still go through a shell, by necessity:
//!   - `module purge` / `module load`: `module` is a shell function. One
//!     `bash -c` loads the modules and writes `env -0` snapshots from before
//!     and after; their difference becomes the module cache.
//!   - the user's `setup.commands` / `setup.script`, which are shell code.
//! Child output (pip, uv, Lmod) is merged through one pipe and copied to the
//! terminal and the setup log, as the old script's `exec > >(tee ...) 2>&1` did.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Map = std.process.Environ.Map;
const File = std.Io.File;
const runtime = @import("runtime.zig");
const Ctx = runtime.Ctx;
const output = @import("output.zig");
const envspec = @import("envspec.zig");
const venv = @import("venv.zig");
const shell = @import("shell.zig");
const python_mod = @import("python.zig");
const parse_deps = @import("parse_deps.zig");
const EnvironmentConfig = @import("config.zig").EnvironmentConfig;
const flags_mod = @import("flags.zig");
const CommandFlags = flags_mod.CommandFlags;
const Installer = flags_mod.Installer;

pub const Options = struct {
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    /// Absolute venv directory.
    venv_dir: []const u8,
    /// Absolute project directory (where zenv.json is): the cwd for installs
    /// (`--dev` installs `.`) and hooks.
    project_dir: []const u8,
    /// Dependency lines, in requirements.txt syntax; run drops invalid and
    /// duplicate ones.
    deps: []const []const u8,
    flags: CommandFlags,
    /// The project's requires-python, checked against the venv's interpreter
    /// before the venv is made. Null: no check.
    requires_python: ?RequiresPython = null,
    /// Path of the uv that installs run; null: pip. `run` sets it
    /// (`resolveUv`) before modules are purged and loaded: a uv from a module
    /// the env does not load would be gone by then.
    uv: ?[]const u8 = null,
};

pub const RequiresPython = struct {
    /// PEP 440 specifiers, e.g. ">=3.10, <4".
    spec: []const u8,
    /// The pyproject.toml it came from, for messages.
    file: []const u8,
};

/// Builds the venv for `opts`. Failures are reported before returning
/// error.ProcessError (or a specific error `errors.report` explains).
/// Allocates with `c.arena`.
pub fn run(c: Ctx, options: Options) !void {
    const a = c.arena;
    var opts = options;
    const flags = opts.flags;
    const join = Io.Dir.path.join;

    info(c, "Setting up environment '{s}' in '{s}'...", .{ opts.env_name, opts.venv_dir });
    const deps = (try parse_deps.validateDependencies(a, c.io, opts.deps, opts.env_name)).items;
    // A Python-free env installs nothing, so it gets no requirements.txt.
    if (opts.env_config.python) try writeRequirements(c, opts.venv_dir, deps);

    banner(c, "started");

    // Copy the setup hook first so a bad path fails before any work is done.
    const setup_hook = try copySetupHook(c, opts);

    if (!opts.env_config.python) return runWithoutPython(c, opts, setup_hook);

    if (flags.use_default_python) info(c, "--python: using only the zenv-pinned Python", .{});
    if (flags.dev_mode) info(c, "--dev: will install the project as an editable package", .{});
    if (flags.no_cache) info(c, "--no-cache: package caches are disabled", .{});
    opts.uv = try resolveUv(c, flags.installer());
    if (opts.uv) |uv| {
        info(c, "Using {s}", .{std.mem.trim(u8, capture(c, &.{ uv, "--version" }, null) orelse "uv (version unknown)", " \n")});
    } else if (flags.use_pip) {
        info(c, "--pip: installing with pip", .{});
    }
    const use_uv = opts.uv != null;

    const fallback = try fallbackPython(c, opts.env_config, flags);

    // Every child runs in `env`: zenv's own environment, then the module env.
    var env = try c.env.clone(a);
    const modules_present = try loadModules(c, opts, &env);

    var module_python: ?[]const u8 = null;
    var module_pkgs: []const Package = &.{};
    if (modules_present) {
        module_python = try workingPython(c, &env);
        module_pkgs = try modulePackages(c, &env);
    }

    const chosen = try selectPython(c, &env, fallback, flags.use_default_python, module_python);
    info(c, "Selected Python for venv: {s} ({s})", .{ chosen.description, chosen.path });
    const chosen_version = capture(c, &.{ chosen.path, "--version" }, &env);
    if (chosen_version) |v| info(c, "Version: {s}", .{std.mem.trim(u8, v, " \n")});
    if (opts.requires_python) |rp| try checkRequiresPython(c, opts, &env, chosen, chosen_version, rp);

    try ensureVenv(c, opts.venv_dir, chosen, &env);

    // Activate for everything below.
    const venv_python = try join(a, &.{ opts.venv_dir, "bin", "python" });
    try env.put("VIRTUAL_ENV", opts.venv_dir);
    try env.put("ZENV_ENV_DIR", opts.venv_dir);
    try envspec.applyOp(&env, .{ .op = .prepend, .name = "PATH", .value = try join(a, &.{ opts.venv_dir, "bin" }) });
    _ = env.orderedRemove("PYTHONHOME");
    // The env's own variables, so installs and hooks see what activation will.
    try applyUserEnv(a, opts, &env);

    if (!use_uv) try seedPip(c, &env, venv_python, chosen);

    try env.put("PYTHONDONTWRITEBYTECODE", "1");
    // uv's build-isolation subprocesses would inherit the module stack's
    // PYTHONPATH and can pick up stale setuptools plugins from it (e.g. pbr ->
    // ModuleNotFoundError: pkg_resources). uv never needs module packages to
    // resolve or install, so it runs without PYTHONPATH. The pip path keeps it:
    // it uses --no-build-isolation and relies on module-provided build deps.
    var uv_env = try env.clone(a);
    _ = uv_env.orderedRemove("PYTHONPATH");
    const install_env = if (use_uv) &uv_env else &env;

    // uv installs pip only when it is missing (a new venv still gets the
    // current one): `--upgrade` would make uv ask the index for the newest pip
    // on every setup, about 0.1 s.
    info(c, "Ensuring pip is {s} the venv", .{if (use_uv) "in" else "up to date in"});
    const pip_args: []const []const u8 = if (use_uv) &.{"pip"} else &.{ "--ignore-installed", "--no-build-isolation", "--upgrade", "pip" };
    try install(c, opts, venv_python, install_env, pip_args, "installing pip");

    const plan = try planInstall(a, deps, module_pkgs, flags.force_deps);
    try installRequirements(c, opts, venv_python, install_env, plan);

    if (flags.dev_mode) try installEditable(c, opts, venv_python, install_env);

    _ = env.orderedRemove("PYTHONDONTWRITEBYTECODE");
    try runHooks(c, opts, &env, setup_hook);

    if (plan.overrides.len > 0) try printOverrides(c, &env, venv_python, plan.overrides);

    banner(c, "completed");
}

/// Setup for an env with `"python": false`: modules, a bin/ for the project's
/// own tools, and the hooks; no interpreter, venv or installs. A venv left
/// from when the env had Python is refused rather than taken apart, since its
/// bin/ mixes installed entry points with the user's own files.
fn runWithoutPython(c: Ctx, opts: Options, setup_hook: ?[]const u8) !void {
    const a = c.arena;
    const cwd = Io.Dir.cwd();
    info(c, "\"python\": false: building without a Python venv", .{});
    if (try hasPythonVenv(c, opts.venv_dir)) {
        return fail(c, "Environment '{s}' still has a Python venv in {s}, but zenv.json now says \"python\": false. Remove it with 'zenv rm {s}', then run 'zenv setup {s}'.", .{ opts.env_name, opts.venv_dir, opts.env_name, opts.env_name });
    }

    var env = try c.env.clone(a);
    _ = try loadModules(c, opts, &env);

    const bin = try Io.Dir.path.join(a, &.{ opts.venv_dir, "bin" });
    cwd.createDirPath(c.io, bin) catch |err| return fail(c, "Could not create {s}: {t}", .{ bin, err });
    // Keep the env out of git, as venv.create does for a Python env.
    try cwd.writeFile(c.io, .{ .sub_path = try Io.Dir.path.join(a, &.{ opts.venv_dir, ".gitignore" }), .data = "# Created by zenv\n*\n" });
    for (try envspec.plainOps(a, opts.venv_dir)) |op| try envspec.applyOp(&env, op);
    try applyUserEnv(a, opts, &env);

    try runHooks(c, opts, &env, setup_hook);
    banner(c, "completed");
}

/// Applies the `env` entries of zenv.json to `env`, as activation will.
fn applyUserEnv(a: Allocator, opts: Options, env: *Map) !void {
    for (try envspec.userOps(a, opts.env_config, opts.venv_dir, opts.project_dir)) |op| try envspec.applyOp(env, op);
}

/// Whether `venv_dir` holds any part of a Python venv. bin/ alone does not
/// count: a Python-free env has one too.
fn hasPythonVenv(c: Ctx, venv_dir: []const u8) !bool {
    for (PYTHON_PARTS) |p| {
        if (runtime.lexists(c.io, try Io.Dir.path.join(c.arena, &.{ venv_dir, p }))) return true;
    }
    return false;
}

/// What venv creation adds besides bin/ (bin/python is its interpreter link).
const PYTHON_PARTS = [_][]const u8{ "bin/python", "lib", "lib64", "include", "pyvenv.cfg" };

// ---------------------------------------------------------------------------
// Output and process helpers
// ---------------------------------------------------------------------------

fn info(c: Ctx, comptime fmt: []const u8, args: anytype) void {
    output.print(c.io, fmt, args);
}

fn warn(c: Ctx, comptime fmt: []const u8, args: anytype) void {
    output.printWarning(c.io, fmt, args);
}

fn fail(c: Ctx, comptime fmt: []const u8, args: anytype) error{ProcessError} {
    output.printError(c.io, fmt, args);
    return error.ProcessError;
}

/// "=== Setup started at 2026-10-13 09:41:07 UTC ===" in the log and terminal.
fn banner(c: Ctx, what: []const u8) void {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, Io.Clock.real.now(c.io).toSeconds())) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    info(c, "=== Setup {s} at {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC ===", .{
        what,                 day.year,                md.month.numeric(),        md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// Runs `argv` in `env` (cwd `cwd`) with stdout and stderr merged into one
/// pipe whose output goes to the terminal and the setup log. `argv[0]` is
/// resolved against `env`'s PATH.
fn runStep(c: Ctx, argv: []const []const u8, env: *const Map, cwd: ?[]const u8) !runtime.Term {
    const io = c.io;
    const exe = try findExecutable(c, argv[0], env.get("PATH")) orelse
        return fail(c, "{s}: command not found", .{argv[0]});

    // One pipe for both streams keeps their interleaving. std.Io has no pipe
    // of its own, nor a "stderr to stdout" option for spawn.
    const fds = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const reader: File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const writer: File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer reader.close(io);

    var child = std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = Io.Dir.cwd(), .path = exe } },
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
        .environ_map = env,
        .stdout = .{ .file = writer },
        .stderr = .{ .file = writer },
    }) catch |err| {
        writer.close(io);
        return fail(c, "Failed to start {s}: {t}", .{ exe, err });
    };
    // The child holds its own copies; ours must close for EOF to arrive.
    writer.close(io);

    // EOF alone cannot end the copy loop: a background process the child
    // started (e.g. `daemon &` in setup.commands) inherits the pipe and keeps
    // it open after the child exits. So wait for the child concurrently and,
    // once it is gone, stop as soon as the pipe goes quiet.
    var exited: std.atomic.Value(bool) = .init(false);
    var waiting = io.concurrent(waitChild, .{ io, &child, &exited }) catch |err| {
        // Killing (not waiting) also reaps it: a child blocked on the full
        // pipe would never exit for a plain wait.
        child.kill(io);
        return err;
    };
    defer _ = waiting.cancel(io) catch {};

    var buf: [8192]u8 = undefined;
    var drained_after_exit: usize = 0;
    while (true) {
        const done = exited.load(.acquire);
        // Bounded drain after exit, so a chatty leftover process cannot keep us here.
        if (done) {
            drained_after_exit += 1;
            if (drained_after_exit > 1024) break;
        }
        const quiet: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(if (done) 0 else 100), .clock = .awake } };
        const result = io.operateTimeout(.{ .file_read_streaming = .{ .file = reader, .data = &.{&buf} } }, quiet) catch |err| switch (err) {
            error.Timeout => if (done) break else continue,
            else => break,
        };
        // EndOfStream once every holder of the write end has closed it.
        const n = result.file_read_streaming catch break;
        output.passthrough(io, buf[0..n]);
    }
    return waiting.await(io);
}

fn waitChild(io: Io, child: *std.process.Child, exited: *std.atomic.Value(bool)) std.process.Child.WaitError!runtime.Term {
    defer exited.store(true, .release);
    return child.wait(io);
}

/// Stdout of `argv` (absolute argv[0]) when it exits 0, else null.
fn capture(c: Ctx, argv: []const []const u8, env: ?*const Map) ?[]const u8 {
    const res = runtime.run(c.arena, c.io, argv, .{
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .environ_map = env,
    }) catch return null;
    if (!res.term.success()) return null;
    return res.stdout;
}

/// Like `command -v`: a name with '/' must be an executable file; a bare name
/// is searched in `path_value`. Null when not found.
fn findExecutable(c: Ctx, name: []const u8, path_value: ?[]const u8) !?[]const u8 {
    if (std.mem.findScalar(u8, name, '/') != null) {
        return if (envspec.isExecutableFile(c.io, name)) name else null;
    }
    return envspec.resolveCommand(c.arena, c.io, name, path_value);
}

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

/// Purges and loads the modules, recording `env -0` snapshots before and after
/// the loads into the file "$1". If `module` is not an exported bash function
/// but Lmod is initialised ($LMOD_CMD, e.g. for zsh users), it is defined the
/// way Lmod defines it. Exit 3: no module system.
const MODULE_SCRIPT =
    \\snap=$1; shift
    \\if ! command -v module >/dev/null 2>&1; then
    \\  if [ -n "${LMOD_CMD:-}" ]; then
    \\    module() { eval "$("$LMOD_CMD" bash "$@")"; }
    \\  else
    \\    exit 3
    \\  fi
    \\fi
    \\exec 3>"$snap"
    \\echo "INFO: Purging all modules"
    \\module --force purge || echo "WARNING: Failed to purge modules, continuing anyway" >&2
    \\printf 'ZENV:BASE\0' >&3; env -0 >&3
    \\for m in "$@"; do
    \\  echo "INFO: Loading module: '$m'"
    \\  if module load "$m"; then
    \\    echo "INFO: Successfully loaded module: $m"
    \\  else
    \\    echo "WARNING: Failed to load module '$m'" >&2
    \\    printf 'ZENV:FAILED\0%s\0' "$m" >&3
    \\  fi
    \\done
    \\printf 'ZENV:LOADED\0' >&3; env -0 >&3
    \\if [ "$#" -gt 0 ]; then
    \\  echo "INFO: Currently loaded modules:"
    \\  module list 2>&1
    \\fi
    \\exit 0
;

pub const Entry = struct { name: []const u8, value: []const u8 };

pub const Snapshot = struct {
    base: []const Entry,
    loaded: []const Entry,
    failed: []const []const u8,
};

/// Parses MODULE_SCRIPT's snapshot file: NUL-separated tokens, where the
/// markers `ZENV:BASE` / `ZENV:LOADED` start a list of `NAME=VALUE` entries and
/// `ZENV:FAILED` is followed by a module name. Entries always contain '=', so
/// they cannot be mistaken for markers.
pub fn parseSnapshot(a: Allocator, data: []const u8) !Snapshot {
    var base: std.ArrayList(Entry) = .empty;
    var loaded: std.ArrayList(Entry) = .empty;
    var failed: std.ArrayList([]const u8) = .empty;
    var target: ?*std.ArrayList(Entry) = null;
    var saw_loaded = false;

    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "ZENV:BASE")) {
            target = &base;
        } else if (std.mem.eql(u8, tok, "ZENV:LOADED")) {
            target = &loaded;
            saw_loaded = true;
        } else if (std.mem.eql(u8, tok, "ZENV:FAILED")) {
            try failed.append(a, it.next() orelse "");
        } else {
            const eq = std.mem.findScalar(u8, tok, '=') orelse return error.InvalidSnapshot;
            const list = target orelse return error.InvalidSnapshot;
            try list.append(a, .{ .name = tok[0..eq], .value = tok[eq + 1 ..] });
        }
    }
    if (!saw_loaded) return error.InvalidSnapshot;
    return .{ .base = base.items, .loaded = loaded.items, .failed = failed.items };
}

/// Shell bookkeeping that differs between any two snapshots; never cached and
/// never carried into the child environment.
const VOLATILE = [_][]const u8{ "_", "SHLVL", "PWD", "OLDPWD", "PS1", "PPID", "BASHPID", "RANDOM", "SECONDS", "LINENO", "COLUMNS", "LINES" };

/// Path lists replayed as prepends, so activation keeps the live login value.
const PATH_VARS = [_][]const u8{ "PATH", "LD_LIBRARY_PATH", "LIBRARY_PATH", "CPATH", "MANPATH", "PKG_CONFIG_PATH" };

fn isOneOf(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub const Delta = struct { ops: []const envspec.Op, untrusted: bool };

/// What `module load` changed, as replayable ops: for path lists, what was put
/// in front of the previous value becomes a prepend and what was put after it
/// an append (a list that no longer contains the previous value is prepended
/// whole); everything else a set. Exported shell functions are skipped.
/// A changed variable whose name is not a shell identifier cannot be replayed
/// by activate.sh, so it marks the capture untrusted. Variables that the load
/// removed are not recorded (as before).
pub fn moduleDelta(a: Allocator, base: []const Entry, loaded: []const Entry) !Delta {
    var before: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (base) |e| try before.put(a, e.name, e.value);

    var ops: std.ArrayList(envspec.Op) = .empty;
    var untrusted = false;
    for (loaded) |e| {
        if (std.mem.startsWith(u8, e.name, "BASH_FUNC_")) continue;
        if (isOneOf(e.name, &VOLATILE)) continue;
        const prev = before.get(e.name);
        if (prev != null and std.mem.eql(u8, prev.?, e.value)) continue;
        if (!envspec.isIdentifier(e.name)) {
            untrusted = true;
            continue;
        }
        if (isOneOf(e.name, &PATH_VARS)) {
            const split = splitAround(e.value, prev orelse "");
            if (split.before.len > 0) try ops.append(a, .{ .op = .prepend, .name = e.name, .value = split.before });
            if (split.after.len > 0) try ops.append(a, .{ .op = .append, .name = e.name, .value = split.after });
        } else {
            try ops.append(a, .{ .op = .set, .name = e.name, .value = e.value });
        }
    }
    return .{ .ops = ops.items, .untrusted = untrusted };
}

/// Splits a path list around an earlier value of it: `X:base:Y` gives
/// before = X, after = Y. `base` must appear as whole components; when it does
/// not (or is empty), the whole value counts as `before`.
fn splitAround(value: []const u8, base: []const u8) struct { before: []const u8, after: []const u8 } {
    if (base.len == 0) return .{ .before = value, .after = "" };
    var from: usize = 0;
    while (std.mem.findPos(u8, value, from, base)) |i| : (from = i + 1) {
        const end = i + base.len;
        const starts_ok = i == 0 or value[i - 1] == ':';
        const ends_ok = end == value.len or value[end] == ':';
        if (!starts_ok or !ends_ok) continue;
        return .{
            .before = if (i == 0) "" else value[0 .. i - 1],
            .after = if (end == value.len) "" else value[end + 1 ..],
        };
    }
    return .{ .before = value, .after = "" };
}

fn moduleSystemAvailable(env: *const Map) bool {
    for ([_][]const u8{ "BASH_FUNC_module%%", "BASH_FUNC_module()", "LMOD_CMD" }) |name| {
        if (env.get(name)) |v| if (v.len > 0) return true;
    }
    return false;
}

/// Makes `env` the module environment: with --reuse-module-cache (what
/// auto-setup passes), reuses the cache when the module set and system are
/// unchanged; otherwise purges and loads in bash and captures a new cache, so
/// an explicit `zenv setup` picks up modules changed by site maintenance. Returns false when there is no module system.
fn loadModules(c: Ctx, opts: Options, env: *Map) !bool {
    const a = c.arena;
    if (!moduleSystemAvailable(env)) {
        info(c, "Module command not found, skipping module operations", .{});
        return false;
    }
    const cfg = opts.env_config;
    const modules = cfg.modules.items;
    const cache_active = cfg.module_cache and modules.len > 0;
    const sig = if (cache_active) try envspec.modulesSignature(a, modules) else "";
    const system: ?[]const u8 = envspec.currentSystem(a, c.io, c.env) catch null;

    // Reuse: same module set on the same system. Like activation, this does
    // not purge first.
    if (cache_active and opts.flags.reuse_module_cache and !opts.flags.force_deps) reuse: {
        const cache = envspec.readModuleCache(a, c.io, opts.venv_dir) orelse break :reuse;
        const sys = system orelse break :reuse;
        if (cache.version != envspec.MODULE_CACHE_VERSION or cache.untrusted) break :reuse;
        if (!std.mem.eql(u8, cache.system, sys) or !std.mem.eql(u8, cache.modules_sig, sig)) break :reuse;
        for (cache.ops) |op| try envspec.applyOp(env, op);
        info(c, "Module set unchanged; reusing cached module environment (skipping module purge/load)", .{});
        return true;
    }

    const snap_path = try Io.Dir.path.join(a, &.{ opts.venv_dir, ".zenv_module_snapshot" });
    defer Io.Dir.cwd().deleteFile(c.io, snap_path) catch {};
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ "/bin/bash", "-c", MODULE_SCRIPT, "zenv-modules", snap_path }, modules });

    const term = try runStep(c, argv, env, opts.project_dir);
    if (term == .exited and term.exited == 3) {
        info(c, "Module command not found, skipping module operations", .{});
        return false;
    }
    if (!term.success()) return fail(c, "Loading modules failed ({f}).", .{term});

    const data = Io.Dir.cwd().readFileAlloc(c.io, snap_path, a, .limited(64 * 1024 * 1024)) catch |err|
        return fail(c, "Could not read the module environment snapshot: {t}", .{err});
    const snap = parseSnapshot(a, data) catch
        return fail(c, "The module environment snapshot is malformed.", .{});

    // The child environment becomes the loaded one, keeping zenv's own values
    // for shell bookkeeping variables. A name `Map.put` would reject (empty,
    // or holding '=') cannot come from `env -0`; skip it rather than assert.
    var next = Map.init(a);
    for (snap.loaded) |e| {
        if (Map.validateKeyForPut(e.name) and !isOneOf(e.name, &VOLATILE)) try next.put(e.name, e.value);
    }
    for (VOLATILE) |name| if (env.get(name)) |v| try next.put(name, v);
    env.* = next;

    if (snap.failed.len > 0) {
        // A missing module would otherwise give a "working" env without it, and
        // every activation would retry (and re-report) the failed load.
        envspec.deleteModuleCache(a, c.io, opts.venv_dir);
        return fail(c, "Failed to load module(s): {s}. Check the names in zenv.json ('module spider <name>') and re-run setup.", .{try std.mem.join(a, ", ", snap.failed)});
    }
    if (!cache_active) return true;
    const delta = try moduleDelta(a, snap.base, snap.loaded);
    const cache = envspec.ModuleCache{
        .version = envspec.MODULE_CACHE_VERSION,
        .system = system orelse "",
        .untrusted = delta.untrusted or system == null,
        .modules_sig = sig,
        .ops = delta.ops,
    };
    envspec.writeModuleCache(a, c.io, opts.venv_dir, &cache) catch |err| {
        warn(c, "Failed to write the module cache: {t}", .{err});
        return true;
    };
    if (cache.untrusted) {
        info(c, "Module cache written but marked untrusted; activation will fall back to 'module load'.", .{});
    } else {
        info(c, "Module environment cache written ({d} changes)", .{delta.ops.len});
    }
    return true;
}

/// The python3 (else python) on the module env's PATH, if it runs.
fn workingPython(c: Ctx, env: *const Map) !?[]const u8 {
    for ([_][]const u8{ "python3", "python" }) |name| {
        const path = try findExecutable(c, name, env.get("PATH")) orelse continue;
        info(c, "Found Python in PATH after loading modules: {s}", .{path});
        if (capture(c, &.{ path, "--version" }, env)) |v| {
            info(c, "Python version: {s}", .{std.mem.trim(u8, v, " \n")});
            return path;
        }
        warn(c, "Python executable exists but failed to get version. It may be misconfigured.", .{});
        return null;
    }
    warn(c, "No Python found in PATH after loading modules.", .{});
    return null;
}

pub const Package = struct { name: []const u8, version: []const u8 };

/// Name and Version from core metadata (a dist-info METADATA or egg-info
/// PKG-INFO): RFC 822 style headers up to the first blank line. Lines that
/// start with whitespace continue the previous header (folding) and are never
/// read as headers themselves. Null when either field is missing.
pub fn parseMetadata(text: []const u8) ?Package {
    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break; // end of headers; the body is the description
        if (line[0] == ' ' or line[0] == '\t') continue; // folded continuation
        const key, const rest = std.mem.cutScalar(u8, line, ':') orelse continue;
        const value = std.mem.trim(u8, rest, " \t");
        if (name == null and std.ascii.eqlIgnoreCase(key, "Name")) name = value;
        if (version == null and std.ascii.eqlIgnoreCase(key, "Version")) version = value;
    }
    return .{ .name = name orelse return null, .version = version orelse return null };
}

/// The leading part of a metadata file, read into `buf`: enough for the
/// headers (Name and Version come first) without reading a long description.
/// Null when unreadable.
fn readMetadataHead(io: Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}

/// Distributions importable from the directories on `python_path`, in
/// PYTHONPATH order (the first of a name wins, as for the interpreter). Looks
/// where importlib.metadata looks on a path entry: `*.dist-info/METADATA`,
/// `*.egg-info/PKG-INFO` or an `*.egg-info` file, and an unzipped `*.egg`
/// entry's `EGG-INFO/PKG-INFO`. Unreadable entries are skipped.
pub fn scanPythonPath(a: Allocator, io: Io, python_path: []const u8) ![]const Package {
    const join = Io.Dir.path.join;
    var pkgs: std.ArrayList(Package) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var head_buf: [16 * 1024]u8 = undefined;

    var entries = std.mem.splitScalar(u8, python_path, ':');
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        var candidates: std.ArrayList([]const u8) = .empty;
        if (std.mem.endsWith(u8, entry, ".egg")) {
            try candidates.append(a, try join(a, &.{ entry, "EGG-INFO", "PKG-INFO" }));
        } else {
            var dir = Io.Dir.cwd().openDir(io, entry, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |e| {
                if (std.mem.endsWith(u8, e.name, ".dist-info")) {
                    try candidates.append(a, try join(a, &.{ entry, e.name, "METADATA" }));
                } else if (std.mem.endsWith(u8, e.name, ".egg-info")) {
                    // A directory holds PKG-INFO; a plain file is the metadata itself.
                    const inner = try join(a, &.{ entry, e.name, "PKG-INFO" });
                    const path = try join(a, &.{ entry, e.name });
                    try candidates.append(a, if (runtime.isFile(io, path)) path else inner);
                }
            }
            // Directory order is arbitrary; keep the result deterministic.
            std.mem.sort([]const u8, candidates.items, {}, struct {
                fn lessThan(_: void, l: []const u8, r: []const u8) bool {
                    return std.mem.lessThan(u8, l, r);
                }
            }.lessThan);
        }
        for (candidates.items) |path| {
            const pkg = parseMetadata(readMetadataHead(io, path, &head_buf) orelse continue) orelse continue;
            const gop = try seen.getOrPut(a, try parse_deps.canonicalName(a, pkg.name));
            if (gop.found_existing) continue;
            // `pkg` points into `head_buf`, which the next file overwrites.
            try pkgs.append(a, .{ .name = try a.dupe(u8, pkg.name), .version = try a.dupe(u8, pkg.version) });
        }
    }
    return pkgs.items;
}

/// Packages the modules provide *to the venv*: those on the module env's
/// PYTHONPATH. The module Python's own site-packages do not count: the venv is
/// created with include-system-site-packages = false and cannot import them,
/// so such dependencies must still be installed.
fn modulePackages(c: Ctx, env: *const Map) ![]const Package {
    info(c, "Checking Python packages the modules provide on PYTHONPATH", .{});
    const pkgs = try scanPythonPath(c.arena, c.io, env.get("PYTHONPATH") orelse "");
    if (pkgs.len == 0) {
        info(c, "No Python packages detected from modules", .{});
        return pkgs;
    }
    var names: Io.Writer.Allocating = .init(c.arena);
    for (pkgs, 0..) |p, i| {
        if (i > 0) try names.writer.writeAll(", ");
        try names.writer.writeAll(p.name);
    }
    info(c, "Found packages from modules: {s}", .{names.written()});
    return pkgs;
}

// ---------------------------------------------------------------------------
// Interpreter and venv
// ---------------------------------------------------------------------------

/// The fallback interpreter: the zenv-pinned Python with --python (required),
/// else `fallback_python` from zenv.json, else the pinned Python, else none.
fn fallbackPython(c: Ctx, cfg: *const EnvironmentConfig, flags: CommandFlags) !?[]const u8 {
    const join = Io.Dir.path.join;
    if (flags.use_default_python) {
        const pinned = python_mod.getDefaultPythonPath(c) catch |err| {
            output.printError(c.io, "Failed to read default Python path with --python flag: {t}", .{err});
            return error.MissingPythonExecutable;
        } orelse {
            output.printError(c.io, "--python flag specified but no default Python configured", .{});
            output.printError(c.io, "Set a default Python first: zenv python pin <version>", .{});
            return error.MissingPythonExecutable;
        };
        const py = try join(c.arena, &.{ pinned, "bin", "python3" });
        info(c, "Using default Python from ZENV_DIR/default-python: {s}", .{py});
        return py;
    }
    if (cfg.fallback_python) |py| return py;
    const pinned = python_mod.getDefaultPythonPath(c) catch |err| {
        warn(c, "Failed to get default Python path: {t}", .{err});
        return null;
    };
    return if (pinned) |p| try join(c.arena, &.{ p, "bin", "python3" }) else null;
}

const Chosen = struct {
    path: []const u8,
    description: []const u8,
    /// Which step of selectPython found it.
    source: enum { pinned, module, fallback, system },
};

/// The interpreter for the venv, in zenv's documented priority: --python's
/// pinned Python; the module Python; `fallback`; python3; python.
fn selectPython(c: Ctx, env: *const Map, fallback: ?[]const u8, use_default: bool, module_python: ?[]const u8) !Chosen {
    const path = env.get("PATH");
    if (use_default) {
        // fallbackPython always returns the pinned Python with --python.
        if (try findExecutable(c, fallback.?, path)) |p| return .{ .path = p, .description = "default configured Python (from --python flag)", .source = .pinned };
        return fail(c, "Default Python ({s}) not found or invalid, but --python flag was specified.", .{fallback.?});
    }
    if (module_python) |p| return .{ .path = p, .description = "module-provided Python", .source = .module };
    if (fallback) |f| {
        if (try findExecutable(c, f, path)) |p| return .{ .path = p, .description = "fallback Python", .source = .fallback };
    }
    if (try findExecutable(c, "python3", path)) |p| return .{ .path = p, .description = "system python3", .source = .system };
    if (try findExecutable(c, "python", path)) |p| return .{ .path = p, .description = "system python", .source = .system };
    return fail(c, "Failed to find a suitable Python executable. Please ensure Python is installed and in PATH.", .{});
}

/// Whether `venv_dir` holds a working venv, which ensureVenv keeps.
fn venvUsable(c: Ctx, venv_dir: []const u8) !bool {
    const join = Io.Dir.path.join;
    return runtime.isFile(c.io, try join(c.arena, &.{ venv_dir, "bin", "python" })) and
        runtime.isFile(c.io, try join(c.arena, &.{ venv_dir, "bin", "activate" }));
}

/// Keeps a working venv; otherwise clears any partial one and creates it.
fn ensureVenv(c: Ctx, venv_dir: []const u8, chosen: Chosen, env: *const Map) !void {
    if (try venvUsable(c, venv_dir)) {
        info(c, "Using existing valid virtual environment {s}.", .{venv_dir});
        return;
    }

    // A bin/ without the other parts is a Python-free env gaining Python:
    // venv.create fills it in and keeps the user's files there.
    if (try hasPythonVenv(c, venv_dir)) {
        info(c, "Existing venv {s} seems corrupted/incomplete. Clearing it and recreating.", .{venv_dir});
        for ([_][]const u8{ "bin", "lib", "lib64", "include", "pyvenv.cfg" }) |p| {
            const path = try Io.Dir.path.join(c.arena, &.{ venv_dir, p });
            // A file, a link (lib64, not followed) or a directory; a missing
            // one is fine. A part that cannot be removed would leave stale
            // links behind, so fail instead.
            Io.Dir.cwd().deleteTree(c.io, path) catch |err|
                return fail(c, "Could not remove {s}: {t}", .{ path, err });
        }
    }

    info(c, "Creating virtual environment in {s} using {s} ({s})...", .{ venv_dir, chosen.description, chosen.path });
    venv.create(c.arena, c.io, chosen.path, venv_dir, env) catch |err|
        return fail(c, "Failed to create the virtual environment: {t}", .{err});
}

/// Fails setup when the interpreter the venv will run on does not satisfy the
/// project's requires-python: the existing venv's, which ensureVenv keeps,
/// else `chosen`. It runs before the venv is made, so a failed setup leaves no
/// venv with the wrong Python behind. A version or specifier it cannot read
/// only warns.
fn checkRequiresPython(c: Ctx, opts: Options, env: *const Map, chosen: Chosen, chosen_version: ?[]const u8, rp: RequiresPython) !void {
    const a = c.arena;
    const io = c.io;
    const kept = try venvUsable(c, opts.venv_dir);
    const python = if (kept) try Io.Dir.path.join(a, &.{ opts.venv_dir, "bin", "python" }) else chosen.path;
    const out = std.mem.trim(u8, (if (kept) capture(c, &.{ python, "--version" }, env) else chosen_version) orelse "", " \r\n");
    const version = std.mem.cutPrefix(u8, out, "Python ") orelse {
        warn(c, "Could not read the version of {s}; skipping the requires-python check.", .{python});
        return;
    };
    const ok = python_mod.satisfies(rp.spec, version) catch {
        warn(c, "Cannot read requires-python '{s}' in {s}; skipping the check.", .{ rp.spec, rp.file });
        return;
    };
    if (ok) return info(c, "Python {s} satisfies requires-python '{s}' from {s}", .{ version, rp.spec, rp.file });

    const name = opts.env_name;
    if (kept) {
        return fail(c, "Environment '{s}' was created with Python {s}, but {s} requires Python '{s}'. Remove it with 'zenv rm {s}', then run 'zenv setup {s}' again with a matching Python.", .{ name, version, rp.file, rp.spec, name, name });
    }
    const use_pinned = opts.flags.use_default_python;
    output.printError(io, "{s} requires Python '{s}', but the selected interpreter, {s} ({s}), is Python {s}.", .{ rp.file, rp.spec, chosen.description, chosen.path, version });
    output.printError(io, "Make zenv select a matching Python, then run the setup again:", .{});

    // What makes selectPython pick another interpreter: a module Python wins
    // over all but --python, and fallback_python wins over the pinned Python.
    const modules_hint = "load a matching Python through \"modules\" in zenv.json ('module spider Python' lists the versions)";
    if (chosen.source == .module) {
        output.printError(io, "  - {s}", .{modules_hint});
        return error.ProcessError;
    }
    if (use_pinned or opts.env_config.fallback_python == null) {
        var matching: std.ArrayList([]const u8) = .empty;
        for (python_mod.installedVersions(c) catch &.{}) |v| {
            if (python_mod.satisfies(rp.spec, v) catch false) try matching.append(a, v);
        }
        if (matching.items.len > 0) {
            output.printError(io, "  - pin a matching Python zenv installed ({s}): zenv python pin {s}", .{ try std.mem.join(a, ", ", matching.items), matching.items[0] });
        } else {
            output.printError(io, "  - build one with zenv: zenv python install <version>, then zenv python pin <version>", .{});
        }
    }
    if (!use_pinned) {
        output.printError(io, "  - point \"fallback_python\" in zenv.json at a matching interpreter", .{});
        if (c.getEnv("LMOD_CMD") != null or c.getEnv("MODULESHOME") != null) output.printError(io, "  - {s}", .{modules_hint});
    }
    return error.ProcessError;
}

/// Installs pip into a venv that has none (zenv-made venvs start without it).
/// Only for pip mode; with uv, the pip upgrade step installs it.
fn seedPip(c: Ctx, env: *const Map, venv_python: []const u8, chosen: Chosen) !void {
    if (capture(c, &.{ venv_python, "-m", "pip", "--version" }, env) != null) return;
    info(c, "Installing pip into the venv", .{});
    if (capture(c, &.{ venv_python, "-c", "import ensurepip" }, env) != null) {
        const t = try runStep(c, &.{ venv_python, "-m", "ensurepip", "--upgrade", "--default-pip" }, env, null);
        if (!t.success()) return fail(c, "ensurepip failed to install pip into the venv.", .{});
    } else if (capture(c, &.{ chosen.path, "-m", "pip", "--version" }, env) != null) {
        const t = try runStep(c, &.{ chosen.path, "-m", "pip", "--python", venv_python, "install", "pip" }, env, null);
        if (!t.success()) return fail(c, "Could not install pip with {s}'s pip (needs pip >= 22.3). With uv on PATH (and no --pip), zenv installs with uv instead.", .{chosen.description});
    } else {
        return fail(c, "{s} has neither ensurepip nor pip, so pip cannot be installed into the venv. With uv on PATH (and no --pip), zenv installs with uv instead.", .{chosen.description});
    }
}

// ---------------------------------------------------------------------------
// Installs
// ---------------------------------------------------------------------------

/// The uv that installs packages for `choice`, from zenv's own PATH; null
/// means pip. `auto` takes uv when PATH has one and otherwise falls back to
/// pip; `uv` fails without one.
pub fn resolveUv(c: Ctx, choice: Installer) !?[]const u8 {
    if (choice == .pip) return null;
    if (try envspec.resolveCommand(c.arena, c.io, "uv", c.getEnv("PATH"))) |uv| return uv;
    if (choice == .uv) return fail(c, "'uv' command not found, but --uv was specified. Install uv, or drop --uv to fall back to pip.", .{});
    info(c, "'uv' not found on PATH; installing with pip", .{});
    return null;
}

/// The installer argv: `<uv> pip install [--no-cache] --link-mode=copy ARGS`
/// with `uv`, else `<venv python> -m pip install [--no-cache-dir] ARGS`.
pub fn installerArgv(a: Allocator, venv_python: []const u8, uv: ?[]const u8, no_cache: bool, args: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    if (uv) |exe| {
        try argv.appendSlice(a, &.{ exe, "pip", "install" });
        if (no_cache) try argv.append(a, "--no-cache");
        try argv.append(a, "--link-mode=copy");
    } else {
        try argv.appendSlice(a, &.{ venv_python, "-m", "pip", "install" });
        if (no_cache) try argv.append(a, "--no-cache-dir");
    }
    try argv.appendSlice(a, args);
    return argv.items;
}

fn install(c: Ctx, opts: Options, venv_python: []const u8, env: *const Map, args: []const []const u8, what: []const u8) !void {
    const argv = try installerArgv(c.arena, venv_python, opts.uv, opts.flags.no_cache, args);
    const t = try runStep(c, argv, env, opts.project_dir);
    if (!t.success()) return fail(c, "Installation failed while {s}.", .{what});
}

pub const Override = struct { name: []const u8, requirement: []const u8, module_version: []const u8 };
pub const Plan = struct { install: []const []const u8, overrides: []const Override };

/// The project name a requirement line starts with (`numpy>=1.26` -> numpy).
fn requirementName(line: []const u8) []const u8 {
    var end: usize = 0;
    while (end < line.len) : (end += 1) {
        const c = line[end];
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) break;
    }
    return line[0..end];
}

/// Splits `deps` into what to install and what the loaded modules already
/// provide (by normalised name). With `force`, everything is installed.
pub fn planInstall(a: Allocator, deps: []const []const u8, module_pkgs: []const Package, force: bool) !Plan {
    var to_install: std.ArrayList([]const u8) = .empty;
    var overrides: std.ArrayList(Override) = .empty;
    var provided: std.StringHashMapUnmanaged([]const u8) = .empty; // canonical name -> version
    for (module_pkgs) |p| try provided.put(a, try parse_deps.canonicalName(a, p.name), p.version);
    for (deps) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!force) {
            const name = try parse_deps.canonicalName(a, requirementName(line));
            if (name.len > 0) {
                if (provided.get(name)) |version| {
                    try overrides.append(a, .{ .name = name, .requirement = line, .module_version = version });
                    continue;
                }
            }
        }
        try to_install.append(a, line);
    }
    return .{ .install = to_install.items, .overrides = overrides.items };
}

fn installRequirements(c: Ctx, opts: Options, venv_python: []const u8, env: *const Map, plan: Plan) !void {
    if (opts.flags.force_deps) {
        info(c, "Using --force: installing all specified dependencies", .{});
    } else {
        for (plan.overrides) |o| info(c, "Excluding '{s}' (provided by loaded modules as {s}=={s})", .{ o.requirement, o.name, o.module_version });
    }
    if (plan.install.len == 0) {
        info(c, "No dependencies to install.", .{});
        return;
    }
    info(c, "Installing {d} package(s) ({d} provided by modules)", .{ plan.install.len, plan.overrides.len });

    // Passed as a file so requirement lines keep their exact syntax.
    const cwd = Io.Dir.cwd();
    const path = try Io.Dir.path.join(c.arena, &.{ opts.venv_dir, "requirements.install.txt" });
    try cwd.writeFile(c.io, .{ .sub_path = path, .data = try linesOf(c.arena, plan.install) });
    defer cwd.deleteFile(c.io, path) catch {};

    try install(c, opts, venv_python, env, &.{ "-r", path }, "installing dependencies");
}

/// `lines`, each ended by a newline.
fn linesOf(a: Allocator, lines: []const []const u8) ![]const u8 {
    var text: Io.Writer.Allocating = .init(a);
    for (lines) |line| try text.writer.print("{s}\n", .{line});
    return text.written();
}

/// Writes the validated dependencies to `<venv_dir>/requirements.txt`, the
/// record of what setup installed.
fn writeRequirements(c: Ctx, venv_dir: []const u8, deps: []const []const u8) !void {
    const path = try Io.Dir.path.join(c.arena, &.{ venv_dir, "requirements.txt" });
    info(c, "Writing {d} validated dependencies to {s}", .{ deps.len, path });
    const text = if (deps.len > 0) try linesOf(c.arena, deps) else blk: {
        info(c, "Warning: No valid dependencies found! Writing only a comment to requirements file.", .{});
        break :blk "# No valid dependencies found\n";
    };
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = text });
    info(c, "Created requirements file: {s}", .{path});
}

fn installEditable(c: Ctx, opts: Options, venv_python: []const u8, env: *const Map) !void {
    info(c, "Installing the project as an editable package", .{});
    const join = Io.Dir.path.join;
    if (!runtime.isFile(c.io, try join(c.arena, &.{ opts.project_dir, "setup.py" })) and
        !runtime.isFile(c.io, try join(c.arena, &.{ opts.project_dir, "pyproject.toml" })))
    {
        warn(c, "No setup.py or pyproject.toml found in {s}; skipping editable install.", .{opts.project_dir});
        return;
    }
    const args: []const []const u8 = if (opts.uv != null) &.{ "--editable", ".", "--no-deps" } else &.{ "--no-build-isolation", "--editable", ".", "--no-deps" };
    const argv = try installerArgv(c.arena, venv_python, opts.uv, opts.flags.no_cache, args);
    const t = try runStep(c, argv, env, opts.project_dir);
    if (t.success()) {
        info(c, "Installed the project as an editable package", .{});
    } else {
        warn(c, "Editable install failed; check setup.py / pyproject.toml. Continuing without it.", .{});
    }
}

// ---------------------------------------------------------------------------
// Hooks and summary
// ---------------------------------------------------------------------------

/// Copies setup.script into `<venv>/scripts/setup_hook.sh`. A configured hook
/// that cannot be copied is a hard error: the env would silently diverge from
/// zenv.json.
fn copySetupHook(c: Ctx, opts: Options) !?[]const u8 {
    const setup = opts.env_config.setup orelse return null;
    const src = setup.script orelse return null;
    return shell.copyHookScript(c.arena, c.io, src, opts.venv_dir, "setup_hook.sh", opts.project_dir) catch |err|
        return fail(c, "Failed to copy setup script '{s}': {t}", .{ src, err });
}

/// Runs setup.commands (under `set -e`) and then setup.script in one bash, in
/// the activated env, from the project directory. A failing command fails
/// setup; a failing hook script only warns.
fn runHooks(c: Ctx, opts: Options, env: *const Map, hook: ?[]const u8) !void {
    const commands: []const []const u8 = if (opts.env_config.setup) |s| (if (s.commands) |cmds| cmds.items else &.{}) else &.{};
    if (commands.len == 0 and hook == null) return;

    var script: Io.Writer.Allocating = .init(c.arena);
    const w = &script.writer;
    try w.writeAll("set -e\n");
    if (commands.len > 0) {
        info(c, "Running custom setup commands", .{});
        for (commands) |cmd| try w.print("{s}\n", .{cmd});
    }
    // `set +e`: bash 3.2 (macOS /bin/bash) otherwise aborts inside the
    // sourced file despite the `||`; bash 5 already ignores -e there.
    if (hook) |path| try w.print(
        \\set +e
        \\echo 'INFO: Running setup script: {0f}'
        \\. '{0f}' || echo "WARNING: Setup script failed with exit code $?"
        \\
    , .{shell.sq(path)});
    const t = try runStep(c, &.{ "/bin/bash", "-c", script.written() }, env, opts.project_dir);
    if (!t.success()) return fail(c, "Custom setup commands failed ({f}).", .{t});
}

/// Reports dependencies served by module packages, flagging versions that do
/// not satisfy the requirement. Runs in the venv's Python for `packaging`
/// (pip's vendored copy if needed); rows arrive as argv triples.
const OVERRIDE_SCRIPT =
    \\import sys
    \\def load():
    \\    for mod in ("packaging.requirements", "pip._vendor.packaging.requirements"):
    \\        try:
    \\            return __import__(mod, fromlist=["Requirement"]).Requirement
    \\        except Exception:
    \\            pass
    \\Requirement = load()
    \\args = sys.argv[1:]
    \\rows = []
    \\for i in range(0, len(args) - 2, 3):
    \\    name, req, ver = args[i], args[i + 1], args[i + 2]
    \\    spec, status = req, "?"
    \\    if Requirement is not None:
    \\        try:
    \\            r = Requirement(req)
    \\            spec = str(r.specifier) or "(any)"
    \\            status = "ok" if r.specifier.contains(ver, prereleases=True) else "CONFLICT"
    \\        except Exception:
    \\            pass
    \\    rows.append((name, spec, ver, status))
    \\headers = ("PACKAGE", "REQUIRED", "MODULE VERSION", "STATUS")
    \\widths = [max(len(str(r[i])) for r in [headers] + rows) for i in range(4)]
    \\fmt = lambda c: "    " + "  ".join(str(c[i]).ljust(widths[i]) for i in range(4))
    \\print(fmt(headers))
    \\for r in rows:
    \\    color = "\033[1;33m" if r[3] == "CONFLICT" else "\033[0;32m" if r[3] == "ok" else ""
    \\    print(color + fmt(r) + ("\033[0m" if color else ""))
;

fn printOverrides(c: Ctx, env: *const Map, venv_python: []const u8, overrides: []const Override) !void {
    info(c, "Dependencies provided by loaded modules (used instead of your requirements):", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.arena, &.{ venv_python, "-c", OVERRIDE_SCRIPT });
    for (overrides) |o| try argv.appendSlice(c.arena, &.{ o.name, o.requirement, o.module_version });
    const ok = if (runStep(c, argv.items, env, null)) |t| t.success() else |_| false;
    if (!ok) {
        for (overrides) |o| info(c, "    {s}  {s}  {s}", .{ o.name, o.requirement, o.module_version });
    }
    info(c, "STATUS 'CONFLICT' means the module version does not satisfy your requirement.", .{});
    info(c, "You can keep using the module-provided package as-is. If you require the exact", .{});
    info(c, "version, unload the corresponding module and re-run 'zenv setup' to install it.", .{});
}

// ============================ Tests ============================
const testing = std.testing;

test "parseSnapshot splits base, loaded and failed, keeping multi-line values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = "ZENV:BASE\x00PATH=/usr/bin\x00FZF=--a\n--b\x00ZENV:FAILED\x00bad/1\x00ZENV:LOADED\x00PATH=/m/bin:/usr/bin\x00FZF=--a\n--b\x00EMPTY=\x00";
    const s = try parseSnapshot(a, data);
    try testing.expectEqual(@as(usize, 2), s.base.len);
    try testing.expectEqualStrings("--a\n--b", s.base[1].value);
    try testing.expectEqual(@as(usize, 3), s.loaded.len);
    try testing.expectEqualStrings("", s.loaded[2].value);
    try testing.expectEqualStrings("bad/1", s.failed[0]);

    try testing.expectError(error.InvalidSnapshot, parseSnapshot(a, "ZENV:BASE\x00A=1\x00"));
    try testing.expectError(error.InvalidSnapshot, parseSnapshot(a, "A=1\x00ZENV:LOADED\x00"));
}

test "moduleDelta: prepends added path parts, sets changed vars, skips noise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_]Entry{
        .{ .name = "PATH", .value = "/usr/bin" },
        .{ .name = "SHLVL", .value = "1" },
        .{ .name = "KEEP", .value = "same" },
        .{ .name = "MANPATH", .value = "/m" },
        .{ .name = "CPATH", .value = "/base" },
    };
    const loaded = [_]Entry{
        .{ .name = "PATH", .value = "/gcc/bin:/usr/bin" },
        .{ .name = "LD_LIBRARY_PATH", .value = "/gcc/lib" },
        .{ .name = "SHLVL", .value = "2" },
        .{ .name = "KEEP", .value = "same" },
        .{ .name = "MANPATH", .value = "/other" }, // base gone: whole value prepended
        .{ .name = "CPATH", .value = "/inc:/base:/tail" }, // put on both sides
        .{ .name = "BANNER", .value = "line1\nline2" },
        .{ .name = "BASH_FUNC_module%%", .value = "() { :; }" },
    };
    const d = try moduleDelta(a, &base, &loaded);
    try testing.expect(!d.untrusted);
    try testing.expectEqual(@as(usize, 6), d.ops.len);
    try testing.expectEqualStrings("/gcc/bin", d.ops[0].value);
    try testing.expectEqual(envspec.OpKind.prepend, d.ops[1].op);
    try testing.expectEqualStrings("/gcc/lib", d.ops[1].value);
    try testing.expectEqualStrings("/other", d.ops[2].value);
    try testing.expectEqual(envspec.OpKind.prepend, d.ops[3].op);
    try testing.expectEqualStrings("/inc", d.ops[3].value);
    try testing.expectEqual(envspec.OpKind.append, d.ops[4].op);
    try testing.expectEqualStrings("/tail", d.ops[4].value);
    try testing.expectEqualStrings("line1\nline2", d.ops[5].value);

    // A component match only: "/us" is not the start of "/usr/bin".
    const s = splitAround("/usr/bin:/us", "/us");
    try testing.expectEqualStrings("/usr/bin", s.before);
    try testing.expectEqualStrings("", s.after);

    const odd = [_]Entry{.{ .name = "has-dash", .value = "x" }};
    try testing.expect((try moduleDelta(a, &.{}, &odd)).untrusted);
}

test "planInstall excludes module-provided packages by normalised name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deps = [_][]const u8{ "numpy>=1.26", "Scikit_Learn==1.5", "# comment", "", "requests" };
    const mods = [_]Package{ .{ .name = "numpy", .version = "1.26.4" }, .{ .name = "scikit-learn", .version = "1.4.0" } };

    const p = try planInstall(a, &deps, &mods, false);
    try testing.expectEqual(@as(usize, 1), p.install.len);
    try testing.expectEqualStrings("requests", p.install[0]);
    try testing.expectEqual(@as(usize, 2), p.overrides.len);
    try testing.expectEqualStrings("scikit-learn", p.overrides[1].name);
    try testing.expectEqualStrings("1.4.0", p.overrides[1].module_version);

    const forced = try planInstall(a, &deps, &mods, true);
    try testing.expectEqual(@as(usize, 3), forced.install.len);
    try testing.expectEqual(@as(usize, 0), forced.overrides.len);
}

test "parseMetadata reads Name and Version from the headers only" {
    const meta = "Metadata-Version: 2.1\r\nname: Zope.Interface\r\nVersion: 6.0\r\n\r\nName: not-a-header\n";
    const pkg = parseMetadata(meta).?;
    try testing.expectEqualStrings("Zope.Interface", pkg.name);
    try testing.expectEqualStrings("6.0", pkg.version);
    try testing.expect(parseMetadata("Metadata-Version: 2.1\nName: x\n\nVersion: 1\n") == null);
    // A folded header line is part of the previous header, not a header.
    const folded = parseMetadata("Name: real\nSummary: a summary that\n  Name: wraps onto a second line\nVersion: 2\n").?;
    try testing.expectEqualStrings("real", folded.name);
    try testing.expectEqualStrings("2", folded.version);
}

test "scanPythonPath finds dist-info, egg-info and eggs in PYTHONPATH order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    const root = ".zig-cache/tmp/zenv-scan-pythonpath-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    const files = [_][2][]const u8{
        .{ root ++ "/first/numpy-1.26.4.dist-info/METADATA", "Name: numpy\nVersion: 1.26.4\n" },
        .{ root ++ "/first/old_pkg-0.1-py3.9.egg-info/PKG-INFO", "Name: old-pkg\nVersion: 0.1\n" },
        .{ root ++ "/first/flat.egg-info", "Name: flat\nVersion: 2.0\n" },
        .{ root ++ "/first/broken-1.0.dist-info/RECORD", "" }, // no METADATA: skipped
        .{ root ++ "/second/NumPy-2.0.dist-info/METADATA", "Name: NumPy\nVersion: 2.0\n" }, // shadowed
        .{ root ++ "/third/legacy-3.0-py3.9.egg/EGG-INFO/PKG-INFO", "Name: legacy\nVersion: 3.0\n" },
    };
    for (files) |f| {
        try cwd.createDirPath(io, Io.Dir.path.dirname(f[0]).?);
        try cwd.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }

    const pp = root ++ "/first::" ++ root ++ "/missing:" ++ root ++ "/second:" ++ root ++ "/third/legacy-3.0-py3.9.egg";
    const pkgs = try scanPythonPath(a, io, pp);
    try testing.expectEqual(@as(usize, 4), pkgs.len);
    try testing.expectEqualStrings("flat", pkgs[0].name);
    try testing.expectEqualStrings("numpy", pkgs[1].name);
    try testing.expectEqualStrings("1.26.4", pkgs[1].version); // first on the path wins
    try testing.expectEqualStrings("old-pkg", pkgs[2].name);
    try testing.expectEqualStrings("legacy", pkgs[3].name);
}

test "installerArgv for uv and pip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uv = try installerArgv(a, "/v/bin/python", "/opt/uv/bin/uv", true, &.{ "-r", "f" });
    const want_uv = [_][]const u8{ "/opt/uv/bin/uv", "pip", "install", "--no-cache", "--link-mode=copy", "-r", "f" };
    try testing.expectEqual(want_uv.len, uv.len);
    for (want_uv, uv) |w, g| try testing.expectEqualStrings(w, g);

    const pip = try installerArgv(a, "/v/bin/python", null, false, &.{ "--upgrade", "pip" });
    const want_pip = [_][]const u8{ "/v/bin/python", "-m", "pip", "install", "--upgrade", "pip" };
    try testing.expectEqual(want_pip.len, pip.len);
    for (want_pip, pip) |w, g| try testing.expectEqualStrings(w, g);
}

test "hasPythonVenv: bin/ alone is a Python-free env, any venv part is not" {
    const test_support = @import("../test_support.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = test_support.ctx(arena.allocator(), &test_support.no_env);
    const io = c.io;
    const cwd = Io.Dir.cwd();

    const root = ".zig-cache/tmp/zenv-has-python-venv-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/bin");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/bin/hello", .data = "#!/bin/sh\n" });
    try testing.expect(!try hasPythonVenv(c, root));

    try cwd.writeFile(io, .{ .sub_path = root ++ "/pyvenv.cfg", .data = "home = /usr/bin\n" });
    try testing.expect(try hasPythonVenv(c, root));
    try cwd.deleteFile(io, root ++ "/pyvenv.cfg");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/bin/python", .data = "" });
    try testing.expect(try hasPythonVenv(c, root));
}

test "runWithoutPython keeps bin/ and refuses a leftover Python venv" {
    const test_support = @import("../test_support.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = test_support.ctx(a, &test_support.no_env);
    const io = c.io;
    const cwd = Io.Dir.cwd();

    const root = ".zig-cache/tmp/zenv-run-without-python-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/bin");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/bin/hello", .data = "#!/bin/sh\n" });

    var cfg = EnvironmentConfig.init(a);
    cfg.python = false;
    const opts = Options{ .env_config = &cfg, .env_name = "plain", .venv_dir = root, .project_dir = ".", .deps = &.{}, .flags = .{} };

    // No module system in the test environment and no hooks: only bin/ is made.
    try runWithoutPython(c, opts, null);
    try cwd.access(io, root ++ "/bin/hello", .{});
    try cwd.access(io, root ++ "/.gitignore", .{});
    try testing.expect(!try hasPythonVenv(c, root));

    // The env had Python before: refused, nothing removed.
    try cwd.createDirPath(io, root ++ "/lib");
    try testing.expectError(error.ProcessError, runWithoutPython(c, opts, null));
    try cwd.access(io, root ++ "/lib", .{});
    try cwd.access(io, root ++ "/bin/hello", .{});
}

test "runStep copies merged output and is not held up by a background child" {
    const test_support = @import("../test_support.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var env = Map.init(arena.allocator());
    try env.put("PATH", "/usr/bin:/bin");
    const c = test_support.ctx(arena.allocator(), &env);

    const start = Io.Timestamp.now(c.io, .awake);
    const term = try runStep(c, &.{ "sh", "-c", "echo out; echo err >&2; (sleep 5; echo late) & exit 7" }, &env, null);
    try testing.expectEqual(runtime.Term{ .exited = 7 }, term);
    try testing.expect(start.untilNow(c.io, .awake).toSeconds() < 4);
}
