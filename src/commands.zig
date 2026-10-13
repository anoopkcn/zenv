const std = @import("std");
const Allocator = std.mem.Allocator;

const CommandFlags = @import("utils/flags.zig").CommandFlags;
const positional = @import("utils/flags.zig").positional;
const unknownFlag = @import("utils/flags.zig").unknownFlag;
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
const zerrors = @import("utils/errors.zig");
const ZenvConfig = configurations.ZenvConfig;
const EnvironmentRegistry = configurations.EnvironmentRegistry;

/// The flags each command takes (see printUsage in main.zig).
pub const SETUP_FLAGS = [_][]const u8{ "--init", "--no-python", "--dev", "--uv", "--no-host", "--python", "--force", "--no-cache", "--jupyter" };
const REGISTER_FLAGS = [_][]const u8{"--no-host"};
const ADD_FLAGS = [_][]const u8{ "--dev", "--zenv", "--uv" };

/// Refuses a flag that `zenv <command>` does not take, naming the ones it does.
pub fn checkFlags(allocator: Allocator, args: []const []const u8, allowed: []const []const u8) error{ArgsError}!void {
    const bad = unknownFlag(args, allowed) orelse return;
    output.printError(allocator, "Unknown option '{s}' for 'zenv {s}'. Options: {f}", .{ bad, args[1], joinedList(allowed) }) catch {};
    return error.ArgsError;
}

/// Formats a list as "a, b, c" (`{f}`).
fn joinedList(list: []const []const u8) std.fmt.Alt([]const []const u8, formatList) {
    return .{ .data = list };
}

fn formatList(list: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (list, 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(f);
    }
}

/// The starter zenv.json for `zenv init`: one environment for any machine,
/// with every key present so users can see what is configurable. Written with
/// the JSON writer, so a name or description containing `"` or `\` stays
/// valid JSON. Caller owns the result.
fn initConfigJson(allocator: Allocator, env_name: []const u8, description: []const u8, dependency_file: ?[]const u8, with_python: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    const none = [_][]const u8{};

    try s.beginObject();
    try s.objectField("base_dir");
    try s.write(".zenv");
    try s.objectField(env_name);
    try s.beginObject();
    try s.objectField("target_machines");
    try s.write([_][]const u8{"*"});
    try s.objectField("description");
    try s.write(description);
    // A Python-free env gets "python": false and none of the Python-only keys
    // (which validation would reject), plus an empty "env" to fill in.
    if (with_python) {
        try s.objectField("fallback_python");
        try s.write(null);
    } else {
        try s.objectField("python");
        try s.write(false);
    }
    try s.objectField("modules");
    try s.write(none);
    try s.objectField("modules_file");
    try s.write(null);
    try s.objectField("module_cache");
    try s.write(true);
    if (with_python) {
        try s.objectField("dependencies");
        try s.write(none);
        try s.objectField("dependency_file");
        try s.write(dependency_file);
    } else {
        try s.objectField("env");
        try s.beginObject();
        try s.endObject();
    }
    for ([_][]const u8{ "setup", "activate" }) |hook| {
        try s.objectField(hook);
        try s.beginObject();
        try s.objectField("commands");
        try s.write(none);
        try s.objectField("script");
        try s.write(null);
        try s.endObject();
    }
    try s.endObject();
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
pub fn initConfig(allocator: Allocator, env_name: []const u8, description: ?[]const u8, with_python: bool) !InitOutcome {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config_path = "zenv.json";

    // Point dependency_file at an existing requirements.txt, else pyproject.toml.
    var dependency_file: ?[]const u8 = null;
    if (with_python) for ([_][]const u8{ "requirements.txt", "pyproject.toml" }) |candidate| {
        if (runtime.access(candidate)) |_| {
            dependency_file = candidate;
            break;
        } else |err| if (err != error.FileNotFound) return err;
    };

    const desc = description orelse pyproject: {
        const content = runtime.readFileAlloc(a, "pyproject.toml", 10 * 1024 * 1024) catch break :pyproject null;
        break :pyproject try deps.pyprojectField(a, content, "description");
    } orelse "Env config created by zenv";

    const template = try initConfigJson(a, env_name, desc, dependency_file, with_python);

    runtime.access(config_path) catch |err| {
        if (err != error.FileNotFound) return err;
        try runtime.writeFile(config_path, template);
        return .created;
    };
    return if (try manifest.addEnvToZenvJson(a, config_path, env_name, template)) .added else .exists;
}

/// Refuses `name` unless it can be an environment name (paths.isValidEnvName).
pub fn requireValidEnvName(allocator: Allocator, name: []const u8) error{InvalidEnvironmentName}!void {
    if (paths.isValidEnvName(name)) return;
    output.printError(allocator, "Invalid environment name '{s}'. Use only letters, digits, '-', '_' and '.'.", .{name}) catch {};
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

pub fn handleInitCommand(
    allocator: Allocator,
    args: []const []const u8,
) void {
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            output.rawOut(allocator, INIT_USAGE ++ "\n", .{}) catch {};
            return;
        }
        if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "--no-python")) {
            output.printError(allocator, "Unknown option '{s}' for 'zenv init'.\n" ++ INIT_USAGE, .{arg}) catch {};
            std.process.exit(1);
        }
    }

    var owned_name: ?[]u8 = null;
    defer if (owned_name) |n| allocator.free(n);
    const env_name = positional(args, 0) orelse blk: {
        const cwd = runtime.cwdRealpath(allocator) catch |err| {
            output.printError(allocator, "Reading the current directory: {s}", .{@errorName(err)}) catch {};
            std.process.exit(1);
        };
        defer allocator.free(cwd);
        owned_name = defaultEnvName(allocator, cwd) catch {
            output.printError(allocator, "Out of memory", .{}) catch {};
            std.process.exit(1);
        };
        break :blk owned_name.?;
    };
    requireValidEnvName(allocator, env_name) catch std.process.exit(1);

    const python_env = !CommandFlags.fromArgs(args).no_python;
    const outcome = initConfig(allocator, env_name, positional(args, 1), python_env) catch |err| {
        if (err == error.InvalidFormat) {
            output.printError(allocator, "zenv.json exists but is not a JSON object; fix it or remove it first.", .{}) catch {};
        } else {
            output.printError(allocator, "Writing zenv.json: {s}", .{@errorName(err)}) catch {};
        }
        std.process.exit(1);
    };
    switch (outcome) {
        .created, .added => {
            const what = if (outcome == .created) "Created zenv.json with" else "Added to zenv.json:";
            const kind = if (python_env) "environment" else "Python-free environment";
            output.print(allocator, "{s} {s} '{s}'. Run 'zenv setup {s}'", .{ what, kind, env_name, env_name }) catch {};
        },
        .exists => {
            output.printError(allocator, "zenv.json already defines environment '{s}'. Pick another name: zenv init <name>", .{env_name}) catch {};
            std.process.exit(1);
        },
    }
}

