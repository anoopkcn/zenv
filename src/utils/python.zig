const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");
const output = @import("output.zig");
const download = @import("download.zig");
const runtime = @import("runtime.zig");

// Define Python versions we know work well
pub const DEFAULT_PYTHON_VERSION = "3.10.8";

// Default installation dir is in the zenv dir/python
pub fn getDefaultInstallDir(allocator: Allocator) ![]const u8 {
    return paths.getPythonInstallDir(allocator);
}

// Get path to the Python version for "use" command
pub fn getPythonVersionPath(allocator: Allocator, version: []const u8) ![]const u8 {
    const base_install_dir = try getDefaultInstallDir(allocator);
    defer allocator.free(base_install_dir);

    const install_dir = try std.fs.path.join(allocator, &[_][]const u8{ base_install_dir, version });
    errdefer allocator.free(install_dir); // returned on success; freed on the error path
    const python_bin = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "bin", "python3" });
    defer allocator.free(python_bin);

    // Check if the Python binary exists
    const python_exists = blk: {
        runtime.access(python_bin) catch |err| {
            if (err == error.FileNotFound) {
                break :blk false;
            }
            // For any other error, we'll assume the file doesn't exist
            output.print(allocator, "Warning: Error checking Python executable: {s}", .{@errorName(err)}) catch {};
            break :blk false;
        };
        break :blk true;
    };

    if (!python_exists) {
        output.printError(allocator, "Python version {s} is not installed", .{version}) catch {};
        output.printError(allocator, "Use 'zenv python install {s}' to install it first", .{version}) catch {};
        return error.FileNotFound;
    }

    return install_dir;
}

// List all installed Python versions
pub fn listInstalledVersions(allocator: Allocator) !void {
    const base_install_dir = try getDefaultInstallDir(allocator);
    defer allocator.free(base_install_dir);

    // Get stdout writer
    var stdout_buf: [2048]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writerStreaming(runtime.io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    defer stdout.flush() catch {};

    var dir = runtime.openDir(base_install_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            output.print(allocator, "No Python versions installed yet", .{}) catch {};
            output.print(allocator, "Use 'zenv python install <version>' to install a Python version", .{}) catch {};
            return;
        }
        return err;
    };
    defer dir.close(runtime.io);

    var installed_count: usize = 0;
    const default_path = try getDefaultPythonPath(allocator);
    defer if (default_path) |path| allocator.free(path);

    var it = dir.iterate();
    while (try it.next(runtime.io)) |entry| {
        if (entry.kind != .directory) continue;

        const version_dir = entry.name;
        const python_path = try std.fs.path.join(allocator, &[_][]const u8{ base_install_dir, version_dir, "bin", "python3" });
        defer allocator.free(python_path);

        // Check if the Python binary exists in this directory
        const python_exists = blk: {
            runtime.access(python_path) catch |err| {
                if (err == error.FileNotFound) {
                    break :blk false;
                }
                // For any other error, we'll assume the file doesn't exist
                output.print(allocator, "Warning: Error checking Python executable: {s}", .{@errorName(err)}) catch {};
                break :blk false;
            };
            break :blk true;
        };
        if (!python_exists) continue;

        // Check if this is the default version
        var is_default = false;
        if (default_path) |path| {
            const install_path = try std.fs.path.join(allocator, &[_][]const u8{ base_install_dir, version_dir });
            defer allocator.free(install_path);
            is_default = std.mem.eql(u8, install_path, path);
        }

        if (is_default) {
            stdout.print("{s} (pinned)\n", .{version_dir}) catch {};
        } else {
            stdout.print("{s}\n", .{version_dir}) catch {};
        }
        installed_count += 1;
    }

    if (installed_count == 0) {
        output.print(allocator, "No Python versions installed yet", .{}) catch {};
        output.print(allocator, "Use 'zenv python install <version>' to install a Python version", .{}) catch {};
    }
}

