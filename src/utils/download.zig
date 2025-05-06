const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const fs = std.fs;
const output = @import("output.zig");

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
        try output.print("Downloading {s}", .{url});
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
        try output.printError("Failed to download: HTTP status {d}", .{@intFromEnum(req.response.status)});
        return error.StatusError;
    }
    
    // Check if we have Content-Length to show progress
    var total_size: ?u64 = null;
    if (req.response.content_length) |length| {
        total_size = length;
        if (options.show_progress) {
            try output.print("Download size: {d} bytes", .{length});
        }
    }
    
    // Stream the response body to file in chunks
    var total_bytes: usize = 0;
    var buf: [8192]u8 = undefined;
    var last_progress: usize = 0;
    
    while (true) {
        const bytes_read = try req.reader().read(&buf);
        if (bytes_read == 0) break; // End of response
        
        try output_file.writeAll(buf[0..bytes_read]);
        total_bytes += bytes_read;
        
        // Show progress every ~100KB or at 5% intervals for large files
        if (options.show_progress and 
            (total_bytes - last_progress > 100 * 1024 or
             (total_size != null and total_bytes * 20 / total_size.? > last_progress * 20 / total_size.?))) {
            last_progress = total_bytes;
            if (total_size) |size| {
                const percent = @as(usize, @intCast(total_bytes * 100 / size));
                try output.print("Progress: {d}% ({d}/{d} bytes)", .{percent, total_bytes, size});
            } else {
                try output.print("Downloaded: {d} bytes", .{total_bytes});
            }
        }
    }
    
    if (options.show_progress) {
        try output.print("Download complete: {s} ({d} bytes)", .{
            output_path, total_bytes
        });
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