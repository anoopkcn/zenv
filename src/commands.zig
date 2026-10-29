const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const flags_module = @import("utils/flags.zig");
const CommandFlags = flags_module.CommandFlags;
const Flag = flags_module.Flag;
const positional = flags_module.positional;
const unknownFlag = flags_module.unknownFlag;
const paths = @import("utils/paths.zig");
const env = @import("utils/environment.zig");
const host = @import("utils/host.zig");
const deps = @import("utils/parse_deps.zig");
const envbuild = @import("utils/envbuild.zig");
const autosetup = @import("utils/autosetup.zig");
const manifest = @import("utils/manifest.zig");
const python = @import("utils/python.zig");
const jupyter = @import("utils/jupyter.zig");
const configurations = @import("utils/config.zig");
const validation = @import("utils/validation.zig");
const output = @import("utils/output.zig");
const runtime = @import("utils/runtime.zig");
const envspec = @import("utils/envspec.zig");
const activation = @import("utils/activation.zig");
const shell_hook = @import("utils/hook.zig");
const ZenvConfig = configurations.ZenvConfig;
const EnvironmentRegistry = configurations.EnvironmentRegistry;
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
    unknown,
};

/// The flags each command takes (see printUsage in main.zig).
pub const SETUP_FLAGS = [_]Flag{ .@"--init", .@"--no-python", .@"--dev", .@"--uv", .@"--pip", .@"--no-host", .@"--python", .@"--force", .@"--no-cache", .@"--jupyter", .@"--reuse-module-cache", .@"--group" };
const REGISTER_FLAGS = [_]Flag{.@"--no-host"};
const ADD_FLAGS = [_]Flag{ .@"--dev", .@"--group", .@"--zenv", .@"--uv", .@"--pip" };

/// Refuses a flag that `zenv <command>` does not take, naming the ones it
/// does, and two flags that contradict each other.
pub fn checkFlags(io: Io, args: []const []const u8, allowed: []const Flag) error{ArgsError}!void {
    if (unknownFlag(args, allowed)) |bad| {
        output.printError(io, "Unknown option '{s}' for 'zenv {s}'. Options: {f}", .{ bad, args[1], joinedList(Flag, allowed) });
        return error.ArgsError;
    }
    if (flags_module.badGroup(args)) |bad| {
        output.printError(io, "'--group' needs a dependency group name (letters and digits, with '.', '_' or '-' inside), got '{s}'.", .{bad});
        return error.ArgsError;
    }
    const pair = flags_module.conflict(args) orelse return;
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

/// The starter zenv.json for `zenv init`: one environment for any machine,
/// with every key present so users can see what is configurable. Written with
/// the JSON writer, so a name or description containing `"` or `\` stays
/// valid JSON. Caller owns the result.
fn initConfigJson(allocator: Allocator, env_name: []const u8, description: []const u8, dependency_file: ?[]const u8, with_python: bool) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    const none: []const []const u8 = &.{};
    const hook = .{ .commands = none, .script = null };

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
        .setup = hook,
        .activate = hook,
    }) else try s.write(.{
        .target_machines = [_][]const u8{"*"},
        .description = description,
        .python = false,
        .modules = none,
        .modules_file = null,
        .module_cache = true,
        .env = struct {}{},
        .setup = hook,
        .activate = hook,
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
    try std.testing.expect(std.mem.startsWith(u8, text, "{\n  \"base_dir\": \".zenv\",\n  \"my\\\"env\": {"));

    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const env_obj = parsed.value.object.get("my\"env").?.object;
    try std.testing.expectEqualStrings("a \\ \"quoted\" desc", env_obj.get("description").?.string);
    try std.testing.expectEqualStrings("*", env_obj.get("target_machines").?.array.items[0].string);
    try std.testing.expectEqualStrings("requirements.txt", env_obj.get("dependency_file").?.string);
    try std.testing.expect(env_obj.get("module_cache").?.bool);
    try std.testing.expect(env_obj.get("activate").?.object.get("script").? == .null);
    const keys = [_][]const u8{ "target_machines", "description", "fallback_python", "modules", "modules_file", "module_cache", "dependencies", "dependency_file", "setup", "activate" };
    try std.testing.expectEqual(keys.len, env_obj.count());
    for (keys, env_obj.keys()) |want, got| try std.testing.expectEqualStrings(want, got);

    const no_deps = try initConfigJson(a, "e", "d", null, true);
    defer a.free(no_deps);
    try std.testing.expect(std.mem.find(u8, no_deps, "\"dependency_file\": null") != null);
}

const INIT_USAGE =
    \\Usage: zenv init [name] [description] [--no-python]
    \\Creates zenv.json with environment <name>, or adds <name> to an existing zenv.json.
    \\  name         defaults to the current directory's name
    \\  description  defaults to [project].description from pyproject.toml, if any
    \\  --no-python  an environment without Python, for modules, env variables and settings
;

pub const InitOutcome = enum { created, added, exists };

/// Defines environment `env_name` in ./zenv.json: writes a new file, or adds
/// the env to an existing one. `exists` (nothing written) when the file
/// already defines it. A null `description` is taken from pyproject.toml.
/// Without `with_python`, the env is written Python-free (`"python": false`).
/// Allocates with `a` (use an arena).
pub fn initConfig(a: Allocator, io: Io, env_name: []const u8, description: ?[]const u8, with_python: bool) !InitOutcome {
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
        const content = cwd.readFileAlloc(io, "pyproject.toml", a, .limited(10 * 1024 * 1024)) catch break :pyproject null;
        break :pyproject try deps.pyprojectField(a, content, "description");
    } orelse "Env config created by zenv";

    const template = try initConfigJson(a, env_name, desc, dependency_file, with_python);

    // Creating the file is the existence check: no window for another zenv
    // to create it in between.
    cwd.writeFile(io, .{ .sub_path = config_path, .data = template, .flags = .{ .exclusive = true } }) catch |err| switch (err) {
        error.PathAlreadyExists => return if (try manifest.addEnvToZenvJson(a, io, config_path, env_name, template)) .added else .exists,
        else => return err,
    };
    return .created;
}

/// Refuses `name` unless it can be an environment name (paths.isValidEnvName).
pub fn requireValidEnvName(io: Io, name: []const u8) error{InvalidEnvironmentName}!void {
    if (paths.isValidEnvName(name)) return;
    output.printError(io, "Invalid environment name '{s}'. Use only letters, digits, '-', '_' and '.'.", .{name});
    return error.InvalidEnvironmentName;
}

/// An env name from directory `dir`'s name: characters an env name cannot
/// hold become '-'. "test" when nothing usable is left.
pub fn defaultEnvName(allocator: Allocator, dir: []const u8) ![]u8 {
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
    const keys = [_][]const u8{ "target_machines", "description", "python", "modules", "modules_file", "module_cache", "env", "setup", "activate" };
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

pub fn handleInitCommand(ctx: Ctx, args: []const []const u8) void {
    const io = ctx.io;
    const allocator = ctx.arena;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            output.rawOut(io, INIT_USAGE ++ "\n", .{});
            return;
        }
    }
    if (unknownFlag(args, &.{.@"--no-python"})) |arg| {
        output.printError(io, "Unknown option '{s}' for 'zenv init'.\n" ++ INIT_USAGE, .{arg});
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

    const python_env = !CommandFlags.fromArgs(args).no_python;
    const outcome = initConfig(allocator, io, env_name, positional(args, 1), python_env) catch |err| {
        if (err == error.InvalidFormat) {
            output.printError(io, "zenv.json exists but is not a JSON object; fix it or remove it first.", .{});
        } else {
            output.printError(io, "Writing zenv.json: {t}", .{err});
        }
        std.process.exit(1);
    };
    switch (outcome) {
        .created, .added => {
            const what = if (outcome == .created) "Created zenv.json with" else "Added to zenv.json:";
            const kind = if (python_env) "environment" else "Python-free environment";
            output.print(io, "{s} {s} '{s}'. Run 'zenv setup {s}'", .{ what, kind, env_name, env_name });
        },
        .exists => {
            output.printError(io, "zenv.json already defines environment '{s}'. Pick another name: zenv init <name>", .{env_name});
            std.process.exit(1);
        },
    }
}

