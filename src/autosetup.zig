//! Auto-setup: keep a built environment in sync with its configuration.
//!
//! When `zenv.json` or any file it references (the dependency file, modules
//! file, or setup hook script) changes, the environment is stale and must be
//! rebuilt before commands like `run`/`activate` use it. This module detects
//! that drift with a checksum recorded in a per-env stamp file, and — when it
//! finds drift — re-runs `zenv setup` as a captured subprocess (silent build),
//! bracketed by a short notice on STDERR so the user knows a rebuild happened
//! without polluting the stdout that `activate`/`cd` feed to the shell.
//!
//! Why a subprocess instead of calling setup in-process: re-invoking
//! `zenv setup` and CAPTURING its output (`runtime.run`) keeps the rebuild
//! silent, reuses all of setup's logic verbatim with fresh config/registry
//! state, and — by setting the child's cwd to the project dir — reproduces the
//! original resolution of a relative `base_dir`/`dependency_file` exactly. `registry.register()` updates
//! in place by env_name, so re-setup never duplicates the registry entry.
//!
//! The stamp is the env's build record: the checksum of what it was built
//! from and the setup flags to replay. Only this module reads or writes it.
//! Setup records a build (`recordSetup`); commands that change tracked files
//! themselves (`add`, `rename`) do so inside a `Change`, which keeps an env
//! that was up to date from rebuilding; `builtWith` gives the flags of the
//! last build.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;

const runtime = @import("runtime.zig");
const Ctx = runtime.Ctx;
const paths = @import("paths.zig");
const config = @import("config.zig");
const Registry = @import("Registry.zig");
const validation = @import("validation.zig");
const output = @import("output.zig");
const cli = @import("cli.zig");
const deps = @import("deps.zig");
const container = @import("container.zig");
const jsonc = @import("jsonc.zig");
const sources = @import("sources.zig");

const stamp_name = ".zenv.stamp";
const stamp_version = 1;
const max_tracked_file_size = 10 * 1024 * 1024;

// ===========================================================================
// Tracked-file checksum
// ===========================================================================

/// Folds one tracked file into `sha`. The logical `key` and a content-length
/// separator are mixed in so that adding/removing/renaming a tracked file, or a
/// content boundary shift between adjacent files, all change the digest. A
/// missing or unreadable file is folded as a marker rather than erroring, so the
/// hash stays well-defined even when e.g. a configured dependency_file is absent.
fn foldFile(
    allocator: Allocator,
    io: Io,
    sha: *std.crypto.hash.Sha1,
    key: []const u8,
    path: []const u8,
) void {
    sha.update(key);
    sha.update("\x00");
    const content = readTracked(allocator, io, path) catch |err| {
        sha.update(if (err == error.FileNotFound) "A\x00" else "E\x00");
        return;
    };
    defer allocator.free(content);
    foldBytes(sha, content);
}

fn foldBytes(sha: *std.crypto.hash.Sha1, bytes: []const u8) void {
    sha.update("P\x00");
    sha.update(std.mem.asBytes(&bytes.len));
    sha.update(bytes);
    sha.update("\x00");
}

/// Folds the part of zenv.json (`zenv_json`, its content or why it could not
/// be read) that concerns `env_name`: `base_dir` and the env's own object,
/// re-serialized. Editing another env in the same file then leaves this env's
/// hash alone. A file that does not parse is folded whole.
fn foldEnvConfig(
    allocator: Allocator,
    sha: *std.crypto.hash.Sha1,
    zenv_json: anyerror![]const u8,
    env_name: []const u8,
) void {
    sha.update("config\x00");
    const content = zenv_json catch |err| {
        sha.update(if (err == error.FileNotFound) "A\x00" else "E\x00");
        return;
    };
    // Comments are blanked, so editing only a comment does not cause a rebuild.
    const stripped = jsonc.strip(allocator, content) catch return foldBytes(sha, content);
    defer allocator.free(stripped);
    const parsed = json.parseFromSlice(
        json.Value,
        allocator,
        stripped,
        .{},
    ) catch return foldBytes(sha, content);
    defer parsed.deinit();
    if (parsed.value != .object) return foldBytes(sha, content);
    for ([_][]const u8{ "base_dir", env_name }) |key| {
        sha.update(key);
        sha.update("\x00");
        const value = parsed.value.object.get(key) orelse {
            sha.update("A\x00");
            continue;
        };
        const text = json.Stringify.valueAlloc(
            allocator,
            value,
            .{},
        ) catch return foldBytes(sha, content);
        defer allocator.free(text);
        foldBytes(sha, text);
    }
}

/// What a build read besides its config: the `--group` dependency groups and
/// `--dev`, from the setup flags. They decide whether the project's
/// ./pyproject.toml is tracked (`sources.readsProjectPyproject`).
const Build = struct {
    groups: []const []const u8 = &.{},
    dev: bool = false,
};

/// The `Build` that setup flag tokens (`cli.Flags.buildTokens`) describe.
/// Groups borrow from `tokens`; the list is allocated with `allocator`.
fn buildOf(allocator: Allocator, tokens: []const []const u8) !Build {
    var groups: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i + 1 < tokens.len) : (i += 1) {
        if (std.mem.eql(u8, tokens[i], "--group")) try groups.append(allocator, tokens[i + 1]);
    }
    return .{ .groups = try groups.toOwnedSlice(allocator), .dev = cli.Flags.parse(tokens).dev_mode };
}

