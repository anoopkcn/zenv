const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const errors = @import("errors.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");

/// On-disk format version of the module-environment cache. Written into the
/// stamp at setup and checked at activation; bump this when the capture/replay
/// format changes so existing caches are invalidated (fall back to `module load`).
pub const MODULE_CACHE_VERSION: u32 = 1;

/// Basenames of the cache artifacts written into the venv directory.
pub const MODULE_CACHE_FILE = ".zenv_module_cache.sh";
pub const MODULE_CACHE_STAMP = ".zenv_module_cache.stamp";

/// Appends `value` to `buf` as the body of a shell single-quoted string,
/// escaping any embedded single quotes with the classic `'\''` trick. The
/// caller writes the wrapping single quotes around the call. Use this for any
/// config-sourced value (venv paths, module names) interpolated into generated
/// shell so a stray `'` can't break or rewrite the script.
pub fn appendSqEscaped(buf: *std.array_list.Managed(u8), value: []const u8) !void {
    for (value) |c| {
        if (c == '\'') {
            try buf.appendSlice("'\\''");
        } else {
            try buf.append(c);
        }
    }
}

fn accessFile(path: []const u8) bool {
    runtime.access(path) catch return false;
    return true;
}

/// Lowercase-hex SHA-1 of the effective module list, in load order. Used as the
/// reuse key for the module-env cache: setup skips re-running Lmod (purge/load/
/// capture) and just sources the existing cache when this matches the stamp.
/// Order- and boundary-sensitive (a NUL separator follows each name). Caller
/// owns the result.
pub fn modulesSignature(allocator: Allocator, modules: []const []const u8) ![]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    for (modules) |m| {
        sha.update(m);
        sha.update("\x00");
    }
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

/// Copies a user hook script into the environment's scripts directory and returns
/// the absolute destination path (caller owns it). Shared by setup and activate.
///
/// Source resolution tries, in order: `hook_path` as-is when absolute, then
/// `cwd_path/hook_path`, then the bare `hook_path` (relative to the process cwd).
/// `dest_dir` MUST already be the absolute scripts directory (callers resolve any
/// cwd join before calling); the script is written to `dest_dir/dest_filename`
/// with mode 0755.
pub fn copyHookScript(
    allocator: Allocator,
    hook_path: []const u8,
    dest_dir: []const u8,
    dest_filename: []const u8,
    cwd_path: []const u8,
) ![]const u8 {
    var source_path: []const u8 = undefined;
    var path_allocd = false;

    if (std.fs.path.isAbsolute(hook_path)) {
        source_path = hook_path;
    } else {
        // Try relative to cwd (where zenv.json is), then the bare filename.
        const rel_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, hook_path });
        defer allocator.free(rel_path);

        if (accessFile(rel_path)) {
            source_path = try allocator.dupe(u8, rel_path);
            path_allocd = true;
        } else if (accessFile(hook_path)) {
            source_path = hook_path;
        } else {
            output.printError(allocator, "Hook script not found: tried '{s}' and '{s}'", .{ hook_path, rel_path }) catch {};
            return error.FileNotFound;
        }
    }
    defer if (path_allocd) allocator.free(source_path);

    if (!accessFile(source_path)) {
        output.printError(allocator, "Hook script found but cannot be read: {s}", .{source_path}) catch {};
        return error.FileNotFound;
    }

    const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_dir, dest_filename });
    errdefer allocator.free(dest_path);

    output.print(allocator, "Copying hook script {s} -> {s}", .{ source_path, dest_path }) catch {};
    const content = runtime.readFileAlloc(allocator, source_path, 10 * 1024 * 1024) catch |err| {
        output.printError(allocator, "Failed to read source hook script '{s}': {s}", .{ source_path, @errorName(err) }) catch {};
        return error.FileNotFound;
    };
    defer allocator.free(content);

    var dest_file = runtime.createFile(dest_path, .{ .permissions = .fromMode(0o755) }) catch |err| {
        output.printError(allocator, "Failed to create destination file '{s}': {s}", .{ dest_path, @errorName(err) }) catch {};
        return error.FileNotFound;
    };
    defer dest_file.close(runtime.io);

    dest_file.writeStreamingAll(runtime.io, content) catch |err| {
        output.printError(allocator, "Error writing to destination file '{s}': {s}", .{ dest_path, @errorName(err) }) catch {};
        return error.FileNotFound;
    };

    output.print(allocator, "Copied hook script from {s} to {s}", .{ source_path, dest_path }) catch {};
    return dest_path;
}

