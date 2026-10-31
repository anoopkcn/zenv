//! The global registry of environments, `<ZENV_DIR>/registry.json`. `zenv
//! setup` and `zenv register` record an environment here, so every other
//! command can find it by name, alias, id or "." from any directory.

const Registry = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const ArrayList = std.ArrayList;
const json = std.json;
const paths = @import("paths.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const host = @import("host.zig");

allocator: Allocator,
io: Io,
/// zenv's environment: ZENV_DIR/HOME locate registry.json, and the host
/// identity breaks resolution ties.
env: *const Environ.Map,
entries: std.ArrayList(Entry) = .empty,

/// One registered environment; every string is owned. The empty defaults let a
/// partly built entry be deinit'd safely.
pub const Entry = struct {
    id: []const u8 = "", // SHA-1 unique identifier
    env_name: []const u8 = "",
    project_dir: []const u8 = "",
    description: ?[]const u8 = null,
    target_machines_str: []const u8 = "",
    venv_path: []const u8 = "",
    aliases: ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Entry, allocator: Allocator) void {
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

    pub fn hasAlias(self: *const Entry, alias: []const u8) bool {
        for (self.aliases.items) |a| {
            if (std.mem.eql(u8, a, alias)) return true;
        }
        return false;
    }

    /// Serialized as registry.json lists it (see `EntryJson`).
    pub fn jsonStringify(self: Entry, jw: *json.Stringify) json.Stringify.Error!void {
        try jw.write(EntryJson{
            .id = self.id,
            .name = self.env_name,
            .project_dir = self.project_dir,
            .target_machine = self.target_machines_str,
            .venv_path = self.venv_path,
            .description = self.description,
            .aliases = self.aliases.items,
        });
    }
};

/// One environment as registry.json lists it, written by `save` and read
/// back by `load`. On read, a missing id or venv_path is rebuilt (registries
/// from older zenv versions).
const EntryJson = struct {
    id: ?[]const u8 = null,
    name: []const u8,
    project_dir: []const u8,
    target_machine: []const u8,
    venv_path: ?[]const u8 = null,
    description: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
};

/// An environment's id: SHA-1 of (name, project dir, targets), NUL-separated so
/// field boundaries cannot shift. A (name, project dir) pair is registered
/// once, so ids are unique, and they are reproducible: re-registering the same
/// env gives the same id, so a remembered id prefix keeps working.
fn envId(
    allocator: Allocator,
    env_name: []const u8,
    project_dir: []const u8,
    target_machines_str: []const u8,
) ![]const u8 {
    var sha1: std.crypto.hash.Sha1 = .init(.{});
    for ([_][]const u8{ env_name, project_dir, target_machines_str }) |part| {
        sha1.update(part);
        sha1.update("\x00");
    }
    return allocator.dupe(u8, &std.fmt.bytesToHex(sha1.finalResult(), .lower));
}

pub fn init(allocator: Allocator, io: Io, env: *const Environ.Map) Registry {
    return .{ .allocator = allocator, .io = io, .env = env };
}

pub fn deinit(self: *Registry) void {
    for (self.entries.items) |*entry| entry.deinit(self.allocator);
    self.entries.deinit(self.allocator);
}

pub fn load(allocator: Allocator, io: Io, env: *const Environ.Map) !Registry {
    var registry = Registry.init(allocator, io, env);
    errdefer registry.deinit();

    // Read first and only create ZENV_DIR when the registry is missing:
    // every command loads the registry, so the common path stays a single
    // file read instead of a mkdir round-trip per invocation.
    const registry_path = try paths.zenvPath(allocator, env, "registry.json");
    defer allocator.free(registry_path);

    // Read the registry file (creating an empty one if it does not exist yet)
    const file_content = Io.Dir.cwd().readFileAlloc(
        io,
        registry_path,
        allocator,
        .limited(10 * 1024 * 1024),
    ) catch |err| {
        if (err == error.FileNotFound) {
            try registry.save(); // Creates ZENV_DIR and an empty registry
            return registry;
        }
        return err;
    };
    defer allocator.free(file_content);

    // Parsed into a scratch arena; every field kept below is duped into
    // `allocator`.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = json.parseFromSliceLeaky(
        json.Value,
        arena.allocator(),
        file_content,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRegistryFormat,
    };
    if (root != .object) return error.InvalidRegistryFormat;
    const environments = root.object.get("environments") orelse return registry;
    if (environments != .array) return error.InvalidRegistryFormat;

    try registry.entries.ensureTotalCapacityPrecise(allocator, environments.array.items.len);
    for (environments.array.items) |value| {
        const e = json.parseFromValueLeaky(EntryJson, arena.allocator(), value, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue, // not an entry zenv wrote; skip it
        };

        var entry: Entry = .{};
        errdefer entry.deinit(allocator);
        entry.env_name = try allocator.dupe(u8, e.name);
        entry.project_dir = try allocator.dupe(u8, e.project_dir);
        entry.target_machines_str = try allocator.dupe(u8, e.target_machine);
        if (e.description) |desc| entry.description = try allocator.dupe(u8, desc);
        entry.id = if (e.id) |id| try allocator.dupe(u8, id) else try envId(
            allocator,
            e.name,
            e.project_dir,
            e.target_machine,
        );
        entry.venv_path = if (e.venv_path) |p| try allocator.dupe(u8, p) else try Io.Dir.path.join(
            allocator,
            &.{ e.project_dir, "zenv", e.name },
        );
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
/// afterwards. Close the returned lock file to finish.
fn beginUpdate(self: *Registry) !Io.File {
    const zenv_dir = try paths.getZenvDir(self.allocator, self.env);
    defer self.allocator.free(zenv_dir);
    const lock_path = try Io.Dir.path.join(self.allocator, &.{ zenv_dir, "registry.lock" });
    defer self.allocator.free(lock_path);

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(self.io, zenv_dir);
    // flock(2); closing the file releases it.
    const file = try cwd.createFile(self.io, lock_path, .{ .truncate = false, .lock = .exclusive });
    errdefer file.close(self.io);

    const fresh = try Registry.load(self.allocator, self.io, self.env);
    self.deinit();
    self.* = fresh;
    return file;
}

fn indexOfId(self: *const Registry, id: []const u8) !usize {
    for (self.entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, id)) return i;
    }
    return error.EnvironmentNotRegistered; // removed by another process meanwhile
}

