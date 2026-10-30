const std = @import("std");
const Io = std.Io;
const output = @import("output.zig");

/// Maps any error that reaches the top level to a single user-facing message,
/// then exits the process. This is the one place error presentation lives; `main`
/// only dispatches here.
///
/// Note: this does NOT enforce that every error has a friendly message. The
/// `anyerror` boundary needs the `else` safety net.
pub fn report(io: Io, err: anyerror) noreturn {
    switch (err) {
        error.ConfigFileNotFound => output.printError(
            io,
            "Configuration file 'zenv.json' not found",
            .{},
        ),
        error.FileNotFound => output.printError(
            io,
            "zenv could not find a file required to complete this command",
            .{},
        ),
        error.EnvironmentNotFound => output.printError(
            io,
            "Environment name not found in configuration or argument missing",
            .{},
        ),
        error.InvalidFormat => output.printError(
            io,
            "Invalid JSON format in 'zenv.json'. Check syntax for details above",
            .{},
        ),
        error.ConfigInvalid => output.printError(
            io,
            "Invalid configuration structure in 'zenv.json'. Check keys/types/required fields",
            .{},
        ),
        error.MissingHostname => output.printError(
            io,
            "HOSTNAME is not set or inaccessible which is required for validation",
            .{},
        ),
        error.PathResolutionFailed => output.printError(
            io,
            "Failed to resolve a required file path (e.g., requirements file)",
            .{},
        ),
        error.TargetMachineMismatch => output.printError(
            io,
            "Current machine does not match the target specified for this environment",
            .{},
        ),
        error.RegistryError => output.printError(
            io,
            "Failed to access the environment registry. Check permissions for ZENV_DIR",
            .{},
        ),
        error.ArgsError => output.printError(
            io,
            "Invalid command-line arguments provided. Check usage with 'zenv help'",
            .{},
        ),
        error.MissingPythonExecutable => {
            output.printError(
                io,
                "A required Python executable was not found or is not configured",
                .{},
            );
            output.printError(
                io,
                "Use 'zenv python install <version>' or configure 'fallback_python' in zenv.json",
                .{},
            );
        },
        error.InvalidRegistryFormat => output.printError(
            io,
            "The registry file (ZENV_DIR/registry.json) is corrupted or has an invalid format",
            .{},
        ),
        error.IoError => output.printError(
            io,
            "An I/O error occurred. Check file system permissions and disk space",
            .{},
        ),
        error.OutOfMemory => output.printError(
            io,
            "The application ran out of memory. Try freeing up system resources",
            .{},
        ),
        error.InvalidPath => output.printError(io, "Invalid file or directory path", .{}),
        error.HomeDirectoryNotFound => output.printError(
            io,
            "Failed to get HOME environment variable (needed when ZENV_DIR is not set)",
            .{},
        ),
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
        error.DependencyGroupNotFound,
        error.InvalidDependencyGroup,
        error.RecordFailed,
        error.ContainerEnv,
        => {},
        else => output.printError(io, "An unexpected error occurred: {t}", .{err}),
    }
    std.process.exit(1);
}
