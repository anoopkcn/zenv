//! The help text: one topic per command. `zenv help` prints all of them with
//! the shared notes; `zenv help <command>` and `zenv <command> --help` print one.

const std = @import("std");
const Io = std.Io;

const Command = @import("commands.zig").Command;
const output = @import("output.zig");

const Topic = struct {
    /// The command, with its other spellings.
    commands: []const Command,
    /// What follows "Usage: zenv ".
    synopsis: []const u8,
    /// The command's entry in the overview.
    entry: []const u8,
    /// Its "Options for ..." section in the overview, if it has one.
    options: []const u8 = "",
};

const header =
    \\Usage: zenv <command> [name|id] [options]
    \\
    \\Manages project environments based on zenv.json configuration: a Python venv
    \\and its packages, HPC modules, environment variables and settings.
    \\
    \\Commands:
;

/// In the order the overview lists them.
const topics = [_]Topic{
    .{
        .commands = &.{.init},
        .synopsis = "init [name] [desc] [--no-python]",
        .entry =
        \\  init [name] [desc]         Creates 'zenv.json' with environment 'name', or adds it to an
        \\                             existing one. 'name' defaults to the directory's name.
        \\                             'desc' defaults to [project].description from pyproject.toml.
        \\                             --no-python: an environment without Python, for modules,
        \\                             environment variables and settings only.
        \\                             Use to start defining your environments[z].
        ,
    },
    .{
        .commands = &.{.setup},
        .synopsis = "setup <name> [options]",
        .entry =
        \\  setup <name>               Creates and configures the environment '<name>' as per
        \\                             'zenv.json' in '<base_dir>/<name>': modules, the Python venv and
        \\                             its packages (none with "python": false), hooks and activation.
        \\                             This is the primary command to build an environment.
        ,
        .options =
        \\Options for 'zenv setup <name>':
        \\  --init                     Creates and populates 'zenv.json' file before 'zenv setup'.
        \\                             Convenient for creating and setting up in one step.
        \\  --no-python                With --init (or 'zenv init'): write the env as "python": false.
        \\
        \\  --dev                      Installs the current directory's project in editable mode.
        \\                             Equivalent to 'pip install --editable .' command.
        \\
        \\  --group <name>             Also installs [dependency-groups].<name> (PEP 735) from the
        \\                             pyproject.toml dependency_file, else ./pyproject.toml.
        \\                             Repeatable; like 'pip install --group <name>'.
        \\
        \\  --uv                       Requires 'uv' for package operations; fails if it is not on PATH.
        \\                             Without --uv or --pip, zenv uses uv when it is on PATH, else pip.
        \\
        \\  --pip                      Uses 'pip' even when 'uv' is available.
        \\
        \\  --no-host                  Bypasses hostname validation during setup.
        \\                             Equivalent to "target_machines": ["*"] in zenv.json.
        \\                             Use if an environment should be set up regardless of the machine.
        \\
        \\  --python                   Use the zenv-pinned Python for creating environment.
        \\                             Ignores the default Python priority[b] list.
        \\
        \\  --force                    Installs every dependency, including those the loaded modules
        \\                             already provide, and re-captures the module cache.
        \\
        \\  --reuse-module-cache       Replays the existing module cache instead of re-running
        \\                             'module load' when the module list is unchanged.
        \\                             Automatic rebuilds use it; plain 'zenv setup' re-captures.
        \\
        \\  --no-cache                 Disables the package cache when installing dependencies.
        \\                             Ensures fresh package downloads for each installation.
        \\
        \\  --jupyter                  Creates a Jupyter kernel for the environment after setup.
        \\                             Equivalent to running 'zenv jupyter create <name>' after setup.
        ,
    },
    .{
        .commands = &.{.activate},
        .synopsis = "activate <name|id|.> [--shell=sh|bash|zsh|csh|tcsh|fish]",
        .entry =
        \\  activate <name|id|.>       Outputs the activation script path for an environment.
        \\                             To use: source $(zenv activate <name|id|.>)
        \\                             csh/tcsh: source `zenv activate <name|id|.> --shell=csh`
        \\                             fish:     source (zenv activate <name|id|.> --shell=fish)
        \\                             'deactivate' then restores what activation set; activating
        \\                             another environment deactivates this one first.
        \\                             --auto [dir]: for the cd hook; like '.', but from dir:
        \\                             source $(zenv activate --auto .)
        \\                             Uses the nearest zenv.json at or above dir (default: .);
        \\                             prints nothing if it has no registered env. Never rebuilds.
        ,
    },
    .{
        .commands = &.{.hook},
        .synopsis = "hook <zsh|bash>",
        .entry =
        \\  hook <shell>               Outputs a shell hook that activates a project's environment
        \\                             when you cd into it and deactivates it when you leave.
        \\                             zsh:  add to ~/.zshrc: eval "$(zenv hook zsh)"
        \\                             bash: add to the end of ~/.bashrc: eval "$(zenv hook bash)"
        ,
    },
    .{
        .commands = &.{.run},
        .synopsis = "run <name|id|.> <command> [args...]",
        .entry =
        \\  run <name|id|.> <command>  Executes a <command> within the specified isolated environment.
        \\                             Does NOT require manual activation of the environment.
        \\                             Exits with the command's exit status.
        ,
    },
    .{
        .commands = &.{.add},
        .synopsis = "add <name|id|.> <package> [--dev | --group <name>] [--zenv] [--uv|--pip]",
        .entry =
        \\  add <name|id|.> <package>  Installs <package> into the environment and records it in the
        \\                             project's manifest (requirements.txt / pyproject.toml / zenv.json).
        \\                             <package> may include a version (e.g. 'flask>=2.0'); adding a
        \\                             package again updates its recorded version.
        \\                             Options: --dev (dev dependency), --group <name> (dependency
        \\                             group), --zenv (record only in zenv.json), --uv / --pip
        \\                             (installer; default: uv when found).
        \\                             Refused for environments with "python": false.
        ,
        .options =
        \\Options for 'zenv add <name> <package>':
        \\  --dev                      Records the package as a development dependency: '--group dev',
        \\                             except that without a pyproject.toml dependency_file it goes to
        \\                             zenv.json's dev_dependencies. (Note: --dev means editable install
        \\                             for 'setup', dev dependency for 'add'.)
        \\
        \\  --group <name>             Records the package in [dependency-groups].<name> of the
        \\                             pyproject.toml dependency_file, else ./pyproject.toml, and makes
        \\                             rebuilds of the env install that group.
        \\
        \\  --zenv                     Records the package only in zenv.json, leaving requirements.txt
        \\                             and pyproject.toml untouched. The package is still installed.
        \\
        \\  --uv, --pip                Installs with 'uv pip install' or 'python -m pip install'.
        \\                             Default: the --uv/--pip the env was set up with, else uv when
        \\                             it is on PATH, else pip.
        ,
    },
    .{
        .commands = &.{.remove},
        .synopsis = "remove <name|id|.> <package> [--dev | --group <name>] [--zenv] [--uv|--pip]",
        .entry =
        \\  remove <name|id|.> <package>
        \\                             Undoes 'zenv add': removes <package> from the project's manifest
        \\                             and uninstalls it from the environment. A version given with
        \\                             the name is ignored.
        \\                             Options: --dev, --group <name> and --zenv pick the manifest as
        \\                             they do for 'add'; --uv / --pip pick the uninstaller.
        \\                             To delete a whole environment, use 'zenv rm'.
        ,
        .options =
        \\Options for 'zenv remove <name> <package>':
        \\  --dev, --group <name>, --zenv
        \\                             Look for the package where 'zenv add' records it with the same
        \\                             option. A package that is recorded somewhere else is not
        \\                             removed; the error names the option that reaches it.
        \\
        \\  --uv, --pip                Uninstalls with 'uv pip uninstall' or 'python -m pip uninstall',
        \\                             chosen as for 'add'. An environment in a container image always
        \\                             uses the image's pip.
        \\
        \\  The package stays installed when another manifest of the environment still records it, or
        \\  an installed package requires it. Packages that only it required stay installed too.
        ,
    },
    .{
        .commands = &.{.cd},
        .synopsis = "cd <name|id|.>",
        .entry =
        \\  cd <name|id|.>             Outputs the project directory path for an environment.
        \\                             To use: cd $(zenv cd <name|id|.>)
        ,
    },
    .{
        .commands = &.{ .ls, .list },
        .synopsis = "ls [--all | <name|id|.>]",
        .entry =
        \\  ls                         Lists registered environments accessible on this machine.
        \\
        \\  ls --all                   Lists all registered environments.
        \\
        \\  ls <name|id|.>             Shows only the details of the specified environment.
        ,
    },
    .{
        .commands = &.{.register},
        .synopsis = "register <name>",
        .entry =
        \\  register <name>            Adds the environment '<name>' (from current 'zenv.json') to the
        \\                             global registry[a], making it accessible from any location.
        ,
    },
    .{
        .commands = &.{.deregister},
        .synopsis = "deregister <name|id|.>",
        .entry =
        \\  deregister <name|id|.>     Removes an environment from the global registry.
        \\                             The virtual environment files are NOT deleted.
        ,
    },
    .{
        .commands = &.{.rename},
        .synopsis = "rename <old|id> <new>",
        .entry =
        \\  rename <old|id> <new>      Renames an environment from 'old' to 'new': its registry entry,
        \\                             its directory and generated scripts, its entry in zenv.json and
        \\                             its Jupyter kernel. Nothing changes if 'new' is already a name,
        \\                             alias or id, or its directory exists.
        ,
    },
    .{
        .commands = &.{.rm},
        .synopsis = "rm <name|id|.>",
        .entry =
        \\  rm <name|id|.>             De-registers the environment AND permanently deletes its
        \\                             virtual environment directory from the filesystem.
        ,
    },
    .{
        .commands = &.{.validate},
        .synopsis = "validate [config]",
        .entry =
        \\  validate [config]          Validates the configuration file. If no argument is provided it
        \\                             will validate the 'zenv.json' file in the current directory.
        \\                             Reports errors with line numbers and field names if found.
        ,
    },
    .{
        .commands = &.{.log},
        .synopsis = "log <name|id|.>",
        .entry =
        \\  log <name|id|.>            Displays the setup log file for the specified environment.
        ,
    },
    .{
        .commands = &.{.alias},
        .synopsis = "alias <create|remove|ls|show> [args]",
        .entry =
        \\  alias <subcommand>         Manages environment aliases for easier access:
        \\    create <alias> <env>     Creates an alias for an environment.
        \\    remove <alias>           Removes the alias (from every environment sharing it).
        \\    ls                       Lists all defined aliases.
        \\    show <alias>             Shows what environment an alias points to.
        ,
    },
    .{
        .commands = &.{.jupyter},
        .synopsis = "jupyter <create|remove|ls|check> [args]",
        .entry =
        \\  jupyter <subcommand>       Manages Jupyter kernels for environments:
        \\    create <env_name>        Creates a Jupyter kernel for the environment. The kernel starts
        \\                             through 'zenv run', so it gets the env's modules; the env
        \\                             needs ipykernel ('zenv add <env> ipykernel').
        \\                             --name <kernel> and --display-name <text> replace the
        \\                             defaults 'zenv-<env_name>' and 'Python (<env_name>)'.
        \\    remove <env_name>        Removes the Jupyter kernel for the specified environment.
        \\    ls                       Lists all zenv-managed Jupyter kernels.
        \\    check                    Checks if Jupyter is installed and available.
        ,
    },
    .{
        .commands = &.{.python},
        .synopsis = "python <install|pin|unpin|ls> [version]",
        .entry =
        \\  python <subcommand>        (Experimental feature) Manages Python installations:
        \\    install <version>        Downloads and installs a specific Python version for zenv.
        \\    pin <version>            Sets <version> as the pinned Python for zenv to prioritize.
        \\    unpin                    Removes the pin; installed Pythons are kept.
        \\    ls                       Shows Python versions installed and managed by zenv.
        ,
    },
    .{
        .commands = &.{ .version, .@"-v", .@"-V", .@"--version" },
        .synopsis = "version",
        .entry =
        \\  version, -v, --version     Prints the installed zenv version.
        ,
    },
    .{
        .commands = &.{ .help, .@"-h", .@"--help" },
        .synopsis = "help [command]",
        .entry =
        \\  help [command]             Shows this help message, or the help for one command.
        \\                             'zenv <command> --help' (or -h) shows the same.
        ,
    },
};

