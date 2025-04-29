const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ZenvError = error{
    MissingHostname,
    HostnameParseError,
    ConfigFileNotFound,
    ConfigFileReadError,
    JsonParseError,
    ConfigInvalid,
    RegistryError,
    EnvironmentNotRegistered,
    ClusterNotFound,
    EnvironmentNotFound,
    IoError,
    ProcessError,
    ModuleLoadError, // New error type specifically for module loading failures
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
};

/// Logs an error message and returns the provided error.
/// Useful for standardizing error logging and handling across the application.
///
/// Params:
///   - err: The error to return
///   - message: Format string for the error message
///   - args: Arguments for the format string
///
/// Returns: The original error for propagation
pub fn logAndReturn(err: anyerror, comptime message: []const u8, args: anytype) anyerror {
    std.log.err(message, args);
    return err;
}

/// Helper function for consistent error handling when dealing with file operations.
/// Logs the error with the path information and returns an appropriate error.
///
/// Params:
///   - err: The error that occurred
///   - path: The file path that was being accessed
///   - operation: Description of what operation was being performed
///
/// Returns: A mapped error or the original error
pub fn handleFileError(err: anyerror, path: []const u8, operation: []const u8) anyerror {
    std.log.err("File operation error: {s} '{s}': {s}", .{ operation, path, @errorName(err) });
    
    // Map common file errors to our error set
    return switch (err) {
        error.FileNotFound => ZenvError.ConfigFileNotFound,
        error.IsDir => ZenvError.IoError,
        error.AccessDenied => ZenvError.IoError,
        else => err,
    };
}

/// Check if debug mode is enabled by examining the ZENV_DEBUG environment variable.
/// Debug statements should only be printed if ZENV_DEBUG is set to "1", "true", or "yes".
///
/// Params:
///   - allocator: Memory allocator for environment variable handling
///
/// Returns: Whether debug logging should be enabled
pub fn isDebugEnabled(allocator: Allocator) bool {
    const env_var = std.process.getEnvVarOwned(allocator, "ZENV_DEBUG") catch |err| {
        if (err == error.EnvironmentVariableNotFound) return false;
        // If we encounter other errors reading the env var, default to false
        return false;
    };
    defer allocator.free(env_var);
    
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
    if (isDebugEnabled(allocator)) {
        std.log.debug(message, args);
    }
}
