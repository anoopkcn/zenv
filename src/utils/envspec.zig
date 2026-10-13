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
const host = @import("host.zig");
const EnvironmentConfig = @import("config.zig").EnvironmentConfig;

pub const FILE_NAME = "zenv-env.json";

/// Bump when the JSON layout changes; a mismatching file is ignored (callers
/// fall back to activate.sh until the next `zenv setup` rewrites it).
pub const FORMAT_VERSION: u32 = 1;

pub const OpKind = enum { set, prepend, append, unset };

/// One environment change. `prepend` follows the activate.sh rule
/// `NAME=value"${NAME:+:$NAME}"`: the value goes in front of a non-empty
/// current value, or replaces an empty/unset one; `append` is the mirror
/// image. `unset` ignores `value`.
pub const Op = struct {
    op: OpKind,
    name: []const u8,
    value: []const u8 = "",
};

/// The module-environment cache in the venv: what `module load` changed during
/// setup (see envbuild.zig), replayed by activation and `zenv run` instead of
/// running Lmod again.
pub const MODULE_CACHE_FILE = ".zenv_module_cache.json";

/// Bump when capture or replay semantics change; a cache with another version
/// is never replayed (activation falls back to `module load`). 2: captured
/// from `env -0` snapshots by zenv itself, stored as JSON.
pub const MODULE_CACHE_VERSION: u32 = 2;

/// Contents of MODULE_CACHE_FILE. `system` is the cluster it was captured on
/// (`${SYSTEMNAME:-$(hostname)}`); `modules_sig` identifies the module list so
/// setup can reuse the cache when only dependencies changed.
pub const ModuleCache = struct {
    version: u32,
    system: []const u8,
    untrusted: bool,
    modules_sig: []const u8 = "",
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
        if (cache.version != MODULE_CACHE_VERSION or cache.untrusted) return null;
        return cache;
    }
};

/// The venv part of activation: what a venv's `bin/activate` exports, plus
/// zenv's additions. `prompt` becomes VIRTUAL_ENV_PROMPT; zenv uses the bare
/// env name, as CPython 3.13+ and uv do. PS1 and `deactivate` are shell
/// concerns, handled by activation.zig. All slices are allocated with
/// `allocator` (use an arena).
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

/// Activation for an env with `"python": false`: its bin/ on PATH and
/// ZENV_ENV_DIR, without the venv variables. VIRTUAL_ENV would make uv and pip
/// target a directory that has no Python in it.
pub fn plainOps(allocator: Allocator, venv_path: []const u8) ![]const Op {
    const bin = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, "bin" });
    var ops: std.ArrayList(Op) = .empty;
    try ops.append(allocator, .{ .op = .prepend, .name = "PATH", .value = bin });
    try ops.append(allocator, .{ .op = .set, .name = "ZENV_ENV_DIR", .value = venv_path });
    return ops.toOwnedSlice(allocator);
}

/// `value` with `${ZENV_ENV_DIR}` and `${ZENV_PROJECT_DIR}` replaced by the
/// env and project directories. Anything else, `$HOME` included, stays
/// literal, so the value is the same in every shell and in `zenv run`.
pub fn expandValue(allocator: Allocator, value: []const u8, venv_path: []const u8, project_dir: []const u8) ![]const u8 {
    const env_dir_ref = try std.mem.replaceOwned(u8, allocator, value, "${ZENV_ENV_DIR}", venv_path);
    return std.mem.replaceOwned(u8, allocator, env_dir_ref, "${ZENV_PROJECT_DIR}", project_dir);
}

/// The `env` entries of zenv.json as ops, expanded, in file order. Applied
/// after the venv ops, so they may extend PATH in front of the env's bin/.
pub fn userOps(allocator: Allocator, env_config: *const EnvironmentConfig, venv_path: []const u8, project_dir: []const u8) ![]const Op {
    var ops: std.ArrayList(Op) = .empty;
    for (env_config.env.items) |v| try ops.append(allocator, .{
        .op = switch (v.kind) {
            .set => .set,
            .prepend => .prepend,
            .append => .append,
        },
        .name = v.name,
        .value = try expandValue(allocator, v.value, venv_path, project_dir),
    });
    return ops.toOwnedSlice(allocator);
}

