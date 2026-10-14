const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const envspec = @import("envspec.zig");
const paths = @import("paths.zig");
const Ctx = runtime.Ctx;

/// Check if Jupyter is installed and available
pub fn isJupyterAvailable(allocator: Allocator, io: Io) bool {
    const result = runtime.run(allocator, io, &.{ "jupyter", "--version" }, .{
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return result.term.success();
}

/// Get the Jupyter data directory path
pub fn getJupyterDataDir(allocator: Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("JUPYTER_DATA_DIR")) |data_dir| return allocator.dupe(u8, data_dir);

    // jupyter_core's user data dir: ~/Library/Jupyter on macOS, else
    // $XDG_DATA_HOME/jupyter (default ~/.local/share/jupyter).
    const macos = builtin.target.os.tag == .macos;
    if (!macos) if (env.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) return Io.Dir.path.join(allocator, &.{ xdg, "jupyter" });
    };
    const home = env.get("HOME") orelse return error.InvalidPath;
    return Io.Dir.path.join(allocator, &.{ home, if (macos) "Library/Jupyter" else ".local/share/jupyter" });
}

/// `<jupyter data dir>/kernels`, or the directory of kernel `name` in it.
fn kernelsDir(ctx: Ctx, name: ?[]const u8) ![]const u8 {
    const data_dir = try getJupyterDataDir(ctx.arena, ctx.env);
    return Io.Dir.path.join(ctx.arena, if (name) |n| &.{ data_dir, "kernels", n } else &.{ data_dir, "kernels" });
}

/// The directory of `env_name`'s default kernel, `zenv-<env_name>`.
fn envKernelDir(ctx: Ctx, env_name: []const u8) ![]const u8 {
    return kernelsDir(ctx, try ctx.arena.print("zenv-{s}", .{env_name}));
}

/// The zenv command a kernel launches through: the `zenv` on PATH when there is
/// one (a stable symlink such as Homebrew's survives upgrades), else this
/// binary.
fn zenvLauncher(ctx: Ctx) ![]const u8 {
    if (try envspec.resolveCommand(ctx.arena, ctx.io, "zenv", ctx.getEnv("PATH"))) |p| return p;
    return std.process.executablePathAlloc(ctx.io, ctx.arena);
}

/// kernel.json for `env_name`. The kernel starts through `zenv run`, which
/// applies the env's module environment and activation first: a venv built
/// from a module's Python cannot even start without the module's
/// LD_LIBRARY_PATH, and a Jupyter server usually runs with other modules.
pub fn generateKernelJson(allocator: Allocator, display_name: []const u8, env_name: []const u8, zenv_exe: []const u8) ![]u8 {
    const kernel = .{
        .display_name = display_name,
        .language = "python",
        .argv = [_][]const u8{ zenv_exe, "run", env_name, "python", "-m", "ipykernel_launcher", "-f", "{connection_file}" },
    };
    return allocator.print("{f}\n", .{std.json.fmt(kernel, .{ .whitespace = .indent_2 })});
}

/// Create a Jupyter kernel for an environment. `env_name` and `venv_path`
/// come from a registry entry the CALLER resolved (the host-aware resolver in
/// config.zig) — this module never touches the registry, so it cannot pick a
/// different environment than every other command would.
pub fn createKernel(ctx: Ctx, env_name: []const u8, venv_path: []const u8, custom_name: ?[]const u8, custom_display_name: ?[]const u8) !void {
    const io = ctx.io;
    const a = ctx.arena;
    const cwd = Io.Dir.cwd();
    const kernel_name = custom_name orelse try a.print("zenv-{s}", .{env_name});
    // The name becomes a directory under kernels/, so it must not be a path.
    if (!paths.isValidEnvName(kernel_name)) {
        output.printError(io, "Invalid kernel name '{s}'. Use only letters, digits, '-', '_' and '.'.", .{kernel_name});
        return error.InvalidEnvironmentName;
    }

    const display_name = custom_display_name orelse try a.print("Python ({s})", .{env_name});

    const python_path = try Io.Dir.path.join(a, &.{ venv_path, "bin", "python" });
    cwd.access(io, python_path, .{}) catch |err| {
        output.printError(io, "Python executable not found at {s}: {t}", .{ python_path, err });
        return error.NoPython;
    };

    // Creating the kernel directory itself is the existence check, so two
    // concurrent creates cannot both succeed. A failure below must not leave
    // an empty kernel directory that blocks the next attempt.
    const kernel_dir = try kernelsDir(ctx, kernel_name);
    cwd.createDirPath(io, try kernelsDir(ctx, null)) catch |err| {
        output.printError(io, "Failed to create kernels directory: {t}", .{err});
        return err;
    };
    cwd.createDir(io, kernel_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            output.printError(io, "Kernel '{s}' already exists", .{kernel_name});
            return error.KernelExists;
        },
        else => {
            output.printError(io, "Failed to create kernel directory: {t}", .{err});
            return err;
        },
    };
    errdefer cwd.deleteTree(io, kernel_dir) catch {};

    const kernel_json = try generateKernelJson(a, display_name, env_name, try zenvLauncher(ctx));
    cwd.writeFile(io, .{ .sub_path = try Io.Dir.path.join(a, &.{ kernel_dir, "kernel.json" }), .data = kernel_json }) catch |err| {
        output.printError(io, "Failed to write kernel.json: {t}", .{err});
        return err;
    };

    output.print(io, "Created Jupyter kernel '{s}' for environment '{s}'", .{ kernel_name, env_name });
    output.print(io, "Kernel location: {s}", .{kernel_dir});
    output.print(io, "The environment needs ipykernel (zenv add {s} ipykernel) for the kernel to start.", .{env_name});
}

