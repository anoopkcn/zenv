//! Host / hostname matching primitives.
//!
//! A leaf module: it depends only on `std`, `runtime`, `errors`, and `output`,
//! and is imported by both `environment.zig` (which re-exports the public
//! functions for its existing callers) and `config.zig` (which uses them for
//! host-aware identifier resolution). Keeping these here avoids a circular
//! import — `environment.zig` imports `config.zig`, so `config.zig` cannot
//! import `environment.zig` in turn.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");

// Checks if pattern with wildcards matches a string
// Supports * (any characters) and ? (single character)
fn patternMatches(pattern: []const u8, str: []const u8) bool {
    // Empty pattern only matches empty string
    if (pattern.len == 0) return str.len == 0;

    // Special case: single * matches anything
    if (pattern.len == 1 and pattern[0] == '*') return true;

    // Empty string only matches if pattern is just asterisks
    if (str.len == 0) {
        for (pattern) |c| {
            if (c != '*') return false;
        }
        return true;
    }

    // Optimize common patterns first

    // 1. Fast path for prefix pattern: "prefix*"
    if (pattern.len >= 2 and pattern[pattern.len - 1] == '*') {
        // Check if all other characters are literals (no wildcards)
        var has_other_wildcards = false;
        for (pattern[0 .. pattern.len - 1]) |c| {
            if (c == '*' or c == '?') {
                has_other_wildcards = true;
                break;
            }
        }

        if (!has_other_wildcards) {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, str, prefix);
        }
    }

    // 2. Fast path for suffix pattern: "*suffix"
    if (pattern.len >= 2 and pattern[0] == '*' and pattern[1] != '*') {
        // Check if all other characters are literals (no wildcards)
        var has_other_wildcards = false;
        for (pattern[1..]) |c| {
            if (c == '*' or c == '?') {
                has_other_wildcards = true;
                break;
            }
        }

        if (!has_other_wildcards) {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, str, suffix);
        }
    }

    // 3. Fast path for contains pattern: "*middle*"
    if (pattern.len >= 3 and pattern[0] == '*' and pattern[pattern.len - 1] == '*') {
        // Check if middle part has no wildcards
        var has_wildcards = false;
        for (pattern[1 .. pattern.len - 1]) |c| {
            if (c == '*' or c == '?') {
                has_wildcards = true;
                break;
            }
        }

        if (!has_wildcards) {
            const middle = pattern[1 .. pattern.len - 1];
            return std.mem.find(u8, str, middle) != null;
        }
    }

    return globMatch(pattern, str);
}

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

// Splits a hostname into domain components and checks if any match the target
fn matchDomainComponent(hostname: []const u8, target: []const u8) bool {
    var parts = std.mem.splitScalar(u8, hostname, '.');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, target)) {
            return true;
        }
    }
    return false;
}

// Get the hostname via the `gethostname(2)`/`uname(2)` syscall (internal).
//
// Unlike `getHostnameFromCommand`, this needs no external `hostname` binary —
// on Linux it goes straight to the kernel via `uname`, so it works on minimal
// systems (containers, HPC compute nodes, busybox images) where `/bin/hostname`
// is absent. We try this before shelling out to the command.
pub fn getHostnameFromSyscall(allocator: Allocator) ![]const u8 {
    errors.debugLog(allocator, "Querying hostname via gethostname syscall", .{});
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&buf) catch |err| {
        errors.debugLog(allocator, "gethostname syscall failed: {s}", .{@errorName(err)});
        return error.ProcessError;
    };
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        errors.debugLog(allocator, "gethostname syscall returned empty output", .{});
        return error.MissingHostname;
    }
    errors.debugLog(allocator, "Got hostname from syscall: '{s}'", .{trimmed});
    return allocator.dupe(u8, trimmed);
}

// Helper function to get hostname using the `hostname` command (internal)
pub fn getHostnameFromCommand(allocator: Allocator) ![]const u8 {
    errors.debugLog(allocator, "Executing 'hostname' command", .{});
    const result = runtime.run(allocator, &[_][]const u8{"hostname"}, .{
        .stdout_limit = .limited(128),
        .stderr_limit = .limited(512),
    }) catch |err| {
        output.printError(allocator, "Failed to run `hostname` command: {s}", .{@errorName(err)}) catch {};
        return error.ProcessError;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check if the command was successful
    const success = result.term == .exited and result.term.exited == 0;

    if (!success) {
        output.printError(allocator, "`hostname` command failed. Term: {s} Stderr: {s}", .{ @tagName(result.term), result.stderr }) catch {};
        return error.ProcessError;
    }

    const trimmed_hostname = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed_hostname.len == 0) {
        output.printError(allocator, "`hostname` command returned empty output.", .{}) catch {};
        return error.MissingHostname;
    }
    errors.debugLog(allocator, "Got hostname from command: '{s}'", .{trimmed_hostname});
    // Return a duplicate of the trimmed hostname
    return allocator.dupe(u8, trimmed_hostname);
}

