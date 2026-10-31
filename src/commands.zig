const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const cli = @import("cli.zig");
const Flags = cli.Flags;
const Flag = cli.Flag;
const positional = cli.positional;
const unknownFlag = cli.unknownFlag;
const paths = @import("paths.zig");
const host = @import("host.zig");
const deps = @import("deps.zig");
const envbuild = @import("envbuild.zig");
const sources = @import("sources.zig");
const autosetup = @import("autosetup.zig");
const manifest = @import("manifest.zig");
const python = @import("python.zig");
const jupyter = @import("jupyter.zig");
const config = @import("config.zig");
const Registry = @import("Registry.zig");
const validation = @import("validation.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const envspec = @import("envspec.zig");
const activation = @import("activation.zig");
const container = @import("container.zig");
const venv = @import("venv.zig");
const hook = @import("hook.zig");
const launch = @import("launch.zig");
const sh_quote = @import("shell.zig").sq;
const Ctx = runtime.Ctx;

/// zenv's commands. Tag names ARE the command spellings (including @"-v" etc.).
pub const Command = enum {
    setup,
    activate,
    ls,
    /// Former name of `ls`, still accepted.
    list,
    register,
    deregister,
    cd,
    init,
    rm,
    rename,
    python,
    log,
    run,
    add,
    validate,
    alias,
    jupyter,
    hook,
    help,
    version,
    @"-v",
    @"-V",
    @"--version",
    @"--help",
    /// Internal, run inside an env's container (container.zig): setup's
    /// build (`envbuild.runInside`) and a command in the env (`handleExecInside`).
    __build,
    __exec,
};

/// The flags each command takes (see printUsage in main.zig).
const setup_flags = [_]Flag{
    .@"--init",
    .@"--no-python",
    .@"--dev",
    .@"--uv",
    .@"--pip",
    .@"--no-host",
    .@"--python",
    .@"--force",
    .@"--no-cache",
    .@"--jupyter",
    .@"--reuse-module-cache",
    .@"--group",
};
const register_flags = [_]Flag{.@"--no-host"};
const add_flags = [_]Flag{ .@"--dev", .@"--group", .@"--zenv", .@"--uv", .@"--pip" };

/// Refuses a flag that `zenv <command>` does not take, naming the ones it
/// does, and two flags that contradict each other.
fn checkFlags(io: Io, args: []const []const u8, allowed: []const Flag) error{ArgsError}!void {
    if (unknownFlag(args, allowed)) |bad| {
        output.printError(
            io,
            "Unknown option '{s}' for 'zenv {s}'. Options: {f}",
            .{ bad, args[1], joinedList(Flag, allowed) },
        );
        return error.ArgsError;
    }
    if (cli.badGroup(args)) |bad| {
        output.printError(
            io,
            "'--group' needs a dependency group name (letters and digits, with '.', '_' or '-' inside), got '{s}'.",
            .{bad},
        );
        return error.ArgsError;
    }
    const pair = cli.conflict(args) orelse return;
    output.printError(io, "'{s}' and '{s}' cannot be used together.", .{ pair[0], pair[1] });
    return error.ArgsError;
}

/// Formats a list of strings or enum values as "a, b, c" (`{f}`).
fn joinedList(comptime T: type, list: []const T) std.fmt.Alt([]const T, struct {
    fn format(items: []const T, w: *Io.Writer) Io.Writer.Error!void {
        for (items, 0..) |item, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(if (T == []const u8) item else @tagName(item));
        }
    }
}.format) {
    return .{ .data = list };
}

/// `args[i]`, or `error.ArgsError` after printing `message`.
fn argAt(
    io: Io,
    args: []const []const u8,
    i: usize,
    comptime message: []const u8,
) error{ArgsError}![]const u8 {
    if (i < args.len) return args[i];
    output.printError(io, message, .{});
    return error.ArgsError;
}

/// The subcommand of `zenv <command>` in `args[2]`, one of `E`'s tags.
fn subcommandOf(
    comptime E: type,
    io: Io,
    args: []const []const u8,
    comptime command: []const u8,
    comptime usage: []const u8,
) error{ArgsError}!E {
    const name = try argAt(io, args, 2, "Missing " ++ command ++ " subcommand.\nUsage: " ++ usage);
    return std.meta.stringToEnum(E, name) orelse {
        output.printError(
            io,
            "Unknown " ++ command ++ " subcommand '{s}'.\nUsage: " ++ usage,
            .{name},
        );
        return error.ArgsError;
    };
}

/// The starter zenv.json for `zenv init`: one environment for any machine,
/// with every key present so users can see what is configurable. Written with
/// the JSON writer, so a name or description containing `"` or `\` stays
/// valid JSON. Caller owns the result.
fn initConfigJson(
    allocator: Allocator,
    env_name: []const u8,
    description: []const u8,
    dependency_file: ?[]const u8,
    with_python: bool,
) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    const none: []const []const u8 = &.{};
    const empty_hook = .{ .commands = none, .script = null };

    // The env name is a key, so the top level is written field by field; the
    // env itself is a struct literal, written in field order.
    try s.beginObject();
    try s.objectField("base_dir");
    try s.write(".zenv");
    try s.objectField(env_name);
    // A Python-free env gets "python": false and none of the Python-only keys
    // (which validation would reject), plus an empty "env" to fill in.
    if (with_python) try s.write(.{
        .target_machines = [_][]const u8{"*"},
        .description = description,
        .fallback_python = null,
        .modules = none,
        .modules_file = null,
        .module_cache = true,
        .dependencies = none,
        .dependency_file = dependency_file,
        .setup = empty_hook,
        .activate = empty_hook,
    }) else try s.write(.{
        .target_machines = [_][]const u8{"*"},
        .description = description,
        .python = false,
        .modules = none,
        .modules_file = null,
        .module_cache = true,
        .env = struct {}{},
        .setup = empty_hook,
        .activate = empty_hook,
    });
    try s.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

test "initConfigJson writes every key in order and escapes user text" {
    const a = std.testing.allocator;
    const text = try initConfigJson(a, "my\"env", "a \\ \"quoted\" desc", "requirements.txt", true);
    defer a.free(text);

    // base_dir first, then the env, as the old template had it.
    try std.testing.expect(
        std.mem.startsWith(u8, text, "{\n  \"base_dir\": \".zenv\",\n  \"my\\\"env\": {"),
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const env_obj = parsed.value.object.get("my\"env").?.object;
    try std.testing.expectEqualStrings("a \\ \"quoted\" desc", env_obj.get("description").?.string);
    try std.testing.expectEqualStrings("*", env_obj.get("target_machines").?.array.items[0].string);
    try std.testing.expectEqualStrings("requirements.txt", env_obj.get("dependency_file").?.string);
    try std.testing.expect(env_obj.get("module_cache").?.bool);
    try std.testing.expect(env_obj.get("activate").?.object.get("script").? == .null);
    const keys = [_][]const u8{
        "target_machines",
        "description",
        "fallback_python",
        "modules",
        "modules_file",
        "module_cache",
        "dependencies",
        "dependency_file",
        "setup",
        "activate",
    };
    try std.testing.expectEqual(keys.len, env_obj.count());
    for (keys, env_obj.keys()) |want, got| try std.testing.expectEqualStrings(want, got);

    const no_deps = try initConfigJson(a, "e", "d", null, true);
    defer a.free(no_deps);
    try std.testing.expect(std.mem.find(u8, no_deps, "\"dependency_file\": null") != null);
}

const init_usage =
    \\Usage: zenv init [name] [description] [--no-python]
    \\Creates zenv.json with environment <name>, or adds <name> to an existing zenv.json.
    \\  name         defaults to the current directory's name
    \\  description  defaults to [project].description from pyproject.toml, if any
    \\  --no-python  an environment without Python, for modules, env variables and settings
;

const InitOutcome = enum { created, added, exists };

/// Defines environment `env_name` in ./zenv.json: writes a new file, or adds
/// the env to an existing one. `exists` (nothing written) when the file
/// already defines it. A null `description` is taken from pyproject.toml.
/// Without `with_python`, the env is written Python-free (`"python": false`).
/// Allocates with `a` (use an arena).
fn initConfig(
    a: Allocator,
    io: Io,
    env_name: []const u8,
    description: ?[]const u8,
    with_python: bool,
) !InitOutcome {
    const cwd = Io.Dir.cwd();
    const config_path = "zenv.json";

    // Point dependency_file at an existing requirements.txt, else pyproject.toml.
    var dependency_file: ?[]const u8 = null;
    if (with_python) for ([_][]const u8{ "requirements.txt", "pyproject.toml" }) |candidate| {
        if (cwd.access(io, candidate, .{})) |_| {
            dependency_file = candidate;
            break;
        } else |err| if (err != error.FileNotFound) return err;
    };

    const desc = description orelse pyproject: {
        const content = cwd.readFileAlloc(
            io,
            "pyproject.toml",
            a,
            .limited(10 * 1024 * 1024),
        ) catch break :pyproject null;
        break :pyproject try deps.pyprojectField(a, content, "description");
    } orelse "Env config created by zenv";

    const template = try initConfigJson(a, env_name, desc, dependency_file, with_python);

    // Creating the file is the existence check: no window for another zenv
    // to create it in between.
    cwd.writeFile(
        io,
        .{ .sub_path = config_path, .data = template, .flags = .{ .exclusive = true } },
    ) catch |err| switch (err) {
        error.PathAlreadyExists => return if (try manifest.addEnvToZenvJson(
            a,
            io,
            config_path,
            env_name,
            template,
        )) .added else .exists,
        else => return err,
    };
    return .created;
}

/// Refuses to register a new environment named `env_name` when that is an
/// alias of another one: names resolve first, so the alias would be hidden.
/// An environment already registered under the name is just set up again.
fn refuseAliasName(io: Io, registry: *const Registry, env_name: []const u8) error{AliasAlreadyExists}!void {
    for (registry.entries.items) |entry| {
        if (std.mem.eql(u8, entry.env_name, env_name)) return;
    }
    const holder = registry.resolveAlias(env_name) orelse return;
    output.printError(
        io,
        "'{s}' is already an alias of environment '{s}'. Pick another name, or remove the alias first: zenv alias remove {s}",
        .{ env_name, holder, env_name },
    );
    return error.AliasAlreadyExists;
}

/// Refuses `name` unless it can be an environment name (paths.isValidEnvName).
fn requireValidEnvName(io: Io, name: []const u8) error{InvalidEnvironmentName}!void {
    if (paths.isValidEnvName(name)) return;
    output.printError(
        io,
        "Invalid environment name '{s}'. Use only letters, digits, '-', '_' and '.'.",
        .{name},
    );
    return error.InvalidEnvironmentName;
}

/// An env name from directory `dir`'s name: characters an env name cannot
/// hold become '-'. "test" when nothing usable is left.
fn defaultEnvName(allocator: Allocator, dir: []const u8) ![]u8 {
    const base = std.Io.Dir.path.basename(dir);
    const name = try allocator.dupe(u8, base);
    for (name) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '_' and c.* != '-' and c.* != '.') c.* = '-';
    }
    if (paths.isValidEnvName(name)) return name;
    allocator.free(name);
    return allocator.dupe(u8, "test");
}

