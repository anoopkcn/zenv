//! Auto-setup: keep a built environment in sync with its configuration.
//!
//! When `zenv.json` or any file it references (the dependency file, modules
//! file, or setup hook script) changes, the environment is stale and must be
//! rebuilt before commands like `run`/`activate` use it. This module detects
//! that drift with a checksum recorded in a per-env stamp file, and — when it
//! finds drift — re-runs `zenv setup` as a SILENT subprocess.
//!
//! Why a subprocess instead of calling setup in-process: the venv build runs a
//! shell script with INHERITED stdio (auxiliary.zig `executeShellScript`), so
//! pip/uv output reaches the terminal and is NOT suppressed by `output.silent`.
//! Re-invoking `zenv setup` and CAPTURING its output (`runtime.run`) is the only
//! way to stay silent, reuses all of setup's logic verbatim, and — by setting
//! the child's cwd to the project dir — reproduces the original resolution of a
//! relative `base_dir`/`dependency_file` exactly. `registry.register()` updates
//! in place by env_name, so re-setup never duplicates the registry entry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const runtime = @import("runtime.zig");
const config = @import("config.zig");
const validation = @import("validation.zig");
const output = @import("output.zig");
const flags = @import("flags.zig");

const STAMP_NAME = ".zenv.stamp";
// Untyped so it coerces to the JSON field (u32) and to i64 when comparing
// against a parsed json integer.
const STAMP_VERSION = 1;
const MAX_TRACKED_FILE = 10 * 1024 * 1024;

// ===========================================================================
// Tracked-file checksum
// ===========================================================================

/// Resolves a config-relative path against `anchor_dir`; absolute paths are
/// left untouched. Caller owns the result.
fn resolvePath(allocator: Allocator, anchor_dir: []const u8, rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel)) return allocator.dupe(u8, rel);
    return std.fs.path.join(allocator, &[_][]const u8{ anchor_dir, rel });
}

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
    sha.update("P\x00");
    sha.update(std.mem.asBytes(&content.len));
    sha.update(content);
    sha.update("\x00");
}

/// Lowercase-hex SHA-1 over the env's tracked files, hashed in a fixed order:
/// zenv.json (always), then dependency_file, modules_file and setup.script when
/// configured. `anchor_dir` is the setup cwd when recording the stamp and the
/// entry's project_dir when checking — these are the same directory, which is
/// what makes the two call sites agree. Caller owns the returned slice.
pub fn computeTrackedHash(
    allocator: Allocator,
    anchor_dir: []const u8,
    env_config: *const config.EnvironmentConfig,
) ![]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});

    {
        const p = try std.fs.path.join(allocator, &[_][]const u8{ anchor_dir, "zenv.json" });
        defer allocator.free(p);
        foldFile(allocator, &sha, "config", p);
    }
    if (env_config.dependency_file) |df| {
        const p = try resolvePath(allocator, anchor_dir, df);
        defer allocator.free(p);
        foldFile(allocator, &sha, "deps", p);
    }
    if (env_config.modules_file) |mf| {
        const p = try resolvePath(allocator, anchor_dir, mf);
        defer allocator.free(p);
        foldFile(allocator, &sha, "modules", p);
    }
    if (env_config.setup) |s| {
        if (s.script) |script| {
            const p = try resolvePath(allocator, anchor_dir, script);
            defer allocator.free(p);
            foldFile(allocator, &sha, "setup_script", p);
        }
    }

    var digest: [20]u8 = undefined;
    sha.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

// ===========================================================================
// Stamp file
// ===========================================================================

// Serialization view (fields are borrowed for writing).
const StampJSON = struct {
    version: u32,
    hash: []const u8,
    flags: []const []const u8,
};

/// An owned, parsed stamp. Caller must `deinit`.
pub const Stamp = struct {
    hash: []const u8,
    flags: []const []const u8,

    pub fn deinit(self: *const Stamp, allocator: Allocator) void {
        allocator.free(self.hash);
        for (self.flags) |f| allocator.free(f);
        allocator.free(self.flags);
    }
};

fn stampPath(allocator: Allocator, venv_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ venv_dir, STAMP_NAME });
}

