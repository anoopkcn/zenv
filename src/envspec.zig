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
const Io = std.Io;
const json = std.json;
const runtime = @import("runtime.zig");
const host = @import("host.zig");
const config = @import("config.zig");
const container = @import("container.zig");

pub const file_name = "zenv-env.json";

/// Bump when the JSON layout changes; a mismatching file is ignored (callers
/// fall back to activate.sh until the next `zenv setup` rewrites it).
const format_version: u32 = 1;

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
pub const module_cache_file = ".zenv_module_cache.json";

/// Bump when capture or replay semantics change; a cache with another version
/// is never replayed (activation falls back to `module load`). 2: captured
/// from `env -0` snapshots by zenv itself, stored as JSON.
pub const module_cache_version: u32 = 2;

/// Contents of module_cache_file. `system` is the cluster it was captured on
/// (`${SYSTEMNAME:-$(hostname)}`); `modules_sig` identifies the module list so
/// an auto-setup rebuild can reuse the cache when only dependencies changed.
pub const ModuleCache = struct {
    version: u32,
    system: []const u8,
    untrusted: bool,
    modules_sig: []const u8 = "",
    ops: []const Op,

    /// Why this cache must never be replayed (another format, an untrusted
    /// capture), or null.
    pub fn defect(self: *const ModuleCache) ?[]const u8 {
        if (self.version != module_cache_version) return "module cache version mismatch";
        if (self.untrusted) return "module cache is marked untrusted";
        return null;
    }

    /// Why this cache must not be replayed on `system` (null: unknown, which
    /// is refused), or for the module list `modules_sig` (null: not checked),
    /// or null when it may be. Every replay decision goes through here or
    /// `defect`.
    pub fn unfitFor(
        self: *const ModuleCache,
        system: ?[]const u8,
        modules_sig: ?[]const u8,
    ) ?[]const u8 {
        if (self.defect()) |why| return why;
        const sys = system orelse return "cannot determine the current system";
        if (!std.mem.eql(u8, sys, self.system)) return "module cache was captured on another system";
        if (modules_sig) |sig| if (!std.mem.eql(u8, sig, self.modules_sig))
            return "module cache was captured for other modules";
        return null;
    }
};

pub const Spec = struct {
    format: u32 = format_version,
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
    /// The Apptainer image the env runs in; commands are started inside it.
    container: ?container.Image = null,

    pub fn hasActivateHooks(self: *const Spec) bool {
        return self.activate_commands.len > 0 or self.activate_script != null;
    }

    /// The captured module env when it may be replayed at all: declared
    /// modules, caching on, a trusted capture in the current format. Whether
    /// it fits the current system is decided at activation time.
    pub fn usableModuleCache(self: *const Spec) ?ModuleCache {
        if (self.modules.len == 0 or !self.module_cache_enabled) return null;
        const cache = self.module_cache orelse return null;
        if (cache.defect() != null) return null;
        return cache;
    }
};

/// The venv part of activation: what a venv's `bin/activate` exports, plus
/// zenv's additions. `prompt` becomes VIRTUAL_ENV_PROMPT; zenv uses the bare
/// env name, as CPython 3.13+ and uv do. PS1 and `deactivate` are shell
/// concerns, handled by activation.zig. All slices are allocated with
/// `allocator` (use an arena).
pub fn venvOps(allocator: Allocator, venv_path: []const u8, prompt: ?[]const u8) ![]const Op {
    const bin = try std.Io.Dir.path.join(allocator, &.{ venv_path, "bin" });
    var ops: std.ArrayList(Op) = .empty;
    try ops.append(allocator, .{ .op = .set, .name = "VIRTUAL_ENV", .value = venv_path });
    try ops.append(allocator, .{ .op = .prepend, .name = "PATH", .value = bin });
    try ops.append(allocator, .{ .op = .unset, .name = "PYTHONHOME" });
    if (prompt) |p| try ops.append(
        allocator,
        .{ .op = .set, .name = "VIRTUAL_ENV_PROMPT", .value = p },
    );
    try ops.append(allocator, .{ .op = .set, .name = "PYTHONDONTWRITEBYTECODE", .value = "1" });
    try ops.append(allocator, .{ .op = .set, .name = "ZENV_ENV_DIR", .value = venv_path });
    return ops.toOwnedSlice(allocator);
}

