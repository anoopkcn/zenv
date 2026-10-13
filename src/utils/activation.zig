//! Renders activation scripts from an `envspec.Spec`.
//!
//! activate.sh (bash/zsh) and activate.csh (csh/tcsh) are generated from the
//! same data `zenv run` applies directly; the venv's own bin/activate is no
//! longer sourced. Each script defines `deactivate`. It saves PATH, PYTHONHOME
//! and the prompt under the venv convention's `_OLD_VIRTUAL_*` names, so
//! activating over a plain venv (or the other way round) deactivates cleanly.
//! Variables the venv convention does not cover are saved as `_ZENV_OLD_<NAME>`
//! and restored only when zenv activated them (`_ZENV_ACTIVE`).
//!
//! What still needs shell logic at activation time is the module section: the
//! module cache is only valid on the system it was captured on, and otherwise
//! `module load` must run. The user's activate hooks are sh code, so they run
//! from activate.sh only; activate.csh warns that it skipped them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const envspec = @import("envspec.zig");
const Spec = envspec.Spec;
const Op = envspec.Op;
const shell = @import("shell.zig");
const runtime = @import("runtime.zig");
const output = @import("output.zig");
const EnvironmentConfig = @import("config.zig").EnvironmentConfig;

const sq = shell.appendSqEscaped;

pub const Shell = enum { sh, csh };

/// The script `zenv activate` prints for `flavour`.
pub fn fileName(flavour: Shell) []const u8 {
    return switch (flavour) {
        .sh => "activate.sh",
        .csh => "activate.csh",
    };
}

/// Maps a `--shell=` value to a script flavour. Null for unsupported shells.
pub fn parseShell(name: []const u8) ?Shell {
    for ([_][]const u8{ "sh", "bash", "zsh" }) |n| if (std.mem.eql(u8, name, n)) return .sh;
    for ([_][]const u8{ "csh", "tcsh" }) |n| if (std.mem.eql(u8, name, n)) return .csh;
    return null;
}

/// Builds the Spec for an environment, writes activate.sh, activate.csh,
/// deactivate.csh and zenv-env.json into `venv_path`. Called at the end of
/// setup, after the setup script ran. Setup runs in the project directory, so
/// cwd anchors a relative activate.script path.
pub fn generate(allocator: Allocator, env_config: *const EnvironmentConfig, env_name: []const u8, venv_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    output.print(allocator, "Creating activation scripts for '{s}'...", .{env_name}) catch {};

    const cwd = try runtime.cwdRealpath(a);
    const scripts_dir = try std.Io.Dir.path.join(a, &[_][]const u8{ venv_path, "scripts" });
    runtime.makePath(scripts_dir) catch |err| {
        output.printError(allocator, "Failed to create scripts directory: {s}", .{@errorName(err)}) catch {};
    };

    var hook: ?[]const u8 = null;
    if (env_config.activate) |act| {
        if (act.script) |src| {
            hook = shell.copyHookScript(a, src, scripts_dir, "activate_hook.sh", cwd) catch |err| blk: {
                output.printError(allocator, "Failed to copy activation script '{s}': {s}", .{ src, @errorName(err) }) catch {};
                break :blk null;
            };
        }
    }

    var spec = try envspec.build(a, env_config, env_name, venv_path, hook);
    spec.modules = try printableModules(allocator, a, spec.modules);

    try writeScript(a, venv_path, fileName(.sh), try renderSh(a, &spec));
    try writeScript(a, venv_path, fileName(.csh), try renderCsh(a, &spec));
    try writeScript(a, venv_path, "deactivate.csh", try renderCshDeactivate(a, &spec));

    // Non-fatal: without it run/add fall back to sourcing activate.sh.
    envspec.write(a, &spec) catch |err| {
        output.print(allocator, "Warning: could not write {s}: {s}", .{ envspec.FILE_NAME, @errorName(err) }) catch {};
    };

    output.print(allocator, "Activation scripts created in {s}", .{venv_path}) catch {};
}

