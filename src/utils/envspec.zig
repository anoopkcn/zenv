//! Environment-as-data: `<venv>/zenv-env.json`.
//!
//! `zenv setup` records what activating the environment does to the process
//! environment as an ordered list of operations (set / prepend / unset), next to
//! the module-env cache captured during setup. `zenv run` and `zenv add` apply
//! those operations to their own environment and spawn the command directly,
//! skipping `bash` + `activate.sh`.
//!
//! The same Spec is what activation.zig renders into activate.sh / activate.csh,
//! so the shells and `run` agree on one description of the environment.
//!
//! The data cannot reproduce everything activate.sh does: user activate hooks
//! are shell code, and a missing or stale module cache means a real
//! `module load` is needed. `directReason` names the first such blocker and the
//! caller then falls back to sourcing activate.sh.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const runtime = @import("runtime.zig");
const template = @import("template.zig");
const host = @import("host.zig");
const EnvironmentConfig = @import("config.zig").EnvironmentConfig;

pub const FILE_NAME = "zenv-env.json";

/// Bump when the JSON layout changes; a mismatching file is ignored (callers
/// fall back to activate.sh until the next `zenv setup` rewrites it).
pub const FORMAT_VERSION: u32 = 1;

pub const OpKind = enum { set, prepend, unset };

/// One environment change. `prepend` follows the activate.sh rule
/// `NAME=value"${NAME:+:$NAME}"`: the value goes in front of a non-empty
/// current value, or replaces an empty/unset one. `unset` ignores `value`.
pub const Op = struct {
    op: OpKind,
    name: []const u8,
    value: []const u8 = "",
};

/// The module environment captured by setup (see setup.template
/// `zenv_write_module_cache`), with the stamp fields that decide whether it may
/// be replayed on this machine.
pub const ModuleCache = struct {
    version: u32,
    system: []const u8,
    untrusted: bool,
    ops: []const Op,
};

pub const Spec = struct {
    format: u32 = FORMAT_VERSION,
    /// Environment name; the shell prompt prefix is `(name) `.
    name: []const u8,
    venv: []const u8,
    /// Modules the env declares, in load order. Empty means activation only
    /// purges (when a module system is present).
    modules: []const []const u8 = &.{},
    /// `module_cache` from zenv.json. Distinguishes "caching off" from "on but
    /// nothing captured" when `module_cache` below is null.
    module_cache_enabled: bool = false,
    /// Applied before `ops`. Null when caching is off or no data was captured.
    module_cache: ?ModuleCache = null,
    /// The venv part of activation, in order.
    ops: []const Op,
    /// activate.commands from zenv.json (sh code, run in the user's shell).
    activate_commands: []const []const u8 = &.{},
    /// activate.script, copied into `<venv>/scripts/` at setup (sh code).
    activate_script: ?[]const u8 = null,

    pub fn hasActivateHooks(self: *const Spec) bool {
        return self.activate_commands.len > 0 or self.activate_script != null;
    }

    /// The captured module env when it may be replayed at all: declared
    /// modules, caching on, a trusted capture in the current format. Whether
    /// it fits the current system is decided at activation time.
    pub fn usableModuleCache(self: *const Spec) ?ModuleCache {
        if (self.modules.len == 0 or !self.module_cache_enabled) return null;
        const cache = self.module_cache orelse return null;
        if (cache.version != template.MODULE_CACHE_VERSION or cache.untrusted) return null;
        return cache;
    }
};

/// The venv part of activation: what the venv's own `bin/activate` exports,
/// plus zenv's additions. `prompt` is bin/activate's VIRTUAL_ENV_PROMPT (its
/// format varies by Python version); null leaves the variable alone. PS1 and
/// `deactivate` are shell concerns, handled by activation.zig. All slices are
/// allocated with `allocator` (use an arena).
pub fn venvOps(allocator: Allocator, venv_path: []const u8, prompt: ?[]const u8) ![]const Op {
    const bin = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, "bin" });
    var ops: std.ArrayList(Op) = .empty;
    try ops.append(allocator, .{ .op = .set, .name = "VIRTUAL_ENV", .value = venv_path });
    try ops.append(allocator, .{ .op = .prepend, .name = "PATH", .value = bin });
    try ops.append(allocator, .{ .op = .unset, .name = "PYTHONHOME" });
    if (prompt) |p| try ops.append(allocator, .{ .op = .set, .name = "VIRTUAL_ENV_PROMPT", .value = p });
    try ops.append(allocator, .{ .op = .set, .name = "PYTHONDONTWRITEBYTECODE", .value = "1" });
    try ops.append(allocator, .{ .op = .set, .name = "ZENV_ENV_DIR", .value = venv_path });
    return ops.toOwnedSlice(allocator);
}

