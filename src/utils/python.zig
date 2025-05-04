const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const process = std.process;
const paths = @import("paths.zig");
const output = @import("output.zig");

// Define Python versions we know work well
const DEFAULT_PYTHON_VERSION = "3.10.8";

// Default installation dir is in the zenv dir/python
pub fn getDefaultInstallDir(allocator: Allocator) ![]const u8 {
    return paths.getPythonInstallDir(allocator);
}

// Get path to the Python version for "use" command
pub fn getPythonVersionPath(allocator: Allocator, version: []const u8) ![]const u8 {
    const base_install_dir = try getDefaultInstallDir(allocator);
    defer allocator.free(base_install_dir);

    const install_dir = try std.fs.path.join(allocator, &[_][]const u8{base_install_dir, version});
    const python_bin = try std.fs.path.join(allocator, &[_][]const u8{install_dir, "bin", "python3"});

    // Check if the Python binary exists
    const python_exists = blk: {
        fs.cwd().access(python_bin, .{}) catch |err| {
            if (err == error.FileNotFound) {
                break :blk false;
            }
            // For any other error, we'll assume the file doesn't exist
            try output.print("Warning: Error checking Python executable: {s}", .{@errorName(err)});
            break :blk false;
        };
        break :blk true;
    };

    if (!python_exists) {
        output.printError("Python version {s} is not installed", .{version}) catch {};
        output.printError("Use 'zenv python install {s}' to install it first", .{version}) catch {};
        return error.FileNotFound;
    }

    allocator.free(python_bin);
    return install_dir;
}

// List all installed Python versions
pub fn listInstalledVersions(allocator: Allocator) !void {
    const base_install_dir = try getDefaultInstallDir(allocator);
    defer allocator.free(base_install_dir);

    // Get stdout writer

    var dir = fs.cwd().openDir(base_install_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            output.print("No Python versions installed yet", .{}) catch {};
            output.print("Use 'zenv python install <version>' to install a Python version", .{}) catch {};
            return;
        }
        return err;
    };
    defer dir.close();

    var installed_count: usize = 0;
    const default_path = try getDefaultPythonPath(allocator);
    defer if (default_path) |path| allocator.free(path);

    output.print("Installed Python versions:", .{}) catch {};

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        const version_dir = entry.name;
        const python_path = try std.fs.path.join(allocator, &[_][]const u8{base_install_dir, version_dir, "bin", "python3"});
        defer allocator.free(python_path);

        // Check if the Python binary exists in this directory
        const python_exists = blk: {
            fs.cwd().access(python_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    break :blk false;
                }
                // For any other error, we'll assume the file doesn't exist
                try output.print("Warning: Error checking Python executable: {s}", .{@errorName(err)});
                break :blk false;
            };
            break :blk true;
        };
        if (!python_exists) continue;

        // Check if this is the default version
        var is_default = false;
        if (default_path) |path| {
            const install_path = try std.fs.path.join(allocator, &[_][]const u8{base_install_dir, version_dir});
            defer allocator.free(install_path);
            is_default = std.mem.eql(u8, install_path, path);
        }

        if (is_default) {
            output.print("{s} (default)", .{version_dir}) catch {};
        } else {
            output.print("{s}", .{version_dir}) catch {};
        }
        installed_count += 1;
    }

    if (installed_count == 0) {
        output.print("No Python versions installed yet\n", .{}) catch {};
        output.print("Use 'zenv python install <version>' to install a Python version", .{}) catch {};
    } else {
        output.print("Use 'zenv python use <version>' to set a version as default", .{}) catch {};
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
    const default_file_path = try std.fs.path.join(allocator, &[_][]const u8{zenv_dir, "default-python"});
    defer allocator.free(default_file_path);

    var file = try fs.cwd().createFile(default_file_path, .{});
    defer file.close();

    try file.writeAll(python_path);
    try file.sync();

    // Get stdout writer
    output.print("Set Python {s} as the default version", .{version}) catch {};
    output.print("This will be used as the fallback Python when not specified in zenv.json", .{}) catch {};
}

// Get the default Python path from the saved file
pub fn getDefaultPythonPath(allocator: Allocator) !?[]const u8 {
    const default_file_path = try paths.getDefaultPythonFilePath(allocator);
    defer allocator.free(default_file_path);

    const content = fs.cwd().readFileAlloc(allocator, default_file_path, 1024) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        output.printError("Failed to read default-python file: {s}", .{@errorName(err)}) catch {};
        return null;
    };

    return std.mem.trim(u8, content, "\n\r\t ");
}

// Download the Python source code for the specified version
pub fn downloadPythonSource(allocator: Allocator, version: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "https://www.python.org/ftp/python/{s}/Python-{s}.tgz", .{version, version});
    defer allocator.free(url);

    const filename = try std.fmt.allocPrint(allocator, "Python-{s}.tgz", .{version});
    defer allocator.free(filename);

    try output.print("Downloading Python {s} from {s}", .{version, url});

    // Create a temporary directory for downloads
    const temp_dir = "/tmp";
    const dl_path = try std.fs.path.join(allocator, &[_][]const u8{temp_dir, filename});

    // Run curl to download the file
    var curl_args = [_][]const u8{"curl", "-fsSL", url, "-o", dl_path};
    var child = std.process.Child.init(&curl_args, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    _ = try child.spawnAndWait();

    return dl_path;
}