/// Drops module names containing control characters (they cannot be loaded
/// and would corrupt the generated scripts), warning about each.
fn printableModules(allocator: Allocator, a: Allocator, modules: []const []const u8) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (modules) |m| {
        const bad = for (m) |c| {
            if (c < 0x20 or c == 0x7f) break true;
        } else false;
        if (bad) {
            output.printError(allocator, "Module name '{f}' contains control characters; skipping it.", .{std.ascii.hexEscape(m, .lower)}) catch {};
            continue;
        }
        try kept.append(a, m);
    }
    return kept.toOwnedSlice(a);
}

fn writeScript(a: Allocator, venv_path: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.Io.Dir.path.join(a, &[_][]const u8{ venv_path, name });
    var file = try runtime.createFile(path, .{ .permissions = .fromMode(0o755) });
    defer file.close(runtime.io);
    try file.writeStreamingAll(runtime.io, content);
}

// ---------------------------------------------------------------------------
// Save / restore policy for the variables the venv ops touch
// ---------------------------------------------------------------------------

const Restore = enum {
    /// bin/activate convention: saved as `_OLD_VIRTUAL_<NAME>` when set,
    /// restored when saved (PATH, PYTHONHOME).
    venv_old,
    /// Unset on deactivate (VIRTUAL_ENV, VIRTUAL_ENV_PROMPT).
    unset,
    /// zenv's own: previous value or absence saved as `_ZENV_OLD_<NAME>`.
    zenv_old,
};

fn restoreFor(name: []const u8) Restore {
    for ([_][]const u8{ "PATH", "PYTHONHOME" }) |n| if (std.mem.eql(u8, name, n)) return .venv_old;
    for ([_][]const u8{ "VIRTUAL_ENV", "VIRTUAL_ENV_PROMPT" }) |n| if (std.mem.eql(u8, name, n)) return .unset;
    return .zenv_old;
}

/// Distinct variable names touched by `ops`, in first-use order. Errors on a
/// name that is not a shell identifier, since names are emitted unquoted.
fn opNames(a: Allocator, ops: []const Op) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    outer: for (ops) |op| {
        if (!envspec.isIdentifier(op.name)) return error.InvalidVariableName;
        for (names.items) |n| if (std.mem.eql(u8, n, op.name)) continue :outer;
        try names.append(a, op.name);
    }
    return names.toOwnedSlice(a);
}

fn checkOps(ops: []const Op) !void {
    for (ops) |op| if (!envspec.isIdentifier(op.name)) return error.InvalidVariableName;
}

fn indent(w: *Writer, n: usize) !void {
    try w.splatByteAll(' ', n);
}

// ---------------------------------------------------------------------------
// sh (bash / zsh)
// ---------------------------------------------------------------------------

