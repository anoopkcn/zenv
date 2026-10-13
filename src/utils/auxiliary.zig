const std = @import("std");
const Allocator = std.mem.Allocator;
const runtime = @import("runtime.zig");

const config_module = @import("config.zig");
const EnvironmentConfig = config_module.EnvironmentConfig;
const errors = @import("errors.zig");
const parse_deps = @import("parse_deps.zig");
const envbuild = @import("envbuild.zig");
const output = @import("output.zig");
const CommandFlags = @import("flags.zig").CommandFlags;

/// Sets up the full environment in `venv_dir` (absolute, already created):
/// validates and records the dependency list, then builds the env (see
/// envbuild.zig). `project_dir` is the directory holding zenv.json, the anchor
/// for its relative paths. `deps` are borrowed.
pub fn setupEnvironment(
    allocator: Allocator,
    env_config: *const EnvironmentConfig,
    env_name: []const u8,
    venv_dir: []const u8,
    project_dir: []const u8,
    deps: []const []const u8,
    flags: CommandFlags,
) !void {
    output.print(allocator, "Setting up environment '{s}' in '{s}'...", .{ env_name, venv_dir }) catch {};

    // The returned list borrows its items from `deps`.
    var valid_deps_list = try parse_deps.validateDependencies(allocator, deps, env_name);
    defer valid_deps_list.deinit(allocator);

    // A Python-free env installs nothing, so it gets no requirements.txt.
    if (env_config.python) try writeRequirements(allocator, venv_dir, valid_deps_list.items);

    try envbuild.run(allocator, .{
        .env_config = env_config,
        .env_name = env_name,
        .venv_dir = venv_dir,
        .project_dir = project_dir,
        .deps = valid_deps_list.items,
        .flags = flags,
    });

    output.print(allocator, "Environment '{s}' setup completed successfully.", .{env_name}) catch {};
}

/// Writes the validated dependencies to `<venv_dir>/requirements.txt`, the
/// record of what setup installed.
fn writeRequirements(allocator: Allocator, venv_dir: []const u8, deps: []const []const u8) !void {
    const req_abs_path = try std.Io.Dir.path.join(allocator, &[_][]const u8{ venv_dir, "requirements.txt" });
    defer allocator.free(req_abs_path);

    output.print(allocator, "Writing {d} validated dependencies to {s}", .{ deps.len, req_abs_path }) catch {};

    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    if (deps.len == 0) {
        output.print(allocator, "Warning: No valid dependencies found! Writing only a comment to requirements file.", .{}) catch {};
        try content.writer.writeAll("# No valid dependencies found\n");
    } else {
        for (deps) |dep| {
            try content.writer.print("{s}\n", .{dep});
            errors.debugLog(allocator, "Wrote dependency to file: {s}", .{dep});
        }
    }
    try runtime.writeFile(req_abs_path, content.written());

    output.print(allocator, "Created requirements file: {s}", .{req_abs_path}) catch {};
}
