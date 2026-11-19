const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const paths = @import("paths.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const Ctx = runtime.Ctx;

/// Define Python versions we know work well
const default_version = "3.10.8";

/// True when `<dir>/bin/python3` exists. Any error other than FileNotFound is
/// warned about and counts as absent.
fn hasPython3(allocator: Allocator, io: Io, dir: []const u8) !bool {
    const python_bin = try Io.Dir.path.join(allocator, &.{ dir, "bin", "python3" });
    defer allocator.free(python_bin);
    Io.Dir.cwd().access(io, python_bin, .{}) catch |err| {
        if (err != error.FileNotFound) output.printWarning(
            io,
            "Error checking Python executable: {t}",
            .{err},
        );
        return false;
    };
    return true;
}

/// Get path to the Python version for "use" command
fn getPythonVersionPath(ctx: Ctx, version: []const u8) ![]const u8 {
    const install_dir = try paths.zenvPath(
        ctx.arena,
        ctx.env,
        try Io.Dir.path.join(ctx.arena, &.{ "python", version }),
    );
    if (!try hasPython3(ctx.arena, ctx.io, install_dir)) {
        output.printError(ctx.io, "Python version {s} is not installed", .{version});
        output.printError(ctx.io, "Use 'zenv python install {s}' to install it first", .{version});
        return error.FileNotFound;
    }
    return install_dir;
}

/// The versions installed under ZENV_DIR/python: its subdirectories with a
/// bin/python3, newest first.
pub fn installedVersions(ctx: Ctx) ![]const []const u8 {
    const a = ctx.arena;
    const base_install_dir = try paths.zenvPath(a, ctx.env, "python");
    var versions: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(
        ctx.io,
        base_install_dir,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound => return versions.items,
        else => return err,
    };
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        const install_path = try Io.Dir.path.join(a, &.{ base_install_dir, entry.name });
        if (try hasPython3(a, ctx.io, install_path)) try versions.append(
            a,
            try a.dupe(u8, entry.name),
        );
    }
    // Directory order is arbitrary; list (and suggest) the newest first.
    std.mem.sort([]const u8, versions.items, {}, newerFirst);
    return versions.items;
}

fn newerFirst(_: void, l: []const u8, r: []const u8) bool {
    const lr = Release.parse(l) orelse return false;
    const rr = Release.parse(r) orelse return true;
    return lr.order(rr) == .gt;
}

/// List all installed Python versions
pub fn listInstalled(ctx: Ctx) !void {
    const versions = try installedVersions(ctx);
    const base_install_dir = try paths.zenvPath(ctx.arena, ctx.env, "python");
    const default_path = try pinnedPath(ctx);
    for (versions) |v| {
        const install_path = try Io.Dir.path.join(ctx.arena, &.{ base_install_dir, v });
        const is_default = if (default_path) |p| std.mem.eql(u8, install_path, p) else false;
        output.rawOut(ctx.io, "{s}{s}\n", .{ v, if (is_default) " (pinned)" else "" });
    }

    if (versions.len == 0) {
        output.print(ctx.io, "No Python versions installed yet", .{});
        output.print(
            ctx.io,
            "Use 'zenv python install <version>' to install a Python version",
            .{},
        );
    }
}

/// Write the default Python path to a file
pub fn pin(ctx: Ctx, version: []const u8) !void {
    const python_path = try getPythonVersionPath(ctx, version);
    const zenv_dir = try paths.getZenvDir(ctx.arena, ctx.env);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(ctx.io, zenv_dir);
    try cwd.writeFile(
        ctx.io,
        .{
            .sub_path = try Io.Dir.path.join(ctx.arena, &.{ zenv_dir, "default-python" }),
            .data = python_path,
        },
    );

    output.print(ctx.io, "Set Python {s} as the default version", .{version});
    output.print(
        ctx.io,
        "This will be used as the fallback Python when not specified in zenv.json",
        .{},
    );
}