pub fn renderSh(a: Allocator, spec: *const Spec) ![]u8 {
    var buf: Writer.Allocating = .init(a);
    const w = &buf.writer;
    const names = try opNames(a, spec.ops);

    try w.print(
        \\# Activation script for '{s}', generated by zenv from {s}.
        \\# Use from bash or zsh: source $(zenv activate {s})
        \\
        \\deactivate () {{
        \\
    , .{ spec.name, envspec.FILE_NAME, spec.name });
    for (names) |n| switch (restoreFor(n)) {
        .venv_old => try w.print(
            \\    if [ -n "${{_OLD_VIRTUAL_{0s}:-}}" ] ; then
            \\        {0s}="${{_OLD_VIRTUAL_{0s}:-}}"
            \\        export {0s}
            \\        unset _OLD_VIRTUAL_{0s}
            \\    fi
            \\
        , .{n}),
        .unset => try w.print("    unset {s}\n", .{n}),
        .zenv_old => {},
    };
    try w.writeAll(
        \\    if [ -n "${_OLD_VIRTUAL_PS1:-}" ] ; then
        \\        PS1="${_OLD_VIRTUAL_PS1:-}"
        \\        export PS1
        \\        unset _OLD_VIRTUAL_PS1
        \\    fi
        \\    if [ -n "${_ZENV_ACTIVE:-}" ] ; then
        \\
    );
    for (names) |n| if (restoreFor(n) == .zenv_old) try w.print(
        \\        if [ -n "${{_ZENV_OLD_{0s}+x}}" ] ; then
        \\            {0s}="$_ZENV_OLD_{0s}"
        \\            export {0s}
        \\            unset _ZENV_OLD_{0s}
        \\        else
        \\            unset {0s}
        \\        fi
        \\
    , .{n});
    try w.writeAll(
        \\        unset _ZENV_ACTIVE
        \\    fi
        \\    if [ -n "${BASH:-}" -o -n "${ZSH_VERSION:-}" ] ; then
        \\        hash -r 2> /dev/null
        \\    fi
        \\    if [ ! "${1:-}" = "nondestructive" ] ; then
        \\        unset -f deactivate
        \\    fi
        \\}
        \\
        \\# Undo a previous activation (zenv or plain venv) without dropping this function.
        \\deactivate nondestructive
        \\
        \\
    );

    try writeShModules(a, w, spec);

    for (names) |n| switch (restoreFor(n)) {
        .venv_old => try w.print("if [ -n \"${{{0s}:-}}\" ] ; then _OLD_VIRTUAL_{0s}=\"${0s}\" ; fi\n", .{n}),
        .unset => {},
        .zenv_old => try w.print("if [ -n \"${{{0s}+x}}\" ] ; then _ZENV_OLD_{0s}=\"${0s}\" ; else unset _ZENV_OLD_{0s} ; fi\n", .{n}),
    };
    for (spec.ops) |op| try writeShOp(w, op, 0);
    try w.writeAll("_ZENV_ACTIVE=1\n\n");

    try w.writeAll(
        \\if [ -z "${VIRTUAL_ENV_DISABLE_PROMPT:-}" ] ; then
        \\    _OLD_VIRTUAL_PS1="${PS1:-}"
        \\    PS1='(
    );
    try sq(w, spec.name);
    try w.writeAll(
        \\) '"${PS1:-}"
        \\    export PS1
        \\fi
        \\
        \\if [ -n "${BASH:-}" -o -n "${ZSH_VERSION:-}" ] ; then
        \\    hash -r 2> /dev/null
        \\fi
        \\
    );

    if (spec.activate_commands.len > 0) {
        try w.writeAll("\n# activate.commands from zenv.json\n");
        for (spec.activate_commands) |cmd| try w.print("{s}\n", .{cmd});
    }
    if (spec.activate_script) |path| {
        try w.writeAll("\n# activate.script from zenv.json\nif [ -f '");
        try sq(w, path);
        try w.writeAll("' ] ; then\n    . '");
        try sq(w, path);
        try w.writeAll("' || echo \"WARNING: activate hook failed with exit code $?\" >&2\nelse\n    echo 'WARNING: activate hook not found: ");
        try sq(w, path);
        try w.writeAll("' >&2\nfi\n");
    }

    return buf.toOwnedSlice();
}

fn writeShOp(w: *Writer, op: Op, ind: usize) !void {
    try indent(w, ind);
    switch (op.op) {
        .set => {
            try w.print("export {s}='", .{op.name});
            try sq(w, op.value);
            try w.writeAll("'\n");
        },
        .unset => try w.print("unset {s}\n", .{op.name}),
        .prepend => {
            try w.print("{s}='", .{op.name});
            try sq(w, op.value);
            try w.print("'\"${{{0s}:+:${{{0s}}}}}\"\n", .{op.name});
            try indent(w, ind);
            try w.print("export {s}\n", .{op.name});
        },
    }
}

fn writeShLoads(w: *Writer, modules: []const []const u8, ind: usize) !void {
    try indent(w, ind);
    try w.writeAll("module --force purge || echo 'WARNING: Failed to purge modules, continuing anyway' >&2\n");
    for (modules) |m| {
        try indent(w, ind);
        try w.writeAll("module load '");
        try sq(w, m);
        try w.writeAll("' || echo 'WARNING: Failed to load module ");
        try sq(w, m);
        try w.writeAll("' >&2\n");
    }
}

