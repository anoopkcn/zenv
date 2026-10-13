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
const Map = std.process.Environ.Map;
const File = std.Io.File;
const runtime = @import("runtime.zig");
const output = @import("output.zig");
const envspec = @import("envspec.zig");
const venv = @import("venv.zig");
const shell = @import("shell.zig");
const python_mod = @import("python.zig");
const parse_deps = @import("parse_deps.zig");
const EnvironmentConfig = @import("config.zig").EnvironmentConfig;
const CommandFlags = @import("flags.zig").CommandFlags;

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
};

/// Builds the venv for `opts`. Failures are reported before returning
/// error.ProcessError (or a specific error `errors.report` explains).
pub fn run(allocator: Allocator, opts: Options) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const flags = opts.flags;
    const join = std.Io.Dir.path.join;

    info(a, "Setting up environment '{s}' in '{s}'...", .{ opts.env_name, opts.venv_dir });
    const deps = (try parse_deps.validateDependencies(a, opts.deps, opts.env_name)).items;
    // A Python-free env installs nothing, so it gets no requirements.txt.
    if (opts.env_config.python) try writeRequirements(a, opts.venv_dir, deps);

    banner(a, "started");

    // Copy the setup hook first so a bad path fails before any work is done.
    const setup_hook = try copySetupHook(a, opts);

    if (!opts.env_config.python) return runWithoutPython(a, opts, setup_hook);

    if (flags.use_default_python) info(a, "--python: using only the zenv-pinned Python", .{});
    if (flags.dev_mode) info(a, "--dev: will install the project as an editable package", .{});
    if (flags.no_cache) info(a, "--no-cache: package caches are disabled", .{});
    if (flags.use_uv) {
        const uv = try findExecutable(a, "uv", runtime.env("PATH")) orelse
            return fail(a, "'uv' command not found, but --uv was specified. Install uv or run without --uv.", .{});
        info(a, "Using {s}", .{std.mem.trim(u8, capture(a, &.{ uv, "--version" }, null) orelse "uv (version unknown)", " \n")});
    }

    const fallback = try fallbackPython(a, opts.env_config, flags);

    // Every child runs in `env`: zenv's own environment, then the module env.
    var env = try runtime.environ_map.clone(a);
    const modules_present = try loadModules(a, opts, &env);

    var module_python: ?[]const u8 = null;
    var module_pkgs: []const Package = &.{};
    if (modules_present) {
        module_python = try workingPython(a, &env);
        module_pkgs = try modulePackages(a, &env);
    }

    const chosen = try selectPython(a, &env, fallback, flags.use_default_python, module_python);
    info(a, "Selected Python for venv: {s} ({s})", .{ chosen.description, chosen.path });
    if (capture(a, &.{ chosen.path, "--version" }, &env)) |v| info(a, "Version: {s}", .{std.mem.trim(u8, v, " \n")});

    try ensureVenv(a, opts.venv_dir, chosen, &env);

    // Activate for everything below.
    const venv_python = try join(a, &[_][]const u8{ opts.venv_dir, "bin", "python" });
    try env.put("VIRTUAL_ENV", opts.venv_dir);
    try env.put("ZENV_ENV_DIR", opts.venv_dir);
    try envspec.applyOp(&env, .{ .op = .prepend, .name = "PATH", .value = try join(a, &[_][]const u8{ opts.venv_dir, "bin" }) });
    _ = env.orderedRemove("PYTHONHOME");
    // The env's own variables, so installs and hooks see what activation will.
    try applyUserEnv(a, opts, &env);

    if (!flags.use_uv) try seedPip(a, &env, venv_python, chosen);

    try env.put("PYTHONDONTWRITEBYTECODE", "1");
    // uv's build-isolation subprocesses would inherit the module stack's
    // PYTHONPATH and can pick up stale setuptools plugins from it (e.g. pbr ->
    // ModuleNotFoundError: pkg_resources). uv never needs module packages to
    // resolve or install, so it runs without PYTHONPATH. The pip path keeps it:
    // it uses --no-build-isolation and relies on module-provided build deps.
    var uv_env = try env.clone(a);
    _ = uv_env.orderedRemove("PYTHONPATH");
    const install_env = if (flags.use_uv) &uv_env else &env;

    info(a, "Ensuring pip is up to date in the venv", .{});
    const upgrade_pip: []const []const u8 = if (flags.use_uv) &.{ "--upgrade", "pip" } else &.{ "--ignore-installed", "--no-build-isolation", "--upgrade", "pip" };
    try install(a, opts, venv_python, install_env, upgrade_pip, "upgrading pip");

    const plan = try planInstall(a, deps, module_pkgs, flags.force_deps);
    try installRequirements(a, opts, venv_python, install_env, plan);

    if (flags.dev_mode) try installEditable(a, opts, venv_python, install_env);

    _ = env.orderedRemove("PYTHONDONTWRITEBYTECODE");
    try runHooks(a, opts, &env, setup_hook);

    if (plan.overrides.len > 0) try printOverrides(a, &env, venv_python, plan.overrides);

    banner(a, "completed");
}