/// Removes the pin by deleting ZENV_DIR/default-python. Having no pin is not
/// an error. The installed Pythons are left in place.
pub fn unpin(ctx: Ctx) !void {
    const pinned = try pinnedPath(ctx) orelse {
        output.print(ctx.io, "No Python is pinned", .{});
        return;
    };
    const default_file_path = try paths.zenvPath(ctx.arena, ctx.env, "default-python");
    Io.Dir.cwd().deleteFile(ctx.io, default_file_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            output.printError(ctx.io, "Failed to remove default-python file: {t}", .{err});
            return err;
        },
    };
    output.print(ctx.io, "Unpinned Python {s}", .{Io.Dir.path.basename(pinned)});
}

/// The pinned Python's install directory from ZENV_DIR/default-python, or
/// null when nothing is pinned.
pub fn pinnedPath(ctx: Ctx) !?[]const u8 {
    const default_file_path = try paths.zenvPath(ctx.arena, ctx.env, "default-python");
    const content = Io.Dir.cwd().readFileAlloc(
        ctx.io,
        default_file_path,
        ctx.arena,
        .limited(1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            output.printError(ctx.io, "Failed to read default-python file: {t}", .{err});
            return err;
        },
    };
    return std.mem.trim(u8, content, "\n\r\t ");
}

/// What the gzip trailer records about the uncompressed data.
const GzipCheck = struct {
    crc: std.hash.Crc32 = .init(),
    len: u32 = 0,

    pub fn update(c: *GzipCheck, bytes: []const u8) void {
        c.crc.update(bytes);
        c.len +%= @truncate(bytes.len);
    }
};

/// Downloads the source tarball at `url` and unpacks it into `dest` without
/// its top directory, in one pass: the response body is decompressed and
/// unpacked as it arrives, so no tarball is stored.
fn fetchSource(gpa: Allocator, io: Io, url: []const u8, dest: Io.Dir) !void {
    output.print(io, "Downloading {s}", .{url});
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var request = try client.request(.GET, try std.Uri.parse(url), .{});
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const status = response.head.status;
    if (status != .ok) {
        output.printError(
            io,
            "Failed to download {s}: HTTP {d} {s}",
            .{ url, @backingInt(status), status.phrase() orelse "" },
        );
        return error.HttpError;
    }

    // The body is the .tgz itself; no Content-Encoding is undone here.
    var transfer_buffer: [64 * 1024]u8 = undefined;
    unpackTarGz(io, response.reader(&transfer_buffer), dest) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse err,
        error.CorruptDownload => {
            output.printError(
                io,
                "The download of {s} is corrupt (gzip checksum mismatch)",
                .{url},
            );
            return err;
        },
        else => return err,
    };
    output.print(io, "Download complete", .{});
}

/// Unpacks the .tar.gz read from `in` into `dest`, without its top directory.
/// std's gzip reader does not compare the trailer's CRC-32 and length with the
/// data, so that is done here: damaged data fails with error.CorruptDownload
/// instead of being built from.
fn unpackTarGz(io: Io, in: *Io.Reader, dest: Io.Dir) !void {
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gunzip: std.compress.flate.Decompress = .init(in, .gzip, &window);
    var check_buffer: [64 * 1024]u8 = undefined;
    var checked = gunzip.reader.hashed(GzipCheck{}, &check_buffer);

    std.tar.extract(
        io,
        dest,
        &checked.reader,
        .{ .strip_components = 1 },
    ) catch |err| switch (err) {
        error.ReadFailed => return gunzip.err orelse err,
        else => return err,
    };
    // The archive's end marker can come before the end of the gzip stream;
    // reading the rest reaches the trailer.
    _ = checked.reader.discardRemaining() catch |err| return gunzip.err orelse err;
    const trailer = gunzip.container_metadata.gzip;
    if (trailer.crc != checked.hasher.crc.final() or trailer.count != checked.hasher.len)
        return error.CorruptDownload;
}

/// Gives every file under `dir` the same modification time. Unpacking stamps
/// files in archive order, which can make a generated source that ships in
/// the tarball look older than its input, and make would then try to
/// regenerate it with tools the build may not have.
fn uniformMtimes(gpa: Allocator, io: Io, dir: Io.Dir) !void {
    const stamp: Io.File.SetTimestamp = .{ .new = Io.Clock.real.now(io) };
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        try entry.dir.setTimestamps(
            io,
            entry.basename,
            .{ .modify_timestamp = stamp, .follow_symlinks = false },
        );
    }
}

