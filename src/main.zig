const std = @import("std");
const process = std.process;
const Allocator = std.mem.Allocator;

const options = @import("options");
const commands = @import("commands.zig");
const configurations = @import("utils/config.zig");
const output = @import("utils/output.zig");
const flags_module = @import("utils/flags.zig");
const validation = @import("utils/validation.zig");
const runtime = @import("utils/runtime.zig");
const paths = @import("utils/paths.zig");
const errors = @import("utils/errors.zig");

pub const Command = enum {
    setup,
    activate,
    ls,
    /// Former name of `ls`, still accepted.
    list,
    register,
    deregister,
    cd,
    init,
    rm,
    rename,
    python,
    log,
    run,
    add,
    validate,
    alias,
    jupyter,
    hook,
    help,
    version,
    @"-v",
    @"-V",
    @"--version",
    @"--help",
    unknown,

    fn fromString(s: []const u8) Command {
        // Tag names ARE the command spellings (including @"-v" etc.), so the
        // comptime-built string map covers every command with no hand-kept table.
        return std.meta.stringToEnum(Command, s) orelse .unknown;
    }
};

fn stdoutWrite(bytes: []const u8) void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(runtime.io, &buf);
    const w = &fw.interface;
    w.writeAll(bytes) catch return;
    w.flush() catch return;
}

fn printVersion() void {
    stdoutWrite(options.version ++ "\n");
}

fn printUsage() void {
    const usage = comptime
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
        \\                             --auto [dir]: the project you are in, from any subdirectory:
        \\                             source $(zenv activate --auto .)
        \\                             Uses the nearest zenv.json at or above dir (default: .);
        \\                             prints nothing if it has no registered env. Never rebuilds.
        \\
        \\  hook <shell>               Outputs a shell hook that activates a project's environment
        \\                             when you cd into it and deactivates it when you leave.
        \\                             Supported: zsh. Add to ~/.zshrc: eval "$(zenv hook zsh)"
        \\
        \\  run <name|id|.> <command>  Executes a <command> within the specified isolated environment.
        \\                             Does NOT require manual activation of the environment.
        \\
        \\  add <name|id|.> <package>  Installs <package> into the environment and records it in the
        \\                             project's manifest (requirements.txt / pyproject.toml / zenv.json).
        \\                             <package> may include a version (e.g. 'flask>=2.0').
        \\                             Options: --dev (dev dependency), --zenv (record only in
        \\                             zenv.json), --uv (use uv instead of pip).
        \\                             Refused for environments with "python": false.
        \\
        \\  cd <name|id|.>             Outputs the project directory path for an environment.
        \\                             To use: cd $(zenv cd <name|id|.>)
        \\
        \\  ls                         Lists registered environments accessible on this machine.
        \\
        \\  ls --all                   Lists all registered environments.
        \\
        \\  register <name>            Adds the environment '<name>' (from current 'zenv.json') to the
        \\                             global registry[a], making it accessible from any location.
        \\
        \\  deregister <name|id|.>     Removes an environment from the global registry.
        \\                             The virtual environment files are NOT deleted.
        \\
        \\  rename <old|id> <new>      Renames an environment from 'old' to 'new'.
        \\                             Updates the registry, renames the virtual environment directory,
        \\                             updates generated scripts, and updates any associated Jupyter kernels.
        \\                             Preserves all configuration and metadata.
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
        \\    list                     Lists all defined aliases.
        \\    show <alias>             Shows what environment an alias points to.
        \\
        \\  jupyter <subcommand>       Manages Jupyter kernels for environments:
        \\    create <env_name>        Creates a Jupyter kernel for the environment. The kernel starts
        \\                             through 'zenv run', so it gets the env's modules; the env
        \\                             needs ipykernel ('zenv add <env> ipykernel').
        \\    remove <env_name>        Removes the Jupyter kernel for the specified environment.
        \\    list                     Lists all zenv-managed Jupyter kernels.
        \\    check                    Checks if Jupyter is installed and available.
        \\
        \\  python <subcommand>        (Experimental feature) Manages Python installations:
        \\    install <version>        Downloads and installs a specific Python version for zenv.
        \\    pin <version>            Sets <version> as the pinned Python for zenv to prioritize.
        \\    list                     Shows Python versions installed and managed by zenv.
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
        \\  --uv                       Uses 'uv' instead of 'pip' for package operations.
        \\                             Ensure 'uv' is installed and accessible.
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
        \\  --no-cache                 Disables the package cache when installing dependencies.
        \\                             Ensures fresh package downloads for each installation.
        \\
        \\  --jupyter                  Creates a Jupyter kernel for the environment after setup.
        \\                             Equivalent to running 'zenv jupyter create <name>' after setup.
        \\
        \\Options for 'zenv add <name> <package>':
        \\  --dev                      Records the package as a development dependency.
        \\                             pyproject.toml -> [dependency-groups].dev; otherwise zenv.json.
        \\                             (Note: --dev means editable install for 'setup', dev dependency
        \\                             for 'add' — its meaning is per-command.)
        \\
        \\  --zenv                     Records the package only in zenv.json, leaving requirements.txt
        \\                             and pyproject.toml untouched. The package is still installed.
        \\
        \\  --uv                       Uses 'uv pip install' instead of 'python -m pip install'.
        \\
        \\[z] Configuration (zenv.json):
        \\  The 'zenv.json' file is a JSON formatted file that defines your environments.
        \\  Each top-level key is an environment name. "base_dir": "path/to/venvs" is a special
        \\  top-level key specifying the storage location for virtual environments.
        \\  Paths can be absolute (e.g., /path/to/venvs) or relative to the 'zenv.json' location.
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
        \\
        \\[.] Dot Notation:
        \\  Use '.' as the environment identifier to automatically select an environment
        \\  from the current directory. This works when you're in a directory containing
        \\  a zenv.json file and have registered environments for that directory.
        \\  From a subdirectory of the project, use 'zenv activate --auto .' instead.
        \\
    ;
    stdoutWrite(usage);
}

