const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const envspec = @import("envspec.zig");
const paths = @import("paths.zig");

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

    return runtime.exitedOk(result.term);
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

/// The directory of `env_name`'s default kernel, `zenv-<env_name>`.
fn envKernelDir(allocator: Allocator, env_name: []const u8) ![]const u8 {
    const jupyter_data_dir = try getJupyterDataDir(allocator);
    defer allocator.free(jupyter_data_dir);
    return allocator.print("{s}/kernels/zenv-{s}", .{ jupyter_data_dir, env_name });
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
    const kernel_name = custom_name orelse try allocator.print("zenv-{s}", .{env_name});
    defer if (custom_name == null) allocator.free(kernel_name);
    // The name becomes a directory under kernels/, so it must not be a path.
    if (!paths.isValidEnvName(kernel_name)) {
        output.printError(allocator, "Invalid kernel name '{s}'. Use only letters, digits, '-', '_' and '.'.", .{kernel_name}) catch {};
        return error.InvalidEnvironmentName;
    }

    const display_name = custom_display_name orelse try allocator.print("Python ({s})", .{env_name});
    defer if (custom_display_name == null) allocator.free(display_name);

    const python_path = try allocator.print("{s}/bin/python", .{venv_path});
    defer allocator.free(python_path);
    runtime.access(python_path) catch |err| {
        output.printError(allocator, "Python executable not found at {s}: {s}", .{ python_path, @errorName(err) }) catch {};
        return error.NoPython;
    };

    const kernel_dir = try getKernelDir(allocator, kernel_name);
    defer allocator.free(kernel_dir);
    if (runtime.access(kernel_dir)) |_| {
        output.printError(allocator, "Kernel '{s}' already exists", .{kernel_name}) catch {};
        return error.KernelExists;
    } else |err| if (err != error.FileNotFound) {
        output.printError(allocator, "Failed to access kernel directory: {s}", .{@errorName(err)}) catch {};
        return err;
    }

    // Creates the Jupyter data and kernels directories too. A failure below
    // must not leave an empty kernel directory that blocks the next attempt.
    runtime.makePath(kernel_dir) catch |err| {
        output.printError(allocator, "Failed to create kernel directory: {s}", .{@errorName(err)}) catch {};
        return err;
    };
    errdefer runtime.deleteTree(kernel_dir) catch {};

    const zenv_exe = try zenvLauncher(allocator);
    defer allocator.free(zenv_exe);
    const kernel_json = try generateKernelJson(allocator, display_name, env_name, zenv_exe);
    defer allocator.free(kernel_json);

    const kernel_json_path = try allocator.print("{s}/kernel.json", .{kernel_dir});
    defer allocator.free(kernel_json_path);
    runtime.writeFile(kernel_json_path, kernel_json) catch |err| {
        output.printError(allocator, "Failed to write kernel.json: {s}", .{@errorName(err)}) catch {};
        return err;
    };

    try output.print(allocator, "Created Jupyter kernel '{s}' for environment '{s}'", .{ kernel_name, env_name });
    try output.print(allocator, "Kernel location: {s}", .{kernel_dir});
    try output.print(allocator, "The environment needs ipykernel (zenv add {s} ipykernel) for the kernel to start.", .{env_name});
}