/// Lowercase-hex SHA-1 over what `env_name` is built from, in a fixed order:
/// its part of zenv.json (`zenv_json`: the content, or why it could not be
/// read), then dependency_file, modules_file and setup.script when
/// configured, a local container image, and the project's ./pyproject.toml
/// when `build` reads it as well. `anchor_dir` is the setup cwd when
/// recording the stamp and the entry's project_dir when checking — these are
/// the same directory, which is what makes the two call sites agree. A part
/// that does not apply is not folded at all, so envs it does not concern
/// keep their digest.
fn hashTracked(
    allocator: Allocator,
    io: Io,
    anchor_dir: []const u8,
    env_name: []const u8,
    env_config: *const config.Env,
    zenv_json: anyerror![]const u8,
    build: Build,
) ![40]u8 {
    var sha: std.crypto.hash.Sha1 = .init(.{});
    foldEnvConfig(allocator, &sha, zenv_json, env_name);
    const tracked = [_]struct { []const u8, ?[]const u8 }{
        .{ "deps", env_config.dependency_file },
        .{ "modules", env_config.modules_file },
        .{ "setup_script", env_config.setup.script },
    };
    for (tracked) |t| {
        const key, const configured = t;
        const p = try paths.resolvePath(allocator, anchor_dir, configured orelse continue);
        defer allocator.free(p);
        foldFile(allocator, io, &sha, key, p);
    }
    // A local image by size and modification time, so a re-pulled image
    // rebuilds the env; hashing gigabytes on every run would be too slow.
    // Folded only for container envs, so other envs keep their digest.
    if (env_config.container) |ct| if (!container.isUri(ct.image)) {
        sha.update("image\x00");
        const p = try paths.resolvePath(allocator, anchor_dir, ct.image);
        defer allocator.free(p);
        const fp = try container.fingerprint(allocator, io, p);
        defer if (fp) |f| allocator.free(f);
        foldBytes(&sha, fp orelse "A");
    };
    if (sources.readsProjectPyproject(env_config, build.groups, build.dev)) {
        const p = try paths.resolvePath(allocator, anchor_dir, "pyproject.toml");
        defer allocator.free(p);
        foldFile(allocator, io, &sha, "project_pyproject", p);
    }

    return std.fmt.bytesToHex(sha.finalResult(), .lower);
}

/// The content of tracked file `path`; the caller frees it.
fn readTracked(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_tracked_file_size));
}

// ===========================================================================
// Stamp file
// ===========================================================================

/// The stamp file's contents. `readStamp` returns it parsed.
const Stamp = struct {
    version: u32,
    hash: []const u8,
    flags: []const []const u8 = &.{},
};

fn stampPath(allocator: Allocator, venv_dir: []const u8) ![]u8 {
    return Io.Dir.path.join(allocator, &.{ venv_dir, stamp_name });
}

/// Writes `<venv_dir>/.zenv.stamp` atomically. `flags` are the build-affecting
/// setup flags to replay on a future auto-setup.
fn writeStamp(
    allocator: Allocator,
    io: Io,
    venv_dir: []const u8,
    hash: []const u8,
    build_flags: []const []const u8,
) !void {
    const path = try stampPath(allocator, venv_dir);
    defer allocator.free(path);
    const stamp: Stamp = .{ .version = stamp_version, .hash = hash, .flags = build_flags };
    try runtime.writeJsonAtomic(io, path, stamp, false);
}

