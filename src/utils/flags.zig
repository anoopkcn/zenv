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
    @"--group",
};

/// Flags that take a value, as `--flag value` or `--flag=value`.
fn takesValue(flag: Flag) bool {
    return flag == .@"--group";
}

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

    /// The field each flag sets; null for a flag with a value (see `groups`).
    const fields: std.enums.EnumFieldStruct(Flag, ?[]const u8, null) = .{
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
        .@"--group" = null,
    };

    /// Parse command-line args to extract flags
    pub fn fromArgs(args: []const []const u8) CommandFlags {
        var flags: CommandFlags = .{};
        for (args) |arg| switch (std.meta.stringToEnum(Flag, arg) orelse continue) {
            .@"--group" => {},
            inline else => |flag| @field(flags, @field(fields, @tagName(flag)).?) = true,
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
/// a mistyped flag (`--no-cach`) is refused instead of silently ignored. The
/// value of a flag that takes one is skipped; `=value` on any other flag is
/// refused.
pub fn unknownFlag(args: []const []const u8, allowed: []const Flag) ?[]const u8 {
    if (args.len <= 2) return null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "-")) continue;
        const name, const has_value = if (std.mem.cutScalar(u8, arg, '=')) |cut| .{ cut[0], true } else .{ arg, false };
        const flag = std.meta.stringToEnum(Flag, name) orelse return arg;
        if (std.mem.findScalar(Flag, allowed, flag) == null) return arg;
        if (!takesValue(flag)) {
            if (has_value) return arg;
        } else if (!has_value) i += 1;
    }
    return null;
}

/// The dependency groups named by `--group NAME` and `--group=NAME`, in order,
/// without exact repeats. Names borrow from `args`. `badGroup` has refused a
/// missing or invalid name before this is called.
pub fn groups(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = groupArgs(args);
    while (it.next()) |g| {
        const name = g.name orelse continue;
        for (list.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try list.append(allocator, name);
    }
    return list.toOwnedSlice(allocator);
}

/// The first `--group` without a valid name: the argument to quote in the
/// error (`--group` itself when the name is missing), or null.
pub fn badGroup(args: []const []const u8) ?[]const u8 {
    var it = groupArgs(args);
    while (it.next()) |g| {
        const name = g.name orelse return g.arg;
        if (!validGroupName(name)) return if (name.len == 0) g.arg else name;
    }
    return null;
}

/// A dependency group name as PEP 735 allows it (a PEP 508 project name):
/// letters and digits, with `.`, `_` and `-` inside.
pub fn validGroupName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphanumeric(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    return true;
}

/// Iterates the `--group` arguments of a command line.
const GroupArgs = struct {
    args: []const []const u8,
    i: usize = 2,

    const Item = struct {
        /// `--group` or `--group=NAME`, as given.
        arg: []const u8,
        /// Null when `--group` is the last argument or followed by a flag.
        name: ?[]const u8,
    };

    fn next(self: *GroupArgs) ?Item {
        while (self.i < self.args.len) {
            const arg = self.args[self.i];
            self.i += 1;
            if (std.mem.eql(u8, arg, "--group")) {
                if (self.i >= self.args.len or std.mem.startsWith(u8, self.args[self.i], "-")) return .{ .arg = arg, .name = null };
                self.i += 1;
                return .{ .arg = arg, .name = self.args[self.i - 1] };
            }
            if (std.mem.startsWith(u8, arg, "--group=")) return .{ .arg = arg, .name = arg["--group=".len..] };
        }
        return null;
    }
};

fn groupArgs(args: []const []const u8) GroupArgs {
    return .{ .args = args };
}

test "unknownFlag finds the first flag a command does not take" {
    const allowed = [_]Flag{ .@"--uv", .@"--dev" };
    try std.testing.expect(unknownFlag(&.{ "zenv", "add", "e", "pkg", "--uv" }, &allowed) == null);
    try std.testing.expectEqualStrings("--no-cach", unknownFlag(&.{ "zenv", "setup", "--uv", "e", "--no-cach" }, &allowed).?);
    try std.testing.expectEqualStrings("--force", unknownFlag(&.{ "zenv", "add", "e", "--force" }, &allowed).?);
    try std.testing.expect(unknownFlag(&.{"zenv"}, &allowed) == null);
    // --group skips its value; `=value` only on a flag that takes one.
    const with_group = [_]Flag{ .@"--uv", .@"--group" };
    try std.testing.expect(unknownFlag(&.{ "zenv", "setup", "e", "--group", "dev", "--uv", "--group=demo" }, &with_group) == null);
    try std.testing.expectEqualStrings("--uv=1", unknownFlag(&.{ "zenv", "setup", "e", "--uv=1" }, &with_group).?);
    try std.testing.expectEqualStrings("--group", unknownFlag(&.{ "zenv", "setup", "e", "--group", "dev" }, &allowed).?);
}

test "groups: both spellings, in order, repeats dropped; badGroup names the bad one" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "zenv", "setup", "e", "--group", "dev", "--uv", "--group=demo", "--group", "dev" };
    const g = try groups(a, &args);
    defer a.free(g);
    try std.testing.expectEqual(@as(usize, 2), g.len);
    try std.testing.expectEqualStrings("dev", g[0]);
    try std.testing.expectEqualStrings("demo", g[1]);
    try std.testing.expect(badGroup(&args) == null);
    try std.testing.expect(CommandFlags.fromArgs(&args).use_uv);

    try std.testing.expectEqualStrings("--group", badGroup(&.{ "zenv", "setup", "e", "--group" }).?);
    try std.testing.expectEqualStrings("--group", badGroup(&.{ "zenv", "setup", "e", "--group", "--uv" }).?);
    try std.testing.expectEqualStrings("--group=", badGroup(&.{ "zenv", "setup", "e", "--group=" }).?);
    try std.testing.expectEqualStrings("de v", badGroup(&.{ "zenv", "setup", "e", "--group", "de v" }).?);
    try std.testing.expectEqualStrings("-dev", badGroup(&.{ "zenv", "setup", "e", "--group=-dev" }).?);
    try std.testing.expect(validGroupName("Docs_build.v2"));
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
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-")) {
            const flag = std.meta.stringToEnum(Flag, arg) orelse continue;
            if (takesValue(flag)) i += 1; // `--group dev`: "dev" is not positional
            continue;
        }
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

    const args5 = [_][]const u8{ "zenv", "add", "--group", "demo", "myenv", "--group=x", "openai" };
    try testing.expectEqualStrings("myenv", positional(&args5, 0).?);
    try testing.expectEqualStrings("openai", positional(&args5, 1).?);
}