test "initConfigJson without Python: python false, no Python-only keys, valid" {
    const a = std.testing.allocator;
    const text = try initConfigJson(a, "tools", "d", "requirements.txt", false);
    defer a.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const env_obj = parsed.value.object.get("tools").?.object;
    const keys = [_][]const u8{
        "target_machines",
        "description",
        "python",
        "modules",
        "modules_file",
        "module_cache",
        "env",
        "setup",
        "activate",
    };
    try std.testing.expectEqual(keys.len, env_obj.count());
    for (keys, env_obj.keys()) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(!env_obj.get("python").?.bool);
    try std.testing.expectEqual(@as(usize, 0), env_obj.get("env").?.object.count());
    // What init writes must pass validation as is.
    try std.testing.expect((try validation.validateJsonContent(a, text)) == null);
}

test "defaultEnvName uses the directory name, made valid" {
    const a = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "/home/u/my-proj", "my-proj" },
        .{ "/home/u/My Project (v2)", "My-Project--v2-" },
        .{ "/home/u/proj.d/", "proj.d" },
        .{ "/", "test" },
        .{ "..", "test" },
    }) |case| {
        const got = try defaultEnvName(a, case[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

pub fn handleInit(ctx: Ctx, args: []const []const u8) void {
    const io = ctx.io;
    const allocator = ctx.arena;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            output.rawOut(io, init_usage ++ "\n", .{});
            return;
        }
    }
    if (unknownFlag(args, &.{.@"--no-python"})) |arg| {
        output.printError(io, "Unknown option '{s}' for 'zenv init'.\n" ++ init_usage, .{arg});
        std.process.exit(1);
    }

    const env_name = positional(args, 0) orelse blk: {
        const cwd = std.process.currentPathAlloc(io, allocator) catch |err| {
            output.printError(io, "Reading the current directory: {t}", .{err});
            std.process.exit(1);
        };
        break :blk defaultEnvName(allocator, cwd) catch {
            output.printError(io, "Out of memory", .{});
            std.process.exit(1);
        };
    };
    requireValidEnvName(io, env_name) catch std.process.exit(1);

    const python_env = !Flags.parse(args).no_python;
    const outcome = initConfig(
        allocator,
        io,
        env_name,
        positional(args, 1),
        python_env,
    ) catch |err| {
        if (err == error.InvalidFormat) {
            output.printError(
                io,
                "zenv.json exists but is not a JSON object; fix it or remove it first.",
                .{},
            );
        } else {
            output.printError(io, "Writing zenv.json: {t}", .{err});
        }
        std.process.exit(1);
    };
    switch (outcome) {
        .created, .added => {
            const what = if (outcome == .created) "Created zenv.json with" else "Added to zenv.json:";
            const kind = if (python_env) "environment" else "Python-free environment";
            output.print(
                io,
                "{s} {s} '{s}'. Run 'zenv setup {s}'",
                .{ what, kind, env_name, env_name },
            );
        },
        .exists => {
            output.printError(
                io,
                "zenv.json already defines environment '{s}'. Pick another name: zenv init <name>",
                .{env_name},
            );
            std.process.exit(1);
        },
    }
}

/// `zenv setup --init`: defines the env in zenv.json first, unless it already
/// is (see `initConfig`).
fn setupInit(ctx: Ctx, args: []const []const u8, flags: Flags) void {
    const io = ctx.io;
    // The name is the first POSITIONAL argument, skipping flags:
    // `zenv setup --init myenv` must not create an env named "--init".
    const env_name = positional(args, 0) orelse {
        output.printError(io, "Missing environment name. Usage: zenv setup <name> --init", .{});
        std.process.exit(1);
    };
    requireValidEnvName(io, env_name) catch std.process.exit(1);
    const outcome = initConfig(
        ctx.arena,
        io,
        env_name,
        positional(args, 1),
        !flags.no_python,
    ) catch |err| {
        output.printError(io, "Could not add '{s}' to zenv.json: {t}", .{ env_name, err });
        std.process.exit(1);
    };
    switch (outcome) {
        .created => output.print(
            io,
            "--init: created zenv.json with environment '{s}'",
            .{env_name},
        ),
        .added => output.print(io, "--init: added environment '{s}' to zenv.json", .{env_name}),
        .exists => {
            // An existing env keeps its config; refuse rather than set up
            // something other than what --no-python asked for.
            // An unusable zenv.json is reported by the load after --init.
            if (flags.no_python and pythonDisabled(ctx.arena, io, "zenv.json", env_name) == false) {
                output.printError(
                    io,
                    "zenv.json already defines '{s}' with Python. Set \"python\": false for it in zenv.json, or pick a new name.",
                    .{env_name},
                );
                std.process.exit(1);
            }
            output.print(io, "--init: zenv.json already defines '{s}'; using it", .{env_name});
        },
    }
}

pub fn handleSetup(ctx: Ctx, registry: *Registry, args: []const []const u8) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    try checkFlags(io, args, &setup_flags);
    const flags = Flags.parse(args);
    // --no-python only shapes a new env's config; after that, zenv.json
    // decides (and auto-setup rebuilds from it without replaying flags).
    if (flags.no_python and !flags.init_mode) {
        output.printError(
            io,
            "--no-python only applies with --init. For an existing environment, set \"python\": false for it in zenv.json.",
            .{},
        );
        std.process.exit(1);
    }
    if (flags.init_mode) setupInit(ctx, args, flags);
    var file = try validation.load(allocator, io, "zenv.json", .loud);
    defer file.deinit(allocator);
    const project = &file.project;

    // Log the detected flags
    if (flags.force_deps) {
        output.print(io,
            \\Force dependencies flag detected.
            \\User-specified dependencies will try to override module-provided packages.
        , .{});
    }
    if (flags.skip_hostname_check) {
        output.print(io, "No-host flag detected. Bypassing hostname validation.", .{});
    }
    if (flags.init_mode) {
        output.print(io, "Init flag detected. Using configuration created by --init.", .{});
    }
    if (flags.no_cache) {
        output.print(
            io,
            "No-cache flag detected. Will disable package cache during dependency installation.",
            .{},
        );
    }

    // Get and validate the environment config
    const env_config = try selectEnv(ctx, project, args, flags);
    // Non-null: selectEnv just errored otherwise.
    const env_name = positional(args, 0).?;
    try refuseAliasName(io, registry, env_name);
    const groups = try cli.groups(allocator, args);

    if (!env_config.python) {
        if (flags.dev_mode) return noPython(io, env_name, "--dev installs the project into it");
        if (groups.len > 0) return noPython(io, env_name, "--group installs packages into it");
        if (flags.create_jupyter_kernel) return noPython(io, env_name, "--jupyter needs Python");
    }

    const targets = env_config.target_machines.items;
    const display_target = if (targets.len > 0) targets[0] else "any";

    // Set up logging to a file inside the environment directory. Setup runs in
    // the project directory, so cwd is the anchor for a relative base_dir.
    const setup_cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(setup_cwd);

    const env_dir_path = try paths.venvPath(allocator, setup_cwd, project.base_dir, env_name);
    defer allocator.free(env_dir_path);

    // Refuse an env directory that is, or holds, the project or zenv's global
    // state (e.g. base_dir ".." puts the env on the project itself, and
    // `zenv setup` from $HOME with the default base_dir would write next to
    // registry.json). Setup would write over them and `zenv rm` delete them.
    // Guard here, before any logging or directory creation.
    try refuseEnvDirOverlap(ctx, env_dir_path, setup_cwd, "set up");

    // The env directory holds the setup log, so it is created first.
    try Io.Dir.cwd().createDirPath(io, env_dir_path);
    const log_path = try Io.Dir.path.join(allocator, &.{ env_dir_path, "zenv_setup.log" });
    defer allocator.free(log_path);

    try output.startLogging(io, log_path);
    defer output.stopLogging(io);

    var command_str: std.ArrayList(u8) = .empty;
    for (args, 0..) |arg, i| {
        if (i > 0) try command_str.append(allocator, ' ');
        // Quote arguments with spaces
        if (std.mem.findScalar(u8, arg, ' ') != null) {
            try command_str.print(allocator, "\"{s}\"", .{arg});
        } else {
            try command_str.appendSlice(allocator, arg);
        }
    }
    output.print(io, "Command: {s}", .{command_str.items});
    output.print(io, "Setting up environment: {s} (Target: {s})", .{ env_name, display_target });

    // 1. Collect the dependencies. They live in `allocator` (main's arena);
    // config strings are borrowed.
    const collected = try sources.collect(ctx, env_config, setup_cwd, groups, flags.dev_mode);
    output.print(io, "Combined dependency list ({d} items):", .{collected.deps.len});
    for (collected.deps) |dep| {
        output.print(io, "  - {s}", .{dep});
    }

    // 2. Build the environment: modules, venv, dependencies, hooks.
    try envbuild.run(ctx, .{
        .env_config = env_config,
        .env_name = env_name,
        .venv_dir = env_dir_path,
        .project_dir = setup_cwd,
        .deps = collected.deps,
        .flags = flags,
        .requires_python = collected.requires_python,
    });
    output.print(io, "Environment '{s}' setup completed successfully.", .{env_name});

    // 3. Record activation as data (zenv-env.json) and render the per-shell
    // activation scripts from it.
    try activation.generate(allocator, io, env_config, env_name, env_dir_path, setup_cwd);

    // 4. Register the environment in the global registry; register() persists
    // registry.json itself (like deregister/rename).
    try registry.register(
        env_name,
        setup_cwd,
        project.base_dir,
        env_config.description,
        env_config.target_machines.items,
    );

    // Create Jupyter kernel if requested, for the entry just registered.
    if (flags.create_jupyter_kernel) {
        const run_as = if (registry.find(env_name, setup_cwd)) |ref| registry.launchIdentifier(ref) else env_name;
        jupyter.createKernel(ctx, env_name, env_dir_path, run_as, null, null) catch |err| {
            output.printError(io, "Failed to create Jupyter kernel: {t}", .{err});
        };
    }

    // Record the build so run/activate/cd/jupyter can detect config drift
    // later and auto-rebuild. Non-fatal: setup already succeeded; a missing
    // record just forces the next gated command to re-setup.
    autosetup.recordSetup(ctx, .{
        .project_dir = setup_cwd,
        .env_name = env_name,
        .venv_dir = env_dir_path,
        .file = &file,
        .flags = flags,
        .groups = groups,
    }) catch |err| {
        output.printWarning(io, "could not write setup stamp: {t}", .{err});
    };

    output.print(io,
        \\Environment '{s}' setup complete and registered in global registry.
        \\Usage: source $(zenv activate {s})
    , .{ env_name, env_name });
}