pub fn save(self: *const Registry) !void {
    const zenv_dir = try paths.getZenvDir(self.allocator, self.env);
    defer self.allocator.free(zenv_dir);
    try Io.Dir.cwd().createDirPath(self.io, zenv_dir);
    const registry_path = try Io.Dir.path.join(self.allocator, &.{ zenv_dir, "registry.json" });
    defer self.allocator.free(registry_path);

    // Atomic replace: a crash mid-save must never truncate the registry.
    try runtime.writeJsonAtomic(
        self.io,
        registry_path,
        .{ .environments = self.entries.items },
        false,
    );
}

/// Adds (or updates) the entry for `env_name` and persists registry.json,
/// matching deregister/rename: every mutator saves, so callers cannot
/// forget. If the save fails the error is returned and the in-memory
/// registry keeps the (consistently owned) change; callers then stop.
pub fn register(
    self: *Registry,
    env_name: []const u8,
    project_dir: []const u8,
    base_dir: []const u8,
    description: ?[]const u8,
    target_machines: []const []const u8,
) !void {
    const lock = try self.beginUpdate();
    defer lock.close(self.io);
    try self.upsert(env_name, project_dir, base_dir, description, target_machines);
    try self.save();
}

/// In-memory part of register: the entry of `env_name` in `project_dir`
/// keeps its name, id and aliases and takes the new location, description and
/// targets; otherwise a new entry is appended. The same name may be
/// registered for several projects (clones, worktrees of one repo).
fn upsert(
    self: *Registry,
    env_name: []const u8,
    project_dir: []const u8,
    base_dir: []const u8,
    description: ?[]const u8,
    target_machines: []const []const u8,
) !void {
    const a = self.allocator;
    var new: Entry = .{};
    errdefer new.deinit(a);
    new.project_dir = try a.dupe(u8, project_dir);
    if (description) |desc| new.description = try a.dupe(u8, desc);
    new.target_machines_str = if (target_machines.len == 0) try a.dupe(
        u8,
        "any",
    ) else try std.mem.join(
        a,
        ", ",
        target_machines,
    );
    new.venv_path = try paths.venvPath(a, project_dir, base_dir, env_name);

    for (self.entries.items) |*entry| {
        if (!matches(entry.*, .name, env_name) or !std.mem.eql(u8, entry.project_dir, project_dir)) continue;
        // `new` takes the replaced strings and frees them.
        std.mem.swap([]const u8, &entry.project_dir, &new.project_dir);
        std.mem.swap(?[]const u8, &entry.description, &new.description);
        std.mem.swap([]const u8, &entry.target_machines_str, &new.target_machines_str);
        std.mem.swap([]const u8, &entry.venv_path, &new.venv_path);
        new.deinit(a);
        return;
    }
    // Names resolve before aliases, so a new name equal to an alias would hide
    // it (the command checks first; this covers an alias added meanwhile).
    if (self.resolveAlias(env_name) != null) return error.AliasAlreadyExists;
    new.env_name = try a.dupe(u8, env_name);
    new.id = try envId(a, env_name, project_dir, new.target_machines_str);
    try self.entries.append(a, new);
}