/// The version and configure options of `zenv python install [version] [-- opts...]`,
/// or the first argument before `--` that is neither: an extra word, or an
/// option that belongs after `--`.
pub const InstallArgs = union(enum) {
    ok: struct { version: ?[]const u8, configure: []const []const u8 },
    unexpected: []const u8,

    /// `rest` is what follows `install` on the command line.
    pub fn parse(rest: []const []const u8) InstallArgs {
        var split = rest.len;
        for (rest, 0..) |arg, i| if (std.mem.eql(u8, arg, "--")) {
            split = i;
            break;
        };
        const before = rest[0..split];
        const configure = if (split < rest.len) rest[split + 1 ..] else &.{};
        if (before.len > 1) return .{ .unexpected = before[1] };
        if (before.len == 1 and std.mem.startsWith(u8, before[0], "-"))
            return .{ .unexpected = before[0] };
        return .{ .ok = .{
            .version = if (before.len == 1) before[0] else null,
            .configure = configure,
        } };
    }
};

/// The prefix of Homebrew's openssl@3 when it has headers, else null. Not
/// openssl@4: its opaque ASN1 types break _ssl.c in CPython 3.13.0. CPython's
/// configure does not look in Homebrew's prefixes, and macOS ships no OpenSSL
/// headers, so without this the build silently leaves out the ssl module.
fn homebrewOpenssl(a: Allocator, io: Io, env: *const std.process.Environ.Map) !?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    for ([_]?[]const u8{ env.get("HOMEBREW_PREFIX"), "/opt/homebrew", "/usr/local" }) |brew| {
        const prefix = try Io.Dir.path.join(a, &.{ brew orelse continue, "opt", "openssl@3" });
        const header = try Io.Dir.path.join(a, &.{ prefix, "include", "openssl", "ssl.h" });
        if (runtime.exists(io, header)) return prefix;
    }
    return null;
}

/// The `./configure` command: zenv's defaults, `--with-openssl=<openssl>`
/// unless the user gives one, then ZENV_PYTHON_CONFIGURE_OPTS (split on
/// whitespace) and `cli`. User options come last because autoconf keeps the
/// last of a repeated option, so they override the defaults.
fn configureArgv(
    a: Allocator,
    install_dir: []const u8,
    openssl: ?[]const u8,
    env_opts: ?[]const u8,
    cli: []const []const u8,
) ![]const []const u8 {
    var user: std.ArrayList([]const u8) = .empty;
    if (env_opts) |opts| {
        var it = std.mem.tokenizeAny(u8, opts, " \t\r\n");
        while (it.next()) |arg| try user.append(a, arg);
    }
    try user.appendSlice(a, cli);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{
        "./configure",
        "--prefix",
        install_dir,
        "--enable-optimizations",
        "--disable-test-modules",
        "--with-ensurepip=install",
    });
    const user_openssl = for (user.items) |arg| {
        if (std.mem.startsWith(u8, arg, "--with-openssl=")) break true;
    } else false;
    if (openssl) |dir| if (!user_openssl) try argv.append(a, try a.print("--with-openssl={s}", .{dir}));
    try argv.appendSlice(a, user.items);
    return argv.items;
}