/// Extracts the `VIRTUAL_ENV_PROMPT=...` assignment from a bin/activate script,
/// dropping one level of surrounding quotes. Python 3.12 writes `"(name) "`,
/// 3.13+ writes the bare name. Null when the script has no such line.
pub fn promptFromActivate(script: []const u8) ?[]const u8 {
    const key = "VIRTUAL_ENV_PROMPT=";
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const v = line[key.len..];
        if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) return v[1 .. v.len - 1];
        return v;
    }
    return null;
}

/// Parses the module-env data file: one `set NAME=VALUE` or
/// `prepend NAME=VALUE` per line. Any other line is an error, so a corrupt file
/// disables replay instead of applying a partial environment.
pub fn parseModuleData(allocator: Allocator, content: []const u8) ![]const Op {
    var ops: std.ArrayList(Op) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sp = std.mem.findScalar(u8, line, ' ') orelse return error.InvalidModuleData;
        const kind: OpKind = if (std.mem.eql(u8, line[0..sp], "set"))
            .set
        else if (std.mem.eql(u8, line[0..sp], "prepend"))
            .prepend
        else
            return error.InvalidModuleData;
        const rest = line[sp + 1 ..];
        const eq = std.mem.findScalar(u8, rest, '=') orelse return error.InvalidModuleData;
        if (eq == 0) return error.InvalidModuleData;
        try ops.append(allocator, .{ .op = kind, .name = rest[0..eq], .value = rest[eq + 1 ..] });
    }
    return ops.toOwnedSlice(allocator);
}

/// Reads the module cache data + stamp from `venv_path`. Null when either file
/// is missing or malformed. Results borrow from `allocator` (use an arena).
fn loadModuleCache(allocator: Allocator, venv_path: []const u8) ?ModuleCache {
    const data_path = std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, template.MODULE_CACHE_DATA }) catch return null;
    const stamp_path = std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, template.MODULE_CACHE_STAMP }) catch return null;
    const data = runtime.readFileAlloc(allocator, data_path, 16 * 1024 * 1024) catch return null;
    const stamp = runtime.readFileAlloc(allocator, stamp_path, 64 * 1024) catch return null;

    var cache = ModuleCache{ .version = 0, .system = "", .untrusted = true, .ops = &.{} };
    var lines = std.mem.splitScalar(u8, stamp, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "version")) {
            cache.version = std.fmt.parseInt(u32, val, 10) catch return null;
        } else if (std.mem.eql(u8, key, "system")) {
            cache.system = val;
        } else if (std.mem.eql(u8, key, "untrusted")) {
            cache.untrusted = std.mem.eql(u8, val, "1");
        }
    }
    cache.ops = parseModuleData(allocator, data) catch return null;
    return cache;
}

/// Builds the Spec for `env_config`. Call at the end of setup, after the setup
/// script has (re)written the module cache files and created the venv.
/// `activate_script` is the hook's path inside the venv (already copied), if
/// any. Everything is allocated with, or borrowed from, `allocator` and
/// `env_config` (use an arena).
pub fn build(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    venv_path: []const u8,
    activate_script: ?[]const u8,
) !Spec {
    const activate_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, "bin", "activate" });
    const activate_text = runtime.readFileAlloc(allocator, activate_path, 1024 * 1024) catch "";

    const modules = env_config.modules.items;
    return .{
        .name = env_name,
        .venv = venv_path,
        .modules = modules,
        .module_cache_enabled = env_config.module_cache,
        .module_cache = if (modules.len > 0 and env_config.module_cache) loadModuleCache(allocator, venv_path) else null,
        .ops = try venvOps(allocator, venv_path, promptFromActivate(activate_text)),
        .activate_commands = if (env_config.activate) |act| (if (act.commands) |c| c.items else &.{}) else &.{},
        .activate_script = activate_script,
    };
}

/// Writes `spec` to `<spec.venv>/zenv-env.json` atomically.
pub fn write(allocator: Allocator, spec: *const Spec) !void {
    const text = try json.Stringify.valueAlloc(allocator, spec.*, .{ .whitespace = .indent_2 });
    defer allocator.free(text);
    const path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ spec.venv, FILE_NAME });
    defer allocator.free(path);
    try runtime.writeFileAtomic(allocator, path, text);
}