/// Remove a Jupyter kernel for the given environment
pub fn removeKernel(ctx: Ctx, env_name: []const u8) !void {
    const io = ctx.io;
    const kernel_dir = try envKernelDir(ctx, env_name);
    Io.Dir.cwd().access(io, kernel_dir, .{}) catch |err| {
        if (err == error.FileNotFound) {
            output.printError(io, "Kernel 'zenv-{s}' not found", .{env_name});
            return error.KernelNotFound;
        }
        output.printError(io, "Failed to access kernel directory: {t}", .{err});
        return err;
    };
    Io.Dir.cwd().deleteTree(io, kernel_dir) catch |err| {
        output.printError(io, "Failed to remove kernel directory: {t}", .{err});
        return err;
    };
    output.print(io, "Removed Jupyter kernel 'zenv-{s}' for environment '{s}'", .{ env_name, env_name });
}

/// List all zenv-managed Jupyter kernels
pub fn listKernels(ctx: Ctx) !void {
    const io = ctx.io;
    var dir = Io.Dir.cwd().openDir(io, try kernelsDir(ctx, null), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return output.print(io, "No Jupyter kernels directory found", .{}),
        else => {
            output.printError(io, "Failed to access kernels directory: {t}", .{err});
            return err;
        },
    };
    defer dir.close(io);

    var found_kernels = false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // Only zenv-managed kernels: zenv-<env>.
        const env_name = std.mem.cutPrefix(u8, entry.name, "zenv-") orelse continue;
        if (try runtime.kindOf(io, dir, entry, .{}) != .directory) continue;
        if (!found_kernels) output.print(io, "Zenv-managed Jupyter kernels:", .{});
        found_kernels = true;
        output.print(io, "  - {s} (environment: {s})", .{ entry.name, env_name });
    }
    if (!found_kernels) output.print(io, "No zenv-managed Jupyter kernels found", .{});
}

/// Check Jupyter installation and show status
pub fn checkJupyter(ctx: Ctx) !void {
    const io = ctx.io;
    if (!isJupyterAvailable(ctx.arena, io)) {
        output.printError(io, "Jupyter is not installed or not available in PATH", .{});
        output.print(io, "Install Jupyter with: pip install jupyter", .{});
        return;
    }
    output.print(io, "Jupyter is installed and available", .{});
    output.print(io, "Jupyter data directory: {s}", .{try getJupyterDataDir(ctx.arena, ctx.env)});

    const kernels_dir = try kernelsDir(ctx, null);
    if (Io.Dir.cwd().access(io, kernels_dir, .{})) |_| {
        output.print(io, "Kernels directory: {s}", .{kernels_dir});
    } else |err| switch (err) {
        error.FileNotFound => output.print(io, "Kernels directory does not exist (will be created when needed)", .{}),
        else => output.printError(io, "Cannot access kernels directory: {t}", .{err}),
    }
}

