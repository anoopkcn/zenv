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

pub const Shell = enum { sh, csh, fish };

/// The script `zenv activate` prints for `flavour`.
pub fn fileName(flavour: Shell) []const u8 {
    return switch (flavour) {
        .sh => "activate.sh",
        .csh => "activate.csh",
        .fish => "activate.fish",
    };
}

/// Maps a `--shell=` value to a script flavour. Null for unsupported shells.
pub fn parseShell(name: []const u8) ?Shell {
    for ([_][]const u8{ "sh", "bash", "zsh" }) |n| if (std.mem.eql(u8, name, n)) return .sh;
    for ([_][]const u8{ "csh", "tcsh" }) |n| if (std.mem.eql(u8, name, n)) return .csh;
    if (std.mem.eql(u8, name, "fish")) return .fish;
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

    var spec = try envspec.build(a, env_config, env_name, venv_path, cwd, hook);
    spec.modules = try printableModules(allocator, a, spec.modules);

    try writeAll(a, &spec);
    output.print(allocator, "Activation scripts created in {s}", .{venv_path}) catch {};
}

/// Writes everything activation is made of for `spec`: zenv-env.json and the
/// scripts rendered from it. Used by setup and by rename (after relocating the
/// stored Spec), so the scripts are always a pure function of the data.
pub fn writeAll(a: Allocator, spec: *const Spec) !void {
    try writeScript(a, spec.venv, fileName(.sh), try renderSh(a, spec));
    try writeScript(a, spec.venv, fileName(.csh), try renderCsh(a, spec));
    try writeScript(a, spec.venv, "deactivate.csh", try renderCshDeactivate(a, spec));
    try writeScript(a, spec.venv, fileName(.fish), try renderFish(a, spec));
    try envspec.write(a, spec);
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
// Save / restore policy
// ---------------------------------------------------------------------------

const csq = shell.appendCshSqEscaped;

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

/// Every variable activation may change: the usable module cache's and the
/// venv's. They are saved before the module section and restored by
/// `deactivate`, so deactivating undoes the cache replay and re-activating
/// does not stack the same path entries again. (Variables changed only by a
/// live `module load` fallback are Lmod's to undo.)
fn touchedNames(a: Allocator, spec: *const Spec) ![]const []const u8 {
    var all: std.ArrayList(Op) = .empty;
    if (spec.usableModuleCache()) |cache| try all.appendSlice(a, cache.ops);
    try all.appendSlice(a, spec.ops);
    return opNames(a, all.items);
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
    const names = try touchedNames(a, spec);

    try w.print(
        \\# Activation script for '{s}', generated by zenv from {s}.
        \\# Use from bash or zsh: source $(zenv activate {s})
        \\
        \\# Leave a previous environment (zenv or plain venv) with its own
        \\# deactivate: only it knows what that environment set.
        \\if typeset -f deactivate > /dev/null 2>&1 ; then
        \\    deactivate
        \\fi
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

    for (names) |n| switch (restoreFor(n)) {
        .venv_old => try w.print("if [ -n \"${{{0s}:-}}\" ] ; then _OLD_VIRTUAL_{0s}=\"${0s}\" ; fi\n", .{n}),
        .unset => {},
        .zenv_old => try w.print("if [ -n \"${{{0s}+x}}\" ] ; then _ZENV_OLD_{0s}=\"${0s}\" ; else unset _ZENV_OLD_{0s} ; fi\n", .{n}),
    };
    try w.writeAll("_ZENV_ACTIVE=1\n\n");

    try writeShModules(a, w, spec);

    for (spec.ops) |op| try writeShOp(w, op, 0);

    try w.writeAll(
        \\
        \\if [ -z "${VIRTUAL_ENV_DISABLE_PROMPT:-}" ] && [ -n "${PS1:-}" ] ; then
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
        .append => {
            try w.print("{0s}=\"${{{0s}:+${{{0s}}}:}}\"'", .{op.name});
            try sq(w, op.value);
            try w.writeAll("'\n");
            try indent(w, ind);
            try w.print("export {s}\n", .{op.name});
        },
    }
}

/// `module --force purge` + `module load` for each module. Where `module` is
/// not defined but Lmod is initialised ($LMOD_CMD), defines it the way Lmod's
/// bash init does; with no module system at all, warns instead.
fn writeShLoads(w: *Writer, modules: []const []const u8, ind: usize) !void {
    const lines = [_][]const u8{
        "if ! command -v module >/dev/null 2>&1 && [ -n \"${LMOD_CMD:-}\" ] ; then\n",
        "    module () { eval \"$(\"$LMOD_CMD\" bash \"$@\")\" ; }\n",
        "fi\n",
        "if command -v module >/dev/null 2>&1 ; then\n",
        "    module --force purge || echo 'WARNING: Failed to purge modules, continuing anyway' >&2\n",
    };
    for (lines) |l| {
        try indent(w, ind);
        try w.writeAll(l);
    }
    for (modules) |m| {
        try indent(w, ind + 4);
        try w.writeAll("module load '");
        try sq(w, m);
        try w.writeAll("' || echo 'WARNING: Failed to load module ");
        try sq(w, m);
        try w.writeAll("' >&2\n");
    }
    try indent(w, ind);
    try w.writeAll("else\n");
    try indent(w, ind + 4);
    try w.writeAll("echo \"WARNING: zenv: no 'module' command available; this environment's modules are not loaded.\" >&2\n");
    try indent(w, ind);
    try w.writeAll("fi\n");
}

/// The module section, chosen at setup:
///   - no modules: purge where a module system exists (historical behaviour);
///   - usable captured cache: replay it when the cache file still exists and
///     the system matches (no `module` command needed), else load;
///   - otherwise (caching off, or nothing usable captured): load.
fn writeShModules(a: Allocator, w: *Writer, spec: *const Spec) !void {
    if (spec.modules.len == 0) {
        try w.writeAll("if command -v module >/dev/null 2>&1 ; then\n    module --force purge || echo 'WARNING: Failed to purge modules, continuing anyway' >&2\nfi\n\n");
        return;
    }
    if (spec.usableModuleCache()) |cache| {
        const cache_file = try std.Io.Dir.path.join(a, &[_][]const u8{ spec.venv, envspec.MODULE_CACHE_FILE });
        try w.writeAll("if [ -f '");
        try sq(w, cache_file);
        try w.writeAll("' ] && [ \"${SYSTEMNAME:-$(uname -n)}\" = '");
        try sq(w, cache.system);
        try w.writeAll("' ] ; then\n");
        for (cache.ops) |op| try writeShOp(w, op, 4);
        try w.writeAll("else\n    echo \"INFO: zenv module cache is missing or for another system; loading modules. Re-run 'zenv setup' here to refresh.\" >&2\n");
        try writeShLoads(w, spec.modules, 4);
        try w.writeAll("fi\n\n");
    } else {
        try writeShLoads(w, spec.modules, 0);
        try w.writeAll("\n");
    }
}

// ---------------------------------------------------------------------------
// csh (csh / tcsh)
// ---------------------------------------------------------------------------

pub fn renderCsh(a: Allocator, spec: *const Spec) ![]u8 {
    var buf: Writer.Allocating = .init(a);
    const w = &buf.writer;
    const names = try touchedNames(a, spec);
    const deactivate_path = try std.Io.Dir.path.join(a, &[_][]const u8{ spec.venv, "deactivate.csh" });

    try w.print(
        \\# Activation script for '{s}', generated by zenv from {s}.
        \\# Use from csh or tcsh: source `zenv activate {s} --shell=csh`
        \\
        \\# Leave a previous environment with its own deactivate: only it knows
        \\# what that environment set.
        \\if ( "`alias deactivate`" != "" ) then
        \\    deactivate
        \\endif
        \\
        \\alias deactivate 'source "
    , .{ spec.name, envspec.FILE_NAME, spec.name });
    try csq(w, deactivate_path);
    try w.writeAll(
        \\" \!*'
        \\# Undo a previous activation without dropping the alias.
        \\deactivate nondestructive
        \\
        \\
    );

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
    try w.writeAll("set _ZENV_ACTIVE = 1\n\n");

    try writeCshModules(a, w, spec);

    for (spec.ops) |op| try writeCshOp(w, op, 0);

    try w.writeAll(
        \\
        \\if ( ! $?VIRTUAL_ENV_DISABLE_PROMPT ) then
        \\    if ( $?prompt ) then
        \\        set _OLD_VIRTUAL_PROMPT = "$prompt"
        \\        set prompt = '(
    );
    try csq(w, spec.name);
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
    const names = try touchedNames(a, spec);

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
            try csq(w, op.value);
            try w.writeAll("'\n");
        },
        .unset => {
            try indent(w, ind);
            try w.print("unsetenv {s}\n", .{op.name});
        },
        .prepend, .append => {
            // Nested blocks: csh expands a whole line before testing `$?NAME`.
            try indent(w, ind);
            try w.print("if ( $?{s} ) then\n", .{op.name});
            try indent(w, ind + 4);
            try w.print("if ( \"${s}\" != \"\" ) then\n", .{op.name});
            try indent(w, ind + 8);
            if (op.op == .prepend) {
                try w.print("setenv {s} '", .{op.name});
                try csq(w, op.value);
                try w.print("':\"${s}\"\n", .{op.name});
            } else {
                try w.print("setenv {0s} \"${0s}\":'", .{op.name});
                try csq(w, op.value);
                try w.writeAll("'\n");
            }
            try indent(w, ind + 4);
            try w.writeAll("else\n");
            try writeCshSet(w, op, ind + 8);
            try indent(w, ind + 4);
            try w.writeAll("endif\n");
            try indent(w, ind);
            try w.writeAll("else\n");
            try writeCshSet(w, op, ind + 4);
            try indent(w, ind);
            try w.writeAll("endif\n");
        },
    }
}

