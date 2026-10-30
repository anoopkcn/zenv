const std = @import("std");
const builtin = @import("builtin");
const process = std.process;
const Io = std.Io;

const options = @import("options");
const commands = @import("commands.zig");
const Command = commands.Command;
const Registry = @import("Registry.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const errors = @import("errors.zig");

fn printUsage(io: Io) void {
    const usage =
        \\Usage: zenv <command> [name|id] [options]
        \\
        \\Manages project environments based on zenv.json configuration: a Python venv
        \\and its packages, HPC modules, environment variables and settings.
        \\
        \\Commands:
        \\  init [name] [desc]         Creates 'zenv.json' with environment 'name', or adds it to an
        \\                             existing one. 'name' defaults to the directory's name.
        \\                             --no-python: an environment without Python, for modules,
        \\                             environment variables and settings only.
        \\                             Use to start defining your environments[z].
        \\
        \\  setup <name>               Creates and configures the environment '<name>' as per
        \\                             'zenv.json' in '<base_dir>/<name>': modules, the Python venv and
        \\                             its packages (none with "python": false), hooks and activation.
        \\                             This is the primary command to build an environment.
        \\
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
        \\
        \\  hook <shell>               Outputs a shell hook that activates a project's environment
        \\                             when you cd into it and deactivates it when you leave.
        \\                             zsh:  add to ~/.zshrc: eval "$(zenv hook zsh)"
        \\                             bash: add to the end of ~/.bashrc: eval "$(zenv hook bash)"
        \\
        \\  run <name|id|.> <command>  Executes a <command> within the specified isolated environment.
        \\                             Does NOT require manual activation of the environment.
        \\                             Exits with the command's exit status.
        \\
        \\  add <name|id|.> <package>  Installs <package> into the environment and records it in the
        \\                             project's manifest (requirements.txt / pyproject.toml / zenv.json).
        \\                             <package> may include a version (e.g. 'flask>=2.0'); adding a
        \\                             package again updates its recorded version.
        \\                             Options: --dev (dev dependency), --group <name> (dependency
        \\                             group), --zenv (record only in zenv.json), --uv / --pip
        \\                             (installer; default: uv when found).
        \\                             Refused for environments with "python": false.
        \\
        \\  cd <name|id|.>             Outputs the project directory path for an environment.
        \\                             To use: cd $(zenv cd <name|id|.>)
        \\
        \\  ls                         Lists registered environments accessible on this machine.
        \\
        \\  ls --all                   Lists all registered environments.
        \\
        \\  ls <name|id|.>             Shows only the details of the specified environment.
        \\
        \\  register <name>            Adds the environment '<name>' (from current 'zenv.json') to the
        \\                             global registry[a], making it accessible from any location.
        \\
        \\  deregister <name|id|.>     Removes an environment from the global registry.
        \\                             The virtual environment files are NOT deleted.
        \\
        \\  rename <old|id> <new>      Renames an environment from 'old' to 'new': its registry entry,
        \\                             its directory and generated scripts, its entry in zenv.json and
        \\                             its Jupyter kernel. Nothing changes if 'new' is already a name,
        \\                             alias or id, or its directory exists.
        \\
        \\  rm <name|id|.>             De-registers the environment AND permanently deletes its
        \\                             virtual environment directory from the filesystem.
        \\
        \\  validate [config]          Validates the configuration file. If no argument is provided it
        \\                             will validate the 'zenv.json' file in the current directory.
        \\                             Reports errors with line numbers and field names if found.
        \\
        \\  log <name|id|.>            Displays the setup log file for the specified environment.
        \\
        \\  alias <subcommand>         Manages environment aliases for easier access:
        \\    create <alias> <env>     Creates an alias for an environment.
        \\    remove <alias>           Removes the alias (from every environment sharing it).
        \\    ls                       Lists all defined aliases.
        \\    show <alias>             Shows what environment an alias points to.
        \\
        \\  jupyter <subcommand>       Manages Jupyter kernels for environments:
        \\    create <env_name>        Creates a Jupyter kernel for the environment. The kernel starts
        \\                             through 'zenv run', so it gets the env's modules; the env
        \\                             needs ipykernel ('zenv add <env> ipykernel').
        \\                             --name <kernel> and --display-name <text> replace the
        \\                             defaults 'zenv-<env_name>' and 'Python (<env_name>)'.
        \\    remove <env_name>        Removes the Jupyter kernel for the specified environment.
        \\    ls                       Lists all zenv-managed Jupyter kernels.
        \\    check                    Checks if Jupyter is installed and available.
        \\
        \\  python <subcommand>        (Experimental feature) Manages Python installations:
        \\    install <version>        Downloads and installs a specific Python version for zenv.
        \\    pin <version>            Sets <version> as the pinned Python for zenv to prioritize.
        \\    ls                       Shows Python versions installed and managed by zenv.
        \\
        \\  version, -v, --version     Prints the installed zenv version.
        \\
        \\  help, --help               Shows this help message.
        \\
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
        \\
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
        \\
        \\[z] Configuration (zenv.json):
        \\  The 'zenv.json' file is a JSON formatted file that defines your environments.
        \\  Each top-level key is an environment name. "base_dir": "path/to/venvs" is a special
        \\  top-level key specifying the storage location for virtual environments (default:
        \\  .zenv). Paths can be absolute (e.g., /path/to/venvs) or relative to the 'zenv.json'
        \\  location.
        \\  In an environment, "python": false builds it without a Python venv, and "env" sets
        \\  environment variables ("NAME": "value", or {"prepend": ...} / {"append": ...}).
        \\
        \\[a] Registry (ZENV_DIR/registry.json):
        \\  A global JSON file (path in ZENV_DIR environment variable, typically $HOME/.zenv)
        \\  that tracks registered environments. This allows 'zenv' commands to manage
        \\  these environments from any directory. Environments are added via 'zenv setup'
        \\  or 'zenv register'.
        \\
        \\[b] Python Priority List (for 'zenv setup' without '--python' flag):
        \\  zenv attempts to find a Python interpreter in the following order:
        \\  1. HPC module-provided Python (if HPC environment modules are loaded).
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
        \\
    ;
    Io.File.stdout().writeStreamingAll(io, usage) catch {};
}

pub fn main(init: std.process.Init.Minimal) !void {
    // One arena for the whole run; the process exits when the command ends.
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // What std.process.Init sets up, except that the environment is copied
    // into the arena. Init copies it with its general-purpose allocator, which
    // on Linux without libc is the SmpAllocator; on a many-core node that maps
    // a fresh 64 KB slab for most of the small copies (~170 mmaps, ~1 ms per
    // command on a 256-CPU login node).
    const gpa = if (builtin.link_libc) std.heap.c_allocator else std.heap.smp_allocator;
    var threaded: Io.Threaded = .init(gpa, .{ .argv0 = .init(init.args), .environ = init.environ });
    defer threaded.deinit();
    const environ_map = try init.environ.createMap(allocator);

    // What every command gets from the process; passed down explicitly.
    const ctx: runtime.Ctx = .{ .arena = allocator, .io = threaded.io(), .env = &environ_map };
    const io = ctx.io;
    if (ctx.getEnv("ZENV_DEBUG")) |v| {
        output.debug_enabled = for ([_][]const u8{ "1", "true", "yes" }) |on| {
            if (std.mem.eql(u8, v, on)) break true;
        } else false;
    }

    const args = try init.args.toSlice(allocator);

    const command: Command = if (args.len < 2) .help else std.meta.stringToEnum(
        Command,
        args[1],
    ) orelse {
        output.printError(io, "Unknown command '{s}'", .{args[1]});
        output.print(io, "run 'zenv help' to see the usage", .{});
        process.exit(1);
    };
    // Handlers return errors rather than reporting them; they are mapped to a
    // message (and an exit status) in one place.
    dispatch(ctx, command, args) catch |err| errors.report(io, err);
}

fn dispatch(ctx: runtime.Ctx, command: Command, args: []const []const u8) !void {
    switch (command) {
        .help, .@"--help" => printUsage(ctx.io),
        .version, .@"-v", .@"-V", .@"--version" => {
            Io.File.stdout().writeStreamingAll(ctx.io, options.version ++ "\n") catch {};
        },
        .init => commands.handleInit(ctx, args),
        // These never touch the registry, so they neither pay for nor fail on
        // registry.json.
        .python => try commands.handlePython(ctx, args),
        .hook => try commands.handleHook(ctx, args),
        .validate => try commands.handleValidate(ctx, args),
        .setup => try withRegistry(ctx, args, commands.handleSetup),
        .activate => try withRegistry(ctx, args, commands.handleActivate),
        .ls, .list => try withRegistry(ctx, args, commands.handleList),
        .register => try withRegistry(ctx, args, commands.handleRegister),
        .deregister => try withRegistry(ctx, args, commands.handleDeregister),
        .rm => try withRegistry(ctx, args, commands.handleRm),
        .rename => try withRegistry(ctx, args, commands.handleRename),
        .cd => try withRegistry(ctx, args, commands.handleCd),
        .log => try withRegistry(ctx, args, commands.handleLog),
        .run => try withRegistry(ctx, args, commands.handleRun),
        .add => try withRegistry(ctx, args, commands.handleAdd),
        .alias => try withRegistry(ctx, args, commands.handleAlias),
        .jupyter => try withRegistry(ctx, args, commands.handleJupyter),
    }
}

/// Loads the registry, then runs `handler` with it.
fn withRegistry(ctx: runtime.Ctx, args: []const []const u8, comptime handler: anytype) !void {
    var registry = Registry.load(ctx.arena, ctx.io, ctx.env) catch |err| {
        output.printError(ctx.io, "Failed to load environment registry: {t}", .{err});
        // A corrupt file has a message of its own; anything else is access.
        return if (err == error.InvalidRegistryFormat) err else error.RegistryError;
    };
    defer registry.deinit();
    try handler(ctx, &registry, args);
}