/// Configure and build Python
fn buildPython(
    ctx: Ctx,
    source_dir: []const u8,
    install_dir: []const u8,
    configure_argv: []const []const u8,
) !void {
    const io = ctx.io;
    output.print(io, "Configuring Python build in {s}", .{source_dir});
    output.print(io, "Python will be installed to {s}", .{install_dir});

    Io.Dir.cwd().createDirPath(io, install_dir) catch |err| {
        output.printError(
            io,
            "Failed to create installation directory '{s}': {t}",
            .{ install_dir, err },
        );
        return err;
    };

    const start = Io.Timestamp.now(io, .awake);

    // Determine the number of CPU cores for the parallel build, leaving one
    // core free to keep the system responsive (fall back to 1 on failure).
    const cores_to_use = if (std.Thread.getCpuCount()) |count| @max(count - 1, 1) else |_| 1;
    const cpu_count = try ctx.arena.print("{d}", .{cores_to_use});
    const make_msg = try ctx.arena.print("Building Python (make -j {s})...", .{cpu_count});

    // Each step's output streams straight to the user's terminal.
    const Step = struct {
        msg: []const u8,
        argv: []const []const u8,
        failed: []const u8,
        err: error{ ConfigureFailed, BuildFailed, InstallFailed },
    };
    const steps = [_]Step{
        .{
            .msg = try ctx.arena.print(
                "Configuring Python: {s}",
                .{try std.mem.join(ctx.arena, " ", configure_argv)},
            ),
            .argv = configure_argv,
            .failed = "Configuration failed",
            .err = error.ConfigureFailed,
        },
        .{
            .msg = make_msg,
            .argv = &.{ "make", "-j", cpu_count },
            .failed = "Build failed",
            .err = error.BuildFailed,
        },
        .{
            .msg = "Installing Python (make install)...",
            .argv = &.{ "make", "install" },
            .failed = "Installation failed",
            .err = error.InstallFailed,
        },
    };
    for (steps) |step| {
        output.print(io, "{s}", .{step.msg});
        const term = try runtime.exec(io, step.argv, .{ .cwd = source_dir });
        if (!term.success()) {
            output.printError(io, "{s} (see output above)", .{step.failed});
            return step.err;
        }
    }

    output.print(
        io,
        "Python installation completed successfully in {f}",
        .{start.untilNow(io, .awake)},
    );
}

/// Warns when the Python at `install_dir` cannot import ssl: pip then cannot
/// reach PyPI, and the build only mentions it among its last lines.
fn checkSsl(ctx: Ctx, install_dir: []const u8, version: []const u8) void {
    const python3 = Io.Dir.path.join(ctx.arena, &.{ install_dir, "bin", "python3" }) catch return;
    const ok = if (runtime.run(ctx.arena, ctx.io, &.{ python3, "-c", "import ssl" }, .{})) |r|
        r.term == .exited and r.term.exited == 0
    else |_|
        false;
    if (ok) return;
    output.printWarning(
        ctx.io,
        "Python {s} was built without the ssl module, so pip cannot download packages.",
        .{version},
    );
    output.printWarning(
        ctx.io,
        "Install OpenSSL with its headers, then reinstall with its prefix: rm -rf {s} && zenv python install {s} -- --with-openssl=<dir>",
        .{ install_dir, version },
    );
}

/// Downloads, builds and installs Python `version` (default: `default_version`)
/// into ZENV_DIR/python/<version>. `configure_opts` go to ./configure after
/// zenv's own options and those of ZENV_PYTHON_CONFIGURE_OPTS.
pub fn install(ctx: Ctx, version: ?[]const u8, configure_opts: []const []const u8) !void {
    const io = ctx.io;
    const a = ctx.arena;
    const python_version = version orelse default_version;
    const install_dir = try paths.zenvPath(
        a,
        ctx.env,
        try Io.Dir.path.join(a, &.{ "python", python_version }),
    );

    // Check if this version is already installed
    if (try hasPython3(a, io, install_dir)) {
        output.print(
            io,
            "Python {s} is already installed at {s}",
            .{ python_version, install_dir },
        );
        output.print(
            io,
            "To reinstall, first remove the directory manually: rm -rf {s}",
            .{install_dir},
        );
        return;
    }

    // A fresh build directory under $TMPDIR (shared login nodes), removed
    // afterwards: random, so concurrent installs cannot share one.
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const build_dir = try a.print(
        "{s}/zenv-python-build-{s}",
        .{ runtime.tempDir(ctx.env), &std.fmt.bytesToHex(nonce, .lower) },
    );
    const cwd = Io.Dir.cwd();
    var source = cwd.createDirPathOpen(
        io,
        build_dir,
        .{ .open_options = .{ .iterate = true } },
    ) catch |err| {
        output.printError(io, "Failed to create build directory: {t}", .{err});
        return err;
    };
    defer cwd.deleteTree(io, build_dir) catch |err| {
        output.printWarning(
            io,
            "Failed to delete temporary directory {s}: {t}",
            .{ build_dir, err },
        );
    };
    {
        defer source.close(io);
        const url = try a.print(
            "https://www.python.org/ftp/python/{s}/Python-{s}.tgz",
            .{ python_version, python_version },
        );
        try fetchSource(a, io, url, source);
        try uniformMtimes(a, io, source);
    }

    const configure_argv = try configureArgv(
        a,
        install_dir,
        try homebrewOpenssl(a, io, ctx.env),
        ctx.getEnv("ZENV_PYTHON_CONFIGURE_OPTS"),
        configure_opts,
    );
    try buildPython(ctx, build_dir, install_dir, configure_argv);

    output.print(io, "Python {s} has been successfully installed!", .{python_version});
    output.print(io, "Installation path: {s}", .{install_dir});
    checkSsl(ctx, install_dir, python_version);
}