/// Activation for an env with `"python": false`: its bin/ on PATH and
/// ZENV_ENV_DIR, without the venv variables. VIRTUAL_ENV would make uv and pip
/// target a directory that has no Python in it.
pub fn plainOps(allocator: Allocator, venv_path: []const u8) ![]const Op {
    return allocator.dupe(Op, &.{
        .{
            .op = .prepend,
            .name = "PATH",
            .value = try std.Io.Dir.path.join(allocator, &.{ venv_path, "bin" }),
        },
        .{ .op = .set, .name = "ZENV_ENV_DIR", .value = venv_path },
    });
}

/// `value` with `${ZENV_ENV_DIR}` and `${ZENV_PROJECT_DIR}` replaced by the
/// env and project directories. Anything else, `$HOME` included, stays
/// literal, so the value is the same in every shell and in `zenv run`.
fn expandValue(
    allocator: Allocator,
    value: []const u8,
    venv_path: []const u8,
    project_dir: []const u8,
) ![]const u8 {
    const env_dir_ref = try std.mem.replaceOwned(
        u8,
        allocator,
        value,
        "${ZENV_ENV_DIR}",
        venv_path,
    );
    return std.mem.replaceOwned(u8, allocator, env_dir_ref, "${ZENV_PROJECT_DIR}", project_dir);
}

/// The `env` entries of zenv.json as ops, expanded, in file order. Applied
/// after the venv ops, so they may extend PATH in front of the env's bin/.
pub fn userOps(
    allocator: Allocator,
    env_config: *const config.Env,
    venv_path: []const u8,
    project_dir: []const u8,
) ![]const Op {
    const ops = try allocator.alloc(Op, env_config.env.items.len);
    for (ops, env_config.env.items) |*op, v| op.* = .{
        .op = switch (v.kind) {
            inline else => |k| @field(OpKind, @tagName(k)),
        },
        .name = v.name,
        .value = try expandValue(allocator, v.value, venv_path, project_dir),
    };
    return ops;
}

