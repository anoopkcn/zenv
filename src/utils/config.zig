const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const json = std.json;
const paths = @import("paths.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const host = @import("host.zig");

/// An environment's id: SHA-1 of (name, project dir, targets), NUL-separated so
/// field boundaries cannot shift. Env names are unique in the registry, so ids
/// are too, and they are reproducible: re-registering the same env gives the
/// same id, so a remembered id prefix keeps working.
fn generateSHA1ID(
    allocator: Allocator,
    env_name: []const u8,
    project_dir: []const u8,
    target_machines_str: []const u8,
) ![]const u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    for ([_][]const u8{ env_name, project_dir, target_machines_str }) |part| {
        sha1.update(part);
        sha1.update("\x00");
    }

    var hash: [20]u8 = undefined;
    sha1.final(&hash);

    // Efficient hex conversion (no intermediate format pass)
    const hex = std.fmt.bytesToHex(hash, .lower);
    return allocator.dupe(u8, &hex);
}

// =======================
// Config Structs
// =======================

pub const ScriptConfig = struct {
    commands: ?ArrayList([]const u8) = null,
    script: ?[]const u8 = null,

    pub fn deinit(self: *ScriptConfig, allocator: Allocator) void {
        if (self.commands) |*cmds| {
            for (cmds.items) |item| allocator.free(item);
            cmds.deinit(allocator);
        }
        if (self.script) |script_path| allocator.free(script_path);
    }
};

/// One entry of an env's `env` object in zenv.json: set NAME to `value`, or
/// add `value` to the front or back of a PATH-like NAME. `value` is as
/// written, before `${ZENV_ENV_DIR}` / `${ZENV_PROJECT_DIR}` expansion.
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
    kind: Kind = .set,

    pub const Kind = enum { set, prepend, append };
};

pub const EnvironmentConfig = struct {
    /// Every owned string and list in this config is allocated with `allocator`.
    allocator: Allocator,
    target_machines: ArrayList([]const u8) = .empty,
    description: ?[]const u8 = null,
    modules: ArrayList([]const u8) = .empty,
    modules_file: ?[]const u8 = null,
    dependency_file: ?[]const u8 = null,
    dependencies: ArrayList([]const u8) = .empty,
    // Development-only dependencies recorded in zenv.json. Installed alongside
    // `dependencies` during setup, but kept separate so `zenv add --dev` can
    // track them apart from runtime deps (and from any dependency_file).
    dev_dependencies: ArrayList([]const u8) = .empty,
    fallback_python: ?[]const u8 = null,
    setup: ?ScriptConfig = null,
    activate: ?ScriptConfig = null,
    // When true (default), setup snapshots the environment that `module load`
    // produces and activate replays it instead of re-running Lmod. Only has an
    // effect when `modules` is non-empty.
    module_cache: bool = true,
    // When false, the env has no Python venv: setup only loads modules, runs
    // the hooks and writes activation, for projects that use zenv just for
    // modules and settings. Dependencies are then a validation error.
    python: bool = true,
    // `env` from zenv.json, in file order: variables activation sets and
    // deactivate restores.
    env: ArrayList(EnvVar) = .empty,

    pub fn init(allocator: Allocator) EnvironmentConfig {
        return .{ .allocator = allocator };
    }

    fn freeList(allocator: Allocator, list: *ArrayList([]const u8)) void {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    pub fn deinit(self: *EnvironmentConfig) void {
        const allocator = self.allocator;
        freeList(allocator, &self.target_machines);
        freeList(allocator, &self.modules);
        freeList(allocator, &self.dependencies);
        freeList(allocator, &self.dev_dependencies);

        if (self.description) |desc| allocator.free(desc);
        if (self.modules_file) |mfile| allocator.free(mfile);
        if (self.dependency_file) |req| allocator.free(req);
        if (self.fallback_python) |py_exec| allocator.free(py_exec);

        if (self.setup) |*setup_config| setup_config.deinit(allocator);
        if (self.activate) |*activate_config| activate_config.deinit(allocator);

        for (self.env.items) |v| {
            allocator.free(v.name);
            allocator.free(v.value);
        }
        self.env.deinit(allocator);
    }
};

pub const ZenvConfig = struct {
    allocator: Allocator,
    environments: StringHashMap(EnvironmentConfig),
    base_dir: []const u8,

    pub fn deinit(self: *ZenvConfig) void {
        var iter = self.environments.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.environments.deinit();
        self.allocator.free(self.base_dir);
    }

    pub fn getEnvironment(self: *const ZenvConfig, env_name: []const u8) ?*const EnvironmentConfig {
        return self.environments.getPtr(env_name);
    }
};

// =======================
// RegistryEntry & Registry
// =======================

/// One registered environment; every string is owned. The empty defaults let a
/// partly built entry be deinit'd safely.
pub const RegistryEntry = struct {
    id: []const u8 = "", // SHA-1 unique identifier
    env_name: []const u8 = "",
    project_dir: []const u8 = "",
    description: ?[]const u8 = null,
    target_machines_str: []const u8 = "",
    venv_path: []const u8 = "",
    aliases: ArrayList([]const u8) = .empty,

    pub fn deinit(self: *RegistryEntry, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.env_name);
        allocator.free(self.project_dir);
        if (self.description) |desc| allocator.free(desc);
        allocator.free(self.target_machines_str);
        allocator.free(self.venv_path);
        for (self.aliases.items) |alias| {
            allocator.free(alias);
        }
        self.aliases.deinit(allocator);
    }
};

// Fields extracted from a pyvenv.cfg body. Slices point INTO the input.
const PyvenvFields = struct { version: ?[]const u8, path: ?[]const u8 };