// Write the default Python path to a file
pub fn setDefaultPythonPath(allocator: Allocator, version: []const u8) !void {
    // Ensure zenv directory exists
    const zenv_dir = try paths.ensureZenvDir(allocator);
    defer allocator.free(zenv_dir);

    // Get the full path to the Python installation
    const python_path = try getPythonVersionPath(allocator, version);
    defer allocator.free(python_path);

    // Create/overwrite the default-python file
    const default_file_path = try std.fs.path.join(allocator, &[_][]const u8{ zenv_dir, "default-python" });
    defer allocator.free(default_file_path);

    try runtime.writeFile(default_file_path, python_path);

    // Get stdout writer
    output.print(allocator, "Set Python {s} as the default version", .{version}) catch {};
    output.print(allocator, "This will be used as the fallback Python when not specified in zenv.json", .{}) catch {};
}

// Get the default Python path from the saved file
pub fn getDefaultPythonPath(allocator: Allocator) !?[]const u8 {
    const default_file_path = try paths.getDefaultPythonFilePath(allocator);
    defer allocator.free(default_file_path);

    const content = runtime.readFileAlloc(allocator, default_file_path, 1024) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        // For other errors, propagate them so they can be handled by the central error handler
        output.printError(allocator, "Failed to read default-python file: {s}", .{@errorName(err)}) catch {}; // Keep user informed
        return err; // Propagate the error
    };
    defer allocator.free(content);

    // Return an independently-owned copy: trimming yields a sub-slice of `content`
    // whose pointer/len no longer match the original allocation, so callers could
    // not safely free it otherwise.
    const trimmed = std.mem.trim(u8, content, "\n\r\t ");
    return try allocator.dupe(u8, trimmed);
}

// Download the Python source code for the specified version
pub fn downloadPythonSource(allocator: Allocator, version: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "https://www.python.org/ftp/python/{s}/Python-{s}.tgz", .{ version, version });
    defer allocator.free(url);

    const filename = try std.fmt.allocPrint(allocator, "Python-{s}.tgz", .{version});
    defer allocator.free(filename);

    // Use our download utility instead of curl
    const dl_path = try download.downloadToTemp(allocator, url, filename, .{
        .show_progress = true,
    });

    return dl_path;
}

// Extract the downloaded tarball
pub fn extractPythonSource(allocator: Allocator, tarball_path: []const u8, target_dir: []const u8) ![]const u8 {
    // Make sure the target directory exists
    runtime.makePath(target_dir) catch |err| {
        output.printError(allocator, "Failed to create directory '{s}': {s}", .{ target_dir, @errorName(err) }) catch {};
        return err;
    };

    output.print(allocator, "Extracting {s} to {s}", .{ tarball_path, target_dir }) catch {};

    // Run tar to extract the file
    var child = try std.process.spawn(runtime.io, .{
        .argv = &[_][]const u8{ "tar", "-xzf", tarball_path, "-C", target_dir },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    _ = try child.wait(runtime.io);

    // Get the extracted directory name (Python-VERSION)
    const filename = std.fs.path.basename(tarball_path);
    const dirname = filename[0 .. filename.len - 4]; // Remove .tgz
    const source_dir = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, dirname });

    return source_dir;
}