fn writeCshSet(w: *Writer, op: Op, ind: usize) !void {
    try indent(w, ind);
    try w.print("setenv {s} '", .{op.name});
    try csq(w, op.value);
    try w.writeAll("'\n");
}

/// csh counterpart of writeShLoads (`module` is an alias here).
fn writeCshLoads(w: *Writer, modules: []const []const u8, ind: usize) !void {
    const lines = [_][]const u8{
        "if ( \"`alias module`\" == \"\" ) then\n",
        "    if ( $?LMOD_CMD ) alias module 'eval `$LMOD_CMD tcsh \\!*`'\n",
        "endif\n",
        "if ( \"`alias module`\" != \"\" ) then\n",
        "    module --force purge || echo 'WARNING: Failed to purge modules, continuing anyway' > /dev/stderr\n",
    };
    for (lines) |l| {
        try indent(w, ind);
        try w.writeAll(l);
    }
    for (modules) |m| {
        try indent(w, ind + 4);
        try w.writeAll("module load '");
        try csq(w, m);
        try w.writeAll("' || echo 'WARNING: Failed to load module ");
        try csq(w, m);
        try w.writeAll("' > /dev/stderr\n");
    }
    try indent(w, ind);
    try w.writeAll("else\n");
    try indent(w, ind + 4);
    try w.writeAll("echo \"WARNING: zenv: no 'module' command available; this environment's modules are not loaded.\" > /dev/stderr\n");
    try indent(w, ind);
    try w.writeAll("endif\n");
}