/// Writes `<venv_dir>/.zenv.stamp` atomically. `flags` are the build-affecting
/// setup flags to replay on a future auto-setup.
pub fn writeStamp(allocator: Allocator, venv_dir: []const u8, hash: []const u8, build_flags: []const []const u8) !void {
    const path = try stampPath(allocator, venv_dir);
    defer allocator.free(path);

    const view = StampJSON{ .version = STAMP_VERSION, .hash = hash, .flags = build_flags };
    const text = try std.json.Stringify.valueAlloc(allocator, view, .{ .whitespace = .indent_2 });
    defer allocator.free(text);

    try runtime.writeFileAtomic(allocator, path, text);
}

/// Reads `<venv_dir>/.zenv.stamp`. Returns null (never errors) when the stamp is
/// absent, unreadable, malformed, or a different format version — every such
/// case means "treat as changed" and force a re-setup.
pub fn readStamp(allocator: Allocator, venv_dir: []const u8) ?Stamp {
    const path = stampPath(allocator, venv_dir) catch return null;
    defer allocator.free(path);

    const content = runtime.readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(content);

    const parsed = json.parseFromSlice(json.Value, allocator, content, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const ver = root.object.get("version") orelse return null;
    if (ver != .integer or ver.integer != STAMP_VERSION) return null;

    const hash_v = root.object.get("hash") orelse return null;
    if (hash_v != .string) return null;

    const hash_owned = allocator.dupe(u8, hash_v.string) catch return null;
    var ok = false;
    defer if (!ok) allocator.free(hash_owned);

    var flag_list = std.array_list.Managed([]const u8).init(allocator);
    defer if (!ok) {
        for (flag_list.items) |f| allocator.free(f);
        flag_list.deinit();
    };

    if (root.object.get("flags")) |flags_v| {
        if (flags_v == .array) {
            for (flags_v.array.items) |fv| {
                if (fv == .string) {
                    const f = allocator.dupe(u8, fv.string) catch return null;
                    flag_list.append(f) catch {
                        allocator.free(f);
                        return null;
                    };
                }
            }
        }
    }

    const flags_owned = flag_list.toOwnedSlice() catch return null;
    ok = true;
    return Stamp{ .hash = hash_owned, .flags = flags_owned };
}

// ===========================================================================
// Flag replay
// ===========================================================================

/// Canonical tokens for the build-affecting flags of a setup invocation, to be
/// replayed on a future auto-setup. Excludes `--no-host` (the gate always
/// re-adds it), `--init` (one-time bootstrap) and `--jupyter` (the kernel
/// already targets the unchanged venv). Items are static literals — the caller
/// frees only the returned slice.
pub fn flagTokens(allocator: Allocator, f: flags.CommandFlags) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    errdefer list.deinit();
    if (f.force_deps) try list.append("--force");
    if (f.use_default_python) try list.append("--python");
    if (f.dev_mode) try list.append("--dev");
    if (f.use_uv) try list.append("--uv");
    if (f.no_cache) try list.append("--no-cache");
    return list.toOwnedSlice();
}

// ===========================================================================
// The gate
// ===========================================================================

/// Re-invokes `zenv setup <env> --no-host [replay_flags...]` as a captured
/// (silent) subprocess with cwd set to the project dir. Returns
/// `error.AutoSetupFailed` if the child cannot start or exits non-zero. A
/// failure to locate the running binary is non-fatal: we warn and skip rather
/// than break an otherwise-working command.
fn runSetup(allocator: Allocator, entry: *const config.RegistryEntry, replay_flags: []const []const u8) !void {
    const self_exe = runtime.selfExePath(allocator) catch |err| {
        output.rawErr(allocator, "WARNING: auto-setup skipped (cannot locate zenv binary: {s})\n", .{@errorName(err)}) catch {};
        return;
    };
    defer allocator.free(self_exe);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&[_][]const u8{ self_exe, "setup", entry.env_name, "--no-host" });
    try argv.appendSlice(replay_flags);

    const res = runtime.run(allocator, argv.items, .{ .cwd = entry.project_dir }) catch |err| {
        output.rawErr(allocator, "ERROR: auto-setup failed to start: {s}\n", .{@errorName(err)}) catch {};
        return error.AutoSetupFailed;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        output.rawErr(allocator, "ERROR: auto-setup failed; see {s}/zenv_setup.log\n", .{entry.venv_path}) catch {};
        return error.AutoSetupFailed;
    }
}