/// Reads `<venv_path>/.zenv_module_cache.json`. Null when missing or
/// malformed. Results are allocated with `allocator` (use an arena).
pub fn readModuleCache(allocator: Allocator, venv_path: []const u8) ?ModuleCache {
    const path = std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, MODULE_CACHE_FILE }) catch return null;
    const text = runtime.readFileAlloc(allocator, path, 16 * 1024 * 1024) catch return null;
    return json.parseFromSliceLeaky(ModuleCache, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// Writes the module cache atomically and removes the pre-JSON cache files.
pub fn writeModuleCache(allocator: Allocator, venv_path: []const u8, cache: *const ModuleCache) !void {
    const text = try json.Stringify.valueAlloc(allocator, cache.*, .{ .whitespace = .indent_2 });
    defer allocator.free(text);
    const path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, MODULE_CACHE_FILE });
    defer allocator.free(path);
    try runtime.writeFileAtomic(allocator, path, text);
}

/// Removes the module cache; a missing file is fine.
pub fn deleteModuleCache(allocator: Allocator, venv_path: []const u8) void {
    const path = std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, MODULE_CACHE_FILE }) catch return;
    defer allocator.free(path);
    runtime.deleteFile(path) catch {};
}

/// Lowercase-hex SHA-1 of the module list, in load order: the key under which
/// setup may reuse a cache instead of re-running Lmod. Caller owns the result.
pub fn modulesSignature(allocator: Allocator, modules: []const []const u8) ![]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    for (modules) |m| {
        sha.update(m);
        sha.update("\x00");
    }
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

/// Whether `name` is a shell identifier, i.e. can be exported and rendered
/// unquoted into activation scripts.
pub fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = c == '_' or std.ascii.isAlphabetic(c) or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return true;
}

/// Builds the Spec for `env_config`. Call at the end of setup, after the setup
/// script has (re)written the module cache files and created the venv.
/// `activate_script` is the hook's path inside the venv (already copied), if
/// any. `project_dir` anchors `${ZENV_PROJECT_DIR}` in `env` values.
/// Everything is allocated with, or borrowed from, `allocator` and
/// `env_config` (use an arena).
pub fn build(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    venv_path: []const u8,
    project_dir: []const u8,
    activate_script: ?[]const u8,
) !Spec {
    const modules = env_config.modules.items;
    const venv_ops = if (env_config.python) try venvOps(allocator, venv_path, env_name) else try plainOps(allocator, venv_path);
    return .{
        .name = env_name,
        .venv = venv_path,
        .modules = modules,
        .module_cache_enabled = env_config.module_cache,
        .module_cache = if (modules.len > 0 and env_config.module_cache) readModuleCache(allocator, venv_path) else null,
        .ops = try std.mem.concat(allocator, Op, &.{ venv_ops, try userOps(allocator, env_config, venv_path, project_dir) }),
        .activate_commands = if (env_config.activate) |act| (if (act.commands) |c| c.items else &.{}) else &.{},
        .activate_script = activate_script,
    };
}

/// `value` moved from under `old_dir` to `new_dir` when it is that directory or
/// a path inside it; otherwise `value` itself.
fn movePath(a: Allocator, value: []const u8, old_dir: []const u8, new_dir: []const u8) ![]const u8 {
    if (std.mem.eql(u8, value, old_dir)) return new_dir;
    if (value.len > old_dir.len and std.mem.startsWith(u8, value, old_dir) and value[old_dir.len] == '/') {
        return std.mem.concat(a, u8, &.{ new_dir, value[old_dir.len..] });
    }
    return value;
}

