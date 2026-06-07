const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const output = @import("output.zig");
const runtime = @import("runtime.zig");

/// Options for downloading files
pub const DownloadOptions = struct {
    /// Show progress output
    show_progress: bool = true,
};

/// Downloads a file from a URL to a local path
///
/// Params:
///   - allocator: Memory allocator for temporary storage
///   - url: The URL to download from
///   - output_path: The local file path to save the downloaded content
///   - options: Additional download options
///
/// Returns: void, or an error if the download fails
pub fn downloadFile(
    allocator: Allocator,
    url: []const u8,
    output_path: []const u8,
    options: DownloadOptions,
) !void {
    if (options.show_progress) {
        try output.print(allocator, "Downloading {s}", .{url});
    }

    // Create HTTP client (Zig 0.16 threads Io through the client).
    var client = http.Client{ .allocator = allocator, .io = runtime.io };
    defer client.deinit();

    // Create the output file and stream the response body straight into it.
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
        try output.printError(allocator, "Failed to download: HTTP status {d}", .{@intFromEnum(result.status)});
        return error.StatusError;
    }

    if (options.show_progress) {
        try output.print(allocator, "Download complete: {s}", .{output_path});
    }
}

/// Downloads a file and returns the path to the downloaded file
///
/// Params:
///   - allocator: Memory allocator for temporary storage
///   - url: The URL to download from
///   - filename: The filename to save as (will be saved to temp directory)
///   - options: Additional download options
///
/// Returns: The path to the downloaded file, caller owns the memory
pub fn downloadToTemp(
    allocator: Allocator,
    url: []const u8,
    filename: []const u8,
    options: DownloadOptions,
) ![]const u8 {
    const temp_dir = "/tmp";
    const dl_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, filename });
    errdefer allocator.free(dl_path);

    try downloadFile(allocator, url, dl_path, options);

    return dl_path;
}
