const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const errors = @import("errors.zig");
const output = @import("output.zig");

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
    // Use a pre-sized buffer to reduce reallocations
    var result_buffer = try std.ArrayList(u8).initCapacity(allocator, template_content.len);
    defer result_buffer.deinit();
    const writer = result_buffer.writer();

    // Process the template - search for @@PLACEHOLDER@@ patterns and replace them
    var pos: usize = 0;
    while (pos < template_content.len) {
        // Find the start of a placeholder
        const placeholder_start = std.mem.indexOfPos(u8, template_content, pos, "@@") orelse {
            // No more placeholders, append the rest of the template and exit
            try writer.writeAll(template_content[pos..]);
            break;
        };

        // Write the content before the placeholder
        try writer.writeAll(template_content[pos..placeholder_start]);

        // Find the end of the placeholder
        const placeholder_end = std.mem.indexOfPos(u8, template_content, placeholder_start + 2, "@@") orelse {
            // No closing @@ found, treat as literal text
            try writer.writeAll(template_content[placeholder_start..]);
            break;
        };

        // Extract the placeholder name
        const placeholder_name = template_content[placeholder_start + 2 .. placeholder_end];

        // Check if we have a replacement for this placeholder using get()
        if (replacements.get(placeholder_name)) |replacement| {
            // Replace with the provided value
            try writer.writeAll(replacement);
        } else {
            // No replacement found, leave the placeholder as is
            try writer.writeAll(template_content[placeholder_start .. placeholder_end + 2]);
            try output.print("Warning: No replacement provided for placeholder @@{s}@@", .{placeholder_name});
        }

        // Move position to after the placeholder
        pos = placeholder_end + 2;
    }

    return result_buffer.toOwnedSlice();
}