/// `spec` for a venv moved from `old_venv` to `new_venv` and renamed to
/// `new_name` (zenv rename): paths into the venv move with it and the prompt
/// takes the new name. Allocated with `a` (use an arena).
pub fn relocate(a: Allocator, spec: *const Spec, old_venv: []const u8, new_venv: []const u8, new_name: []const u8) !Spec {
    var out = spec.*;
    out.name = new_name;
    out.venv = new_venv;
    const ops = try a.dupe(Op, spec.ops);
    for (ops) |*op| {
        op.value = if (std.mem.eql(u8, op.name, "VIRTUAL_ENV_PROMPT")) new_name else try movePath(a, op.value, old_venv, new_venv);
    }
    out.ops = ops;
    if (spec.activate_script) |p| out.activate_script = try movePath(a, p, old_venv, new_venv);
    return out;
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
/// the same rule the generated activate scripts check. Caller owns the result.
pub fn currentSystem(allocator: Allocator) ![]const u8 {
    if (runtime.env("SYSTEMNAME")) |s| {
        if (s.len > 0) return allocator.dupe(u8, s);
    }
    return host.getHostnameFromSyscall(allocator);
}

/// Returns why `spec` cannot be applied directly (so the caller must source
/// activate.sh), or null when the direct path may be used.
///
/// The direct path deliberately differs from activate.sh in two ways:
///   - an env without modules does not purge the caller's loaded modules
///     (activate.sh runs `module --force purge` when a module system exists);
///   - with modules declared and a valid cache, the cache is replayed even
///     when `module` is not initialised in the calling shell.
pub fn directReason(spec: *const Spec, current_system: ?[]const u8) ?[]const u8 {
    if (spec.hasActivateHooks()) return "activate hooks are configured";
    if (spec.modules.len > 0) {
        const cache = spec.module_cache orelse return "no module cache data";
        if (cache.version != MODULE_CACHE_VERSION) return "module cache version mismatch";
        if (cache.untrusted) return "module cache is marked untrusted";
        const sys = current_system orelse return "cannot determine the current system";
        if (!std.mem.eql(u8, sys, cache.system)) return "module cache was captured on another system";
    }
    return null;
}

pub fn applyOp(map: *std.process.Environ.Map, op: Op) !void {
    switch (op.op) {
        .set => try map.put(op.name, op.value),
        .unset => _ = map.orderedRemove(op.name),
        .prepend, .append => {
            const current = map.get(op.name) orelse "";
            if (current.len == 0) return map.put(op.name, op.value);
            const parts: []const []const u8 = if (op.op == .prepend) &.{ op.value, ":", current } else &.{ current, ":", op.value };
            const joined = try std.mem.concat(map.allocator, u8, parts);
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
/// in `path_value` (an empty entry means the current directory; an unset PATH
/// means `/usr/bin:/bin`, as execvp uses). Returns null when nothing matches.
/// Caller owns the result.
pub fn resolveCommand(allocator: Allocator, command: []const u8, path_value: ?[]const u8) !?[]u8 {
    if (command.len == 0) return null;
    if (std.mem.findScalar(u8, command, '/') != null) return try allocator.dupe(u8, command);

    var dirs = std.mem.splitScalar(u8, path_value orelse "/usr/bin:/bin", ':');
    while (dirs.next()) |entry| {
        const dir = if (entry.len == 0) "." else entry;
        const candidate = try std.Io.Dir.path.join(allocator, &[_][]const u8{ dir, command });
        if (isExecutableFile(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

pub fn isExecutableFile(path: []const u8) bool {
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

test "plainOps puts bin/ on PATH without the venv variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ops = try plainOps(arena.allocator(), "/p/.zenv/demo");
    try testing.expectEqual(@as(usize, 2), ops.len);
    try testing.expectEqual(OpKind.prepend, ops[0].op);
    try testing.expectEqualStrings("PATH", ops[0].name);
    try testing.expectEqualStrings("/p/.zenv/demo/bin", ops[0].value);
    try testing.expectEqualStrings("ZENV_ENV_DIR", ops[1].name);
    for (ops) |op| try testing.expect(!std.mem.startsWith(u8, op.name, "VIRTUAL_ENV") and !std.mem.startsWith(u8, op.name, "PYTHON"));
}

test "build picks plainOps for a Python-free env" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg = EnvironmentConfig.init(arena.allocator());
    cfg.python = false;
    const spec = try build(arena.allocator(), &cfg, "demo", "/p/.zenv/demo", "/p", null);
    try testing.expectEqual(@as(usize, 2), spec.ops.len);
    cfg.python = true;
    const with_python = try build(arena.allocator(), &cfg, "demo", "/p/.zenv/demo", "/p", null);
    try testing.expectEqualStrings("VIRTUAL_ENV", with_python.ops[0].name);
}

test "expandValue replaces only the two zenv directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try expandValue(arena.allocator(), "${ZENV_PROJECT_DIR}/data:${ZENV_ENV_DIR}/bin:$HOME/${OTHER}:${ZENV_ENV_DIR}", "/p/.zenv/demo", "/p");
    try testing.expectEqualStrings("/p/data:/p/.zenv/demo/bin:$HOME/${OTHER}:/p/.zenv/demo", out);
}

test "build appends env entries after the venv ops, expanded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = EnvironmentConfig.init(a);
    try cfg.env.append(a, .{ .name = "DATA", .value = "${ZENV_PROJECT_DIR}/data" });
    try cfg.env.append(a, .{ .name = "PATH", .value = "${ZENV_ENV_DIR}/tools", .kind = .prepend });
    const spec = try build(a, &cfg, "demo", "/p/.zenv/demo", "/p", null);
    const n = spec.ops.len;
    try testing.expectEqualStrings("VIRTUAL_ENV", spec.ops[0].name);
    try testing.expectEqualStrings("DATA", spec.ops[n - 2].name);
    try testing.expectEqual(OpKind.set, spec.ops[n - 2].op);
    try testing.expectEqualStrings("/p/data", spec.ops[n - 2].value);
    try testing.expectEqual(OpKind.prepend, spec.ops[n - 1].op);
    try testing.expectEqualStrings("/p/.zenv/demo/tools", spec.ops[n - 1].value);
    // Activation needs no shell for them: `zenv run` keeps the direct launch.
    try testing.expect(directReason(&spec, null) == null);
}

test "relocate moves venv paths and the name, nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = Spec{ .name = "old", .venv = "/p/.zenv/old", .ops = try venvOps(a, "/p/.zenv/old", "old"), .activate_script = "/p/.zenv/old/scripts/activate_hook.sh" };
    spec.ops = try std.mem.concat(a, Op, &.{ spec.ops, &.{.{ .op = .set, .name = "OTHER", .value = "/p/.zenv/older" }} });
    const moved = try relocate(a, &spec, "/p/.zenv/old", "/p/.zenv/new", "new");
    try testing.expectEqualStrings("new", moved.name);
    try testing.expectEqualStrings("/p/.zenv/new", moved.venv);
    try testing.expectEqualStrings("/p/.zenv/new", moved.ops[0].value); // VIRTUAL_ENV
    try testing.expectEqualStrings("/p/.zenv/new/bin", moved.ops[1].value); // PATH
    try testing.expectEqualStrings("new", moved.ops[3].value); // VIRTUAL_ENV_PROMPT
    try testing.expectEqualStrings("/p/.zenv/older", moved.ops[6].value); // a sibling path is not "inside"
    try testing.expectEqualStrings("/p/.zenv/new/scripts/activate_hook.sh", moved.activate_script.?);
    try testing.expectEqualStrings("/p/.zenv/old", spec.ops[0].value); // the input is untouched
}

test "modulesSignature is deterministic, order- and content-sensitive" {
    const a = testing.allocator;
    const ab = [_][]const u8{ "gcc", "cuda" };
    const ab2 = [_][]const u8{ "gcc", "cuda" };
    const ba = [_][]const u8{ "cuda", "gcc" };
    const abc = [_][]const u8{ "gcc", "cuda", "mpi" };

    const h_ab = try modulesSignature(a, &ab);
    defer a.free(h_ab);
    const h_ab2 = try modulesSignature(a, &ab2);
    defer a.free(h_ab2);
    const h_ba = try modulesSignature(a, &ba);
    defer a.free(h_ba);
    const h_abc = try modulesSignature(a, &abc);
    defer a.free(h_abc);

    try testing.expectEqual(@as(usize, 40), h_ab.len);
    try testing.expectEqualStrings(h_ab, h_ab2); // deterministic
    try testing.expect(!std.mem.eql(u8, h_ab, h_ba)); // load order matters
    try testing.expect(!std.mem.eql(u8, h_ab, h_abc)); // adding a module changes it
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

test "directReason gates on hooks and module cache validity, never on purge" {
    const cache_ok = ModuleCache{ .version = MODULE_CACHE_VERSION, .system = "jureca", .untrusted = false, .ops = &.{} };
    var spec = Spec{ .name = "v", .venv = "/v", .module_cache_enabled = true, .ops = &.{} };

    // No modules: direct, even on a machine with Lmod (no purge on this path).
    try testing.expect(directReason(&spec, "laptop") == null);

    spec.activate_script = "/v/scripts/activate_hook.sh";
    try testing.expect(directReason(&spec, "laptop") != null);
    spec.activate_script = null;

    spec.modules = &.{ "gcc", "cuda" };
    try testing.expect(directReason(&spec, "jureca") != null); // no cache
    spec.module_cache = cache_ok;
    try testing.expect(directReason(&spec, "jureca") == null);
    try testing.expect(directReason(&spec, "juwels") != null); // other system
    try testing.expect(directReason(&spec, null) != null);

    var stale = cache_ok;
    stale.version += 1;
    spec.module_cache = stale;
    try testing.expect(directReason(&spec, "jureca") != null);

    var untrusted = cache_ok;
    untrusted.untrusted = true;
    spec.module_cache = untrusted;
    try testing.expect(directReason(&spec, "jureca") != null);
}

test "usableModuleCache requires modules, caching on, trusted current-format data" {
    const ok = ModuleCache{ .version = MODULE_CACHE_VERSION, .system = "s", .untrusted = false, .ops = &.{} };
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
    const default_path = (try resolveCommand(a, "sh", null)).?; // unset PATH: /usr/bin:/bin
    defer a.free(default_path);
    try testing.expect(std.mem.endsWith(u8, default_path, "/sh"));
    // A directory on PATH named like the command is skipped.
    try testing.expect((try resolveCommand(a, "bin", "/")) == null);
}