/// The config of the environment named by the first positional argument, with
/// its `modules_file` (if any) read into `modules`, after checking the current
/// host against its target_machines unless `--no-host` was given. Prints why
/// and returns an error when any step fails.
fn selectEnv(
    ctx: Ctx,
    project: *config.Project,
    args: []const []const u8,
    flags: Flags,
) !*const config.Env {
    const io = ctx.io;
    // First positional after the command — NOT args[2], which may be a flag
    // (e.g. `zenv setup --init myenv`).
    const env_name = positional(args, 0) orelse {
        output.printError(io, "Missing environment name argument for command '{s}'", .{args[1]});
        return error.ArgsError;
    };

    const env_config = project.environments.getPtr(env_name) orelse {
        output.printError(io, "Environment '{s}' not found in configuration.", .{env_name});
        return error.EnvironmentNotFound;
    };

    // If modules_file is specified, read modules from the file
    if (env_config.modules_file) |modules_file_path| {
        output.debug(io, "Modules file specified: {s}", .{modules_file_path});

        // Read modules with the config's own allocator so the list can be moved
        // into env_config as-is, without copying each name.
        const modules_from_file = readModulesFile(
            env_config.allocator,
            io,
            modules_file_path,
        ) catch |err| {
            if (err == error.FileNotFound) {
                output.printError(io, "Modules file '{s}' not found.", .{modules_file_path});
            } else {
                output.printError(
                    io,
                    "Failed to read modules from file '{s}': {t}",
                    .{ modules_file_path, err },
                );
            }
            return err;
        };

        // Replace the existing modules (ignoring them as specified)
        if (env_config.modules.items.len > 0) {
            output.print(
                io,
                "Ignoring {d} modules defined in zenv.json in favor of modules_file",
                .{env_config.modules.items.len},
            );
        }
        for (env_config.modules.items) |module| env_config.allocator.free(module);
        env_config.modules.deinit(env_config.allocator);
        env_config.modules = modules_from_file;

        output.print(
            io,
            "Loaded {d} modules from file for environment '{s}'",
            .{ env_config.modules.items.len, env_name },
        );
    }

    // Check if hostname validation is needed
    if (flags.skip_hostname_check) {
        output.debug(io, "Hostname validation bypassed for environment '{s}'.", .{env_name});
        return env_config;
    }

    try host.check(ctx, env_config.target_machines.items, env_name);
    output.debug(io, "Hostname validation passed for env '{s}'.", .{env_name});
    return env_config;
}

/// Module names from `file_path`, one per line, in first-seen order without
/// duplicates. Blank lines and `#` comments are skipped; CRLF line ends and a
/// UTF-8 BOM are accepted. Names are owned by `allocator`.
fn readModulesFile(allocator: Allocator, io: Io, file_path: []const u8) !std.ArrayList([]const u8) {
    var modules_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (modules_list.items) |item| allocator.free(item);
        modules_list.deinit(allocator);
    }

    const file_content = try Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(file_content);
    const content = std.mem.cutPrefix(
        u8,
        file_content,
        "\xEF\xBB\xBF",
    ) orelse file_content; // UTF-8 BOM

    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    next: while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (name.len == 0 or name[0] == '#') continue;
        for (modules_list.items) |seen| if (std.mem.eql(u8, seen, name)) continue :next;
        try modules_list.ensureUnusedCapacity(allocator, 1);
        modules_list.appendAssumeCapacity(try allocator.dupe(u8, name));
        output.debug(io, "  - Found module: '{s}'", .{name});
    }

    if (modules_list.items.len == 0) {
        output.printWarning(
            io,
            "No valid modules found in file. Ensure it contains valid module names.",
            .{},
        );
    } else {
        output.print(io, "Found {d} unique modules in file.", .{modules_list.items.len});
    }
    return modules_list;
}

test "readModulesFile: BOM, CRLF, comments and duplicates" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const path = ".zig-cache/tmp/zenv-modules-file.txt";
    try cwd.createDirPath(io, ".zig-cache/tmp");
    defer cwd.deleteFile(io, path) catch {};
    try cwd.writeFile(
        io,
        .{
            .sub_path = path,
            .data = "\xEF\xBB\xBFStages/2026\r\n# a comment\r\n\r\n  GCC  \nPython/3.13.5\nGCC\n",
        },
    );

    var list = try readModulesFile(a, io, path);
    defer {
        for (list.items) |m| a.free(m);
        list.deinit(a);
    }
    const want = [_][]const u8{ "Stages/2026", "GCC", "Python/3.13.5" };
    try std.testing.expectEqual(want.len, list.items.len);
    for (want, list.items) |w, got| try std.testing.expectEqualStrings(w, got);
}

/// Explains why `identifier` did not resolve, listing the candidates of an
/// ambiguous one, and returns `err` for main.zig to report.
fn explainResolveError(
    ctx: Ctx,
    registry: *const Registry,
    identifier: []const u8,
    err: anytype,
) @TypeOf(err) {
    const io = ctx.io;
    const allocator = ctx.arena;
    if (err == error.AmbiguousIdentifier) {
        const cands = registry.candidates(allocator, identifier) catch return err;
        defer allocator.free(cands);

        output.rawErr(io, "ERROR: '{s}' matches multiple environments:\n", .{identifier});

        // A name several projects register: say where each lives.
        if (cands.len > 1 and std.mem.eql(u8, cands[0].env_name, identifier) and
            !std.mem.eql(u8, identifier, "."))
        {
            for (cands) |c| output.rawErr(
                io,
                "  - {s} in {s} (id {s})\n",
                .{ c.env_name, c.project_dir, c.id[0..@min(c.id.len, 7)] },
            );
            output.rawErr(io, "Run the command inside one of these projects, or use the id.\n", .{});
            return err;
        }

        // Host framing applies only to the host-aware branches ("." and a shared
        // alias). A non-unique id-prefix is host-irrelevant — advise more characters.
        const host_relevant = std.mem.eql(
            u8,
            identifier,
            ".",
        ) or registry.resolveAlias(identifier) != null;
        if (!host_relevant) {
            for (cands) |c| output.rawErr(io, "  - {s}\n", .{c.env_name});
            output.rawErr(io, "Use more characters of the id, or the exact env name.\n", .{});
            return err;
        }

        // Best-effort current host so we can explain WHY the tie wasn't broken:
        // either none of the candidates target this host, or several do.
        const current_host: ?[]const u8 = host.getSystemHostname(allocator, io, ctx.env) catch null;
        defer if (current_host) |h| allocator.free(h);
        var host_matches: usize = 0;
        for (cands) |c| {
            const m = if (current_host) |h| host.matchesTargets(h, c.target_machines) else false;
            if (m) host_matches += 1;
            const mark = if (m) "  <- matches this host" else "";
            output.rawErr(
                io,
                "  - {s} (target: {s}){s}\n",
                .{ c.env_name, c.target_machines, mark },
            );
        }
        if (current_host) |h| {
            if (host_matches == 0) {
                output.rawErr(
                    io,
                    "None of these target the current host '{s}'. Add this machine to one env's target_machines, or use the exact env name / id.\n",
                    .{h},
                );
            } else {
                output.rawErr(
                    io,
                    "{d} target the current host '{s}'. Use the exact env name or id to choose one.\n",
                    .{ host_matches, h },
                );
            }
        } else {
            output.rawErr(
                io,
                "Could not determine the current host. Use the exact env name or id.\n",
                .{},
            );
        }
    } else if (err == error.EnvironmentNotRegistered) {
        if (std.mem.eql(u8, identifier, ".")) {
            const root = Registry.dotProjectDir(allocator, io) catch return err;
            defer allocator.free(root);
            output.rawErr(
                io,
                "ERROR: No environment is registered for the project at '{s}' (the nearest zenv.json).\n",
                .{root},
            );
        } else output.rawErr(
            io,
            "ERROR: Environment with name or ID '{s}' not found in registry.\n",
            .{identifier},
        );
        output.rawErr(io, "Use 'zenv ls' to see all available environments with their IDs.\n", .{});
    }
    return err;
}

/// Resolves the environment named by `args[2]`; when it is missing, says how
/// to call `zenv <usage>`.
fn resolveArg(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
    comptime usage: []const u8,
) !Registry.Ref {
    if (args.len < 3) {
        output.printError(
            ctx.io,
            "Missing environment name or ID argument.\nUsage: zenv " ++ usage,
            .{},
        );
        return error.EnvironmentNotFound;
    }
    return resolve(ctx, registry, args[2]);
}

/// Resolves `identifier`, explaining a failure (see `explainResolveError`).
fn resolve(ctx: Ctx, registry: *const Registry, identifier: []const u8) !Registry.Ref {
    return registry.resolve(ctx.arena, identifier) catch |e| return explainResolveError(
        ctx,
        registry,
        identifier,
        e,
    );
}

pub fn handleActivate(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    var shell: activation.Shell = .sh;
    var auto = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--auto")) {
            auto = true;
            continue;
        }
        const name = std.mem.cutPrefix(u8, arg, "--shell=") orelse {
            if (!std.mem.startsWith(u8, arg, "-")) continue;
            output.printError(
                io,
                "Unknown option '{s}' for 'zenv activate'. Options: --shell=<shell>, --auto",
                .{arg},
            );
            return error.ArgsError;
        };
        shell = activation.parseShell(name) orelse {
            output.printError(
                io,
                "Unsupported shell '{s}'. Supported: sh, bash, zsh, csh, tcsh, fish.",
                .{name},
            );
            return error.ArgsError;
        };
    }
    if (auto) return activateAuto(ctx, registry, positional(args, 0) orelse ".", shell);

    const identifier = positional(args, 0) orelse {
        output.printError(
            io,
            "Missing environment name or ID argument. Usage: zenv activate <name|id> [--shell=sh|bash|zsh|csh|tcsh|fish]",
            .{},
        );
        return error.EnvironmentNotFound;
    };

    const ref = try resolve(ctx, registry, identifier);
    // Rebuild the env first if its config/dependency files changed. The rebuild
    // is silent and any notice goes to stderr, so stdout stays just the
    // activate-script path that the shell sources.
    try autosetup.ensureUpToDate(ctx, registry.get(ref));
    const entry = registry.get(ref);
    if (launch.containerOf(ctx, entry.venv_path) != null) {
        output.printError(
            io,
            "'{s}' runs in a container image, which activation cannot enter. For a shell in it: zenv run {s} bash",
            .{ entry.env_name, entry.env_name },
        );
        return error.ContainerEnv;
    }
    try printActivateScript(ctx, entry, shell);
}