pub fn handleSetupCommand(
    ctx: Ctx,
    config: *ZenvConfig,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) anyerror!void {
    const io = ctx.io;
    const allocator = ctx.arena;
    // Parse command-line flags
    const flags = CommandFlags.fromArgs(args);

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
        output.print(io, "No-cache flag detected. Will disable package cache during dependency installation.", .{});
    }

    // Get and validate the environment config
    const env_config = try env.getAndValidateEnvironment(ctx, config, args, flags);
    // Non-null: getAndValidateEnvironment just errored otherwise.
    const env_name = positional(args, 0).?;
    const groups = try flags_module.groups(allocator, args);

    if (!env_config.python) {
        if (flags.dev_mode) return noPython(io, env_name, "--dev installs the project into it");
        if (groups.len > 0) return noPython(io, env_name, "--group installs packages into it");
        if (flags.create_jupyter_kernel) return noPython(io, env_name, "--jupyter needs Python");
    }

    const display_target = if (env_config.target_machines.items.len > 0) env_config.target_machines.items[0] else "any";

    // Set up logging to a file inside the environment directory. Setup runs in
    // the project directory, so cwd is the anchor for a relative base_dir.
    const setup_cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(setup_cwd);

    // Refuse to create an environment whose base dir resolves to the global
    // ZENV_DIR (e.g. `zenv setup` from $HOME with default base_dir `.zenv` and
    // ZENV_DIR unset -> ~/.zenv). That would overwrite registry.json, python
    // installs and other global state. Guard here, before any logging or
    // directory creation. See paths.baseDirIsZenvDir.
    {
        const zenv_dir = try paths.getZenvDir(allocator, ctx.env);
        defer allocator.free(zenv_dir);
        if (try paths.baseDirIsZenvDir(allocator, io, setup_cwd, config.base_dir, zenv_dir)) {
            output.printError(io, "Refusing to set up: base directory '{s}' resolves to ZENV_DIR ('{s}').", .{ config.base_dir, zenv_dir });
            output.printError(io, "This would overwrite global zenv state. Run setup from a project directory, set a different 'base_dir' in zenv.json, or point ZENV_DIR elsewhere.", .{});
            return error.BaseDirIsZenvDir;
        }
    }

    const env_dir_path = try paths.venvPath(allocator, setup_cwd, config.base_dir, env_name);
    defer allocator.free(env_dir_path);

    // The env directory holds the setup log, so it is created first.
    try Io.Dir.cwd().createDirPath(io, env_dir_path);
    const log_path = try Io.Dir.path.join(allocator, &.{ env_dir_path, "zenv_setup.log" });
    defer allocator.free(log_path);

    try output.startLogging(io, log_path);
    defer output.stopLogging(io);

    // Log the command that was used to start the setup
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

    // 1. Combine Dependencies. The list and the strings parsed from the
    // dependency file live in `allocator` (main's arena); config strings are borrowed.
    var all_required_deps: std.ArrayList([]const u8) = .empty;

    // Add dependencies from config
    if (env_config.dependencies.items.len > 0) {
        output.print(io, "Adding {d} dependencies from configuration:", .{env_config.dependencies.items.len});
        for (env_config.dependencies.items) |dep| {
            output.print(io, "  - Config dependency: {s}", .{dep});
        }
        try all_required_deps.appendSlice(allocator, env_config.dependencies.items);
    } else {
        output.print(io, "No dependencies specified in configuration.", .{});
    }

    // Add development dependencies from config (e.g. those recorded by
    // `zenv add --dev`).
    if (env_config.dev_dependencies.items.len > 0) {
        output.print(io, "Adding {d} development dependencies from configuration:", .{env_config.dev_dependencies.items.len});
        for (env_config.dev_dependencies.items) |dep| {
            output.print(io, "  - Dev dependency: {s}", .{dep});
        }
        try all_required_deps.appendSlice(allocator, env_config.dev_dependencies.items);
    }

    // The project's requires-python, from a pyproject.toml dependency file;
    // with --dev, ./pyproject.toml (the project pip installs) takes precedence.
    var requires_python: ?envbuild.RequiresPython = null;

    // Add dependencies from requirements file if specified
    if (env_config.dependency_file) |req_file| {
        const req_content = Io.Dir.cwd().readFileAlloc(io, req_file, allocator, .limited(1 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                output.printError(io, "Requirements file specified in configuration ('{s}') not found.", .{req_file});
                return err;
            }
            output.printError(io, "Failed to read file '{s}': {t}", .{ req_file, err });
            return error.PathResolutionFailed;
        };
        output.print(io, "Reading dependencies from file: '{s}'", .{req_file});
        output.print(io, "Successfully read file ({d} bytes). Parsing dependencies...", .{req_content.len});

        const is_toml = std.mem.endsWith(u8, req_file, ".toml");
        output.print(io, "{s}", .{if (is_toml) "Detected TOML file format, parsing as pyproject.toml" else "Parsing as requirements.txt format"});
        const req_file_dep_count = if (is_toml)
            try deps.parsePyprojectToml(allocator, io, req_content, &all_required_deps)
        else
            try deps.parseRequirementsTxt(allocator, io, req_content, &all_required_deps);
        if (is_toml) if (try deps.pyprojectField(allocator, req_content, "requires-python")) |spec| {
            requires_python = .{ .spec = spec, .file = req_file };
        };

        if (req_file_dep_count > 0) {
            output.print(io, "Added {d} dependencies from file '{s}'", .{ req_file_dep_count, req_file });
        } else {
            output.print(io, "Warning: No valid dependencies found in file '{s}'", .{req_file});
        }
    } else {
        output.print(io, "No requirements file specified in configuration.", .{});
    }

    // Dependency groups named with --group (PEP 735).
    if (groups.len > 0) {
        const file = groupsFile(env_config.dependency_file);
        const content = Io.Dir.cwd().readFileAlloc(io, file, allocator, .limited(10 * 1024 * 1024)) catch |err| {
            if (err != error.FileNotFound) return err;
            output.printError(io, "--group reads [dependency-groups] from '{s}', which does not exist.", .{file});
            return error.DependencyGroupNotFound;
        };
        const group_dep_count = try deps.parseDependencyGroups(allocator, io, content, file, groups, &all_required_deps);
        output.print(io, "Added {d} dependencies from dependency groups in '{s}'", .{ group_dep_count, file });
    }

    if (flags.dev_mode and env_config.python) {
        if (Io.Dir.cwd().readFileAlloc(io, "pyproject.toml", allocator, .limited(10 * 1024 * 1024))) |content| {
            if (try deps.pyprojectField(allocator, content, "requires-python")) |spec| requires_python = .{ .spec = spec, .file = "pyproject.toml" };
        } else |_| {}
    }

    // Debug output - print the combined dependencies
    output.print(io, "Combined dependency list ({d} items):", .{all_required_deps.items.len});
    for (all_required_deps.items) |dep| {
        output.print(io, "  - {s}", .{dep});
    }

    // 2. Build the environment: modules, venv, dependencies, hooks.
    try envbuild.run(ctx, .{
        .env_config = env_config,
        .env_name = env_name,
        .venv_dir = env_dir_path,
        .project_dir = setup_cwd,
        .deps = all_required_deps.items,
        .flags = flags,
        .requires_python = requires_python,
    });
    output.print(io, "Environment '{s}' setup completed successfully.", .{env_name});

    // 3. Record activation as data (zenv-env.json) and render the per-shell
    // activation scripts from it.
    try activation.generate(allocator, io, env_config, env_name, env_dir_path);

    // 4. Register the environment in the global registry; register() persists
    // registry.json itself (like deregister/rename).
    try registry.register(
        env_name,
        setup_cwd,
        config.base_dir,
        env_config.description,
        env_config.target_machines.items,
    );

    // Create Jupyter kernel if requested. Registry names are unique, so the
    // entry just registered has exactly this name and venv path.
    if (flags.create_jupyter_kernel) {
        jupyter.createKernel(ctx, env_name, env_dir_path, null, null) catch |err| {
            output.printError(io, "Failed to create Jupyter kernel: {t}", .{err});
        };
    }

    // Record the tracked-file checksum + build flags so run/activate/cd/jupyter
    // can detect config drift later and auto-rebuild. The anchor is setup_cwd
    // (== the registered project_dir), so the gate's hash matches this one.
    // Non-fatal: setup already succeeded; a missing stamp just forces the next
    // gated command to re-setup.
    if (autosetup.computeTrackedHash(allocator, io, setup_cwd, env_name, env_config) catch null) |tracked_hash| {
        defer allocator.free(tracked_hash);
        const flag_tokens = autosetup.flagTokens(allocator, flags, groups) catch &.{};
        defer allocator.free(flag_tokens);
        autosetup.writeStamp(allocator, io, env_dir_path, tracked_hash, flag_tokens) catch |err| {
            output.print(io, "Warning: could not write setup stamp: {t}", .{err});
        };
    }

    output.print(io,
        \\Environment '{s}' setup complete and registered in global registry.
        \\Usage: source $(zenv activate {s})
    , .{ env_name, env_name });
}