// Run a command with its output streamed straight to the user's terminal.
// Returns true on a clean (status 0) exit.
fn runStreamedCommand(args: []const []const u8, cwd: []const u8) !bool {
    var child = try std.process.spawn(runtime.io, .{
        .argv = args,
        .cwd = .{ .path = cwd },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(runtime.io);
    return term == .exited and term.exited == 0;
}

// Configure and build Python
pub fn buildPython(allocator: Allocator, source_dir: []const u8, install_dir: []const u8) !void {
    output.print(allocator, "Configuring Python build in {s}", .{source_dir}) catch {};
    output.print(allocator, "Python will be installed to {s}", .{install_dir}) catch {};

    // Create a clean directory for the build
    runtime.makePath(install_dir) catch |err| {
        output.printError(allocator, "Failed to create installation directory '{s}': {s}", .{ install_dir, @errorName(err) }) catch {};
        return err;
    };

    // Ensure the source directory is accessible before configuring
    runtime.access(source_dir) catch |err| {
        output.printError(allocator, "Cannot access source directory '{s}': {s}", .{ source_dir, @errorName(err) }) catch {};
        return err;
    };

    const install_start = runtime.nowMillis();

    // Run configure
    output.print(allocator, "Configuring Python (./configure)...", .{}) catch {};

    var config_args = [_][]const u8{
        "./configure",
        "--prefix",
        install_dir,
        "--enable-optimizations",
        "--disable-test-modules",
        "--with-ensurepip=install",
    };

    if (!try runStreamedCommand(&config_args, source_dir)) {
        output.printError(allocator, "Configuration failed (see output above)", .{}) catch {};
        return error.ConfigureFailed;
    }

    // Determine the number of CPU cores for the parallel build, leaving one
    // core free to keep the system responsive (fall back to 1 on failure).
    const cores_to_use = if (std.Thread.getCpuCount()) |count|
        @max(count - 1, 1)
    else |_|
        1;
    const cpu_count = try std.fmt.allocPrint(allocator, "{d}", .{cores_to_use});
    defer allocator.free(cpu_count);

    // Run make
    output.print(allocator, "Building Python (make -j {s})...", .{cpu_count}) catch {};

    var make_args = [_][]const u8{ "make", "-j", cpu_count };

    if (!try runStreamedCommand(&make_args, source_dir)) {
        output.printError(allocator, "Build failed (see output above)", .{}) catch {};
        return error.BuildFailed;
    }

    // Run make install
    output.print(allocator, "Installing Python (make install)...", .{}) catch {};

    var install_args = [_][]const u8{ "make", "install" };

    if (!try runStreamedCommand(&install_args, source_dir)) {
        output.printError(allocator, "Installation failed (see output above)", .{}) catch {};
        return error.InstallFailed;
    }

    // Calculate total installation time
    const elapsed_ms = runtime.nowMillis() - install_start;
    const elapsed_minutes = @divFloor(elapsed_ms, 60000);
    const elapsed_seconds = @mod(@divFloor(elapsed_ms, 1000), 60);

    output.print(allocator, "Python installation completed successfully in {d}m {d}s", .{ elapsed_minutes, elapsed_seconds }) catch {};
}

// Main function to install Python
pub fn installPython(allocator: Allocator, version: ?[]const u8) !void {
    const python_version = version orelse DEFAULT_PYTHON_VERSION;

    // Get the installation directory
    const base_install_dir = try getDefaultInstallDir(allocator);
    defer allocator.free(base_install_dir);

    const install_dir = try std.fs.path.join(allocator, &[_][]const u8{ base_install_dir, python_version });
    defer allocator.free(install_dir);

    // Check if this version is already installed
    const python_bin = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "bin", "python3" });
    defer allocator.free(python_bin);

    const python_exists = blk: {
        runtime.access(python_bin) catch |err| {
            if (err == error.FileNotFound) {
                break :blk false;
            }
            // For any other error, we'll assume the file doesn't exist
            output.print(allocator, "Warning: Error checking Python executable: {s}", .{@errorName(err)}) catch {};
            break :blk false;
        };
        break :blk true;
    };

    if (python_exists) {
        output.print(allocator, "Python {s} is already installed at {s}", .{ python_version, install_dir }) catch {};
        output.print(allocator, "To reinstall, first remove the directory manually: rm -rf {s}", .{install_dir}) catch {};
        return;
    }

    // Create a temporary build directory
    const build_dir = "/tmp/zenv_python_build";
    runtime.makePath(build_dir) catch |err| {
        output.printError(allocator, "Failed to create build directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    // Download the Python source
    const tarball_path = try downloadPythonSource(allocator, python_version);
    defer allocator.free(tarball_path);
    defer runtime.deleteFile(tarball_path) catch |err| {
        output.print(allocator, "Warning: Failed to delete temporary file {s}: {s}\n", .{ tarball_path, @errorName(err) }) catch {};
    };

    // Extract the source
    const source_dir = try extractPythonSource(allocator, tarball_path, build_dir);
    defer allocator.free(source_dir);
    defer runtime.deleteTree(source_dir) catch |err| {
        output.print(allocator, "Warning: Failed to delete temporary directory {s}: {s}", .{ source_dir, @errorName(err) }) catch {};
    };

    // Build and install Python
    try buildPython(allocator, source_dir, install_dir);

    // Print success message with actual paths
    output.print(allocator, "Python {s} has been successfully installed!", .{python_version}) catch {};
    output.print(allocator, "Installation path: {s}", .{install_dir}) catch {};
    output.print(allocator, "This Python version has been pinned 'ZENV_DIR/default-python'", .{}) catch {};
}