/// The module section. Runs only where `module` exists, like before. Three
/// shapes, chosen at setup:
///   - no modules: purge (historical behaviour);
///   - usable captured cache: replay it when the cache file still exists and
///     the system matches, else purge + load;
///   - otherwise (caching off, or nothing usable captured): purge + load.
fn writeShModules(a: Allocator, w: *Writer, spec: *const Spec) !void {
    try w.writeAll("if command -v module >/dev/null 2>&1; then\n");
    if (spec.modules.len == 0) {
        try w.writeAll("    module --force purge || echo 'WARNING: Failed to purge modules, continuing anyway' >&2\nfi\n\n");
        return;
    }

    if (spec.usableModuleCache()) |cache| {
        try checkOps(cache.ops);
        const cache_file = try std.Io.Dir.path.join(a, &[_][]const u8{ spec.venv, envspec.MODULE_CACHE_FILE });
        try w.writeAll("    if [ -f '");
        try sq(w, cache_file);
        try w.writeAll("' ] && [ \"${SYSTEMNAME:-$(hostname 2>/dev/null)}\" = '");
        try sq(w, cache.system);
        try w.writeAll("' ] ; then\n");
        for (cache.ops) |op| try writeShOp(w, op, 8);
        try w.writeAll("    else\n");
        try writeShLoads(w, spec.modules, 8);
        try w.writeAll("        if [ -f '");
        try sq(w, cache_file);
        try w.writeAll("' ] ; then echo \"INFO: zenv module cache is for another system; ran 'module load'. Re-run 'zenv setup' here to refresh.\" >&2 ; fi\n    fi\n");
    } else {
        try writeShLoads(w, spec.modules, 4);
    }
    try w.writeAll("fi\n\n");
}

// ---------------------------------------------------------------------------
// csh (csh / tcsh)
// ---------------------------------------------------------------------------

pub fn renderCsh(a: Allocator, spec: *const Spec) ![]u8 {
    var buf: Writer.Allocating = .init(a);
    const w = &buf.writer;
    const names = try opNames(a, spec.ops);
    const deactivate_path = try std.Io.Dir.path.join(a, &[_][]const u8{ spec.venv, "deactivate.csh" });

    try w.print(
        \\# Activation script for '{s}', generated by zenv from {s}.
        \\# Use from csh or tcsh: source `zenv activate {s} --shell=csh`
        \\
        \\alias deactivate 'source "
    , .{ spec.name, envspec.FILE_NAME, spec.name });
    try sq(w, deactivate_path);
    try w.writeAll(
        \\" \!*'
        \\# Undo a previous activation without dropping the alias.
        \\deactivate nondestructive
        \\
        \\
    );

    try writeCshModules(a, w, spec);

    for (names) |n| switch (restoreFor(n)) {
        .venv_old => try w.print(
            \\if ( $?{0s} ) then
            \\    set _OLD_VIRTUAL_{0s} = "${0s}"
            \\endif
            \\
        , .{n}),
        .unset => {},
        .zenv_old => try w.print(
            \\if ( $?{0s} ) then
            \\    set _ZENV_OLD_{0s} = "${0s}"
            \\else
            \\    unset _ZENV_OLD_{0s}
            \\endif
            \\
        , .{n}),
    };
    for (spec.ops) |op| try writeCshOp(w, op, 0);
    try w.writeAll("set _ZENV_ACTIVE = 1\n\n");

    try w.writeAll(
        \\if ( ! $?VIRTUAL_ENV_DISABLE_PROMPT ) then
        \\    if ( $?prompt ) then
        \\        set _OLD_VIRTUAL_PROMPT = "$prompt"
        \\        set prompt = '(
    );
    try sq(w, spec.name);
    try w.writeAll(
        \\) '"$prompt"
        \\    endif
        \\endif
        \\
        \\rehash
        \\
    );

    if (spec.hasActivateHooks()) {
        try w.writeAll("\necho 'WARNING: zenv activate hooks are sh code and were skipped; activate from bash or zsh to run them.' > /dev/stderr\n");
    }
    return buf.toOwnedSlice();
}