/// Renders a resolution failure at the call site — preserving the ambiguous
/// candidate list — and returns the error for main.zig to map to an exit
/// message. Mirrors the messages the deleted lookupRegistryEntry printed.
fn present(ctx: Ctx, registry: *const EnvironmentRegistry, identifier: []const u8, err: anyerror) anyerror {
    const io = ctx.io;
    const allocator = ctx.arena;
    if (err == error.AmbiguousIdentifier) {
        const cands = registry.candidates(allocator, identifier) catch return err;
        defer allocator.free(cands);

        output.rawErr(io, "ERROR: '{s}' matches multiple environments:\n", .{identifier});

        // Host framing applies only to the host-aware branches ("." and a shared
        // alias). A non-unique id-prefix is host-irrelevant — advise more characters.
        const host_relevant = std.mem.eql(u8, identifier, ".") or registry.resolveAlias(identifier) != null;
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
            const m = if (current_host) |h| host.hostMatchesTargets(h, c.target_machines) else false;
            if (m) host_matches += 1;
            const mark = if (m) "  <- matches this host" else "";
            output.rawErr(io, "  - {s} (target: {s}){s}\n", .{ c.env_name, c.target_machines, mark });
        }
        if (current_host) |h| {
            if (host_matches == 0) {
                output.rawErr(io, "None of these target the current host '{s}'. Add this machine to one env's target_machines, or use the exact env name / id.\n", .{h});
            } else {
                output.rawErr(io, "{d} target the current host '{s}'. Use the exact env name or id to choose one.\n", .{ host_matches, h });
            }
        } else {
            output.rawErr(io, "Could not determine the current host. Use the exact env name or id.\n", .{});
        }
    } else if (err == error.EnvironmentNotRegistered) {
        if (std.mem.eql(u8, identifier, ".")) {
            const root = EnvironmentRegistry.dotProjectDir(allocator, io) catch return err;
            defer allocator.free(root);
            output.rawErr(io, "ERROR: No environment is registered for the project at '{s}' (the nearest zenv.json).\n", .{root});
        } else output.rawErr(io, "ERROR: Environment with name or ID '{s}' not found in registry.\n", .{identifier});
        output.rawErr(io, "Use 'zenv ls' to see all available environments with their IDs.\n", .{});
    }
    return err;
}

/// Resolves the environment named by `args[2]`; when it is missing, says how
/// to call `zenv <usage>`.
fn resolveArg(ctx: Ctx, registry: *const EnvironmentRegistry, args: []const []const u8, comptime usage: []const u8) !EnvironmentRegistry.EnvRef {
    if (args.len < 3) {
        output.printError(ctx.io, "Missing environment name or ID argument.\nUsage: zenv " ++ usage, .{});
        return error.EnvironmentNotFound;
    }
    return resolve(ctx, registry, args[2]);
}

/// Resolves `identifier`, explaining a failure (see `present`).
fn resolve(ctx: Ctx, registry: *const EnvironmentRegistry, identifier: []const u8) !EnvironmentRegistry.EnvRef {
    return registry.resolve(ctx.arena, identifier) catch |e| return present(ctx, registry, identifier, e);
}

pub fn handleActivateCommand(
    ctx: Ctx,
    registry: *const EnvironmentRegistry,
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
            output.printError(io, "Unknown option '{s}' for 'zenv activate'. Options: --shell=<shell>, --auto", .{arg});
            return error.ArgsError;
        };
        shell = activation.parseShell(name) orelse {
            output.printError(io, "Unsupported shell '{s}'. Supported: sh, bash, zsh, csh, tcsh, fish.", .{name});
            return error.ArgsError;
        };
    }
    if (auto) return activateAuto(ctx, registry, positional(args, 0) orelse ".", shell);

    const identifier = positional(args, 0) orelse {
        output.printError(io, "Missing environment name or ID argument. Usage: zenv activate <name|id> [--shell=sh|bash|zsh|csh|tcsh|fish]", .{});
        return error.EnvironmentNotFound;
    };

    const ref = try resolve(ctx, registry, identifier);
    // Rebuild the env first if its config/dependency files changed. The rebuild
    // is silent and any notice goes to stderr, so stdout stays just the
    // activate-script path that the shell sources.
    try autosetup.ensureUpToDate(ctx, registry.get(ref));
    try printActivateScript(ctx, registry.get(ref), shell);
}

/// `zenv activate --auto [dir]`, for the shell hook (`zenv hook`): prints the
/// activation script of the env registered for the nearest directory at or
/// above `dir` that holds a zenv.json. Prints nothing when there is none or
/// several match, so the hook can run it on every project change. Never
/// rebuilds: a build on `cd` would be slow, and would run newly pulled
/// activate hooks unasked. A stale env gets a notice and activates as built.
fn activateAuto(ctx: Ctx, registry: *const EnvironmentRegistry, dir: []const u8, shell: activation.Shell) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const start = try Io.Dir.cwd().realPathFileAlloc(io, dir, allocator);
    defer allocator.free(start);
    const root = (try paths.findProjectRoot(allocator, io, start)) orelse return;
    defer allocator.free(root);

    const ref = registry.resolveDir(allocator, root) catch |e| switch (e) {
        error.EnvironmentNotRegistered => return,
        error.AmbiguousIdentifier => {
            output.rawErr(io, "zenv: {s} has several environments for this machine; activate one by name.\n", .{root});
            return;
        },
    };
    const entry = registry.get(ref);
    if (autosetup.isStale(ctx, entry) catch false) {
        output.rawErr(io, "zenv: '{s}' is out of date with zenv.json; run 'zenv setup {s}' to rebuild it.\n", .{ entry.env_name, entry.env_name });
    }
    try printActivateScript(ctx, entry, shell);
}