pub fn handleSetupCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) anyerror!void {
    // Parse command-line flags
    const flags = CommandFlags.fromArgs(args);

    // Log the detected flags
    if (flags.force_deps) {
        output.print(allocator,
            \\Force dependencies flag detected.
            \\User-specified dependencies will try to override module-provided packages.
        , .{}) catch {};
    }
    if (flags.skip_hostname_check) {
        output.print(allocator, "No-host flag detected. Bypassing hostname validation.", .{}) catch {};
    }
    if (flags.init_mode) {
        output.print(allocator, "Init flag detected. Using configuration created by --init.", .{}) catch {};
    }
    if (flags.no_cache) {
        output.print(allocator, "No-cache flag detected. Will disable package cache during dependency installation.", .{}) catch {};
    }

    // Get and validate the environment config
    const env_config = try env.getAndValidateEnvironment(allocator, config, args, flags);
    // Non-null: getAndValidateEnvironment just errored otherwise.
    const env_name = positional(args, 0).?;

    if (!env_config.python) {
        if (flags.dev_mode) return noPython(allocator, env_name, "--dev installs the project into it");
        if (flags.create_jupyter_kernel) return noPython(allocator, env_name, "--jupyter needs Python");
    }

    const display_target = if (env_config.target_machines.items.len > 0) env_config.target_machines.items[0] else "any";

    // Set up logging to a file inside the environment directory. Setup runs in
    // the project directory, so cwd is the anchor for a relative base_dir.
    const setup_cwd = try runtime.cwdRealpath(allocator);
    defer allocator.free(setup_cwd);

    // Refuse to create an environment whose base dir resolves to the global
    // ZENV_DIR (e.g. `zenv setup` from $HOME with default base_dir `.zenv` and
    // ZENV_DIR unset -> ~/.zenv). That would overwrite registry.json, python
    // installs and other global state. Guard here, before any logging or
    // directory creation. See paths.baseDirIsZenvDir.
    {
        const zenv_dir = try paths.getZenvDir(allocator);
        defer allocator.free(zenv_dir);
        if (try paths.baseDirIsZenvDir(allocator, setup_cwd, config.base_dir, zenv_dir)) {
            output.printError(allocator, "Refusing to set up: base directory '{s}' resolves to ZENV_DIR ('{s}').", .{ config.base_dir, zenv_dir }) catch {};
            output.printError(allocator, "This would overwrite global zenv state. Run setup from a project directory, set a different 'base_dir' in zenv.json, or point ZENV_DIR elsewhere.", .{}) catch {};
            return error.BaseDirIsZenvDir;
        }
    }

    const env_dir_path = try paths.venvPath(allocator, setup_cwd, config.base_dir, env_name);
    defer allocator.free(env_dir_path);

    // The env directory holds the setup log, so it is created first.
    try runtime.makePath(env_dir_path);
    const log_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ env_dir_path, "zenv_setup.log" });
    defer allocator.free(log_path);

    try output.startLogging(allocator, log_path);
    defer output.stopLogging();

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
    output.print(allocator, "Command: {s}", .{command_str.items}) catch {};
    output.print(allocator, "Setting up environment: {s} (Target: {s})", .{ env_name, display_target }) catch {};

    // 1. Combine Dependencies. The list and the strings parsed from the
    // dependency file live in `allocator` (main's arena); config strings are borrowed.
    var all_required_deps: std.ArrayList([]const u8) = .empty;

    // Add dependencies from config
    if (env_config.dependencies.items.len > 0) {
        output.print(allocator, "Adding {d} dependencies from configuration:", .{env_config.dependencies.items.len}) catch {};
        for (env_config.dependencies.items) |dep| {
            output.print(allocator, "  - Config dependency: {s}", .{dep}) catch {};
        }
        try all_required_deps.appendSlice(allocator, env_config.dependencies.items);
    } else {
        output.print(allocator, "No dependencies specified in configuration.", .{}) catch {};
    }

    // Add development dependencies from config (e.g. those recorded by
    // `zenv add --dev`).
    if (env_config.dev_dependencies.items.len > 0) {
        output.print(allocator, "Adding {d} development dependencies from configuration:", .{env_config.dev_dependencies.items.len}) catch {};
        for (env_config.dev_dependencies.items) |dep| {
            output.print(allocator, "  - Dev dependency: {s}", .{dep}) catch {};
        }
        try all_required_deps.appendSlice(allocator, env_config.dev_dependencies.items);
    }

    // The project's requires-python, from a pyproject.toml dependency file;
    // with --dev, ./pyproject.toml (the project pip installs) takes precedence.
    var requires_python: ?envbuild.RequiresPython = null;

    // Add dependencies from requirements file if specified
    if (env_config.dependency_file) |req_file| {
        const req_content = runtime.readFileAlloc(allocator, req_file, 1 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                output.printError(allocator, "Requirements file specified in configuration ('{s}') not found.", .{req_file}) catch {};
                return err;
            }
            output.printError(allocator, "Failed to read file '{s}': {s}", .{ req_file, @errorName(err) }) catch {};
            return error.PathResolutionFailed;
        };
        output.print(allocator, "Reading dependencies from file: '{s}'", .{req_file}) catch {};
        output.print(allocator, "Successfully read file ({d} bytes). Parsing dependencies...", .{req_content.len}) catch {};

        const is_toml = std.mem.endsWith(u8, req_file, ".toml");
        output.print(allocator, "{s}", .{if (is_toml) "Detected TOML file format, parsing as pyproject.toml" else "Parsing as requirements.txt format"}) catch {};
        const req_file_dep_count = if (is_toml)
            try deps.parsePyprojectToml(allocator, req_content, &all_required_deps)
        else
            try deps.parseRequirementsTxt(allocator, req_content, &all_required_deps);
        if (is_toml) if (try deps.pyprojectField(allocator, req_content, "requires-python")) |spec| {
            requires_python = .{ .spec = spec, .file = req_file };
        };

        if (req_file_dep_count > 0) {
            output.print(allocator, "Added {d} dependencies from file '{s}'", .{ req_file_dep_count, req_file }) catch {};
        } else {
            output.print(allocator, "Warning: No valid dependencies found in file '{s}'", .{req_file}) catch {};
        }
    } else {
        output.print(allocator, "No requirements file specified in configuration.", .{}) catch {};
    }

    if (flags.dev_mode and env_config.python) {
        if (runtime.readFileAlloc(allocator, "pyproject.toml", 10 * 1024 * 1024)) |content| {
            if (try deps.pyprojectField(allocator, content, "requires-python")) |spec| requires_python = .{ .spec = spec, .file = "pyproject.toml" };
        } else |_| {}
    }

    // Debug output - print the combined dependencies
    output.print(allocator, "Combined dependency list ({d} items):", .{all_required_deps.items.len}) catch {};
    for (all_required_deps.items) |dep| {
        output.print(allocator, "  - {s}", .{dep}) catch {};
    }

    // 2. Build the environment: modules, venv, dependencies, hooks.
    try envbuild.run(allocator, .{
        .env_config = env_config,
        .env_name = env_name,
        .venv_dir = env_dir_path,
        .project_dir = setup_cwd,
        .deps = all_required_deps.items,
        .flags = flags,
        .requires_python = requires_python,
    });
    output.print(allocator, "Environment '{s}' setup completed successfully.", .{env_name}) catch {};

    // 3. Record activation as data (zenv-env.json) and render the per-shell
    // activation scripts from it.
    try activation.generate(allocator, env_config, env_name, env_dir_path);

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
        jupyter.createKernel(allocator, env_name, env_dir_path, null, null) catch |err| {
            output.printError(allocator, "Failed to create Jupyter kernel: {s}", .{@errorName(err)}) catch {};
        };
    }

    // Record the tracked-file checksum + build flags so run/activate/cd/jupyter
    // can detect config drift later and auto-rebuild. The anchor is setup_cwd
    // (== the registered project_dir), so the gate's hash matches this one.
    // Non-fatal: setup already succeeded; a missing stamp just forces the next
    // gated command to re-setup.
    if (autosetup.computeTrackedHash(allocator, setup_cwd, env_name, env_config) catch null) |tracked_hash| {
        defer allocator.free(tracked_hash);
        const flag_tokens = autosetup.flagTokens(allocator, flags) catch &[_][]const u8{};
        defer allocator.free(flag_tokens);
        autosetup.writeStamp(allocator, env_dir_path, tracked_hash, flag_tokens) catch |err| {
            output.print(allocator, "Warning: could not write setup stamp: {s}", .{@errorName(err)}) catch {};
        };
    }

    output.print(allocator,
        \\Environment '{s}' setup complete and registered in global registry.
        \\Usage: source $(zenv activate {s})
    , .{ env_name, env_name }) catch {};
}

