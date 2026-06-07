const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("output.zig");
const runtime = @import("runtime.zig");

pub const ZenvError = error{
    MissingHostname,
    HostnameParseError,
    ConfigFileNotFound,
    ConfigFileReadError,
    JsonParseError,
    ConfigInvalid,
    InvalidFormat,
    RegistryError,
    EnvironmentNotRegistered,
    ClusterNotFound,
    EnvironmentNotFound,
    IoError,
    ProcessError,
    ModuleLoadError,
    MissingPythonExecutable,
    PathResolutionFailed,
    OutOfMemory,
    EnvironmentVariableNotFound, // From getEnvVarOwned
    InvalidWtf8, // From getEnvVarOwned
    ArgsError, // Added for command line argument issues
    TargetMachineMismatch, // Added for hostname validation issues
    AmbiguousIdentifier, // Added for ambiguous ID prefixes
    InvalidRegistryFormat, // Added when registry JSON structure is wrong
    PathTraversalAttempt, // Added to handle path traversal attack attempts
    AliasAlreadyExists, // Added for alias creation conflicts
    AliasNotFound, // Added for alias removal/lookup failures
    EnvironmentAlreadyExists, // Added for rename conflicts
    InvalidEnvironmentName, // Added for invalid environment names
    PathAlreadyExists, // Added for path conflicts
    InvalidPath, // Added for invalid paths
    JupyterNotFound, // Jupyter is not installed / not on PATH
    KernelNotFound, // Jupyter kernel for the environment is missing
    KernelExists, // Jupyter kernel with that name already exists
};