/// csh module section: same shapes as sh.
fn writeCshModules(a: Allocator, w: *Writer, spec: *const Spec) !void {
    if (spec.modules.len == 0) {
        try w.writeAll("if ( \"`alias module`\" != \"\" ) then\n    module --force purge || echo 'WARNING: Failed to purge modules, continuing anyway' > /dev/stderr\nendif\n\n");
        return;
    }
    if (spec.usableModuleCache()) |cache| {
        const cache_file = try std.Io.Dir.path.join(a, &[_][]const u8{ spec.venv, envspec.MODULE_CACHE_FILE });
        try w.writeAll(
            \\set _zenv_sys = "`uname -n`"
            \\if ( $?SYSTEMNAME ) then
            \\    if ( "$SYSTEMNAME" != "" ) set _zenv_sys = "$SYSTEMNAME"
            \\endif
            \\set _zenv_hit = 0
            \\if ( -f '
        );
        try csq(w, cache_file);
        try w.writeAll("' ) then\n    if ( \"$_zenv_sys\" == '");
        try csq(w, cache.system);
        try w.writeAll("' ) set _zenv_hit = 1\nendif\nif ( $_zenv_hit ) then\n");
        for (cache.ops) |op| try writeCshOp(w, op, 4);
        try w.writeAll("else\n    echo \"INFO: zenv module cache is missing or for another system; loading modules. Re-run 'zenv setup' here to refresh.\" > /dev/stderr\n");
        try writeCshLoads(w, spec.modules, 4);
        try w.writeAll("endif\nunset _zenv_sys _zenv_hit\n\n");
    } else {
        try writeCshLoads(w, spec.modules, 0);
        try w.writeAll("\n");
    }
}

// ---------------------------------------------------------------------------
// fish
// ---------------------------------------------------------------------------

const fsq = shell.appendFishSqEscaped;

pub fn renderFish(a: Allocator, spec: *const Spec) ![]u8 {
    var buf: Writer.Allocating = .init(a);
    const w = &buf.writer;
    const names = try touchedNames(a, spec);

    try w.print(
        \\# Activation script for '{s}', generated by zenv from {s}.
        \\# Use from fish: source (zenv activate {s} --shell=fish)
        \\
        \\# Leave a previous environment (zenv or plain venv) with its own
        \\# deactivate: only it knows what that environment set.
        \\if functions -q deactivate
        \\    deactivate
        \\end
        \\
        \\function deactivate -d "Leave the zenv environment"
        \\
    , .{ spec.name, envspec.FILE_NAME, spec.name });
    for (names) |n| switch (restoreFor(n)) {
        .venv_old => try w.print(
            \\    if set -q _OLD_VIRTUAL_{0s}
            \\        set -gx {0s} $_OLD_VIRTUAL_{0s}
            \\        set -e _OLD_VIRTUAL_{0s}
            \\    end
            \\
        , .{n}),
        .unset => try w.print("    set -e {s}\n", .{n}),
        .zenv_old => {},
    };
    try w.writeAll("    if set -q _ZENV_ACTIVE\n");
    for (names) |n| if (restoreFor(n) == .zenv_old) try w.print(
        \\        if set -q _ZENV_OLD_{0s}
        \\            set -gx {0s} $_ZENV_OLD_{0s}
        \\            set -e _ZENV_OLD_{0s}
        \\        else
        \\            set -e {0s}
        \\        end
        \\
    , .{n});
    try w.writeAll(
        \\        set -e _ZENV_ACTIVE
        \\    end
        \\    if functions -q _old_fish_prompt
        \\        functions -e fish_prompt
        \\        functions -c _old_fish_prompt fish_prompt
        \\        functions -e _old_fish_prompt
        \\    end
        \\    if test "$argv[1]" != nondestructive
        \\        functions -e deactivate
        \\    end
        \\end
        \\
        \\# Undo a previous activation (zenv or plain venv) without dropping this function.
        \\deactivate nondestructive
        \\
        \\
    );

    for (names) |n| switch (restoreFor(n)) {
        .venv_old => try w.print("if set -q {0s}\n    set -g _OLD_VIRTUAL_{0s} ${0s}\nend\n", .{n}),
        .unset => {},
        .zenv_old => try w.print("if set -q {0s}\n    set -g _ZENV_OLD_{0s} ${0s}\nelse\n    set -e _ZENV_OLD_{0s}\nend\n", .{n}),
    };
    try w.writeAll("set -g _ZENV_ACTIVE 1\n\n");

    try writeFishModules(a, w, spec);

    for (spec.ops) |op| try writeFishOp(w, op, 0);

    try w.writeAll(
        \\
        \\if test -z "$VIRTUAL_ENV_DISABLE_PROMPT"; and functions -q fish_prompt; and not functions -q _old_fish_prompt
        \\    functions -c fish_prompt _old_fish_prompt
        \\    function fish_prompt
        \\        set -l old_status $status
        \\        printf '%s' '(
    );
    try fsq(w, spec.name);
    try w.writeAll(
        \\) '
        \\        echo "exit $old_status" | source
        \\        _old_fish_prompt
        \\    end
        \\end
        \\
    );

    if (spec.hasActivateHooks()) {
        try w.writeAll("\necho 'WARNING: zenv activate hooks are sh code and were skipped; activate from bash or zsh to run them.' >&2\n");
    }
    return buf.toOwnedSlice();
}

