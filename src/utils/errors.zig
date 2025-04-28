const std = @import("std");

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
};