/// Structural removal by ref. CONSUMES the ref and RETURNS the owned,
/// detached entry so the caller can read env_name/venv_path AFTER removal
/// with no dupe-before-mutate. Persists registry.json on success; on save
/// failure the entry is freed and the error returned (no leak).
pub fn deregister(self: *Registry, ref: Ref) !Entry {
    const id = try self.allocator.dupe(u8, self.entries.items[ref.idx].id);
    defer self.allocator.free(id);
    const lock = try self.beginUpdate();
    defer lock.close(self.io);

    var removed = self.entries.orderedRemove(try self.indexOfId(id));
    errdefer removed.deinit(self.allocator);
    try self.save();
    return removed;
}

/// Opaque, stable handle to a resolved environment. Index-keyed: valid
/// across a field mutation of its entry (rename), consumed by structural
/// removal (deregister), and does not outlive a reload of the registry.
pub const Ref = struct { idx: usize };

/// What an identifier is matched against: "." matches project_dir, any
/// other identifier tries name -> alias -> exact id -> 7+ char id prefix.
const MatchKind = enum { project_dir, name, alias, id, id_prefix };

fn matches(entry: Entry, kind: MatchKind, key: []const u8) bool {
    return switch (kind) {
        .project_dir => std.mem.eql(u8, entry.project_dir, key),
        .name => std.mem.eql(u8, entry.env_name, key),
        .alias => entry.hasAlias(key),
        .id => std.mem.eql(u8, entry.id, key),
        .id_prefix => key.len >= 7 and std.mem.startsWith(u8, entry.id, key),
    };
}

const Tally = struct { first: ?usize = null, count: usize = 0 };

/// The entries matching (kind, key), restricted to those whose
/// target_machines match `on_host` when it is non-null.
fn tally(self: *const Registry, kind: MatchKind, key: []const u8, on_host: ?[]const u8) Tally {
    var t: Tally = .{};
    for (self.entries.items, 0..) |entry, i| {
        if (!matches(entry, kind, key)) continue;
        if (on_host) |hn| if (!host.matchesTargets(hn, entry.target_machines_str)) continue;
        t.count += 1;
        if (t.first == null) t.first = i;
    }
    return t;
}

/// The one entry matching (kind, key), or null when none does. Ids are
/// unique, so the first match wins. A name registered for several projects
/// is narrowed to the one of project `cwd` (when known). Several name,
/// project_dir or alias matches (per-machine envs sharing a project or an
/// alias) are narrowed to the one whose target_machines matches `hostname`;
/// a tie these cannot break (null hostname, 0 or >1 survivors) is
/// `AmbiguousIdentifier`, and so is a 7+ char id prefix matching several ids
/// (host-blind, a typo case).
fn unique(
    self: *const Registry,
    kind: MatchKind,
    key: []const u8,
    cwd: ?[]const u8,
    hostname: ?[]const u8,
) error{AmbiguousIdentifier}!?Ref {
    const all = self.tally(kind, key, null);
    if (all.count <= 1 or kind == .id) return if (all.first) |i| .{
        .idx = i,
    } else null;
    if (kind == .id_prefix) return error.AmbiguousIdentifier;
    if (kind == .name) if (cwd) |dir| {
        var found: ?usize = null;
        var count: usize = 0;
        for (self.entries.items, 0..) |entry, i| {
            if (!matches(entry, .name, key) or !std.mem.eql(u8, entry.project_dir, dir)) continue;
            count += 1;
            found = i;
        }
        if (count == 1) return .{ .idx = found.? };
    };
    const on_host = self.tally(kind, key, hostname orelse return error.AmbiguousIdentifier);
    if (on_host.count != 1) return error.AmbiguousIdentifier;
    return .{ .idx = on_host.first.? };
}

/// Pure resolution core (internal seam). No I/O, no printing. Maps an
/// identifier to exactly one entry index, applying the load-bearing order:
///   "." (project_dir == cwd) -> name -> alias -> exact id -> unique 7+ prefix.
/// `cwd` is the project directory "." names (see `dotProjectDir`); it must
/// be non-null when `identifier` is ".". For a name it breaks a tie between
/// projects registering that name; null leaves such a tie to the host.
/// `hostname`, when non-null, breaks a tie in the host-aware branches ("." and
/// a shared alias), see `unique`. Ambiguity (a prefix matching >1, or a
/// "."/alias the host can't narrow to one) is distinct from not-found.
fn resolveAgainstCwd(
    self: *const Registry,
    identifier: []const u8,
    cwd: ?[]const u8,
    hostname: ?[]const u8,
) error{ EnvironmentNotRegistered, AmbiguousIdentifier }!Ref {
    if (std.mem.eql(u8, identifier, ".")) {
        const dir = cwd orelse return error.EnvironmentNotRegistered;
        return try self.unique(.project_dir, dir, null, hostname) orelse error.EnvironmentNotRegistered;
    }
    for ([_]MatchKind{ .name, .alias, .id, .id_prefix }) |kind| {
        if (try self.unique(kind, identifier, cwd, hostname)) |ref| return ref;
    }
    return error.EnvironmentNotRegistered;
}

