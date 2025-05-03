const std = @import("std");

/// Struct to hold command flags for better handling
pub const CommandFlags = struct {
    force_deps: bool = false, // Whether to force install dependencies even if provided by modules
    skip_hostname_check: bool = false, // Whether to skip hostname validation
    force_rebuild: bool = false, // Whether to force rebuild the virtual environment
    use_default_python: bool = false, // Whether to force using the default Python from ZENV_DIR/default-python

    /// Parse command-line args to extract flags
    pub fn fromArgs(args: []const []const u8) CommandFlags {
        var flags = CommandFlags{};

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--force-deps")) {
                flags.force_deps = true;
            } else if (std.mem.eql(u8, arg, "--no-host")) {
                flags.skip_hostname_check = true;
            } else if (std.mem.eql(u8, arg, "--rebuild")) {
                flags.force_rebuild = true;
            } else if (std.mem.eql(u8, arg, "--python")) {
                flags.use_default_python = true;
            }
        }

        return flags;
    }
};