/// Renders a resolution failure at the call site — preserving the ambiguous
/// candidate list — and returns the error for main.zig to map to an exit
/// message. Mirrors the messages the deleted lookupRegistryEntry printed.
fn present(allocator: Allocator, registry: *const EnvironmentRegistry, identifier: []const u8, err: anyerror) anyerror {
    if (err == error.AmbiguousIdentifier) {
        const cands = registry.candidates(allocator, identifier) catch return err;
        defer allocator.free(cands);

        output.rawErr(allocator, "ERROR: '{s}' matches multiple environments:\n", .{identifier}) catch {};

        // Host framing applies only to the host-aware branches ("." and a shared
        // alias). A non-unique id-prefix is host-irrelevant — advise more characters.
        const host_relevant = std.mem.eql(u8, identifier, ".") or registry.resolveAlias(identifier) != null;
        if (!host_relevant) {
            for (cands) |c| output.rawErr(allocator, "  - {s}\n", .{c.env_name}) catch {};
            output.rawErr(allocator, "Use more characters of the id, or the exact env name.\n", .{}) catch {};
            return err;
        }

        // Best-effort current host so we can explain WHY the tie wasn't broken:
        // either none of the candidates target this host, or several do.
        const current_host: ?[]const u8 = host.getSystemHostname(allocator) catch null;
        defer if (current_host) |h| allocator.free(h);
        var host_matches: usize = 0;
        for (cands) |c| {
            const m = if (current_host) |h| host.hostMatchesTargets(h, c.target_machines) else false;
            if (m) host_matches += 1;
            const mark = if (m) "  <- matches this host" else "";
            output.rawErr(allocator, "  - {s} (target: {s}){s}\n", .{ c.env_name, c.target_machines, mark }) catch {};
        }
        if (current_host) |h| {
            if (host_matches == 0) {
                output.rawErr(allocator, "None of these target the current host '{s}'. Add this machine to one env's target_machines, or use the exact env name / id.\n", .{h}) catch {};
            } else {
                output.rawErr(allocator, "{d} target the current host '{s}'. Use the exact env name or id to choose one.\n", .{ host_matches, h }) catch {};
            }
        } else {
            output.rawErr(allocator, "Could not determine the current host. Use the exact env name or id.\n", .{}) catch {};
        }
    } else if (err == error.EnvironmentNotRegistered) {
        output.rawErr(allocator, "ERROR: Environment with name or ID '{s}' not found in registry.\n", .{identifier}) catch {};
        output.rawErr(allocator, "Use 'zenv ls' to see all available environments with their IDs.\n", .{}) catch {};
    }
    return err;
}

/// Resolves the environment named by `args[2]`; when it is missing, says how
/// to call `zenv <usage>`.
fn resolveArg(allocator: Allocator, registry: *const EnvironmentRegistry, args: []const []const u8, comptime usage: []const u8) !EnvironmentRegistry.EnvRef {
    if (args.len < 3) {
        output.printError(allocator, "Missing environment name or ID argument.\nUsage: zenv " ++ usage, .{}) catch {};
        return error.EnvironmentNotFound;
    }
    return registry.resolve(allocator, args[2]) catch |e| return present(allocator, registry, args[2], e);
}

pub fn handleActivateCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    var shell: activation.Shell = .sh;
    var auto = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--auto")) {
            auto = true;
            continue;
        }
        const prefix = "--shell=";
        if (!std.mem.startsWith(u8, arg, prefix)) {
            if (!std.mem.startsWith(u8, arg, "-")) continue;
            output.printError(allocator, "Unknown option '{s}' for 'zenv activate'. Options: --shell=<shell>, --auto", .{arg}) catch {};
            return error.ArgsError;
        }
        shell = activation.parseShell(arg[prefix.len..]) orelse {
            output.printError(allocator, "Unsupported shell '{s}'. Supported: sh, bash, zsh, csh, tcsh, fish.", .{arg[prefix.len..]}) catch {};
            return error.ArgsError;
        };
    }
    if (auto) return activateAuto(allocator, registry, positional(args, 0) orelse ".", shell);

    const identifier = positional(args, 0) orelse {
        output.printError(allocator, "Missing environment name or ID argument. Usage: zenv activate <name|id> [--shell=sh|bash|zsh|csh|tcsh|fish]", .{}) catch {};
        return error.EnvironmentNotFound;
    };

    const ref = registry.resolve(allocator, identifier) catch |e| return present(allocator, registry, identifier, e);
    // Rebuild the env first if its config/dependency files changed. The rebuild
    // is silent and any notice goes to stderr, so stdout stays just the
    // activate-script path that the shell sources.
    try autosetup.ensureUpToDate(allocator, registry.get(ref));
    try printActivateScript(allocator, registry.get(ref), shell);
}

/// `zenv activate --auto [dir]`, for the shell hook (`zenv hook`): prints the
/// activation script of the env registered for the nearest directory at or
/// above `dir` that holds a zenv.json. Prints nothing when there is none or
/// several match, so the hook can run it on every project change. Never
/// rebuilds: a build on `cd` would be slow, and would run newly pulled
/// activate hooks unasked. A stale env gets a notice and activates as built.
fn activateAuto(allocator: Allocator, registry: *const EnvironmentRegistry, dir: []const u8, shell: activation.Shell) !void {
    const start = try runtime.realpathAlloc(allocator, dir);
    defer allocator.free(start);
    const root = (try paths.findProjectRoot(allocator, start)) orelse return;
    defer allocator.free(root);

    const ref = registry.resolveDir(allocator, root) catch |e| switch (e) {
        error.EnvironmentNotRegistered => return,
        error.AmbiguousIdentifier => {
            output.rawErr(allocator, "zenv: {s} has several environments for this machine; activate one by name.\n", .{root}) catch {};
            return;
        },
    };
    const entry = registry.get(ref);
    if (autosetup.isStale(allocator, entry) catch false) {
        output.rawErr(allocator, "zenv: '{s}' is out of date with zenv.json; run 'zenv setup {s}' to rebuild it.\n", .{ entry.env_name, entry.env_name }) catch {};
    }
    try printActivateScript(allocator, entry, shell);
}

fn printActivateScript(allocator: Allocator, entry: *const configurations.RegistryEntry, shell: activation.Shell) !void {
    const script = try std.Io.Dir.path.join(allocator, &[_][]const u8{ entry.venv_path, activation.fileName(shell) });
    defer allocator.free(script);
    // Envs built by an older zenv have only activate.sh.
    runtime.access(script) catch {
        output.printError(allocator, "{s} not found. Re-run 'zenv setup {s}' to generate it.", .{ script, entry.env_name }) catch {};
        return error.EnvironmentNotFound;
    };

    output.rawOut(allocator, "{s}\n", .{script}) catch |e| {
        output.printError(allocator, "Error writing to stdout: {s}", .{@errorName(e)}) catch {};
        return;
    };
}

/// `zenv hook <shell>`: prints the shell code that `eval "$(zenv hook zsh)"`
/// loads to activate project environments on cd.
pub fn handleHookCommand(allocator: Allocator, args: []const []const u8) !void {
    const name = positional(args, 0) orelse {
        output.printError(allocator, "Missing shell. Usage: zenv hook zsh", .{}) catch {};
        return error.ArgsError;
    };
    const code = shell_hook.forShell(name) orelse {
        output.printError(allocator, "Unsupported shell '{s}' for 'zenv hook'. Supported: zsh.", .{name}) catch {};
        return error.ArgsError;
    };
    output.rawOut(allocator, "{s}", .{code}) catch |e| {
        output.printError(allocator, "Error writing to stdout: {s}", .{@errorName(e)}) catch {};
    };
}