/// Remove a Jupyter kernel for the given environment
pub fn removeKernel(allocator: Allocator, env_name: []const u8) !void {
    const kernel_dir = try envKernelDir(allocator, env_name);
    defer allocator.free(kernel_dir);

    runtime.access(kernel_dir) catch |err| {
        if (err == error.FileNotFound) {
            try output.printError(allocator, "Kernel 'zenv-{s}' not found", .{env_name});
            return error.KernelNotFound;
        }
        try output.printError(allocator, "Failed to access kernel directory: {s}", .{@errorName(err)});
        return err;
    };

    // Remove kernel directory recursively
    runtime.deleteTree(kernel_dir) catch |err| {
        try output.printError(allocator, "Failed to remove kernel directory: {s}", .{@errorName(err)});
        return err;
    };

    try output.print(allocator, "Removed Jupyter kernel 'zenv-{s}' for environment '{s}'", .{ env_name, env_name });
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
pub fn renameKernel(allocator: Allocator, old_env_name: []const u8, new_env_name: []const u8) !void {
    const old_kernel_dir = try envKernelDir(allocator, old_env_name);
    defer allocator.free(old_kernel_dir);

    const new_kernel_dir = try envKernelDir(allocator, new_env_name);
    defer allocator.free(new_kernel_dir);

    // No old kernel: nothing to rename. The new name must be free.
    runtime.access(old_kernel_dir) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    if (runtime.access(new_kernel_dir)) |_| {
        return error.KernelExists;
    } else |err| if (err != error.FileNotFound) return err;

    // Rename the kernel directory
    runtime.rename(old_kernel_dir, new_kernel_dir) catch |err| {
        try output.printError(allocator, "Failed to rename kernel directory: {s}", .{@errorName(err)});
        return err;
    };
    // A kernel.json still naming the old env must not stay under the new name.
    errdefer runtime.rename(new_kernel_dir, old_kernel_dir) catch {};

    const kernel_json_path = try allocator.print("{s}/kernel.json", .{new_kernel_dir});
    defer allocator.free(kernel_json_path);

    // Regenerate kernel.json with the new display name and env. zenv-managed
    // kernels have a fixed shape, so regenerating is equivalent to editing it.
    const new_display_name = try allocator.print("Python ({s})", .{new_env_name});
    defer allocator.free(new_display_name);

    const zenv_exe = try zenvLauncher(allocator);
    defer allocator.free(zenv_exe);
    const kernel_json = try generateKernelJson(allocator, new_display_name, new_env_name, zenv_exe);
    defer allocator.free(kernel_json);

    try runtime.writeFile(kernel_json_path, kernel_json);

    try output.print(allocator, "Renamed Jupyter kernel from 'zenv-{s}' to 'zenv-{s}'", .{ old_env_name, new_env_name });
}

/// Check if an environment has an associated Jupyter kernel
pub fn hasKernel(allocator: Allocator, env_name: []const u8) bool {
    const kernel_dir = envKernelDir(allocator, env_name) catch return false;
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

test "renameKernel and removeKernel act on zenv-<env> kernels" {
    test_support.setupRuntime();
    const a = testing.allocator;
    const data_dir = try std.Io.Dir.path.join(a, &[_][]const u8{ runtime.tempDir(), "zenv_jupyter_test" });
    defer a.free(data_dir);
    runtime.deleteTree(data_dir) catch {};
    defer runtime.deleteTree(data_dir) catch {};

    var env_map = std.process.Environ.Map.init(a);
    defer env_map.deinit();
    try env_map.put("JUPYTER_DATA_DIR", data_dir);
    const prev_env = runtime.environ_map;
    runtime.environ_map = &env_map;
    defer runtime.environ_map = prev_env;

    const old_dir = try std.Io.Dir.path.join(a, &[_][]const u8{ data_dir, "kernels", "zenv-old" });
    defer a.free(old_dir);
    try runtime.makePath(old_dir);
    try testing.expect(hasKernel(a, "old"));
    try testing.expect(!hasKernel(a, "new"));

    try renameKernel(a, "old", "new");
    try testing.expect(!hasKernel(a, "old"));
    const json_path = try std.Io.Dir.path.join(a, &[_][]const u8{ data_dir, "kernels", "zenv-new", "kernel.json" });
    defer a.free(json_path);
    const text = try runtime.readFileAlloc(a, json_path, 64 * 1024);
    defer a.free(text);
    try testing.expect(std.mem.find(u8, text, "\"new\"") != null);

    try renameKernel(a, "missing", "new"); // no old kernel: nothing to do
    try runtime.makePath(old_dir);
    try testing.expectError(error.KernelExists, renameKernel(a, "old", "new"));

    try removeKernel(a, "new");
    try testing.expect(!hasKernel(a, "new"));
    try testing.expectError(error.KernelNotFound, removeKernel(a, "new"));
}