// Resolve the identity of the current machine for `target_machines` matching.
//
// On HPC systems every node of a cluster exports the same `$SYSTEMNAME`, while
// `hostname` differs per node (jrlogin01 vs jrc0042). Keying off `$SYSTEMNAME`
// first means one `target_machines` entry (e.g. "jureca") matches on login and
// compute nodes alike, instead of only the nodes whose hostname happens to carry
// the cluster name. This mirrors the `${SYSTEMNAME:-$(hostname)}` rule that keys
// the module cache (envspec.currentSystem, and the check in generated
// activate scripts), so matching and caching agree on one cluster identity. Off HPC, `$SYSTEMNAME` is unset and we
// fall back to the previous hostname behaviour unchanged.
pub fn getSystemHostname(allocator: Allocator) ![]const u8 {
    errors.debugLog(allocator, "Attempting to get machine identity from environment variable...", .{});

    // Prefer SYSTEMNAME (cluster-global), then HOSTNAME, then HOST (if non-empty),
    // then fall back to the `hostname` command.
    if (runtime.env("SYSTEMNAME")) |systemname_env| {
        if (systemname_env.len > 0) {
            errors.debugLog(allocator, "Got machine identity from SYSTEMNAME: '{s}'", .{systemname_env});
            return allocator.dupe(u8, systemname_env);
        }
    }

    if (runtime.env("HOSTNAME")) |hostname_env| {
        if (hostname_env.len > 0) {
            errors.debugLog(allocator, "Got hostname from HOSTNAME: '{s}'", .{hostname_env});
            return allocator.dupe(u8, hostname_env);
        }
    }

    if (runtime.env("HOST")) |host_env| {
        if (host_env.len > 0) {
            errors.debugLog(allocator, "Got hostname from HOST: '{s}'", .{host_env});
            return allocator.dupe(u8, host_env);
        }
    }

    // Prefer the syscall (no external binary) over the `hostname` command, so
    // machines without `/bin/hostname` still resolve an identity. Fall back to
    // the command only if the syscall itself fails.
    errors.debugLog(allocator, "Hostname env vars not set, trying gethostname syscall...", .{});
    if (getHostnameFromSyscall(allocator)) |name| {
        return name;
    } else |err| {
        errors.debugLog(allocator, "Syscall hostname failed ({s}), falling back to 'hostname' command...", .{@errorName(err)});
    }

    return getHostnameFromCommand(allocator);
}

// Simple check for hostname matching target machine (used by list command)
pub fn checkHostnameMatch(hostname: []const u8, target_machine: []const u8) bool {
    // This function is only for the simplified registry case of a single target machine
    // Use the same matching logic for consistency

    // Special cases for universal targets
    if (std.mem.eql(u8, target_machine, "localhost") or
        std.mem.eql(u8, target_machine, "any") or
        std.mem.eql(u8, target_machine, "*"))
    {
        return true;
    }

    // Special case for "local" which should match any hostname with ".local" suffix
    if (std.mem.eql(u8, target_machine, "local") and std.mem.endsWith(u8, hostname, ".local")) {
        return true;
    }

    const norm_hostname = hostname;

    // Check if the target contains wildcard characters
    const has_wildcards = std.mem.findAny(u8, target_machine, "*?") != null;

    // If target has wildcards, use pattern matching
    if (has_wildcards) {
        return patternMatches(target_machine, norm_hostname);
    }

    // Try various matching strategies

    // 1. Exact match
    if (std.mem.eql(u8, norm_hostname, target_machine)) {
        return true;
    }

    // 2. Domain component match
    if (matchDomainComponent(norm_hostname, target_machine)) {
        return true;
    }

    // 3. Domain suffix like ".example.com"
    if (target_machine.len > 0 and target_machine[0] == '.' and norm_hostname.len > target_machine.len and
        std.mem.endsWith(u8, norm_hostname, target_machine))
    {
        return true;
    }

    // 4. Domain suffix match (e.g., node123.cluster matches target cluster)
    if (norm_hostname.len > target_machine.len + 1 and
        norm_hostname[norm_hostname.len - target_machine.len - 1] == '.')
    {
        const suffix = norm_hostname[norm_hostname.len - target_machine.len ..];
        if (std.mem.eql(u8, suffix, target_machine)) {
            return true;
        }
    }

    return false;
}