pub fn main(app: std.process.Init) anyerror!void {
    // Establish the process-wide I/O context for the whole program.
    runtime.io = app.io;
    runtime.environ_map = app.environ_map;
    runtime.version = options.version;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Collect args into an owned slice. The argv strings are static (owned by
    // the OS), so we only copy the pointers; the arena owns the slice itself.
    var args_builder: std.ArrayList([]const u8) = .empty;
    var arg_it = app.minimal.args.iterate();
    while (arg_it.next()) |a| try args_builder.append(allocator, a);
    const args = try args_builder.toOwnedSlice(allocator);

    // Command parsing logic - Use args directly for command parsing
    const command: Command = if (args.len < 2) .help else Command.fromString(args[1]);

    const config_path = "zenv.json";

    // Commands that never touch the registry are handled before it is loaded,
    // so `zenv python`/`zenv validate` don't pay for (or fail on) registry.json.
    switch (command) {
        .help, .@"--help" => {
            printUsage();
            process.exit(0);
        },
        .version, .@"-v", .@"-V", .@"--version" => {
            printVersion();
            process.exit(0);
        },
        .init => {
            // Handle init command directly to avoid loading config
            commands.handleInitCommand(allocator, args);
            process.exit(0);
        },
        .python => {
            commands.handlePythonCommand(allocator, args) catch |err| errors.report(allocator, err);
            return;
        },
        .hook => {
            commands.handleHookCommand(allocator, args) catch |err| errors.report(allocator, err);
            return;
        },
        .validate => {
            commands.handleValidateCommand(allocator, config_path, args) catch |err| errors.report(allocator, err);
            return;
        },
        .unknown => {
            output.printError(allocator, "Unknown command '{s}'", .{args[1]}) catch {};
            output.print(allocator, "run 'zenv help' to see the usage", .{}) catch {};
            process.exit(1);
        },
        // Registry-backed commands proceed to registry/config loading below.
        .setup,
        .activate,
        .ls,
        .list,
        .register,
        .deregister,
        .cd,
        .rm,
        .rename,
        .log,
        .run,
        .add,
        .alias,
        .jupyter,
        => {},
    }
    // Load the environment registry first, as we'll need it for all commands
    var registry = configurations.EnvironmentRegistry.load(allocator) catch |err| {
        output.printError(allocator, "Failed to load environment registry: {s}", .{@errorName(err)}) catch {};
        errors.report(allocator, error.RegistryError);
        return;
    };
    defer registry.deinit();

    // Parse configuration if we're in a project directory with zenv.json
    // We'll only need this for setup and registering new environments
    var config: ?configurations.ZenvConfig = null;
    defer if (config != null) config.?.deinit();

    // For setup command, check if we need to init first
    if (command == .setup) {
        commands.checkFlags(allocator, args, &commands.SETUP_FLAGS) catch |err| errors.report(allocator, err);
        const flags = flags_module.CommandFlags.fromArgs(args);
        const init_flag = flags.init_mode;

        // --no-python only shapes a new env's config; after that, zenv.json
        // decides (and auto-setup rebuilds from it without replaying flags).
        if (flags.no_python and !init_flag) {
            output.printError(allocator, "--no-python only applies with --init. For an existing environment, set \"python\": false for it in zenv.json.", .{}) catch {};
            process.exit(1);
        }

        if (init_flag) {
            // The name is the first POSITIONAL argument, skipping flags:
            // `zenv setup --init myenv` must not create an env named "--init".
            const env_name = flags_module.positional(args, 0) orelse {
                output.printError(allocator, "Missing environment name. Usage: zenv setup <name> --init", .{}) catch {};
                process.exit(1);
            };
            if (!paths.isValidEnvName(env_name)) {
                output.printError(allocator, "Invalid environment name '{s}'. Use only letters, digits, '-', '_' and '.'.", .{env_name}) catch {};
                process.exit(1);
            }
            // Writes zenv.json, or adds the env to an existing one; an env the
            // file already defines is simply set up.
            const outcome = commands.initConfig(allocator, env_name, flags_module.positional(args, 1), !flags.no_python) catch |err| {
                output.printError(allocator, "Could not add '{s}' to zenv.json: {s}", .{ env_name, @errorName(err) }) catch {};
                process.exit(1);
            };
            switch (outcome) {
                .created => output.print(allocator, "--init: created zenv.json with environment '{s}'", .{env_name}) catch {},
                .added => output.print(allocator, "--init: added environment '{s}' to zenv.json", .{env_name}) catch {},
                .exists => {
                    // An existing env keeps its config; refuse rather than
                    // set up something other than what --no-python asked for.
                    if (flags.no_python and !(commands.pythonDisabled(allocator, config_path, env_name) catch false)) {
                        output.printError(allocator, "zenv.json already defines '{s}' with Python. Set \"python\": false for it in zenv.json, or pick a new name.", .{env_name}) catch {};
                        process.exit(1);
                    }
                    output.print(allocator, "--init: zenv.json already defines '{s}'; using it", .{env_name}) catch {};
                },
            }
        }

        // Now load the config with validation
        config = validation.validateAndParse(allocator, config_path) catch |err| {
            errors.report(allocator, err);
            return; // Exit after handling error
        };
    } else if (command == .register) {
        config = validation.validateAndParse(allocator, config_path) catch |err| {
            errors.report(allocator, err);
            return; // Exit after handling error
        };
    }

    // Dispatch to command handlers
    // Dispatch the command; any error it returns is mapped to a user-facing
    // message (and exits) by the single error handler.
    const config_ptr: ?*const configurations.ZenvConfig = if (config) |*c| c else null;
    dispatch(command, allocator, config_ptr, &registry, args) catch |err| errors.report(allocator, err);
}

/// Routes a parsed command to its handler. Handlers return errors rather than
/// reporting them; `main` maps the error to a message in one place.
fn dispatch(
    command: Command,
    allocator: Allocator,
    config: ?*const configurations.ZenvConfig,
    registry: *configurations.EnvironmentRegistry,
    args: []const []const u8,
) !void {
    switch (command) {
        .setup => try commands.handleSetupCommand(allocator, config.?, registry, args),
        .activate => try commands.handleActivateCommand(allocator, registry, args),
        .ls, .list => try commands.handleListCommand(allocator, registry, args),
        .register => try commands.handleRegisterCommand(allocator, config.?, registry, args),
        .deregister => try commands.handleDeregisterCommand(allocator, registry, args),
        .rm => try commands.handleRmCommand(allocator, registry, args),
        .rename => try commands.handleRenameCommand(allocator, registry, args),
        .cd => try commands.handleCdCommand(allocator, registry, args),
        .log => try commands.handleLogCommand(allocator, registry, args),
        .run => try commands.handleRunCommand(allocator, registry, args),
        .add => try commands.handleAddCommand(allocator, registry, args),
        .alias => try commands.handleAliasCommand(allocator, registry, args),
        .jupyter => try commands.handleJupyterCommand(allocator, registry, args),

        // These were handled before dispatch, unreachable here
        .help, .@"--help", .version, .@"-v", .@"-V", .@"--version", .init, .python, .validate, .hook, .unknown => unreachable,
    }
}
