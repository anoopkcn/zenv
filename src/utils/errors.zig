const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("output.zig");
const runtime = @import("runtime.zig");

/// Maps any error that reaches the top level to a single user-facing message,
/// then exits the process. This is the one place error presentation lives; `main`
/// only dispatches here.
///
/// Note: this does NOT enforce that every error has a friendly message. The
/// `anyerror` boundary needs the `else` safety net.
pub fn report(allocator: Allocator, err: anyerror) noreturn {
    switch (err) {
        error.ConfigFileNotFound => output.printError(allocator, "Configuration file 'zenv.json' not found", .{}) catch {},
        error.FileNotFound => output.printError(allocator, "zenv could not find a file required to complete this command", .{}) catch {},
        error.EnvironmentNotFound => output.printError(allocator, "Environment name not found in configuration or argument missing", .{}) catch {},
        error.InvalidFormat => output.printError(allocator, "Invalid JSON format in 'zenv.json'. Check syntax for details above", .{}) catch {},
        error.ConfigInvalid => output.printError(allocator, "Invalid configuration structure in 'zenv.json'. Check keys/types/required fields", .{}) catch {},
        error.MissingHostname => output.printError(allocator, "HOSTNAME is not set or inaccessible which is required for validation", .{}) catch {},
        error.PathResolutionFailed => output.printError(allocator, "Failed to resolve a required file path (e.g., requirements file)", .{}) catch {},
        error.TargetMachineMismatch => output.printError(allocator, "Current machine does not match the target specified for this environment", .{}) catch {},
        error.RegistryError => output.printError(allocator, "Failed to access the environment registry. Check permissions for ZENV_DIR", .{}) catch {},
        error.ArgsError => output.printError(allocator, "Invalid command-line arguments provided. Check usage with 'zenv help'", .{}) catch {},
        error.MissingPythonExecutable => {
            output.printError(allocator, "A required Python executable was not found or is not configured", .{}) catch {};
            output.printError(allocator, "Use 'zenv python install <version>' or configure 'fallback_python' in zenv.json", .{}) catch {};
        },
        error.InvalidRegistryFormat => output.printError(allocator, "The registry file (ZENV_DIR/registry.json) is corrupted or has an invalid format", .{}) catch {},
        error.IoError => output.printError(allocator, "An I/O error occurred. Check file system permissions and disk space", .{}) catch {},
        error.OutOfMemory => output.printError(allocator, "The application ran out of memory. Try freeing up system resources", .{}) catch {},
        error.InvalidPath => output.printError(allocator, "Invalid file or directory path", .{}) catch {},
        // Already reported where they were raised (the process, auto-setup
        // gate, setup base-dir guard, identifier resolution, or the command
        // that refused); just exit (no message).
        error.ProcessError,
        error.AutoSetupFailed,
        error.BaseDirIsZenvDir,
        error.NoPython,
        error.EnvironmentNotRegistered,
        error.AmbiguousIdentifier,
        error.EnvironmentAlreadyExists,
        error.InvalidEnvironmentName,
        error.AliasAlreadyExists,
        error.AliasNotFound,
        error.PathAlreadyExists,
        error.KernelExists,
        error.KernelNotFound,
        error.MissingEnvSpec,
        => {},
        else => output.printError(allocator, "An unexpected error occurred: {s}", .{@errorName(err)}) catch {},
    }
    std.process.exit(1);
}

/// Logs a debug message to stderr when ZENV_DEBUG is "1", "true" or "yes".
pub fn debugLog(allocator: Allocator, comptime message: []const u8, args: anytype) void {
    const v = runtime.env("ZENV_DEBUG") orelse return;
    if (!std.mem.eql(u8, v, "1") and !std.mem.eql(u8, v, "true") and !std.mem.eql(u8, v, "yes")) return;
    // Write directly to stderr (gated on ZENV_DEBUG) rather than via std.log,
    // whose debug level is compiled out in release builds. This keeps ZENV_DEBUG
    // functional in the shipped (ReleaseSmall/ReleaseFast) binaries.
    output.rawErr(allocator, "DEBUG: " ++ message ++ "\n", args) catch {};
}
