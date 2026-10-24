const std = @import("std");

/// Every `--flag` zenv takes. The commands list the ones they accept as enum
/// literals, so a misspelt flag in such a list is a compile error.
pub const Flag = enum {
    @"--force",
    @"--no-host",
    @"--python",
    @"--dev",
    @"--uv",
    @"--pip",
    @"--init",
    @"--no-cache",
    @"--jupyter",
    @"--zenv",
    @"--reuse-module-cache",
    @"--no-python",
};

pub const CommandFlags = struct {
    force_deps: bool = false, // Whether to force install dependencies even if provided by modules
    skip_hostname_check: bool = false, // Whether to skip hostname validation
    use_default_python: bool = false, // Whether to force using the default Python from ZENV_DIR/default-python
    dev_mode: bool = false, // Whether to install the current directory as an editable package
    use_uv: bool = false, // Require 'uv' as the installer
    use_pip: bool = false, // Use pip even when 'uv' is available
    init_mode: bool = false, // Whether to initialize the environment before setup
    no_cache: bool = false, // Whether to disable package cache when installing dependencies
    create_jupyter_kernel: bool = false, // Whether to create a Jupyter kernel after setup
    zenv_only: bool = false, // (zenv add) Record the package only in zenv.json, not requirements.txt/pyproject.toml
    no_python: bool = false, // (zenv init, setup --init) Write the new env with "python": false
    reuse_module_cache: bool = false, // (setup) Replay the module cache instead of re-capturing it when the module set is unchanged

    /// The field each flag sets.
    const fields: std.enums.EnumFieldStruct(Flag, []const u8, null) = .{
        .@"--force" = "force_deps",
        .@"--no-host" = "skip_hostname_check",
        .@"--python" = "use_default_python",
        .@"--dev" = "dev_mode",
        .@"--uv" = "use_uv",
        .@"--pip" = "use_pip",
        .@"--init" = "init_mode",
        .@"--no-cache" = "no_cache",
        .@"--jupyter" = "create_jupyter_kernel",
        .@"--zenv" = "zenv_only",
        .@"--reuse-module-cache" = "reuse_module_cache",
        .@"--no-python" = "no_python",
    };

    /// Parse command-line args to extract flags
    pub fn fromArgs(args: []const []const u8) CommandFlags {
        var flags: CommandFlags = .{};
        for (args) |arg| switch (std.meta.stringToEnum(Flag, arg) orelse continue) {
            inline else => |flag| @field(flags, @field(fields, @tagName(flag))) = true,
        };
        return flags;
    }

    /// The package installer the flags ask for. `--uv` with `--pip` is
    /// refused earlier, by `conflict`.
    pub fn installer(f: CommandFlags) Installer {
        if (f.use_uv) return .uv;
        if (f.use_pip) return .pip;
        return .auto;
    }
};

/// Which tool installs packages: `auto` uses uv when it is on PATH, else pip.
pub const Installer = enum { auto, uv, pip };

/// Two flags in `args` that cannot be combined, or null.
pub fn conflict(args: []const []const u8) ?[2][]const u8 {
    const f = CommandFlags.fromArgs(args);
    if (f.use_uv and f.use_pip) return .{ "--uv", "--pip" };
    return null;
}

/// The first `-`/`--` argument after the command that is not in `allowed`, so
/// a mistyped flag (`--no-cach`) is refused instead of silently ignored.
pub fn unknownFlag(args: []const []const u8, allowed: []const Flag) ?[]const u8 {
    if (args.len <= 2) return null;
    for (args[2..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) continue;
        const flag = std.meta.stringToEnum(Flag, arg) orelse return arg;
        if (std.mem.findScalar(Flag, allowed, flag) == null) return arg;
    }
    return null;
}

test "unknownFlag finds the first flag a command does not take" {
    const allowed = [_]Flag{ .@"--uv", .@"--dev" };
    try std.testing.expect(unknownFlag(&.{ "zenv", "add", "e", "pkg", "--uv" }, &allowed) == null);
    try std.testing.expectEqualStrings("--no-cach", unknownFlag(&.{ "zenv", "setup", "--uv", "e", "--no-cach" }, &allowed).?);
    try std.testing.expectEqualStrings("--force", unknownFlag(&.{ "zenv", "add", "e", "--force" }, &allowed).?);
    try std.testing.expect(unknownFlag(&.{"zenv"}, &allowed) == null);
}

test "fromArgs sets the field of each flag it sees" {
    const f = CommandFlags.fromArgs(&.{ "zenv", "setup", "--uv", "e", "--no-host", "--no-python" });
    try std.testing.expect(f.use_uv and f.skip_hostname_check and f.no_python);
    try std.testing.expect(!f.force_deps and !f.dev_mode and !f.init_mode and !f.zenv_only);
}

test "installer: --uv, --pip, else auto; both conflict" {
    try std.testing.expectEqual(Installer.auto, CommandFlags.fromArgs(&.{ "zenv", "setup", "e" }).installer());
    try std.testing.expectEqual(Installer.uv, CommandFlags.fromArgs(&.{ "zenv", "setup", "e", "--uv" }).installer());
    try std.testing.expectEqual(Installer.pip, CommandFlags.fromArgs(&.{ "zenv", "add", "e", "p", "--pip" }).installer());
    try std.testing.expect(conflict(&.{ "zenv", "setup", "e", "--uv" }) == null);
    try std.testing.expect(conflict(&.{ "zenv", "setup", "--pip", "e", "--uv" }) != null);
}

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
