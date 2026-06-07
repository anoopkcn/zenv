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
};

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
