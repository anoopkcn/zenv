const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");
const output = @import("output.zig");
const download = @import("download.zig");
const runtime = @import("runtime.zig");

// Define Python versions we know work well
pub const DEFAULT_PYTHON_VERSION = "3.10.8";

/// True when `<dir>/bin/python3` exists. Any error other than FileNotFound is
/// warned about and counts as absent.
fn hasPython3(allocator: Allocator, dir: []const u8) !bool {
    const python_bin = try std.Io.Dir.path.join(allocator, &[_][]const u8{ dir, "bin", "python3" });
    defer allocator.free(python_bin);
    runtime.access(python_bin) catch |err| {
        if (err != error.FileNotFound) output.print(allocator, "Warning: Error checking Python executable: {s}", .{@errorName(err)}) catch {};
        return false;
    };
    return true;
}

// Get path to the Python version for "use" command
fn getPythonVersionPath(allocator: Allocator, version: []const u8) ![]const u8 {
    const base_install_dir = try paths.zenvPath(allocator, "python");
    defer allocator.free(base_install_dir);

    const install_dir = try std.Io.Dir.path.join(allocator, &[_][]const u8{ base_install_dir, version });
    errdefer allocator.free(install_dir); // returned on success; freed on the error path

    if (!try hasPython3(allocator, install_dir)) {
        output.printError(allocator, "Python version {s} is not installed", .{version}) catch {};
        output.printError(allocator, "Use 'zenv python install {s}' to install it first", .{version}) catch {};
        return error.FileNotFound;
    }

    return install_dir;
}

// List all installed Python versions
pub fn listInstalledVersions(allocator: Allocator) !void {
    const base_install_dir = try paths.zenvPath(allocator, "python");
    defer allocator.free(base_install_dir);

    var installed_count: usize = 0;
    if (runtime.openDir(base_install_dir, .{ .iterate = true })) |dir| {
        defer dir.close(runtime.io);

        const default_path = try getDefaultPythonPath(allocator);
        defer if (default_path) |path| allocator.free(path);

        var it = dir.iterate();
        while (try it.next(runtime.io)) |entry| {
            if (entry.kind != .directory) continue;

            const install_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ base_install_dir, entry.name });
            defer allocator.free(install_path);
            if (!try hasPython3(allocator, install_path)) continue;

            const is_default = if (default_path) |path| std.mem.eql(u8, install_path, path) else false;
            output.rawOut(allocator, "{s}{s}\n", .{ entry.name, if (is_default) " (pinned)" else "" }) catch {};
            installed_count += 1;
        }
    } else |err| if (err != error.FileNotFound) return err;

    if (installed_count == 0) {
        output.print(allocator, "No Python versions installed yet", .{}) catch {};
        output.print(allocator, "Use 'zenv python install <version>' to install a Python version", .{}) catch {};
    }
}

// Write the default Python path to a file
pub fn setDefaultPythonPath(allocator: Allocator, version: []const u8) !void {
    // Creates the zenv directory if needed.
    const default_file_path = try paths.ensureZenvPath(allocator, "default-python");
    defer allocator.free(default_file_path);

    // Get the full path to the Python installation
    const python_path = try getPythonVersionPath(allocator, version);
    defer allocator.free(python_path);

    try runtime.writeFile(default_file_path, python_path);

    output.print(allocator, "Set Python {s} as the default version", .{version}) catch {};
    output.print(allocator, "This will be used as the fallback Python when not specified in zenv.json", .{}) catch {};
}