/// fish keeps variables whose name ends in PATH as lists that it exports
/// joined by ':'; list operations then prepend/append without a stray ':'
/// when the old value is empty. Other variables are plain strings.
fn writeFishOp(w: *Writer, op: Op, ind: usize) !void {
    try indent(w, ind);
    const path_like = std.mem.endsWith(u8, op.name, "PATH");
    switch (op.op) {
        .set => {
            try w.print("set -gx {s} '", .{op.name});
            try fsq(w, op.value);
            try w.writeAll("'\n");
        },
        .unset => try w.print("set -e {s}\n", .{op.name}),
        .prepend, .append => if (path_like) {
            try w.print("set -gx {s} ", .{op.name});
            if (op.op == .append) try w.print("${s} ", .{op.name});
            try w.writeAll("'");
            try fsq(w, op.value);
            try w.writeAll("'");
            if (op.op == .prepend) try w.print(" ${s}", .{op.name});
            try w.writeAll("\n");
        } else {
            try w.print("if set -q {0s}; and test -n \"${0s}\"\n", .{op.name});
            try indent(w, ind + 4);
            if (op.op == .prepend) {
                try w.print("set -gx {s} '", .{op.name});
                try fsq(w, op.value);
                try w.print(":'\"${s}\"\n", .{op.name});
            } else {
                try w.print("set -gx {0s} \"${0s}\"':", .{op.name});
                try fsq(w, op.value);
                try w.writeAll("'\n");
            }
            try indent(w, ind);
            try w.writeAll("else\n");
            try indent(w, ind + 4);
            try w.print("set -gx {s} '", .{op.name});
            try fsq(w, op.value);
            try w.writeAll("'\n");
            try indent(w, ind);
            try w.writeAll("end\n");
        },
    }
}

