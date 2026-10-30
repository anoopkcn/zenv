//! The typed form of a project's zenv.json, as `validation.loadConfig` builds
//! it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// An env's `setup` or `activate` hook: commands run in order, then a script.
pub const Hook = struct {
    commands: ArrayList([]const u8) = .empty,
    script: ?[]const u8 = null,

    pub fn deinit(self: *Hook, allocator: Allocator) void {
        for (self.commands.items) |item| allocator.free(item);
        self.commands.deinit(allocator);
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

/// An env's `container`: the Apptainer image the env runs in (see
/// container.zig).
pub const Container = struct {
    /// A path (relative to zenv.json) or an Apptainer URI (`docker://...`), as written.
    image: []const u8,
    /// Extra `apptainer exec` options, e.g. "--nv".
    options: ArrayList([]const u8) = .empty,
    /// Extra bind specs, `src[:dest[:opts]]`, beyond the paths zenv binds itself.
    bind: ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Container, allocator: Allocator) void {
        allocator.free(self.image);
        for (self.options.items) |item| allocator.free(item);
        self.options.deinit(allocator);
        for (self.bind.items) |item| allocator.free(item);
        self.bind.deinit(allocator);
    }
};

pub const Env = struct {
    /// Every owned string and list in this config is allocated with `allocator`.
    allocator: Allocator,
    target_machines: ArrayList([]const u8) = .empty,
    description: ?[]const u8 = null,
    modules: ArrayList([]const u8) = .empty,
    modules_file: ?[]const u8 = null,
    dependency_file: ?[]const u8 = null,
    dependencies: ArrayList([]const u8) = .empty,
    /// Development-only dependencies recorded in zenv.json. Installed alongside
    /// `dependencies` during setup, but kept separate so `zenv add --dev` can
    /// track them apart from runtime deps (and from any dependency_file).
    dev_dependencies: ArrayList([]const u8) = .empty,
    fallback_python: ?[]const u8 = null,
    setup: Hook = .{},
    activate: Hook = .{},
    /// When true (default), setup snapshots the environment that `module load`
    /// produces and activate replays it instead of re-running Lmod. Only has an
    /// effect when `modules` is non-empty.
    module_cache: bool = true,
    /// When false, the env has no Python venv: setup only loads modules, runs
    /// the hooks and writes activation, for projects that use zenv just for
    /// modules and settings. Dependencies are then a validation error.
    python: bool = true,
    /// `env` from zenv.json, in file order: variables activation sets and
    /// deactivate restores.
    env: ArrayList(EnvVar) = .empty,
    /// When set, the env's Python, installs, hooks and commands run inside
    /// this Apptainer image.
    container: ?Container = null,

    pub fn init(allocator: Allocator) Env {
        return .{ .allocator = allocator };
    }

    fn freeList(allocator: Allocator, list: *ArrayList([]const u8)) void {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    pub fn deinit(self: *Env) void {
        const allocator = self.allocator;
        freeList(allocator, &self.target_machines);
        freeList(allocator, &self.modules);
        freeList(allocator, &self.dependencies);
        freeList(allocator, &self.dev_dependencies);

        if (self.description) |desc| allocator.free(desc);
        if (self.modules_file) |mfile| allocator.free(mfile);
        if (self.dependency_file) |req| allocator.free(req);
        if (self.fallback_python) |py_exec| allocator.free(py_exec);

        self.setup.deinit(allocator);
        self.activate.deinit(allocator);

        for (self.env.items) |v| {
            allocator.free(v.name);
            allocator.free(v.value);
        }
        self.env.deinit(allocator);
        if (self.container) |*c| c.deinit(allocator);
    }
};

pub const Project = struct {
    allocator: Allocator,
    environments: std.StringHashMapUnmanaged(Env) = .empty,
    base_dir: []const u8,

    pub fn deinit(self: *Project) void {
        var iter = self.environments.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.environments.deinit(self.allocator);
        self.allocator.free(self.base_dir);
    }

    pub fn getEnvironment(self: *const Project, env_name: []const u8) ?*const Env {
        return self.environments.getPtr(env_name);
    }
};