pub fn handleListCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writerStreaming(runtime.io, &stdout_buf);
    const stdout = &stdout_fw.interface; // special case for using standard writer
    defer stdout.flush() catch {};
    const list_all = args.len > 2 and std.mem.eql(u8, args[2], "--all");
    if (args.len > 3 or (args.len == 3 and !list_all and std.mem.startsWith(u8, args[2], "-"))) {
        output.printError(allocator, "Unexpected argument '{s}'. Usage: zenv ls [--all | <name|id|.>]", .{args[args.len - 1]}) catch {};
        return error.ArgsError;
    }

    // `zenv ls <name|id|.>`: that one environment, whatever machine it targets.
    if (args.len == 3 and !list_all) {
        const ref = try resolveArg(allocator, registry, args, "ls <name|id|.>");
        printListEntry(allocator, stdout, registry.get(ref));
        return;
    }

    // Without --all, only this machine's envs; a host that cannot be
    // determined lists everything.
    const current_hostname: ?[]const u8 = if (list_all) null else host.getSystemHostname(allocator) catch |err| blk: {
        output.print(allocator,
            \\Could not determine current hostname for filtering: {s}
            \\Listing all registered environments instead.
        , .{@errorName(err)}) catch {};
        break :blk null;
    };
    defer if (current_hostname) |h| allocator.free(h);

    var count: usize = 0;
    for (registry.entries.items) |entry| {
        // hostMatchesTargets owns the comma-list matching rules.
        if (current_hostname) |h| if (!host.hostMatchesTargets(h, entry.target_machines_str)) continue;

        printListEntry(allocator, stdout, &entry);
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
fn printListEntry(allocator: Allocator, stdout: *std.Io.Writer, entry: *const configurations.RegistryEntry) void {
    stdout.print("- {s}\n  id      : {s}\n  target  : {s}\n  project : {s}\n  venv    : {s}", .{ entry.env_name, entry.id, entry.target_machines_str, entry.project_dir, entry.venv_path }) catch {};
    // The Python that built the venv, read from <venv>/pyvenv.cfg.
    // Omitted entirely when the env isn't built (no pyvenv.cfg).
    if (configurations.readVenvPython(allocator, entry.venv_path) catch null) |py| {
        defer allocator.free(py);
        stdout.print("\n  python  : {s}", .{py}) catch {};
    }
    if (entry.aliases.items.len > 0) stdout.print("\n  aliases : {f}", .{joinedList(entry.aliases.items)}) catch {};
    if (entry.description) |desc| stdout.print("\n  desc    : {s}", .{desc}) catch {};
    stdout.writeAll("\n") catch {};
}

pub fn handleRegisterCommand(
    allocator: Allocator,
    config: *const ZenvConfig,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    // First positional, not args[2]: `zenv register --no-host myenv` must not
    // treat the flag as the environment name.
    const env_name = positional(args, 0) orelse {
        output.printError(allocator, "Missing environment name argument. Usage: zenv register <name>", .{}) catch {};
        return error.EnvironmentNotFound;
    };

    try checkFlags(allocator, args, &REGISTER_FLAGS);
    const flags = CommandFlags.fromArgs(args);

    // Log flags if they're set
    if (flags.skip_hostname_check) {
        output.print(allocator, "'--no-host' flag detected. Skipping hostname validation.", .{}) catch {};
    }

    // Get the environment config directly without re-parsing validation
    const env_config = config.getEnvironment(env_name) orelse {
        output.printError(allocator, "Environment '{s}' not found in configuration.", .{env_name}) catch {};
        return error.EnvironmentNotFound;
    };

    if (!flags.skip_hostname_check) try env.checkHost(allocator, env_config, env_name);

    // Get absolute path of current working directory
    const cwd_path = runtime.cwdRealpath(allocator) catch |err| {
        output.printError(allocator, "Could not get current working directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(cwd_path);

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
        output.printError(allocator, "Failed to register environment: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    output.print(allocator,
        \\Environment '{s}' registered successfully.
        \\Usage: source $(zenv activate {s})
    , .{ env_name, env_name }) catch {};
}

pub fn handleDeregisterCommand(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const ref = try resolveArg(allocator, registry, args, "deregister <name|id|.>");

    // Resolve once, then remove by handle. deregister returns the owned, detached
    // entry (and persists), so the success message reads a valid name post-removal.
    var removed = registry.deregister(ref) catch |err| {
        output.printError(allocator, "Failed to unregister environment: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer removed.deinit(allocator);

    output.print(allocator, "Environment '{s}' unregistered successfully.", .{removed.env_name}) catch {};
}

pub fn handleCdCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const ref = try resolveArg(allocator, registry, args, "cd <name|id|.>");
    // Rebuild the env first if its config/dependency files changed (silent).
    // A failed rebuild still prints the directory: the project is where the
    // user goes to fix zenv.json, and `cd $(zenv cd ...)` would otherwise land
    // in $HOME. The gate has already shown the rebuild's errors on stderr.
    autosetup.ensureUpToDate(allocator, registry.get(ref)) catch |err| {
        if (err != error.AutoSetupFailed) return err;
    };

    // Output just the project directory path
    output.rawOut(allocator, "{s}\n", .{registry.get(ref).project_dir}) catch |e| {
        output.printError(allocator, "Error writing to stdout: {s}", .{@errorName(e)}) catch {};
        return;
    };
}

pub fn handlePythonCommand(
    allocator: Allocator,
    args: []const []const u8,
) !void {
    // Check if we have a subcommand
    if (args.len < 3) {
        output.printError(allocator, "Missing subcommand for 'python' command", .{}) catch {};
        output.print(allocator, "Available subcommands: install, pin, ls", .{}) catch {};
        return error.ArgsError;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "install")) {
        // Python install [version] command
        var version: ?[]const u8 = null;
        if (args.len >= 4) {
            version = args[3];
            output.print(allocator, "Installing Python version: {s}", .{version.?}) catch {};
        } else {
            output.print(allocator, "No version specified, will install default version", .{}) catch {};
        }

        // Installing does not pin; `zenv python pin` does.
        python.installPython(allocator, version) catch |err| {
            output.printError(allocator, "Python installation failed: {s}", .{@errorName(err)}) catch {};
            return err;
        };
    } else if (std.mem.eql(u8, subcommand, "pin") or std.mem.eql(u8, subcommand, "use")) {
        if (args.len < 4) {
            output.printError(allocator, "Missing version argument for 'python pin' command", .{}) catch {};
            output.print(allocator, "Usage: zenv python pin <version>", .{}) catch {};
            return error.ArgsError;
        }

        const version = args[3];
        try python.setDefaultPythonPath(allocator, version);
    } else if (std.mem.eql(u8, subcommand, "ls") or std.mem.eql(u8, subcommand, "list")) {
        // Python list command - list all installed versions
        try python.listInstalledVersions(allocator);
    } else {
        output.printError(allocator, "Unknown subcommand '{s}' for 'python' command", .{subcommand}) catch {};
        output.print(allocator, "Available subcommands: install, pin, ls", .{}) catch {};
        return error.ArgsError;
    }
}

pub fn handleRmCommand(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const ref = try resolveArg(allocator, registry, args, "rm <name|id>");

    // Owned, detached entry: no raw identifier reaches the mutator (the old
    // ambiguity bug is unrepresentable), and venv_path is read AFTER removal.
    var removed = registry.deregister(ref) catch |err| {
        output.printError(allocator, "Failed to deregister environment: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer removed.deinit(allocator);

    output.print(allocator, "Environment '{s}' deregistered successfully.", .{removed.env_name}) catch {};

    output.print(allocator, "Attempting to remove: {s}", .{removed.venv_path}) catch {};
    runtime.deleteTree(removed.venv_path) catch |err| {
        output.printError(allocator, "Failed to remove '{s}': {s}", .{ removed.venv_path, @errorName(err) }) catch {};
        output.printError(allocator, "You may need to remove it manually.", .{}) catch {};
        return err;
    };

    output.print(allocator, "Directory '{s}' removed successfully.", .{removed.venv_path}) catch {};
    output.print(allocator, "Environment '{s}' removed.", .{removed.env_name}) catch {};
}

pub fn handleRunCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    // Need at least 4 args: zenv run <env> <command>
    if (args.len < 4) {
        output.printError(allocator, "Missing environment name or command. Usage: zenv run <name|id> <command> [args...]", .{}) catch {};
        return error.ArgsError;
    }

    const command = args[3];
    const command_args = args[4..];

    const ref = registry.resolve(allocator, args[2]) catch |e| return present(allocator, registry, args[2], e);
    // Rebuild the env first if its config/dependency files changed (silent).
    try autosetup.ensureUpToDate(allocator, registry.get(ref));
    const venv_path = registry.get(ref).venv_path;

    const term = execInEnv(allocator, venv_path, command, command_args) catch |err| {
        output.printError(allocator, "Failed to run command: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    // Propagate the child's exit status as zenv's own, so callers (CI, scripts)
    // see the real result instead of a flattened 0/1. A signalled child maps to
    // the conventional 128 + signo.
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal, .stopped => |sig| {
            // Saturate rather than truncate: an out-of-range signo must not
            // wrap into a small (success-looking) exit code.
            const signo: u8 = std.math.cast(u8, @backingInt(sig)) orelse 255;
            output.printError(allocator, "Command terminated by signal {d}", .{signo}) catch {};
            std.process.exit(128 +| signo);
        },
        .unknown => |status| {
            output.printError(allocator, "Command terminated abnormally (status {d})", .{status}) catch {};
            std.process.exit(1);
        },
    }
}

/// `zenv add <name|id|.> <package> [--dev] [--zenv] [--uv]`
/// Installs `<package>` into the environment's venv and records it in the right
/// manifest. Install happens FIRST; the manifest is only updated on success.
pub fn handleAddCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const env_id = positional(args, 0) orelse {
        output.printError(allocator, "Missing environment name. Usage: zenv add <name|id|.> <package> [--dev] [--zenv] [--uv]", .{}) catch {};
        return error.ArgsError;
    };
    const package = positional(args, 1) orelse {
        output.printError(allocator, "Missing package name. Usage: zenv add <name|id|.> <package> [--dev] [--zenv] [--uv]", .{}) catch {};
        return error.ArgsError;
    };
    try checkFlags(allocator, args, &ADD_FLAGS);
    const flags = CommandFlags.fromArgs(args);

    const ref = registry.resolve(allocator, env_id) catch |e| return present(allocator, registry, env_id, e);
    const entry = registry.get(ref);
    const env_name = entry.env_name;
    const project_dir = entry.project_dir;

    // The environment must already be built (its activation script exists).
    const activate_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ entry.venv_path, "activate.sh" });
    defer allocator.free(activate_path);
    runtime.access(activate_path) catch |err| {
        if (err == error.FileNotFound) {
            output.printError(allocator, "Environment '{s}' is not set up yet. Run 'zenv setup {s}' first.", .{ env_name, env_name }) catch {};
            return error.EnvironmentNotFound;
        }
        return err;
    };

    // The project's zenv.json tells us which manifest (if any) backs this env.
    const zenv_json_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ project_dir, "zenv.json" });
    defer allocator.free(zenv_json_path);

    const info = try readEnvJson(allocator, zenv_json_path, env_name);
    defer if (info.dependency_file) |df| allocator.free(df);

    // Turning Python on is the user's call, made in zenv.json, not a side
    // effect of adding a package.
    if (!info.python) {
        const retry = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(retry);
        output.printError(allocator, "'{s}' has no Python (\"python\": false in zenv.json), so packages cannot be added.", .{env_name}) catch {};
        output.printError(allocator, "Set \"python\": true for '{s}' in zenv.json, then re-run: zenv {s}", .{ env_name, retry }) catch {};
        return error.NoPython;
    }
    // Python was just turned on for an env built without it: build the venv
    // first (zenv.json changed, so the gate rebuilds).
    if (!try venvHasPython(allocator, entry.venv_path)) {
        try autosetup.ensureUpToDate(allocator, entry);
        if (!try venvHasPython(allocator, entry.venv_path)) {
            output.printError(allocator, "Environment '{s}' has no Python venv yet. Run 'zenv setup {s}' first.", .{ env_name, env_name }) catch {};
            return error.NoPython;
        }
    }

    // Recording the package changes a tracked manifest. If the env is up to
    // date now, the install below makes it up to date again, so the build
    // record is renewed rather than left to trigger a rebuild on the next run.
    const was_fresh = !(autosetup.isStale(allocator, entry) catch true);

    // 1. Install into the venv (only persist below if this succeeds).
    try installPackage(allocator, entry.venv_path, package, flags.use_uv);

    // 2. Persist to the appropriate manifest.
    persistAddedPackage(allocator, project_dir, zenv_json_path, env_name, info.dependency_file, package, flags.dev_mode, flags.zenv_only) catch |err| {
        output.printError(allocator, "'{s}' is installed in '{s}', but recording it failed: {s}. Add it to the manifest by hand.", .{ package, env_name, @errorName(err) }) catch {};
        return err;
    };
    if (was_fresh) autosetup.restamp(allocator, project_dir, env_name, entry.venv_path) catch {};

    output.print(allocator, "Added '{s}' to environment '{s}'.", .{ package, env_name }) catch {};
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
fn readEnvJson(allocator: Allocator, path: []const u8, env_name: []const u8) !EnvJsonInfo {
    const content = runtime.readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const env_obj = parsed.value.object.get(env_name) orelse return .{};
    if (env_obj != .object) return .{};

    var info: EnvJsonInfo = .{};
    if (env_obj.object.get("python")) |py| info.python = !(py == .bool and !py.bool);
    if (env_obj.object.get("dependency_file")) |df| {
        if (df == .string) info.dependency_file = try allocator.dupe(u8, df.string);
    }
    return info;
}

/// Whether zenv.json at `path` sets `"python": false` for `env_name`.
pub fn pythonDisabled(allocator: Allocator, path: []const u8, env_name: []const u8) !bool {
    const info = try readEnvJson(allocator, path, env_name);
    if (info.dependency_file) |df| allocator.free(df);
    return !info.python;
}

/// Whether the venv at `venv_path` has its interpreter link, bin/python.
fn venvHasPython(allocator: Allocator, venv_path: []const u8) !bool {
    const py = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, "bin", "python" });
    defer allocator.free(py);
    runtime.access(py) catch return false;
    return true;
}