/// Handler-facing entry point. Resolves a raw <name|id|.> to a stable Ref.
/// Touches the filesystem for the "." branch (the nearest zenv.json at or
/// above the cwd, see `dotProjectDir`) and, ONLY to break a tie, for the
/// current hostname. Prints nothing — failures are typed errors that the
/// caller renders (see commands.present) and main.zig maps.
///
/// Hostname is fetched lazily: the first pass runs host-blind, and only an
/// `AmbiguousIdentifier` (the sole outcome a host can change) triggers a
/// `getSystemHostname` retry. So the common path never spawns `hostname`, and
/// a hostname that can't be determined degrades gracefully to the ambiguity.
pub fn resolve(self: *const Registry, allocator: Allocator, identifier: []const u8) !Ref {
    if (!std.mem.eql(u8, identifier, ".")) return self.resolveWithHost(allocator, identifier, null);
    const root = try dotProjectDir(allocator, self.io);
    defer allocator.free(root);
    return self.resolveWithHost(allocator, identifier, root);
}

/// The project "." names: the nearest directory at or above the cwd that
/// holds a zenv.json, as the cd hook finds it (`paths.findProjectRoot`).
/// `ConfigFileNotFound` when there is none. Caller owns the result.
pub fn dotProjectDir(allocator: Allocator, io: Io) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return try paths.findProjectRoot(allocator, io, cwd) orelse error.ConfigFileNotFound;
}

/// Resolves "." as if run from `dir`, a canonical project directory (as
/// `realpathAlloc` returns it), without changing the process cwd.
pub fn resolveDir(self: *const Registry, allocator: Allocator, dir: []const u8) !Ref {
    return self.resolveWithHost(allocator, ".", dir);
}

fn resolveWithHost(
    self: *const Registry,
    allocator: Allocator,
    identifier: []const u8,
    cwd: ?[]const u8,
) !Ref {
    return self.resolveAgainstCwd(identifier, cwd, null) catch |e| {
        if (e != error.AmbiguousIdentifier) return e;
        // A name several projects register: the one of the project the cwd is
        // in wins, as "." would pick it.
        var dir = cwd;
        var owned: ?[]u8 = null;
        defer if (owned) |o| allocator.free(o);
        if (dir == null) {
            owned = dotProjectDir(allocator, self.io) catch null;
            dir = owned;
            if (dir != null) {
                if (self.resolveAgainstCwd(identifier, dir, null)) |ref| return ref else |e2| {
                    if (e2 != error.AmbiguousIdentifier) return e2;
                }
            }
        }
        const hn = host.getSystemHostname(allocator, self.io, self.env) catch return e;
        defer allocator.free(hn);
        return self.resolveAgainstCwd(identifier, dir, hn);
    };
}

/// The entry of env `env_name` in project `project_dir`, or null.
pub fn find(self: *const Registry, env_name: []const u8, project_dir: []const u8) ?Ref {
    for (self.entries.items, 0..) |entry, i| {
        if (matches(entry, .name, env_name) and std.mem.eql(u8, entry.project_dir, project_dir))
            return .{ .idx = i };
    }
    return null;
}

/// What reaches the env at `ref` from any directory, e.g. in a Jupyter
/// kernel's `zenv run`: its name, or its id when other projects register
/// the name too. Registry-owned.
pub fn launchIdentifier(self: *const Registry, ref: Ref) []const u8 {
    const entry = self.get(ref);
    if (self.tally(.name, entry.env_name, null).count > 1) return entry.id;
    return entry.env_name;
}

/// Just-in-time borrow through a handle. The returned pointer/slices are
/// registry-owned and live until the entry is mutated/removed; do not stash.
pub fn get(self: *const Registry, ref: Ref) *const Entry {
    return &self.entries.items[ref.idx];
}

/// One environment an ambiguous identifier matched, carried with its target
/// machines so the caller can show WHY the host couldn't pick a single one.
/// Both slices are registry-owned (borrowed); caller frees only the outer slice.
pub const Candidate = struct {
    env_name: []const u8,
    target_machines: []const u8,
    project_dir: []const u8,
    id: []const u8,
};

