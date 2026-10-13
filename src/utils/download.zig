const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const output = @import("output.zig");
const runtime = @import("runtime.zig");

/// Downloads `url` to `output_path`, streaming the response body straight into
/// the file, with a progress line before and after. On failure the partial
/// file is left for the caller to remove.
pub fn downloadFile(allocator: Allocator, url: []const u8, output_path: []const u8) !void {
    try output.print(allocator, "Downloading {s}", .{url});

    var client = http.Client{ .allocator = allocator, .io = runtime.io };
    defer client.deinit();

    var output_file = try runtime.createFile(output_path, .{});
    defer output_file.close(runtime.io);

    var file_buf: [64 * 1024]u8 = undefined;
    var file_writer = output_file.writer(runtime.io, &file_buf);
    const body_writer = &file_writer.interface;

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = body_writer,
    }) catch |err| {
        try output.printError(allocator, "Failed to download {s}: {s}", .{ url, @errorName(err) });
        return error.HttpError;
    };

    try body_writer.flush();

    if (result.status != .ok) {
        try output.printError(allocator, "Failed to download: HTTP status {d}", .{@backingInt(result.status)});
        return error.StatusError;
    }

    try output.print(allocator, "Download complete: {s}", .{output_path});
}