/// Refuses a Python-only action on a Python-free env, saying how to enable it.
fn noPython(allocator: Allocator, env_name: []const u8, why: []const u8) error{NoPython} {
    output.printError(allocator, "'{s}' has no Python (\"python\": false in zenv.json); {s}.", .{ env_name, why }) catch {};
    output.printError(allocator, "Set \"python\": true for '{s}' in zenv.json to use it.", .{env_name}) catch {};
    return error.NoPython;
}

/// Installs `package` into the activated environment via pip (or uv when
/// `use_uv`). A non-zero installer exit maps to error.ProcessError.
fn installPackage(allocator: Allocator, venv_path: []const u8, package: []const u8, use_uv: bool) !void {
    const command: []const u8 = if (use_uv) "uv" else "python";
    const cmd_args: []const []const u8 = if (use_uv)
        &[_][]const u8{ "pip", "install", package }
    else
        &[_][]const u8{ "-m", "pip", "install", package };

    output.print(allocator, "Installing '{s}'...", .{package}) catch {};
    const term = execInEnv(allocator, venv_path, command, cmd_args) catch |err| {
        output.printError(allocator, "Failed to run installer: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    if (!runtime.exitedOk(term)) {
        output.printError(allocator, "Package installation failed; nothing was recorded.", .{}) catch {};
        return error.ProcessError;
    }
}

/// Records the installed `package` in the manifest selected by the flags and the
/// env's `dep_file` (see the table in handleAddCommand's docs / the plan).
fn persistAddedPackage(
    allocator: Allocator,
    project_dir: []const u8,
    zenv_json_path: []const u8,
    env_name: []const u8,
    dep_file: ?[]const u8,
    package: []const u8,
    dev: bool,
    zenv_only: bool,
) !void {
    const kind: []const u8 = if (dev) "dev_dependencies" else "dependencies";

    // --zenv (or no dependency_file at all) -> record in zenv.json.
    if (zenv_only or dep_file == null) {
        try manifest.addToZenvJson(allocator, zenv_json_path, env_name, package, dev);
        output.print(allocator, "Recorded in zenv.json ({s}).", .{kind}) catch {};
        return;
    }

    const df = dep_file.?;
    const df_path = try paths.resolvePath(allocator, project_dir, df);
    defer allocator.free(df_path);

    if (std.mem.endsWith(u8, df, ".toml")) {
        // pyproject.toml: runtime -> [project].dependencies, dev -> [dependency-groups].dev.
        const edited = try manifest.addToPyproject(allocator, df_path, package, dev);
        if (edited) {
            const tbl = if (dev) "[dependency-groups].dev" else "[project].dependencies";
            output.print(allocator, "Recorded in {s} ({s}).", .{ df, tbl }) catch {};
        } else {
            // Runtime case with no [project] table: fall back to zenv.json.
            output.print(allocator, "Could not locate [project] in {s}; recording in zenv.json instead.", .{df}) catch {};
            try manifest.addToZenvJson(allocator, zenv_json_path, env_name, package, dev);
        }
    } else if (dev) {
        // requirements files have no dev concept; dev deps live in zenv.json.
        try manifest.addToZenvJson(allocator, zenv_json_path, env_name, package, true);
        output.print(allocator, "Recorded dev dependency in zenv.json.", .{}) catch {};
    } else {
        try manifest.addToRequirementsTxt(allocator, df_path, package);
        output.print(allocator, "Recorded in {s}.", .{df}) catch {};
    }
}

/// Runs `command` inside the environment at `venv_path` with inherited stdio
/// and returns its `Term`. Uses the direct launch when `zenv-env.json` can
/// reproduce activation, else sources activate.sh through bash.
fn execInEnv(allocator: Allocator, venv_path: []const u8, command: []const u8, command_args: []const []const u8) !runtime.Term {
    if (try execDirect(allocator, venv_path, command, command_args)) |term| return term;

    const activate_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, "activate.sh" });
    defer allocator.free(activate_path);
    const argv = try buildRunArgv(allocator, activate_path, command, command_args);
    defer allocator.free(argv);
    return runtime.exec(argv, .{});
}