/// True if `hostname` matches ANY comma-separated pattern in `target_machines_str`
/// (the registry's stored form, e.g. "m1, m2" or "any"). An empty/blank string
/// matches every host (mirrors how an empty target list registers as "any").
pub fn hostMatchesTargets(hostname: []const u8, target_machines_str: []const u8) bool {
    if (std.mem.trim(u8, target_machines_str, " ").len == 0) return true;
    var it = std.mem.splitScalar(u8, target_machines_str, ',');
    while (it.next()) |raw| {
        const pattern = std.mem.trim(u8, raw, " ");
        if (pattern.len == 0) continue;
        if (checkHostnameMatch(hostname, pattern)) return true;
    }
    return false;
}

// ============================ Tests ============================
const testing = std.testing;

test "checkHostnameMatch: universal targets match any host" {
    try testing.expect(checkHostnameMatch("jrlogin01.jureca", "*"));
    try testing.expect(checkHostnameMatch("jrlogin01.jureca", "any"));
    try testing.expect(checkHostnameMatch("whatever", "localhost"));
}

test "checkHostnameMatch: exact and domain-component matching" {
    try testing.expect(checkHostnameMatch("jureca", "jureca"));
    try testing.expect(!checkHostnameMatch("juwels", "jureca"));
    // A target naming any dot-separated component of the FQDN matches.
    try testing.expect(checkHostnameMatch("jrlogin01.jureca", "jureca"));
    try testing.expect(checkHostnameMatch("node1.cluster.example.com", "cluster"));
    try testing.expect(!checkHostnameMatch("node1.cluster.example.com", "uster"));
}

test "checkHostnameMatch: wildcard patterns" {
    try testing.expect(checkHostnameMatch("jrlogin01.jureca", "jrlogin*"));
    try testing.expect(!checkHostnameMatch("jwlogin01.juwels", "jrlogin*"));
    try testing.expect(checkHostnameMatch("node1.cluster", "*.cluster"));
    try testing.expect(checkHostnameMatch("jrlogin01.jureca", "*jureca*"));
    try testing.expect(checkHostnameMatch("node1", "node?"));
    try testing.expect(!checkHostnameMatch("node12", "node?"));
    // Mixed wildcard pattern goes through the DP matcher.
    try testing.expect(checkHostnameMatch("jrlogin01.jureca", "jr*0?.jureca"));
}

test "checkHostnameMatch: domain suffix forms" {
    try testing.expect(checkHostnameMatch("node1.example.com", ".example.com"));
    try testing.expect(!checkHostnameMatch("example.com", ".example.com"));
    try testing.expect(checkHostnameMatch("mymac.local", "local"));
}

test "hostMatchesTargets: comma-separated list, blank, and no-match" {
    try testing.expect(hostMatchesTargets("machine2", "machine1, machine2"));
    try testing.expect(!hostMatchesTargets("machine3", "machine1, machine2"));
    try testing.expect(hostMatchesTargets("anything", "")); // blank = any
    try testing.expect(hostMatchesTargets("anything", "machine1, *"));
    try testing.expect(hostMatchesTargets("jrlogin01.jureca", "juwels, jureca"));
}

test "getSystemHostname: SYSTEMNAME takes precedence over HOSTNAME/HOST" {
    const a = testing.allocator;
    const prev_env = runtime.environ_map;
    defer runtime.environ_map = prev_env;

    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    // A node whose hostname does NOT carry the cluster name still resolves to the
    // cluster via SYSTEMNAME, so a `target_machines: ["jureca"]` entry matches.
    try env_map.put("SYSTEMNAME", "jureca");
    try env_map.put("HOSTNAME", "jrc0042");
    try env_map.put("HOST", "jrc0042");
    runtime.environ_map = &env_map;

    const id = try getSystemHostname(a);
    defer a.free(id);
    try testing.expectEqualStrings("jureca", id);
    try testing.expect(hostMatchesTargets(id, "jureca"));
}

test "getHostnameFromSyscall: returns a non-empty hostname without the `hostname` binary" {
    const a = testing.allocator;
    const name = getHostnameFromSyscall(a) catch |err| {
        // Some sandboxed CI environments block the syscall; tolerate that.
        try testing.expect(err == error.ProcessError or err == error.MissingHostname);
        return;
    };
    defer a.free(name);
    try testing.expect(name.len > 0);
}

test "getSystemHostname: empty SYSTEMNAME falls back to HOSTNAME" {
    const a = testing.allocator;
    const prev_env = runtime.environ_map;
    defer runtime.environ_map = prev_env;

    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    try env_map.put("SYSTEMNAME", ""); // set-but-empty must not win
    try env_map.put("HOSTNAME", "jrlogin01.jureca");
    runtime.environ_map = &env_map;

    const id = try getSystemHostname(a);
    defer a.free(id);
    try testing.expectEqualStrings("jrlogin01.jureca", id);
}