/// The release numbers of a version ("3.12.1" -> 3, 12, 1), zero-padded so
/// that 3.10 equals 3.10.0. A suffix such as "rc1" or "+local" ends it.
/// Not `std.SemanticVersion`: PEP 440 versions may have two or four numbers,
/// and a pre-release counts as its release here, as pip treats it.
const Release = struct {
    parts: [4]u32 = @splat(0),
    len: usize = 0,

    /// Null without a leading number, or with more than four numbers.
    fn parse(text: []const u8) ?Release {
        var r: Release = .{};
        var it = std.mem.splitScalar(u8, text, '.');
        while (it.next()) |part| {
            const digits = std.mem.findNone(u8, part, "0123456789") orelse part.len;
            if (digits == 0 or r.len == r.parts.len) return null;
            r.parts[r.len] = std.fmt.parseInt(u32, part[0..digits], 10) catch return null;
            r.len += 1;
            if (digits < part.len) break;
        }
        return r;
    }

    fn order(a: Release, b: Release) std.math.Order {
        return std.mem.order(u32, &a.parts, &b.parts);
    }

    fn samePrefix(a: Release, b: Release, n: usize) bool {
        return std.mem.eql(u32, a.parts[0..n], b.parts[0..n]);
    }
};

/// The PEP 440 comparison operators `satisfies` reads.
const Operator = enum { @"==", @"!=", @">=", @"<=", @">", @"<", @"~=" };

/// Whether Python `version` ("3.12.1") satisfies the PEP 440 specifier set
/// `spec`, as written in requires-python: ">=3.10, <4", "~=3.11", "==3.12.*",
/// "!=3.9.*". Like pip, only the release numbers count, so 3.13.0rc1 is
/// treated as 3.13.0. error.InvalidSpecifier when either does not parse;
/// "===" (arbitrary equality) is not supported.
pub fn satisfies(spec: []const u8, version: []const u8) error{InvalidSpecifier}!bool {
    const have = Release.parse(version) orelse return error.InvalidSpecifier;
    var clauses = std.mem.splitScalar(u8, spec, ',');
    while (clauses.next()) |raw| {
        const clause = std.mem.trim(u8, raw, " \t");
        const op_end = std.mem.findNone(u8, clause, "<>=!~") orelse return error.InvalidSpecifier;
        const op = std.meta.stringToEnum(
            Operator,
            clause[0..op_end],
        ) orelse return error.InvalidSpecifier;
        var text = std.mem.trim(u8, clause[op_end..], " \t");
        const wildcard = std.mem.endsWith(u8, text, ".*");
        if (wildcard) text = text[0 .. text.len - 2];
        const want = Release.parse(text) orelse return error.InvalidSpecifier;
        const ord = have.order(want);

        if (wildcard and op != .@"==" and op != .@"!=") return error.InvalidSpecifier;
        const ok = switch (op) {
            .@"==", .@"!=" => (if (wildcard) have.samePrefix(
                want,
                want.len,
            ) else ord == .eq) == (op == .@"=="),
            .@">=" => ord != .lt,
            .@"<=" => ord != .gt,
            .@">" => ord == .gt,
            .@"<" => ord == .lt,
            .@"~=" => if (want.len < 2) return error.InvalidSpecifier else ord != .lt and have.samePrefix(
                want,
                want.len - 1,
            ),
        };
        if (!ok) return false;
    }
    return true;
}

