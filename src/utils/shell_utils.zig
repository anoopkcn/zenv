const std = @import("std");
const Allocator = std.mem.Allocator;

// Helper function to escape shell values (single quotes)
// Uses a fixed buffer to avoid memory allocations
pub fn escapeShellValue(value: []const u8, writer: anytype) !void {
    for (value) |char| {
        if (char == '\'') {
            try writer.writeAll("'\\'''");
        } else {
            try writer.writeByte(char);
        }
    }
}