// Pure parser for pyvenv.cfg contents. `version` is the `version =` value.
// `path` is the best-available interpreter path across Python versions:
// `executable =` (3.11+) -> first token of `command =` (3.x, incl. zenv's
// default 3.10) -> `home =` (the bin dir). Returns nulls when absent.
fn parsePyvenvCfg(content: []const u8) PyvenvFields {
    var version: ?[]const u8 = null;
    var executable: ?[]const u8 = null;
    var home: ?[]const u8 = null;
    var command: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "version")) {
            version = val;
        } else if (std.mem.eql(u8, key, "executable")) {
            executable = val;
        } else if (std.mem.eql(u8, key, "home")) {
            home = val;
        } else if (std.mem.eql(u8, key, "command")) {
            command = val;
        }
    }

    var path: ?[]const u8 = executable;
    if (path == null) {
        if (command) |cmd| {
            const first = std.mem.sliceTo(cmd, ' ');
            if (first.len > 0) path = first;
        }
    }
    if (path == null) path = home;

    return .{ .version = version, .path = path };
}

// Reads <venv_path>/pyvenv.cfg and returns the Python that built the venv: its
// interpreter path, or its version when no path is recorded. Returns null if
// the file is absent/unreadable (env not built) or has no `version`. Caller
// owns the result.
pub fn readVenvPython(allocator: Allocator, venv_path: []const u8) !?[]u8 {
    const cfg_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_path, "pyvenv.cfg" });
    defer allocator.free(cfg_path);

    const content = runtime.readFileAlloc(allocator, cfg_path, 64 * 1024) catch {
        // Missing or unreadable -> treat as "not built"; list output stays robust.
        return null;
    };
    defer allocator.free(content);

    const fields = parsePyvenvCfg(content);
    const version = fields.version orelse return null;
    return try allocator.dupe(u8, fields.path orelse version);
}

// registry.json as written by save and read back by load. On read, a missing
// id or venv_path is rebuilt (registries from older zenv versions).
const RegistryJSON = struct {
    environments: []const RegistryEntryJSON,

    const RegistryEntryJSON = struct {
        id: ?[]const u8 = null,
        name: []const u8,
        project_dir: []const u8,
        target_machine: []const u8,
        venv_path: ?[]const u8 = null,
        description: ?[]const u8 = null,
        aliases: []const []const u8 = &.{},
    };
};