fn printActivateScript(ctx: Ctx, entry: *const configurations.RegistryEntry, shell: activation.Shell) !void {
    const io = ctx.io;
    const script = try Io.Dir.path.join(ctx.arena, &.{ entry.venv_path, activation.fileName(shell) });
    // Envs built by an older zenv have only activate.sh.
    if (!runtime.exists(io, script)) {
        output.printError(io, "{s} not found. Re-run 'zenv setup {s}' to generate it.", .{ script, entry.env_name });
        return error.EnvironmentNotFound;
    }
    output.rawOut(io, "{s}\n", .{script});
}

/// `zenv hook <shell>`: prints the shell code that `eval "$(zenv hook zsh)"`
/// (or `bash`) loads to activate project environments on cd.
pub fn handleHookCommand(ctx: Ctx, args: []const []const u8) !void {
    const io = ctx.io;
    const name = positional(args, 0) orelse {
        output.printError(io, "Missing shell. Usage: zenv hook <zsh|bash>", .{});
        return error.ArgsError;
    };
    const code = shell_hook.forShell(name) orelse {
        output.printError(io, "Unsupported shell '{s}' for 'zenv hook'. Supported: zsh, bash.", .{name});
        return error.ArgsError;
    };
    output.rawOut(io, "{s}", .{code});
}

pub fn handleListCommand(
    ctx: Ctx,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_fw.interface; // special case for using standard writer
    defer stdout.flush() catch {};
    const list_all = args.len > 2 and std.mem.eql(u8, args[2], "--all");
    if (args.len > 3 or (args.len == 3 and !list_all and std.mem.startsWith(u8, args[2], "-"))) {
        output.printError(io, "Unexpected argument '{s}'. Usage: zenv ls [--all | <name|id|.>]", .{args[args.len - 1]});
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
    const current_hostname: ?[]const u8 = if (list_all) null else host.getSystemHostname(allocator, io, ctx.env) catch |err| blk: {
        output.print(io,
            \\Could not determine current hostname for filtering: {t}
            \\Listing all registered environments instead.
        , .{err});
        break :blk null;
    };
    defer if (current_hostname) |h| allocator.free(h);

    var count: usize = 0;
    for (registry.entries.items) |entry| {
        // hostMatchesTargets owns the comma-list matching rules.
        if (current_hostname) |h| if (!host.hostMatchesTargets(h, entry.target_machines_str)) continue;

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
            stdout.writeAll("No environments found. (Could not determine current hostname).\n") catch {};
        } else {
            stdout.writeAll(
                \\No environments found in the registry
                \\Use 'zenv setup <name>' OR 'zenv register <name>' to register environments
                \\
            ) catch {};
        }
    } else if (current_hostname) |h| {
        stdout.print("Found {d} environment(s) for the current machine ('{s}')\n", .{ count, h }) catch {};
    } else {
        stdout.print("Found {d} total registered environment(s)\n", .{count}) catch {};
    }
}

/// One environment's block in `zenv ls`, ending in a newline.
fn printListEntry(ctx: Ctx, stdout: *Io.Writer, entry: *const configurations.RegistryEntry) void {
    stdout.print("- {s}\n  id      : {s}\n  target  : {s}\n  project : {s}\n  venv    : {s}", .{ entry.env_name, entry.id, entry.target_machines_str, entry.project_dir, entry.venv_path }) catch {};
    // The Python that built the venv, read from <venv>/pyvenv.cfg.
    // Omitted entirely when the env isn't built (no pyvenv.cfg).
    if (configurations.readVenvPython(ctx.arena, ctx.io, entry.venv_path) catch null) |py| {
        stdout.print("\n  python  : {s}", .{py}) catch {};
    }
    if (entry.aliases.items.len > 0) stdout.print("\n  aliases : {f}", .{joinedList([]const u8, entry.aliases.items)}) catch {};
    if (entry.description) |desc| stdout.print("\n  desc    : {s}", .{desc}) catch {};
    stdout.writeAll("\n") catch {};
}