/// Maps any error that reaches the top level to a single user-facing message,
/// then exits the process. This is the one place error presentation lives; `main`
/// only dispatches here. `errors.zig` already owns error output (`debugLog`), so
/// co-locating the messages with `ZenvError` keeps them together.
///
/// Note: this does NOT enforce that every error has a friendly message. The
/// `anyerror` boundary needs the `else` safety net; real compile-time enforcement
/// would require typing error propagation as `ZenvError` throughout the codebase.
pub fn report(allocator: Allocator, err: anyerror) void {
    switch (err) {
        error.ConfigFileNotFound => output.printError(allocator, "Configuration file 'zenv.json' not found", .{}) catch {},
        error.FileNotFound => output.printError(allocator, "zenv could not find a file required to complete this command", .{}) catch {},
        error.ClusterNotFound => output.printError(allocator, "Target machine mismatch or environment not suitable for current machine", .{}) catch {},
        error.EnvironmentNotFound => output.printError(allocator, "Environment name not found in configuration or argument missing", .{}) catch {},
        error.JsonParseError => output.printError(allocator, "Invalid JSON format in 'zenv.json'. Check syntax", .{}) catch {},
        error.InvalidFormat => output.printError(allocator, "Invalid JSON format in 'zenv.json'. Check syntax for details above", .{}) catch {},
        error.ConfigInvalid => output.printError(allocator, "Invalid configuration structure in 'zenv.json'. Check keys/types/required fields", .{}) catch {},
        error.MissingHostname => output.printError(allocator, "HOSTNAME is not set or inaccessible which is required for validation", .{}) catch {},
        error.PathResolutionFailed => output.printError(allocator, "Failed to resolve a required file path (e.g., requirements file)", .{}) catch {},
        error.TargetMachineMismatch => output.printError(allocator, "Current machine does not match the target specified for this environment", .{}) catch {},
        error.AmbiguousIdentifier => output.printError(allocator, "Ambiguous identifier (see the candidates above). Use the exact env name or id", .{}) catch {},
        error.RegistryError => output.printError(allocator, "Failed to access the environment registry. Check permissions for ZENV_DIR", .{}) catch {},
        error.ArgsError => output.printError(allocator, "Invalid command-line arguments provided. Check usage with 'zenv help'", .{}) catch {},
        error.EnvironmentNotRegistered => output.printError(allocator, "The specified environment is not registered. Use 'zenv register <name>'", .{}) catch {},
        error.MissingPythonExecutable => {
            output.printError(allocator, "A required Python executable was not found or is not configured", .{}) catch {};
            output.printError(allocator, "Use 'zenv python install <version>' or configure 'fallback_python' in zenv.json", .{}) catch {};
        },
        error.InvalidRegistryFormat => output.printError(allocator, "The registry file (ZENV_DIR/registry.json) is corrupted or has an invalid format", .{}) catch {},
        error.ConfigFileReadError => output.printError(allocator, "Error reading the configuration file 'zenv.json'. Check permissions and file integrity", .{}) catch {},
        error.HostnameParseError => output.printError(allocator, "Failed to parse the system hostname", .{}) catch {},
        error.IoError => output.printError(allocator, "An I/O error occurred. Check file system permissions and disk space", .{}) catch {},
        error.OutOfMemory => output.printError(allocator, "The application ran out of memory. Try freeing up system resources", .{}) catch {},
        error.PathTraversalAttempt => output.printError(allocator, "A path traversal attempt was detected and blocked for security reasons", .{}) catch {},
        error.EnvironmentVariableNotFound => output.printError(allocator, "A required environment variable was not found. Please ensure it is set", .{}) catch {},
        error.InvalidWtf8 => output.printError(allocator, "An environment variable contained invalid UTF-8 (WTF-8) characters", .{}) catch {},
        error.EnvironmentAlreadyExists => output.printError(allocator, "An environment with that name already exists", .{}) catch {},
        error.InvalidEnvironmentName => output.printError(allocator, "Invalid environment name. Use only alphanumeric characters, hyphens, underscores, and dots", .{}) catch {},
        error.PathAlreadyExists => output.printError(allocator, "The target path already exists", .{}) catch {},
        error.InvalidPath => output.printError(allocator, "Invalid file or directory path", .{}) catch {},
        error.JupyterNotFound => output.printError(allocator, "Jupyter is not installed or not on PATH. Install it (e.g. 'pip install jupyter')", .{}) catch {},
        error.KernelNotFound => output.printError(allocator, "The Jupyter kernel for this environment was not found", .{}) catch {},
        error.KernelExists => output.printError(allocator, "A Jupyter kernel with that name already exists", .{}) catch {},
        // Already reported by the process / module loader; just exit (no message).
        error.ProcessError, error.ModuleLoadError => {},
        else => output.printError(allocator, "An unexpected error occurred: {s}", .{@errorName(err)}) catch {},
    }
    std.process.exit(1);
}

/// Check if debug mode is enabled by examining the ZENV_DEBUG environment variable.
/// Debug statements should only be printed if ZENV_DEBUG is set to "1", "true", or "yes".
///
/// Params:
///   - allocator: Memory allocator for environment variable handling
///
/// Returns: Whether debug logging should be enabled
pub fn isDebugEnabled(allocator: Allocator) bool {
    _ = allocator;
    const env_var = runtime.env("ZENV_DEBUG") orelse return false;

    return std.mem.eql(u8, env_var, "1") or
        std.mem.eql(u8, env_var, "true") or
        std.mem.eql(u8, env_var, "yes");
}

/// Log a debug message, but only if the ZENV_DEBUG environment variable is enabled.
/// This provides a consistent way to handle conditional debug logging across the app.
///
/// Params:
///   - allocator: Memory allocator for environment checking
///   - message: Format string for the debug message
///   - args: Arguments for the format string
pub fn debugLog(allocator: Allocator, comptime message: []const u8, args: anytype) void {
    if (!isDebugEnabled(allocator)) return;
    // Write directly to stderr (gated on ZENV_DEBUG) rather than via std.log,
    // whose debug level is compiled out in release builds. This keeps ZENV_DEBUG
    // functional in the shipped (ReleaseSmall/ReleaseFast) binaries.
    output.rawErr(allocator, "DEBUG: " ++ message ++ "\n", args) catch {};
}