/// Process a template string by replacing placeholders with actual values.
/// Placeholders are in the format @@PLACEHOLDER@@ and are replaced with
/// values from the replacements HashMap.
///
/// Params:
///   - allocator: Memory allocator for the result buffer
///   - template_content: The template string containing placeholders
///   - replacements: A HashMap mapping placeholder names to replacement values
///
/// Returns: A newly allocated string with placeholders replaced, caller owns the memory
pub fn processTemplateString(
    allocator: Allocator,
    template_content: []const u8,
    replacements: std.StringHashMap([]const u8),
) ![]const u8 {
    // Check if we have any placeholders at all to avoid unnecessary work
    if (std.mem.indexOf(u8, template_content, "@@") == null) {
        return allocator.dupe(u8, template_content); // No placeholders, return a copy
    }

    // Pre-scan for placeholders to estimate total result size
    var estimated_size = template_content.len;
    var pos: usize = 0;
    while (pos < template_content.len) {
        const placeholder_start = std.mem.indexOfPos(u8, template_content, pos, "@@") orelse break;
        const placeholder_end = std.mem.indexOfPos(u8, template_content, placeholder_start + 2, "@@") orelse break;

        // Extract placeholder name
        const placeholder_name = template_content[placeholder_start + 2 .. placeholder_end];
        if (replacements.get(placeholder_name)) |replacement| {
            // Adjust the estimated size: remove placeholder size, add replacement size
            estimated_size = estimated_size - (placeholder_end + 2 - placeholder_start) + replacement.len;
        }

        pos = placeholder_end + 2;
    }

    // Use a pre-sized buffer to reduce reallocations
    var result_buffer = try std.array_list.Managed(u8).initCapacity(allocator, estimated_size);
    defer result_buffer.deinit();

    // Process the template - search for @@PLACEHOLDER@@ patterns and replace them
    pos = 0;
    while (pos < template_content.len) {
        // Find the start of a placeholder
        const placeholder_start = std.mem.indexOfPos(u8, template_content, pos, "@@") orelse {
            // No more placeholders, append the rest of the template and exit
            try result_buffer.appendSlice(template_content[pos..]);
            break;
        };

        // Write the content before the placeholder
        try result_buffer.appendSlice(template_content[pos..placeholder_start]);

        // Find the end of the placeholder
        const placeholder_end = std.mem.indexOfPos(u8, template_content, placeholder_start + 2, "@@") orelse {
            // No closing @@ found, treat as literal text
            try result_buffer.appendSlice(template_content[placeholder_start..]);
            break;
        };

        // Extract the placeholder name
        const placeholder_name = template_content[placeholder_start + 2 .. placeholder_end];

        // Check if we have a replacement for this placeholder
        if (replacements.get(placeholder_name)) |replacement| {
            // Replace with the provided value
            try result_buffer.appendSlice(replacement);
        } else {
            // No replacement found, leave the placeholder as is
            try result_buffer.appendSlice(template_content[placeholder_start .. placeholder_end + 2]);
            output.print(allocator, "Warning: No replacement provided for placeholder @@{s}@@", .{placeholder_name}) catch {};
        }

        // Move position to after the placeholder
        pos = placeholder_end + 2;
    }

    return result_buffer.toOwnedSlice();
}

// ============================ Tests ============================

const testing = std.testing;
const test_support = @import("../test_support.zig");

test "processTemplateString replaces a known placeholder" {
    test_support.setupRuntime();
    const a = testing.allocator;
    var repl = std.StringHashMap([]const u8).init(a);
    defer repl.deinit();
    try repl.put("NAME", "world");
    const out = try processTemplateString(a, "hello @@NAME@@!", repl);
    defer a.free(out);
    try testing.expectEqualStrings("hello world!", out);
}

test "processTemplateString leaves an unknown placeholder untouched" {
    test_support.setupRuntime();
    const a = testing.allocator;
    var repl = std.StringHashMap([]const u8).init(a);
    defer repl.deinit();
    const out = try processTemplateString(a, "x @@MISSING@@ y", repl);
    defer a.free(out);
    try testing.expectEqualStrings("x @@MISSING@@ y", out);
}

test "processTemplateString passes through text with no placeholders" {
    const a = testing.allocator;
    var repl = std.StringHashMap([]const u8).init(a);
    defer repl.deinit();
    const out = try processTemplateString(a, "no placeholders here", repl);
    defer a.free(out);
    try testing.expectEqualStrings("no placeholders here", out);
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