/// `zenv activate --auto [dir]`, for the shell hook (`zenv hook`): prints the
/// activation script of the env registered for the nearest directory at or
/// above `dir` that holds a zenv.json. Prints nothing when there is none or
/// several match, so the hook can run it on every project change. Never
/// rebuilds: a build on `cd` would be slow, and would run newly pulled
/// activate hooks unasked. A stale env gets a notice and activates as built.
fn activateAuto(
    ctx: Ctx,
    registry: *const Registry,
    dir: []const u8,
    shell: activation.Shell,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const start = try Io.Dir.cwd().realPathFileAlloc(io, dir, allocator);
    defer allocator.free(start);
    const root = (try paths.findProjectRoot(allocator, io, start)) orelse return;
    defer allocator.free(root);

    const ref = registry.resolveDir(allocator, root) catch |e| switch (e) {
        error.EnvironmentNotRegistered => return,
        error.AmbiguousIdentifier => {
            output.rawErr(
                io,
                "zenv: {s} has several environments for this machine; activate one by name.\n",
                .{root},
            );
            return;
        },
    };
    const entry = registry.get(ref);
    // A container env cannot be activated; on every cd, silence beats an error.
    if (launch.containerOf(ctx, entry.venv_path) != null) return;
    if (autosetup.isStale(ctx, entry) catch false) {
        output.rawErr(
            io,
            "zenv: '{s}' is out of date with zenv.json; run 'zenv setup {s}' to rebuild it.\n",
            .{ entry.env_name, entry.env_name },
        );
    }
    try printActivateScript(ctx, entry, shell);
}

fn printActivateScript(ctx: Ctx, entry: *const Registry.Entry, shell: activation.Shell) !void {
    const io = ctx.io;
    const script = try Io.Dir.path.join(
        ctx.arena,
        &.{ entry.venv_path, activation.fileName(shell) },
    );
    // Envs built by an older zenv have only activate.sh.
    if (!runtime.exists(io, script)) {
        output.printError(
            io,
            "{s} not found. Re-run 'zenv setup {s}' to generate it.",
            .{ script, entry.env_name },
        );
        return error.EnvironmentNotFound;
    }
    output.rawOut(io, "{s}\n", .{script});
}

/// `zenv hook <shell>`: prints the shell code that `eval "$(zenv hook zsh)"`
/// (or `bash`) loads to activate project environments on cd.
pub fn handleHook(ctx: Ctx, args: []const []const u8) !void {
    const io = ctx.io;
    const name = positional(args, 0) orelse {
        output.printError(io, "Missing shell. Usage: zenv hook <zsh|bash>", .{});
        return error.ArgsError;
    };
    const code = hook.forShell(name) orelse {
        output.printError(
            io,
            "Unsupported shell '{s}' for 'zenv hook'. Supported: zsh, bash.",
            .{name},
        );
        return error.ArgsError;
    };
    output.rawOut(io, "{s}", .{code});
}

pub fn handleList(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    defer stdout.flush() catch {};
    const list_all = args.len > 2 and std.mem.eql(u8, args[2], "--all");
    if (args.len > 3 or (args.len == 3 and !list_all and std.mem.startsWith(u8, args[2], "-"))) {
        output.printError(
            io,
            "Unexpected argument '{s}'. Usage: zenv ls [--all | <name|id|.>]",
            .{args[args.len - 1]},
        );
        return error.ArgsError;
    }

    // `zenv ls <name|id|.>`: that one environment, whatever machine it targets.
    if (args.len == 3 and !list_all) {
        const ref = try resolveArg(ctx, registry, args, "ls <name|id|.>");
        printListEntry(ctx, stdout, registry.get(ref));
        return;
    }

    // Without --all, only this machine's envs; a host that cannot be
    // determined lists everything.
    const current_hostname: ?[]const u8 = if (list_all) null else host.getSystemHostname(
        allocator,
        io,
        ctx.env,
    ) catch |err| blk: {
        output.print(io,
            \\Could not determine current hostname for filtering: {t}
            \\Listing all registered environments instead.
        , .{err});
        break :blk null;
    };
    defer if (current_hostname) |h| allocator.free(h);

    var count: usize = 0;
    for (registry.entries.items) |entry| {
        // matchesTargets owns the comma-list matching rules.
        if (current_hostname) |h| if (!host.matchesTargets(h, entry.target_machines_str)) continue;

        printListEntry(ctx, stdout, &entry);
        stdout.writeAll("\n") catch {};
        count += 1;
    }

    // current_hostname is non-null only without --all, when the host is known.
    if (count == 0) {
        if (current_hostname) |h| {
            stdout.print(
                \\No environments found for the current machine ('{s}')
                \\Use 'zenv ls --all' to see all registered environments.
                \\
            , .{h}) catch {};
        } else if (!list_all) {
            stdout.writeAll(
                "No environments found. (Could not determine current hostname).\n",
            ) catch {};
        } else {
            stdout.writeAll(
                \\No environments found in the registry
                \\Use 'zenv setup <name>' OR 'zenv register <name>' to register environments
                \\
            ) catch {};
        }
    } else if (current_hostname) |h| {
        stdout.print(
            "Found {d} environment(s) for the current machine ('{s}')\n",
            .{ count, h },
        ) catch {};
    } else {
        stdout.print("Found {d} total registered environment(s)\n", .{count}) catch {};
    }
}

/// One environment's block in `zenv ls`, ending in a newline.
fn printListEntry(ctx: Ctx, stdout: *Io.Writer, entry: *const Registry.Entry) void {
    stdout.print(
        "- {s}\n  id      : {s}\n  target  : {s}\n  project : {s}\n  venv    : {s}",
        .{
            entry.env_name,
            entry.id,
            entry.target_machines_str,
            entry.project_dir,
            entry.venv_path,
        },
    ) catch {};
    // The Python that built the venv, read from <venv>/pyvenv.cfg.
    // Omitted entirely when the env isn't built (no pyvenv.cfg).
    if (venv.readPython(ctx.arena, ctx.io, entry.venv_path) catch null) |py| {
        stdout.print("\n  python  : {s}", .{py}) catch {};
    }
    if (entry.aliases.items.len > 0) stdout.print(
        "\n  aliases : {f}",
        .{joinedList([]const u8, entry.aliases.items)},
    ) catch {};
    if (entry.description) |desc| stdout.print("\n  desc    : {s}", .{desc}) catch {};
    stdout.writeAll("\n") catch {};
}

pub fn handleRegister(ctx: Ctx, registry: *Registry, args: []const []const u8) !void {
    const io = ctx.io;
    var file = try validation.load(ctx.arena, io, "zenv.json", .loud);
    defer file.deinit(ctx.arena);
    const project = &file.project;
    // First positional, not args[2]: `zenv register --no-host myenv` must not
    // treat the flag as the environment name.
    const env_name = positional(args, 0) orelse {
        output.printError(
            io,
            "Missing environment name argument. Usage: zenv register <name>",
            .{},
        );
        return error.EnvironmentNotFound;
    };
    try refuseAliasName(io, registry, env_name);

    try checkFlags(io, args, &register_flags);
    const flags = Flags.parse(args);

    if (flags.skip_hostname_check) {
        output.print(io, "'--no-host' flag detected. Skipping hostname validation.", .{});
    }

    const env_config = project.getEnvironment(env_name) orelse {
        output.printError(io, "Environment '{s}' not found in configuration.", .{env_name});
        return error.EnvironmentNotFound;
    };

    if (!flags.skip_hostname_check) try host.check(ctx, env_config.target_machines.items, env_name);

    const cwd_path = std.process.currentPathAlloc(io, ctx.arena) catch |err| {
        output.printError(io, "Could not get current working directory: {t}", .{err});
        return err;
    };

    try refuseEnvDirOverlap(
        ctx,
        try paths.venvPath(ctx.arena, cwd_path, project.base_dir, env_name),
        cwd_path,
        "register",
    );

    // Register the environment in the global registry (persists internally).
    registry.register(
        env_name,
        cwd_path,
        project.base_dir,
        env_config.description,
        env_config.target_machines.items,
    ) catch |err| {
        output.printError(io, "Failed to register environment: {t}", .{err});
        return err;
    };

    output.print(io,
        \\Environment '{s}' registered successfully.
        \\Usage: source $(zenv activate {s})
    , .{ env_name, env_name });
}

pub fn handleDeregister(
    ctx: Ctx,
    registry: *Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const ref = try resolveArg(ctx, registry, args, "deregister <name|id|.>");

    // Resolve once, then remove by handle. deregister returns the owned, detached
    // entry (and persists), so the success message reads a valid name post-removal.
    var removed = registry.deregister(ref) catch |err| {
        output.printError(io, "Failed to unregister environment: {t}", .{err});
        return err;
    };
    defer removed.deinit(allocator);

    output.print(io, "Environment '{s}' unregistered successfully.", .{removed.env_name});
}

pub fn handleCd(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const ref = try resolveArg(ctx, registry, args, "cd <name|id|.>");
    // Rebuild the env first if its config/dependency files changed (silent).
    // A failed rebuild still prints the directory: the project is where the
    // user goes to fix zenv.json, and `cd $(zenv cd ...)` would otherwise land
    // in $HOME. The gate has already shown the rebuild's errors on stderr.
    autosetup.ensureUpToDate(ctx, registry.get(ref)) catch |err| {
        if (err != error.AutoSetupFailed) return err;
    };

    output.rawOut(ctx.io, "{s}\n", .{registry.get(ref).project_dir});
}

