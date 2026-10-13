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

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const runtime = @import("runtime.zig");
const paths = @import("paths.zig");
const config = @import("config.zig");
const validation = @import("validation.zig");
const output = @import("output.zig");
const flags = @import("flags.zig");

const STAMP_NAME = ".zenv.stamp";
const STAMP_VERSION = 1;
const MAX_TRACKED_FILE = 10 * 1024 * 1024;

// ===========================================================================
// Tracked-file checksum
// ===========================================================================

/// Folds one tracked file into `sha`. The logical `key` and a content-length
/// separator are mixed in so that adding/removing/renaming a tracked file, or a
/// content boundary shift between adjacent files, all change the digest. A
/// missing or unreadable file is folded as a marker rather than erroring, so the
/// hash stays well-defined even when e.g. a configured dependency_file is absent.
fn foldFile(allocator: Allocator, sha: *std.crypto.hash.Sha1, key: []const u8, path: []const u8) void {
    sha.update(key);
    sha.update("\x00");
    const content = runtime.readFileAlloc(allocator, path, MAX_TRACKED_FILE) catch |err| {
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

/// Folds the part of zenv.json that concerns `env_name`: `base_dir` and the
/// env's own object, re-serialized. Editing another env in the same file then
/// leaves this env's hash alone. A file that does not parse is folded whole.
fn foldEnvConfig(allocator: Allocator, sha: *std.crypto.hash.Sha1, path: []const u8, env_name: []const u8) void {
    sha.update("config\x00");
    const content = runtime.readFileAlloc(allocator, path, MAX_TRACKED_FILE) catch |err| {
        sha.update(if (err == error.FileNotFound) "A\x00" else "E\x00");
        return;
    };
    defer allocator.free(content);
    const parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch return foldBytes(sha, content);
    defer parsed.deinit();
    if (parsed.value != .object) return foldBytes(sha, content);
    for ([_][]const u8{ "base_dir", env_name }) |key| {
        sha.update(key);
        sha.update("\x00");
        const value = parsed.value.object.get(key) orelse {
            sha.update("A\x00");
            continue;
        };
        const text = json.Stringify.valueAlloc(allocator, value, .{}) catch return foldBytes(sha, content);
        defer allocator.free(text);
        foldBytes(sha, text);
    }
}

/// Lowercase-hex SHA-1 over what `env_name` is built from, in a fixed order:
/// its part of zenv.json (always), then dependency_file, modules_file and
/// setup.script when configured. `anchor_dir` is the setup cwd when recording the stamp and the
/// entry's project_dir when checking — these are the same directory, which is
/// what makes the two call sites agree. Caller owns the returned slice.
pub fn computeTrackedHash(
    allocator: Allocator,
    anchor_dir: []const u8,
    env_name: []const u8,
    env_config: *const config.EnvironmentConfig,
) ![]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});

    {
        const p = try std.Io.Dir.path.join(allocator, &[_][]const u8{ anchor_dir, "zenv.json" });
        defer allocator.free(p);
        foldEnvConfig(allocator, &sha, p, env_name);
    }
    const setup_script = if (env_config.setup) |s| s.script else null;
    const tracked = [_]struct { []const u8, ?[]const u8 }{
        .{ "deps", env_config.dependency_file },
        .{ "modules", env_config.modules_file },
        .{ "setup_script", setup_script },
    };
    for (tracked) |t| {
        const rel = t[1] orelse continue;
        const p = try paths.resolvePath(allocator, anchor_dir, rel);
        defer allocator.free(p);
        foldFile(allocator, &sha, t[0], p);
    }

    var digest: [20]u8 = undefined;
    sha.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

// ===========================================================================
// Stamp file
// ===========================================================================

/// The stamp file's contents. `readStamp` returns it parsed.
pub const Stamp = struct {
    version: u32,
    hash: []const u8,
    flags: []const []const u8 = &.{},
};

fn stampPath(allocator: Allocator, venv_dir: []const u8) ![]u8 {
    return std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_dir, STAMP_NAME });
}

/// Writes `<venv_dir>/.zenv.stamp` atomically. `flags` are the build-affecting
/// setup flags to replay on a future auto-setup.
pub fn writeStamp(allocator: Allocator, venv_dir: []const u8, hash: []const u8, build_flags: []const []const u8) !void {
    const path = try stampPath(allocator, venv_dir);
    defer allocator.free(path);

    const stamp = Stamp{ .version = STAMP_VERSION, .hash = hash, .flags = build_flags };
    const text = try std.json.Stringify.valueAlloc(allocator, stamp, .{ .whitespace = .indent_2 });
    defer allocator.free(text);

    try runtime.writeFileAtomic(allocator, path, text);
}