/// The sections after the commands; the entries refer to them as [z], [a], [b] and [.].
const notes =
    \\[z] Configuration (zenv.json):
    \\  The 'zenv.json' file is a JSON formatted file that defines your environments; it
    \\  may contain // line and /* block */ comments.
    \\  Each top-level key is an environment name. "base_dir": "path/to/venvs" is a special
    \\  top-level key specifying the storage location for virtual environments (default:
    \\  .zenv). Paths can be absolute (e.g., /path/to/venvs) or relative to the 'zenv.json'
    \\  location.
    \\  In an environment, "python": false builds it without a Python venv, and "env" sets
    \\  environment variables ("NAME": "value", or {"prepend": ...} / {"append": ...}).
    \\  "container": {"image": "path.sif", "options": [...], "bind": [...]} runs it in an
    \\  Apptainer image, and with "runtime": "docker" and an image reference in a Docker image:
    \\  setup and 'zenv run' start their commands inside it, and activation is refused.
    \\
    \\[a] Registry (ZENV_DIR/registry.json):
    \\  A global JSON file (path in ZENV_DIR environment variable, typically $HOME/.zenv)
    \\  that tracks registered environments. This allows 'zenv' commands to manage
    \\  these environments from any directory. Environments are added via 'zenv setup'
    \\  or 'zenv register'.
    \\
    \\[b] Python Priority List (for 'zenv setup' without '--python' flag):
    \\  zenv attempts to find a Python interpreter in the following order:
    \\  1. A Python the loaded HPC modules put on PATH.
    \\  2. Path explicitly specified by the 'fallback_python' key in zenv.json.
    \\  3. zenv-pinned Python (set via 'zenv python pin <version>').
    \\  4. System Python.
    \\  Use 'zenv setup <name> --python' to use only the pinned version.
    \\  When pyproject.toml sets requires-python (as the dependency_file, or with
    \\  --dev), setup stops if the selected Python does not satisfy it.
    \\
    \\[.] Dot Notation:
    \\  Use '.' as the environment identifier to select the environment of the project
    \\  you are in: the nearest zenv.json at or above the current directory, so it
    \\  works from any subdirectory. A nested project's zenv.json shadows the one
    \\  around it.
    \\
    \\Automatic rebuilds:
    \\  'run', 'activate', 'cd' and 'jupyter create' first rebuild an environment whose
    \\  entry in zenv.json, or a file that entry names (dependency_file, modules_file,
    \\  setup.script), changed since its last setup. A notice goes to stderr.
    \\
    \\Environment variables:
    \\  ZENV_DIR                   Where zenv keeps its registry and Python installs
    \\                             (default: $HOME/.zenv).
    \\  ZENV_NO_AUTO_SETUP=1       Turns automatic rebuilds off.
    \\  ZENV_RUN_SHELL=1           'zenv run' sources activate.sh in bash instead of starting
    \\                             the command directly.
    \\  ZENV_DEBUG=1               Prints debug output.