/// Names the candidates an ambiguous identifier matched, for the call-site
/// error message. Covers all three ambiguity kinds: "." (the envs of the
/// project "." names), a shared alias, and a non-unique 7+ id-prefix.
/// Returns borrowed slices; caller frees the outer slice only.
pub fn candidates(
    self: *const Registry,
    allocator: Allocator,
    identifier: []const u8,
) ![]Candidate {
    var list: std.ArrayList(Candidate) = .empty;
    errdefer list.deinit(allocator);

    const dot = std.mem.eql(u8, identifier, ".");
    const cwd = if (dot) dotProjectDir(
        allocator,
        self.io,
    ) catch return list.toOwnedSlice(allocator) else null;
    defer if (cwd) |dir| allocator.free(dir);
    // "." lists the envs of this project; anything else the projects
    // registering a name, a shared alias's holders, or failing that the ids
    // a non-unique 7+ prefix matches.
    const kinds: []const MatchKind = if (dot) &.{.project_dir} else &.{ .name, .alias, .id_prefix };
    for (kinds) |kind| {
        for (self.entries.items) |entry| {
            if (matches(entry, kind, cwd orelse identifier))
                try list.append(allocator, .{
                    .env_name = entry.env_name,
                    .target_machines = entry.target_machines_str,
                    .project_dir = entry.project_dir,
                    .id = entry.id,
                });
        }
        // One name match is no ambiguity of its own; an alias may still be.
        if (list.items.len > @intFromBool(kind == .name)) break;
        list.clearRetainingCapacity();
    }
    return list.toOwnedSlice(allocator);
}

// Alias management methods

/// Attaches `alias_name` to the env with id `env_id` and persists, on the
/// registry as it is on disk now (see beginUpdate).
pub fn addAlias(self: *Registry, alias_name: []const u8, env_id: []const u8) !void {
    if (!paths.isValidEnvName(alias_name)) return error.InvalidEnvironmentName;
    // env_id may be borrowed from an entry, which beginUpdate frees.
    const env_name = try self.allocator.dupe(u8, env_id);
    defer self.allocator.free(env_name);
    const lock = try self.beginUpdate();
    defer lock.close(self.io);

    try self.attachAlias(alias_name, env_name);
    try self.save();
}

/// In-memory part of addAlias. `env_name` is the env's id, or (in tests) its
/// name, of which the first entry is used.
fn attachAlias(self: *Registry, alias_name: []const u8, env_name: []const u8) !void {
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
    const target = for (self.entries.items, 0..) |entry, i| {
        if (matches(entry, .id, env_name)) break i;
    } else for (self.entries.items, 0..) |entry, i| {
        if (matches(entry, .name, env_name)) break i;
    } else null;
    const entry = &self.entries.items[target orelse return error.EnvironmentNotFound];
    if (matches(entry.*, .alias, alias_name)) return error.AliasAlreadyExists;
    const alias_name_owned = try self.allocator.dupe(u8, alias_name);
    errdefer self.allocator.free(alias_name_owned);
    try entry.aliases.append(self.allocator, alias_name_owned);
}

/// Removes the alias from EVERY environment that holds it (a shared alias spans
/// several per-machine envs, so removal is "drop this name everywhere") and
/// persists. Returns true if at least one occurrence was removed.
pub fn removeAlias(self: *Registry, alias_name: []const u8) !bool {
    const lock = try self.beginUpdate();
    defer lock.close(self.io);
    const removed = self.detachAlias(alias_name);
    if (removed) try self.save();
    return removed;
}

/// In-memory part of removeAlias.
fn detachAlias(self: *Registry, alias_name: []const u8) bool {
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
pub fn resolveAlias(self: *const Registry, identifier: []const u8) ?[]const u8 {
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
pub fn rename(self: *Registry, ref: *Ref, new_name: []const u8) !void {
    if (!paths.isValidEnvName(new_name)) return error.InvalidEnvironmentName;
    const id = try self.allocator.dupe(u8, self.entries.items[ref.idx].id);
    defer self.allocator.free(id);
    const lock = try self.beginUpdate();
    defer lock.close(self.io);
    ref.* = .{ .idx = try self.indexOfId(id) };
    try self.renameAt(ref.*, new_name);
    try self.save();
}

/// Whether `name` cannot become the name of an env of project `project_dir`:
/// another env of that project has it, or it is an alias or (a 7+ character
/// prefix of) an id. Host-blind: a rename target must be free on every host.
/// Envs of other projects may share it.
pub fn nameTaken(self: *const Registry, name: []const u8, project_dir: []const u8) bool {
    for (self.entries.items) |entry| {
        if (matches(entry, .name, name) and std.mem.eql(u8, entry.project_dir, project_dir)) return true;
        if (matches(entry, .alias, name) or matches(entry, .id, name) or matches(entry, .id_prefix, name)) return true;
    }
    return false;
}

/// In-memory part of rename, on an up-to-date registry: uniqueness check,
/// then the new name, venv path and id.
fn renameAt(self: *Registry, ref: Ref, new_name: []const u8) !void {
    if (self.nameTaken(new_name, self.entries.items[ref.idx].project_dir)) return error.EnvironmentAlreadyExists;
    const a = self.allocator;
    const entry = &self.entries.items[ref.idx];
    const parent_dir = Io.Dir.path.dirname(entry.venv_path) orelse return error.InvalidPath;

    // Built in full before anything is swapped; it ends up holding (and
    // freeing) the replaced strings.
    var new: Entry = .{};
    defer new.deinit(a);
    new.venv_path = try Io.Dir.path.join(a, &.{ parent_dir, new_name });
    new.id = try envId(a, new_name, entry.project_dir, entry.target_machines_str);
    new.env_name = try a.dupe(u8, new_name);
    std.mem.swap([]const u8, &entry.venv_path, &new.venv_path);
    std.mem.swap([]const u8, &entry.id, &new.id);
    std.mem.swap([]const u8, &entry.env_name, &new.env_name);
}

// ============================ Tests ============================

const testing = std.testing;
const test_support = @import("test_support.zig");

/// An environment whose ZENV_DIR is `zdir`, so registry files go there.
fn zenvDirEnv(a: Allocator, zdir: []const u8) !Environ.Map {
    var env = Environ.Map.init(a);
    errdefer env.deinit();
    try env.put("ZENV_DIR", zdir);
    return env;
}

test "envId returns 40-char lowercase hex" {
    const a = testing.allocator;
    const id = try envId(a, "env", "/proj", "*");
    defer a.free(id);
    try testing.expectEqual(@as(usize, 40), id.len);
    const again = try envId(a, "env", "/proj", "*");
    defer a.free(again);
    try testing.expectEqualStrings(id, again); // reproducible
    const shifted = try envId(a, "en", "v/proj", "*");
    defer a.free(shifted);
    try testing.expect(!std.mem.eql(u8, id, shifted)); // field boundaries count
    for (id) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(ok);
    }
}

test "registry resolution by name, alias, and id prefix" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
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
    try testing.expectError(
        error.EnvironmentNotRegistered,
        reg.resolveAgainstCwd("nope", null, null),
    );
    try testing.expectEqual(
        @as(usize, 0),
        (try reg.resolveAgainstCwd("0123456789abcdef", null, null)).idx,
    ); // id prefix

    try reg.attachAlias("me", "myenv");
    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("me", null, null)).idx);
    try testing.expectEqualStrings("myenv", reg.resolveAlias("me").?);
    try testing.expect(reg.detachAlias("me"));
    try testing.expect(reg.resolveAlias("me") == null);
}

