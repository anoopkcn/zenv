//! The current machine's identity and how it is matched against an
//! environment's `target_machines`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const output = @import("output.zig");
const runtime = @import("runtime.zig");

/// `*` (any run, including empty) and `?` (one character) glob match, by the
/// classic two-pointer scan with backtracking to the last `*`: no allocation,
/// no length limit, O(pattern * str) worst case.
fn globMatch(pattern: []const u8, str: []const u8) bool {
    var p: usize = 0;
    var s_i: usize = 0;
    var star: ?usize = null; // index in pattern of the last '*'
    var star_s: usize = 0; // str index that '*' currently stretches to
    while (s_i < str.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == str[s_i])) {
            p += 1;
            s_i += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_s = s_i;
            p += 1;
        } else if (star) |st| {
            p = st + 1;
            star_s += 1;
            s_i = star_s;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test "globMatch handles long patterns and many stars" {
    try std.testing.expect(globMatch("jr?ogin*.jureca", "jrlogin01.jureca"));
    try std.testing.expect(!globMatch("jr?ogin*.juwels", "jrlogin01.jureca"));
    try std.testing.expect(globMatch("*a*b*c*", "xxaxxbxxcxx"));
    var long_pat: [600]u8 = undefined;
    @memset(&long_pat, 'a');
    long_pat[0] = '*'; // a wildcard pattern longer than the old 512-entry buffer
    try std.testing.expect(globMatch(&long_pat, long_pat[1..]));
    const many_stars = "*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b";
    var as: [200]u8 = undefined;
    @memset(&as, 'a');
    try std.testing.expect(!globMatch(many_stars, &as)); // no exponential blow-up
}

/// Whether one of `hostname`'s dot-separated components is `target`.
fn matchDomainComponent(hostname: []const u8, target: []const u8) bool {
    var parts = std.mem.splitScalar(u8, hostname, '.');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, target)) {
            return true;
        }
    }
    return false;
}

/// The hostname from the `gethostname(2)`/`uname(2)` syscall. Unlike
/// `fromCommand`, this needs no external `hostname` binary, so it works on
/// minimal systems (containers, HPC compute nodes, busybox images) where
/// `/bin/hostname` is absent.
pub fn fromSyscall(allocator: Allocator, io: Io) ![]const u8 {
    output.debug(io, "Querying hostname via gethostname syscall", .{});
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&buf) catch |err| {
        output.debug(io, "gethostname syscall failed: {t}", .{err});
        return error.ProcessError;
    };
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        output.debug(io, "gethostname syscall returned empty output", .{});
        return error.MissingHostname;
    }
    output.debug(io, "Got hostname from syscall: '{s}'", .{trimmed});
    return allocator.dupe(u8, trimmed);
}

/// The hostname the `hostname` command prints.
fn fromCommand(allocator: Allocator, io: Io) ![]const u8 {
    output.debug(io, "Executing 'hostname' command", .{});
    const result = runtime.run(allocator, io, &.{"hostname"}, .{
        .stdout_limit = .limited(128),
        .stderr_limit = .limited(512),
    }) catch |err| {
        output.printError(io, "Failed to run `hostname` command: {t}", .{err});
        return error.ProcessError;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.term.success()) {
        output.printError(
            io,
            "`hostname` command {f}. Stderr: {s}",
            .{ result.term, result.stderr },
        );
        return error.ProcessError;
    }

    const trimmed_hostname = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed_hostname.len == 0) {
        output.printError(io, "`hostname` command returned empty output.", .{});
        return error.MissingHostname;
    }
    output.debug(io, "Got hostname from command: '{s}'", .{trimmed_hostname});
    // Return a duplicate of the trimmed hostname
    return allocator.dupe(u8, trimmed_hostname);
}