/// Reads `<venv_dir>/.zenv.stamp`. Returns null (never errors) when the stamp is
/// absent, unreadable, malformed, or a different format version — every such
/// case means "treat as changed" and force a re-setup. Caller must `deinit`.
pub fn readStamp(allocator: Allocator, venv_dir: []const u8) ?json.Parsed(Stamp) {
    const path = stampPath(allocator, venv_dir) catch return null;
    defer allocator.free(path);

    const content = runtime.readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = json.parseFromSlice(Stamp, allocator, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    if (parsed.value.version != STAMP_VERSION) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

// ===========================================================================
// Flag replay
// ===========================================================================

/// Canonical tokens for the build-affecting flags of a setup invocation, to be
/// replayed on a future auto-setup. Excludes `--no-host` (the gate always
/// re-adds it), `--init` and `--no-python` (one-time bootstrap: zenv.json
/// then records the choice) and `--jupyter` (the kernel
/// already targets the unchanged venv). Items are static literals — the caller
/// frees only the returned slice.
pub fn flagTokens(allocator: Allocator, f: flags.CommandFlags) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    if (f.force_deps) try list.append(allocator, "--force");
    if (f.use_default_python) try list.append(allocator, "--python");
    if (f.dev_mode) try list.append(allocator, "--dev");
    if (f.use_uv) try list.append(allocator, "--uv");
    if (f.no_cache) try list.append(allocator, "--no-cache");
    return list.toOwnedSlice(allocator);
}

// ===========================================================================
// The gate
// ===========================================================================

/// Re-invokes `zenv setup <env> --no-host [replay_flags...]` as a captured
/// subprocess with cwd set to the project dir. The child's stdout/stderr are
/// captured (not inherited), so the rebuild itself is silent; we bracket it with
/// a one-line `reason` notice and a completion notice on STDERR so the user knows
/// a rebuild happened. stderr is used deliberately: `activate`/`cd` emit their
/// shell-eval payload on stdout (which the shell captures), so a stderr notice is
/// visible without corrupting `source $(zenv activate ...)`. Returns
/// `error.AutoSetupFailed` if the child cannot start or exits non-zero. A
/// failure to locate the running binary is non-fatal: we warn and skip rather
/// than break an otherwise-working command.
fn runSetup(allocator: Allocator, entry: *const config.RegistryEntry, replay_flags: []const []const u8, reason: []const u8) !void {
    const self_exe = runtime.selfExePath(allocator) catch |err| {
        output.rawErr(allocator, "WARNING: auto-setup skipped (cannot locate zenv binary: {s})\n", .{@errorName(err)}) catch {};
        return;
    };
    defer allocator.free(self_exe);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &[_][]const u8{ self_exe, "setup", entry.env_name, "--no-host" });
    try argv.appendSlice(allocator, replay_flags);

    // Announce on STDERR before the (silent, possibly slow) rebuild. stderr is
    // safe for every caller: `activate`/`cd` put their shell-eval payload on
    // stdout, which the shell captures, while stderr flows to the terminal — so
    // the user learns a rebuild happened without the notice corrupting
    // `source $(zenv activate ...)`. The notice only fires on real drift, so a
    // routine activation that changed nothing stays silent.
    output.rawErr(allocator, "zenv: rebuilding environment '{s}' ({s}; auto-setup)...\n", .{ entry.env_name, reason }) catch {};

    const res = runtime.run(allocator, argv.items, .{ .cwd = entry.project_dir }) catch |err| {
        output.rawErr(allocator, "ERROR: auto-setup failed to start: {s}\n", .{@errorName(err)}) catch {};
        return error.AutoSetupFailed;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (!runtime.exitedOk(res.term)) {
        // The rebuild ran silently; surface its errors (e.g. what to change in
        // zenv.json) so the user need not open the log for them.
        var lines = std.mem.splitScalar(u8, res.stderr, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "ERROR:")) output.rawErr(allocator, "{s}\n", .{line}) catch {};
        }
        output.rawErr(allocator, "ERROR: auto-setup failed; see {s}/zenv_setup.log\n", .{entry.venv_path}) catch {};
        return error.AutoSetupFailed;
    }

    output.rawErr(allocator, "zenv: environment '{s}' is up to date.\n", .{entry.env_name}) catch {};
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
/// error.ConfigInvalid when it does not validate.
fn loadConfigQuiet(allocator: Allocator, project_dir: []const u8) !?config.ZenvConfig {
    const config_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ project_dir, "zenv.json" });
    defer allocator.free(config_path);
    const content = runtime.readFileAlloc(allocator, config_path, MAX_TRACKED_FILE) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);
    switch (try validation.loadConfig(allocator, content)) {
        .config => |c| return c,
        .errors => |errs| {
            var list = errs;
            validation.freeErrors(allocator, &list);
            return error.ConfigInvalid;
        },
    }
}