pub const EnvironmentRegistry = struct {
    allocator: Allocator,
    entries: std.ArrayList(RegistryEntry),

    pub fn init(allocator: Allocator) EnvironmentRegistry {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *EnvironmentRegistry) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn load(allocator: Allocator) !EnvironmentRegistry {
        var registry = EnvironmentRegistry.init(allocator);
        errdefer registry.deinit();

        // Read first and only create ZENV_DIR when the registry is missing:
        // every command loads the registry, so the common path stays a single
        // file read instead of a mkdir round-trip per invocation.
        const registry_path = try paths.zenvPath(allocator, "registry.json");
        defer allocator.free(registry_path);

        // Read the registry file (creating an empty one if it does not exist yet)
        const file_content = runtime.readFileAlloc(allocator, registry_path, 10 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                try registry.save(); // Creates ZENV_DIR and an empty registry
                return registry;
            }
            output.printError(allocator, "Failed to open registry file: {s}", .{@errorName(err)}) catch {};
            return err;
        };
        defer allocator.free(file_content);

        // Parsed into a scratch arena; every field kept below is duped into
        // `allocator`.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const root = try json.parseFromSliceLeaky(json.Value, arena.allocator(), file_content, .{});
        if (root != .object) return error.InvalidRegistryFormat;
        const environments = root.object.get("environments") orelse return registry;
        if (environments != .array) return error.InvalidRegistryFormat;

        try registry.entries.ensureTotalCapacityPrecise(allocator, environments.array.items.len);
        for (environments.array.items) |value| {
            const e = json.parseFromValueLeaky(RegistryJSON.RegistryEntryJSON, arena.allocator(), value, .{
                .ignore_unknown_fields = true,
            }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue, // not an entry zenv wrote; skip it
            };

            var entry: RegistryEntry = .{};
            errdefer entry.deinit(allocator);
            entry.env_name = try allocator.dupe(u8, e.name);
            entry.project_dir = try allocator.dupe(u8, e.project_dir);
            entry.target_machines_str = try allocator.dupe(u8, e.target_machine);
            if (e.description) |desc| entry.description = try allocator.dupe(u8, desc);
            entry.id = if (e.id) |id| try allocator.dupe(u8, id) else try generateSHA1ID(allocator, e.name, e.project_dir, e.target_machine);
            entry.venv_path = if (e.venv_path) |p| try allocator.dupe(u8, p) else try std.Io.Dir.path.join(allocator, &[_][]const u8{ e.project_dir, "zenv", e.name });
            try entry.aliases.ensureTotalCapacityPrecise(allocator, e.aliases.len);
            for (e.aliases) |alias| entry.aliases.appendAssumeCapacity(try allocator.dupe(u8, alias));
            registry.entries.appendAssumeCapacity(entry);
        }
        return registry;
    }

    /// Starts a read-modify-write of registry.json. Takes an exclusive lock on
    /// `<ZENV_DIR>/registry.lock` (shared filesystems: across nodes too) and
    /// replaces the in-memory entries with the file's current contents, so the
    /// caller's change applies to what is on disk now rather than to the copy
    /// loaded when the command started (which may be minutes old after a
    /// setup). Entries, refs and borrowed strings from before are invalid
    /// afterwards. Finish with `endUpdate`.
    fn beginUpdate(self: *EnvironmentRegistry) !std.Io.File {
        const lock_path = try paths.ensureZenvPath(self.allocator, "registry.lock");
        defer self.allocator.free(lock_path);

        var file = try runtime.createFile(lock_path, .{ .truncate = false });
        errdefer file.close(runtime.io);
        try file.lock(runtime.io, .exclusive);
        errdefer file.unlock(runtime.io);

        const fresh = try EnvironmentRegistry.load(self.allocator);
        self.deinit();
        self.* = fresh;
        return file;
    }

    fn endUpdate(file: std.Io.File) void {
        file.unlock(runtime.io);
        file.close(runtime.io);
    }

    fn indexOfId(self: *const EnvironmentRegistry, id: []const u8) !usize {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, id)) return i;
        }
        return error.EnvironmentNotRegistered; // removed by another process meanwhile
    }

    pub fn save(self: *const EnvironmentRegistry) !void {
        const registry_path = try paths.ensureZenvPath(self.allocator, "registry.json");
        defer self.allocator.free(registry_path);

        // Build a plain serializable view of the registry and let std.json
        // stringify it directly (no manual Value-tree construction).
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const entries = try a.alloc(RegistryJSON.RegistryEntryJSON, self.entries.items.len);
        for (self.entries.items, 0..) |entry, i| {
            entries[i] = .{
                .id = entry.id,
                .name = entry.env_name,
                .project_dir = entry.project_dir,
                .target_machine = entry.target_machines_str,
                .venv_path = entry.venv_path,
                .description = entry.description,
                .aliases = entry.aliases.items,
            };
        }
        const registry_json = RegistryJSON{ .environments = entries };

        // Serialize to JSON text and write it out in one shot.
        const json_text = try std.json.Stringify.valueAlloc(
            self.allocator,
            registry_json,
            .{ .whitespace = .indent_2 },
        );
        defer self.allocator.free(json_text);

        // Atomic replace: a crash mid-save must never truncate the registry.
        try runtime.writeFileAtomic(self.allocator, registry_path, json_text);
    }

    /// Adds (or updates) the entry for `env_name` and persists registry.json,
    /// matching deregister/rename: every mutator saves, so callers cannot
    /// forget. If the save fails the error is returned and the in-memory
    /// registry keeps the (consistently owned) change; callers then stop.
    pub fn register(
        self: *EnvironmentRegistry,
        env_name: []const u8,
        project_dir: []const u8,
        base_dir: []const u8,
        description: ?[]const u8,
        target_machines: []const []const u8,
    ) !void {
        const lock = try self.beginUpdate();
        defer endUpdate(lock);
        try self.upsert(env_name, project_dir, base_dir, description, target_machines);
        try self.save();
    }

    /// In-memory part of register: an existing entry keeps its name, id and
    /// aliases and takes the new location, description and targets; otherwise
    /// a new entry is appended.
    fn upsert(
        self: *EnvironmentRegistry,
        env_name: []const u8,
        project_dir: []const u8,
        base_dir: []const u8,
        description: ?[]const u8,
        target_machines: []const []const u8,
    ) !void {
        const a = self.allocator;
        var new: RegistryEntry = .{};
        errdefer new.deinit(a);
        new.project_dir = try a.dupe(u8, project_dir);
        if (description) |desc| new.description = try a.dupe(u8, desc);
        new.target_machines_str = if (target_machines.len == 0) try a.dupe(u8, "any") else try std.mem.join(a, ", ", target_machines);
        new.venv_path = try paths.venvPath(a, project_dir, base_dir, env_name);

        for (self.entries.items) |*entry| {
            if (!matches(entry.*, .name, env_name)) continue;
            // `new` takes the replaced strings and frees them.
            std.mem.swap([]const u8, &entry.project_dir, &new.project_dir);
            std.mem.swap(?[]const u8, &entry.description, &new.description);
            std.mem.swap([]const u8, &entry.target_machines_str, &new.target_machines_str);
            std.mem.swap([]const u8, &entry.venv_path, &new.venv_path);
            new.deinit(a);
            return;
        }
        new.env_name = try a.dupe(u8, env_name);
        new.id = try generateSHA1ID(a, env_name, project_dir, new.target_machines_str);
        try self.entries.append(a, new);
    }

    /// Structural removal by ref. CONSUMES the ref and RETURNS the owned,
    /// detached entry so the caller can read env_name/venv_path AFTER removal
    /// with no dupe-before-mutate. Persists registry.json on success; on save
    /// failure the entry is freed and the error returned (no leak).
    pub fn deregister(self: *EnvironmentRegistry, ref: EnvRef) !RegistryEntry {
        const id = try self.allocator.dupe(u8, self.entries.items[ref.idx].id);
        defer self.allocator.free(id);
        const lock = try self.beginUpdate();
        defer endUpdate(lock);

        var removed = self.entries.orderedRemove(try self.indexOfId(id));
        errdefer removed.deinit(self.allocator);
        try self.save();
        return removed;
    }

    /// Opaque, stable handle to a resolved environment. Index-keyed: valid
    /// across a field mutation of its entry (rename), consumed by structural
    /// removal (deregister), and does not outlive a reload of the registry.
    pub const EnvRef = struct { idx: usize };

    /// What an identifier is matched against: "." matches project_dir, any
    /// other identifier tries name -> alias -> exact id -> 7+ char id prefix.
    const MatchKind = enum { project_dir, name, alias, id, id_prefix };

    fn matches(entry: RegistryEntry, kind: MatchKind, key: []const u8) bool {
        return switch (kind) {
            .project_dir => std.mem.eql(u8, entry.project_dir, key),
            .name => std.mem.eql(u8, entry.env_name, key),
            .alias => for (entry.aliases.items) |alias| {
                if (std.mem.eql(u8, alias, key)) break true;
            } else false,
            .id => std.mem.eql(u8, entry.id, key),
            .id_prefix => key.len >= 7 and std.mem.startsWith(u8, entry.id, key),
        };
    }

    const Tally = struct { first: ?usize = null, count: usize = 0 };

    /// The entries matching (kind, key), restricted to those whose
    /// target_machines match `on_host` when it is non-null.
    fn tally(self: *const EnvironmentRegistry, kind: MatchKind, key: []const u8, on_host: ?[]const u8) Tally {
        var t: Tally = .{};
        for (self.entries.items, 0..) |entry, i| {
            if (!matches(entry, kind, key)) continue;
            if (on_host) |hn| if (!host.hostMatchesTargets(hn, entry.target_machines_str)) continue;
            t.count += 1;
            if (t.first == null) t.first = i;
        }
        return t;
    }

    /// The one entry matching (kind, key), or null when none does. Names and
    /// ids are unique, so the first match wins. Several project_dir or alias
    /// matches (per-machine envs sharing a project or an alias) are narrowed to
    /// the one whose target_machines matches `hostname`; a tie the host cannot
    /// break (null hostname, 0 or >1 survivors) is `AmbiguousIdentifier`, and
    /// so is a 7+ char id prefix matching several ids (host-blind, a typo case).
    fn unique(
        self: *const EnvironmentRegistry,
        kind: MatchKind,
        key: []const u8,
        hostname: ?[]const u8,
    ) error{AmbiguousIdentifier}!?EnvRef {
        const all = self.tally(kind, key, null);
        if (all.count <= 1 or kind == .name or kind == .id) return if (all.first) |i| .{ .idx = i } else null;
        if (kind == .id_prefix) return error.AmbiguousIdentifier;
        const on_host = self.tally(kind, key, hostname orelse return error.AmbiguousIdentifier);
        if (on_host.count != 1) return error.AmbiguousIdentifier;
        return .{ .idx = on_host.first.? };
    }

    /// Pure resolution core (internal seam). No I/O, no printing. Maps an
    /// identifier to exactly one entry index, applying the load-bearing order:
    ///   "." (project_dir == cwd) -> name -> alias -> exact id -> unique 7+ prefix.
    /// `cwd` must be non-null when `identifier` is "."; pass null otherwise.
    /// `hostname`, when non-null, breaks a tie in the host-aware branches ("." and
    /// a shared alias), see `unique`. Ambiguity (a prefix matching >1, or a
    /// "."/alias the host can't narrow to one) is distinct from not-found.
    fn resolveAgainstCwd(
        self: *const EnvironmentRegistry,
        identifier: []const u8,
        cwd: ?[]const u8,
        hostname: ?[]const u8,
    ) error{ EnvironmentNotRegistered, AmbiguousIdentifier }!EnvRef {
        if (std.mem.eql(u8, identifier, ".")) {
            const dir = cwd orelse return error.EnvironmentNotRegistered;
            return try self.unique(.project_dir, dir, hostname) orelse error.EnvironmentNotRegistered;
        }
        for ([_]MatchKind{ .name, .alias, .id, .id_prefix }) |kind| {
            if (try self.unique(kind, identifier, hostname)) |ref| return ref;
        }
        return error.EnvironmentNotRegistered;
    }

    /// Handler-facing entry point. Resolves a raw <name|id|.> to a stable EnvRef.
    /// Touches the filesystem for the "." branch (cwd realpath + zenv.json
    /// presence) and, ONLY to break a tie, for the current hostname. Prints
    /// nothing — failures are typed errors that the caller renders (see
    /// commands.present) and main.zig maps.
    ///
    /// Hostname is fetched lazily: the first pass runs host-blind, and only an
    /// `AmbiguousIdentifier` (the sole outcome a host can change) triggers a
    /// `getSystemHostname` retry. So the common path never spawns `hostname`, and
    /// a hostname that can't be determined degrades gracefully to the ambiguity.
    pub fn resolve(self: *const EnvironmentRegistry, allocator: Allocator, identifier: []const u8) !EnvRef {
        if (!std.mem.eql(u8, identifier, ".")) return self.resolveWithHost(allocator, identifier, null);
        runtime.access("zenv.json") catch |err| {
            if (err == error.FileNotFound) return error.ConfigFileNotFound;
            return err;
        };
        const cwd = try runtime.cwdRealpath(allocator);
        defer allocator.free(cwd);
        return self.resolveWithHost(allocator, identifier, cwd);
    }

    /// Resolves "." as if run from `dir`, a canonical project directory (as
    /// `realpathAlloc` returns it), without changing the process cwd.
    pub fn resolveDir(self: *const EnvironmentRegistry, allocator: Allocator, dir: []const u8) !EnvRef {
        return self.resolveWithHost(allocator, ".", dir);
    }

    fn resolveWithHost(self: *const EnvironmentRegistry, allocator: Allocator, identifier: []const u8, cwd: ?[]const u8) !EnvRef {
        return self.resolveAgainstCwd(identifier, cwd, null) catch |e| {
            if (e != error.AmbiguousIdentifier) return e;
            const hn = host.getSystemHostname(allocator) catch return e;
            defer allocator.free(hn);
            return self.resolveAgainstCwd(identifier, cwd, hn);
        };
    }

    /// Just-in-time borrow through a handle. The returned pointer/slices are
    /// registry-owned and live until the entry is mutated/removed; do not stash.
    pub fn get(self: *const EnvironmentRegistry, ref: EnvRef) *const RegistryEntry {
        return &self.entries.items[ref.idx];
    }

    /// One environment an ambiguous identifier matched, carried with its target
    /// machines so the caller can show WHY the host couldn't pick a single one.
    /// Both slices are registry-owned (borrowed); caller frees only the outer slice.
    pub const Candidate = struct {
        env_name: []const u8,
        target_machines: []const u8,
    };

    /// Names the candidates an ambiguous identifier matched, for the call-site
    /// error message. Covers all three ambiguity kinds: "." (project_dir == cwd),
    /// a shared alias, and a non-unique 7+ id-prefix. Returns borrowed slices;
    /// caller frees the outer slice only.
    pub fn candidates(self: *const EnvironmentRegistry, allocator: Allocator, identifier: []const u8) ![]Candidate {
        var list: std.ArrayList(Candidate) = .empty;
        errdefer list.deinit(allocator);

        const dot = std.mem.eql(u8, identifier, ".");
        const cwd = if (dot) runtime.cwdRealpath(allocator) catch return list.toOwnedSlice(allocator) else null;
        defer if (cwd) |dir| allocator.free(dir);
        // "." lists the envs of this project; anything else a shared alias's
        // holders, or failing that the ids a non-unique 7+ prefix matches.
        const kinds: []const MatchKind = if (dot) &.{.project_dir} else &.{ .alias, .id_prefix };
        for (kinds) |kind| {
            for (self.entries.items) |entry| {
                if (matches(entry, kind, cwd orelse identifier))
                    try list.append(allocator, .{ .env_name = entry.env_name, .target_machines = entry.target_machines_str });
            }
            if (list.items.len > 0) break;
        }
        return list.toOwnedSlice(allocator);
    }

    // Alias management methods

    /// Attaches `alias_name` to the env named `env_name` and persists, on the
    /// registry as it is on disk now (see beginUpdate).
    pub fn addAlias(self: *EnvironmentRegistry, alias_name: []const u8, env_name_in: []const u8) !void {
        if (!paths.isValidEnvName(alias_name)) return error.InvalidEnvironmentName;
        // env_name_in may be borrowed from an entry, which beginUpdate frees.
        const env_name = try self.allocator.dupe(u8, env_name_in);
        defer self.allocator.free(env_name);
        const lock = try self.beginUpdate();
        defer endUpdate(lock);

        try self.attachAlias(alias_name, env_name);
        try self.save();
    }

    /// In-memory part of addAlias.
    fn attachAlias(self: *EnvironmentRegistry, alias_name: []const u8, env_name: []const u8) !void {
        // Reject an alias that would shadow an existing environment name. Resolution
        // is name-first, so without this guard such an alias would be unreachable
        // and confusing; forbidding it keeps name and alias namespaces disjoint.
        for (self.entries.items) |entry| {
            if (matches(entry, .name, alias_name)) return error.AliasAlreadyExists;
        }

        // Find the target environment and attach the alias. A given alias MAY be
        // shared across several environments — host-aware resolution disambiguates
        // by the current machine (see resolveAgainstCwd) — so an alias already used
        // by ANOTHER entry is not rejected; only re-adding it to the SAME entry is.
        for (self.entries.items) |*entry| {
            if (matches(entry.*, .name, env_name)) {
                if (matches(entry.*, .alias, alias_name)) return error.AliasAlreadyExists;
                const alias_name_owned = try self.allocator.dupe(u8, alias_name);
                errdefer self.allocator.free(alias_name_owned);
                try entry.aliases.append(self.allocator, alias_name_owned);
                return;
            }
        }
        return error.EnvironmentNotFound;
    }

    /// Removes the alias from EVERY environment that holds it (a shared alias spans
    /// several per-machine envs, so removal is "drop this name everywhere") and
    /// persists. Returns true if at least one occurrence was removed.
    pub fn removeAlias(self: *EnvironmentRegistry, alias_name: []const u8) !bool {
        const lock = try self.beginUpdate();
        defer endUpdate(lock);
        const removed = self.detachAlias(alias_name);
        if (removed) try self.save();
        return removed;
    }

    /// In-memory part of removeAlias.
    fn detachAlias(self: *EnvironmentRegistry, alias_name: []const u8) bool {
        var removed = false;
        for (self.entries.items) |*entry| {
            var i: usize = 0;
            while (i < entry.aliases.items.len) {
                if (std.mem.eql(u8, entry.aliases.items[i], alias_name)) {
                    self.allocator.free(entry.aliases.orderedRemove(i));
                    removed = true; // do not advance i; the next item shifted down
                } else {
                    i += 1;
                }
            }
        }
        return removed;
    }

    /// The name of the first environment holding alias `identifier`, or null.
    pub fn resolveAlias(self: *const EnvironmentRegistry, identifier: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (matches(entry, .alias, identifier)) return entry.env_name;
        }
        return null;
    }

    /// Field-mutates the entry at `ref` (env_name, venv_path, recomputed id) in
    /// place and persists. `ref` is updated to the entry's index in the
    /// re-read registry, so a caller's rollback is `rename(ref, old_name)`. If
    /// the save fails the error is returned and the in-memory registry keeps
    /// the change; callers then stop. Does NOT move the venv directory or touch
    /// Jupyter kernels — that orchestration stays in the command.
    pub fn rename(self: *EnvironmentRegistry, ref: *EnvRef, new_name: []const u8) !void {
        if (!paths.isValidEnvName(new_name)) return error.InvalidEnvironmentName;
        const id = try self.allocator.dupe(u8, self.entries.items[ref.idx].id);
        defer self.allocator.free(id);
        const lock = try self.beginUpdate();
        defer endUpdate(lock);
        ref.* = .{ .idx = try self.indexOfId(id) };
        try self.renameAt(ref.*, new_name);
        try self.save();
    }

    /// Whether `name` already resolves to an entry (name, alias, exact id, or
    /// unique prefix). Host-blind (null hostname): a rename target must be free
    /// on every host. Only a clean not-found means the name is available; an
    /// AmbiguousIdentifier (e.g. `name` equals an alias shared by several envs)
    /// means it is taken, or an env_name could collide with an alias.
    pub fn nameTaken(self: *const EnvironmentRegistry, name: []const u8) bool {
        _ = self.resolveAgainstCwd(name, null, null) catch |e| return e == error.AmbiguousIdentifier;
        return true;
    }

    /// In-memory part of rename, on an up-to-date registry: uniqueness check,
    /// then the new name, venv path and id.
    fn renameAt(self: *EnvironmentRegistry, ref: EnvRef, new_name: []const u8) !void {
        if (self.nameTaken(new_name)) return error.EnvironmentAlreadyExists;
        const a = self.allocator;
        const entry = &self.entries.items[ref.idx];
        const parent_dir = std.Io.Dir.path.dirname(entry.venv_path) orelse return error.InvalidPath;

        // Built in full before anything is swapped; it ends up holding (and
        // freeing) the replaced strings.
        var new: RegistryEntry = .{};
        defer new.deinit(a);
        new.venv_path = try std.Io.Dir.path.join(a, &[_][]const u8{ parent_dir, new_name });
        new.id = try generateSHA1ID(a, new_name, entry.project_dir, entry.target_machines_str);
        new.env_name = try a.dupe(u8, new_name);
        std.mem.swap([]const u8, &entry.venv_path, &new.venv_path);
        std.mem.swap([]const u8, &entry.id, &new.id);
        std.mem.swap([]const u8, &entry.env_name, &new.env_name);
    }
};