/// deactivate.csh, sourced by the `deactivate` alias with its arguments.
pub fn renderCshDeactivate(a: Allocator, spec: *const Spec) ![]u8 {
    var buf: Writer.Allocating = .init(a);
    const w = &buf.writer;
    const names = try opNames(a, spec.ops);

    try w.print("# Deactivation for '{s}', generated by zenv. Sourced by the `deactivate` alias.\n\n", .{spec.name});
    for (names) |n| switch (restoreFor(n)) {
        .venv_old => try w.print(
            \\if ( $?_OLD_VIRTUAL_{0s} ) then
            \\    setenv {0s} "$_OLD_VIRTUAL_{0s}"
            \\    unset _OLD_VIRTUAL_{0s}
            \\endif
            \\
        , .{n}),
        .unset => try w.print("unsetenv {s}\n", .{n}),
        .zenv_old => {},
    };
    try w.writeAll(
        \\if ( $?_OLD_VIRTUAL_PROMPT ) then
        \\    set prompt = "$_OLD_VIRTUAL_PROMPT"
        \\    unset _OLD_VIRTUAL_PROMPT
        \\endif
        \\if ( $?_ZENV_ACTIVE ) then
        \\
    );
    for (names) |n| if (restoreFor(n) == .zenv_old) try w.print(
        \\    if ( $?_ZENV_OLD_{0s} ) then
        \\        setenv {0s} "$_ZENV_OLD_{0s}"
        \\        unset _ZENV_OLD_{0s}
        \\    else
        \\        unsetenv {0s}
        \\    endif
        \\
    , .{n});
    try w.writeAll(
        \\    unset _ZENV_ACTIVE
        \\endif
        \\rehash
        \\if ( "$argv" != "nondestructive" ) unalias deactivate
        \\
    );
    return buf.toOwnedSlice();
}

fn writeCshOp(w: *Writer, op: Op, ind: usize) !void {
    if (std.mem.findScalar(u8, op.value, '\n') != null) {
        // A csh quoted string cannot contain a newline.
        try indent(w, ind);
        try w.print("# skipped {s}: multi-line values cannot be set from csh\n", .{op.name});
        return;
    }
    switch (op.op) {
        .set => {
            try indent(w, ind);
            try w.print("setenv {s} '", .{op.name});
            try sq(w, op.value);
            try w.writeAll("'\n");
        },
        .unset => {
            try indent(w, ind);
            try w.print("unsetenv {s}\n", .{op.name});
        },
        .prepend => {
            // Nested blocks: csh expands a whole line before testing `$?NAME`.
            try indent(w, ind);
            try w.print("if ( $?{s} ) then\n", .{op.name});
            try indent(w, ind + 4);
            try w.print("if ( \"${s}\" != \"\" ) then\n", .{op.name});
            try indent(w, ind + 8);
            try w.print("setenv {s} '", .{op.name});
            try sq(w, op.value);
            try w.print("':\"${s}\"\n", .{op.name});
            try indent(w, ind + 4);
            try w.writeAll("else\n");
            try indent(w, ind + 8);
            try w.print("setenv {s} '", .{op.name});
            try sq(w, op.value);
            try w.writeAll("'\n");
            try indent(w, ind + 4);
            try w.writeAll("endif\n");
            try indent(w, ind);
            try w.writeAll("else\n");
            try indent(w, ind + 4);
            try w.print("setenv {s} '", .{op.name});
            try sq(w, op.value);
            try w.writeAll("'\n");
            try indent(w, ind);
            try w.writeAll("endif\n");
        },
    }
}

fn writeCshLoads(w: *Writer, modules: []const []const u8, ind: usize) !void {
    try indent(w, ind);
    try w.writeAll("module --force purge || echo 'WARNING: Failed to purge modules, continuing anyway' > /dev/stderr\n");
    for (modules) |m| {
        try indent(w, ind);
        try w.writeAll("module load '");
        try sq(w, m);
        try w.writeAll("' || echo 'WARNING: Failed to load module ");
        try sq(w, m);
        try w.writeAll("' > /dev/stderr\n");
    }
}