/// A removed/broken config, or an env it no longer defines, counts as no drift:
/// it must not block a working venv. A broken one gets a one-line notice.
fn drift(allocator: Allocator, entry: *const config.RegistryEntry) !Drift {
    var cfg = (loadConfigQuiet(allocator, entry.project_dir) catch |err| {
        if (err == error.ConfigInvalid) {
            output.rawErr(allocator, "zenv: {s}/zenv.json is invalid ('zenv validate' shows why); using '{s}' as last built.\n", .{ entry.project_dir, entry.env_name }) catch {};
        }
        return .none;
    }) orelse return .none;
    defer cfg.deinit();

    const env_cfg = cfg.getEnvironment(entry.env_name) orelse return .none;

    // Stamp first: without one, the hash would be computed for nothing.
    const stamp = readStamp(allocator, entry.venv_path) orelse return .unstamped;
    errdefer stamp.deinit();
    const current = try computeTrackedHash(allocator, entry.project_dir, entry.env_name, env_cfg);
    defer allocator.free(current);

    if (std.mem.eql(u8, stamp.value.hash, current)) {
        stamp.deinit();
        return .none;
    }
    return .{ .changed = stamp };
}

/// THE GATE. Call after an environment is resolved and before a command uses its
/// venv. If the env's tracked files differ from the recorded stamp (or no stamp
/// exists yet), silently re-runs setup first. Bypassed entirely when
/// ZENV_NO_AUTO_SETUP is set. Never recurses: `setup` does not go through here.
pub fn ensureUpToDate(allocator: Allocator, entry: *const config.RegistryEntry) !void {
    if (runtime.env("ZENV_NO_AUTO_SETUP")) |_| return;

    switch (try drift(allocator, entry)) {
        .none => {},
        .changed => |stamp| {
            defer stamp.deinit();
            try runSetup(allocator, entry, stamp.value.flags, "configuration or dependency files changed");
        },
        // Force a one-time re-setup with no replayed flags.
        .unstamped => try runSetup(allocator, entry, &[_][]const u8{}, "no build record found"),
    }
}

/// Re-records the build stamp after a command changed an up-to-date env's
/// tracked files itself (`add` recording a package it already installed,
/// `rename` renaming the env), so the next gated command does not rebuild what
/// is already done. Keeps the stamp's replay flags. Does nothing when the env
/// has no stamp, or zenv.json is missing, invalid or lacks the env.
pub fn restamp(allocator: Allocator, project_dir: []const u8, env_name: []const u8, venv_path: []const u8) !void {
    var cfg = (loadConfigQuiet(allocator, project_dir) catch return) orelse return;
    defer cfg.deinit();
    const env_cfg = cfg.getEnvironment(env_name) orelse return;
    const stamp = readStamp(allocator, venv_path) orelse return;
    defer stamp.deinit();

    const hash = try computeTrackedHash(allocator, project_dir, env_name, env_cfg);
    defer allocator.free(hash);
    try writeStamp(allocator, venv_path, hash, stamp.value.flags);
}

