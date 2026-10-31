//! Starting a command inside an env, the way `zenv run` does.
//!
//! One interface, `start`, over three adapters, picked per env:
//!   - container: the env runs in an Apptainer image, so `zenv __exec` is
//!     started there and applies the env inside it;
//!   - direct: this process's environment with `zenv-env.json` applied, the
//!     command resolved on the resulting PATH, no shell;
//!   - activate.sh: bash sources the env's activation script, then execs the
//!     command. Used when the direct launch cannot reproduce activation
//!     (activate hooks, a module cache that does not fit) or when
//!     ZENV_RUN_SHELL=1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const activation = @import("activation.zig");
const container = @import("container.zig");
const envspec = @import("envspec.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const Ctx = runtime.Ctx;

/// How `start` starts the command: as a child it waits for, or in place of
/// zenv (exec), in which case it returns only if the command did not start.
pub const Mode = enum { wait, replace };

/// Starts `command` inside the environment at `venv_path` with inherited stdio,
/// as `mode` says; with `.wait` it returns the command's `Term`. An env with
/// a container is started in its image (`execInContainer`). Otherwise uses the
/// direct launch when `zenv-env.json` can reproduce activation, else sources
/// activate.sh through bash.
pub fn start(
    ctx: Ctx,
    venv_path: []const u8,
    command: []const u8,
    command_args: []const []const u8,
    mode: Mode,
) !runtime.Term {
    if (!container.inside(ctx.env)) if (containerOf(ctx, venv_path)) |img| {
        return execInContainer(ctx, img, venv_path, command, command_args, mode);
    };
    if (try execDirect(ctx, venv_path, command, command_args, mode)) |term| return term;

    const activate_path = try Io.Dir.path.join(
        ctx.arena,
        &.{ venv_path, activation.fileName(.sh) },
    );
    const argv = try buildRunArgv(ctx.arena, activate_path, command, command_args);
    return startCommand(ctx.io, argv, .{}, mode);
}

/// The container an env runs in, from its `zenv-env.json`; null for an env
/// without one (or without a readable spec). Allocated in the arena.
pub fn containerOf(ctx: Ctx, venv_path: []const u8) ?container.Image {
    // Not deinit: the image's strings live on in the arena.
    const parsed = envspec.read(ctx.arena, ctx.io, venv_path) orelse return null;
    return parsed.value.container;
}

/// Starts `command` in the env's container: `zenv __exec` there applies the
/// env to the container's environment and starts it (`commands.handleExecInside`).
/// The host's Python settings stay outside (`container.hostEnv`).
fn execInContainer(
    ctx: Ctx,
    img: container.Image,
    venv_path: []const u8,
    command: []const u8,
    command_args: []const []const u8,
    mode: Mode,
) !runtime.Term {
    const a = ctx.arena;
    const io = ctx.io;
    const self_exe = try std.process.executablePathAlloc(io, a);
    const inner = try std.mem.concat(a, []const u8, &.{
        &.{ self_exe, "__exec", venv_path, command },
        command_args,
    });
    const argv = try container.execArgv(a, io, img, &.{ img.project_dir, venv_path, self_exe }, inner);
    var env = try container.hostEnv(a, ctx.env);
    const exe = try envspec.resolveCommand(a, io, argv[0], env.get("PATH")) orelse {
        output.printError(io, "apptainer: command not found (the environment runs in {s})", .{img.image});
        return .{ .exited = 127 };
    };
    return startCommand(io, argv, .{ .environ_map = &env, .exe_path = exe }, mode);
}

fn startCommand(
    io: Io,
    argv: []const []const u8,
    opts: runtime.ExecOptions,
    mode: Mode,
) !runtime.Term {
    return switch (mode) {
        .wait => runtime.exec(io, argv, opts),
        .replace => runtime.replace(io, argv, opts),
    };
}

/// Direct launch: copy this process's environment, apply `zenv-env.json`,
/// resolve `command` against the resulting PATH and start it, no shell
/// involved. Returns null (caller falls back to bash) when the spec is missing
/// or `envspec.directReason` reports a blocker, or when ZENV_RUN_SHELL=1.
fn execDirect(
    ctx: Ctx,
    venv_path: []const u8,
    command: []const u8,
    command_args: []const []const u8,
    mode: Mode,
) !?runtime.Term {
    const io = ctx.io;
    const allocator = ctx.arena;
    if (ctx.getEnv("ZENV_RUN_SHELL")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            output.debug(io, "run: ZENV_RUN_SHELL=1, using activate.sh", .{});
            return null;
        }
    }
    var child_env = try environ(ctx, venv_path) orelse return null;

    const exe = try envspec.resolveCommand(allocator, io, command, child_env.get("PATH")) orelse {
        // Same status bash's `exec` gives for an unknown command.
        output.printError(io, "{s}: command not found", .{command});
        return .{ .exited = 127 };
    };
    output.debug(io, "run: direct launch of {s}", .{exe});

    const argv = try std.mem.concat(allocator, []const u8, &.{ &.{command}, command_args });
    return try startCommand(io, argv, .{ .environ_map = &child_env, .exe_path = exe }, mode);
}