// Get the default Python path from the saved file
pub fn getDefaultPythonPath(allocator: Allocator) !?[]const u8 {
    const default_file_path = try paths.zenvPath(allocator, "default-python");
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

/// Extracts `tarball` into `build_dir` and returns the source directory it
/// holds, `<build_dir>/Python-<version>` (caller owns it).
fn extractPythonSource(allocator: Allocator, tarball: []const u8, build_dir: []const u8, version: []const u8) ![]const u8 {
    output.print(allocator, "Extracting {s} to {s}", .{ tarball, build_dir }) catch {};

    const term = try runtime.exec(&[_][]const u8{ "tar", "-xzf", tarball, "-C", build_dir }, .{});
    if (!runtime.exitedOk(term)) {
        output.printError(allocator, "Extraction failed (see output above)", .{}) catch {};
        return error.ExtractFailed;
    }

    return allocator.print("{s}/Python-{s}", .{ build_dir, version });
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

    // Determine the number of CPU cores for the parallel build, leaving one
    // core free to keep the system responsive (fall back to 1 on failure).
    const cores_to_use = if (std.Thread.getCpuCount()) |count|
        @max(count - 1, 1)
    else |_|
        1;
    const cpu_count = try allocator.print("{d}", .{cores_to_use});
    defer allocator.free(cpu_count);
    const make_msg = try allocator.print("Building Python (make -j {s})...", .{cpu_count});
    defer allocator.free(make_msg);

    // Each step's output streams straight to the user's terminal.
    const Step = struct { msg: []const u8, argv: []const []const u8, failed: []const u8, err: error{ ConfigureFailed, BuildFailed, InstallFailed } };
    const steps = [_]Step{
        .{ .msg = "Configuring Python (./configure)...", .argv = &.{ "./configure", "--prefix", install_dir, "--enable-optimizations", "--disable-test-modules", "--with-ensurepip=install" }, .failed = "Configuration failed", .err = error.ConfigureFailed },
        .{ .msg = make_msg, .argv = &.{ "make", "-j", cpu_count }, .failed = "Build failed", .err = error.BuildFailed },
        .{ .msg = "Installing Python (make install)...", .argv = &.{ "make", "install" }, .failed = "Installation failed", .err = error.InstallFailed },
    };
    for (steps) |step| {
        output.print(allocator, "{s}", .{step.msg}) catch {};
        const term = try runtime.exec(step.argv, .{ .cwd = source_dir });
        if (!runtime.exitedOk(term)) {
            output.printError(allocator, "{s} (see output above)", .{step.failed}) catch {};
            return step.err;
        }
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
    const base_install_dir = try paths.zenvPath(allocator, "python");
    defer allocator.free(base_install_dir);

    const install_dir = try std.Io.Dir.path.join(allocator, &[_][]const u8{ base_install_dir, python_version });
    defer allocator.free(install_dir);

    // Check if this version is already installed
    if (try hasPython3(allocator, install_dir)) {
        output.print(allocator, "Python {s} is already installed at {s}", .{ python_version, install_dir }) catch {};
        output.print(allocator, "To reinstall, first remove the directory manually: rm -rf {s}", .{install_dir}) catch {};
        return;
    }

    // Per-process build directory under $TMPDIR (shared login nodes). The
    // tarball and the extracted sources live in it and are removed with it.
    const build_dir = try allocator.print("{s}/zenv-python-build-{d}", .{ runtime.tempDir(), runtime.processId() });
    defer allocator.free(build_dir);
    runtime.makePath(build_dir) catch |err| {
        output.printError(allocator, "Failed to create build directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    defer runtime.deleteTree(build_dir) catch |err| {
        output.print(allocator, "Warning: Failed to delete temporary directory {s}: {s}", .{ build_dir, @errorName(err) }) catch {};
    };

    // Download the Python source
    const url = try allocator.print("https://www.python.org/ftp/python/{s}/Python-{s}.tgz", .{ python_version, python_version });
    defer allocator.free(url);
    const tarball_path = try allocator.print("{s}/Python-{s}.tgz", .{ build_dir, python_version });
    defer allocator.free(tarball_path);
    try download.downloadFile(allocator, url, tarball_path);

    // Extract the source
    const source_dir = try extractPythonSource(allocator, tarball_path, build_dir, python_version);
    defer allocator.free(source_dir);

    // Build and install Python
    try buildPython(allocator, source_dir, install_dir);

    // Print success message with actual paths
    output.print(allocator, "Python {s} has been successfully installed!", .{python_version}) catch {};
    output.print(allocator, "Installation path: {s}", .{install_dir}) catch {};
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");

test "hasPython3 checks for bin/python3" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const dir = try std.Io.Dir.path.join(a, &[_][]const u8{ runtime.tempDir(), "zenv_python_test" });
    defer a.free(dir);
    runtime.deleteTree(dir) catch {};
    defer runtime.deleteTree(dir) catch {};

    try runtime.makePath(dir);
    try testing.expect(!try hasPython3(a, dir));

    const bin = try std.Io.Dir.path.join(a, &[_][]const u8{ dir, "bin" });
    defer a.free(bin);
    try runtime.makePath(bin);
    const python3 = try std.Io.Dir.path.join(a, &[_][]const u8{ bin, "python3" });
    defer a.free(python3);
    try runtime.writeFile(python3, "");
    try testing.expect(try hasPython3(a, dir));
}

test "extractPythonSource names the tarball's directory and fails with tar" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const prev = test_support.useFakeExec();
    defer runtime.exec_backend = prev;

    test_support.fake_exec_exit = 0;
    const source_dir = try extractPythonSource(a, "/b/Python-3.12.1.tgz", "/b", "3.12.1");
    defer a.free(source_dir);
    try testing.expectEqualStrings("/b/Python-3.12.1", source_dir);

    test_support.fake_exec_exit = 2; // e.g. a truncated download
    defer test_support.fake_exec_exit = 0;
    try testing.expectError(error.ExtractFailed, extractPythonSource(a, "/b/Python-3.12.1.tgz", "/b", "3.12.1"));
}