// ============================ Tests ============================

const testing = std.testing;
const test_support = @import("../test_support.zig");

test "generateSHA1ID returns 40-char lowercase hex" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const id = try generateSHA1ID(a, "env", "/proj", "*");
    defer a.free(id);
    try testing.expectEqual(@as(usize, 40), id.len);
    const again = try generateSHA1ID(a, "env", "/proj", "*");
    defer a.free(again);
    try testing.expectEqualStrings(id, again); // reproducible
    const shifted = try generateSHA1ID(a, "en", "v/proj", "*");
    defer a.free(shifted);
    try testing.expect(!std.mem.eql(u8, id, shifted)); // field boundaries count
    for (id) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
}

test "registry resolution by name, alias, and id prefix" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();

    try reg.entries.append(a, .{
        .id = try a.dupe(u8, "0123456789abcdef0123456789abcdef01234567"),
        .env_name = try a.dupe(u8, "myenv"),
        .project_dir = try a.dupe(u8, "/p"),
        .description = null,
        .target_machines_str = try a.dupe(u8, "*"),
        .venv_path = try a.dupe(u8, "/p/zenv/myenv"),
        .aliases = .empty,
    });

    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("myenv", null, null)).idx);
    try testing.expectError(error.EnvironmentNotRegistered, reg.resolveAgainstCwd("nope", null, null));
    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("0123456789abcdef", null, null)).idx); // id prefix

    try reg.attachAlias("me", "myenv");
    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("me", null, null)).idx);
    try testing.expectEqualStrings("myenv", reg.resolveAlias("me").?);
    try testing.expect(reg.detachAlias("me"));
    try testing.expect(reg.resolveAlias("me") == null);
}