;

/// Everything: what `zenv help` prints.
const overview = blk: {
    var text: []const u8 = header ++ "\n";
    for (topics) |t| text = text ++ t.entry ++ "\n\n";
    for (topics) |t| {
        if (t.options.len > 0) text = text ++ t.options ++ "\n\n";
    }
    break :blk text ++ notes ++ "\n";
};

/// The topic of `command`; null for the internal commands, which have none.
fn topicOf(command: Command) ?Topic {
    for (topics) |t| {
        if (std.mem.indexOfScalar(Command, t.commands, command) != null) return t;
    }
    return null;
}

pub fn printOverview(io: Io) void {
    Io.File.stdout().writeStreamingAll(io, overview) catch {};
}

/// Prints the help of one command, or the overview when it has no topic.
pub fn printCommand(io: Io, command: Command) void {
    const t = topicOf(command) orelse return printOverview(io);
    output.rawOut(io, "Usage: zenv {s}\n\n{s}\n\n", .{ t.synopsis, t.entry });
    if (t.options.len > 0) output.rawOut(io, "{s}\n\n", .{t.options});
    output.rawOut(
        io,
        "Run 'zenv help' for all commands and the notes on zenv.json, the registry and Python selection.\n",
        .{},
    );
}

/// Whether `args` (the whole command line) ask for the help of `command`
/// instead of running it.
pub fn requested(command: Command, args: []const []const u8) bool {
    if (args.len < 3) return false;
    switch (command) {
        // `zenv help <command>` is the caller's to resolve.
        .help, .@"-h", .@"--help" => return false,
        // Here the first argument is a subcommand, so the word is free.
        // Elsewhere it would be an environment named "help".
        .alias, .jupyter, .python => if (std.mem.eql(u8, args[2], "help")) return true,
        else => {},
    }
    // After the environment, `run`'s arguments belong to the command it runs.
    const own = if (command == .run) args[2..3] else args[2..];
    for (own) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    }
    return false;
}

test "requested: help flags and the help word" {
    const t = std.testing;
    try t.expect(requested(.setup, &.{ "zenv", "setup", "--help" }));
    try t.expect(requested(.init, &.{ "zenv", "init", "name", "-h" }));
    try t.expect(requested(.python, &.{ "zenv", "python", "help" }));
    try t.expect(!requested(.python, &.{ "zenv", "python" }));
    // An environment may be named "help".
    try t.expect(!requested(.setup, &.{ "zenv", "setup", "help" }));
    try t.expect(requested(.run, &.{ "zenv", "run", "--help" }));
    try t.expect(!requested(.run, &.{ "zenv", "run", "env", "pytest", "--help" }));
}

test "every public command has a topic" {
    for (std.enums.values(Command)) |command| {
        try std.testing.expect(topicOf(command) != null);
    }
}