pub fn handlePython(ctx: Ctx, args: []const []const u8) !void {
    const io = ctx.io;
    if (args.len < 3) {
        output.printError(io, "Missing subcommand for 'python' command", .{});
        output.print(io, "Available subcommands: install, pin, ls", .{});
        return error.ArgsError;
    }

    const subcommand = std.meta.stringToEnum(enum { install, pin, use, ls, list }, args[2]) orelse {
        output.printError(io, "Unknown subcommand '{s}' for 'python' command", .{args[2]});
        output.print(io, "Available subcommands: install, pin, ls", .{});
        return error.ArgsError;
    };
    switch (subcommand) {
        .install => {
            const version: ?[]const u8 = if (args.len >= 4) args[3] else null;
            if (version) |v| {
                output.print(io, "Installing Python version: {s}", .{v});
            } else {
                output.print(io, "No version specified, will install default version", .{});
            }
            // Installing does not pin; `zenv python pin` does.
            python.install(ctx, version) catch |err| {
                output.printError(io, "Python installation failed: {t}", .{err});
                return err;
            };
        },
        .pin, .use => {
            if (args.len < 4) {
                output.printError(io, "Missing version argument for 'python pin' command", .{});
                output.print(io, "Usage: zenv python pin <version>", .{});
                return error.ArgsError;
            }
            try python.pin(ctx, args[3]);
        },
        .ls, .list => try python.listInstalled(ctx),
    }
}

/// Refuses an env directory that `paths.envDirOverlap` finds clobbering the
/// project or ZENV_DIR, saying why; `what` is the refused action.
fn refuseEnvDirOverlap(
    ctx: Ctx,
    env_dir: []const u8,
    project_dir: []const u8,
    what: []const u8,
) !void {
    const io = ctx.io;
    const zenv_dir = try paths.getZenvDir(ctx.arena, ctx.env);
    const overlap = try paths.envDirOverlap(ctx.arena, io, env_dir, project_dir, zenv_dir) orelse return;
    switch (overlap) {
        .project_dir => output.printError(
            io,
            "Refusing to {s}: the environment directory '{s}' is or contains the project directory '{s}'.",
            .{ what, env_dir, project_dir },
        ),
        .zenv_dir => output.printError(
            io,
            "Refusing to {s}: the environment directory '{s}' would overwrite zenv's global state in ZENV_DIR ('{s}').",
            .{ what, env_dir, zenv_dir },
        ),
    }
    output.printError(
        io,
        "Set a different 'base_dir' in zenv.json, run from a project directory, or point ZENV_DIR elsewhere.",
        .{},
    );
    return error.EnvDirOverlap;
}

/// Whether `dir` looks like an env zenv built: it holds a file only setup
/// writes. A missing dir counts as one (nothing to delete).
fn isEnvDir(io: Io, allocator: Allocator, dir: []const u8) !bool {
    if (!runtime.lexists(io, dir)) return true;
    for ([_][]const u8{ envspec.file_name, ".zenv.stamp", "zenv_setup.log" }) |marker| {
        if (runtime.lexists(io, try Io.Dir.path.join(allocator, &.{ dir, marker }))) return true;
    }
    return false;
}

pub fn handleRm(
    ctx: Ctx,
    registry: *Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const ref = try resolveArg(ctx, registry, args, "rm <name|id>");

    // Delete only what setup made: never the project or zenv's own state, and
    // never a directory without a file setup writes (an entry registered over
    // something else). `zenv deregister` still drops such an entry.
    {
        const entry = registry.get(ref);
        refuseEnvDirOverlap(ctx, entry.venv_path, entry.project_dir, "remove") catch |err| {
            output.printError(io, "'zenv deregister {s}' drops the entry and keeps the files.", .{entry.env_name});
            return err;
        };
        if (!try isEnvDir(io, allocator, entry.venv_path)) {
            output.printError(
                io,
                "Refusing to remove '{s}': it does not look like a zenv environment. 'zenv deregister {s}' drops the entry and keeps the files.",
                .{ entry.venv_path, entry.env_name },
            );
            return error.EnvDirOverlap;
        }
    }

    // deregister returns the owned, detached entry, so venv_path stays
    // readable after removal.
    var removed = registry.deregister(ref) catch |err| {
        output.printError(io, "Failed to deregister environment: {t}", .{err});
        return err;
    };
    defer removed.deinit(allocator);

    output.print(io, "Environment '{s}' deregistered successfully.", .{removed.env_name});

    output.print(io, "Attempting to remove: {s}", .{removed.venv_path});
    Io.Dir.cwd().deleteTree(io, removed.venv_path) catch |err| {
        output.printError(io, "Failed to remove '{s}': {t}", .{ removed.venv_path, err });
        output.printError(io, "You may need to remove it manually.", .{});
        return err;
    };

    output.print(io, "Directory '{s}' removed successfully.", .{removed.venv_path});
    output.print(io, "Environment '{s}' removed.", .{removed.env_name});
}

pub fn handleRun(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    if (args.len < 4) {
        output.printError(
            io,
            "Missing environment name or command. Usage: zenv run <name|id> <command> [args...]",
            .{},
        );
        return error.ArgsError;
    }

    const command = args[3];
    const command_args = args[4..];

    const ref = try resolve(ctx, registry, args[2]);
    // Rebuild the env first if its config/dependency files changed (silent).
    try autosetup.ensureUpToDate(ctx, registry.get(ref));
    const venv_path = registry.get(ref).venv_path;

    // The command replaces zenv (exec), so its exit status and signals reach
    // the caller as if it ran directly, and a signal sent to this pid (e.g. a
    // Jupyter kernel interrupt) reaches the command instead of ending zenv
    // under it. launch.start returns only when the command was not found.
    const term = launch.start(ctx, venv_path, command, command_args, .replace) catch |err| {
        output.printError(io, "Failed to run command: {t}", .{err});
        return err;
    };
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}

/// `zenv add <name|id|.> <package> [--dev | --group <name>] [--zenv] [--uv|--pip]`
/// Installs `<package>` into the environment's venv and records it in the right
/// manifest. Install happens FIRST; the manifest is only updated on success.
pub fn handleAdd(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const env_id = positional(args, 0) orelse {
        output.printError(
            io,
            "Missing environment name. Usage: zenv add <name|id|.> <package> [--dev | --group <name>] [--zenv] [--uv|--pip]",
            .{},
        );
        return error.ArgsError;
    };
    const package = positional(args, 1) orelse {
        output.printError(
            io,
            "Missing package name. Usage: zenv add <name|id|.> <package> [--dev | --group <name>] [--zenv] [--uv|--pip]",
            .{},
        );
        return error.ArgsError;
    };
    try checkFlags(io, args, &add_flags);
    const flags = Flags.parse(args);
    const group = try addGroup(allocator, io, args, flags);

    const ref = try resolve(ctx, registry, env_id);
    const entry = registry.get(ref);
    const env_name = entry.env_name;
    const project_dir = entry.project_dir;

    // The environment must already be built (its activation script exists).
    const activate_path = try Io.Dir.path.join(
        allocator,
        &.{ entry.venv_path, activation.fileName(.sh) },
    );
    defer allocator.free(activate_path);
    Io.Dir.cwd().access(io, activate_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            output.printError(
                io,
                "Environment '{s}' is not set up yet. Run 'zenv setup {s}' first.",
                .{ env_name, env_name },
            );
            return error.EnvironmentNotFound;
        }
        return err;
    };

    // The project's zenv.json says which manifest (if any) backs this env, so
    // it must be usable before anything is installed.
    const zenv_json_path = try Io.Dir.path.join(allocator, &.{ project_dir, "zenv.json" });
    defer allocator.free(zenv_json_path);
    var file = try validation.load(allocator, io, zenv_json_path, .loud);
    defer file.deinit(allocator);
    const env_config = file.project.getEnvironment(env_name) orelse {
        output.printError(
            io,
            "'{s}' is not defined in {s}, so the package cannot be recorded.",
            .{ env_name, zenv_json_path },
        );
        return error.EnvironmentNotConfigured;
    };
    const dep_file = env_config.dependency_file;

    // Turning Python on is the user's call, made in zenv.json, not a side
    // effect of adding a package.
    if (!env_config.python) {
        output.printError(
            io,
            "'{s}' has no Python (\"python\": false in zenv.json), so packages cannot be added.",
            .{env_name},
        );
        output.printError(
            io,
            "Set \"python\": true for '{s}' in zenv.json, then re-run: zenv {f}",
            .{ env_name, shellWords(args[1..]) },
        );
        return error.NoPython;
    }
    // A container env installs inside its image (its bin/python points there).
    if (launch.containerOf(ctx, entry.venv_path) != null) {
        const record = try sources.recordTarget(
            allocator,
            io,
            project_dir,
            dep_file,
            group,
            flags.zenv_only,
        );
        return addByRebuild(ctx, entry, zenv_json_path, record, package);
    }
    // Python was just turned on for an env built without it: build the venv
    // first (zenv.json changed, so the gate rebuilds).
    if (!try venvHasPython(allocator, io, entry.venv_path)) {
        try autosetup.ensureUpToDate(ctx, entry);
        if (!try venvHasPython(allocator, io, entry.venv_path)) {
            output.printError(
                io,
                "Environment '{s}' has no Python venv yet. Run 'zenv setup {s}' first.",
                .{ env_name, env_name },
            );
            return error.NoPython;
        }
    }

    // Where the package will be recorded, settled before installing so a
    // group that cannot be recorded installs nothing.
    const record = try sources.recordTarget(
        allocator,
        io,
        project_dir,
        dep_file,
        group,
        flags.zenv_only,
    );

    // Recording the package changes a tracked manifest, and the install below
    // makes the env match it again: an env up to date now stays so.
    var change = try autosetup.Change.begin(ctx, entry);

    // 1. Install into the venv (only persist below if this succeeds).
    const uv = try envbuild.resolveUv(ctx, addInstaller(allocator, io, flags, entry.venv_path));
    try installPackage(ctx, entry.venv_path, project_dir, package, uv);
    // The venv's record of its requirements; the next add resolves with it.
    envbuild.recordAdded(allocator, io, entry.venv_path, package) catch {};

    // 2. Persist to the appropriate manifest.
    sources.record(allocator, io, zenv_json_path, env_name, record, package) catch |err| {
        output.printError(
            io,
            "'{s}' is installed in '{s}', but recording it failed: {t}. Add it to the manifest by hand.",
            .{ package, env_name, err },
        );
        return error.RecordFailed;
    };
    // A package in a dependency group survives rebuilds only if they install
    // the group, so the build record now replays it.
    if (record.group()) |g| if (change.replayGroup(ctx, g)) output.print(
        io,
        "Rebuilds of '{s}' now install group '{s}'; a manual 'zenv setup' needs '--group {s}'.",
        .{ env_name, g, g },
    );
    change.finish(ctx, project_dir, env_name, entry.venv_path);

    output.print(io, "Added '{s}' to environment '{s}'.", .{ package, env_name });
}