/// True when the gate would rebuild the env. Never builds: for callers that
/// must stay fast and side-effect free, like `activate --auto` on every cd.
pub fn isStale(allocator: Allocator, entry: *const config.RegistryEntry) !bool {
    switch (try drift(allocator, entry)) {
        .none => return false,
        .changed => |stamp| {
            stamp.deinit();
            return true;
        },
        .unstamped => return true,
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const test_support = @import("../test_support.zig");

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

// Recording fake backend for gate tests: notes whether a subprocess was spawned
// and what exit code to report.
var test_spawned: bool = false;
var test_run_exit: u8 = 0;

fn recordingRun(allocator: Allocator, argv: []const []const u8, opts: runtime.RunOptions) anyerror!runtime.RunResult {
    _ = argv;
    _ = opts;
    test_spawned = true;
    return .{
        .term = .{ .exited = test_run_exit },
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn recordingExec(argv: []const []const u8, opts: runtime.ExecOptions) anyerror!runtime.Term {
    _ = argv;
    _ = opts;
    return .{ .exited = 0 };
}

fn testDir(allocator: Allocator, name: []const u8) ![]u8 {
    const base = runtime.env("TMPDIR") orelse "/tmp";
    const dir = try std.Io.Dir.path.join(allocator, &[_][]const u8{ base, "zenv_autosetup_test", name });
    runtime.deleteTree(dir) catch {};
    try runtime.makePath(dir);
    return dir;
}

fn cleanup(allocator: Allocator, dir: []u8) void {
    runtime.deleteTree(dir) catch {};
    allocator.free(dir);
}

fn writeAt(allocator: Allocator, dir: []const u8, name: []const u8, content: []const u8) !void {
    const p = try std.Io.Dir.path.join(allocator, &[_][]const u8{ dir, name });
    defer allocator.free(p);
    try runtime.writeFile(p, content);
}

fn makeEntry(allocator: Allocator, name: []const u8, project_dir: []const u8, venv_path: []const u8) !config.RegistryEntry {
    return config.RegistryEntry{
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
    test_support.setupRuntime();
    const a = testing.allocator;
    const dir = try testDir(a, "ch1");
    defer cleanup(a, dir);
    try writeAt(a, dir, "zenv.json", test_config_a);

    var env_cfg = config.EnvironmentConfig.init(a);
    defer env_cfg.deinit();

    const h1 = try computeTrackedHash(a, dir, "zenv-test", &env_cfg);
    defer a.free(h1);
    const h2 = try computeTrackedHash(a, dir, "zenv-test", &env_cfg);
    defer a.free(h2);
    try testing.expectEqualStrings(h1, h2); // deterministic (no timestamp)
    try testing.expectEqual(@as(usize, 40), h1.len);

    try writeAt(a, dir, "zenv.json", test_config_b);
    const h3 = try computeTrackedHash(a, dir, "zenv-test", &env_cfg);
    defer a.free(h3);
    try testing.expect(!std.mem.eql(u8, h1, h3)); // content change flips the hash

    // Adding or editing a different env in the same file leaves it alone.
    try writeAt(a, dir, "zenv.json",
        \\{
        \\  "base_dir": ".zenv",
        \\  "zenv-test": { "target_machines": ["*"], "dependencies": ["numpy"] },
        \\  "other": { "target_machines": ["*"], "modules": ["gcc"] }
        \\}
    );
    const h4 = try computeTrackedHash(a, dir, "zenv-test", &env_cfg);
    defer a.free(h4);
    try testing.expectEqualStrings(h3, h4);
}

test "computeTrackedHash tracks dependency_file presence" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const dir = try testDir(a, "ch2");
    defer cleanup(a, dir);
    try writeAt(a, dir, "zenv.json", test_config_a);

    var env_cfg = config.EnvironmentConfig.init(a);
    defer env_cfg.deinit();
    env_cfg.dependency_file = try a.dupe(u8, "requirements.txt");

    const h_absent = try computeTrackedHash(a, dir, "zenv-test", &env_cfg);
    defer a.free(h_absent);

    try writeAt(a, dir, "requirements.txt", "numpy\n");
    const h_present = try computeTrackedHash(a, dir, "zenv-test", &env_cfg);
    defer a.free(h_present);

    try testing.expect(!std.mem.eql(u8, h_absent, h_present));
}

test "computeTrackedHash format is stable" {
    // Pins the digest: a format change rebuilds every existing env once.
    test_support.setupRuntime();
    const a = testing.allocator;
    const dir = try testDir(a, "ch3");
    defer cleanup(a, dir);
    try writeAt(a, dir, "zenv.json", test_config_b);
    try writeAt(a, dir, "requirements.txt", "numpy\n");
    try writeAt(a, dir, "setup.sh", "echo hi\n");

    var env_cfg = config.EnvironmentConfig.init(a);
    defer env_cfg.deinit();
    env_cfg.dependency_file = try a.dupe(u8, "requirements.txt");
    env_cfg.modules_file = try a.dupe(u8, "modules.txt"); // absent
    env_cfg.setup = .{ .script = try std.Io.Dir.path.join(a, &[_][]const u8{ dir, "setup.sh" }) }; // absolute

    const h = try computeTrackedHash(a, dir, "zenv-test", &env_cfg);
    defer a.free(h);
    try testing.expectEqualStrings("ad1f98e6f973b6566a7791da680347e8d7a499d0", h);
}

test "stamp round-trips and tolerates bad input" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const dir = try testDir(a, "stamp");
    defer cleanup(a, dir);

    const in_flags = [_][]const u8{ "--uv", "--no-cache" };
    try writeStamp(a, dir, "deadbeef", &in_flags);

    const got = readStamp(a, dir).?;
    defer got.deinit();
    try testing.expectEqualStrings("deadbeef", got.value.hash);
    try testing.expectEqual(@as(usize, 2), got.value.flags.len);
    try testing.expectEqualStrings("--uv", got.value.flags[0]);
    try testing.expectEqualStrings("--no-cache", got.value.flags[1]);

    const empty = try testDir(a, "stamp_empty");
    defer cleanup(a, empty);
    try testing.expect(readStamp(a, empty) == null); // absent

    try writeAt(a, empty, STAMP_NAME, "not json {");
    try testing.expect(readStamp(a, empty) == null); // malformed

    try writeAt(a, empty, STAMP_NAME, "{\"version\":999,\"hash\":\"x\",\"flags\":[]}");
    try testing.expect(readStamp(a, empty) == null); // wrong version

    try writeAt(a, empty, STAMP_NAME, "{\"version\":1,\"hash\":\"x\"}");
    const no_flags = readStamp(a, empty).?; // flags are optional
    defer no_flags.deinit();
    try testing.expectEqual(@as(usize, 0), no_flags.value.flags.len);
}

test "flagTokens emits only build-affecting flags" {
    const a = testing.allocator;
    const f = flags.CommandFlags{
        .use_uv = true,
        .no_cache = true,
        .skip_hostname_check = true, // --no-host: excluded
        .create_jupyter_kernel = true, // --jupyter: excluded
        .init_mode = true, // --init: excluded
        .no_python = true, // --no-python: excluded
    };
    const toks = try flagTokens(a, f);
    defer a.free(toks);
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqualStrings("--uv", toks[0]);
    try testing.expectEqualStrings("--no-cache", toks[1]);
}

test "ensureUpToDate: no-op on match, re-setup on drift, error on failure" {
    test_support.setupRuntime();
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
        const cfg_path = try std.Io.Dir.path.join(a, &[_][]const u8{ proj, "zenv.json" });
        defer a.free(cfg_path);
        var cfg = try validation.validateAndParse(a, cfg_path);
        defer cfg.deinit();
        const env_cfg = cfg.getEnvironment("zenv-test").?;
        const h = try computeTrackedHash(a, proj, "zenv-test", env_cfg);
        defer a.free(h);
        try writeStamp(a, venv, h, &[_][]const u8{});
    }

    test_spawned = false;
    try ensureUpToDate(a, &entry);
    try testing.expect(!test_spawned); // up to date -> no spawn

    // Drift: change the config so the hash no longer matches the stamp.
    try writeAt(a, proj, "zenv.json", test_config_b);
    test_spawned = false;
    test_run_exit = 0;
    try ensureUpToDate(a, &entry);
    try testing.expect(test_spawned); // drift -> spawned setup

    // Child setup fails -> AutoSetupFailed (stamp still stale).
    test_spawned = false;
    test_run_exit = 1;
    try testing.expectError(error.AutoSetupFailed, ensureUpToDate(a, &entry));
}

test "ensureUpToDate respects ZENV_NO_AUTO_SETUP" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const prev = runtime.exec_backend;
    runtime.exec_backend = .{ .run = recordingRun, .exec = recordingExec };
    defer runtime.exec_backend = prev;

    // Swap in an environment that sets the opt-out, then restore.
    var optout = std.process.Environ.Map.init(std.heap.page_allocator);
    defer optout.deinit();
    try optout.put("ZENV_NO_AUTO_SETUP", "1");
    const prev_env = runtime.environ_map;
    runtime.environ_map = &optout;
    defer runtime.environ_map = prev_env;

    var entry = try makeEntry(a, "x", "/no/such/proj", "/no/such/venv");
    defer entry.deinit(a);

    test_spawned = false;
    try ensureUpToDate(a, &entry);
    try testing.expect(!test_spawned); // opt-out short-circuits before any work
}

test "isStale reports drift without spawning setup" {
    test_support.setupRuntime();
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

    test_spawned = false;
    try testing.expect(try isStale(a, &entry)); // no stamp yet

    {
        const cfg_path = try std.Io.Dir.path.join(a, &[_][]const u8{ proj, "zenv.json" });
        defer a.free(cfg_path);
        var cfg = try validation.validateAndParse(a, cfg_path);
        defer cfg.deinit();
        const h = try computeTrackedHash(a, proj, "zenv-test", cfg.getEnvironment("zenv-test").?);
        defer a.free(h);
        try writeStamp(a, venv, h, &[_][]const u8{});
    }
    try testing.expect(!try isStale(a, &entry)); // stamp matches

    try writeAt(a, proj, "zenv.json", test_config_b);
    try testing.expect(try isStale(a, &entry)); // config drifted
    try testing.expect(!test_spawned);
}