/// The identity of the current machine for `target_machines` matching.
///
/// On HPC systems every node of a cluster exports the same `$SYSTEMNAME`, while
/// `hostname` differs per node (jrlogin01 vs jrc0042). Keying off `$SYSTEMNAME`
/// first means one `target_machines` entry (e.g. "jureca") matches on login and
/// compute nodes alike. This mirrors the `${SYSTEMNAME:-$(hostname)}` rule that
/// keys the module cache (envspec.currentSystem, and the check in generated
/// activate scripts), so matching and caching agree on one cluster identity.
/// Off HPC, `$SYSTEMNAME` is unset and the hostname is used.
pub fn getSystemHostname(
    allocator: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    output.debug(io, "Attempting to get machine identity from environment variable...", .{});

    // Prefer SYSTEMNAME (cluster-global), then HOSTNAME, then HOST (if non-empty).
    for ([_][]const u8{ "SYSTEMNAME", "HOSTNAME", "HOST" }) |name| {
        const value = env.get(name) orelse continue;
        if (value.len == 0) continue;
        output.debug(io, "Got machine identity from {s}: '{s}'", .{ name, value });
        return allocator.dupe(u8, value);
    }

    // Prefer the syscall (no external binary) over the `hostname` command, so
    // machines without `/bin/hostname` still resolve an identity. Fall back to
    // the command only if the syscall itself fails.
    output.debug(io, "Hostname env vars not set, trying gethostname syscall...", .{});
    if (fromSyscall(allocator, io)) |name| {
        return name;
    } else |err| {
        output.debug(
            io,
            "Syscall hostname failed ({t}), falling back to 'hostname' command...",
            .{err},
        );
    }

    return fromCommand(allocator, io);
}

/// True if `hostname` matches one `target_machines` entry: a universal target
/// ("*", "any", "localhost"), "local" for `*.local` hosts, a `*`/`?` glob, the
/// exact name, one of its dot-separated components, or a domain suffix.
fn matches(hostname: []const u8, target_machine: []const u8) bool {
    if (std.mem.eql(u8, target_machine, "localhost") or
        std.mem.eql(u8, target_machine, "any") or
        std.mem.eql(u8, target_machine, "*"))
    {
        return true;
    }

    // "local" matches any hostname with a ".local" suffix
    if (std.mem.eql(u8, target_machine, "local") and std.mem.endsWith(u8, hostname, ".local")) {
        return true;
    }

    if (std.mem.findAny(u8, target_machine, "*?") != null) return globMatch(
        target_machine,
        hostname,
    );

    // Exact name, or one of its components ("jureca" for jrlogin01.jureca)
    if (std.mem.eql(
        u8,
        hostname,
        target_machine,
    ) or matchDomainComponent(hostname, target_machine)) return true;

    // Domain suffix: ".example.com", or "example.com" after a dot (node1.example.com)
    if (std.mem.cutSuffix(u8, hostname, target_machine)) |rest| {
        if (target_machine.len > 0 and target_machine[0] == '.' and rest.len > 0) return true;
        if (rest.len > 1 and rest[rest.len - 1] == '.') return true;
    }
    return false;
}

/// True if `hostname` matches ANY comma-separated pattern in `target_machines_str`
/// (the registry's stored form, e.g. "m1, m2" or "any"). An empty/blank string
/// matches every host (mirrors how an empty target list registers as "any").
pub fn matchesTargets(hostname: []const u8, target_machines_str: []const u8) bool {
    if (std.mem.trim(u8, target_machines_str, " ").len == 0) return true;
    var it = std.mem.splitScalar(u8, target_machines_str, ',');
    while (it.next()) |raw| {
        const pattern = std.mem.trim(u8, raw, " ");
        if (pattern.len == 0) continue;
        if (matches(hostname, pattern)) return true;
    }
    return false;
}

/// True if `hostname` matches any of `targets`; an empty list matches every
/// machine.
fn matchesAny(hostname: []const u8, targets: []const []const u8) bool {
    if (targets.len == 0) return true;
    for (targets) |target| {
        if (matches(hostname, target)) return true;
    }
    return false;
}

