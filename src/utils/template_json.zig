const std = @import("std");
const Allocator = std.mem.Allocator;
const template = @import("template.zig");

// Embed the template file at compile time
const JSON_TEMPLATE = @embedFile("templates/zenv.json.template");

/// Creates a templated JSON configuration file with provided replacements
pub fn createJsonConfigFromTemplate(allocator: Allocator, replacements: std.StringHashMap([]const u8)) ![]const u8 {
    // Process the template
    return try template.processTemplateString(allocator, JSON_TEMPLATE, replacements);
}