pub fn handleRegisterCommand(
    ctx: Ctx,
    config: *const ZenvConfig,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    // First positional, not args[2]: `zenv register --no-host myenv` must not
    // treat the flag as the environment name.
    const env_name = positional(args, 0) orelse {
        output.printError(io, "Missing environment name argument. Usage: zenv register <name>", .{});
        return error.EnvironmentNotFound;
    };

    try checkFlags(io, args, &REGISTER_FLAGS);
    const flags = CommandFlags.fromArgs(args);

    // Log flags if they're set
    if (flags.skip_hostname_check) {
        output.print(io, "'--no-host' flag detected. Skipping hostname validation.", .{});
    }

    // Get the environment config directly without re-parsing validation
    const env_config = config.getEnvironment(env_name) orelse {
        output.printError(io, "Environment '{s}' not found in configuration.", .{env_name});
        return error.EnvironmentNotFound;
    };

    if (!flags.skip_hostname_check) try env.checkHost(ctx, env_config, env_name);

    // Get absolute path of current working directory
    const cwd_path = std.process.currentPathAlloc(io, ctx.arena) catch |err| {
        output.printError(io, "Could not get current working directory: {t}", .{err});
        return err;
    };

    // Get the base_dir from the loaded config
    const base_dir = config.base_dir;

    // Register the environment in the global registry (persists internally).
    registry.register(
        env_name,
        cwd_path,
        base_dir,
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

pub fn handleDeregisterCommand(
    ctx: Ctx,
    registry: *EnvironmentRegistry,
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

pub fn handleCdCommand(
    ctx: Ctx,
    registry: *const EnvironmentRegistry,
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

    // Output just the project directory path
    output.rawOut(ctx.io, "{s}\n", .{registry.get(ref).project_dir});
}

pub fn handlePythonCommand(ctx: Ctx, args: []const []const u8) !void {
    const io = ctx.io;
    // Check if we have a subcommand
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
            python.installPython(ctx, version) catch |err| {
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
            try python.setDefaultPythonPath(ctx, args[3]);
        },
        .ls, .list => try python.listInstalledVersions(ctx),
    }
}

pub fn handleRmCommand(
    ctx: Ctx,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const ref = try resolveArg(ctx, registry, args, "rm <name|id>");

    // Owned, detached entry: no raw identifier reaches the mutator (the old
    // ambiguity bug is unrepresentable), and venv_path is read AFTER removal.
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

pub fn handleRunCommand(
    ctx: Ctx,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    // Need at least 4 args: zenv run <env> <command>
    if (args.len < 4) {
        output.printError(io, "Missing environment name or command. Usage: zenv run <name|id> <command> [args...]", .{});
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
    // under it. execInEnv returns only when the command was not found.
    const term = execInEnv(ctx, venv_path, command, command_args, .replace) catch |err| {
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
pub fn handleAddCommand(
    ctx: Ctx,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const env_id = positional(args, 0) orelse {
        output.printError(io, "Missing environment name. Usage: zenv add <name|id|.> <package> [--dev | --group <name>] [--zenv] [--uv|--pip]", .{});
        return error.ArgsError;
    };
    const package = positional(args, 1) orelse {
        output.printError(io, "Missing package name. Usage: zenv add <name|id|.> <package> [--dev | --group <name>] [--zenv] [--uv|--pip]", .{});
        return error.ArgsError;
    };
    try checkFlags(io, args, &ADD_FLAGS);
    const flags = CommandFlags.fromArgs(args);
    const group = try addGroup(allocator, io, args, flags);

    const ref = try resolve(ctx, registry, env_id);
    const entry = registry.get(ref);
    const env_name = entry.env_name;
    const project_dir = entry.project_dir;

    // The environment must already be built (its activation script exists).
    const activate_path = try Io.Dir.path.join(allocator, &.{ entry.venv_path, "activate.sh" });
    defer allocator.free(activate_path);
    Io.Dir.cwd().access(io, activate_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            output.printError(io, "Environment '{s}' is not set up yet. Run 'zenv setup {s}' first.", .{ env_name, env_name });
            return error.EnvironmentNotFound;
        }
        return err;
    };

    // The project's zenv.json tells us which manifest (if any) backs this env.
    const zenv_json_path = try Io.Dir.path.join(allocator, &.{ project_dir, "zenv.json" });
    defer allocator.free(zenv_json_path);

    const info = try readEnvJson(allocator, io, zenv_json_path, env_name);
    defer if (info.dependency_file) |df| allocator.free(df);

    // Turning Python on is the user's call, made in zenv.json, not a side
    // effect of adding a package.
    if (!info.python) {
        const retry = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(retry);
        output.printError(io, "'{s}' has no Python (\"python\": false in zenv.json), so packages cannot be added.", .{env_name});
        output.printError(io, "Set \"python\": true for '{s}' in zenv.json, then re-run: zenv {s}", .{ env_name, retry });
        return error.NoPython;
    }
    // Python was just turned on for an env built without it: build the venv
    // first (zenv.json changed, so the gate rebuilds).
    if (!try venvHasPython(allocator, io, entry.venv_path)) {
        try autosetup.ensureUpToDate(ctx, entry);
        if (!try venvHasPython(allocator, io, entry.venv_path)) {
            output.printError(io, "Environment '{s}' has no Python venv yet. Run 'zenv setup {s}' first.", .{ env_name, env_name });
            return error.NoPython;
        }
    }

    // Where the package will be recorded, settled before installing so a
    // group that cannot be recorded installs nothing.
    const record = try addRecord(allocator, io, project_dir, info.dependency_file, group, flags.zenv_only);

    // Recording the package changes a tracked manifest. If the env is up to
    // date now, the install below makes it up to date again, so the build
    // record is renewed rather than left to trigger a rebuild on the next run.
    const was_fresh = !(autosetup.isStale(ctx, entry) catch true);

    // 1. Install into the venv (only persist below if this succeeds).
    const uv = try envbuild.resolveUv(ctx, addInstaller(allocator, io, flags, entry.venv_path));
    try installPackage(ctx, entry.venv_path, package, uv);

    // 2. Persist to the appropriate manifest.
    persistAddedPackage(allocator, io, zenv_json_path, env_name, record, package) catch |err| {
        output.printError(io, "'{s}' is installed in '{s}', but recording it failed: {t}. Add it to the manifest by hand.", .{ package, env_name, err });
        return err;
    };
    // A package in a dependency group survives rebuilds only if they install
    // the group, so the build record now replays it.
    if (record == .pyproject) if (record.pyproject.group) |g| {
        if (autosetup.addReplayGroup(allocator, io, entry.venv_path, g) catch false)
            output.print(io, "Rebuilds of '{s}' now install group '{s}'; a manual 'zenv setup' needs '--group {s}'.", .{ env_name, g, g });
    };
    if (was_fresh) autosetup.restamp(ctx, project_dir, env_name, entry.venv_path) catch {};

    output.print(io, "Added '{s}' to environment '{s}'.", .{ package, env_name });
}

/// What `add` and `jupyter create` need from an env's entry in zenv.json,
/// read without validating the whole file.
const EnvJsonInfo = struct {
    /// False only for an explicit `"python": false`.
    python: bool = true,
    /// Owned by the caller.
    dependency_file: ?[]const u8 = null,
};

/// Reads `env_name`'s entry from the zenv.json at `path`. Defaults when the
/// file, env or field is absent or unparsable: add stays best-effort and falls
/// back to zenv.json then.
fn readEnvJson(allocator: Allocator, io: Io, path: []const u8, env_name: []const u8) !EnvJsonInfo {
    const content = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const env_obj = parsed.value.object.get(env_name) orelse return .{};
    const fields = std.json.parseFromValueLeaky(struct {
        python: ?bool = null,
        dependency_file: ?[]const u8 = null,
    }, parsed.arena.allocator(), env_obj, .{ .ignore_unknown_fields = true }) catch return .{};
    return .{
        .python = fields.python orelse true,
        .dependency_file = if (fields.dependency_file) |df| try allocator.dupe(u8, df) else null,
    };
}

/// Whether zenv.json at `path` sets `"python": false` for `env_name`.
pub fn pythonDisabled(allocator: Allocator, io: Io, path: []const u8, env_name: []const u8) !bool {
    const info = try readEnvJson(allocator, io, path, env_name);
    if (info.dependency_file) |df| allocator.free(df);
    return !info.python;
}

/// Whether the venv at `venv_path` has its interpreter link, bin/python.
fn venvHasPython(allocator: Allocator, io: Io, venv_path: []const u8) !bool {
    const py = try Io.Dir.path.join(allocator, &.{ venv_path, "bin", "python" });
    defer allocator.free(py);
    return runtime.exists(io, py);
}

/// Refuses a Python-only action on a Python-free env, saying how to enable it.
fn noPython(io: Io, env_name: []const u8, why: []const u8) error{NoPython} {
    output.printError(io, "'{s}' has no Python (\"python\": false in zenv.json); {s}.", .{ env_name, why });
    output.printError(io, "Set \"python\": true for '{s}' in zenv.json to use it.", .{env_name});
    return error.NoPython;
}

/// The installer `zenv add` asks for: its own --uv/--pip, else the one the
/// env's last setup was given explicitly (a `--pip` env stays on pip), else
/// auto.
fn addInstaller(allocator: Allocator, io: Io, flags: CommandFlags, venv_path: []const u8) flags_module.Installer {
    if (flags.installer() != .auto) return flags.installer();
    const stamp = autosetup.readStamp(allocator, io, venv_path) orelse return .auto;
    defer stamp.deinit();
    return CommandFlags.fromArgs(stamp.value.flags).installer();
}

/// Installs `package` into the activated environment with `uv` (a path, from
/// `envbuild.resolveUv`), or pip when null. A non-zero installer exit maps to
/// error.ProcessError.
fn installPackage(ctx: Ctx, venv_path: []const u8, package: []const u8, uv: ?[]const u8) !void {
    const io = ctx.io;
    // uv is resolved on zenv's own PATH, as setup does: an activate.sh launch
    // purges modules, which would drop a uv that a module provides.
    const command: []const u8 = uv orelse "python";
    const cmd_args: []const []const u8 = if (uv != null)
        &.{ "pip", "install", package }
    else
        &.{ "-m", "pip", "install", package };

    output.print(io, "Installing '{s}'...", .{package});
    const term = execInEnv(ctx, venv_path, command, cmd_args, .wait) catch |err| {
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
fn addGroup(allocator: Allocator, io: Io, args: []const []const u8, flags: CommandFlags) !?[]const u8 {
    const groups = try flags_module.groups(allocator, args);
    if (groups.len > 1) {
        output.printError(io, "'zenv add' records a package in one dependency group; got {d}.", .{groups.len});
        return error.ArgsError;
    }
    if (groups.len == 0) return if (flags.dev_mode) "dev" else null;
    const group = groups[0];
    if (flags.dev_mode and !deps.sameName(group, "dev")) {
        output.printError(io, "'--dev' means '--group dev'; it cannot be combined with '--group {s}'.", .{group});
        return error.ArgsError;
    }
    if (std.mem.findScalar(u8, group, '.') != null) {
        output.printError(io, "'zenv add' cannot record into group '{s}': a '.' in the name would make a nested TOML key. Add it by hand.", .{group});
        return error.ArgsError;
    }
    return group;
}

/// The pyproject.toml that holds an env's dependency groups, relative to the
/// project directory: its `dependency_file` when that is a pyproject.toml,
/// else `pyproject.toml`. `setup --group` reads the groups there.
fn groupsFile(dep_file: ?[]const u8) []const u8 {
    if (dep_file) |df| if (std.mem.endsWith(u8, df, ".toml")) return df;
    return "pyproject.toml";
}

/// Where `zenv add` records a package.
const AddRecord = union(enum) {
    /// zenv.json `dependencies`, or `dev_dependencies` when true.
    zenv_json: bool,
    /// A requirements file (absolute path), for runtime dependencies.
    requirements: struct { path: []const u8, label: []const u8 },
    /// `[project].dependencies` when `group` is null, else that dependency group.
    pyproject: struct { path: []const u8, label: []const u8, group: ?[]const u8 },
};

/// Picks the manifest for a package added to `group` (see `addGroup`):
///
/// | dependency_file   | runtime            | --dev                    | --group <other>      |
/// |-------------------|--------------------|--------------------------|----------------------|
/// | pyproject.toml    | [project]          | [dependency-groups].dev  | [dependency-groups]  |
/// | requirements.txt  | requirements.txt   | zenv.json dev_deps       | ./pyproject.toml     |
/// | none              | zenv.json deps     | zenv.json dev_deps       | ./pyproject.toml     |
///
/// `--zenv` sends runtime and dev packages to zenv.json and refuses another
/// group, as does a project without the pyproject.toml it would go to.
fn addRecord(allocator: Allocator, io: Io, project_dir: []const u8, dep_file: ?[]const u8, group: ?[]const u8, zenv_only: bool) !AddRecord {
    const dev = if (group) |g| deps.sameName(g, "dev") else false;
    const toml_dep_file = if (dep_file) |df| std.mem.endsWith(u8, df, ".toml") else false;

    if (group != null and !dev) {
        if (zenv_only) {
            output.printError(io, "zenv.json has no dependency groups besides dev_dependencies, so '--zenv' cannot record into group '{s}'.", .{group.?});
            return error.ArgsError;
        }
        const label = groupsFile(dep_file);
        const path = try paths.resolvePath(allocator, project_dir, label);
        if (!runtime.exists(io, path)) {
            output.printError(io, "Dependency group '{s}' is recorded in pyproject.toml, but '{s}' does not exist.", .{ group.?, path });
            return error.ArgsError;
        }
        return .{ .pyproject = .{ .path = path, .label = label, .group = group } };
    }
    if (zenv_only or dep_file == null) return .{ .zenv_json = dev };
    const path = try paths.resolvePath(allocator, project_dir, dep_file.?);
    if (toml_dep_file) return .{ .pyproject = .{ .path = path, .label = dep_file.?, .group = group } };
    // requirements files have no dev concept; dev deps live in zenv.json.
    if (dev) return .{ .zenv_json = true };
    return .{ .requirements = .{ .path = path, .label = dep_file.? } };
}

/// Records the installed `package` where `record` says.
fn persistAddedPackage(
    allocator: Allocator,
    io: Io,
    zenv_json_path: []const u8,
    env_name: []const u8,
    record: AddRecord,
    package: []const u8,
) !void {
    switch (record) {
        .zenv_json => |dev| {
            try manifest.addToZenvJson(allocator, io, zenv_json_path, env_name, package, dev);
            output.print(io, "Recorded in zenv.json ({s}).", .{if (dev) "dev_dependencies" else "dependencies"});
        },
        .requirements => |r| {
            try manifest.addToRequirementsTxt(allocator, io, r.path, package);
            output.print(io, "Recorded in {s}.", .{r.label});
        },
        .pyproject => |p| {
            if (try manifest.addToPyproject(allocator, io, p.path, package, p.group)) {
                if (p.group) |g|
                    output.print(io, "Recorded in {s} ([dependency-groups].{s}).", .{ p.label, g })
                else
                    output.print(io, "Recorded in {s} ([project].dependencies).", .{p.label});
            } else {
                // Runtime case with no [project] table: fall back to zenv.json.
                output.print(io, "Could not locate [project] in {s}; recording in zenv.json instead.", .{p.label});
                try manifest.addToZenvJson(allocator, io, zenv_json_path, env_name, package, false);
            }
        },
    }
}

/// How execInEnv starts the command: as a child it waits for, or in place of
/// zenv (exec), in which case it returns only if the command did not start.
const Launch = enum { wait, replace };

/// Starts `command` inside the environment at `venv_path` with inherited stdio,
/// as `launch` says; with `.wait` it returns the command's `Term`. Uses the
/// direct launch when `zenv-env.json` can reproduce activation, else sources
/// activate.sh through bash.
fn execInEnv(ctx: Ctx, venv_path: []const u8, command: []const u8, command_args: []const []const u8, launch: Launch) !runtime.Term {
    if (try execDirect(ctx, venv_path, command, command_args, launch)) |term| return term;

    const activate_path = try Io.Dir.path.join(ctx.arena, &.{ venv_path, "activate.sh" });
    const argv = try buildRunArgv(ctx.arena, activate_path, command, command_args);
    return startCommand(ctx.io, argv, .{}, launch);
}

fn startCommand(io: Io, argv: []const []const u8, opts: runtime.ExecOptions, launch: Launch) !runtime.Term {
    return switch (launch) {
        .wait => runtime.exec(io, argv, opts),
        .replace => runtime.replace(io, argv, opts),
    };
}

/// Direct launch: copy this process's environment, apply `zenv-env.json`,
/// resolve `command` against the resulting PATH and start it, no shell
/// involved. Returns null (caller falls back to bash) when the spec is missing
/// or `envspec.directReason` reports a blocker, or when ZENV_RUN_SHELL=1.
fn execDirect(ctx: Ctx, venv_path: []const u8, command: []const u8, command_args: []const []const u8, launch: Launch) !?runtime.Term {
    const io = ctx.io;
    const allocator = ctx.arena;
    if (ctx.getEnv("ZENV_RUN_SHELL")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            output.debug(io, "run: ZENV_RUN_SHELL=1, using activate.sh", .{});
            return null;
        }
    }

    const parsed = envspec.readSpec(allocator, io, venv_path) orelse {
        output.debug(io, "run: no usable {s}, using activate.sh", .{envspec.FILE_NAME});
        return null;
    };
    defer parsed.deinit();
    const spec = &parsed.value;

    // Only the module cache needs the system identity; skip the lookup otherwise.
    const system: ?[]const u8 = if (spec.modules.len > 0) envspec.currentSystem(allocator, io, ctx.env) catch null else null;
    if (envspec.directReason(spec, system)) |reason| {
        output.debug(io, "run: {s}, using activate.sh", .{reason});
        return null;
    }

    var child_env = try ctx.env.clone(allocator);
    try envspec.apply(&child_env, spec);

    const exe = try envspec.resolveCommand(allocator, io, command, child_env.get("PATH")) orelse {
        // Same status bash's `exec` gives for an unknown command.
        output.printError(io, "{s}: command not found", .{command});
        return .{ .exited = 127 };
    };
    output.debug(io, "run: direct launch of {s}", .{exe});

    const argv = try std.mem.concat(allocator, []const u8, &.{ &.{command}, command_args });
    return try startCommand(io, argv, .{ .environ_map = &child_env, .exe_path = exe }, launch);
}

/// Shell snippet passed to `bash -c`. It sources the activation script (passed
/// as the first positional parameter `$1`), drops it from the positionals, then
/// `exec`s the user command (`$@`) so the command replaces the shell. Sourcing
/// honors `module load` and any activate hooks; `exec` makes the command's exit
/// status and signal disposition propagate directly back to zenv.
const run_runner = "set -e; source \"$1\"; shift; exec \"$@\"";

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
    return std.mem.concat(allocator, []const u8, &.{ &.{ "/bin/bash", "-c", run_runner, "zenv", activate_path, command }, command_args });
}

test "pythonDisabled reads only an explicit false" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    const root = ".zig-cache/tmp/zenv-python-disabled-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    const path = root ++ "/zenv.json";
    try cwd.writeFile(io, .{ .sub_path = path, .data =
        \\{ "base_dir": ".zenv", "off": { "python": false, "dependency_file": "r.txt" }, "on": { "python": true }, "unset": {}, "nulls": { "python": null, "dependency_file": null } }
    });
    try std.testing.expect(try pythonDisabled(a, io, path, "off"));
    try std.testing.expect(!try pythonDisabled(a, io, path, "on"));
    try std.testing.expect(!try pythonDisabled(a, io, path, "unset"));
    try std.testing.expect(!try pythonDisabled(a, io, path, "nulls"));
    try std.testing.expect(!try pythonDisabled(a, io, path, "missing"));
    try std.testing.expect(!try pythonDisabled(a, io, root ++ "/nope.json", "off"));
    const off = try readEnvJson(a, io, path, "off");
    defer a.free(off.dependency_file.?);
    try std.testing.expectEqualStrings("r.txt", off.dependency_file.?);
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

pub fn handleLogCommand(
    ctx: Ctx,
    registry: *const EnvironmentRegistry,
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

pub fn handleValidateCommand(
    ctx: Ctx,
    config_path: []const u8,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    // Use custom config path if provided as an argument
    var validate_config_path: []const u8 = config_path;

    if (args.len > 2) {
        validate_config_path = args[2];
        output.print(io, "Using provided file path: {s}", .{validate_config_path});
    } else {
        output.print(io, "Using default config path: {s}", .{validate_config_path});
    }

    // Check if file exists before validating
    if (Io.Dir.cwd().access(io, validate_config_path, .{})) |_| {
        output.print(io, "File exists, proceeding with validation", .{});
    } else |err| {
        output.printError(io, "Failed to open file '{s}': {t}", .{ validate_config_path, err });
        std.process.exit(1);
    }

    // validateAndParse prints what it finds; any finding or failure exits 1.
    var config = validation.validateAndParse(ctx.arena, io, validate_config_path) catch std.process.exit(1);
    config.deinit();
    output.print(io, "Configuration file is valid!", .{});
}

pub fn handleAliasCommand(
    ctx: Ctx,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    if (args.len < 3) {
        output.printError(io,
            \\Missing alias subcommand.
            \\Usage: zenv alias <create|remove|ls|show> [arguments]
        , .{});
        return error.ArgsError;
    }

    const subcommand = std.meta.stringToEnum(enum { create, remove, ls, list, show }, args[2]) orelse {
        output.printError(io,
            \\Unknown alias subcommand '{s}'.
            \\Usage: zenv alias <create|remove|ls|show> [arguments]
        , .{args[2]});
        return error.ArgsError;
    };
    switch (subcommand) {
        .create => try handleAliasCreate(ctx, registry, args),
        .remove => try handleAliasRemove(io, registry, args),
        .ls, .list => handleAliasList(io, registry),
        .show => try handleAliasShow(io, registry, args),
    }
}

fn handleAliasCreate(
    ctx: Ctx,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    if (args.len < 5) {
        output.printError(io,
            \\Missing arguments for alias create.
            \\Usage: zenv alias create <alias_name> <env_name|env_id>
        , .{});
        return error.ArgsError;
    }

    const alias_name = args[3];
    const env_identifier = args[4];

    // An alias must not read like a command.
    if (std.meta.stringToEnum(Command, alias_name)) |command| if (command != .unknown) {
        output.printError(io, "Alias name '{s}' conflicts with existing command.", .{alias_name});
        return error.ArgsError;
    };

    // Check if alias name is "." (reserved for current directory)
    if (std.mem.eql(u8, alias_name, ".")) {
        output.printError(io, "Alias name '.' is reserved for current directory notation.", .{});
        return error.ArgsError;
    }

    // Resolve environment identifier to get the actual environment name
    const target_ref = try resolve(ctx, registry, env_identifier);
    // Owned: addAlias re-reads the registry, which frees the entry's strings.
    const target_env_name = try allocator.dupe(u8, registry.get(target_ref).env_name);
    defer allocator.free(target_env_name);

    // Add alias to registry
    registry.addAlias(alias_name, target_env_name) catch |err| {
        switch (err) {
            error.EnvironmentNotFound => output.printError(io, "Environment '{s}' not found.", .{env_identifier}),
            error.AliasAlreadyExists => output.printError(io, "Alias '{s}' already exists.", .{alias_name}),
            error.InvalidEnvironmentName => output.printError(io, "Invalid alias '{s}': use letters, digits, '_', '-' and '.' (not '.' or '..').", .{alias_name}),
            else => output.printError(io, "Failed to create alias: {t}", .{err}),
        }
        return err;
    };

    output.print(io, "Alias '{s}' created for environment '{s}'.", .{ alias_name, target_env_name });
}

fn handleAliasRemove(
    io: Io,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(io,
            \\Missing alias name.
            \\Usage: zenv alias remove <alias_name>
        , .{});
        return error.ArgsError;
    }

    const alias_name = args[3];

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

fn handleAliasList(io: Io, registry: *EnvironmentRegistry) void {
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
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(io,
            \\Missing alias name.
            \\Usage: zenv alias show <alias_name>
        , .{});
        return error.ArgsError;
    }

    const alias_name = args[3];

    // An alias may be shared across several per-machine environments, so list
    // every holder with its target machines (resolution picks by current host).
    var found = false;
    for (registry.entries.items) |entry| {
        for (entry.aliases.items) |alias| {
            if (std.mem.eql(u8, alias, alias_name)) {
                if (!found) {
                    output.print(io, "Alias '{s}' resolves to:", .{alias_name});
                    found = true;
                }
                output.print(io, "  {s} (target: {s})", .{ entry.env_name, entry.target_machines_str });
                break;
            }
        }
    }
    if (!found) {
        output.printError(io, "Alias '{s}' not found.", .{alias_name});
        return error.AliasNotFound;
    }
}

pub fn handleJupyterCommand(
    ctx: Ctx,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    if (args.len < 3) {
        output.printError(io,
            \\Missing jupyter subcommand.
            \\Usage: zenv jupyter <create|remove|ls|check> [arguments]
        , .{});
        return error.ArgsError;
    }

    const subcommand = std.meta.stringToEnum(enum { create, remove, ls, list, check }, args[2]) orelse {
        output.printError(io,
            \\Unknown jupyter subcommand '{s}'.
            \\Usage: zenv jupyter <create|remove|ls|check> [arguments]
        , .{args[2]});
        return error.ArgsError;
    };
    switch (subcommand) {
        .create => try handleJupyterCreate(ctx, registry, args),
        .remove => try handleJupyterRemove(ctx, registry, args),
        .ls, .list => try jupyter.listKernels(ctx),
        .check => try jupyter.checkJupyter(ctx),
    }
}

fn handleJupyterCreate(
    ctx: Ctx,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    if (args.len < 4) {
        output.printError(io,
            \\Missing environment name argument.
            \\Usage: zenv jupyter create <name|id|.> [--name <kernel_name>] [--display-name <display_name>]
        , .{});
        return error.ArgsError;
    }

    const identifier = args[3];
    var custom_name: ?[]const u8 = null;
    var custom_display_name: ?[]const u8 = null;

    // Parse optional flags
    var i: usize = 4;
    while (i < args.len) : (i += 2) {
        const slot = if (std.mem.eql(u8, args[i], "--name"))
            &custom_name
        else if (std.mem.eql(u8, args[i], "--display-name"))
            &custom_display_name
        else {
            output.printError(io, "Unknown option '{s}' for 'zenv jupyter create'. Options: --name, --display-name", .{args[i]});
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
    // Rebuild the env first if its config/dependency files changed (silent), so
    // the kernel is created against an up-to-date environment.
    try autosetup.ensureUpToDate(ctx, entry);

    const zenv_json_path = try Io.Dir.path.join(ctx.arena, &.{ entry.project_dir, "zenv.json" });
    if (try pythonDisabled(ctx.arena, io, zenv_json_path, entry.env_name)) return noPython(io, entry.env_name, "a Jupyter kernel needs Python");

    try jupyter.createKernel(ctx, entry.env_name, entry.venv_path, custom_name, custom_display_name);
}

fn handleJupyterRemove(
    ctx: Ctx,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const io = ctx.io;
    if (args.len < 4) {
        output.printError(io,
            \\Missing environment name argument.
            \\Usage: zenv jupyter remove <env_name>
        , .{});
        return error.ArgsError;
    }

    // Resolve through the registry so aliases/ids work. Only a name that is not
    // registered at all falls back to the raw name (a kernel whose environment
    // was already deregistered); an ambiguous or '.' identifier must not be
    // guessed into a kernel name.
    const identifier = args[3];
    const env_name = blk: {
        const ref = registry.resolve(ctx.arena, identifier) catch |e| {
            if (e == error.EnvironmentNotRegistered and paths.isValidEnvName(identifier)) break :blk identifier;
            return present(ctx, registry, identifier, e);
        };
        break :blk registry.get(ref).env_name;
    };
    try jupyter.removeKernel(ctx, env_name);
}

pub fn handleRenameCommand(
    ctx: Ctx,
    registry: *EnvironmentRegistry,
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
    if (registry.nameTaken(new_name)) {
        output.printError(io, "'{s}' is already an environment name, alias or id.", .{new_name});
        return error.EnvironmentAlreadyExists;
    }

    var ref = try resolve(ctx, registry, old_identifier);

    // Owned copies: the FS orchestration and rollback messages need these to
    // outlive registry.rename (which frees the entry's copies).
    const old_name = try allocator.dupe(u8, registry.get(ref).env_name);
    defer allocator.free(old_name);
    const old_venv_path = try allocator.dupe(u8, registry.get(ref).venv_path);
    defer allocator.free(old_venv_path);
    const project_dir = try allocator.dupe(u8, registry.get(ref).project_dir);
    defer allocator.free(project_dir);

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
        const spec = envspec.readSpec(allocator, io, old_venv_path) orelse {
            output.printError(io, "{s} has no usable {s}; re-run 'zenv setup {s}' first.", .{ old_venv_path, envspec.FILE_NAME, old_name });
            return error.MissingEnvSpec;
        };
        spec.deinit();
    }

    // An env that is up to date now must not rebuild after the rename: the
    // build record hashes the env's name.
    const was_fresh = !(autosetup.isStale(ctx, registry.get(ref)) catch true);
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
            error.EnvironmentAlreadyExists => output.printError(io, "'{s}' is already an environment name, alias or id.", .{new_name}),
            else => output.printError(io, "Failed to update registry: {t}", .{err}),
        }
        return err;
    };

    if (has_jupyter_kernel) {
        jupyter.renameKernel(ctx, old_name, new_name) catch |err| {
            registry.rename(&ref, old_name) catch {}; // re-saves; ref is kept current
            undoMove(ctx, old_name, new_venv_path, old_venv_path);
            switch (err) {
                error.KernelExists => output.printError(io, "Jupyter kernel '{s}' already exists", .{new_name}),
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
        output.printError(io, "Environment renamed successfully, but failed to update local config files: {t}", .{err});
        return;
    };
    if (was_fresh) autosetup.restamp(ctx, project_dir, new_name, new_venv_path) catch {};
}

/// Rolls back a rename's directory move: moves the venv back to `old_venv_path`
/// FIRST, then regenerates its scripts there (they are read from the venv's
/// current location). Best effort; says what to do if it cannot.
fn undoMove(ctx: Ctx, old_name: []const u8, new_venv_path: []const u8, old_venv_path: []const u8) void {
    const io = ctx.io;
    const cwd = Io.Dir.cwd();
    cwd.rename(new_venv_path, cwd, old_venv_path, io) catch |err| {
        output.printError(io, "Could not move {s} back to {s}: {t}. Move it back by hand.", .{ new_venv_path, old_venv_path, err });
        return;
    };
    updateGeneratedScripts(ctx, old_name, new_venv_path, old_venv_path) catch {
        output.printError(io, "Could not restore the scripts of '{s}'; re-run 'zenv setup {s}'.", .{ old_name, old_name });
    };
}

/// Points a venv moved from `from_path` to `to_path` (where it is now) at its
/// location and `name`: the activation scripts are regenerated from the stored
/// zenv-env.json, and paths are rewritten in the user's hook scripts and in
/// bin/ (console-script shebangs). Also used, swapped, to roll a rename back.
fn updateGeneratedScripts(ctx: Ctx, name: []const u8, from_path: []const u8, to_path: []const u8) !void {
    const io = ctx.io;
    const parsed = envspec.readSpec(ctx.arena, io, to_path) orelse {
        output.printError(io, "{s} has no usable {s}; re-run 'zenv setup' for this environment first.", .{ to_path, envspec.FILE_NAME });
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
    activation.writeAll(ctx.arena, io, &moved) catch |err| {
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
fn rewriteVenvPaths(allocator: Allocator, io: Io, venv_path: []const u8, sub: []const u8, old_venv_path: []const u8, strict: bool) !void {
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

        const content = dir.readFileAlloc(io, entry.name, allocator, .limited(1024 * 1024)) catch |err| {
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
    try cwd.writeFile(io, .{ .sub_path = root ++ "/new/bin/pip", .data = "#!/old/venv/bin/python\nimport pip\n" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/new/bin/blob", .data = "/old/venv\x00binary" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/new/scripts/activate_hook.sh", .data = "echo /old/venv/x\n" });

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

fn updateLocalConfigs(ctx: Ctx, old_name: []const u8, new_name: []const u8, project_dir: []const u8) !void {
    const io = ctx.io;
    const allocator = ctx.arena;
    const config_path = try Io.Dir.path.join(allocator, &.{ project_dir, "zenv.json" });

    output.print(io, "Updating local config: {s}", .{config_path});

    const config_contents = Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            output.print(io, "No local config file found, skipping update", .{});
            return; // No config file, that's fine
        }
        output.printError(io, "Failed to open config file: {t}", .{err});
        return err;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_contents, .{}) catch |err| {
        output.printError(io, "Failed to parse local config JSON: {t}", .{err});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        output.printError(io, "Local config is not a JSON object, skipping update", .{});
        return;
    }
    const root = &parsed.value.object;

    const index = root.getIndex(old_name) orelse {
        output.print(io, "Environment '{s}' not found in local config, skipping update", .{old_name});
        return;
    };
    if (root.contains(new_name)) {
        output.printError(io, "Local config already has an entry '{s}'; not updating it", .{new_name});
        return;
    }

    output.print(io, "Found environment '{s}' in local config, updating to '{s}'", .{ old_name, new_name });

    // Rename the TOP-LEVEL key only, structurally and in place (the order is
    // kept), then re-serialize. Unlike a textual replace, this can never touch
    // a nested key or a string value that happens to contain the name.
    root.setKey(index, new_name);
    try manifest.writeJson(io, config_path, parsed.value);

    output.print(io, "Successfully updated local config file", .{});
}