/// Setup for an env with `"python": false`: modules, a bin/ for the project's
/// own tools, and the hooks; no interpreter, venv or installs. A venv left
/// from when the env had Python is refused rather than taken apart, since its
/// bin/ mixes installed entry points with the user's own files.
fn runWithoutPython(a: Allocator, opts: Options, setup_hook: ?[]const u8) !void {
    info(a, "\"python\": false: building without a Python venv", .{});
    if (try hasPythonVenv(a, opts.venv_dir)) {
        return fail(a, "Environment '{s}' still has a Python venv in {s}, but zenv.json now says \"python\": false. Remove it with 'zenv rm {s}', then run 'zenv setup {s}'.", .{ opts.env_name, opts.venv_dir, opts.env_name, opts.env_name });
    }

    var env = try runtime.environ_map.clone(a);
    _ = try loadModules(a, opts, &env);

    const bin = try std.Io.Dir.path.join(a, &[_][]const u8{ opts.venv_dir, "bin" });
    runtime.makePath(bin) catch |err| return fail(a, "Could not create {s}: {s}", .{ bin, @errorName(err) });
    // Keep the env out of git, as venv.create does for a Python env.
    try runtime.writeFile(try std.Io.Dir.path.join(a, &[_][]const u8{ opts.venv_dir, ".gitignore" }), "# Created by zenv\n*\n");
    for (try envspec.plainOps(a, opts.venv_dir)) |op| try envspec.applyOp(&env, op);
    try applyUserEnv(a, opts, &env);

    try runHooks(a, opts, &env, setup_hook);
    banner(a, "completed");
}

/// Applies the `env` entries of zenv.json to `env`, as activation will.
fn applyUserEnv(a: Allocator, opts: Options, env: *Map) !void {
    for (try envspec.userOps(a, opts.env_config, opts.venv_dir, opts.project_dir)) |op| try envspec.applyOp(env, op);
}

/// Whether `venv_dir` holds any part of a Python venv. bin/ alone does not
/// count: a Python-free env has one too.
fn hasPythonVenv(a: Allocator, venv_dir: []const u8) !bool {
    for (PYTHON_PARTS) |p| {
        if (runtime.lexists(try std.Io.Dir.path.join(a, &[_][]const u8{ venv_dir, p }))) return true;
    }
    return false;
}

/// What venv creation adds besides bin/ (bin/python is its interpreter link).
const PYTHON_PARTS = [_][]const u8{ "bin/python", "lib", "lib64", "include", "pyvenv.cfg" };

// ---------------------------------------------------------------------------
// Output and process helpers
// ---------------------------------------------------------------------------

fn info(a: Allocator, comptime fmt: []const u8, args: anytype) void {
    output.print(a, fmt, args) catch {};
}

fn warn(a: Allocator, comptime fmt: []const u8, args: anytype) void {
    output.printWarning(a, fmt, args) catch {};
}

fn fail(a: Allocator, comptime fmt: []const u8, args: anytype) error{ProcessError} {
    output.printError(a, fmt, args) catch {};
    return error.ProcessError;
}

