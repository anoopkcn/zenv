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

// Optional: Define a combined error type for command handlers
// pub const CommandError = ZenvError || error{ /* Other specific errors? */ };
