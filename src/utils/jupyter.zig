const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const envspec = @import("envspec.zig");

/// Check if Jupyter is installed and available
pub fn isJupyterAvailable(allocator: Allocator) bool {
    const result = runtime.run(allocator, &[_][]const u8{ "jupyter", "--version" }, .{
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;

    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    return result.term == .exited and result.term.exited == 0;
}

/// Get the Jupyter data directory path
pub fn getJupyterDataDir(allocator: Allocator) ![]const u8 {
    // First try to get from environment variable
    if (runtime.env("JUPYTER_DATA_DIR")) |data_dir| {
        return allocator.dupe(u8, data_dir);
    }

    // jupyter_core's user data dir: ~/Library/Jupyter on macOS, else
    // $XDG_DATA_HOME/jupyter (default ~/.local/share/jupyter).
    if (builtin.os.tag != .macos) {
        if (runtime.env("XDG_DATA_HOME")) |xdg| {
            if (xdg.len > 0) return allocator.print("{s}/jupyter", .{xdg});
        }
    }
    const home = runtime.env("HOME") orelse return error.InvalidPath;
    if (builtin.os.tag == .macos) return allocator.print("{s}/Library/Jupyter", .{home});
    return allocator.print("{s}/.local/share/jupyter", .{home});
}

/// Get the kernel directory path for a given kernel name
pub fn getKernelDir(allocator: Allocator, kernel_name: []const u8) ![]const u8 {
    const jupyter_data_dir = try getJupyterDataDir(allocator);
    defer allocator.free(jupyter_data_dir);

    return try allocator.print("{s}/kernels/{s}", .{ jupyter_data_dir, kernel_name });
}

/// The zenv command a kernel launches through: the `zenv` on PATH when there is
/// one (a stable symlink such as Homebrew's survives upgrades), else this
/// binary. Caller owns the result.
fn zenvLauncher(allocator: Allocator) ![]const u8 {
    if (try envspec.resolveCommand(allocator, "zenv", runtime.env("PATH"))) |p| return p;
    const self = try runtime.selfExePath(allocator);
    defer allocator.free(self);
    return allocator.dupe(u8, self);
}

/// kernel.json for `env_name`. The kernel starts through `zenv run`, which
/// applies the env's module environment and activation first: a venv built
/// from a module's Python cannot even start without the module's
/// LD_LIBRARY_PATH, and a Jupyter server usually runs with other modules.
pub fn generateKernelJson(allocator: Allocator, display_name: []const u8, env_name: []const u8, zenv_exe: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try s.write(.{
        .display_name = display_name,
        .language = "python",
        .argv = [_][]const u8{ zenv_exe, "run", env_name, "python", "-m", "ipykernel_launcher", "-f", "{connection_file}" },
    });
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Create a Jupyter kernel for an environment. `env_name` and `venv_path`
/// come from a registry entry the CALLER resolved (the host-aware resolver in
/// config.zig) — this module never touches the registry, so it cannot pick a
/// different environment than every other command would.
pub fn createKernel(allocator: Allocator, env_name: []const u8, venv_path: []const u8, custom_name: ?[]const u8, custom_display_name: ?[]const u8) !void {
    // Determine kernel name and display name
    const kernel_name = custom_name orelse try allocator.print("zenv-{s}", .{env_name});
    defer if (custom_name == null) allocator.free(kernel_name);

    const display_name = custom_display_name orelse try allocator.print("Python ({s})", .{env_name});
    defer if (custom_display_name == null) allocator.free(display_name);

    // Get Python path from environment
    const python_path = try allocator.print("{s}/bin/python", .{venv_path});
    defer allocator.free(python_path);

    // Check if Python executable exists
    runtime.access(python_path) catch |err| {
        try output.printError(allocator, "Python executable not found at {s}: {s}", .{ python_path, @errorName(err) });
        return;
    };

    // Create kernel directory
    const kernel_dir = try getKernelDir(allocator, kernel_name);
    defer allocator.free(kernel_dir);

    // Check if kernel already exists
    if (runtime.access(kernel_dir)) |_| {
        // File exists, that's an error
        try output.printError(allocator, "Kernel '{s}' already exists", .{kernel_name});
        return error.KernelExists;
    } else |err| switch (err) {
        error.FileNotFound => {
            // Good, kernel doesn't exist, continue
        },
        else => {
            try output.printError(allocator, "Failed to access kernel directory: {s}", .{@errorName(err)});
            return;
        },
    }

    // Ensure jupyter data directory exists
    const jupyter_data_dir = try getJupyterDataDir(allocator);
    defer allocator.free(jupyter_data_dir);

    runtime.makePath(jupyter_data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Directory already exists, that's fine
        else => {
            try output.printError(allocator, "Failed to create jupyter data directory: {s}", .{@errorName(err)});
            return;
        },
    };

    // Ensure kernels directory exists
    const kernels_dir = try allocator.print("{s}/kernels", .{jupyter_data_dir});
    defer allocator.free(kernels_dir);

    runtime.makePath(kernels_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {}, // Directory already exists, that's fine
        else => {
            try output.printError(allocator, "Failed to create kernels directory: {s}", .{@errorName(err)});
            return;
        },
    };

    // Create kernel directory
    runtime.makePath(kernel_dir) catch |err| {
        try output.printError(allocator, "Failed to create kernel directory: {s}", .{@errorName(err)});
        return;
    };

    const zenv_exe = try zenvLauncher(allocator);
    defer allocator.free(zenv_exe);
    const kernel_json = try generateKernelJson(allocator, display_name, env_name, zenv_exe);
    defer allocator.free(kernel_json);

    // Write kernel.json file
    const kernel_json_path = try allocator.print("{s}/kernel.json", .{kernel_dir});
    defer allocator.free(kernel_json_path);

    runtime.writeFile(kernel_json_path, kernel_json) catch |err| {
        try output.printError(allocator, "Failed to write kernel.json: {s}", .{@errorName(err)});
        return;
    };

    try output.print(allocator, "Created Jupyter kernel '{s}' for environment '{s}'", .{ kernel_name, env_name });
    try output.print(allocator, "Kernel location: {s}", .{kernel_dir});
    try output.print(allocator, "The environment needs ipykernel (zenv add {s} ipykernel) for the kernel to start.", .{env_name});
}

/// Remove a Jupyter kernel for the given environment
pub fn removeKernel(allocator: Allocator, env_name: []const u8) !void {
    const kernel_name = try allocator.print("zenv-{s}", .{env_name});
    defer allocator.free(kernel_name);

    const kernel_dir = try getKernelDir(allocator, kernel_name);
    defer allocator.free(kernel_dir);

    // Check if kernel exists
    runtime.access(kernel_dir) catch |err| switch (err) {
        error.FileNotFound => {
            try output.printError(allocator, "Kernel '{s}' not found", .{kernel_name});
            return error.KernelNotFound;
        },
        else => {
            try output.printError(allocator, "Failed to access kernel directory: {s}", .{@errorName(err)});
            return;
        },
    };

    // Remove kernel directory recursively
    runtime.deleteTree(kernel_dir) catch |err| {
        try output.printError(allocator, "Failed to remove kernel directory: {s}", .{@errorName(err)});
        return;
    };

    try output.print(allocator, "Removed Jupyter kernel '{s}' for environment '{s}'", .{ kernel_name, env_name });
}

/// List all zenv-managed Jupyter kernels
pub fn listKernels(allocator: Allocator) !void {
    const jupyter_data_dir = try getJupyterDataDir(allocator);
    defer allocator.free(jupyter_data_dir);

    const kernels_dir = try allocator.print("{s}/kernels", .{jupyter_data_dir});
    defer allocator.free(kernels_dir);

    var dir = runtime.openDir(kernels_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try output.print(allocator, "No Jupyter kernels directory found", .{});
            return;
        },
        else => {
            try output.printError(allocator, "Failed to access kernels directory: {s}", .{@errorName(err)});
            return;
        },
    };
    defer dir.close(runtime.io);

    var iterator = dir.iterate();
    var found_kernels = false;

    while (try iterator.next(runtime.io)) |entry| {
        if (entry.kind != .directory) continue;

        // Only show zenv-managed kernels
        if (std.mem.startsWith(u8, entry.name, "zenv-")) {
            if (!found_kernels) {
                try output.print(allocator, "Zenv-managed Jupyter kernels:", .{});
                found_kernels = true;
            }

            const env_name = entry.name[5..]; // Remove "zenv-" prefix
            try output.print(allocator, "  - {s} (environment: {s})", .{ entry.name, env_name });
        }
    }

    if (!found_kernels) {
        try output.print(allocator, "No zenv-managed Jupyter kernels found", .{});
    }
}

/// Check Jupyter installation and show status
pub fn checkJupyter(allocator: Allocator) !void {
    if (isJupyterAvailable(allocator)) {
        try output.print(allocator, "Jupyter is installed and available", .{});

        const jupyter_data_dir = try getJupyterDataDir(allocator);
        defer allocator.free(jupyter_data_dir);

        try output.print(allocator, "Jupyter data directory: {s}", .{jupyter_data_dir});

        const kernels_dir = try allocator.print("{s}/kernels", .{jupyter_data_dir});
        defer allocator.free(kernels_dir);

        if (runtime.access(kernels_dir)) |_| {
            try output.print(allocator, "Kernels directory: {s}", .{kernels_dir});
        } else |err| switch (err) {
            error.FileNotFound => {
                try output.print(allocator, "Kernels directory does not exist (will be created when needed)", .{});
            },
            else => {
                try output.printError(allocator, "Cannot access kernels directory: {s}", .{@errorName(err)});
            },
        }
    } else {
        try output.printError(allocator, "Jupyter is not installed or not available in PATH", .{});
        try output.print(allocator, "Install Jupyter with: pip install jupyter", .{});
    }
}

/// Rename a Jupyter kernel from old environment name to new environment name
pub fn renameKernel(allocator: Allocator, old_env_name: []const u8, new_env_name: []const u8, new_venv_path: []const u8) !void {
    const old_kernel_name = try allocator.print("zenv-{s}", .{old_env_name});
    defer allocator.free(old_kernel_name);

    const new_kernel_name = try allocator.print("zenv-{s}", .{new_env_name});
    defer allocator.free(new_kernel_name);

    const old_kernel_dir = try getKernelDir(allocator, old_kernel_name);
    defer allocator.free(old_kernel_dir);

    const new_kernel_dir = try getKernelDir(allocator, new_kernel_name);
    defer allocator.free(new_kernel_dir);

    // Check if old kernel exists
    runtime.access(old_kernel_dir) catch |err| switch (err) {
        error.FileNotFound => {
            // Old kernel doesn't exist, nothing to rename
            return;
        },
        else => {
            return err;
        },
    };

    // Check if new kernel already exists
    if (runtime.access(new_kernel_dir)) |_| {
        return error.KernelExists;
    } else |err| switch (err) {
        error.FileNotFound => {
            // Good, new kernel doesn't exist
        },
        else => {
            return err;
        },
    }

    // Rename the kernel directory
    runtime.rename(old_kernel_dir, new_kernel_dir) catch |err| {
        try output.printError(allocator, "Failed to rename kernel directory: {s}", .{@errorName(err)});
        return err;
    };

    // Update the kernel.json file with new display name and Python path
    const kernel_json_path = try allocator.print("{s}/kernel.json", .{new_kernel_dir});
    defer allocator.free(kernel_json_path);

    // Regenerate kernel.json with the updated display name and Python path.
    // zenv-managed kernels have a fixed shape, so regenerating is equivalent to
    // editing display_name + argv[0] in place.
    const new_display_name = try allocator.print("Python ({s})", .{new_env_name});
    defer allocator.free(new_display_name);

    _ = new_venv_path;
    const zenv_exe = try zenvLauncher(allocator);
    defer allocator.free(zenv_exe);
    const kernel_json = try generateKernelJson(allocator, new_display_name, new_env_name, zenv_exe);
    defer allocator.free(kernel_json);

    try runtime.writeFile(kernel_json_path, kernel_json);

    try output.print(allocator, "Renamed Jupyter kernel from '{s}' to '{s}'", .{ old_kernel_name, new_kernel_name });
}

/// Check if an environment has an associated Jupyter kernel
pub fn hasKernel(allocator: Allocator, env_name: []const u8) bool {
    const kernel_name = allocator.print("zenv-{s}", .{env_name}) catch return false;
    defer allocator.free(kernel_name);

    const kernel_dir = getKernelDir(allocator, kernel_name) catch return false;
    defer allocator.free(kernel_dir);

    runtime.access(kernel_dir) catch return false;
    return true;
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");

test "generateKernelJson launches through zenv run and escapes text" {
    const a = testing.allocator;
    const text = try generateKernelJson(a, "Python (\"x\")", "hpc", "/usr/local/bin/zenv");
    defer a.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("Python (\"x\")", obj.get("display_name").?.string);
    const argv = obj.get("argv").?.array.items;
    try testing.expectEqualStrings("/usr/local/bin/zenv", argv[0].string);
    try testing.expectEqualStrings("run", argv[1].string);
    try testing.expectEqualStrings("hpc", argv[2].string);
    try testing.expectEqualStrings("{connection_file}", argv[argv.len - 1].string);
}

test "isJupyterAvailable maps exit status to a bool" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const prev = test_support.useFakeExec();
    defer runtime.exec_backend = prev;

    test_support.fake_run_stdout = "jupyter 7.0.0";
    test_support.fake_run_exit = 0;
    try testing.expect(isJupyterAvailable(a));

    test_support.fake_run_exit = 1; // `jupyter` present but errored
    try testing.expect(!isJupyterAvailable(a));
}