/// Reads `<venv_dir>/.zenv.stamp`. Returns null (never errors) when the stamp is
/// absent, unreadable, malformed, or a different format version — every such
/// case means "treat as changed" and force a re-setup. Caller must `deinit`.
fn readStamp(allocator: Allocator, io: Io, venv_dir: []const u8) ?json.Parsed(Stamp) {
    const path = stampPath(allocator, venv_dir) catch return null;
    defer allocator.free(path);

    const content = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch return null;
    defer allocator.free(content);

    const parsed = json.parseFromSlice(Stamp, allocator, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    if (parsed.value.version != stamp_version) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

// ===========================================================================
// Flag replay
// ===========================================================================

/// The flags of the env's last setup that shape its builds (`--uv`, `--pip`,
/// `--force`, `--no-cache`, `--dev`, ...), which a command installing into
/// the env (`zenv add`) uses too. Defaults when there is no build record.
pub fn builtWith(allocator: Allocator, io: Io, venv_path: []const u8) cli.Flags {
    const stamp = readStamp(allocator, io, venv_path) orelse return .{};
    defer stamp.deinit();
    return cli.Flags.parse(stamp.value.flags);
}

/// What `addReplayGroup` did.
const ReplayGroup = enum { no_record, already, added };

/// Adds `--group <group>` to the replay flags of the env's stamp, keeping its
/// hash, so rebuilds install a group that `add` just recorded a package in.
/// `.no_record` when the env has no stamp (its next rebuild replays nothing).
fn addReplayGroup(
    allocator: Allocator,
    io: Io,
    venv_path: []const u8,
    group: []const u8,
) !ReplayGroup {
    const stamp = readStamp(allocator, io, venv_path) orelse return .no_record;
    defer stamp.deinit();
    const old_flags = stamp.value.flags;
    var i: usize = 0;
    while (i + 1 < old_flags.len) : (i += 1) {
        if (std.mem.eql(
            u8,
            old_flags[i],
            "--group",
        ) and deps.sameName(old_flags[i + 1], group)) return .already;
    }
    const new_flags = try std.mem.concat(
        allocator,
        []const u8,
        &.{ stamp.value.flags, &.{ "--group", group } },
    );
    defer allocator.free(new_flags);
    try writeStamp(allocator, io, venv_path, stamp.value.hash, new_flags);
    return .added;
}

// ===========================================================================
// The gate
// ===========================================================================

/// Re-invokes `zenv setup <env> --no-host --reuse-module-cache [replay_flags...]`
/// as a captured subprocess with cwd set to the project dir. A rebuild keeps the
/// module cache when the module set is unchanged; only an explicit `zenv setup`
/// re-captures it. The child's output is captured, so the rebuild itself is
/// silent; a one-line `reason` notice and a completion notice go to stderr
/// (see the module comment). Returns
/// `error.AutoSetupFailed` if the child cannot start or exits non-zero. A
/// failure to locate the running binary is non-fatal: we warn and skip rather
/// than break an otherwise-working command.
fn runSetup(
    ctx: Ctx,
    entry: *const Registry.Entry,
    replay_flags: []const []const u8,
    reason: []const u8,
) !void {
    const allocator = ctx.arena;
    const io = ctx.io;
    const self_exe = std.process.executablePathAlloc(io, allocator) catch |err| {
        output.rawErr(io, "WARNING: auto-setup skipped (cannot locate zenv binary: {t})\n", .{err});
        return;
    };
    defer allocator.free(self_exe);

    const argv = try std.mem.concat(
        allocator,
        []const u8,
        &.{
            &.{ self_exe, "setup", entry.env_name, "--no-host", "--reuse-module-cache" },
            replay_flags,
        },
    );
    defer allocator.free(argv);

    // Announced before the (silent, possibly slow) rebuild; only real drift
    // gets here, so a routine activation stays silent.
    output.rawErr(
        io,
        "zenv: rebuilding environment '{s}' ({s}; auto-setup)...\n",
        .{ entry.env_name, reason },
    );

    const res = runtime.run(allocator, io, argv, .{ .cwd = entry.project_dir }) catch |err| {
        output.rawErr(io, "ERROR: auto-setup failed to start: {t}\n", .{err});
        return error.AutoSetupFailed;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (!res.term.success()) {
        // The rebuild ran silently; surface its errors (e.g. what to change in
        // zenv.json) so the user need not open the log for them.
        var lines = std.mem.splitScalar(u8, res.stderr, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "ERROR:")) output.rawErr(io, "{s}\n", .{line});
        }
        output.rawErr(io, "ERROR: auto-setup failed; see {s}/zenv_setup.log\n", .{entry.venv_path});
        return error.AutoSetupFailed;
    }

    output.rawErr(io, "zenv: environment '{s}' is up to date.\n", .{entry.env_name});
}

/// How an env's tracked files compare with its recorded stamp.
const Drift = union(enum) {
    none,
    /// Changed since the stamped build; carries the stamp for its replay flags.
    changed: json.Parsed(Stamp),
    /// No (valid) stamp: built by an older zenv, or the stamp is unreadable.
    unstamped,
};

/// The zenv.json in `project_dir`, parsed and validated WITHOUT printing the
/// validation errors: the gate runs before commands that must keep working
/// while zenv.json is missing or mid-edit. Null when the file is absent;
/// error.InvalidFormat when it does not validate.
fn loadQuiet(allocator: Allocator, io: Io, project_dir: []const u8) !?validation.ProjectFile {
    const config_path = try Io.Dir.path.join(allocator, &.{ project_dir, "zenv.json" });
    defer allocator.free(config_path);
    return validation.load(allocator, io, config_path, .quiet) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// The hash `stamp`'s env would get now, for env `env_name` of the project
/// `file` was loaded from, with the stamp's own replay flags.
fn currentHash(
    allocator: Allocator,
    io: Io,
    project_dir: []const u8,
    env_name: []const u8,
    file: *const validation.ProjectFile,
    stamp: *const Stamp,
) !?[40]u8 {
    const env_cfg = file.project.getEnvironment(env_name) orelse return null;
    const build = try buildOf(allocator, stamp.flags);
    defer allocator.free(build.groups);
    return try hashTracked(allocator, io, project_dir, env_name, env_cfg, file.content, build);
}

/// A removed/broken config, or an env it no longer defines, counts as no drift:
/// it must not block a working venv. A broken one gets a one-line notice.
fn drift(ctx: Ctx, entry: *const Registry.Entry) !Drift {
    const allocator = ctx.arena;
    const io = ctx.io;
    var file = (loadQuiet(allocator, io, entry.project_dir) catch |err| {
        if (err == error.InvalidFormat) {
            output.rawErr(
                io,
                "zenv: {s}/zenv.json is invalid ('zenv validate' shows why); using '{s}' as last built.\n",
                .{ entry.project_dir, entry.env_name },
            );
        }
        return .none;
    }) orelse return .none;
    defer file.deinit(allocator);

    if (file.project.getEnvironment(entry.env_name) == null) return .none;

    // Stamp first: without one, the hash would be computed for nothing.
    const stamp = readStamp(allocator, io, entry.venv_path) orelse return .unstamped;
    errdefer stamp.deinit();
    const current = (try currentHash(
        allocator,
        io,
        entry.project_dir,
        entry.env_name,
        &file,
        &stamp.value,
    )).?;

    if (std.mem.eql(u8, stamp.value.hash, &current)) {
        stamp.deinit();
        return .none;
    }
    return .{ .changed = stamp };
}

/// THE GATE. Call after an environment is resolved and before a command uses its
/// venv. If the env's tracked files differ from the recorded stamp (or no stamp
/// exists yet), silently re-runs setup first. Bypassed entirely when
/// ZENV_NO_AUTO_SETUP is set. Never recurses: `setup` does not go through here.
pub fn ensureUpToDate(ctx: Ctx, entry: *const Registry.Entry) !void {
    if (ctx.getEnv("ZENV_NO_AUTO_SETUP")) |_| return;

    switch (try drift(ctx, entry)) {
        .none => {},
        .changed => |stamp| {
            defer stamp.deinit();
            try runSetup(
                ctx,
                entry,
                stamp.value.flags,
                "configuration or dependency files changed",
            );
        },
        // Force a one-time re-setup with no replayed flags.
        .unstamped => try runSetup(ctx, entry, &.{}, "no build record found"),
    }
}

/// True when the gate would rebuild the env. Never builds: for callers that
/// must stay fast and side-effect free, like `activate --auto` on every cd.
pub fn isStale(ctx: Ctx, entry: *const Registry.Entry) !bool {
    switch (try drift(ctx, entry)) {
        .none => return false,
        .changed => |stamp| {
            stamp.deinit();
            return true;
        },
        .unstamped => return true,
    }
}

// ===========================================================================
// Recording builds
// ===========================================================================

/// A finished `zenv setup`, as the build record keeps it.
pub const Setup = struct {
    /// The project directory, where zenv.json is (setup's cwd).
    project_dir: []const u8,
    env_name: []const u8,
    venv_dir: []const u8,
    /// The zenv.json setup built from.
    file: *const validation.ProjectFile,
    flags: cli.Flags,
    /// The `--group` names.
    groups: []const []const u8,
};

/// Records a finished setup, so run/activate/cd/jupyter can detect config
/// drift later and rebuild with the same flags.
pub fn recordSetup(ctx: Ctx, setup: Setup) !void {
    const allocator = ctx.arena;
    const env_cfg = setup.file.project.getEnvironment(setup.env_name) orelse
        return error.EnvironmentNotFound;
    const hash = try hashTracked(
        allocator,
        ctx.io,
        setup.project_dir,
        setup.env_name,
        env_cfg,
        setup.file.content,
        .{ .groups = setup.groups, .dev = setup.flags.dev_mode },
    );
    const tokens = try setup.flags.buildTokens(allocator, setup.groups);
    defer allocator.free(tokens);
    try writeStamp(allocator, ctx.io, setup.venv_dir, &hash, tokens);
}

/// A change a command makes to an env's tracked files itself, such as `add`
/// recording a package it installed or `rename` renaming the env (the hash
/// covers the name). `begin` it before touching anything. If the env was up
/// to date then, `finish` re-records the build afterwards, so the next gated
/// command does not rebuild what the command already did; a stale env stays
/// stale. `abort` restores the build record instead.
pub const Change = struct {
    /// Up to date at `begin`, and nothing since made a rebuild necessary.
    fresh: bool,
    venv_path: []const u8,
    /// The stamp file as it was at `begin`; null when there was none.
    saved: ?[]const u8,

    /// Starts a change to `entry`'s tracked files. Allocates with `ctx.arena`.
    pub fn begin(ctx: Ctx, entry: *const Registry.Entry) !Change {
        const path = try stampPath(ctx.arena, entry.venv_path);
        return .{
            .fresh = !(isStale(ctx, entry) catch true),
            .venv_path = try ctx.arena.dupe(u8, entry.venv_path),
            .saved = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1024 * 1024)) catch null,
        };
    }

    /// Has rebuilds install dependency group `group` too, as `add` needs after
    /// recording a package in it. False when the env has no build record (its
    /// next rebuild replays nothing); true when the group was replayed already
    /// or now is. A group new to the build has packages the env never got, so
    /// the env is left stale for the next gated command to install them.
    pub fn replayGroup(self: *Change, ctx: Ctx, group: []const u8) bool {
        const result = addReplayGroup(ctx.arena, ctx.io, self.venv_path, group) catch return false;
        if (result == .added) self.fresh = false;
        return result != .no_record;
    }

    /// Ends the change. `project_dir`, `env_name` and `venv_path` are the env's
    /// after it (`rename` moves the env). Best effort: a build record that
    /// cannot be renewed only costs a rebuild.
    pub fn finish(
        self: *const Change,
        ctx: Ctx,
        project_dir: []const u8,
        env_name: []const u8,
        venv_path: []const u8,
    ) void {
        if (self.fresh) rehash(ctx, project_dir, env_name, venv_path) catch {};
    }

    /// Puts the build record back as it was at `begin`.
    pub fn abort(self: *const Change, ctx: Ctx) void {
        const path = stampPath(ctx.arena, self.venv_path) catch return;
        if (self.saved) |data| {
            Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = data }) catch {};
        } else Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
    }
};