// Appends a minimal entry for resolution tests (venv_path mirrors the dir; not asserted on).
fn tAppend(reg: *EnvironmentRegistry, id: []const u8, name: []const u8, dir: []const u8) !void {
    try tAppendT(reg, id, name, dir, "*");
}

// Like tAppend but with an explicit target_machines_str, for host-aware tests.
fn tAppendT(reg: *EnvironmentRegistry, id: []const u8, name: []const u8, dir: []const u8, targets: []const u8) !void {
    const a = reg.allocator;
    try reg.entries.append(a, .{
        .id = try a.dupe(u8, id),
        .env_name = try a.dupe(u8, name),
        .project_dir = try a.dupe(u8, dir),
        .description = null,
        .target_machines_str = try a.dupe(u8, targets),
        .venv_path = try a.dupe(u8, dir),
        .aliases = .empty,
    });
}

test "resolveAgainstCwd: name, alias, exact id, unique prefix, not-found" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppend(&reg, "aaaaaaa1111111111111111111111111111111111", "web", "/p/web");
    try tAppend(&reg, "bbbbbbb2222222222222222222222222222222222", "api", "/p/api");
    try reg.attachAlias("w", "web");

    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("web", null, null)).idx);
    try testing.expectEqual(@as(usize, 1), (try reg.resolveAgainstCwd("api", null, null)).idx);
    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("w", null, null)).idx); // alias
    try testing.expectEqual(@as(usize, 1), (try reg.resolveAgainstCwd("bbbbbbb2222222222222222222222222222222222", null, null)).idx); // exact id
    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("aaaaaaa", null, null)).idx); // unique 7-char prefix
    try testing.expectError(error.EnvironmentNotRegistered, reg.resolveAgainstCwd("nope", null, null));
}

