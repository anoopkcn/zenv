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
            return std.mem.indexOf(u8, str, middle) != null;
        }
    }

    // Use dynamic programming for more complex patterns
    // This is more efficient than recursion for non-trivial patterns
    return wildcardMatch(pattern, str);
}

// Helper function that implements an efficient dynamic programming algorithm
// for wildcard matching - this avoids recursion stack overhead and
// redundant calculations
fn wildcardMatch(pattern: []const u8, str: []const u8) bool {
    const m = str.len;
    const n = pattern.len;

    // Allocate boolean arrays on the stack for the DP table
    // We only need two rows: previous and current
    var prev_row: [512]bool = undefined;
    var curr_row: [512]bool = undefined;

    // Handle potential buffer size issues
    if (m >= prev_row.len) return fallbackWildcardMatch(pattern, str);

    // Base case: empty pattern matches empty string
    prev_row[0] = true;

    // Base case: a pattern with only '*' can match empty string
    for (1..n + 1) |j| {
        prev_row[j] = prev_row[j - 1] and pattern[j - 1] == '*';
    }

    // Fill the dp table
    for (1..m + 1) |i| {
        // Reset current row
        curr_row[0] = false;

        for (1..n + 1) |j| {
            if (pattern[j - 1] == '*') {
                // '*' can match zero or multiple characters
                curr_row[j] = curr_row[j - 1] or prev_row[j];
            } else if (pattern[j - 1] == '?' or pattern[j - 1] == str[i - 1]) {
                // Current characters match or '?' matches any single character
                curr_row[j] = prev_row[j - 1];
            } else {
                // Characters don't match
                curr_row[j] = false;
            }
        }

        // Swap rows for next iteration
        for (0..n + 1) |j| {
            prev_row[j] = curr_row[j];
        }
    }

    return prev_row[n];
}

// Fallback implementation for extreme cases
fn fallbackWildcardMatch(pattern: []const u8, str: []const u8) bool {
    if (pattern.len == 0) return str.len == 0;

    // Handle first character
    const first_match = str.len > 0 and
        (pattern[0] == str[0] or pattern[0] == '?');

    // If we see a '*', we can:
    // 1. Skip it entirely (match zero characters)
    // 2. Match the current character and keep the '*' (match multiple characters)
    if (pattern.len > 0 and pattern[0] == '*') {
        return fallbackWildcardMatch(pattern[1..], str) or
            (str.len > 0 and fallbackWildcardMatch(pattern, str[1..]));
    }

    // If first character matches, proceed with the rest
    return first_match and fallbackWildcardMatch(pattern[1..], str[1..]);
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

// Get hostname using environment variables or fallback to command
pub fn getSystemHostname(allocator: Allocator) ![]const u8 {
    errors.debugLog(allocator, "Attempting to get hostname from environment variable...", .{});

    // Try HOSTNAME, then HOST (if non-empty), then fall back to the command.
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

    errors.debugLog(allocator, "Hostname env vars not set, falling back to 'hostname' command...", .{});
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
    const has_wildcards = std.mem.indexOfAny(u8, target_machine, "*?") != null;

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