/// Parses a spec. Errors on malformed JSON or a different format version.
/// Caller must `deinit` the result.
pub fn parseSpec(allocator: Allocator, text: []const u8) !json.Parsed(Spec) {
    const parsed = try json.parseFromSlice(Spec, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (parsed.value.format != FORMAT_VERSION) {
        parsed.deinit();
        return error.UnsupportedFormat;
    }
    return parsed;
}

/// Reads `<venv_path>/zenv-env.json`. Null when absent, unreadable, malformed
/// or from another format version. Caller must `deinit` the result.
pub fn readSpec(allocator: Allocator, venv_path: []const u8) ?json.Parsed(Spec) {
    const path = std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, FILE_NAME }) catch return null;
    defer allocator.free(path);
    const text = runtime.readFileAlloc(allocator, path, 16 * 1024 * 1024) catch return null;
    defer allocator.free(text);
    return parseSpec(allocator, text) catch null;
}

/// The cluster identity the module cache is keyed on: `${SYSTEMNAME:-$(hostname)}`,
/// exactly as setup.template writes it into the stamp. Caller owns the result.
pub fn currentSystem(allocator: Allocator) ![]const u8 {
    if (runtime.env("SYSTEMNAME")) |s| {
        if (s.len > 0) return allocator.dupe(u8, s);
    }
    return host.getHostnameFromSyscall(allocator);
}

/// Whether a module system (Lmod / Environment Modules) is initialised in this
/// process environment. activate.sh guards its module section with
/// `command -v module`; these are the variables that come with that function.
pub fn moduleSystemPresent() bool {
    for ([_][]const u8{ "LMOD_CMD", "MODULESHOME", "BASH_FUNC_module%%" }) |name| {
        if (runtime.env(name)) |v| {
            if (v.len > 0) return true;
        }
    }
    return false;
}

/// Returns why `spec` cannot be applied directly (so the caller must source
/// activate.sh), or null when applying it reproduces activation.
///
/// Known difference on the direct path: with modules declared and a valid
/// cache, the cache is replayed even when `module` is not initialised in the
/// calling shell. activate.sh would skip its module section entirely there.
pub fn directReason(spec: *const Spec, current_system: ?[]const u8, module_system_present: bool) ?[]const u8 {
    if (spec.hasActivateHooks()) return "activate hooks are configured";
    if (spec.modules.len > 0) {
        const cache = spec.module_cache orelse return "no module cache data";
        if (cache.version != template.MODULE_CACHE_VERSION) return "module cache version mismatch";
        if (cache.untrusted) return "module cache is marked untrusted";
        const sys = current_system orelse return "cannot determine the current system";
        if (!std.mem.eql(u8, sys, cache.system)) return "module cache was captured on another system";
    } else if (module_system_present) {
        // activate.sh runs `module --force purge` here, which depends on the
        // caller's loaded modules and so cannot be stored as data.
        return "module system present (activate.sh purges modules)";
    }
    return null;
}

pub fn applyOp(map: *std.process.Environ.Map, op: Op) !void {
    switch (op.op) {
        .set => try map.put(op.name, op.value),
        .unset => _ = map.orderedRemove(op.name),
        .prepend => {
            const current = map.get(op.name) orelse "";
            if (current.len == 0) return map.put(op.name, op.value);
            const joined = try std.mem.concat(map.allocator, u8, &[_][]const u8{ op.value, ":", current });
            defer map.allocator.free(joined);
            try map.put(op.name, joined); // put copies `joined` before freeing the old value
        },
    }
}

/// Applies the module cache (when declared) and then the venv ops to `map`.
/// Only call after `directReason` returned null.
pub fn apply(map: *std.process.Environ.Map, spec: *const Spec) !void {
    if (spec.modules.len > 0) {
        if (spec.module_cache) |cache| {
            for (cache.ops) |op| try applyOp(map, op);
        }
    }
    for (spec.ops) |op| try applyOp(map, op);
}