test "resolveAgainstCwd: ambiguous id prefix is distinct from not-found" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppend(&reg, "abcdef0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "one", "/p/one");
    try tAppend(&reg, "abcdef0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "two", "/p/two");

    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd("abcdef0", null, null));
}

test "resolveAgainstCwd: '.' matches by cwd, ambiguous when two share a project_dir" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppend(&reg, "id1aaaa0000000000000000000000000000000000", "web", "/proj");

    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd(".", "/proj", null)).idx);
    try testing.expectError(error.EnvironmentNotRegistered, reg.resolveAgainstCwd(".", "/elsewhere", null));
    try testing.expectError(error.EnvironmentNotRegistered, reg.resolveAgainstCwd(".", null, null));

    try tAppend(&reg, "id2bbbb0000000000000000000000000000000000", "worker", "/proj");
    // Two envs share the project_dir and both target "*", so no host can pick one.
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd(".", "/proj", null));
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd(".", "/proj", "anyhost"));
}

// Builds a registry of two per-machine envs sharing one project_dir and one alias
// "dev" — the user's HPC shared-filesystem setup.
fn tSharedAliasReg(reg: *EnvironmentRegistry) !void {
    try tAppendT(reg, "aaaaaaa1111111111111111111111111111111111", "env_m1", "/proj", "machine1");
    try tAppendT(reg, "bbbbbbb2222222222222222222222222222222222", "env_m2", "/proj", "machine2");
    try reg.attachAlias("dev", "env_m1");
    try reg.attachAlias("dev", "env_m2");
}