/// Formats `words` as a command line a shell reads back as the same words
/// (`{f}`): a word with characters a shell treats specially is single-quoted.
fn shellWords(words: []const []const u8) std.fmt.Alt([]const []const u8, struct {
    fn format(items: []const []const u8, w: *Io.Writer) Io.Writer.Error!void {
        for (items, 0..) |word, i| {
            if (i > 0) try w.writeByte(' ');
            const plain = word.len > 0 and for (word) |c| {
                if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(
                    u8,
                    "-_./=:,+@%",
                    c,
                ) == null) break false;
            } else true;
            if (plain) try w.writeAll(word) else try w.print("'{f}'", .{sh_quote(word)});
        }
    }
}.format) {
    return .{ .data = words };
}

test "shellWords quotes only words a shell would change" {
    var buf: [128]u8 = undefined;
    const got = try std.fmt.bufPrint(
        &buf,
        "{f}",
        .{shellWords(&.{ "add", "e", "flask>=2.0", "it's", "--group=dev" })},
    );
    try std.testing.expectEqualStrings("add e 'flask>=2.0' 'it'\\''s' --group=dev", got);
}

/// Whether the zenv.json at `path` sets `"python": false` for `env_name`:
/// false when the file lacks the env, null when the file is missing or
/// invalid (callers then let the loud `validation.load` say why).
fn pythonDisabled(allocator: Allocator, io: Io, path: []const u8, env_name: []const u8) ?bool {
    var file = validation.load(allocator, io, path, .quiet) catch return null;
    defer file.deinit(allocator);
    const env = file.project.getEnvironment(env_name) orelse return false;
    return !env.python;
}

/// Whether the venv at `venv_path` has its interpreter link, bin/python.
fn venvHasPython(allocator: Allocator, io: Io, venv_path: []const u8) !bool {
    const py = try Io.Dir.path.join(allocator, &.{ venv_path, "bin", "python" });
    defer allocator.free(py);
    return runtime.exists(io, py);
}

/// Refuses a Python-only action on a Python-free env, saying how to enable it.
fn noPython(io: Io, env_name: []const u8, why: []const u8) error{NoPython} {
    output.printError(
        io,
        "'{s}' has no Python (\"python\": false in zenv.json); {s}.",
        .{ env_name, why },
    );
    output.printError(io, "Set \"python\": true for '{s}' in zenv.json to use it.", .{env_name});
    return error.NoPython;
}

/// The installer `zenv add` asks for: its own --uv/--pip, else the one the
/// env's last setup was given explicitly (a `--pip` env stays on pip), else
/// auto.
fn addInstaller(allocator: Allocator, io: Io, flags: Flags, venv_path: []const u8) cli.Installer {
    if (flags.installer() != .auto) return flags.installer();
    return autosetup.builtWith(allocator, io, venv_path).installer();
}

/// Installs `package` into the activated environment with `uv` (a path, from
/// `envbuild.resolveUv`), or pip when null. With uv in an env whose modules
/// provide Python packages, it is resolved against them as setup does
/// (`envbuild.addWithModules`). A non-zero installer exit maps to
/// error.ProcessError.
fn installPackage(
    ctx: Ctx,
    venv_path: []const u8,
    project_dir: []const u8,
    package: []const u8,
    uv: ?[]const u8,
) !void {
    const io = ctx.io;
    output.print(io, "Installing '{s}'...", .{package});
    if (uv) |exe| if (try launch.environ(ctx, venv_path)) |env| {
        if (envbuild.addWithModules(
            ctx,
            exe,
            venv_path,
            project_dir,
            &env,
            package,
            autosetup.builtWith(ctx.arena, io, venv_path),
        )) |done| {
            if (done) return;
        } else |err| {
            output.printError(io, "Package installation failed; nothing was recorded.", .{});
            return err;
        }
    };
    // uv is resolved on zenv's own PATH, as setup does: an activate.sh launch
    // purges modules, which would drop a uv that a module provides.
    const command: []const u8 = uv orelse "python";
    const cmd_args: []const []const u8 = if (uv != null)
        &.{ "pip", "install", package }
    else
        &.{ "-m", "pip", "install", "--no-build-isolation", package };

    const term = launch.start(ctx, venv_path, command, cmd_args, .wait) catch |err| {
        output.printError(io, "Failed to run installer: {t}", .{err});
        return err;
    };

    if (!term.success()) {
        output.printError(io, "Package installation failed; nothing was recorded.", .{});
        return error.ProcessError;
    }
}

/// The dependency group `zenv add` records into: the one `--group` names, else
/// `dev` for `--dev`, else null (a runtime dependency). Refuses several groups,
/// `--dev` with another group, and a dotted name, which is no bare TOML key.
fn addGroup(allocator: Allocator, io: Io, args: []const []const u8, flags: Flags) !?[]const u8 {
    const groups = try cli.groups(allocator, args);
    if (groups.len > 1) {
        output.printError(
            io,
            "'zenv add' records a package in one dependency group; got {d}.",
            .{groups.len},
        );
        return error.ArgsError;
    }
    if (groups.len == 0) return if (flags.dev_mode) "dev" else null;
    const group = groups[0];
    if (flags.dev_mode and !deps.sameName(group, "dev")) {
        output.printError(
            io,
            "'--dev' means '--group dev'; it cannot be combined with '--group {s}'.",
            .{group},
        );
        return error.ArgsError;
    }
    if (std.mem.findScalar(u8, group, '.') != null) {
        output.printError(
            io,
            "'zenv add' cannot record into group '{s}': a '.' in the name would make a nested TOML key. Add it by hand.",
            .{group},
        );
        return error.ArgsError;
    }
    return group;
}

/// `zenv add` for an env that runs in a container image, where the install has
/// to happen: records the package first, then rebuilds the env in the image
/// (`autosetup.ensureUpToDate`), which resolves it against the image's packages
/// like any dependency. A failed rebuild restores the manifest and the build
/// record, so the package is not left recorded.
fn addByRebuild(
    ctx: Ctx,
    entry: *const Registry.Entry,
    zenv_json_path: []const u8,
    record: sources.Record,
    package: []const u8,
) !void {
    const a = ctx.arena;
    const io = ctx.io;
    const cwd = Io.Dir.cwd();
    // Every manifest the add may change (pyproject falls back to zenv.json), as it was.
    var files: std.ArrayList([]const u8) = .empty;
    try files.append(a, zenv_json_path);
    if (record.file()) |f| try files.append(a, f);
    const saved = try a.alloc(?[]const u8, files.items.len);
    for (files.items, saved) |path, *s| {
        s.* = cwd.readFileAlloc(io, path, a, .limited(64 * 1024 * 1024)) catch null;
    }
    const restore = struct {
        fn all(io_: Io, paths_: []const []const u8, contents: []const ?[]const u8) void {
            for (paths_, contents) |path, content| {
                if (content) |data| {
                    Io.Dir.cwd().writeFile(io_, .{ .sub_path = path, .data = data }) catch {};
                } else Io.Dir.cwd().deleteFile(io_, path) catch {};
            }
        }
    }.all;
    var change = try autosetup.Change.begin(ctx, entry);

    sources.record(a, io, zenv_json_path, entry.env_name, record, package) catch |err| {
        restore(io, files.items, saved);
        output.printError(io, "Recording '{s}' failed: {t}.", .{ package, err });
        return error.RecordFailed;
    };
    // The rebuild installs a dependency group only if it replays it.
    if (record.group()) |g| _ = change.replayGroup(ctx, g);
    autosetup.ensureUpToDate(ctx, entry) catch |err| {
        restore(io, files.items, saved);
        change.abort(ctx);
        output.printError(
            io,
            "Installing '{s}' in the container image failed; the manifest is unchanged.",
            .{package},
        );
        return err;
    };
    output.print(io, "Added '{s}' to environment '{s}'.", .{ package, entry.env_name });
}

/// `zenv __exec <venv> <command> [args...]`, run by `launch.start` inside
/// an env's container: starts the command with the env applied, as `zenv run`
/// does outside one.
pub fn handleExecInside(ctx: Ctx, args: []const []const u8) !void {
    if (args.len < 4) return error.ArgsError;
    const term = launch.start(ctx, args[2], args[3], args[4..], .replace) catch |err| {
        output.printError(ctx.io, "Failed to run command: {t}", .{err});
        return err;
    };
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}
test "pythonDisabled reads only an explicit false in a valid zenv.json" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const root = ".zig-cache/tmp/zenv-python-disabled-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    const path = root ++ "/zenv.json";
    try cwd.writeFile(io, .{ .sub_path = path, .data =
        \\{ "base_dir": ".zenv", "off": { "target_machines": ["*"], "python": false }, "on": { "target_machines": ["*"], "python": true }, "unset": { "target_machines": ["*"] }, "nulls": { "target_machines": ["*"], "python": null, "dependency_file": null } }
    });
    try std.testing.expectEqual(@as(?bool, true), pythonDisabled(a, io, path, "off"));
    try std.testing.expectEqual(@as(?bool, false), pythonDisabled(a, io, path, "on"));
    try std.testing.expectEqual(@as(?bool, false), pythonDisabled(a, io, path, "unset"));
    try std.testing.expectEqual(@as(?bool, false), pythonDisabled(a, io, path, "nulls"));
    try std.testing.expectEqual(@as(?bool, false), pythonDisabled(a, io, path, "missing"));
    try std.testing.expectEqual(@as(?bool, null), pythonDisabled(a, io, root ++ "/nope.json", "off"));
    try cwd.writeFile(io, .{ .sub_path = path, .data = "{ bad" });
    try std.testing.expectEqual(@as(?bool, null), pythonDisabled(a, io, path, "off"));
}

pub fn handleLog(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const entry = registry.get(try resolveArg(ctx, registry, args, "log <name|id>"));
    const log_file_path = try Io.Dir.path.join(ctx.arena, &.{ entry.venv_path, "zenv_setup.log" });

    const log_file = Io.Dir.cwd().openFile(io, log_file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            output.printError(io, "No setup log found for environment '{s}'", .{entry.env_name});
            output.printError(io, "The log file should be at: {s}", .{log_file_path});
        } else {
            output.printError(io, "Failed to read log file '{s}': {t}", .{ log_file_path, err });
        }
        return err;
    };
    defer log_file.close(io);

    // Streamed file to stdout: no size limit and no copy in memory.
    var read_buf: [64 * 1024]u8 = undefined;
    var write_buf: [64 * 1024]u8 = undefined;
    var reader = log_file.reader(io, &read_buf);
    var stdout = Io.File.stdout().writerStreaming(io, &write_buf);
    _ = stdout.interface.sendFileAll(&reader, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.WriteFailed => return stdout.err.?,
    };
    stdout.interface.flush() catch return stdout.err.?;
}