/// Appends a minimal entry for resolution tests (venv_path mirrors the dir; not asserted on).
fn tAppend(reg: *Registry, id: []const u8, name: []const u8, dir: []const u8) !void {
    try tAppendT(reg, id, name, dir, "*");
}

/// Like tAppend but with an explicit target_machines_str, for host-aware tests.
fn tAppendT(
    reg: *Registry,
    id: []const u8,
    name: []const u8,
    dir: []const u8,
    targets: []const u8,
) !void {
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
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tAppend(&reg, "aaaaaaa1111111111111111111111111111111111", "web", "/p/web");
    try tAppend(&reg, "bbbbbbb2222222222222222222222222222222222", "api", "/p/api");
    try reg.attachAlias("w", "web");

    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd("web", null, null)).idx);
    try testing.expectEqual(@as(usize, 1), (try reg.resolveAgainstCwd("api", null, null)).idx);
    try testing.expectEqual(
        @as(usize, 0),
        (try reg.resolveAgainstCwd("w", null, null)).idx,
    ); // alias
    try testing.expectEqual(
        @as(usize, 1),
        (try reg.resolveAgainstCwd("bbbbbbb2222222222222222222222222222222222", null, null)).idx,
    ); // exact id
    try testing.expectEqual(
        @as(usize, 0),
        (try reg.resolveAgainstCwd("aaaaaaa", null, null)).idx,
    ); // unique 7-char prefix
    try testing.expectError(
        error.EnvironmentNotRegistered,
        reg.resolveAgainstCwd("nope", null, null),
    );
}

test "resolveAgainstCwd: ambiguous id prefix is distinct from not-found" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tAppend(&reg, "abcdef0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "one", "/p/one");
    try tAppend(&reg, "abcdef0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "two", "/p/two");

    try testing.expectError(
        error.AmbiguousIdentifier,
        reg.resolveAgainstCwd("abcdef0", null, null),
    );
}

test "resolveAgainstCwd: '.' matches by cwd, ambiguous when two share a project_dir" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tAppend(&reg, "id1aaaa0000000000000000000000000000000000", "web", "/proj");

    try testing.expectEqual(@as(usize, 0), (try reg.resolveAgainstCwd(".", "/proj", null)).idx);
    try testing.expectError(
        error.EnvironmentNotRegistered,
        reg.resolveAgainstCwd(".", "/elsewhere", null),
    );
    try testing.expectError(error.EnvironmentNotRegistered, reg.resolveAgainstCwd(".", null, null));

    try tAppend(&reg, "id2bbbb0000000000000000000000000000000000", "worker", "/proj");
    // Two envs share the project_dir and both target "*", so no host can pick one.
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd(".", "/proj", null));
    try testing.expectError(
        error.AmbiguousIdentifier,
        reg.resolveAgainstCwd(".", "/proj", "anyhost"),
    );
}

