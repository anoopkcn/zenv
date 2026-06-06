const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const errors = @import("errors.zig");
const output = @import("output.zig");

/// On-disk format version of the module-environment cache. Written into the
/// stamp at setup and checked at activation; bump this when the capture/replay
/// format changes so existing caches are invalidated (fall back to `module load`).
pub const MODULE_CACHE_VERSION: u32 = 1;

/// Basenames of the cache artifacts written into the venv directory.
pub const MODULE_CACHE_FILE = ".zenv_module_cache.sh";
pub const MODULE_CACHE_STAMP = ".zenv_module_cache.stamp";

/// Escapes a shell value by handling special characters, particularly single quotes.
/// This ensures the value can be safely used in shell script strings.
///
/// Params:
///   - value: The string value to escape
///   - writer: Any writer that implements std.io.Writer
///
/// Returns: Error if writing fails
pub fn escapeShellValue(value: []const u8, writer: anytype) !void {
    for (value) |char| {
        if (char == '\'') {
            try writer.writeAll("\'\\'''"); // Handle single quotes in shell: close quote, escaped quote, reopen quote
        } else {
            try writer.writeByte(char);
        }
    }
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