/// Direct launch: copy this process's environment, apply `zenv-env.json`,
/// resolve `command` against the resulting PATH and spawn it, no shell
/// involved. Returns null (caller falls back to bash) when the spec is missing
/// or `envspec.directReason` reports a blocker, or when ZENV_RUN_SHELL=1.
fn execDirect(allocator: Allocator, venv_path: []const u8, command: []const u8, command_args: []const []const u8) !?runtime.Term {
    if (runtime.env("ZENV_RUN_SHELL")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            zerrors.debugLog(allocator, "run: ZENV_RUN_SHELL=1, using activate.sh", .{});
            return null;
        }
    }

    const parsed = envspec.readSpec(allocator, venv_path) orelse {
        zerrors.debugLog(allocator, "run: no usable {s}, using activate.sh", .{envspec.FILE_NAME});
        return null;
    };
    defer parsed.deinit();
    const spec = &parsed.value;

    // Only the module cache needs the system identity; skip the lookup otherwise.
    const system: ?[]const u8 = if (spec.modules.len > 0) envspec.currentSystem(allocator) catch null else null;
    defer if (system) |s| allocator.free(s);
    if (envspec.directReason(spec, system)) |reason| {
        zerrors.debugLog(allocator, "run: {s}, using activate.sh", .{reason});
        return null;
    }

    var child_env = try runtime.environ_map.clone(allocator);
    defer child_env.deinit();
    try envspec.apply(&child_env, spec);

    const exe = try envspec.resolveCommand(allocator, command, child_env.get("PATH")) orelse {
        // Same status bash's `exec` gives for an unknown command.
        output.printError(allocator, "{s}: command not found", .{command}) catch {};
        return .{ .exited = 127 };
    };
    defer allocator.free(exe);
    zerrors.debugLog(allocator, "run: direct launch of {s}", .{exe});

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, command);
    try argv.appendSlice(allocator, command_args);
    return try runtime.exec(argv.items, .{ .environ_map = &child_env, .exe_path = exe });
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
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    // `zenv` becomes $0 (used only in any bash error message); activate_path is $1.
    try argv.appendSlice(allocator, &[_][]const u8{ "/bin/bash", "-c", run_runner, "zenv", activate_path, command });
    try argv.appendSlice(allocator, command_args);
    return argv.toOwnedSlice(allocator);
}

test "pythonDisabled reads only an explicit false" {
    const test_support = @import("test_support.zig");
    test_support.setupRuntime();
    const a = std.testing.allocator;
    const root = ".zig-cache/tmp/zenv-python-disabled-test";
    runtime.deleteTree(root) catch {};
    defer runtime.deleteTree(root) catch {};
    try runtime.makePath(root);
    const path = root ++ "/zenv.json";
    try runtime.writeFile(path,
        \\{ "base_dir": ".zenv", "off": { "python": false }, "on": { "python": true }, "unset": {} }
    );
    try std.testing.expect(try pythonDisabled(a, path, "off"));
    try std.testing.expect(!try pythonDisabled(a, path, "on"));
    try std.testing.expect(!try pythonDisabled(a, path, "unset"));
    try std.testing.expect(!try pythonDisabled(a, path, "missing"));
    try std.testing.expect(!try pythonDisabled(a, root ++ "/nope.json", "off"));
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
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    const entry = registry.get(try resolveArg(allocator, registry, args, "log <name|id>"));

    const log_file_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ entry.venv_path, "zenv_setup.log" });
    defer allocator.free(log_file_path);

    const log_content = runtime.readFileAlloc(allocator, log_file_path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            output.printError(allocator, "No setup log found for environment '{s}'", .{entry.env_name}) catch {};
            output.printError(allocator, "The log file should be at: {s}", .{log_file_path}) catch {};
        } else {
            output.printError(allocator, "Failed to read log file '{s}': {s}", .{ log_file_path, @errorName(err) }) catch {};
        }
        return err;
    };
    defer allocator.free(log_content);

    // Output the log content
    output.rawOut(allocator, "{s}", .{log_content}) catch |err| {
        output.printError(allocator, "Error writing log to stdout: {s}", .{@errorName(err)}) catch {};
        return err;
    };
}

pub fn handleValidateCommand(
    allocator: Allocator,
    config_path: []const u8,
    args: []const []const u8,
) !void {

    // Use custom config path if provided as an argument
    var validate_config_path: []const u8 = config_path;

    if (args.len > 2) {
        validate_config_path = args[2];
        output.print(allocator, "Using provided file path: {s}", .{validate_config_path}) catch {};
    } else {
        output.print(allocator, "Using default config path: {s}", .{validate_config_path}) catch {};
    }

    // Check if file exists before validating
    if (runtime.access(validate_config_path)) |_| {
        output.print(allocator, "File exists, proceeding with validation", .{}) catch {};
    } else |err| {
        output.printError(allocator, "Failed to open file '{s}': {s}", .{ validate_config_path, @errorName(err) }) catch {};
        std.process.exit(1);
    }

    // validateAndParse prints what it finds; any finding or failure exits 1.
    var config = validation.validateAndParse(allocator, validate_config_path) catch std.process.exit(1);
    config.deinit();
    output.print(allocator, "Configuration file is valid!", .{}) catch {};
}

pub fn handleAliasCommand(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing alias subcommand.
            \\Usage: zenv alias <create|remove|ls|show> [arguments]
        , .{}) catch {};
        return error.ArgsError;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "create")) {
        try handleAliasCreate(allocator, registry, args);
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        try handleAliasRemove(allocator, registry, args);
    } else if (std.mem.eql(u8, subcommand, "ls") or std.mem.eql(u8, subcommand, "list")) {
        try handleAliasList(allocator, registry);
    } else if (std.mem.eql(u8, subcommand, "show")) {
        try handleAliasShow(allocator, registry, args);
    } else {
        output.printError(allocator,
            \\Unknown alias subcommand '{s}'.
            \\Usage: zenv alias <create|remove|ls|show> [arguments]
        , .{subcommand}) catch {};
        return error.ArgsError;
    }
}

fn handleAliasCreate(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 5) {
        output.printError(allocator,
            \\Missing arguments for alias create.
            \\Usage: zenv alias create <alias_name> <env_name|env_id>
        , .{}) catch {};
        return error.ArgsError;
    }

    const alias_name = args[3];
    const env_identifier = args[4];

    // Check if alias name would conflict with existing commands
    const reserved_names = [_][]const u8{ "setup", "activate", "ls", "list", "register", "deregister", "cd", "init", "rm", "rename", "python", "log", "run", "add", "validate", "alias", "jupyter", "hook", "help", "version" };
    for (reserved_names) |reserved| {
        if (std.mem.eql(u8, alias_name, reserved)) {
            output.printError(allocator, "Alias name '{s}' conflicts with existing command.", .{alias_name}) catch {};
            return error.ArgsError;
        }
    }

    // Check if alias name is "." (reserved for current directory)
    if (std.mem.eql(u8, alias_name, ".")) {
        output.printError(allocator, "Alias name '.' is reserved for current directory notation.", .{}) catch {};
        return error.ArgsError;
    }

    // Resolve environment identifier to get the actual environment name
    const target_ref = registry.resolve(allocator, env_identifier) catch |e| return present(allocator, registry, env_identifier, e);
    // Owned: addAlias re-reads the registry, which frees the entry's strings.
    const target_env_name = try allocator.dupe(u8, registry.get(target_ref).env_name);
    defer allocator.free(target_env_name);

    // Add alias to registry
    registry.addAlias(alias_name, target_env_name) catch |err| {
        switch (err) {
            error.EnvironmentNotFound => output.printError(allocator, "Environment '{s}' not found.", .{env_identifier}) catch {},
            error.AliasAlreadyExists => output.printError(allocator, "Alias '{s}' already exists.", .{alias_name}) catch {},
            error.InvalidEnvironmentName => output.printError(allocator, "Invalid alias '{s}': use letters, digits, '_', '-' and '.' (not '.' or '..').", .{alias_name}) catch {},
            else => output.printError(allocator, "Failed to create alias: {s}", .{@errorName(err)}) catch {},
        }
        return err;
    };

    output.print(allocator, "Alias '{s}' created for environment '{s}'.", .{ alias_name, target_env_name }) catch {};
}