/// Builds a registry of two per-machine envs sharing one project_dir and one alias
/// "dev" — the user's HPC shared-filesystem setup.
fn tSharedAliasReg(reg: *Registry) !void {
    try tAppendT(reg, "aaaaaaa1111111111111111111111111111111111", "env_m1", "/proj", "machine1");
    try tAppendT(reg, "bbbbbbb2222222222222222222222222222222222", "env_m2", "/proj", "machine2");
    try reg.attachAlias("dev", "env_m1");
    try reg.attachAlias("dev", "env_m2");
}

test "resolveAgainstCwd: a shared alias is disambiguated by the current host" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tSharedAliasReg(&reg);

    const r1 = try reg.resolveAgainstCwd("dev", null, "machine1");
    try testing.expectEqualStrings("env_m1", reg.get(r1).env_name);
    const r2 = try reg.resolveAgainstCwd("dev", null, "machine2");
    try testing.expectEqualStrings("env_m2", reg.get(r2).env_name);
}

test "resolveAgainstCwd: a shared alias is ambiguous without a hostname" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tSharedAliasReg(&reg);
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd("dev", null, null));
}

test "resolveAgainstCwd: a shared alias matching no host is ambiguous" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tSharedAliasReg(&reg);
    try testing.expectError(
        error.AmbiguousIdentifier,
        reg.resolveAgainstCwd("dev", null, "machine3"),
    );
}

test "resolveAgainstCwd: a shared alias whose holders both target '*' is ambiguous" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tAppendT(&reg, "aaaaaaa1111111111111111111111111111111111", "env_a", "/proj", "*");
    try tAppendT(&reg, "bbbbbbb2222222222222222222222222222222222", "env_b", "/proj", "*");
    try reg.attachAlias("dev", "env_a");
    try reg.attachAlias("dev", "env_b");
    // Both holders match every host, so the host can never narrow to one.
    try testing.expectError(
        error.AmbiguousIdentifier,
        reg.resolveAgainstCwd("dev", null, "anyhost"),
    );
}

test "resolveAgainstCwd: a single-holder alias resolves regardless of host" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
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
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tAppendT(&reg, "aaaaaaa1111111111111111111111111111111111", "env_m1", "/proj", "machine1");
    try tAppendT(&reg, "bbbbbbb2222222222222222222222222222222222", "env_m2", "/proj", "machine2");

    const r1 = try reg.resolveAgainstCwd(".", "/proj", "machine1");
    try testing.expectEqualStrings("env_m1", reg.get(r1).env_name);
    const r2 = try reg.resolveAgainstCwd(".", "/proj", "machine2");
    try testing.expectEqualStrings("env_m2", reg.get(r2).env_name);
    try testing.expectError(
        error.AmbiguousIdentifier,
        reg.resolveAgainstCwd(".", "/proj", "machine3"),
    );
}

test "addAlias: shares an alias across entries, rejects same-entry dup and name-shadow" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
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

test "upsert: a new env cannot take a name that is an alias" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tAppend(&reg, "aaaaaaa1111111111111111111111111111111111", "web", "/p/web");
    try reg.attachAlias("dev", "web");
    try testing.expectError(error.AliasAlreadyExists, reg.upsert("dev", "/p/dev", ".zenv", null, &.{"*"}));
    try reg.upsert("web", "/p/web", "envs", null, &.{"*"}); // the project's env is updated
    try testing.expectEqualStrings("/p/web/envs/web", reg.entries.items[0].venv_path);
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try reg.upsert("web", "/p/web2", ".zenv", null, &.{"*"}); // another project's is added
    try testing.expectEqual(@as(usize, 2), reg.entries.items.len);
    try testing.expectEqualStrings("/p/web", reg.entries.items[0].project_dir);
}

test "removeAlias: drops a shared alias from every holder" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tSharedAliasReg(&reg);
    try testing.expect(reg.detachAlias("dev"));
    // Gone from both holders: "dev" no longer resolves on any host.
    try testing.expectError(
        error.EnvironmentNotRegistered,
        reg.resolveAgainstCwd("dev", null, "machine1"),
    );
    try testing.expect(!reg.detachAlias("dev")); // nothing left to remove
}

test "rename: rejects a new name equal to a shared (ambiguous) alias" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try tSharedAliasReg(&reg);
    const ref = try reg.resolveAgainstCwd("env_m1", null, null);
    // "dev" resolves ambiguously (shared alias); rename must treat it as taken,
    // not swallow the ambiguity and let an env_name collide with an alias.
    try testing.expectError(error.EnvironmentAlreadyExists, reg.renameAt(ref, "dev"));
}