/// csh module section: same gate and shapes as sh (`module` is an alias here).
fn writeCshModules(a: Allocator, w: *Writer, spec: *const Spec) !void {
    try w.writeAll("if ( \"`alias module`\" != \"\" ) then\n");
    if (spec.modules.len == 0) {
        try w.writeAll("    module --force purge || echo 'WARNING: Failed to purge modules, continuing anyway' > /dev/stderr\nendif\n\n");
        return;
    }
    if (spec.usableModuleCache()) |cache| {
        try checkOps(cache.ops);
        const cache_file = try std.Io.Dir.path.join(a, &[_][]const u8{ spec.venv, envspec.MODULE_CACHE_FILE });
        try w.writeAll(
            \\    set _zenv_sys = "`hostname`"
            \\    if ( $?SYSTEMNAME ) then
            \\        if ( "$SYSTEMNAME" != "" ) set _zenv_sys = "$SYSTEMNAME"
            \\    endif
            \\    set _zenv_hit = 0
            \\    if ( -f '
        );
        try sq(w, cache_file);
        try w.writeAll("' ) then\n        if ( \"$_zenv_sys\" == '");
        try sq(w, cache.system);
        try w.writeAll("' ) set _zenv_hit = 1\n    endif\n    if ( $_zenv_hit ) then\n");
        for (cache.ops) |op| try writeCshOp(w, op, 8);
        try w.writeAll("    else\n");
        try writeCshLoads(w, spec.modules, 8);
        try w.writeAll("    endif\n    unset _zenv_sys _zenv_hit\n");
    } else {
        try writeCshLoads(w, spec.modules, 4);
    }
    try w.writeAll("endif\n\n");
}

// ============================ Tests ============================
const testing = std.testing;

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    testing.expect(std.mem.find(u8, haystack, needle) != null) catch |err| {
        std.debug.print("expected to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return err;
    };
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    testing.expect(std.mem.find(u8, haystack, needle) == null) catch |err| {
        std.debug.print("expected NOT to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return err;
    };
}

fn testSpec(a: Allocator) !Spec {
    return .{
        .name = "demo",
        .venv = "/p/.zenv/demo",
        .ops = try envspec.venvOps(a, "/p/.zenv/demo", "demo"),
    };
}

test "parseShell maps shell names to script flavours" {
    try testing.expectEqual(Shell.sh, parseShell("zsh").?);
    try testing.expectEqual(Shell.sh, parseShell("bash").?);
    try testing.expectEqual(Shell.csh, parseShell("tcsh").?);
    try testing.expect(parseShell("fish") == null);
}

test "renderSh: no bin/activate, venv-compatible deactivate, ops, prompt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try testSpec(a);
    const out = try renderSh(a, &spec);

    try expectNotContains(out, "bin/activate");
    try expectContains(out, "deactivate nondestructive");
    // PATH: venv convention save + restore, then prepend.
    try expectContains(out, "if [ -n \"${PATH:-}\" ] ; then _OLD_VIRTUAL_PATH=\"$PATH\" ; fi");
    try expectContains(out, "PATH=\"${_OLD_VIRTUAL_PATH:-}\"");
    try expectContains(out, "PATH='/p/.zenv/demo/bin'\"${PATH:+:${PATH}}\"\nexport PATH");
    // zenv-owned vars are restored only under _ZENV_ACTIVE.
    try expectContains(out, "_ZENV_OLD_PYTHONDONTWRITEBYTECODE=\"$PYTHONDONTWRITEBYTECODE\"");
    try expectContains(out, "unset ZENV_ENV_DIR");
    try expectContains(out, "unset VIRTUAL_ENV\n");
    try expectContains(out, "export VIRTUAL_ENV='/p/.zenv/demo'");
    try expectContains(out, "unset PYTHONHOME");
    try expectContains(out, "PS1='(demo) '\"${PS1:-}\"");
    // No modules: the historical purge only.
    try expectContains(out, "module --force purge");
    try expectNotContains(out, "module load");
}

test "renderSh: deactivate runs before modules, saves run after them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try renderSh(a, &try testSpec(a));
    const deact = std.mem.find(u8, out, "\ndeactivate nondestructive").?;
    const mods = std.mem.find(u8, out, "if command -v module").?;
    const save = std.mem.find(u8, out, "_OLD_VIRTUAL_PATH=\"$PATH\"").?;
    try testing.expect(deact < mods and mods < save);
}