/// Reads `<venv_path>/.zenv_module_cache.json`. Null when missing, malformed,
/// or naming a variable that is not a shell identifier (see `parse`).
/// Results are allocated with `allocator` (use an arena).
pub fn readModuleCache(allocator: Allocator, io: Io, venv_path: []const u8) ?ModuleCache {
    const path = std.Io.Dir.path.join(
        allocator,
        &.{ venv_path, module_cache_file },
    ) catch return null;
    const text = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch return null;
    const cache = json.parseFromSliceLeaky(ModuleCache, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    for (cache.ops) |op| if (!isIdentifier(op.name)) return null;
    return cache;
}

/// The module cache of `venv_path` when it was captured for `modules`. A
/// setup that could not re-capture (no module system found, a failed write)
/// leaves the cache of an earlier module list behind; replaying that would
/// load the wrong modules.
fn cacheFor(
    allocator: Allocator,
    io: Io,
    venv_path: []const u8,
    modules: []const []const u8,
) !?ModuleCache {
    const cache = readModuleCache(allocator, io, venv_path) orelse return null;
    if (!std.mem.eql(u8, cache.modules_sig, try modulesSignature(allocator, modules))) return null;
    return cache;
}

/// Writes the module cache atomically.
pub fn writeModuleCache(
    allocator: Allocator,
    io: Io,
    venv_path: []const u8,
    cache: *const ModuleCache,
) !void {
    const path = try std.Io.Dir.path.join(allocator, &.{ venv_path, module_cache_file });
    defer allocator.free(path);
    try runtime.writeJsonAtomic(io, path, cache.*, false);
}

/// Removes the module cache; a missing file is fine.
pub fn deleteModuleCache(allocator: Allocator, io: Io, venv_path: []const u8) void {
    const path = std.Io.Dir.path.join(allocator, &.{ venv_path, module_cache_file }) catch return;
    defer allocator.free(path);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Lowercase-hex SHA-1 of the module list, in load order: the key under which
/// auto-setup may reuse a cache instead of re-running Lmod. Caller owns the result.
pub fn modulesSignature(allocator: Allocator, modules: []const []const u8) ![]u8 {
    var sha: std.crypto.hash.Sha1 = .init(.{});
    for (modules) |m| {
        sha.update(m);
        sha.update("\x00");
    }
    return allocator.dupe(u8, &std.fmt.bytesToHex(sha.finalResult(), .lower));
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

/// Builds the Spec for `env_config`. Call at the end of setup, after the venv
/// was built and the module cache (re)written.
/// `activate_script` is the hook's path inside the venv (already copied), if
/// any. `project_dir` anchors `${ZENV_PROJECT_DIR}` in `env` values.
/// Everything is allocated with, or borrowed from, `allocator` and
/// `env_config` (use an arena).
pub fn build(
    allocator: Allocator,
    io: Io,
    env_config: *const config.Env,
    env_name: []const u8,
    venv_path: []const u8,
    project_dir: []const u8,
    activate_script: ?[]const u8,
) !Spec {
    const modules = env_config.modules.items;
    const venv_ops = if (env_config.python) try venvOps(
        allocator,
        venv_path,
        env_name,
    ) else try plainOps(allocator, venv_path);
    return .{
        .name = env_name,
        .venv = venv_path,
        .modules = modules,
        .module_cache_enabled = env_config.module_cache,
        .module_cache = if (modules.len > 0 and env_config.module_cache) try cacheFor(
            allocator,
            io,
            venv_path,
            modules,
        ) else null,
        .ops = try std.mem.concat(
            allocator,
            Op,
            &.{ venv_ops, try userOps(allocator, env_config, venv_path, project_dir) },
        ),
        .activate_commands = env_config.activate.commands.items,
        .activate_script = activate_script,
        .container = if (env_config.container) |*ct| try container.fromConfig(
            allocator,
            ct,
            project_dir,
        ) else null,
    };
}

/// `value` with every whole path that is `old_dir` or inside it moved to
/// `new_dir`, wherever it stands (`/opt/x:<old>/lib`, `--prefix=<old>`);
/// `value` itself when there is none.
fn movePath(a: Allocator, value: []const u8, old_dir: []const u8, new_dir: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var from: usize = 0;
    var i: usize = 0;
    while (std.mem.findPos(u8, value, i, old_dir)) |at| {
        const end = at + old_dir.len;
        i = at + 1;
        // Whole paths only: `/p/.zenv/older` and `/x/p/.zenv/old` stay.
        const starts_ok = at == 0 or std.mem.findScalar(u8, ":= ,;\"'", value[at - 1]) != null;
        const ends_ok = end == value.len or value[end] == '/' or value[end] == ':';
        if (!starts_ok or !ends_ok) continue;
        try out.appendSlice(a, value[from..at]);
        try out.appendSlice(a, new_dir);
        from = end;
        i = end;
    }
    if (from == 0) return value;
    try out.appendSlice(a, value[from..]);
    return out.items;
}

/// `spec` for a venv moved from `old_venv` to `new_venv` and renamed to
/// `new_name` (zenv rename): paths into the venv move with it and the prompt
/// takes the new name. Allocated with `a` (use an arena).
pub fn relocate(
    a: Allocator,
    spec: *const Spec,
    old_venv: []const u8,
    new_venv: []const u8,
    new_name: []const u8,
) !Spec {
    var out = spec.*;
    out.name = new_name;
    out.venv = new_venv;
    const ops = try a.dupe(Op, spec.ops);
    for (ops) |*op| {
        op.value = if (std.mem.eql(
            u8,
            op.name,
            "VIRTUAL_ENV_PROMPT",
        )) new_name else try movePath(a, op.value, old_venv, new_venv);
    }
    out.ops = ops;
    if (spec.activate_script) |p| out.activate_script = try movePath(a, p, old_venv, new_venv);
    return out;
}

/// Writes `spec` to `<spec.venv>/zenv-env.json` atomically.
pub fn write(allocator: Allocator, io: Io, spec: *const Spec) !void {
    const path = try std.Io.Dir.path.join(allocator, &.{ spec.venv, file_name });
    defer allocator.free(path);
    try runtime.writeJsonAtomic(io, path, spec.*, false);
}

/// Parses a spec. Errors on malformed JSON, a different format version, or a
/// variable name that is not a shell identifier (`apply` relies on that).
/// Caller must `deinit` the result.
pub fn parse(allocator: Allocator, text: []const u8) !json.Parsed(Spec) {
    const parsed = try json.parseFromSlice(Spec, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    if (parsed.value.format != format_version) return error.UnsupportedFormat;
    const cache_ops = if (parsed.value.module_cache) |c| c.ops else &.{};
    for ([_][]const Op{ parsed.value.ops, cache_ops }) |ops| {
        for (ops) |op| if (!isIdentifier(op.name)) return error.InvalidVariableName;
    }
    return parsed;
}

/// Reads `<venv_path>/zenv-env.json`. Null when absent, unreadable, malformed
/// or from another format version. Caller must `deinit` the result.
pub fn read(allocator: Allocator, io: Io, venv_path: []const u8) ?json.Parsed(Spec) {
    const path = std.Io.Dir.path.join(allocator, &.{ venv_path, file_name }) catch return null;
    defer allocator.free(path);
    const text = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch return null;
    defer allocator.free(text);
    return parse(allocator, text) catch null;
}

/// The cluster identity the module cache is keyed on: `${SYSTEMNAME:-$(hostname)}`,
/// the same rule the generated activate scripts check. Caller owns the result.
pub fn currentSystem(
    allocator: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    if (env.get("SYSTEMNAME")) |s| {
        if (s.len > 0) return allocator.dupe(u8, s);
    }
    return host.fromSyscall(allocator, io);
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
        if (cache.unfitFor(current_system, null)) |why| return why;
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
            const parts: []const []const u8 = if (op.op == .prepend) &.{
                op.value,
                ":",
                current,
            } else &.{
                current,
                ":",
                op.value,
            };
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
///
/// std has no equivalent: `std.process.spawn` resolves `argv[0]` against the
/// PATH of the parent process only, never against the child's environment.
pub fn resolveCommand(
    allocator: Allocator,
    io: Io,
    command: []const u8,
    path_value: ?[]const u8,
) !?[]u8 {
    if (command.len == 0) return null;
    if (std.mem.findScalar(u8, command, '/') != null) return try allocator.dupe(u8, command);

    var dirs = std.mem.splitScalar(
        u8,
        path_value orelse "/usr/bin:/bin",
        std.Io.Dir.path.delimiter,
    );
    while (dirs.next()) |entry| {
        const dir = if (entry.len == 0) "." else entry;
        const candidate = try std.Io.Dir.path.join(allocator, &.{ dir, command });
        if (isExecutableFile(io, candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

pub fn isExecutableFile(io: Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch return false;
    if (st.kind != .file) return false;
    cwd.access(io, path, .{ .execute = true }) catch return false;
    return true;
}

// ============================ Tests ============================
const testing = std.testing;

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
    for (ops) |op| try testing.expect(
        !std.mem.startsWith(
            u8,
            op.name,
            "VIRTUAL_ENV",
        ) and !std.mem.startsWith(u8, op.name, "PYTHON"),
    );
}

test "build picks plainOps for a Python-free env" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cfg = config.Env.init(arena.allocator());
    cfg.python = false;
    const spec = try build(
        arena.allocator(),
        testing.io,
        &cfg,
        "demo",
        "/p/.zenv/demo",
        "/p",
        null,
    );
    try testing.expectEqual(@as(usize, 2), spec.ops.len);
    cfg.python = true;
    const with_python = try build(
        arena.allocator(),
        testing.io,
        &cfg,
        "demo",
        "/p/.zenv/demo",
        "/p",
        null,
    );
    try testing.expectEqualStrings("VIRTUAL_ENV", with_python.ops[0].name);
}

test "build drops a module cache captured for another module list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const venv = ".zig-cache/tmp/zenv-stale-module-cache";
    Io.Dir.cwd().deleteTree(io, venv) catch {};
    defer Io.Dir.cwd().deleteTree(io, venv) catch {};
    try Io.Dir.cwd().createDirPath(io, venv);
    const cache: ModuleCache = .{
        .version = module_cache_version,
        .system = "s",
        .untrusted = false,
        .modules_sig = try modulesSignature(a, &.{"GCC"}),
        .ops = &.{},
    };
    try writeModuleCache(a, io, venv, &cache);

    var cfg = config.Env.init(a);
    try cfg.modules.append(a, "GCC");
    try testing.expect((try build(a, io, &cfg, "demo", venv, "/p", null)).module_cache != null);
    cfg.modules.items[0] = "Clang";
    try testing.expect((try build(a, io, &cfg, "demo", venv, "/p", null)).module_cache == null);
}

test "expandValue replaces only the two zenv directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try expandValue(
        arena.allocator(),
        "${ZENV_PROJECT_DIR}/data:${ZENV_ENV_DIR}/bin:$HOME/${OTHER}:${ZENV_ENV_DIR}",
        "/p/.zenv/demo",
        "/p",
    );
    try testing.expectEqualStrings("/p/data:/p/.zenv/demo/bin:$HOME/${OTHER}:/p/.zenv/demo", out);
}

test "build appends env entries after the venv ops, expanded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = config.Env.init(a);
    try cfg.env.append(a, .{ .name = "DATA", .value = "${ZENV_PROJECT_DIR}/data" });
    try cfg.env.append(a, .{ .name = "PATH", .value = "${ZENV_ENV_DIR}/tools", .kind = .prepend });
    const spec = try build(a, testing.io, &cfg, "demo", "/p/.zenv/demo", "/p", null);
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
    var spec = Spec{ .name = "old", .venv = "/p/.zenv/old", .ops = try venvOps(
        a,
        "/p/.zenv/old",
        "old",
    ), .activate_script = "/p/.zenv/old/scripts/activate_hook.sh" };
    spec.ops = try std.mem.concat(
        a,
        Op,
        &.{ spec.ops, &.{
            .{ .op = .set, .name = "OTHER", .value = "/p/.zenv/older" },
            .{ .op = .prepend, .name = "LIBS", .value = "/opt/x:/p/.zenv/old/lib:/q/p/.zenv/old" },
            .{ .op = .set, .name = "CFG", .value = "--prefix=/p/.zenv/old" },
        } },
    );
    const moved = try relocate(a, &spec, "/p/.zenv/old", "/p/.zenv/new", "new");
    try testing.expectEqualStrings("new", moved.name);
    try testing.expectEqualStrings("/p/.zenv/new", moved.venv);
    try testing.expectEqualStrings("/p/.zenv/new", moved.ops[0].value); // VIRTUAL_ENV
    try testing.expectEqualStrings("/p/.zenv/new/bin", moved.ops[1].value); // PATH
    try testing.expectEqualStrings("new", moved.ops[3].value); // VIRTUAL_ENV_PROMPT
    try testing.expectEqualStrings(
        "/p/.zenv/older",
        moved.ops[6].value,
    ); // a sibling path is not "inside"
    try testing.expectEqualStrings("/opt/x:/p/.zenv/new/lib:/q/p/.zenv/old", moved.ops[7].value);
    try testing.expectEqualStrings("--prefix=/p/.zenv/new", moved.ops[8].value);
    try testing.expectEqualStrings(
        "/p/.zenv/new/scripts/activate_hook.sh",
        moved.activate_script.?,
    );
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
    const parsed = try parse(testing.allocator, text);
    defer parsed.deinit();
    try testing.expectEqualStrings("jureca", parsed.value.module_cache.?.system);
    try testing.expectEqual(OpKind.prepend, parsed.value.module_cache.?.ops[0].op);
    try testing.expectEqual(@as(usize, 6), parsed.value.ops.len);
    try testing.expectEqualStrings("", parsed.value.ops[2].value); // unset: default value
    try testing.expectEqualStrings("gcc", parsed.value.modules[0]);
    try testing.expect(parsed.value.hasActivateHooks());
    try testing.expect(parsed.value.activate_script == null);

    try testing.expectError(
        error.UnsupportedFormat,
        parse(testing.allocator, "{\"format\":99,\"name\":\"v\",\"venv\":\"/v\",\"ops\":[]}"),
    );
    // Names `apply` could not put into an environment map are refused.
    try testing.expectError(
        error.InvalidVariableName,
        parse(
            testing.allocator,
            "{\"format\":1,\"name\":\"v\",\"venv\":\"/v\",\"ops\":[{\"op\":\"set\",\"name\":\"A=B\"}]}",
        ),
    );
    try testing.expectError(
        error.InvalidVariableName,
        parse(
            testing.allocator,
            "{\"format\":1,\"name\":\"v\",\"venv\":\"/v\",\"ops\":[],\"module_cache\":{\"version\":2,\"system\":\"s\",\"untrusted\":false,\"ops\":[{\"op\":\"set\",\"name\":\"\"}]}}",
        ),
    );
}

test "directReason gates on hooks and module cache validity, never on purge" {
    const cache_ok = ModuleCache{
        .version = module_cache_version,
        .system = "jureca",
        .untrusted = false,
        .ops = &.{},
    };
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
    const ok = ModuleCache{
        .version = module_cache_version,
        .system = "s",
        .untrusted = false,
        .ops = &.{},
    };
    var spec = Spec{ .name = "v", .venv = "/v", .modules = &.{
        "gcc",
    }, .module_cache_enabled = true, .module_cache = ok, .ops = &.{} };
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
    try testing.expectEqualStrings(
        "/m/lib",
        map.get("LD_LIBRARY_PATH").?,
    ); // empty -> no trailing ':'
    try testing.expectEqualStrings("gcc/13", map.get("LOADEDMODULES").?);
    try testing.expect(map.get("PYTHONHOME") == null);
}

test "resolveCommand searches PATH and passes paths through" {
    const a = testing.allocator;
    const io = testing.io;

    const sh = (try resolveCommand(a, io, "sh", "/nonexistent:/bin")).?;
    defer a.free(sh);
    try testing.expectEqualStrings("/bin/sh", sh);

    const given = (try resolveCommand(a, io, "./local/tool", "/bin")).?;
    defer a.free(given);
    try testing.expectEqualStrings("./local/tool", given);

    try testing.expect((try resolveCommand(a, io, "zenv-no-such-command", "/bin")) == null);
    const default_path = (try resolveCommand(a, io, "sh", null)).?; // unset PATH: /usr/bin:/bin
    defer a.free(default_path);
    try testing.expect(std.mem.endsWith(u8, default_path, "/sh"));
    // A directory on PATH named like the command is skipped.
    try testing.expect((try resolveCommand(a, io, "bin", "/")) == null);
}

test "ModuleCache.unfitFor checks format, trust, system and module list" {
    const ok = ModuleCache{
        .version = module_cache_version,
        .system = "jureca",
        .untrusted = false,
        .modules_sig = "sig",
        .ops = &.{},
    };
    try testing.expect(ok.defect() == null);
    try testing.expect(ok.unfitFor("jureca", "sig") == null);
    try testing.expect(ok.unfitFor("jureca", null) == null);
    try testing.expect(ok.unfitFor(null, "sig") != null);
    try testing.expect(ok.unfitFor("juwels", "sig") != null);
    try testing.expect(ok.unfitFor("jureca", "other") != null);

    var bad = ok;
    bad.untrusted = true;
    try testing.expectEqualStrings("module cache is marked untrusted", bad.unfitFor("jureca", "sig").?);
    bad = ok;
    bad.version = 1;
    try testing.expectEqualStrings("module cache version mismatch", bad.defect().?);
}