/// Re-records the build stamp's hash for the env's current files, keeping its
/// replay flags. Does nothing when the env has no stamp, or zenv.json is
/// missing, invalid or lacks the env.
fn rehash(
    ctx: Ctx,
    project_dir: []const u8,
    env_name: []const u8,
    venv_path: []const u8,
) !void {
    const allocator = ctx.arena;
    const io = ctx.io;
    var file = (loadQuiet(allocator, io, project_dir) catch return) orelse return;
    defer file.deinit(allocator);
    const stamp = readStamp(allocator, io, venv_path) orelse return;
    defer stamp.deinit();
    const hash = (try currentHash(allocator, io, project_dir, env_name, &file, &stamp.value)) orelse return;
    try writeStamp(allocator, io, venv_path, &hash, stamp.value.flags);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const test_support = @import("test_support.zig");

const test_config_a =
    \\{
    \\  "base_dir": ".zenv",
    \\  "zenv-test": { "target_machines": ["*"], "dependencies": [] }
    \\}
;
const test_config_b =
    \\{
    \\  "base_dir": ".zenv",
    \\  "zenv-test": { "target_machines": ["*"], "dependencies": ["numpy"] }
    \\}
;

/// Recording fake backend for gate tests: notes whether a subprocess was spawned,
/// whether it asked setup to reuse the module cache, and what exit code to report.
var test_spawned: bool = false;
var test_reuse_module_cache: bool = false;
var test_run_exit: u8 = 0;

fn recordingRun(
    allocator: Allocator,
    _: Io,
    argv: []const []const u8,
    _: runtime.RunOptions,
) anyerror!runtime.RunResult {
    test_spawned = true;
    test_reuse_module_cache = cli.Flags.parse(argv).reuse_module_cache;
    return .{
        .term = .{ .exited = test_run_exit },
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn recordingExec(_: Io, _: []const []const u8, _: runtime.ExecOptions) anyerror!runtime.Term {
    return .{ .exited = 0 };
}

/// The hash of env `env_name` in `dir`/zenv.json, built without `--group`
/// or `--dev`.
fn computeTrackedHash(
    allocator: Allocator,
    io: Io,
    dir: []const u8,
    env_name: []const u8,
    env_config: *const config.Env,
) ![40]u8 {
    const path = try Io.Dir.path.join(allocator, &.{ dir, "zenv.json" });
    defer allocator.free(path);
    const content = readTracked(allocator, io, path);
    defer if (content) |c| allocator.free(c) else |_| {};
    return hashTracked(allocator, io, dir, env_name, env_config, content, .{});
}

/// An empty, absolute scratch directory (tracked paths are anchored at it).
fn testDir(allocator: Allocator, name: []const u8) ![]u8 {
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const base = try cwd.realPathFileAlloc(io, ".zig-cache", allocator);
    defer allocator.free(base);
    const dir = try Io.Dir.path.join(allocator, &.{ base, "tmp", "zenv_autosetup_test", name });
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    return dir;
}

fn cleanup(allocator: Allocator, dir: []u8) void {
    Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    allocator.free(dir);
}

fn writeAt(allocator: Allocator, dir: []const u8, name: []const u8, content: []const u8) !void {
    const p = try Io.Dir.path.join(allocator, &.{ dir, name });
    defer allocator.free(p);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = content });
}

fn makeEntry(
    allocator: Allocator,
    name: []const u8,
    project_dir: []const u8,
    venv_path: []const u8,
) !Registry.Entry {
    return Registry.Entry{
        .id = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
        .env_name = try allocator.dupe(u8, name),
        .project_dir = try allocator.dupe(u8, project_dir),
        .description = null,
        .target_machines_str = try allocator.dupe(u8, "*"),
        .venv_path = try allocator.dupe(u8, venv_path),
        .aliases = .empty,
    };
}

test "computeTrackedHash is deterministic and content-sensitive" {
    const a = testing.allocator;
    const dir = try testDir(a, "ch1");
    defer cleanup(a, dir);
    try writeAt(a, dir, "zenv.json", test_config_a);

    var env_cfg = config.Env.init(a);
    defer env_cfg.deinit();

    const h1 = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);
    const h2 = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);
    try testing.expectEqualStrings(h1, h2); // deterministic (no timestamp)
    try testing.expectEqual(@as(usize, 40), h1.len);

    try writeAt(a, dir, "zenv.json", test_config_b);
    const h3 = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);
    try testing.expect(!std.mem.eql(u8, h1, h3)); // content change flips the hash

    // Adding or editing a different env in the same file leaves it alone.
    try writeAt(a, dir, "zenv.json",
        \\{
        \\  "base_dir": ".zenv",
        \\  "zenv-test": { "target_machines": ["*"], "dependencies": ["numpy"] },
        \\  "other": { "target_machines": ["*"], "modules": ["gcc"] }
        \\}
    );
    const h4 = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);
    try testing.expectEqualStrings(h3, h4);

    // So does a comment: only values count.
    try writeAt(a, dir, "zenv.json",
        \\{
        \\  "base_dir": ".zenv", // where envs live
        \\  /* the test env */
        \\  "zenv-test": { "target_machines": ["*"], "dependencies": ["numpy"] },
        \\  "other": { "target_machines": ["*"], "modules": ["gcc"] }
        \\}
    );
    const h5 = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);
    try testing.expectEqualStrings(h3, h5);
}