// ============================ Tests ============================
const testing = std.testing;

test "hasPython3 checks for bin/python3" {
    const a = testing.allocator;
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const dir = ".zig-cache/tmp/zenv_python_test";
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};

    try cwd.createDirPath(io, dir ++ "/bin");
    try testing.expect(!try hasPython3(a, io, dir));
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/bin/python3", .data = "" });
    try testing.expect(try hasPython3(a, io, dir));
}

test "installedVersions lists installs with bin/python3, newest first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const zdir = ".zig-cache/tmp/zenv_python_versions_test";
    cwd.deleteTree(io, zdir) catch {};
    defer cwd.deleteTree(io, zdir) catch {};
    for ([_][]const u8{ "3.9.6", "3.13.1", "3.10.8" }) |v| {
        try cwd.createDirPath(io, try a.print(zdir ++ "/python/{s}/bin", .{v}));
        try cwd.writeFile(
            io,
            .{ .sub_path = try a.print(zdir ++ "/python/{s}/bin/python3", .{v}), .data = "" },
        );
    }
    try cwd.createDirPath(io, zdir ++ "/python/broken"); // no bin/python3

    var env = std.process.Environ.Map.init(a);
    try env.put("ZENV_DIR", zdir);
    const versions = try installedVersions(.{ .arena = a, .io = io, .env = &env });
    try testing.expectEqual(@as(usize, 3), versions.len);
    for ([_][]const u8{
        "3.13.1",
        "3.10.8",
        "3.9.6",
    }, versions) |want, got| try testing.expectEqualStrings(
        want,
        got,
    );
}

test "InstallArgs.parse splits the version from the configure options" {
    const ok = InstallArgs.parse(&.{ "3.13.0", "--", "--with-lto", "--with-openssl=/x" }).ok;
    try testing.expectEqualStrings("3.13.0", ok.version.?);
    try testing.expectEqual(@as(usize, 2), ok.configure.len);
    try testing.expectEqualStrings("--with-openssl=/x", ok.configure[1]);

    const no_version = InstallArgs.parse(&.{ "--", "--with-lto" }).ok;
    try testing.expect(no_version.version == null);
    try testing.expectEqual(@as(usize, 1), no_version.configure.len);

    const bare = InstallArgs.parse(&.{"3.12.0"}).ok;
    try testing.expectEqualStrings("3.12.0", bare.version.?);
    try testing.expectEqual(@as(usize, 0), bare.configure.len);
    try testing.expect(InstallArgs.parse(&.{}).ok.version == null);

    // A configure option before `--`, or a second word, is refused.
    try testing.expectEqualStrings(
        "--with-lto",
        InstallArgs.parse(&.{ "3.13.0", "--with-lto" }).unexpected,
    );
    try testing.expectEqualStrings(
        "--with-lto",
        InstallArgs.parse(&.{"--with-lto"}).unexpected,
    );
    try testing.expectEqualStrings("3.12", InstallArgs.parse(&.{ "3.13", "3.12" }).unexpected);
}

test "configureArgv puts user options after the defaults, the env var before the CLI" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults = [_][]const u8{
        "./configure",
        "--prefix",
        "/p",
        "--enable-optimizations",
        "--disable-test-modules",
        "--with-ensurepip=install",
    };

    const argv = try configureArgv(a, "/p", "/brew/openssl@3", "  --with-lto\t--enable-shared ", &.{"--without-ensurepip"});
    const want = defaults ++ [_][]const u8{
        "--with-openssl=/brew/openssl@3",
        "--with-lto",
        "--enable-shared",
        "--without-ensurepip",
    };
    try testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try testing.expectEqualStrings(w, g);

    // The user's --with-openssl replaces the detected one.
    const own = try configureArgv(a, "/p", "/brew/openssl@3", null, &.{"--with-openssl=/mine"});
    try testing.expectEqual(defaults.len + 1, own.len);
    try testing.expectEqualStrings("--with-openssl=/mine", own[defaults.len]);

    // Nothing detected or given: the defaults alone.
    try testing.expectEqual(defaults.len, (try configureArgv(a, "/p", null, "", &.{})).len);
}

