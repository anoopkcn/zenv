// Define application-specific errors

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
    // Errors propagated from std.process
    EnvironmentVariableNotFound, // From getEnvVarOwned
    InvalidWtf8,                // From getEnvVarOwned
    ArgsError,                  // Added for command line argument issues
};

// Optional: Define a combined error type for command handlers
// pub const CommandError = ZenvError || error{ /* Other specific errors? */ };