test "computeTrackedHash tracks dependency_file presence" {
    const a = testing.allocator;
    const dir = try testDir(a, "ch2");
    defer cleanup(a, dir);
    try writeAt(a, dir, "zenv.json", test_config_a);

    var env_cfg = config.Env.init(a);
    defer env_cfg.deinit();
    env_cfg.dependency_file = try a.dupe(u8, "requirements.txt");

    const h_absent = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);

    try writeAt(a, dir, "requirements.txt", "numpy\n");
    const h_present = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);

    try testing.expect(!std.mem.eql(u8, h_absent, h_present));
}

test "computeTrackedHash tracks a container image file" {
    const a = testing.allocator;
    const dir = try testDir(a, "ch-image");
    defer cleanup(a, dir);
    try writeAt(a, dir, "zenv.json", test_config_a);

    var env_cfg = config.Env.init(a);
    defer env_cfg.deinit();
    env_cfg.container = .{ .image = try a.dupe(u8, "py.sif") };

    const h_absent = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);
    try writeAt(a, dir, "py.sif", "image v1");
    const h_v1 = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);
    try writeAt(a, dir, "py.sif", "image v2, re-pulled");
    const h_v2 = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);

    try testing.expect(!std.mem.eql(u8, h_absent, h_v1));
    try testing.expect(!std.mem.eql(u8, h_v1, h_v2));
    try testing.expectEqualSlices(
        u8,
        h_v2,
        &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg),
    );
}

