const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

pub fn escapeShellValue(value: []const u8, writer: anytype) !void {
    for (value) |char| {
        if (char == '\'') {
            try writer.writeAll("'\\'''");
        } else {
            try writer.writeByte(char);
        }
    }
}

// Template placeholder replacement function for string templates
pub fn processTemplateString(
    allocator: Allocator,
    template_content: []const u8,
    replacements: std.StringHashMap([]const u8),
) ![]const u8 {
    // Create a buffer for the processed content
    var result_buffer = std.ArrayList(u8).init(allocator);
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

        // Check if we have a replacement for this placeholder
        if (replacements.get(placeholder_name)) |replacement| {
            // Replace with the provided value
            try writer.writeAll(replacement);
        } else {
            // No replacement found, leave the placeholder as is
            try writer.writeAll(template_content[placeholder_start .. placeholder_end + 2]);
            std.log.warn("No replacement provided for placeholder @@{s}@@", .{placeholder_name});
        }

        // Move position to after the placeholder
        pos = placeholder_end + 2;
    }

    return result_buffer.toOwnedSlice();
}