/// fish counterpart of writeShLoads; Lmod's fish init defines `module` as
/// `$LMOD_CMD fish ... | source`.
fn writeFishLoads(w: *Writer, modules: []const []const u8, ind: usize) !void {
    const lines = [_][]const u8{
        "if not functions -q module; and not type -q module; and set -q LMOD_CMD\n",
        "    function module; $LMOD_CMD fish $argv | source; end\n",
        "end\n",
        "if functions -q module; or type -q module\n",
        "    module --force purge; or echo 'WARNING: Failed to purge modules, continuing anyway' >&2\n",
    };
    for (lines) |l| {
        try indent(w, ind);
        try w.writeAll(l);
    }
    for (modules) |m| {
        try indent(w, ind + 4);
        try w.writeAll("module load '");
        try fsq(w, m);
        try w.writeAll("'; or echo 'WARNING: Failed to load module ");
        try fsq(w, m);
        try w.writeAll("' >&2\n");
    }
    try indent(w, ind);
    try w.writeAll("else\n");
    try indent(w, ind + 4);
    try w.writeAll("echo \"WARNING: zenv: no 'module' command available; this environment's modules are not loaded.\" >&2\n");
    try indent(w, ind);
    try w.writeAll("end\n");
}

/// fish module section: same shapes as sh.
fn writeFishModules(a: Allocator, w: *Writer, spec: *const Spec) !void {
    if (spec.modules.len == 0) {
        try w.writeAll("if functions -q module; or type -q module\n    module --force purge; or echo 'WARNING: Failed to purge modules, continuing anyway' >&2\nend\n\n");
        return;
    }
    if (spec.usableModuleCache()) |cache| {
        const cache_file = try std.Io.Dir.path.join(a, &[_][]const u8{ spec.venv, envspec.MODULE_CACHE_FILE });
        try w.writeAll(
            \\set -l _zenv_sys (uname -n)
            \\if set -q SYSTEMNAME; and test -n "$SYSTEMNAME"
            \\    set _zenv_sys $SYSTEMNAME
            \\end
            \\if test -f '
        );
        try fsq(w, cache_file);
        try w.writeAll("'; and test \"$_zenv_sys\" = '");
        try fsq(w, cache.system);
        try w.writeAll("'\n");
        for (cache.ops) |op| try writeFishOp(w, op, 4);
        try w.writeAll("else\n    echo \"INFO: zenv module cache is missing or for another system; loading modules. Re-run 'zenv setup' here to refresh.\" >&2\n");
        try writeFishLoads(w, spec.modules, 4);
        try w.writeAll("end\nset -e _zenv_sys\n\n");
    } else {
        try writeFishLoads(w, spec.modules, 0);
        try w.writeAll("\n");
    }
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
    try testing.expectEqual(Shell.fish, parseShell("fish").?);
    try testing.expect(parseShell("nu") == null);
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

test "renderSh: deactivate, then saves, then modules, then venv ops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try renderSh(a, &try testSpec(a));
    const prev = std.mem.find(u8, out, "if typeset -f deactivate > /dev/null 2>&1 ; then\n    deactivate\nfi").?;
    const define = std.mem.find(u8, out, "\ndeactivate () {").?;
    const deact = std.mem.find(u8, out, "\ndeactivate nondestructive").?;
    const save = std.mem.find(u8, out, "_OLD_VIRTUAL_PATH=\"$PATH\"").?;
    // The previous environment's own deactivate runs before ours replaces it.
    try testing.expect(prev < define and define < deact);
    const mods = std.mem.find(u8, out, "if command -v module").?;
    const venv = std.mem.find(u8, out, "export VIRTUAL_ENV=").?;
    // Saving before the module section makes deactivate restore the PATH the
    // user had, not the one with module entries added.
    try testing.expect(deact < save and save < mods and mods < venv);
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

    // The replay is not gated on a `module` command; only the load fallback is.
    try expectContains(out, "\nif [ -f '/p/.zenv/demo/.zenv_module_cache.json' ] && [ \"${SYSTEMNAME:-$(uname -n)}\" = 'jureca' ] ; then\n");
    try expectContains(out, "\n    LD_LIBRARY_PATH='/m/lib'\"${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}\"");
    try expectContains(out, "\n    export LOADEDMODULES='gcc/13'");
    try expectContains(out, "module () { eval \"$(\"$LMOD_CMD\" bash \"$@\")\" ; }");
    // Cache variables are saved, so deactivate undoes the replay.
    try expectContains(out, "_ZENV_OLD_LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\"");
    try expectContains(out, "_ZENV_OLD_LOADEDMODULES=\"$LOADEDMODULES\"");
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
    // The previous environment's own deactivate runs before the alias is replaced.
    const prev = std.mem.find(u8, out, "if ( \"`alias deactivate`\" != \"\" ) then\n    deactivate\nendif").?;
    try testing.expect(prev < std.mem.find(u8, out, "alias deactivate 'source").?);
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

test "renderFish: list ops for PATH-like vars, string ops otherwise, deactivate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = try testSpec(a);
    const mod_ops = [_]Op{
        .{ .op = .prepend, .name = "LD_LIBRARY_PATH", .value = "/m/lib" },
        .{ .op = .append, .name = "MANPATH", .value = "/m/man" },
        .{ .op = .prepend, .name = "PYTHONSTARTUP_DIRS", .value = "/m/x" },
        .{ .op = .set, .name = "BANG", .value = "it's a \\ and ! and\nnewline" },
    };
    spec.modules = &.{"gcc"};
    spec.module_cache_enabled = true;
    spec.module_cache = .{ .version = envspec.MODULE_CACHE_VERSION, .system = "jureca", .untrusted = false, .ops = &mod_ops };
    const out = try renderFish(a, &spec);

    try expectContains(out, "set -gx PATH '/p/.zenv/demo/bin' $PATH\n");
    try expectContains(out, "    set -gx LD_LIBRARY_PATH '/m/lib' $LD_LIBRARY_PATH\n");
    try expectContains(out, "    set -gx MANPATH $MANPATH '/m/man'\n");
    try expectContains(out, "set -gx PYTHONSTARTUP_DIRS '/m/x:'\"$PYTHONSTARTUP_DIRS\"");
    try expectContains(out, "set -gx BANG 'it\\'s a \\\\ and ! and\nnewline'");
    try expectContains(out, "set -g _OLD_VIRTUAL_PATH $PATH");
    try expectContains(out, "set -g _ZENV_OLD_LD_LIBRARY_PATH $LD_LIBRARY_PATH");
    try expectContains(out, "if test -f '/p/.zenv/demo/.zenv_module_cache.json'; and test \"$_zenv_sys\" = 'jureca'\n");
    try expectContains(out, "function module; $LMOD_CMD fish $argv | source; end");
    try expectContains(out, "deactivate nondestructive\n");
    const prev = std.mem.find(u8, out, "if functions -q deactivate\n    deactivate\nend").?;
    try testing.expect(prev < std.mem.find(u8, out, "function deactivate -d").?);
    try expectContains(out, "printf '%s' '(demo) '");
}