/// Checks the current host against `targets`, the target_machines of
/// environment `env_name`. On a mismatch, says so (naming the targets) and
/// returns TargetMachineMismatch.
pub fn check(ctx: runtime.Ctx, targets: []const []const u8, env_name: []const u8) !void {
    const io = ctx.io;
    const hostname = getSystemHostname(ctx.arena, io, ctx.env) catch |err| {
        output.printError(io, "Failed to get current hostname: {t}", .{err});
        return err;
    };

    output.debug(
        io,
        "Comparing current hostname '{s}' with target machines for env '{s}'",
        .{ hostname, env_name },
    );
    if (matchesAny(hostname, targets)) return;

    var quoted: std.Io.Writer.Allocating = .init(ctx.arena);
    for (targets, 0..) |target, i| {
        quoted.writer.print("{s}\"{s}\"", .{ if (i > 0) ", " else "", target }) catch {};
    }
    output.printError(
        io,
        "Current machine ('{s}') does not match target machines ([{s}]) specified for environment '{s}'.",
        .{ hostname, quoted.written(), env_name },
    );
    output.printError(io, "Use '--no-host' flag to bypass this check if needed.", .{});
    return error.TargetMachineMismatch;
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("test_support.zig");

test "matches: universal targets match any host" {
    try testing.expect(matches("jrlogin01.jureca", "*"));
    try testing.expect(matches("jrlogin01.jureca", "any"));
    try testing.expect(matches("whatever", "localhost"));
}

test "matches: exact and domain-component matching" {
    try testing.expect(matches("jureca", "jureca"));
    try testing.expect(!matches("juwels", "jureca"));
    // A target naming any dot-separated component of the FQDN matches.
    try testing.expect(matches("jrlogin01.jureca", "jureca"));
    try testing.expect(matches("node1.cluster.example.com", "cluster"));
    try testing.expect(!matches("node1.cluster.example.com", "uster"));
}

test "matches: wildcard patterns" {
    try testing.expect(matches("jrlogin01.jureca", "jrlogin*"));
    try testing.expect(!matches("jwlogin01.juwels", "jrlogin*"));
    try testing.expect(matches("node1.cluster", "*.cluster"));
    try testing.expect(matches("jrlogin01.jureca", "*jureca*"));
    try testing.expect(matches("node1", "node?"));
    try testing.expect(!matches("node12", "node?"));
    try testing.expect(!matches("jrlogin01.jureca", "*juwels*"));
    try testing.expect(matches("jrlogin01.jureca", "jr*0?.jureca"));
}

test "matches: domain suffix forms" {
    try testing.expect(matches("node1.example.com", ".example.com"));
    try testing.expect(!matches("example.com", ".example.com"));
    try testing.expect(matches("node1.example.com", "example.com"));
    try testing.expect(!matches("myexample.com", "example.com"));
    try testing.expect(matches("mymac.local", "local"));
}

test "matchesTargets: comma-separated list, blank, and no-match" {
    try testing.expect(matchesTargets("machine2", "machine1, machine2"));
    try testing.expect(!matchesTargets("machine3", "machine1, machine2"));
    try testing.expect(matchesTargets("anything", "")); // blank = any
    try testing.expect(matchesTargets("anything", "machine1, *"));
    try testing.expect(matchesTargets("jrlogin01.jureca", "juwels, jureca"));
}

test "getSystemHostname: SYSTEMNAME takes precedence over HOSTNAME/HOST" {
    const a = testing.allocator;
    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    // A node whose hostname does NOT carry the cluster name still resolves to the
    // cluster via SYSTEMNAME, so a `target_machines: ["jureca"]` entry matches.
    try env_map.put("SYSTEMNAME", "jureca");
    try env_map.put("HOSTNAME", "jrc0042");
    try env_map.put("HOST", "jrc0042");

    const id = try getSystemHostname(a, testing.io, &env_map);
    defer a.free(id);
    try testing.expectEqualStrings("jureca", id);
    try testing.expect(matchesTargets(id, "jureca"));
}

test "fromSyscall: returns a non-empty hostname without the `hostname` binary" {
    const a = testing.allocator;
    const name = fromSyscall(a, testing.io) catch |err| {
        // Some sandboxed CI environments block the syscall; tolerate that.
        try testing.expect(err == error.ProcessError or err == error.MissingHostname);
        return;
    };
    defer a.free(name);
    try testing.expect(name.len > 0);
}

test "getSystemHostname: empty SYSTEMNAME falls back to HOSTNAME" {
    const a = testing.allocator;
    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    try env_map.put("SYSTEMNAME", ""); // set-but-empty must not win
    try env_map.put("HOSTNAME", "jrlogin01.jureca");

    const id = try getSystemHostname(a, testing.io, &env_map);
    defer a.free(id);
    try testing.expectEqualStrings("jrlogin01.jureca", id);
}

test "fromCommand trims output and rejects empty/failed runs" {
    const a = testing.allocator;
    const prev = test_support.useFakeExec();
    defer runtime.exec_backend = prev;

    // happy path: surrounding whitespace is trimmed off the captured stdout
    test_support.fake_run_stdout = "  jrlogin01.jureca \n";
    test_support.fake_run_stderr = "";
    test_support.fake_run_exit = 0;
    const h = try fromCommand(a, testing.io);
    defer a.free(h);
    try testing.expectEqualStrings("jrlogin01.jureca", h);

    // whitespace-only output -> MissingHostname
    test_support.fake_run_stdout = "   \n";
    try testing.expectError(error.MissingHostname, fromCommand(a, testing.io));

    // non-zero exit -> ProcessError
    test_support.fake_run_stdout = "ignored";
    test_support.fake_run_exit = 1;
    try testing.expectError(error.ProcessError, fromCommand(a, testing.io));
}