pub fn handleValidate(ctx: Ctx, args: []const []const u8) !void {
    const io = ctx.io;
    var validate_config_path: []const u8 = "zenv.json";

    if (args.len > 2) {
        validate_config_path = args[2];
        output.print(io, "Using provided file path: {s}", .{validate_config_path});
    } else {
        output.print(io, "Using default config path: {s}", .{validate_config_path});
    }

    if (Io.Dir.cwd().access(io, validate_config_path, .{})) |_| {
        output.print(io, "File exists, proceeding with validation", .{});
    } else |err| {
        output.printError(io, "Failed to open file '{s}': {t}", .{ validate_config_path, err });
        std.process.exit(1);
    }

    // load prints what it finds; any finding or failure exits 1.
    var file = validation.load(
        ctx.arena,
        io,
        validate_config_path,
        .loud,
    ) catch std.process.exit(1);
    file.deinit(ctx.arena);
    output.print(io, "Configuration file is valid!", .{});
}

pub fn handleAlias(
    ctx: Ctx,
    registry: *Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const Sub = enum { create, remove, ls, list, show };
    switch (try subcommandOf(
        Sub,
        io,
        args,
        "alias",
        "zenv alias <create|remove|ls|show> [arguments]",
    )) {
        .create => try handleAliasCreate(ctx, registry, args),
        .remove => try handleAliasRemove(io, registry, args),
        .ls, .list => handleAliasList(io, registry),
        .show => try handleAliasShow(io, registry, args),
    }
}

fn handleAliasCreate(
    ctx: Ctx,
    registry: *Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const env_identifier = try argAt(
        io,
        args,
        4,
        "Missing arguments for alias create.\nUsage: zenv alias create <alias_name> <env_name|env_id>",
    );
    const alias_name = args[3];

    // An alias must not read like a command.
    if (std.meta.stringToEnum(Command, alias_name) != null) {
        output.printError(io, "Alias name '{s}' conflicts with existing command.", .{alias_name});
        return error.ArgsError;
    }

    if (std.mem.eql(u8, alias_name, ".")) {
        output.printError(io, "Alias name '.' is reserved for current directory notation.", .{});
        return error.ArgsError;
    }

    const target_ref = try resolve(ctx, registry, env_identifier);
    // Owned: addAlias re-reads the registry, which frees the entry's strings.
    const target_env_name = try allocator.dupe(u8, registry.get(target_ref).env_name);
    defer allocator.free(target_env_name);
    const target_id = try allocator.dupe(u8, registry.get(target_ref).id);

    registry.addAlias(alias_name, target_id) catch |err| {
        switch (err) {
            error.EnvironmentNotFound => output.printError(
                io,
                "Environment '{s}' not found.",
                .{env_identifier},
            ),
            error.AliasAlreadyExists => output.printError(
                io,
                "Alias '{s}' already exists.",
                .{alias_name},
            ),
            error.InvalidEnvironmentName => output.printError(
                io,
                "Invalid alias '{s}': use letters, digits, '_', '-' and '.' (not '.' or '..').",
                .{alias_name},
            ),
            else => output.printError(io, "Failed to create alias: {t}", .{err}),
        }
        return err;
    };

    output.print(
        io,
        "Alias '{s}' created for environment '{s}'.",
        .{ alias_name, target_env_name },
    );
}

fn handleAliasRemove(
    io: Io,
    registry: *Registry,
    args: []const []const u8,
) !void {
    const alias_name = try argAt(
        io,
        args,
        3,
        "Missing alias name.\nUsage: zenv alias remove <alias_name>",
    );

    if (registry.removeAlias(alias_name) catch |err| {
        output.printError(io, "Failed to update registry: {t}", .{err});
        return err;
    }) {
        output.print(io, "Alias '{s}' removed.", .{alias_name});
    } else {
        output.printError(io, "Alias '{s}' not found.", .{alias_name});
        return error.AliasNotFound;
    }
}

fn handleAliasList(io: Io, registry: *const Registry) void {
    var any = false;
    for (registry.entries.items) |entry| for (entry.aliases.items) |alias| {
        if (!any) output.print(io, "Defined aliases:", .{});
        any = true;
        output.print(io, "  {s} -> {s}", .{ alias, entry.env_name });
    };
    if (!any) output.print(io, "No aliases defined.", .{});
}

fn handleAliasShow(
    io: Io,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const alias_name = try argAt(
        io,
        args,
        3,
        "Missing alias name.\nUsage: zenv alias show <alias_name>",
    );

    // An alias may be shared across several per-machine environments, so list
    // every holder with its target machines (resolution picks by current host).
    var found = false;
    for (registry.entries.items) |entry| {
        if (!entry.hasAlias(alias_name)) continue;
        if (!found) output.print(io, "Alias '{s}' resolves to:", .{alias_name});
        found = true;
        output.print(io, "  {s} (target: {s})", .{ entry.env_name, entry.target_machines_str });
    }
    if (!found) {
        output.printError(io, "Alias '{s}' not found.", .{alias_name});
        return error.AliasNotFound;
    }
}

pub fn handleJupyter(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const Sub = enum { create, remove, ls, list, check };
    switch (try subcommandOf(
        Sub,
        io,
        args,
        "jupyter",
        "zenv jupyter <create|remove|ls|check> [arguments]",
    )) {
        .create => try handleJupyterCreate(ctx, registry, args),
        .remove => try handleJupyterRemove(ctx, registry, args),
        .ls, .list => try jupyter.listKernels(ctx),
        .check => try jupyter.check(ctx),
    }
}

fn handleJupyterCreate(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const identifier = try argAt(
        io,
        args,
        3,
        "Missing environment name argument.\nUsage: zenv jupyter create <name|id|.> [--name <kernel_name>] [--display-name <display_name>]",
    );
    var custom_name: ?[]const u8 = null;
    var custom_display_name: ?[]const u8 = null;

    var i: usize = 4;
    while (i < args.len) : (i += 2) {
        const slot = if (std.mem.eql(u8, args[i], "--name"))
            &custom_name
        else if (std.mem.eql(u8, args[i], "--display-name"))
            &custom_display_name
        else {
            output.printError(
                io,
                "Unknown option '{s}' for 'zenv jupyter create'. Options: --name, --display-name",
                .{args[i]},
            );
            return error.ArgsError;
        };
        if (i + 1 >= args.len) {
            output.printError(io, "Option '{s}' needs a value.", .{args[i]});
            return error.ArgsError;
        }
        slot.* = args[i + 1];
    }

    // Same host-aware resolver as every other command: ids, aliases and "."
    // work, and on a shared filesystem the kernel binds to THIS machine's env.
    const ref = try resolve(ctx, registry, identifier);
    const entry = registry.get(ref);
    const zenv_json_path = try Io.Dir.path.join(ctx.arena, &.{ entry.project_dir, "zenv.json" });
    // With an unusable zenv.json the env is used as last built (the gate says
    // so); whether it has Python is then read off its venv.
    const disabled = pythonDisabled(ctx.arena, io, zenv_json_path, entry.env_name) orelse
        !runtime.lexists(io, try Io.Dir.path.join(ctx.arena, &.{ entry.venv_path, "bin", "python" }));
    if (disabled) return noPython(
        io,
        entry.env_name,
        "a Jupyter kernel needs Python",
    );
    // Rebuild the env first if its config/dependency files changed (silent), so
    // the kernel is created against an up-to-date environment.
    try autosetup.ensureUpToDate(ctx, entry);

    try jupyter.createKernel(
        ctx,
        entry.env_name,
        entry.venv_path,
        registry.launchIdentifier(ref),
        custom_name,
        custom_display_name,
    );
}

fn handleJupyterRemove(
    ctx: Ctx,
    registry: *const Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    // Resolve through the registry so aliases/ids work. Only a name that is not
    // registered at all falls back to the raw name (a kernel whose environment
    // was already deregistered); an ambiguous or '.' identifier must not be
    // guessed into a kernel name.
    const identifier = try argAt(
        io,
        args,
        3,
        "Missing environment name argument.\nUsage: zenv jupyter remove <env_name>",
    );
    const env_name = blk: {
        const ref = registry.resolve(ctx.arena, identifier) catch |e| {
            if (e == error.EnvironmentNotRegistered and paths.isValidEnvName(
                identifier,
            )) break :blk identifier;
            return explainResolveError(ctx, registry, identifier, e);
        };
        break :blk registry.get(ref).env_name;
    };
    try jupyter.removeKernel(ctx, env_name);
}