test "satisfies matches requires-python specifiers on release numbers" {
    const cases = [_]struct { spec: []const u8, version: []const u8, ok: bool }{
        .{ .spec = ">=3.10", .version = "3.12.1", .ok = true },
        .{ .spec = ">=3.10", .version = "3.9.6", .ok = false },
        .{ .spec = ">=3.10", .version = "3.10.0", .ok = true },
        .{ .spec = ">= 3.8, <4", .version = "3.13.0", .ok = true },
        .{ .spec = ">=3.8,<3.12", .version = "3.12.0", .ok = false },
        .{ .spec = ">3.9", .version = "3.9.1", .ok = true },
        .{ .spec = ">3.9", .version = "3.9", .ok = false },
        .{ .spec = "<=3.11", .version = "3.11.0", .ok = true },
        .{ .spec = "<=3.11", .version = "3.11.2", .ok = false },
        .{ .spec = "~=3.10", .version = "3.13.2", .ok = true },
        .{ .spec = "~=3.10", .version = "4.0.0", .ok = false },
        .{ .spec = "~=3.10.2", .version = "3.10.9", .ok = true },
        .{ .spec = "~=3.10.2", .version = "3.11.0", .ok = false },
        .{ .spec = "==3.12.*", .version = "3.12.4", .ok = true },
        .{ .spec = "==3.12.*", .version = "3.13.0", .ok = false },
        .{ .spec = "==3.12", .version = "3.12.0", .ok = true },
        .{ .spec = "==3.12", .version = "3.12.1", .ok = false },
        .{ .spec = "!=3.9.*", .version = "3.9.7", .ok = false },
        .{ .spec = ">=3.8, !=3.9.*", .version = "3.10.1", .ok = true },
        // Pre-releases count as their final release, as pip treats them.
        .{ .spec = ">=3.13", .version = "3.13.0rc1", .ok = true },
        .{ .spec = "<3.13", .version = "3.13.0rc1", .ok = false },
    };
    for (cases) |c| {
        if ((try satisfies(c.spec, c.version)) != c.ok) {
            std.debug.print("satisfies(\"{s}\", \"{s}\") != {}\n", .{ c.spec, c.version, c.ok });
            return error.TestUnexpectedResult;
        }
    }
}

test "satisfies rejects specifiers it cannot read" {
    for ([_][]const u8{
        "3.10",
        ">=3.x",
        ">=3.10,",
        "===3.10.0",
        ">=3.*",
        "~=3",
        "",
        ">=1.2.3.4.5",
    }) |spec| {
        try testing.expectError(error.InvalidSpecifier, satisfies(spec, "3.12.1"));
    }
    try testing.expectError(error.InvalidSpecifier, satisfies(">=3.10", "unknown"));
}

test "unpackTarGz extracts without the top directory and checks the gzip trailer" {
    const io = testing.io;
    const cwd = Io.Dir.cwd();
    const root = ".zig-cache/tmp/zenv-python-untar-test";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};

    // A gzip'd tar of Python-x/{configure (0755), README}, built with `tar czf`.
    const tgz = @embedFile("testdata/python-src.tgz");

    // A wrong CRC-32 in the trailer (its last 8 bytes) is caught: std's
    // gzip reader itself accepts it.
    {
        var bad = tgz.*;
        bad[bad.len - 8] ^= 0xff;
        var dest = try cwd.createDirPathOpen(io, root ++ "/bad", .{});
        defer dest.close(io);
        var in: Io.Reader = .fixed(&bad);
        try testing.expectError(error.CorruptDownload, unpackTarGz(io, &in, dest));
    }

    var dest = try cwd.createDirPathOpen(
        io,
        root ++ "/good",
        .{ .open_options = .{ .iterate = true } },
    );
    defer dest.close(io);
    var in: Io.Reader = .fixed(tgz);
    try unpackTarGz(io, &in, dest);

    const st = try dest.statFile(io, "configure", .{});
    try testing.expect(st.permissions.toMode() & 0o100 != 0);
    try uniformMtimes(testing.allocator, io, dest);
    const a = try dest.statFile(io, "configure", .{});
    const b = try dest.statFile(io, "README", .{});
    try testing.expectEqual(a.mtime, b.mtime);
}