/// This process's environment with `zenv-env.json` applied: what a direct
/// launch in the env runs with, and what `zenv add` resolves packages in.
/// Null when the spec is missing or `envspec.directReason` reports a blocker
/// (activate.sh is needed then).
pub fn environ(ctx: Ctx, venv_path: []const u8) !?std.process.Environ.Map {
    const io = ctx.io;
    const allocator = ctx.arena;
    const parsed = envspec.read(allocator, io, venv_path) orelse {
        output.debug(io, "run: no usable {s}, using activate.sh", .{envspec.file_name});
        return null;
    };
    defer parsed.deinit();
    const spec = &parsed.value;

    // Only the module cache needs the system identity; skip the lookup otherwise.
    const system: ?[]const u8 = if (spec.modules.len > 0) envspec.currentSystem(
        allocator,
        io,
        ctx.env,
    ) catch null else null;
    if (envspec.directReason(spec, system)) |reason| {
        output.debug(io, "run: {s}, using activate.sh", .{reason});
        return null;
    }

    var env = try ctx.env.clone(allocator);
    try envspec.apply(&env, spec);
    return env;
}

/// Shell snippet passed to `bash -c`. It sources the activation script (passed
/// as the first positional parameter `$1`), drops it from the positionals, then
/// `exec`s the user command (`$@`) so the command replaces the shell. Sourcing
/// honors `module load` and any activate hooks; `exec` makes the command's exit
/// status and signal disposition propagate directly back to zenv. A failing
/// activate hook does not stop it, as it does not stop `source` in a shell.
/// (activate.sh's one deliberate `return 1`, refusing a container env outside
/// its image, is never reached here: `start` sends those into the image.)
const run_runner = "[ -r \"$1\" ] || { echo \"zenv: cannot read $1\" >&2; exit 1; }; " ++
    "source \"$1\" || :; shift; exec \"$@\"";

/// Builds the argv for `zenv run`: the user command and its arguments are passed
/// to `bash -c` as positional parameters, never interpolated into a script. Because
/// bash receives them as distinct argv entries it never re-parses them, so there is
/// no quoting/escaping or command-injection surface (e.g. a backtick or `$VAR` in an
/// argument stays literal). Caller owns the returned slice (free with `allocator.free`);
/// the element strings are borrowed from the inputs and must outlive it.
fn buildRunArgv(
    allocator: Allocator,
    activate_path: []const u8,
    command: []const u8,
    command_args: []const []const u8,
) ![]const []const u8 {
    // `zenv` becomes $0 (used only in any bash error message); activate_path is $1.
    return std.mem.concat(
        allocator,
        []const u8,
        &.{ &.{ "/bin/bash", "-c", run_runner, "zenv", activate_path, command }, command_args },
    );
}

test "buildRunArgv passes command and args through verbatim" {
    const allocator = std.testing.allocator;
    // An argument crafted to trigger shell expansion if it were ever re-parsed.
    const nasty = "`whoami`$HOME \"q\" ; rm -rf /";
    const args = [_][]const u8{ "pip", "install", nasty };
    const argv = try buildRunArgv(allocator, "/envs/foo/activate.sh", "uv", &args);
    defer allocator.free(argv);

    const expected = [_][]const u8{
        "/bin/bash", "-c", run_runner, "zenv",
        "/envs/foo/activate.sh", // $1: sourced
        "uv", // the command
        "pip", "install", nasty, // args, untouched
    };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try std.testing.expectEqualStrings(e, a);
}

test "buildRunArgv handles a command with no extra args" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{};
    const argv = try buildRunArgv(allocator, "/a.sh", "python", &args);
    defer allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expectEqualStrings("python", argv[5]);
}
