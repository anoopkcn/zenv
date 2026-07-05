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
    zenv_only: bool = false, // (zenv add) Record the package only in zenv.json, not requirements.txt/pyproject.toml

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
            } else if (std.mem.eql(u8, arg, "--zenv")) {
                flags.zenv_only = true;
            }
        }

        return flags;
    }
};

/// Returns the `idx`-th positional argument after the command (i.e. within
/// `args[2..]`), skipping `-`/`--` flags. Keeps `zenv setup --init myenv` and
/// `zenv setup myenv --init` equivalent instead of silently treating the flag
/// itself as the environment name.
pub fn positional(args: []const []const u8, idx: usize) ?[]const u8 {
    if (args.len <= 2) return null;
    var seen: usize = 0;
    for (args[2..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) continue;
        if (seen == idx) return arg;
        seen += 1;
    }
    return null;
}

// ============================ Tests ============================
const testing = std.testing;

test "positional skips flags regardless of position" {
    const args1 = [_][]const u8{ "zenv", "setup", "--init", "myenv", "desc" };
    try testing.expectEqualStrings("myenv", positional(&args1, 0).?);
    try testing.expectEqualStrings("desc", positional(&args1, 1).?);

    const args2 = [_][]const u8{ "zenv", "setup", "myenv", "--init" };
    try testing.expectEqualStrings("myenv", positional(&args2, 0).?);
    try testing.expect(positional(&args2, 1) == null);

    const args3 = [_][]const u8{ "zenv", "setup", "--init" };
    try testing.expect(positional(&args3, 0) == null);

    const args4 = [_][]const u8{ "zenv", "setup" };
    try testing.expect(positional(&args4, 0) == null);
}