// Extract the downloaded tarball
pub fn extractPythonSource(allocator: Allocator, tarball_path: []const u8, target_dir: []const u8) ![]const u8 {
    // Make sure the target directory exists
    fs.cwd().makePath(target_dir) catch |err| {
        output.printError("Failed to create directory '{s}': {s}", .{target_dir, @errorName(err)}) catch {};
        return err;
    };

    try output.print("Extracting {s} to {s}", .{tarball_path, target_dir});

    // Run tar to extract the file
    var tar_args = [_][]const u8{"tar", "-xzf", tarball_path, "-C", target_dir};
    var child = std.process.Child.init(&tar_args, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    _ = try child.spawnAndWait();

    // Get the extracted directory name (Python-VERSION)
    const filename = std.fs.path.basename(tarball_path);
    const dirname = filename[0 .. filename.len - 4]; // Remove .tgz
    const source_dir = try std.fs.path.join(allocator, &[_][]const u8{target_dir, dirname});

    return source_dir;
}

// Configure and build Python
pub fn buildPython(allocator: Allocator, source_dir: []const u8, install_dir: []const u8) !void {
    try output.print("Configuring Python build in {s}", .{source_dir});
    try output.print("Python will be installed to {s}", .{install_dir});

    // Create a clean directory for the build
    fs.cwd().makePath(install_dir) catch |err| {
        output.printError("Failed to create installation directory '{s}': {s}", .{install_dir, @errorName(err)}) catch {};
        return err;
    };

    // Change to the source directory for configuration
    var dir = fs.cwd();
    dir.access(source_dir, .{}) catch |err| {
        output.printError("Cannot access source directory '{s}': {s}", .{source_dir, @errorName(err)}) catch {};
        return err;
    };

    // Run configure
    {
        var config_args = [_][]const u8{
            "./configure",
            "--prefix", install_dir,
            "--enable-optimizations",
            "--with-ensurepip=install",
        };

        var child = std.process.Child.init(&config_args, allocator);
        child.cwd = source_dir;
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;

        const result = try child.spawnAndWait();
        if (result.Exited != 0) {
            return error.ConfigureFailed;
        }
    }

    // Determine the number of CPU cores for parallel build
    var cpu_count = try allocator.dupeZ(u8, "4"); // Default to 4 cores as a safe value
    defer allocator.free(cpu_count);

    // Try to get the actual CPU count if possible
    if (std.Thread.getCpuCount()) |count| {
        if (count > 1) {
            const cores_to_use = @max(count - 1, 1); // Use one less than available to avoid system freeze
            allocator.free(cpu_count);
            cpu_count = try std.fmt.allocPrintZ(allocator, "{d}", .{cores_to_use});
        }
    } else |_| {
        // If we can't get the CPU count, stick with default
    }

    // Run make
    {
        var make_args = [_][]const u8{"make", "-j", cpu_count};

        var child = std.process.Child.init(&make_args, allocator);
        child.cwd = source_dir;
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;

        const result = try child.spawnAndWait();
        if (result.Exited != 0) {
            return error.BuildFailed;
        }
    }

    // Run make install
    {
        var install_args = [_][]const u8{"make", "install"};

        var child = std.process.Child.init(&install_args, allocator);
        child.cwd = source_dir;
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;

        const result = try child.spawnAndWait();
        if (result.Exited != 0) {
            return error.InstallFailed;
        }
    }

    try output.print("Python installation completed successfully", .{});
}

// Main function to install Python
pub fn installPython(allocator: Allocator, version: ?[]const u8) !void {
    const python_version = version orelse DEFAULT_PYTHON_VERSION;

    try output.print("Installing Python version {s}", .{python_version});

    // Get the installation directory
    const base_install_dir = try getDefaultInstallDir(allocator);
    defer allocator.free(base_install_dir);

    const install_dir = try std.fs.path.join(allocator, &[_][]const u8{base_install_dir, python_version});
    defer allocator.free(install_dir);

    // Check if this version is already installed
    const python_bin = try std.fs.path.join(allocator, &[_][]const u8{install_dir, "bin", "python3"});
    defer allocator.free(python_bin);

    const python_exists = blk: {
        fs.cwd().access(python_bin, .{}) catch |err| {
            if (err == error.FileNotFound) {
                break :blk false;
            }
            // For any other error, we'll assume the file doesn't exist
            try output.print("Warning: Error checking Python executable: {s}", .{@errorName(err)});
            break :blk false;
        };
        break :blk true;
    };

    if (python_exists) {
        try output.print("Python {s} is already installed at {s}", .{python_version, install_dir});
        try output.print("To reinstall, first remove the directory manually: rm -rf {s}", .{install_dir});
        return;
    }

    // Create a temporary build directory
    const build_dir = "/tmp/zenv_python_build";
    fs.cwd().makePath(build_dir) catch |err| {
        output.printError("Failed to create build directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    // Download the Python source
    const tarball_path = try downloadPythonSource(allocator, python_version);
    defer allocator.free(tarball_path);
    defer fs.cwd().deleteFile(tarball_path) catch |err| {
        output.print("Warning: Failed to delete temporary file {s}: {s}\n", .{tarball_path, @errorName(err)}) catch {};
    };

    // Extract the source
    const source_dir = try extractPythonSource(allocator, tarball_path, build_dir);
    defer allocator.free(source_dir);
    defer fs.cwd().deleteTree(source_dir) catch |err| {
        output.print("Warning: Failed to delete temporary directory {s}: {s}", .{source_dir, @errorName(err)}) catch {};
    };

    // Build and install Python
    try buildPython(allocator, source_dir, install_dir);

    // Print success message with actual paths
    output.print("Python {s} has been successfully installed!", .{python_version}) catch {};
    output.print("Installation path: {s}", .{install_dir}) catch {};
    output.print("To set this as the default Python for new environments:", .{}) catch {};
    output.print("zenv python use {s}", .{python_version}) catch {};
}