/// Resolves `command` the way `exec` in a shell would: a name containing '/'
/// is used as-is, otherwise the first executable regular file named `command`
/// in `path_value` (an empty entry means the current directory). Returns null
/// when nothing matches. Caller owns the result.
pub fn resolveCommand(allocator: Allocator, command: []const u8, path_value: ?[]const u8) !?[]u8 {
    if (command.len == 0) return null;
    if (std.mem.findScalar(u8, command, '/') != null) return try allocator.dupe(u8, command);

    var dirs = std.mem.splitScalar(u8, path_value orelse return null, ':');
    while (dirs.next()) |entry| {
        const dir = if (entry.len == 0) "." else entry;
        const candidate = try std.Io.Dir.path.join(allocator, &[_][]const u8{ dir, command });
        if (isExecutableFile(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn isExecutableFile(path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(runtime.io, path, .{}) catch return false;
    if (st.kind != .file) return false;
    cwd.access(runtime.io, path, .{ .execute = true }) catch return false;
    return true;
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");

test "venvOps mirrors bin/activate + activate.sh exports, in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ops = try venvOps(arena.allocator(), "/p/.zenv/demo", "(demo) ");
    try testing.expectEqual(@as(usize, 6), ops.len);
    try testing.expectEqualStrings("VIRTUAL_ENV", ops[0].name);
    try testing.expectEqual(OpKind.prepend, ops[1].op);
    try testing.expectEqualStrings("/p/.zenv/demo/bin", ops[1].value);
    try testing.expectEqual(OpKind.unset, ops[2].op);
    try testing.expectEqualStrings("PYTHONHOME", ops[2].name);
    try testing.expectEqualStrings("(demo) ", ops[3].value);
    try testing.expectEqualStrings("ZENV_ENV_DIR", ops[5].name);

    const no_prompt = try venvOps(arena.allocator(), "/p/.zenv/demo", null);
    try testing.expectEqual(@as(usize, 5), no_prompt.len);
}

test "promptFromActivate handles both CPython formats" {
    try testing.expectEqualStrings("(matbind) ", promptFromActivate("    VIRTUAL_ENV_PROMPT=\"(matbind) \"\n    export VIRTUAL_ENV_PROMPT\n").?);
    try testing.expectEqualStrings("demo", promptFromActivate("VIRTUAL_ENV_PROMPT=demo\n").?);
    try testing.expectEqualStrings("my env", promptFromActivate("VIRTUAL_ENV_PROMPT='my env'\n").?);
    try testing.expect(promptFromActivate("export VIRTUAL_ENV=/x\n") == null);
}

test "parseModuleData reads set/prepend lines and rejects anything else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ops = try parseModuleData(a, "set LMOD_FAMILY=gcc\nprepend PATH=/m/bin:/m2/bin\nset EMPTY=\nset EQ=a=b\n");
    try testing.expectEqual(@as(usize, 4), ops.len);
    try testing.expectEqual(OpKind.set, ops[0].op);
    try testing.expectEqualStrings("gcc", ops[0].value);
    try testing.expectEqual(OpKind.prepend, ops[1].op);
    try testing.expectEqualStrings("/m/bin:/m2/bin", ops[1].value);
    try testing.expectEqualStrings("", ops[2].value);
    try testing.expectEqualStrings("a=b", ops[3].value); // only the first '=' splits

    try testing.expectError(error.InvalidModuleData, parseModuleData(a, "export X=1\n"));
    try testing.expectError(error.InvalidModuleData, parseModuleData(a, "set =1\n"));
    try testing.expectError(error.InvalidModuleData, parseModuleData(a, "set NOVALUE\n"));
}

test "spec survives a stringify/parse round trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mod_ops = [_]Op{.{ .op = .prepend, .name = "LD_LIBRARY_PATH", .value = "/m/lib" }};
    const spec = Spec{
        .name = "v",
        .venv = "/v",
        .modules = &.{"gcc"},
        .module_cache_enabled = true,
        .module_cache = .{ .version = 1, .system = "jureca", .untrusted = false, .ops = &mod_ops },
        .activate_commands = &.{"echo hi"},
        .ops = try venvOps(a, "/v", "(v) "),
    };
    const text = try json.Stringify.valueAlloc(a, spec, .{});
    const parsed = try parseSpec(testing.allocator, text);
    defer parsed.deinit();
    try testing.expectEqualStrings("jureca", parsed.value.module_cache.?.system);
    try testing.expectEqual(OpKind.prepend, parsed.value.module_cache.?.ops[0].op);
    try testing.expectEqual(@as(usize, 6), parsed.value.ops.len);
    try testing.expectEqualStrings("", parsed.value.ops[2].value); // unset: default value
    try testing.expectEqualStrings("gcc", parsed.value.modules[0]);
    try testing.expect(parsed.value.hasActivateHooks());
    try testing.expect(parsed.value.activate_script == null);

    try testing.expectError(error.UnsupportedFormat, parseSpec(testing.allocator, "{\"format\":99,\"name\":\"v\",\"venv\":\"/v\",\"ops\":[]}"));
}

test "directReason gates on hooks, module cache validity and purge" {
    const cache_ok = ModuleCache{ .version = template.MODULE_CACHE_VERSION, .system = "jureca", .untrusted = false, .ops = &.{} };
    var spec = Spec{ .name = "v", .venv = "/v", .module_cache_enabled = true, .ops = &.{} };

    try testing.expect(directReason(&spec, "laptop", false) == null);
    try testing.expect(directReason(&spec, "laptop", true) != null); // purge needs a shell

    spec.activate_script = "/v/scripts/activate_hook.sh";
    try testing.expect(directReason(&spec, "laptop", false) != null);
    spec.activate_script = null;

    spec.modules = &.{ "gcc", "cuda" };
    try testing.expect(directReason(&spec, "jureca", true) != null); // no cache
    spec.module_cache = cache_ok;
    try testing.expect(directReason(&spec, "jureca", true) == null);
    try testing.expect(directReason(&spec, "juwels", true) != null); // other system
    try testing.expect(directReason(&spec, null, true) != null);

    var stale = cache_ok;
    stale.version += 1;
    spec.module_cache = stale;
    try testing.expect(directReason(&spec, "jureca", true) != null);

    var untrusted = cache_ok;
    untrusted.untrusted = true;
    spec.module_cache = untrusted;
    try testing.expect(directReason(&spec, "jureca", true) != null);
}

test "usableModuleCache requires modules, caching on, trusted current-format data" {
    const ok = ModuleCache{ .version = template.MODULE_CACHE_VERSION, .system = "s", .untrusted = false, .ops = &.{} };
    var spec = Spec{ .name = "v", .venv = "/v", .modules = &.{"gcc"}, .module_cache_enabled = true, .module_cache = ok, .ops = &.{} };
    try testing.expect(spec.usableModuleCache() != null);
    spec.module_cache_enabled = false;
    try testing.expect(spec.usableModuleCache() == null);
    spec.module_cache_enabled = true;
    spec.modules = &.{};
    try testing.expect(spec.usableModuleCache() == null);
    spec.modules = &.{"gcc"};
    var bad = ok;
    bad.untrusted = true;
    spec.module_cache = bad;
    try testing.expect(spec.usableModuleCache() == null);
}

test "apply: module ops first, prepend joins non-empty values, unset removes" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("PATH", "/usr/bin:/bin");
    try map.put("PYTHONHOME", "/should/go");
    try map.put("LD_LIBRARY_PATH", "");

    const mod_ops = [_]Op{
        .{ .op = .prepend, .name = "PATH", .value = "/m/bin" },
        .{ .op = .prepend, .name = "LD_LIBRARY_PATH", .value = "/m/lib" },
        .{ .op = .set, .name = "LOADEDMODULES", .value = "gcc/13" },
    };
    const venv_ops = [_]Op{
        .{ .op = .prepend, .name = "PATH", .value = "/v/bin" },
        .{ .op = .unset, .name = "PYTHONHOME" },
    };
    const spec = Spec{
        .name = "v",
        .venv = "/v",
        .modules = &.{"gcc"},
        .module_cache_enabled = true,
        .module_cache = .{ .version = 1, .system = "s", .untrusted = false, .ops = &mod_ops },
        .ops = &venv_ops,
    };
    try apply(&map, &spec);

    try testing.expectEqualStrings("/v/bin:/m/bin:/usr/bin:/bin", map.get("PATH").?);
    try testing.expectEqualStrings("/m/lib", map.get("LD_LIBRARY_PATH").?); // empty -> no trailing ':'
    try testing.expectEqualStrings("gcc/13", map.get("LOADEDMODULES").?);
    try testing.expect(map.get("PYTHONHOME") == null);
}

test "resolveCommand searches PATH and passes paths through" {
    test_support.setupRuntime();
    const a = testing.allocator;

    const sh = (try resolveCommand(a, "sh", "/nonexistent:/bin")).?;
    defer a.free(sh);
    try testing.expectEqualStrings("/bin/sh", sh);

    const given = (try resolveCommand(a, "./local/tool", "/bin")).?;
    defer a.free(given);
    try testing.expectEqualStrings("./local/tool", given);

    try testing.expect((try resolveCommand(a, "zenv-no-such-command", "/bin")) == null);
    try testing.expect((try resolveCommand(a, "sh", null)) == null);
    // A directory on PATH named like the command is skipped.
    try testing.expect((try resolveCommand(a, "bin", "/")) == null);
}