test "computeTrackedHash format is stable" {
    // Pins the digest: a format change rebuilds every existing env once.
    const a = testing.allocator;
    const dir = try testDir(a, "ch3");
    defer cleanup(a, dir);
    try writeAt(a, dir, "zenv.json", test_config_b);
    try writeAt(a, dir, "requirements.txt", "numpy\n");
    try writeAt(a, dir, "setup.sh", "echo hi\n");

    var env_cfg = config.Env.init(a);
    defer env_cfg.deinit();
    env_cfg.dependency_file = try a.dupe(u8, "requirements.txt");
    env_cfg.modules_file = try a.dupe(u8, "modules.txt"); // absent
    env_cfg.setup = .{ .script = try Io.Dir.path.join(a, &.{ dir, "setup.sh" }) }; // absolute

    const h = &try computeTrackedHash(a, testing.io, dir, "zenv-test", &env_cfg);
    try testing.expectEqualStrings("ad1f98e6f973b6566a7791da680347e8d7a499d0", h);
}

test "stamp round-trips and tolerates bad input" {
    const a = testing.allocator;
    const dir = try testDir(a, "stamp");
    defer cleanup(a, dir);

    const in_flags = [_][]const u8{ "--uv", "--no-cache" };
    try writeStamp(a, testing.io, dir, "deadbeef", &in_flags);

    const got = readStamp(a, testing.io, dir).?;
    defer got.deinit();
    try testing.expectEqualStrings("deadbeef", got.value.hash);
    try testing.expectEqual(@as(usize, 2), got.value.flags.len);
    try testing.expectEqualStrings("--uv", got.value.flags[0]);
    try testing.expectEqualStrings("--no-cache", got.value.flags[1]);

    const empty = try testDir(a, "stamp_empty");
    defer cleanup(a, empty);
    try testing.expect(readStamp(a, testing.io, empty) == null); // absent

    try writeAt(a, empty, stamp_name, "not json {");
    try testing.expect(readStamp(a, testing.io, empty) == null); // malformed

    try writeAt(a, empty, stamp_name, "{\"version\":999,\"hash\":\"x\",\"flags\":[]}");
    try testing.expect(readStamp(a, testing.io, empty) == null); // wrong version

    try writeAt(a, empty, stamp_name, "{\"version\":1,\"hash\":\"x\"}");
    const no_flags = readStamp(a, testing.io, empty).?; // flags are optional
    defer no_flags.deinit();
    try testing.expectEqual(@as(usize, 0), no_flags.value.flags.len);
}