test "registry save/load round-trips a shared alias" {
    const a = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    const zdir = ".zig-cache/tmp/zenv-shared-alias-roundtrip";
    var env = try zenvDirEnv(a, zdir);
    defer env.deinit();
    cwd.deleteTree(io, zdir) catch {};
    defer cwd.deleteTree(io, zdir) catch {};

    {
        var reg = Registry.init(a, io, &env);
        defer reg.deinit();
        try tSharedAliasReg(&reg);
        try reg.save();
    }
    {
        var reg2 = try Registry.load(a, io, &env);
        defer reg2.deinit();
        const r1 = try reg2.resolveAgainstCwd("dev", null, "machine1");
        try testing.expectEqualStrings("env_m1", reg2.get(r1).env_name);
        const r2 = try reg2.resolveAgainstCwd("dev", null, "machine2");
        try testing.expectEqualStrings("env_m2", reg2.get(r2).env_name);
    }
}

test "registry load rejects a non-object root instead of crashing" {
    const a = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    const zdir = ".zig-cache/tmp/zenv-registry-bad-root";
    var env = try zenvDirEnv(a, zdir);
    defer env.deinit();
    cwd.deleteTree(io, zdir) catch {};
    defer cwd.deleteTree(io, zdir) catch {};
    try cwd.createDirPath(io, zdir);
    try cwd.writeFile(io, .{ .sub_path = zdir ++ "/registry.json", .data = "[]" });

    try testing.expectError(error.InvalidRegistryFormat, Registry.load(a, io, &env));
}

test "registry load rebuilds a missing id and venv_path and skips malformed entries" {
    const a = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    const zdir = ".zig-cache/tmp/zenv-registry-legacy";
    var env = try zenvDirEnv(a, zdir);
    defer env.deinit();
    cwd.deleteTree(io, zdir) catch {};
    defer cwd.deleteTree(io, zdir) catch {};
    try cwd.createDirPath(io, zdir);
    try cwd.writeFile(io, .{ .sub_path = zdir ++ "/registry.json", .data =
        \\{ "environments": [
        \\  { "name": "old", "project_dir": "/p", "target_machine": "*", "extra": 1 },
        \\  { "name": "bad", "project_dir": 5, "target_machine": "*" },
        \\  "not an entry",
        \\  { "id": "abc", "name": "new", "project_dir": "/q", "target_machine": "m1, m2",
        \\    "venv_path": "/q/.zenv/new", "description": null, "aliases": ["n"] }
        \\] }
    });

    var reg = try Registry.load(a, io, &env);
    defer reg.deinit();
    try testing.expectEqual(@as(usize, 2), reg.entries.items.len);
    const old = reg.entries.items[0];
    try testing.expectEqualStrings("/p/zenv/old", old.venv_path);
    const want_id = try envId(a, "old", "/p", "*");
    defer a.free(want_id);
    try testing.expectEqualStrings(want_id, old.id);
    const new = reg.entries.items[1];
    try testing.expectEqualStrings("abc", new.id);
    try testing.expectEqualStrings("/q/.zenv/new", new.venv_path);
    try testing.expect(new.description == null);
    try testing.expectEqualStrings("new", reg.resolveAlias("n").?);
}

test "deregister(ref) transfers ownership; rename(ref) keeps the ref valid" {
    const a = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();

    // Point ZENV_DIR at a scratch dir so the folded save() writes there, not ~/.zenv.
    // (Map.put copies the strings.) The testing allocator then leak-checks the
    // entries' own allocations — catching any double-free/leak in the mutators.
    const zdir = ".zig-cache/tmp/zenv-registry-test";
    var env = try zenvDirEnv(a, zdir);
    defer env.deinit();
    cwd.deleteTree(io, zdir) catch {};
    defer cwd.deleteTree(io, zdir) catch {};

    var reg = Registry.init(a, io, &env);
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

test "a name registered by two projects resolves by the cwd's project" {
    const a = testing.allocator;
    var reg = Registry.init(a, testing.io, &test_support.no_env);
    defer reg.deinit();
    try reg.upsert("dev", "/p/a", ".zenv", null, &.{"*"});
    try reg.upsert("dev", "/p/b", ".zenv", null, &.{"*"});
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd("dev", null, null));
    try testing.expectError(error.AmbiguousIdentifier, reg.resolveAgainstCwd("dev", "/elsewhere", "h"));
    const b = try reg.resolveAgainstCwd("dev", "/p/b", null);
    try testing.expectEqualStrings("/p/b/.zenv/dev", reg.get(b).venv_path);
    // The ids differ, so each is reachable by id.
    const by_id = try reg.resolveAgainstCwd(reg.entries.items[0].id, null, null);
    try testing.expectEqualStrings("/p/a", reg.get(by_id).project_dir);
    // A name another project uses is free here; one this project uses is not.
    try testing.expect(!reg.nameTaken("dev", "/p/c"));
    try testing.expect(reg.nameTaken("dev", "/p/a"));
    // An alias goes to the env whose id is given.
    try reg.attachAlias("al", reg.entries.items[1].id);
    try testing.expectEqualStrings("/p/b", reg.get(try reg.resolveAgainstCwd("al", null, null)).project_dir);
}