fn handleAliasRemove(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing alias name.
            \\Usage: zenv alias remove <alias_name>
        , .{}) catch {};
        return error.ArgsError;
    }

    const alias_name = args[3];

    if (registry.removeAlias(alias_name) catch |err| {
        output.printError(allocator, "Failed to update registry: {s}", .{@errorName(err)}) catch {};
        return err;
    }) {
        output.print(allocator, "Alias '{s}' removed.", .{alias_name}) catch {};
    } else {
        output.printError(allocator, "Alias '{s}' not found.", .{alias_name}) catch {};
        return error.AliasNotFound;
    }
}

fn handleAliasList(allocator: Allocator, registry: *EnvironmentRegistry) !void {
    var any = false;
    for (registry.entries.items) |entry| for (entry.aliases.items) |alias| {
        if (!any) output.print(allocator, "Defined aliases:", .{}) catch {};
        any = true;
        output.print(allocator, "  {s} -> {s}", .{ alias, entry.env_name }) catch {};
    };
    if (!any) output.print(allocator, "No aliases defined.", .{}) catch {};
}

fn handleAliasShow(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing alias name.
            \\Usage: zenv alias show <alias_name>
        , .{}) catch {};
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
                    output.print(allocator, "Alias '{s}' resolves to:", .{alias_name}) catch {};
                    found = true;
                }
                output.print(allocator, "  {s} (target: {s})", .{ entry.env_name, entry.target_machines_str }) catch {};
                break;
            }
        }
    }
    if (!found) {
        output.printError(allocator, "Alias '{s}' not found.", .{alias_name}) catch {};
        return error.AliasNotFound;
    }
}

pub fn handleJupyterCommand(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 3) {
        output.printError(allocator,
            \\Missing jupyter subcommand.
            \\Usage: zenv jupyter <create|remove|ls|check> [arguments]
        , .{}) catch {};
        return error.ArgsError;
    }

    const subcommand = args[2];

    if (std.mem.eql(u8, subcommand, "create")) {
        try handleJupyterCreate(allocator, registry, args);
    } else if (std.mem.eql(u8, subcommand, "remove")) {
        try handleJupyterRemove(allocator, registry, args);
    } else if (std.mem.eql(u8, subcommand, "ls") or std.mem.eql(u8, subcommand, "list")) {
        try jupyter.listKernels(allocator);
    } else if (std.mem.eql(u8, subcommand, "check")) {
        try jupyter.checkJupyter(allocator);
    } else {
        output.printError(allocator,
            \\Unknown jupyter subcommand '{s}'.
            \\Usage: zenv jupyter <create|remove|ls|check> [arguments]
        , .{subcommand}) catch {};
        return error.ArgsError;
    }
}

fn handleJupyterCreate(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing environment name argument.
            \\Usage: zenv jupyter create <name|id|.> [--name <kernel_name>] [--display-name <display_name>]
        , .{}) catch {};
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
            output.printError(allocator, "Unknown option '{s}' for 'zenv jupyter create'. Options: --name, --display-name", .{args[i]}) catch {};
            return error.ArgsError;
        };
        if (i + 1 >= args.len) {
            output.printError(allocator, "Option '{s}' needs a value.", .{args[i]}) catch {};
            return error.ArgsError;
        }
        slot.* = args[i + 1];
    }

    // Same host-aware resolver as every other command: ids, aliases and "."
    // work, and on a shared filesystem the kernel binds to THIS machine's env.
    const ref = registry.resolve(allocator, identifier) catch |e| return present(allocator, registry, identifier, e);
    const entry = registry.get(ref);
    // Rebuild the env first if its config/dependency files changed (silent), so
    // the kernel is created against an up-to-date environment.
    try autosetup.ensureUpToDate(allocator, entry);

    const zenv_json_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ entry.project_dir, "zenv.json" });
    defer allocator.free(zenv_json_path);
    if (try pythonDisabled(allocator, zenv_json_path, entry.env_name)) return noPython(allocator, entry.env_name, "a Jupyter kernel needs Python");

    try jupyter.createKernel(allocator, entry.env_name, entry.venv_path, custom_name, custom_display_name);
}

fn handleJupyterRemove(
    allocator: Allocator,
    registry: *const EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator,
            \\Missing environment name argument.
            \\Usage: zenv jupyter remove <env_name>
        , .{}) catch {};
        return error.ArgsError;
    }

    // Resolve through the registry so aliases/ids work. Only a name that is not
    // registered at all falls back to the raw name (a kernel whose environment
    // was already deregistered); an ambiguous or '.' identifier must not be
    // guessed into a kernel name.
    const identifier = args[3];
    const env_name = blk: {
        const ref = registry.resolve(allocator, identifier) catch |e| {
            if (e == error.EnvironmentNotRegistered and paths.isValidEnvName(identifier)) break :blk identifier;
            return present(allocator, registry, identifier, e);
        };
        break :blk registry.get(ref).env_name;
    };
    try jupyter.removeKernel(allocator, env_name);
}

pub fn handleRenameCommand(
    allocator: Allocator,
    registry: *EnvironmentRegistry,
    args: []const []const u8,
) !void {
    if (args.len < 4) {
        output.printError(allocator, "Usage: zenv rename <old_name|id> <new_name>", .{}) catch {};
        return error.ArgsError;
    }

    const old_identifier = args[2];
    const new_name = args[3];

    // Everything that can refuse the rename is checked before anything moves.
    // The name becomes a directory next to the venv, so it must not be a path.
    try requireValidEnvName(allocator, new_name);
    if (registry.nameTaken(new_name)) {
        output.printError(allocator, "'{s}' is already an environment name, alias or id.", .{new_name}) catch {};
        return error.EnvironmentAlreadyExists;
    }

    var ref = registry.resolve(allocator, old_identifier) catch |e| return present(allocator, registry, old_identifier, e);

    // Owned copies: the FS orchestration and rollback messages need these to
    // outlive registry.rename (which frees the entry's copies).
    const old_name = try allocator.dupe(u8, registry.get(ref).env_name);
    defer allocator.free(old_name);
    const old_venv_path = try allocator.dupe(u8, registry.get(ref).venv_path);
    defer allocator.free(old_venv_path);
    const project_dir = try allocator.dupe(u8, registry.get(ref).project_dir);
    defer allocator.free(project_dir);

    const parent_dir = std.Io.Dir.path.dirname(old_venv_path) orelse {
        output.printError(allocator, "Invalid virtual environment path", .{}) catch {};
        return error.InvalidPath;
    };
    const new_venv_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ parent_dir, new_name });
    defer allocator.free(new_venv_path);

    if (runtime.access(new_venv_path)) |_| {
        output.printError(allocator, "New environment directory already exists: {s}", .{new_venv_path}) catch {};
        return error.PathAlreadyExists;
    } else |err| if (err != error.FileNotFound) return err;

    // The activation scripts are regenerated from zenv-env.json.
    {
        const spec = envspec.readSpec(allocator, old_venv_path) orelse {
            output.printError(allocator, "{s} has no usable {s}; re-run 'zenv setup {s}' first.", .{ old_venv_path, envspec.FILE_NAME, old_name }) catch {};
            return error.MissingEnvSpec;
        };
        spec.deinit();
    }

    // An env that is up to date now must not rebuild after the rename: the
    // build record hashes the env's name.
    const was_fresh = !(autosetup.isStale(allocator, registry.get(ref)) catch true);
    const has_jupyter_kernel = jupyter.hasKernel(allocator, old_name);

    output.print(allocator, "Renaming environment '{s}' to '{s}'...", .{ old_name, new_name }) catch {};

    runtime.rename(old_venv_path, new_venv_path) catch |err| {
        output.printError(allocator, "Failed to rename environment directory: {s}", .{@errorName(err)}) catch {};
        return error.IoError;
    };

    updateGeneratedScripts(allocator, new_name, old_venv_path, new_venv_path) catch |err| {
        undoMove(allocator, old_name, new_venv_path, old_venv_path);
        return err;
    };

    registry.rename(&ref, new_name) catch |err| {
        undoMove(allocator, old_name, new_venv_path, old_venv_path);
        switch (err) {
            error.EnvironmentAlreadyExists => output.printError(allocator, "'{s}' is already an environment name, alias or id.", .{new_name}) catch {},
            else => output.printError(allocator, "Failed to update registry: {s}", .{@errorName(err)}) catch {},
        }
        return err;
    };

    if (has_jupyter_kernel) {
        jupyter.renameKernel(allocator, old_name, new_name) catch |err| {
            registry.rename(&ref, old_name) catch {}; // re-saves; ref is kept current
            undoMove(allocator, old_name, new_venv_path, old_venv_path);
            switch (err) {
                error.KernelExists => output.printError(allocator, "Jupyter kernel '{s}' already exists", .{new_name}) catch {},
                else => output.printError(allocator, "Failed to rename Jupyter kernel: {s}", .{@errorName(err)}) catch {},
            }
            return err;
        };
    }

    output.print(allocator, "Environment renamed successfully!", .{}) catch {};
    output.print(allocator, "  Name: {s} → {s}", .{ old_name, new_name }) catch {};
    output.print(allocator, "  Directory: {s} → {s}", .{ old_venv_path, new_venv_path }) catch {};
    if (has_jupyter_kernel) {
        output.print(allocator, "  Jupyter kernel: zenv-{s} → zenv-{s}", .{ old_name, new_name }) catch {};
    }
    output.print(allocator, "  Generated scripts updated", .{}) catch {};

    updateLocalConfigs(allocator, old_name, new_name, project_dir) catch |err| {
        output.printError(allocator, "Environment renamed successfully, but failed to update local config files: {s}", .{@errorName(err)}) catch {};
        return;
    };
    if (was_fresh) autosetup.restamp(allocator, project_dir, new_name, new_venv_path) catch {};
}