test "addReplayGroup appends a group once and keeps the hash" {
    const a = testing.allocator;
    const dir = try testDir(a, "replaygroup");
    defer cleanup(a, dir);

    try testing.expectEqual(ReplayGroup.no_record, try addReplayGroup(a, testing.io, dir, "demo"));
    try writeStamp(a, testing.io, dir, "deadbeef", &.{ "--uv", "--group", "dev" });
    try testing.expectEqual(ReplayGroup.already, try addReplayGroup(a, testing.io, dir, "Dev")); // normalized
    try testing.expectEqual(ReplayGroup.added, try addReplayGroup(a, testing.io, dir, "demo"));

    const got = readStamp(a, testing.io, dir).?;
    defer got.deinit();
    try testing.expectEqualStrings("deadbeef", got.value.hash);
    try testing.expectEqual(@as(usize, 5), got.value.flags.len);
    try testing.expectEqualStrings("--group", got.value.flags[3]);
    try testing.expectEqualStrings("demo", got.value.flags[4]);

    try writeStamp(a, testing.io, dir, "deadbeef", &.{}); // a stamp without flags
    try testing.expectEqual(ReplayGroup.added, try addReplayGroup(a, testing.io, dir, "demo"));
    const only = readStamp(a, testing.io, dir).?;
    defer only.deinit();
    try testing.expectEqual(@as(usize, 2), only.value.flags.len);
}

test "ensureUpToDate: no-op on match, re-setup on drift, error on failure" {
    const a = testing.allocator;
    const prev = runtime.exec_backend;
    runtime.exec_backend = .{ .run = recordingRun, .exec = recordingExec };
    defer runtime.exec_backend = prev;

    const proj = try testDir(a, "gate_proj");
    defer cleanup(a, proj);
    try writeAt(a, proj, "zenv.json", test_config_a);

    const venv = try testDir(a, "gate_venv");
    defer cleanup(a, venv);

    var entry = try makeEntry(a, "zenv-test", proj, venv);
    defer entry.deinit(a);

    // Record a stamp matching the current config.
    {
        const cfg_path = try Io.Dir.path.join(a, &.{ proj, "zenv.json" });
        defer a.free(cfg_path);
        var file = try validation.load(a, testing.io, cfg_path, .quiet);
        defer file.deinit(a);
        const env_cfg = file.project.getEnvironment("zenv-test").?;
        const h = &try computeTrackedHash(a, testing.io, proj, "zenv-test", env_cfg);
        try writeStamp(a, testing.io, venv, h, &.{});
    }

    const ctx = test_support.ctx(a, &test_support.no_env);
    test_spawned = false;
    try ensureUpToDate(ctx, &entry);
    try testing.expect(!test_spawned); // up to date -> no spawn

    // Drift: change the config so the hash no longer matches the stamp.
    try writeAt(a, proj, "zenv.json", test_config_b);
    test_spawned = false;
    test_run_exit = 0;
    try ensureUpToDate(ctx, &entry);
    try testing.expect(test_spawned); // drift -> spawned setup
    try testing.expect(test_reuse_module_cache); // a rebuild keeps an unchanged module cache

    // Child setup fails -> AutoSetupFailed (stamp still stale).
    test_spawned = false;
    test_run_exit = 1;
    try testing.expectError(error.AutoSetupFailed, ensureUpToDate(ctx, &entry));
}

test "ensureUpToDate respects ZENV_NO_AUTO_SETUP" {
    const a = testing.allocator;
    const prev = runtime.exec_backend;
    runtime.exec_backend = .{ .run = recordingRun, .exec = recordingExec };
    defer runtime.exec_backend = prev;

    var optout = std.process.Environ.Map.init(a);
    defer optout.deinit();
    try optout.put("ZENV_NO_AUTO_SETUP", "1");

    var entry = try makeEntry(a, "x", "/no/such/proj", "/no/such/venv");
    defer entry.deinit(a);

    test_spawned = false;
    try ensureUpToDate(test_support.ctx(a, &optout), &entry);
    try testing.expect(!test_spawned); // opt-out short-circuits before any work
}

test "isStale reports drift without spawning setup" {
    const a = testing.allocator;
    const prev = runtime.exec_backend;
    runtime.exec_backend = .{ .run = recordingRun, .exec = recordingExec };
    defer runtime.exec_backend = prev;

    const proj = try testDir(a, "stale_proj");
    defer cleanup(a, proj);
    try writeAt(a, proj, "zenv.json", test_config_a);

    const venv = try testDir(a, "stale_venv");
    defer cleanup(a, venv);

    var entry = try makeEntry(a, "zenv-test", proj, venv);
    defer entry.deinit(a);

    const ctx = test_support.ctx(a, &test_support.no_env);
    test_spawned = false;
    try testing.expect(try isStale(ctx, &entry)); // no stamp yet

    {
        const cfg_path = try Io.Dir.path.join(a, &.{ proj, "zenv.json" });
        defer a.free(cfg_path);
        var file = try validation.load(a, testing.io, cfg_path, .quiet);
        defer file.deinit(a);
        const h = &try computeTrackedHash(
            a,
            testing.io,
            proj,
            "zenv-test",
            file.project.getEnvironment("zenv-test").?,
        );
        try writeStamp(a, testing.io, venv, h, &.{});
    }
    try testing.expect(!try isStale(ctx, &entry)); // stamp matches

    try writeAt(a, proj, "zenv.json", test_config_b);
    try testing.expect(try isStale(ctx, &entry)); // config drifted
    try testing.expect(!test_spawned);
}