pub fn handleRename(
    ctx: Ctx,
    registry: *Registry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    if (args.len < 4) {
        output.printError(io, "Usage: zenv rename <old_name|id> <new_name>", .{});
        return error.ArgsError;
    }

    const old_identifier = args[2];
    const new_name = args[3];

    // Everything that can refuse the rename is checked before anything moves.
    // The name becomes a directory next to the venv, so it must not be a path.
    try requireValidEnvName(io, new_name);
    var ref = try resolve(ctx, registry, old_identifier);
    if (registry.nameTaken(new_name, registry.get(ref).project_dir)) {
        output.printError(io, "'{s}' is already an environment name, alias or id.", .{new_name});
        return error.EnvironmentAlreadyExists;
    }

    // Owned copies: the FS orchestration and rollback messages need these to
    // outlive registry.rename (which frees the entry's copies).
    const old_name = try allocator.dupe(u8, registry.get(ref).env_name);
    defer allocator.free(old_name);
    const old_venv_path = try allocator.dupe(u8, registry.get(ref).venv_path);
    defer allocator.free(old_venv_path);
    const project_dir = try allocator.dupe(u8, registry.get(ref).project_dir);
    defer allocator.free(project_dir);

    // The project's zenv.json gets the new name too, so it must not define
    // that name already (the env would then run with the other entry's config).
    {
        const config_path = try Io.Dir.path.join(allocator, &.{ project_dir, "zenv.json" });
        if (manifest.ZenvJson.read(allocator, io, config_path)) |file| {
            if (file.root.contains(new_name)) {
                output.printError(
                    io,
                    "{s} already defines '{s}'. Pick another name, or remove that entry first.",
                    .{ config_path, new_name },
                );
                return error.EnvironmentAlreadyExists;
            }
        } else |_| {}
    }

    const parent_dir = std.Io.Dir.path.dirname(old_venv_path) orelse {
        output.printError(io, "Invalid virtual environment path", .{});
        return error.InvalidPath;
    };
    const new_venv_path = try Io.Dir.path.join(allocator, &.{ parent_dir, new_name });
    defer allocator.free(new_venv_path);

    if (Io.Dir.cwd().access(io, new_venv_path, .{})) |_| {
        output.printError(io, "New environment directory already exists: {s}", .{new_venv_path});
        return error.PathAlreadyExists;
    } else |err| if (err != error.FileNotFound) return err;

    // The activation scripts are regenerated from zenv-env.json.
    {
        const spec = envspec.read(allocator, io, old_venv_path) orelse {
            output.printError(
                io,
                "{s} has no usable {s}; re-run 'zenv setup {s}' first.",
                .{ old_venv_path, envspec.file_name, old_name },
            );
            return error.MissingEnvSpec;
        };
        spec.deinit();
    }

    // An env that is up to date now must not rebuild after the rename: the
    // build record hashes the env's name.
    const change = try autosetup.Change.begin(ctx, registry.get(ref));
    const has_jupyter_kernel = jupyter.hasKernel(ctx, old_name);

    output.print(io, "Renaming environment '{s}' to '{s}'...", .{ old_name, new_name });

    const cwd = Io.Dir.cwd();
    cwd.rename(old_venv_path, cwd, new_venv_path, io) catch |err| {
        output.printError(io, "Failed to rename environment directory: {t}", .{err});
        return error.IoError;
    };

    updateGeneratedScripts(ctx, new_name, old_venv_path, new_venv_path) catch |err| {
        undoMove(ctx, old_name, new_venv_path, old_venv_path);
        return err;
    };

    registry.rename(&ref, new_name) catch |err| {
        undoMove(ctx, old_name, new_venv_path, old_venv_path);
        switch (err) {
            error.EnvironmentAlreadyExists => output.printError(
                io,
                "'{s}' is already an environment name, alias or id.",
                .{new_name},
            ),
            else => output.printError(io, "Failed to update registry: {t}", .{err}),
        }
        return err;
    };

    if (has_jupyter_kernel) {
        jupyter.renameKernel(ctx, old_name, new_name) catch |err| {
            registry.rename(&ref, old_name) catch {}; // re-saves; ref is kept current
            undoMove(ctx, old_name, new_venv_path, old_venv_path);
            switch (err) {
                error.KernelExists => output.printError(
                    io,
                    "Jupyter kernel '{s}' already exists",
                    .{new_name},
                ),
                else => output.printError(io, "Failed to rename Jupyter kernel: {t}", .{err}),
            }
            return err;
        };
    }

    output.print(io, "Environment renamed successfully!", .{});
    output.print(io, "  Name: {s} → {s}", .{ old_name, new_name });
    output.print(io, "  Directory: {s} → {s}", .{ old_venv_path, new_venv_path });
    if (has_jupyter_kernel) {
        output.print(io, "  Jupyter kernel: zenv-{s} → zenv-{s}", .{ old_name, new_name });
    }
    output.print(io, "  Generated scripts updated", .{});

    updateLocalConfigs(ctx, old_name, new_name, project_dir) catch |err| {
        output.printError(
            io,
            "Environment renamed, but {s}/zenv.json could not be updated ({t}): rename '{s}' to '{s}' there by hand.",
            .{ project_dir, err, old_name, new_name },
        );
        return error.RecordFailed;
    };
    change.finish(ctx, project_dir, new_name, new_venv_path);
}

/// Rolls back a rename's directory move: moves the venv back to `old_venv_path`
/// FIRST, then regenerates its scripts there (they are read from the venv's
/// current location). Best effort; says what to do if it cannot.
fn undoMove(
    ctx: Ctx,
    old_name: []const u8,
    new_venv_path: []const u8,
    old_venv_path: []const u8,
) void {
    const io = ctx.io;
    const cwd = Io.Dir.cwd();
    cwd.rename(new_venv_path, cwd, old_venv_path, io) catch |err| {
        output.printError(
            io,
            "Could not move {s} back to {s}: {t}. Move it back by hand.",
            .{ new_venv_path, old_venv_path, err },
        );
        return;
    };
    updateGeneratedScripts(ctx, old_name, new_venv_path, old_venv_path) catch {
        output.printError(
            io,
            "Could not restore the scripts of '{s}'; re-run 'zenv setup {s}'.",
            .{ old_name, old_name },
        );
    };
}

/// Points a venv moved from `from_path` to `to_path` (where it is now) at its
/// location and `name`: the activation scripts are regenerated from the stored
/// zenv-env.json, and paths are rewritten in the user's hook scripts and in
/// bin/ (console-script shebangs). Also used, swapped, to roll a rename back.
fn updateGeneratedScripts(
    ctx: Ctx,
    name: []const u8,
    from_path: []const u8,
    to_path: []const u8,
) !void {
    const io = ctx.io;
    const parsed = envspec.read(ctx.arena, io, to_path) orelse {
        output.printError(
            io,
            "{s} has no usable {s}; re-run 'zenv setup' for this environment first.",
            .{ to_path, envspec.file_name },
        );
        return error.MissingEnvSpec;
    };
    defer parsed.deinit();

    // A hook-script copy that cannot be rewritten fails (and so rolls back)
    // the rename; a bin/ script that cannot only warns.
    rewriteVenvPaths(ctx.arena, io, to_path, "scripts", from_path, true) catch |err| {
        output.printError(io, "Failed to update scripts directory: {t}", .{err});
        return err;
    };
    rewriteVenvPaths(ctx.arena, io, to_path, "bin", from_path, false) catch |err| {
        output.printError(io, "Failed to update venv bin/ scripts: {t}", .{err});
        return err;
    };

    const moved = try envspec.relocate(ctx.arena, &parsed.value, from_path, to_path, name);
    activation.writeFiles(ctx.arena, io, &moved) catch |err| {
        output.printError(io, "Failed to regenerate activation scripts: {t}", .{err});
        return err;
    };
}

/// Rewrites `old_venv_path` to `venv_path` in the text files of
/// `<venv_path>/<sub>`. In `scripts` these are the copies of the user's hook
/// scripts; in `bin`, console-script shebangs written by pip/uv
/// (`#!<venv>/bin/python`, or the `/bin/sh` exec trampoline pip uses for long
/// paths) and activate scripts, without which `pip` and other installed
/// commands break after a rename. Binaries and symlinks (the python links
/// point outside the venv) are left alone. With `strict`, a file that cannot
/// be read or written fails the walk; otherwise a file that cannot be read
/// (or is over 1 MiB) is not ours to edit, and a failed write only warns.
fn rewriteVenvPaths(
    allocator: Allocator,
    io: Io,
    venv_path: []const u8,
    sub: []const u8,
    old_venv_path: []const u8,
    strict: bool,
) !void {
    const dir_path = try Io.Dir.path.join(allocator, &.{ venv_path, sub });
    defer allocator.free(dir_path);

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // Not through symlinks: the python links point outside the venv.
        if (try runtime.kindOf(io, dir, entry, .{ .follow_symlinks = false }) != .file) continue;

        const content = dir.readFileAlloc(
            io,
            entry.name,
            allocator,
            .limited(1024 * 1024),
        ) catch |err| {
            if (!strict) continue;
            output.printError(io, "Failed to update {s}/{s}: {t}", .{ dir_path, entry.name, err });
            return err;
        };
        defer allocator.free(content);
        if (std.mem.findScalar(u8, content, 0) != null) continue; // binary
        if (std.mem.find(u8, content, old_venv_path) == null) continue;

        const updated = try std.mem.replaceOwned(u8, allocator, content, old_venv_path, venv_path);
        defer allocator.free(updated);
        // In place: keeps the file's mode (the executable bit) and inode.
        dir.writeFile(io, .{ .sub_path = entry.name, .data = updated }) catch |err| {
            output.printError(io, "Failed to update {s}/{s}: {t}", .{ dir_path, entry.name, err });
            if (strict) return err;
        };
    }
}

test "rewriteVenvPaths rewrites text files and leaves binaries alone" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const root = ".zig-cache/tmp/zenv-rewrite-venv-paths-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/new/bin");
    try cwd.createDirPath(io, root ++ "/new/scripts");
    try cwd.writeFile(
        io,
        .{ .sub_path = root ++ "/new/bin/pip", .data = "#!/old/venv/bin/python\nimport pip\n" },
    );
    try cwd.writeFile(io, .{ .sub_path = root ++ "/new/bin/blob", .data = "/old/venv\x00binary" });
    try cwd.writeFile(
        io,
        .{ .sub_path = root ++ "/new/scripts/activate_hook.sh", .data = "echo /old/venv/x\n" },
    );

    try rewriteVenvPaths(a, io, root ++ "/new", "bin", "/old/venv", false);
    try rewriteVenvPaths(a, io, root ++ "/new", "scripts", "/old/venv", true);
    try rewriteVenvPaths(a, io, root ++ "/new", "missing", "/old/venv", true);

    const cases = [_][2][]const u8{
        .{ root ++ "/new/bin/pip", "#!" ++ root ++ "/new/bin/python\nimport pip\n" },
        .{ root ++ "/new/bin/blob", "/old/venv\x00binary" },
        .{ root ++ "/new/scripts/activate_hook.sh", "echo " ++ root ++ "/new/x\n" },
    };
    for (cases) |case| {
        const got = try cwd.readFileAlloc(io, case[0], a, .limited(1024));
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

fn updateLocalConfigs(
    ctx: Ctx,
    old_name: []const u8,
    new_name: []const u8,
    project_dir: []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const config_path = try Io.Dir.path.join(allocator, &.{ project_dir, "zenv.json" });

    output.print(io, "Updating local config: {s}", .{config_path});

    const file = manifest.ZenvJson.read(allocator, io, config_path) catch |err| switch (err) {
        error.FileNotFound => {
            output.print(io, "No local config file found, skipping update", .{});
            return; // No config file, that's fine
        },
        error.InvalidFormat => {
            output.printError(io, "Local config is not a valid JSON object, skipping update", .{});
            return;
        },
        else => {
            output.printError(io, "Failed to open config file: {t}", .{err});
            return err;
        },
    };
    const root = file.root;

    const index = root.getIndex(old_name) orelse {
        output.print(
            io,
            "Environment '{s}' not found in local config, skipping update",
            .{old_name},
        );
        return;
    };
    if (root.contains(new_name)) {
        output.printError(
            io,
            "Local config already has an entry '{s}'; not updating it",
            .{new_name},
        );
        return;
    }

    output.print(
        io,
        "Found environment '{s}' in local config, updating to '{s}'",
        .{ old_name, new_name },
    );

    // Rewrite the TOP-LEVEL key only, at its span, so comments and layout stay.
    // Unlike a search-and-replace, this can never touch a nested key or a
    // string value that happens to contain the name.
    const key = (try file.members(allocator))[index].key;
    try file.write(allocator, io, config_path, .{
        .span = key,
        .text = try std.json.Stringify.valueAlloc(allocator, new_name, .{}),
    });

    output.print(io, "Successfully updated local config file", .{});
}