/// THE GATE. Call after an environment is resolved and before a command uses its
/// venv. If the env's tracked files differ from the recorded stamp (or no stamp
/// exists yet), silently re-runs setup first. Bypassed entirely when
/// ZENV_NO_AUTO_SETUP is set. Never recurses: `setup` does not go through here.
pub fn ensureUpToDate(allocator: Allocator, entry: *const config.RegistryEntry) !void {
    if (runtime.env("ZENV_NO_AUTO_SETUP")) |_| return;

    const config_path = std.fs.path.join(allocator, &[_][]const u8{ entry.project_dir, "zenv.json" }) catch return;
    defer allocator.free(config_path);

    // A removed/broken config must not block a working venv; skip the check.
    var cfg = validation.validateAndParse(allocator, config_path) catch return;
    defer cfg.deinit();

    const env_cfg = cfg.getEnvironment(entry.env_name) orelse return;

    const current = try computeTrackedHash(allocator, entry.project_dir, env_cfg);
    defer allocator.free(current);

    if (readStamp(allocator, entry.venv_path)) |stamp| {
        defer stamp.deinit(allocator);
        if (std.mem.eql(u8, stamp.hash, current)) return; // up to date
        try runSetup(allocator, entry, stamp.flags);
        return;
    }

    // No (valid) stamp: force a one-time re-setup with no replayed flags.
    try runSetup(allocator, entry, &[_][]const u8{});
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
    const dir = try std.fs.path.join(allocator, &[_][]const u8{ base, "zenv_autosetup_test", name });
    runtime.deleteTree(dir) catch {};
    try runtime.makePath(dir);
    return dir;
}

fn cleanup(allocator: Allocator, dir: []u8) void {
    runtime.deleteTree(dir) catch {};
    allocator.free(dir);
}

fn writeAt(allocator: Allocator, dir: []const u8, name: []const u8, content: []const u8) !void {
    const p = try std.fs.path.join(allocator, &[_][]const u8{ dir, name });
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
        .aliases = std.array_list.Managed([]const u8).init(allocator),
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

    const h1 = try computeTrackedHash(a, dir, &env_cfg);
    defer a.free(h1);
    const h2 = try computeTrackedHash(a, dir, &env_cfg);
    defer a.free(h2);
    try testing.expectEqualStrings(h1, h2); // deterministic (no timestamp)
    try testing.expectEqual(@as(usize, 40), h1.len);

    try writeAt(a, dir, "zenv.json", test_config_b);
    const h3 = try computeTrackedHash(a, dir, &env_cfg);
    defer a.free(h3);
    try testing.expect(!std.mem.eql(u8, h1, h3)); // content change flips the hash
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

    const h_absent = try computeTrackedHash(a, dir, &env_cfg);
    defer a.free(h_absent);

    try writeAt(a, dir, "requirements.txt", "numpy\n");
    const h_present = try computeTrackedHash(a, dir, &env_cfg);
    defer a.free(h_present);

    try testing.expect(!std.mem.eql(u8, h_absent, h_present));
}

test "stamp round-trips and tolerates bad input" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const dir = try testDir(a, "stamp");
    defer cleanup(a, dir);

    const in_flags = [_][]const u8{ "--uv", "--no-cache" };
    try writeStamp(a, dir, "deadbeef", &in_flags);

    const got = readStamp(a, dir).?;
    defer got.deinit(a);
    try testing.expectEqualStrings("deadbeef", got.hash);
    try testing.expectEqual(@as(usize, 2), got.flags.len);
    try testing.expectEqualStrings("--uv", got.flags[0]);
    try testing.expectEqualStrings("--no-cache", got.flags[1]);

    const empty = try testDir(a, "stamp_empty");
    defer cleanup(a, empty);
    try testing.expect(readStamp(a, empty) == null); // absent

    try writeAt(a, empty, STAMP_NAME, "not json {");
    try testing.expect(readStamp(a, empty) == null); // malformed

    try writeAt(a, empty, STAMP_NAME, "{\"version\":999,\"hash\":\"x\",\"flags\":[]}");
    try testing.expect(readStamp(a, empty) == null); // wrong version
}

test "flagTokens emits only build-affecting flags" {
    const a = testing.allocator;
    const f = flags.CommandFlags{
        .use_uv = true,
        .no_cache = true,
        .skip_hostname_check = true, // --no-host: excluded
        .create_jupyter_kernel = true, // --jupyter: excluded
        .init_mode = true, // --init: excluded
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
        const cfg_path = try std.fs.path.join(a, &[_][]const u8{ proj, "zenv.json" });
        defer a.free(cfg_path);
        var cfg = try validation.validateAndParse(a, cfg_path);
        defer cfg.deinit();
        const env_cfg = cfg.getEnvironment("zenv-test").?;
        const h = try computeTrackedHash(a, proj, env_cfg);
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