/// "=== Setup started at 2026-10-13 09:41:07 UTC ===" in the log and terminal.
fn banner(a: Allocator, what: []const u8) void {
    const secs: u64 = @intCast(@max(0, @divFloor(runtime.nowMillis(), 1000)));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    info(a, "=== Setup {s} at {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC ===", .{
        what,                 day.year,                md.month.numeric(),        md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// "exit status 7" / "signal 15" for error messages.
fn describe(a: Allocator, term: runtime.Term) []const u8 {
    return switch (term) {
        .exited => |c| a.print("exit status {d}", .{c}) catch "failed",
        .signal, .stopped => |sig| a.print("signal {d}", .{@backingInt(sig)}) catch "killed",
        .unknown => |s| a.print("status {d}", .{s}) catch "failed",
    };
}

/// Runs `argv` in `env` (cwd `cwd`) with stdout and stderr merged into one
/// pipe whose output goes to the terminal and the setup log. `argv[0]` is
/// resolved against `env`'s PATH.
fn runStep(a: Allocator, argv: []const []const u8, env: *const Map, cwd: ?[]const u8) !runtime.Term {
    const exe = try findExecutable(a, argv[0], env.get("PATH")) orelse
        return fail(a, "{s}: command not found", .{argv[0]});

    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const reader = File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const writer = File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer reader.close(runtime.io);

    var child = std.process.spawn(runtime.io, .{
        .exe = .{ .explicit = .{ .dir = std.Io.Dir.cwd(), .path = exe } },
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = env,
        .stdin = .inherit,
        .stdout = .{ .file = writer },
        .stderr = .{ .file = writer },
    }) catch |err| {
        writer.close(runtime.io);
        return fail(a, "Failed to start {s}: {s}", .{ exe, @errorName(err) });
    };
    // The child holds its own copies; ours must close for EOF to arrive.
    writer.close(runtime.io);

    // EOF alone cannot end the copy loop: a background process the child
    // started (e.g. `daemon &` in setup.commands) inherits the pipe and keeps
    // it open after the child exits. So wait for the child on another thread
    // and, once it is gone, stop as soon as the pipe goes quiet.
    const Waiter = struct {
        child: *std.process.Child,
        result: anyerror!runtime.Term = error.Unexpected,
        done: std.atomic.Value(bool) = .init(false),
        fn wait(self: *@This()) void {
            self.result = self.child.wait(runtime.io);
            self.done.store(true, .release);
        }
    };
    var waiter = Waiter{ .child = &child };
    const thread = std.Thread.spawn(.{}, Waiter.wait, .{&waiter}) catch |err| {
        // Killing (not waiting) also reaps it: a child blocked on the full
        // pipe would never exit for a plain wait.
        child.kill(runtime.io);
        return err;
    };

    var buf: [8192]u8 = undefined;
    var pfd = [_]std.posix.pollfd{.{ .fd = reader.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    var drained_after_exit: usize = 0;
    while (true) {
        const exited = waiter.done.load(.acquire);
        // Bounded drain after exit, so a chatty leftover process cannot keep us here.
        if (exited) {
            drained_after_exit += 1;
            if (drained_after_exit > 1024) break;
        }
        const ready = std.posix.poll(&pfd, if (exited) 0 else 100) catch break;
        if (ready == 0) {
            if (exited) break;
            continue;
        }
        // EndOfStream once every holder of the write end has closed it.
        const n = reader.readStreaming(runtime.io, &.{&buf}) catch break;
        output.passthrough(buf[0..n]) catch {};
    }
    thread.join();
    return waiter.result;
}

/// Stdout of `argv` (absolute argv[0]) when it exits 0, else null.
fn capture(a: Allocator, argv: []const []const u8, env: ?*const Map) ?[]const u8 {
    const res = runtime.run(a, argv, .{
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .environ_map = env,
    }) catch return null;
    if (!runtime.exitedOk(res.term)) return null;
    return res.stdout;
}

/// Like `command -v`: a name with '/' must be an executable file; a bare name
/// is searched in `path_value`. Null when not found.
fn findExecutable(a: Allocator, name: []const u8, path_value: ?[]const u8) !?[]const u8 {
    if (std.mem.findScalar(u8, name, '/') != null) {
        return if (envspec.isExecutableFile(name)) name else null;
    }
    return envspec.resolveCommand(a, name, path_value);
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
    var before = std.StringHashMap([]const u8).init(a);
    for (base) |e| try before.put(e.name, e.value);

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

/// Makes `env` the module environment: reuses the cache when the module set and
/// system are unchanged, else purges and loads in bash and captures a new
/// cache. Returns false when there is no module system.
fn loadModules(a: Allocator, opts: Options, env: *Map) !bool {
    if (!moduleSystemAvailable(env)) {
        info(a, "Module command not found, skipping module operations", .{});
        return false;
    }
    const cfg = opts.env_config;
    const modules = cfg.modules.items;
    const cache_active = cfg.module_cache and modules.len > 0;
    const sig = if (cache_active) try envspec.modulesSignature(a, modules) else "";
    const system: ?[]const u8 = envspec.currentSystem(a) catch null;

    // Reuse: same module set on the same system. Like activation, this does
    // not purge first.
    if (cache_active and !opts.flags.force_deps) reuse: {
        const cache = envspec.readModuleCache(a, opts.venv_dir) orelse break :reuse;
        const sys = system orelse break :reuse;
        if (cache.version != envspec.MODULE_CACHE_VERSION or cache.untrusted) break :reuse;
        if (!std.mem.eql(u8, cache.system, sys) or !std.mem.eql(u8, cache.modules_sig, sig)) break :reuse;
        for (cache.ops) |op| try envspec.applyOp(env, op);
        info(a, "Module set unchanged; reusing cached module environment (skipping module purge/load)", .{});
        return true;
    }

    const snap_path = try std.Io.Dir.path.join(a, &[_][]const u8{ opts.venv_dir, ".zenv_module_snapshot" });
    defer runtime.deleteFile(snap_path) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "/bin/bash", "-c", MODULE_SCRIPT, "zenv-modules", snap_path });
    try argv.appendSlice(a, modules);

    const term = try runStep(a, argv.items, env, opts.project_dir);
    if (term == .exited and term.exited == 3) {
        info(a, "Module command not found, skipping module operations", .{});
        return false;
    }
    if (!runtime.exitedOk(term)) return fail(a, "Loading modules failed ({s}).", .{describe(a, term)});

    const data = runtime.readFileAlloc(a, snap_path, 64 * 1024 * 1024) catch |err|
        return fail(a, "Could not read the module environment snapshot: {s}", .{@errorName(err)});
    const snap = parseSnapshot(a, data) catch
        return fail(a, "The module environment snapshot is malformed.", .{});

    // The child environment becomes the loaded one, keeping zenv's own values
    // for shell bookkeeping variables.
    var next = Map.init(a);
    for (snap.loaded) |e| {
        if (!isOneOf(e.name, &VOLATILE)) try next.put(e.name, e.value);
    }
    for (VOLATILE) |name| if (env.get(name)) |v| try next.put(name, v);
    env.* = next;

    if (snap.failed.len > 0) {
        // A missing module would otherwise give a "working" env without it, and
        // every activation would retry (and re-report) the failed load.
        envspec.deleteModuleCache(a, opts.venv_dir);
        return fail(a, "Failed to load module(s): {s}. Check the names in zenv.json ('module spider <name>') and re-run setup.", .{try std.mem.join(a, ", ", snap.failed)});
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
    envspec.writeModuleCache(a, opts.venv_dir, &cache) catch |err| {
        warn(a, "Failed to write the module cache: {s}", .{@errorName(err)});
        return true;
    };
    if (cache.untrusted) {
        info(a, "Module cache written but marked untrusted; activation will fall back to 'module load'.", .{});
    } else {
        info(a, "Module environment cache written ({d} changes)", .{delta.ops.len});
    }
    return true;
}

/// The python3 (else python) on the module env's PATH, if it runs.
fn workingPython(a: Allocator, env: *const Map) !?[]const u8 {
    for ([_][]const u8{ "python3", "python" }) |name| {
        const path = try findExecutable(a, name, env.get("PATH")) orelse continue;
        info(a, "Found Python in PATH after loading modules: {s}", .{path});
        if (capture(a, &.{ path, "--version" }, env)) |v| {
            info(a, "Python version: {s}", .{std.mem.trim(u8, v, " \n")});
            return path;
        }
        warn(a, "Python executable exists but failed to get version. It may be misconfigured.", .{});
        return null;
    }
    warn(a, "No Python found in PATH after loading modules.", .{});
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
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name == null and std.ascii.eqlIgnoreCase(key, "Name")) name = value;
        if (version == null and std.ascii.eqlIgnoreCase(key, "Version")) version = value;
    }
    return .{ .name = name orelse return null, .version = version orelse return null };
}

/// The leading part of a metadata file: enough for the headers without reading
/// a long description. Null when unreadable.
fn readMetadataHead(a: Allocator, path: []const u8) ?[]const u8 {
    var file = runtime.openFile(path, .{}) catch return null;
    defer file.close(runtime.io);
    const buf = a.alloc(u8, 64 * 1024) catch return null;
    const n = file.readPositionalAll(runtime.io, buf, 0) catch return null;
    return buf[0..n];
}

/// Distributions importable from the directories on `python_path`, in
/// PYTHONPATH order (the first of a name wins, as for the interpreter). Looks
/// where importlib.metadata looks on a path entry: `*.dist-info/METADATA`,
/// `*.egg-info/PKG-INFO` or an `*.egg-info` file, and an unzipped `*.egg`
/// entry's `EGG-INFO/PKG-INFO`. Unreadable entries are skipped.
pub fn scanPythonPath(a: Allocator, python_path: []const u8) ![]const Package {
    const join = std.Io.Dir.path.join;
    var pkgs: std.ArrayList(Package) = .empty;
    var seen = std.StringHashMap(void).init(a);

    var entries = std.mem.splitScalar(u8, python_path, ':');
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        var candidates: std.ArrayList([]const u8) = .empty;
        if (std.mem.endsWith(u8, entry, ".egg")) {
            try candidates.append(a, try join(a, &[_][]const u8{ entry, "EGG-INFO", "PKG-INFO" }));
        } else {
            var dir = runtime.openDir(entry, .{ .iterate = true }) catch continue;
            defer dir.close(runtime.io);
            var it = dir.iterate();
            while (it.next(runtime.io) catch null) |e| {
                if (std.mem.endsWith(u8, e.name, ".dist-info")) {
                    try candidates.append(a, try join(a, &[_][]const u8{ entry, e.name, "METADATA" }));
                } else if (std.mem.endsWith(u8, e.name, ".egg-info")) {
                    // A directory holds PKG-INFO; a plain file is the metadata itself.
                    const inner = try join(a, &[_][]const u8{ entry, e.name, "PKG-INFO" });
                    const path = try join(a, &[_][]const u8{ entry, e.name });
                    try candidates.append(a, if (isFile(path)) path else inner);
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
            const pkg = parseMetadata(readMetadataHead(a, path) orelse continue) orelse continue;
            const key = try parse_deps.canonicalName(a, pkg.name);
            if (seen.contains(key)) continue;
            try seen.put(key, {});
            try pkgs.append(a, pkg);
        }
    }
    return pkgs.items;
}

/// Packages the modules provide *to the venv*: those on the module env's
/// PYTHONPATH. The module Python's own site-packages do not count: the venv is
/// created with include-system-site-packages = false and cannot import them,
/// so such dependencies must still be installed.
fn modulePackages(a: Allocator, env: *const Map) ![]const Package {
    info(a, "Checking Python packages the modules provide on PYTHONPATH", .{});
    const pkgs = try scanPythonPath(a, env.get("PYTHONPATH") orelse "");
    if (pkgs.len == 0) {
        info(a, "No Python packages detected from modules", .{});
        return pkgs;
    }
    var names: std.Io.Writer.Allocating = .init(a);
    for (pkgs, 0..) |p, i| {
        if (i > 0) try names.writer.writeAll(", ");
        try names.writer.writeAll(p.name);
    }
    info(a, "Found packages from modules: {s}", .{names.written()});
    return pkgs;
}

// ---------------------------------------------------------------------------
// Interpreter and venv
// ---------------------------------------------------------------------------

/// The fallback interpreter: the zenv-pinned Python with --python (required),
/// else `fallback_python` from zenv.json, else the pinned Python, else none.
fn fallbackPython(a: Allocator, cfg: *const EnvironmentConfig, flags: CommandFlags) !?[]const u8 {
    const join = std.Io.Dir.path.join;
    if (flags.use_default_python) {
        const pinned = python_mod.getDefaultPythonPath(a) catch |err| {
            output.printError(a, "Failed to read default Python path with --python flag: {s}", .{@errorName(err)}) catch {};
            return error.MissingPythonExecutable;
        } orelse {
            output.printError(a, "--python flag specified but no default Python configured", .{}) catch {};
            output.printError(a, "Set a default Python first: zenv python pin <version>", .{}) catch {};
            return error.MissingPythonExecutable;
        };
        const py = try join(a, &[_][]const u8{ pinned, "bin", "python3" });
        info(a, "Using default Python from ZENV_DIR/default-python: {s}", .{py});
        return py;
    }
    if (cfg.fallback_python) |py| return py;
    const pinned = python_mod.getDefaultPythonPath(a) catch |err| {
        warn(a, "Failed to get default Python path: {s}", .{@errorName(err)});
        return null;
    };
    return if (pinned) |p| try join(a, &[_][]const u8{ p, "bin", "python3" }) else null;
}

const Chosen = struct { path: []const u8, description: []const u8 };

/// The interpreter for the venv, in zenv's documented priority: --python's
/// pinned Python; the module Python; `fallback`; python3; python.
fn selectPython(a: Allocator, env: *const Map, fallback: ?[]const u8, use_default: bool, module_python: ?[]const u8) !Chosen {
    const path = env.get("PATH");
    if (use_default) {
        // fallbackPython always returns the pinned Python with --python.
        if (try findExecutable(a, fallback.?, path)) |p| return .{ .path = p, .description = "default configured Python (from --python flag)" };
        return fail(a, "Default Python ({s}) not found or invalid, but --python flag was specified.", .{fallback.?});
    }
    if (module_python) |p| return .{ .path = p, .description = "module-provided Python" };
    if (fallback) |f| {
        if (try findExecutable(a, f, path)) |p| return .{ .path = p, .description = "fallback Python" };
    }
    if (try findExecutable(a, "python3", path)) |p| return .{ .path = p, .description = "system python3" };
    if (try findExecutable(a, "python", path)) |p| return .{ .path = p, .description = "system python" };
    return fail(a, "Failed to find a suitable Python executable. Please ensure Python is installed and in PATH.", .{});
}

fn isFile(path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(runtime.io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Keeps a working venv; otherwise clears any partial one and creates it.
fn ensureVenv(a: Allocator, venv_dir: []const u8, chosen: Chosen, env: *const Map) !void {
    const join = std.Io.Dir.path.join;
    const py = try join(a, &[_][]const u8{ venv_dir, "bin", "python" });
    const act = try join(a, &[_][]const u8{ venv_dir, "bin", "activate" });
    if (isFile(py) and isFile(act)) {
        info(a, "Using existing valid virtual environment {s}.", .{venv_dir});
        return;
    }

    // A bin/ without the other parts is a Python-free env gaining Python:
    // venv.create fills it in and keeps the user's files there.
    if (try hasPythonVenv(a, venv_dir)) {
        info(a, "Existing venv {s} seems corrupted/incomplete. Clearing it and recreating.", .{venv_dir});
        for ([_][]const u8{ "bin", "lib", "lib64", "include", "pyvenv.cfg" }) |p| {
            const path = try join(a, &[_][]const u8{ venv_dir, p });
            if (!runtime.lexists(path)) continue;
            // A file or link (lib64), else a directory. A part that cannot be
            // removed would leave stale links behind, so fail instead.
            runtime.deleteFile(path) catch runtime.deleteTree(path) catch |err|
                return fail(a, "Could not remove {s}: {s}", .{ path, @errorName(err) });
        }
    }

    info(a, "Creating virtual environment in {s} using {s} ({s})...", .{ venv_dir, chosen.description, chosen.path });
    venv.create(a, chosen.path, venv_dir, env) catch |err|
        return fail(a, "Failed to create the virtual environment: {s}", .{@errorName(err)});
}

/// Installs pip into a venv that has none (zenv-made venvs start without it).
/// Only for pip mode; with --uv, the pip upgrade step installs it.
fn seedPip(a: Allocator, env: *const Map, venv_python: []const u8, chosen: Chosen) !void {
    if (capture(a, &.{ venv_python, "-m", "pip", "--version" }, env) != null) return;
    info(a, "Installing pip into the venv", .{});
    if (capture(a, &.{ venv_python, "-c", "import ensurepip" }, env) != null) {
        const t = try runStep(a, &.{ venv_python, "-m", "ensurepip", "--upgrade", "--default-pip" }, env, null);
        if (!runtime.exitedOk(t)) return fail(a, "ensurepip failed to install pip into the venv.", .{});
    } else if (capture(a, &.{ chosen.path, "-m", "pip", "--version" }, env) != null) {
        const t = try runStep(a, &.{ chosen.path, "-m", "pip", "--python", venv_python, "install", "pip" }, env, null);
        if (!runtime.exitedOk(t)) return fail(a, "Could not install pip with {s}'s pip (needs pip >= 22.3). Re-run with --uv.", .{chosen.description});
    } else {
        return fail(a, "{s} has neither ensurepip nor pip, so pip cannot be installed into the venv. Re-run with --uv.", .{chosen.description});
    }
}

// ---------------------------------------------------------------------------
// Installs
// ---------------------------------------------------------------------------

/// The installer argv: `uv pip install [--no-cache] --link-mode=copy ARGS` or
/// `<venv python> -m pip install [--no-cache-dir] ARGS`.
pub fn installerArgv(a: Allocator, venv_python: []const u8, use_uv: bool, no_cache: bool, args: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    if (use_uv) {
        try argv.appendSlice(a, &.{ "uv", "pip", "install" });
        if (no_cache) try argv.append(a, "--no-cache");
        try argv.append(a, "--link-mode=copy");
    } else {
        try argv.appendSlice(a, &.{ venv_python, "-m", "pip", "install" });
        if (no_cache) try argv.append(a, "--no-cache-dir");
    }
    try argv.appendSlice(a, args);
    return argv.items;
}

fn install(a: Allocator, opts: Options, venv_python: []const u8, env: *const Map, args: []const []const u8, what: []const u8) !void {
    const argv = try installerArgv(a, venv_python, opts.flags.use_uv, opts.flags.no_cache, args);
    const t = try runStep(a, argv, env, opts.project_dir);
    if (!runtime.exitedOk(t)) return fail(a, "Installation failed while {s}.", .{what});
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
    var provided = std.StringHashMap([]const u8).init(a); // canonical name -> version
    for (module_pkgs) |p| try provided.put(try parse_deps.canonicalName(a, p.name), p.version);
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

fn installRequirements(a: Allocator, opts: Options, venv_python: []const u8, env: *const Map, plan: Plan) !void {
    if (opts.flags.force_deps) {
        info(a, "Using --force: installing all specified dependencies", .{});
    } else {
        for (plan.overrides) |o| info(a, "Excluding '{s}' (provided by loaded modules as {s}=={s})", .{ o.requirement, o.name, o.module_version });
    }
    if (plan.install.len == 0) {
        info(a, "No dependencies to install.", .{});
        return;
    }
    info(a, "Installing {d} package(s) ({d} provided by modules)", .{ plan.install.len, plan.overrides.len });

    // Passed as a file so requirement lines keep their exact syntax.
    const path = try std.Io.Dir.path.join(a, &[_][]const u8{ opts.venv_dir, "requirements.install.txt" });
    var text: std.Io.Writer.Allocating = .init(a);
    for (plan.install) |line| try text.writer.print("{s}\n", .{line});
    try runtime.writeFile(path, text.written());
    defer runtime.deleteFile(path) catch {};

    try install(a, opts, venv_python, env, &.{ "-r", path }, "installing dependencies");
}

/// Writes the validated dependencies to `<venv_dir>/requirements.txt`, the
/// record of what setup installed.
fn writeRequirements(a: Allocator, venv_dir: []const u8, deps: []const []const u8) !void {
    const path = try std.Io.Dir.path.join(a, &[_][]const u8{ venv_dir, "requirements.txt" });
    info(a, "Writing {d} validated dependencies to {s}", .{ deps.len, path });
    var text: std.Io.Writer.Allocating = .init(a);
    if (deps.len == 0) {
        info(a, "Warning: No valid dependencies found! Writing only a comment to requirements file.", .{});
        try text.writer.writeAll("# No valid dependencies found\n");
    }
    for (deps) |dep| try text.writer.print("{s}\n", .{dep});
    try runtime.writeFile(path, text.written());
    info(a, "Created requirements file: {s}", .{path});
}

fn installEditable(a: Allocator, opts: Options, venv_python: []const u8, env: *const Map) !void {
    info(a, "Installing the project as an editable package", .{});
    const join = std.Io.Dir.path.join;
    if (!isFile(try join(a, &[_][]const u8{ opts.project_dir, "setup.py" })) and
        !isFile(try join(a, &[_][]const u8{ opts.project_dir, "pyproject.toml" })))
    {
        warn(a, "No setup.py or pyproject.toml found in {s}; skipping editable install.", .{opts.project_dir});
        return;
    }
    const args: []const []const u8 = if (opts.flags.use_uv) &.{ "--editable", ".", "--no-deps" } else &.{ "--no-build-isolation", "--editable", ".", "--no-deps" };
    const argv = try installerArgv(a, venv_python, opts.flags.use_uv, opts.flags.no_cache, args);
    const t = try runStep(a, argv, env, opts.project_dir);
    if (runtime.exitedOk(t)) {
        info(a, "Installed the project as an editable package", .{});
    } else {
        warn(a, "Editable install failed; check setup.py / pyproject.toml. Continuing without it.", .{});
    }
}

// ---------------------------------------------------------------------------
// Hooks and summary
// ---------------------------------------------------------------------------

/// Copies setup.script into `<venv>/scripts/setup_hook.sh`. A configured hook
/// that cannot be copied is a hard error: the env would silently diverge from
/// zenv.json.
fn copySetupHook(a: Allocator, opts: Options) !?[]const u8 {
    const setup = opts.env_config.setup orelse return null;
    const src = setup.script orelse return null;
    return shell.copyHookScript(a, src, opts.venv_dir, "setup_hook.sh", opts.project_dir) catch |err|
        return fail(a, "Failed to copy setup script '{s}': {s}", .{ src, @errorName(err) });
}

/// Runs setup.commands (under `set -e`) and then setup.script in one bash, in
/// the activated env, from the project directory. A failing command fails
/// setup; a failing hook script only warns.
fn runHooks(a: Allocator, opts: Options, env: *const Map, hook: ?[]const u8) !void {
    const commands: []const []const u8 = if (opts.env_config.setup) |s| (if (s.commands) |c| c.items else &.{}) else &.{};
    if (commands.len == 0 and hook == null) return;

    var script: std.Io.Writer.Allocating = .init(a);
    const w = &script.writer;
    try w.writeAll("set -e\n");
    if (commands.len > 0) {
        info(a, "Running custom setup commands", .{});
        for (commands) |cmd| try w.print("{s}\n", .{cmd});
    }
    if (hook) |path| {
        // `set +e`: bash 3.2 (macOS /bin/bash) otherwise aborts inside the
        // sourced file despite the `||`; bash 5 already ignores -e there.
        try w.writeAll("set +e\necho 'INFO: Running setup script: ");
        try shell.appendSqEscaped(w, path);
        try w.writeAll("'\n. '");
        try shell.appendSqEscaped(w, path);
        try w.writeAll("' || echo \"WARNING: Setup script failed with exit code $?\"\n");
    }
    const t = try runStep(a, &.{ "/bin/bash", "-c", script.written() }, env, opts.project_dir);
    if (!runtime.exitedOk(t)) return fail(a, "Custom setup commands failed ({s}).", .{describe(a, t)});
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

fn printOverrides(a: Allocator, env: *const Map, venv_python: []const u8, overrides: []const Override) !void {
    info(a, "Dependencies provided by loaded modules (used instead of your requirements):", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ venv_python, "-c", OVERRIDE_SCRIPT });
    for (overrides) |o| try argv.appendSlice(a, &.{ o.name, o.requirement, o.module_version });
    const t = runStep(a, argv.items, env, null) catch null;
    if (t == null or !runtime.exitedOk(t.?)) {
        for (overrides) |o| info(a, "    {s}  {s}  {s}", .{ o.name, o.requirement, o.module_version });
    }
    info(a, "STATUS 'CONFLICT' means the module version does not satisfy your requirement.", .{});
    info(a, "You can keep using the module-provided package as-is. If you require the exact", .{});
    info(a, "version, unload the corresponding module and re-run 'zenv setup' to install it.", .{});
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
    const test_support = @import("../test_support.zig");
    test_support.setupRuntime();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".zig-cache/tmp/zenv-scan-pythonpath-test";
    runtime.deleteTree(root) catch {};
    defer runtime.deleteTree(root) catch {};
    const files = [_][2][]const u8{
        .{ root ++ "/first/numpy-1.26.4.dist-info/METADATA", "Name: numpy\nVersion: 1.26.4\n" },
        .{ root ++ "/first/old_pkg-0.1-py3.9.egg-info/PKG-INFO", "Name: old-pkg\nVersion: 0.1\n" },
        .{ root ++ "/first/flat.egg-info", "Name: flat\nVersion: 2.0\n" },
        .{ root ++ "/first/broken-1.0.dist-info/RECORD", "" }, // no METADATA: skipped
        .{ root ++ "/second/NumPy-2.0.dist-info/METADATA", "Name: NumPy\nVersion: 2.0\n" }, // shadowed
        .{ root ++ "/third/legacy-3.0-py3.9.egg/EGG-INFO/PKG-INFO", "Name: legacy\nVersion: 3.0\n" },
    };
    for (files) |f| {
        try runtime.makePath(std.Io.Dir.path.dirname(f[0]).?);
        try runtime.writeFile(f[0], f[1]);
    }

    const pp = root ++ "/first::" ++ root ++ "/missing:" ++ root ++ "/second:" ++ root ++ "/third/legacy-3.0-py3.9.egg";
    const pkgs = try scanPythonPath(a, pp);
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
    const uv = try installerArgv(a, "/v/bin/python", true, true, &.{ "-r", "f" });
    const want_uv = [_][]const u8{ "uv", "pip", "install", "--no-cache", "--link-mode=copy", "-r", "f" };
    try testing.expectEqual(want_uv.len, uv.len);
    for (want_uv, uv) |w, g| try testing.expectEqualStrings(w, g);

    const pip = try installerArgv(a, "/v/bin/python", false, false, &.{ "--upgrade", "pip" });
    const want_pip = [_][]const u8{ "/v/bin/python", "-m", "pip", "install", "--upgrade", "pip" };
    try testing.expectEqual(want_pip.len, pip.len);
    for (want_pip, pip) |w, g| try testing.expectEqualStrings(w, g);
}

test "hasPythonVenv: bin/ alone is a Python-free env, any venv part is not" {
    const test_support = @import("../test_support.zig");
    test_support.setupRuntime();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".zig-cache/tmp/zenv-has-python-venv-test";
    runtime.deleteTree(root) catch {};
    defer runtime.deleteTree(root) catch {};
    try runtime.makePath(root ++ "/bin");
    try runtime.writeFile(root ++ "/bin/hello", "#!/bin/sh\n");
    try testing.expect(!try hasPythonVenv(a, root));

    try runtime.writeFile(root ++ "/pyvenv.cfg", "home = /usr/bin\n");
    try testing.expect(try hasPythonVenv(a, root));
    try runtime.deleteFile(root ++ "/pyvenv.cfg");
    try runtime.writeFile(root ++ "/bin/python", "");
    try testing.expect(try hasPythonVenv(a, root));
}

test "runWithoutPython keeps bin/ and refuses a leftover Python venv" {
    const test_support = @import("../test_support.zig");
    test_support.setupRuntime();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = ".zig-cache/tmp/zenv-run-without-python-test";
    runtime.deleteTree(root) catch {};
    defer runtime.deleteTree(root) catch {};
    try runtime.makePath(root ++ "/bin");
    try runtime.writeFile(root ++ "/bin/hello", "#!/bin/sh\n");

    var cfg = EnvironmentConfig.init(a);
    cfg.python = false;
    const opts = Options{ .env_config = &cfg, .env_name = "plain", .venv_dir = root, .project_dir = ".", .deps = &.{}, .flags = .{} };

    // No module system in the test environment and no hooks: only bin/ is made.
    try runWithoutPython(a, opts, null);
    try runtime.access(root ++ "/bin/hello");
    try runtime.access(root ++ "/.gitignore");
    try testing.expect(!try hasPythonVenv(a, root));

    // The env had Python before: refused, nothing removed.
    try runtime.makePath(root ++ "/lib");
    try testing.expectError(error.ProcessError, runWithoutPython(a, opts, null));
    try runtime.access(root ++ "/lib");
    try runtime.access(root ++ "/bin/hello");
}
