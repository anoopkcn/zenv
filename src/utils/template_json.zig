const std = @import("std");
const Allocator = std.mem.Allocator;
const template = @import("template.zig");

const JSON_CUSTOM_TEMPLATE = @embedFile("templates/zenv.json.template");

pub fn createCustomJsonConfigFromTemplate(
    allocator: Allocator,
    replacements: std.StringHashMap([]const u8),
) ![]const u8 {
    return try template.processTemplateString(allocator, JSON_CUSTOM_TEMPLATE, replacements);
}