/// Rolls back a rename's directory move: moves the venv back to `old_venv_path`
/// FIRST, then regenerates its scripts there (they are read from the venv's
/// current location). Best effort; says what to do if it cannot.
fn undoMove(allocator: Allocator, old_name: []const u8, new_venv_path: []const u8, old_venv_path: []const u8) void {
    runtime.rename(new_venv_path, old_venv_path) catch |err| {
        output.printError(allocator, "Could not move {s} back to {s}: {s}. Move it back by hand.", .{ new_venv_path, old_venv_path, @errorName(err) }) catch {};
        return;
    };
    updateGeneratedScripts(allocator, old_name, new_venv_path, old_venv_path) catch {
        output.printError(allocator, "Could not restore the scripts of '{s}'; re-run 'zenv setup {s}'.", .{ old_name, old_name }) catch {};
    };
}

/// Points a venv moved from `from_path` to `to_path` (where it is now) at its
/// location and `name`: the activation scripts are regenerated from the stored
/// zenv-env.json, and paths are rewritten in the user's hook scripts and in
/// bin/ (console-script shebangs). Also used, swapped, to roll a rename back.
fn updateGeneratedScripts(allocator: Allocator, name: []const u8, from_path: []const u8, to_path: []const u8) !void {
    const parsed = envspec.readSpec(allocator, to_path) orelse {
        output.printError(allocator, "{s} has no usable {s}; re-run 'zenv setup' for this environment first.", .{ to_path, envspec.FILE_NAME }) catch {};
        return error.MissingEnvSpec;
    };
    defer parsed.deinit();

    // A hook-script copy that cannot be rewritten fails (and so rolls back)
    // the rename; a bin/ script that cannot only warns.
    rewriteVenvPaths(allocator, to_path, "scripts", from_path, true) catch |err| {
        output.printError(allocator, "Failed to update scripts directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    rewriteVenvPaths(allocator, to_path, "bin", from_path, false) catch |err| {
        output.printError(allocator, "Failed to update venv bin/ scripts: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const moved = try envspec.relocate(arena.allocator(), &parsed.value, from_path, to_path, name);
    activation.writeAll(arena.allocator(), &moved) catch |err| {
        output.printError(allocator, "Failed to regenerate activation scripts: {s}", .{@errorName(err)}) catch {};
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
fn rewriteVenvPaths(allocator: Allocator, venv_path: []const u8, sub: []const u8, old_venv_path: []const u8, strict: bool) !void {
    const dir_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, sub });
    defer allocator.free(dir_path);

    var dir = runtime.openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(runtime.io);

    var it = dir.iterate();
    while (try it.next(runtime.io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(path);

        const content = runtime.readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            if (!strict) continue;
            output.printError(allocator, "Failed to update {s}: {s}", .{ path, @errorName(err) }) catch {};
            return err;
        };
        defer allocator.free(content);
        if (std.mem.findScalar(u8, content, 0) != null) continue; // binary
        if (std.mem.find(u8, content, old_venv_path) == null) continue;

        const updated = try std.mem.replaceOwned(u8, allocator, content, old_venv_path, venv_path);
        defer allocator.free(updated);
        runtime.writeFile(path, updated) catch |err| {
            output.printError(allocator, "Failed to update {s}: {s}", .{ path, @errorName(err) }) catch {};
            if (strict) return err;
        };
    }
}

test "rewriteVenvPaths rewrites text files and leaves binaries alone" {
    const test_support = @import("test_support.zig");
    test_support.setupRuntime();
    const a = std.testing.allocator;
    const root = ".zig-cache/tmp/zenv-rewrite-venv-paths-test";
    runtime.deleteTree(root) catch {};
    defer runtime.deleteTree(root) catch {};
    try runtime.makePath(root ++ "/new/bin");
    try runtime.makePath(root ++ "/new/scripts");
    try runtime.writeFile(root ++ "/new/bin/pip", "#!/old/venv/bin/python\nimport pip\n");
    try runtime.writeFile(root ++ "/new/bin/blob", "/old/venv\x00binary");
    try runtime.writeFile(root ++ "/new/scripts/activate_hook.sh", "echo /old/venv/x\n");

    try rewriteVenvPaths(a, root ++ "/new", "bin", "/old/venv", false);
    try rewriteVenvPaths(a, root ++ "/new", "scripts", "/old/venv", true);
    try rewriteVenvPaths(a, root ++ "/new", "missing", "/old/venv", true);

    const cases = [_][2][]const u8{
        .{ root ++ "/new/bin/pip", "#!" ++ root ++ "/new/bin/python\nimport pip\n" },
        .{ root ++ "/new/bin/blob", "/old/venv\x00binary" },
        .{ root ++ "/new/scripts/activate_hook.sh", "echo " ++ root ++ "/new/x\n" },
    };
    for (cases) |case| {
        const got = try runtime.readFileAlloc(a, case[0], 1024);
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

fn updateLocalConfigs(allocator: Allocator, old_name: []const u8, new_name: []const u8, project_dir: []const u8) !void {
    const config_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ project_dir, "zenv.json" });
    defer allocator.free(config_path);

    output.print(allocator, "Updating local config: {s}", .{config_path}) catch {};

    const config_contents = runtime.readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            output.print(allocator, "No local config file found, skipping update", .{}) catch {};
            return; // No config file, that's fine
        }
        output.printError(allocator, "Failed to open config file: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(config_contents);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, config_contents, .{}) catch |err| {
        output.printError(allocator, "Failed to parse local config JSON: {s}", .{@errorName(err)}) catch {};
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        output.printError(allocator, "Local config is not a JSON object, skipping update", .{}) catch {};
        return;
    }
    const root = &parsed.value.object;

    if (root.get(old_name) == null) {
        output.print(allocator, "Environment '{s}' not found in local config, skipping update", .{old_name}) catch {};
        return;
    }
    if (root.get(new_name) != null) {
        output.printError(allocator, "Local config already has an entry '{s}'; not updating it", .{new_name}) catch {};
        return;
    }

    output.print(allocator, "Found environment '{s}' in local config, updating to '{s}'", .{ old_name, new_name }) catch {};

    // Rename the TOP-LEVEL key only, structurally: rebuild the root object in
    // order with the one key swapped, then re-serialize. Unlike a textual
    // replace, this can never touch a nested key or a string value that
    // happens to contain the name.
    var new_root: std.json.ObjectMap = .empty;
    defer new_root.deinit(allocator);
    var it = root.iterator();
    while (it.next()) |kv| {
        const key = if (std.mem.eql(u8, kv.key_ptr.*, old_name)) new_name else kv.key_ptr.*;
        try new_root.put(allocator, key, kv.value_ptr.*);
    }

    try manifest.writeJson(allocator, config_path, .{ .object = new_root });

    output.print(allocator, "Successfully updated local config file", .{}) catch {};
}