test "the gate watches ./pyproject.toml for replayed groups, not otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const proj = try testDir(a, "groups_proj");
    defer Io.Dir.cwd().deleteTree(io, proj) catch {};
    const venv = try testDir(a, "groups_venv");
    defer Io.Dir.cwd().deleteTree(io, venv) catch {};
    try writeAt(a, proj, "zenv.json",
        \\{ "zenv-test": { "target_machines": ["*"], "dependency_file": "r.txt" } }
    );
    try writeAt(a, proj, "r.txt", "six\n");
    try writeAt(a, proj, "pyproject.toml", "[dependency-groups]\ndemo = [\"idna\"]\n");

    var entry = try makeEntry(a, "zenv-test", proj, venv);
    const ctx = test_support.ctx(a, &test_support.no_env);
    const path = try Io.Dir.path.join(a, &.{ proj, "zenv.json" });
    var file = try validation.load(a, io, path, .quiet);

    // Built without groups: editing ./pyproject.toml is not drift.
    try recordSetup(ctx, .{
        .project_dir = proj,
        .env_name = "zenv-test",
        .venv_dir = venv,
        .file = &file,
        .flags = .{ .use_uv = true },
        .groups = &.{},
    });
    try writeAt(a, proj, "pyproject.toml", "[dependency-groups]\ndemo = [\"idna\", \"attrs\"]\n");
    try testing.expect(!try isStale(ctx, &entry));

    // Built with --group demo: it is.
    try recordSetup(ctx, .{
        .project_dir = proj,
        .env_name = "zenv-test",
        .venv_dir = venv,
        .file = &file,
        .flags = .{ .use_uv = true },
        .groups = &.{"demo"},
    });
    try testing.expect(!try isStale(ctx, &entry));
    try writeAt(a, proj, "pyproject.toml", "[dependency-groups]\ndemo = [\"idna\"]\n");
    try testing.expect(try isStale(ctx, &entry));
    try testing.expect(builtWith(a, io, venv).use_uv);
    _ = &entry;
}

test "Change keeps a fresh env fresh, leaves a stale one stale, and aborts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const proj = try testDir(a, "change_proj");
    defer Io.Dir.cwd().deleteTree(io, proj) catch {};
    const venv = try testDir(a, "change_venv");
    defer Io.Dir.cwd().deleteTree(io, venv) catch {};
    try writeAt(a, proj, "zenv.json", test_config_a);
    var entry = try makeEntry(a, "zenv-test", proj, venv);
    const ctx = test_support.ctx(a, &test_support.no_env);
    var file = try validation.load(a, io, try Io.Dir.path.join(a, &.{ proj, "zenv.json" }), .quiet);
    try recordSetup(ctx, .{
        .project_dir = proj,
        .env_name = "zenv-test",
        .venv_dir = venv,
        .file = &file,
        .flags = .{},
        .groups = &.{},
    });

    // Fresh: the change is absorbed.
    var change = try Change.begin(ctx, &entry);
    try writeAt(a, proj, "zenv.json", test_config_b);
    change.finish(ctx, proj, "zenv-test", venv);
    try testing.expect(!try isStale(ctx, &entry));

    // A group new to the build was never installed: the env stays stale.
    change = try Change.begin(ctx, &entry);
    try testing.expect(change.replayGroup(ctx, "demo"));
    change.finish(ctx, proj, "zenv-test", venv);
    try testing.expect(try isStale(ctx, &entry));
    try testing.expectEqual(@as(usize, 2), (readStamp(a, io, venv).?).value.flags.len);
    file = try validation.load(a, io, try Io.Dir.path.join(a, &.{ proj, "zenv.json" }), .quiet);
    try recordSetup(ctx, .{
        .project_dir = proj,
        .env_name = "zenv-test",
        .venv_dir = venv,
        .file = &file,
        .flags = .{},
        .groups = &.{"demo"},
    });
    // A group the build already installs keeps it fresh.
    change = try Change.begin(ctx, &entry);
    try testing.expect(change.replayGroup(ctx, "demo"));
    change.finish(ctx, proj, "zenv-test", venv);
    try testing.expect(!try isStale(ctx, &entry));

    // Stale before: still stale after.
    try writeAt(a, proj, "zenv.json", test_config_a);
    change = try Change.begin(ctx, &entry);
    change.finish(ctx, proj, "zenv-test", venv);
    try testing.expect(try isStale(ctx, &entry));

    // Abort restores the record, and removes one that did not exist.
    change = try Change.begin(ctx, &entry);
    try writeStamp(a, io, venv, "other", &.{});
    change.abort(ctx);
    try testing.expectEqualStrings(change.saved.?, try Io.Dir.cwd().readFileAlloc(
        io,
        try stampPath(a, venv),
        a,
        .limited(1024 * 1024),
    ));
    Io.Dir.cwd().deleteFile(io, try stampPath(a, venv)) catch {};
    change = try Change.begin(ctx, &entry);
    try writeStamp(a, io, venv, "other", &.{});
    change.abort(ctx);
    try testing.expect(readStamp(a, io, venv) == null);
    _ = &entry;
}
