const std = @import("std");

pub const CommandFlags = struct {
    force_deps: bool = false, // Whether to force install dependencies even if provided by modules
    skip_hostname_check: bool = false, // Whether to skip hostname validation
    use_default_python: bool = false, // Whether to force using the default Python from ZENV_DIR/default-python
    dev_mode: bool = false, // Whether to install the current directory as an editable package
    use_uv: bool = false, // Whether to use 'uv' instead of 'pip'
    init_mode: bool = false, // Whether to initialize the environment before setup
    no_cache: bool = false, // Whether to disable package cache when installing dependencies
    create_jupyter_kernel: bool = false, // Whether to create a Jupyter kernel after setup

    /// Parse command-line args to extract flags
    pub fn fromArgs(args: []const []const u8) CommandFlags {
        var flags = CommandFlags{};

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--force")) {
                flags.force_deps = true;
            } else if (std.mem.eql(u8, arg, "--no-host")) {
                flags.skip_hostname_check = true;
            } else if (std.mem.eql(u8, arg, "--python")) {
                flags.use_default_python = true;
            } else if (std.mem.eql(u8, arg, "--dev")) {
                flags.dev_mode = true;
            } else if (std.mem.eql(u8, arg, "--uv")) {
                flags.use_uv = true;
            } else if (std.mem.eql(u8, arg, "--init")) {
                flags.init_mode = true;
            } else if (std.mem.eql(u8, arg, "--no-cache")) {
                flags.no_cache = true;
            } else if (std.mem.eql(u8, arg, "--jupyter")) {
                flags.create_jupyter_kernel = true;
            }
        }

        return flags;
    }
};