/// Rename a Jupyter kernel from old environment name to new environment name
pub fn renameKernel(ctx: Ctx, old_env_name: []const u8, new_env_name: []const u8) !void {
    const io = ctx.io;
    const cwd = Io.Dir.cwd();
    const old_kernel_dir = try envKernelDir(ctx, old_env_name);
    const new_kernel_dir = try envKernelDir(ctx, new_env_name);

    // No old kernel: nothing to rename. The new name must be free. (Not
    // `renamePreserve`: on Linux that needs RENAME_NOREPLACE, which some
    // network filesystems reject.)
    cwd.access(io, old_kernel_dir, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    if (cwd.access(io, new_kernel_dir, .{})) |_| {
        return error.KernelExists;
    } else |err| if (err != error.FileNotFound) return err;

    cwd.rename(old_kernel_dir, cwd, new_kernel_dir, io) catch |err| {
        output.printError(io, "Failed to rename kernel directory: {t}", .{err});
        return err;
    };
    // A kernel.json still naming the old env must not stay under the new name.
    errdefer cwd.rename(new_kernel_dir, cwd, old_kernel_dir, io) catch {};

    // Regenerate kernel.json with the new display name and env. zenv-managed
    // kernels have a fixed shape, so regenerating is equivalent to editing it.
    const display_name = try ctx.arena.print("Python ({s})", .{new_env_name});
    const kernel_json = try generateKernelJson(ctx.arena, display_name, new_env_name, try zenvLauncher(ctx));
    try cwd.writeFile(io, .{ .sub_path = try Io.Dir.path.join(ctx.arena, &.{ new_kernel_dir, "kernel.json" }), .data = kernel_json });

    output.print(io, "Renamed Jupyter kernel from 'zenv-{s}' to 'zenv-{s}'", .{ old_env_name, new_env_name });
}

/// Check if an environment has an associated Jupyter kernel
pub fn hasKernel(ctx: Ctx, env_name: []const u8) bool {
    const kernel_dir = envKernelDir(ctx, env_name) catch return false;
    return runtime.exists(ctx.io, kernel_dir);
}

// ============================ Tests ============================
const testing = std.testing;
const test_support = @import("../test_support.zig");

test "generateKernelJson launches through zenv run and escapes text" {
    const a = testing.allocator;
    const text = try generateKernelJson(a, "Python (\"x\")", "hpc", "/usr/local/bin/zenv");
    defer a.free(text);
    try testing.expectStringStartsWith(text, "{\n  \"display_name\": \"Python (\\\"x\\\")\",\n  \"language\": \"python\",\n  \"argv\": [\n    \"/usr/local/bin/zenv\",");
    try testing.expectStringEndsWith(text, "\"{connection_file}\"\n  ]\n}\n");
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
    const a = testing.allocator;
    const prev = test_support.useFakeExec();
    defer runtime.exec_backend = prev;

    test_support.fake_run_stdout = "jupyter 7.0.0";
    test_support.fake_run_exit = 0;
    try testing.expect(isJupyterAvailable(a, testing.io));

    test_support.fake_run_exit = 1; // `jupyter` present but errored
    try testing.expect(!isJupyterAvailable(a, testing.io));
}

test "renameKernel and removeKernel act on zenv-<env> kernels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const data_dir = ".zig-cache/tmp/zenv_jupyter_test";
    cwd.deleteTree(io, data_dir) catch {};
    defer cwd.deleteTree(io, data_dir) catch {};

    var env_map = std.process.Environ.Map.init(a);
    try env_map.put("JUPYTER_DATA_DIR", data_dir);
    try env_map.put("PATH", "/nonexistent");
    const ctx = test_support.ctx(a, &env_map);

    const old_dir = data_dir ++ "/kernels/zenv-old";
    try cwd.createDirPath(io, old_dir);
    try testing.expect(hasKernel(ctx, "old"));
    try testing.expect(!hasKernel(ctx, "new"));

    try renameKernel(ctx, "old", "new");
    try testing.expect(!hasKernel(ctx, "old"));
    const text = try cwd.readFileAlloc(io, data_dir ++ "/kernels/zenv-new/kernel.json", a, .limited(64 * 1024));
    try testing.expect(std.mem.find(u8, text, "\"new\"") != null);

    try renameKernel(ctx, "missing", "new"); // no old kernel: nothing to do
    try cwd.createDirPath(io, old_dir);
    try testing.expectError(error.KernelExists, renameKernel(ctx, "old", "new"));

    try removeKernel(ctx, "new");
    try testing.expect(!hasKernel(ctx, "new"));
    try testing.expectError(error.KernelNotFound, removeKernel(ctx, "new"));
}