test "resolveAgainstCwd: a shared alias is disambiguated by the current host" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tSharedAliasReg(&reg);

    const r1 = try reg.resolveAgainstCwd("dev", null, "machine1");
    try testing.expectEqualStrings("env_m1", reg.get(r1).env_name);
    const r2 = try reg.resolveAgainstCwd("dev", null, "machine2");
    try testing.expectEqualStrings("env_m2", reg.get(r2).env_name);
}

test "resolveAgainstCwd: a shared alias is ambiguous without a hostname" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tSharedAliasReg(&reg);
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd("dev", null, null));
}

test "resolveAgainstCwd: a shared alias matching no host is ambiguous" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tSharedAliasReg(&reg);
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd("dev", null, "machine3"));
}

test "resolveAgainstCwd: a shared alias whose holders both target '*' is ambiguous" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppendT(&reg, "aaaaaaa1111111111111111111111111111111111", "env_a", "/proj", "*");
    try tAppendT(&reg, "bbbbbbb2222222222222222222222222222222222", "env_b", "/proj", "*");
    try reg.attachAlias("dev", "env_a");
    try reg.attachAlias("dev", "env_b");
    // Both holders match every host, so the host can never narrow to one.
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd("dev", null, "anyhost"));
}

test "resolveAgainstCwd: a single-holder alias resolves regardless of host" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppendT(&reg, "aaaaaaa1111111111111111111111111111111111", "web", "/p/web", "machine1");
    try reg.attachAlias("w", "web");
    // The host does not match the target, but a lone alias holder still resolves
    // (back-compat: host only breaks ties among >1 candidate).
    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("w", null, "other")).idx);
    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("w", null, null)).idx);
}

test "resolveAgainstCwd: '.' is disambiguated by host when envs share a project_dir" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppendT(&reg, "aaaaaaa1111111111111111111111111111111111", "env_m1", "/proj", "machine1");
    try tAppendT(&reg, "bbbbbbb2222222222222222222222222222222222", "env_m2", "/proj", "machine2");

    const r1 = try reg.resolveAgainstCwd(".", "/proj", "machine1");
    try testing.expectEqualStrings("env_m1", reg.get(r1).env_name);
    const r2 = try reg.resolveAgainstCwd(".", "/proj", "machine2");
    try testing.expectEqualStrings("env_m2", reg.get(r2).env_name);
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd(".", "/proj", "machine3"));
}

test "addAlias: shares an alias across entries, rejects same-entry dup and name-shadow" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppendT(&reg, "aaaaaaa1111111111111111111111111111111111", "env_m1", "/proj", "machine1");
    try tAppendT(&reg, "bbbbbbb2222222222222222222222222222222222", "env_m2", "/proj", "machine2");

    try reg.attachAlias("dev", "env_m1");
    try reg.attachAlias("dev", "env_m2"); // shared across entries: now allowed
    // Re-adding the same alias to the SAME entry is still rejected.
    try testing.expectError(error.AliasAlreadyExists, reg.attachAlias("dev", "env_m1"));
    // An alias equal to an existing env name is still rejected (name-shadow guard).
    try testing.expectError(error.AliasAlreadyExists, reg.attachAlias("env_m2", "env_m1"));
}

test "removeAlias: drops a shared alias from every holder" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tSharedAliasReg(&reg);
    try testing.expect(reg.detachAlias("dev"));
    // Gone from both holders: "dev" no longer resolves on any host.
    try testing.expectError(error.EnvironmentNotRegistered, reg.resolveAgainstCwd("dev", null, "machine1"));
    try testing.expect(!reg.detachAlias("dev")); // nothing left to remove
}

test "rename: rejects a new name equal to a shared (ambiguous) alias" {
    const a = testing.allocator;
    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tSharedAliasReg(&reg);
    const ref = try reg.resolveAgainstCwd("env_m1", null, null);
    // "dev" resolves ambiguously (shared alias); rename must treat it as taken,
    // not swallow the ambiguity and let an env_name collide with an alias.
    try testing.expectError(error.EnvironmentAlreadyExists, reg.renameAt(ref, "dev"));
}

test "registry save/load round-trips a shared alias" {
    test_support.setupRuntime();
    const a = testing.allocator;

    const zdir = ".zig-cache/tmp/zenv-shared-alias-roundtrip";
    runtime.environ_map.put("ZENV_DIR", zdir) catch unreachable;
    runtime.deleteTree(zdir) catch {};
    defer runtime.deleteTree(zdir) catch {};

    {
        var reg = EnvironmentRegistry.init(a);
        defer reg.deinit();
        try tSharedAliasReg(&reg);
        try reg.save();
    }
    {
        var reg2 = try EnvironmentRegistry.load(a);
        defer reg2.deinit();
        const r1 = try reg2.resolveAgainstCwd("dev", null, "machine1");
        try testing.expectEqualStrings("env_m1", reg2.get(r1).env_name);
        const r2 = try reg2.resolveAgainstCwd("dev", null, "machine2");
        try testing.expectEqualStrings("env_m2", reg2.get(r2).env_name);
    }
}