test "renderSh: usable module cache is inlined behind a system check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = try testSpec(a);
    const mod_ops = [_]Op{
        .{ .op = .prepend, .name = "LD_LIBRARY_PATH", .value = "/m/lib" },
        .{ .op = .set, .name = "LOADEDMODULES", .value = "gcc/13" },
    };
    spec.modules = &.{ "gcc/13", "it's" };
    spec.module_cache_enabled = true;
    spec.module_cache = .{ .version = envspec.MODULE_CACHE_VERSION, .system = "jureca", .untrusted = false, .ops = &mod_ops };
    const out = try renderSh(a, &spec);

    try expectContains(out, "[ -f '/p/.zenv/demo/.zenv_module_cache.json' ] && [ \"${SYSTEMNAME:-$(hostname 2>/dev/null)}\" = 'jureca' ]");
    try expectContains(out, "        LD_LIBRARY_PATH='/m/lib'\"${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}\"");
    try expectContains(out, "        export LOADEDMODULES='gcc/13'");
    try expectContains(out, "        module load 'it'\\''s' || echo 'WARNING: Failed to load module it'\\''s' >&2");
    try expectNotContains(out, "sed -n"); // no stamp parsing at activation
    try expectNotContains(out, ".zenv_module_cache.sh");

    // csh renders the same cache; a multi-line value is skipped, not mangled.
    const multi = [_]Op{.{ .op = .set, .name = "BANNER", .value = "a\nb" }};
    spec.module_cache = .{ .version = envspec.MODULE_CACHE_VERSION, .system = "jureca", .untrusted = false, .ops = &multi };
    const csh = try renderCsh(a, &spec);
    try expectContains(csh, "# skipped BANNER: multi-line values cannot be set from csh");
    try expectContains(csh, ".zenv_module_cache.json");
    const sh = try renderSh(a, &spec);
    try expectContains(sh, "export BANNER='a\nb'"); // sh quotes span lines fine
}

test "renderSh: no usable cache data means a plain purge + load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = try testSpec(a);
    spec.modules = &.{"gcc"};
    spec.module_cache_enabled = true;
    const out = try renderSh(a, &spec);
    try expectNotContains(out, "zenv_module_cache");
    try expectNotContains(out, "sed -n");
    try expectContains(out, "    module --force purge");
    try expectContains(out, "    module load 'gcc'");
}

test "renderSh: hooks are emitted after activation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = try testSpec(a);
    spec.activate_commands = &.{"export FOO=bar"};
    spec.activate_script = "/p/.zenv/demo/scripts/activate_hook.sh";
    const out = try renderSh(a, &spec);
    try expectContains(out, "export FOO=bar\n");
    try expectContains(out, ". '/p/.zenv/demo/scripts/activate_hook.sh'");
    try testing.expect(std.mem.find(u8, out, "_ZENV_ACTIVE=1").? < std.mem.find(u8, out, "export FOO=bar").?);
}

test "render rejects variable names that are not identifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = try testSpec(a);
    spec.ops = &.{.{ .op = .set, .name = "X; rm -rf ~", .value = "" }};
    try testing.expectError(error.InvalidVariableName, renderSh(a, &spec));
    try testing.expectError(error.InvalidVariableName, renderCsh(a, &spec));

    spec = try testSpec(a);
    spec.modules = &.{"gcc"};
    spec.module_cache_enabled = true;
    const bad = [_]Op{.{ .op = .set, .name = "BAD NAME", .value = "" }};
    spec.module_cache = .{ .version = envspec.MODULE_CACHE_VERSION, .system = "s", .untrusted = false, .ops = &bad };
    try testing.expectError(error.InvalidVariableName, renderSh(a, &spec));
}

test "renderCsh / renderCshDeactivate: setenv ops, alias, hooks skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = try testSpec(a);
    spec.activate_commands = &.{"export FOO=bar"};
    const out = try renderCsh(a, &spec);
    try expectContains(out, "alias deactivate 'source \"/p/.zenv/demo/deactivate.csh\" \\!*'");
    try expectContains(out, "setenv VIRTUAL_ENV '/p/.zenv/demo'");
    try expectContains(out, "        setenv PATH '/p/.zenv/demo/bin':\"$PATH\"");
    try expectContains(out, "unsetenv PYTHONHOME");
    try expectContains(out, "set prompt = '(demo) '\"$prompt\"");
    try expectContains(out, "were skipped");
    try expectNotContains(out, "export FOO=bar");

    const de = try renderCshDeactivate(a, &spec);
    try expectContains(de, "setenv PATH \"$_OLD_VIRTUAL_PATH\"");
    try expectContains(de, "unsetenv VIRTUAL_ENV\n");
    try expectContains(de, "unsetenv ZENV_ENV_DIR");
    try expectContains(de, "if ( \"$argv\" != \"nondestructive\" ) unalias deactivate");
}
