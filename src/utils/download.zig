const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const fs = std.fs;
const output = @import("output.zig");
const math = std.math;

/// Helper function to format file sizes in human-readable form
fn formatFileSize(allocator: Allocator, size: usize) ![]const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size_f: f64 = @floatFromInt(size);
    var unit_index: usize = 0;

    while (size_f >= 1024.0 and unit_index < units.len - 1) {
        size_f /= 1024.0;
        unit_index += 1;
    }

    if (unit_index == 0) {
        // Just bytes, no decimal
        const size_int: usize = @intFromFloat(size_f);
        return std.fmt.allocPrint(allocator, "{d} {s}", .{ size_int, units[unit_index] });
    } else {
        // With decimals for KB, MB, etc.
        return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ size_f, units[unit_index] });
    }
}

/// Error set for download operations
pub const DownloadError = error{
    HttpError,
    FileCreationError,
    WriteError,
    StatusError,
    OutOfMemory,
    FileNotFound,
    ReadError,
};

/// Options for downloading files
pub const DownloadOptions = struct {
    /// Show progress output
    show_progress: bool = true,

    /// Follow redirects
    follow_redirects: bool = true,

    /// Maximum number of redirects to follow
    max_redirects: u8 = 10,

    /// Additional HTTP headers
    headers: ?[]const http.Header = null,
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

    // Create HTTP client
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    // Parse URL
    const uri = try std.Uri.parse(url);

    // Allocate buffer for server headers
    var header_buf: [4096]u8 = undefined;

    // Create output file
    var output_file = try fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    // Start the HTTP request
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
    });
    defer req.deinit();

    // Send the HTTP request headers
    try req.send();

    // Finish the body of the request (no body for GET)
    try req.finish();

    // Wait for the response
    try req.wait();

    if (req.response.status != .ok) {
        try output.printError(allocator, "Failed to download: HTTP status {d}", .{@intFromEnum(req.response.status)});
        return error.StatusError;
    }

    // Check if we have Content-Length to show progress
    var total_size: ?u64 = null;
    if (req.response.content_length) |length| {
        total_size = length;
        if (options.show_progress) {
            try output.print(allocator, "Download size: {d} bytes", .{length});
        }
    }

    // Stream the response body to file in chunks
    var total_bytes: usize = 0;
    var buf: [8192]u8 = undefined;
    var last_progress: usize = 0;
    const start_time = std.time.milliTimestamp();

    while (true) {
        const bytes_read = try req.reader().read(&buf);
        if (bytes_read == 0) break; // End of response

        try output_file.writeAll(buf[0..bytes_read]);
        total_bytes += bytes_read;

        // Show progress every ~50KB or at 2% intervals for large files
        if (options.show_progress and
            (total_bytes - last_progress > 50 * 1024 or
                (total_size != null and total_bytes * 50 / total_size.? > last_progress * 50 / total_size.?)))
        {
            last_progress = total_bytes;

            // Calculate speed
            const elapsed_ms = std.time.milliTimestamp() - start_time;
            const elapsed_s = @max(@as(f64, @floatFromInt(elapsed_ms)) / 1000.0, 0.001); // Avoid division by zero
            const speed_kbps = @as(f64, @floatFromInt(total_bytes)) / elapsed_s / 1024.0;

            // Clear current line and move cursor to beginning
            const stdout = std.io.getStdOut().writer();
            try stdout.writeAll("\r\x1b[K"); // ANSI escape code to clear line

            if (total_size) |size| {
                const percent = @as(usize, @intCast(total_bytes * 100 / size));

                // Create progress bar
                var progress_bar: [50]u8 = undefined;
                const bar_length = 30;
                const filled = bar_length * percent / 100;

                for (0..bar_length) |i| {
                    progress_bar[i] = if (i < filled) '=' else ' ';
                }

                // Format file sizes
                const human_total = formatFileSize(allocator, size) catch "?";
                defer if (std.mem.eql(u8, human_total, "?")) {} else allocator.free(human_total);

                const human_current = formatFileSize(allocator, total_bytes) catch "?";
                defer if (std.mem.eql(u8, human_current, "?")) {} else allocator.free(human_current);

                // Print progress bar
                try stdout.print("[{s}{s}] {d}% {s}/{s} ({d:.1} KB/s)", .{ progress_bar[0..filled], progress_bar[filled..bar_length], percent, human_current, human_total, speed_kbps });
            } else {
                // For unknown size, just show downloaded amount and speed
                const human_current = formatFileSize(allocator, total_bytes) catch "?";
                defer if (std.mem.eql(u8, human_current, "?")) {} else allocator.free(human_current);

                try stdout.print("Downloaded: {s} ({d:.1} KB/s)", .{ human_current, speed_kbps });
            }
        }
    }

    // Clear the progress line and move to next line after download completes
    if (options.show_progress) {
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("\n");
    }

    if (options.show_progress) {
        try output.print(allocator, "Download complete: {s} ({d} bytes)", .{ output_path, total_bytes });
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