test "registry load rejects a non-object root instead of crashing" {
    test_support.setupRuntime();
    const a = testing.allocator;

    const zdir = ".zig-cache/tmp/zenv-registry-bad-root";
    runtime.environ_map.put("ZENV_DIR", zdir) catch unreachable;
    runtime.deleteTree(zdir) catch {};
    defer runtime.deleteTree(zdir) catch {};
    try runtime.makePath(zdir);
    try runtime.writeFile(zdir ++ "/registry.json", "[]");

    try testing.expectError(error.InvalidRegistryFormat, EnvironmentRegistry.load(a));
}

test "registry load rebuilds a missing id and venv_path and skips malformed entries" {
    test_support.setupRuntime();
    const a = testing.allocator;

    const zdir = ".zig-cache/tmp/zenv-registry-legacy";
    runtime.environ_map.put("ZENV_DIR", zdir) catch unreachable;
    runtime.deleteTree(zdir) catch {};
    defer runtime.deleteTree(zdir) catch {};
    try runtime.makePath(zdir);
    try runtime.writeFile(zdir ++ "/registry.json",
        \\{ "environments": [
        \\  { "name": "old", "project_dir": "/p", "target_machine": "*", "extra": 1 },
        \\  { "name": "bad", "project_dir": 5, "target_machine": "*" },
        \\  "not an entry",
        \\  { "id": "abc", "name": "new", "project_dir": "/q", "target_machine": "m1, m2",
        \\    "venv_path": "/q/.zenv/new", "description": null, "aliases": ["n"] }
        \\] }
    );

    var reg = try EnvironmentRegistry.load(a);
    defer reg.deinit();
    try testing.expectEqual(@as(usize, 2), reg.entries.items.len);
    const old = reg.entries.items[0];
    try testing.expectEqualStrings("/p/zenv/old", old.venv_path);
    const want_id = try generateSHA1ID(a, "old", "/p", "*");
    defer a.free(want_id);
    try testing.expectEqualStrings(want_id, old.id);
    const new = reg.entries.items[1];
    try testing.expectEqualStrings("abc", new.id);
    try testing.expectEqualStrings("/q/.zenv/new", new.venv_path);
    try testing.expect(new.description == null);
    try testing.expectEqualStrings("new", reg.resolveAlias("n").?);
}

test "deregister(ref) transfers ownership; rename(ref) keeps the ref valid" {
    test_support.setupRuntime();
    const a = testing.allocator;

    // Point ZENV_DIR at a scratch dir so the folded save() writes there, not ~/.zenv.
    // (Map.put copies the strings.) The testing allocator then leak-checks the
    // entries' own allocations — catching any double-free/leak in the mutators.
    const zdir = ".zig-cache/tmp/zenv-registry-test";
    runtime.environ_map.put("ZENV_DIR", zdir) catch unreachable;
    runtime.deleteTree(zdir) catch {};
    defer runtime.deleteTree(zdir) catch {};

    var reg = EnvironmentRegistry.init(a);
    defer reg.deinit();
    try tAppend(&reg, "aaaaaaa1111111111111111111111111111111111", "web", "/p/web");
    try tAppend(&reg, "bbbbbbb2222222222222222222222222222222222", "api", "/p/api");
    try reg.save(); // mutators re-read registry.json under the lock

    // rename: the ref is kept current and the old strings are freed once.
    var ref_web = try reg.resolveAgainstCwd("web", null, null);
    try reg.rename(&ref_web, "web2");
    try testing.expectEqualStrings("web2", reg.get(ref_web).env_name);
    try testing.expectEqual(ref_web.idx, (try reg.resolveAgainstCwd("web2", null, null)).idx);

    // deregister: the owned, detached entry is readable after removal, then freed once.
    const ref_api = try reg.resolveAgainstCwd("api", null, null);
    var removed = try reg.deregister(ref_api);
    try testing.expectEqualStrings("api", removed.env_name);
    removed.deinit(a);
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try testing.expectEqualStrings("web2", reg.get(.{ .idx = 0 }).env_name);
}

test "parsePyvenvCfg: 3.11-style uses executable path" {
    const content =
        \\home = /opt/python/3.11/bin
        \\include-system-site-packages = false
        \\version = 3.11.5
        \\executable = /opt/python/3.11/bin/python3.11
        \\command = /opt/python/3.11/bin/python3.11 -m venv /p/zenv/e
    ;
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.11.5", f.version.?);
    try testing.expectEqualStrings("/opt/python/3.11/bin/python3.11", f.path.?);
}

test "parsePyvenvCfg: 3.10-style (no executable) falls back to command's first token" {
    const content =
        \\home = /opt/python/3.10/bin
        \\include-system-site-packages = false
        \\version = 3.10.8
        \\command = /opt/python/3.10/bin/python3.10 -m venv /p/zenv/e
    ;
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.10.8", f.version.?);
    try testing.expectEqualStrings("/opt/python/3.10/bin/python3.10", f.path.?);
}

test "parsePyvenvCfg: only version + home falls back to home" {
    const content =
        \\home = /usr/bin
        \\version = 3.9.2
    ;
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.9.2", f.version.?);
    try testing.expectEqualStrings("/usr/bin", f.path.?);
}

test "parsePyvenvCfg: missing version yields null (caller omits the line)" {
    const content =
        \\home = /usr/bin
        \\include-system-site-packages = false
    ;
    const f = parsePyvenvCfg(content);
    try testing.expect(f.version == null);
}

test "parsePyvenvCfg: tolerates CRLF and irregular spacing around '='" {
    const content = "version=3.12.1\r\nexecutable   =   /x/py\r\n";
    const f = parsePyvenvCfg(content);
    try testing.expectEqualStrings("3.12.1", f.version.?);
    try testing.expectEqualStrings("/x/py", f.path.?);
}
