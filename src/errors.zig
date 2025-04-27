const std = @import("std");

pub const ZenvError = error{
    MissingHostname,
    HostnameParseError,
    ConfigFileNotFound,
    ConfigFileReadError,
    JsonParseError,
    ConfigInvalid,
    ClusterNotFound,
    EnvironmentNotFound,
    IoError,
    ProcessError,
    MissingPythonExecutable,
    PathResolutionFailed,
    OutOfMemory,
    EnvironmentVariableNotFound, // From getEnvVarOwned
    InvalidWtf8, // From getEnvVarOwned
    ArgsError, // Added for command line argument issues
    TargetMachineMismatch, // Added for hostname validation issues
};

// Add a tagged union for error context
pub const ErrorContext = union(enum) {
    config_file: struct {
        path: []const u8,
        line: ?usize = null,
    },
    environment: struct {
        name: []const u8,
    },
    hostname: struct {
        expected: []const u8,
        actual: []const u8,
    },
    path: struct {
        path: []const u8,
    },
    command: struct {
        cmd: []const u8,
        exit_code: ?u8 = null,
    },
    none: void,
    
    // Helper to create an empty context
    pub fn empty() ErrorContext {
        return .{ .none = {} };
    }
    
    // Helper to create a config file context
    pub fn configFile(path: []const u8, line: ?usize) ErrorContext {
        return .{ .config_file = .{ .path = path, .line = line } };
    }
    
    // Helper to create an environment context
    pub fn environmentName(name: []const u8) ErrorContext {
        return .{ .environment = .{ .name = name } };
    }
};

// Create a structure that combines error and context
pub const ZenvErrorWithContext = struct {
    err: ZenvError,
    context: ErrorContext,

    // Constructor for convenience
    pub fn init(err: ZenvError, context: ErrorContext) ZenvErrorWithContext {
        return .{
            .err = err,
            .context = context,
        };
    }
    
    // Format function to pretty-print the error
    pub fn format(
        self: ZenvErrorWithContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        
        try writer.print("Error: {s}", .{@errorName(self.err)});
        switch (self.context) {
            .config_file => |ctx| {
                try writer.print(" in config file '{s}'", .{ctx.path});
                if (ctx.line) |line| {
                    try writer.print(" at line {d}", .{line});
                }
            },
            .environment => |ctx| {
                try writer.print(" with environment '{s}'", .{ctx.name});
            },
            .hostname => |ctx| {
                try writer.print(" expected '{s}' but got '{s}'", .{ctx.expected, ctx.actual});
            },
            .path => |ctx| {
                try writer.print(" with path '{s}'", .{ctx.path});
            },
            .command => |ctx| {
                try writer.print(" when executing '{s}'", .{ctx.cmd});
                if (ctx.exit_code) |code| {
                    try writer.print(" (exit code: {d})", .{code});
                }
            },
            .none => {},
        }
    }
};
