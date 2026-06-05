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

pub const Command = enum {
    setup,
    activate,
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
    validate,
    alias,
    jupyter,
    help,
    version,
    @"-v",
    @"-V",
    @"--version",
    @"--help",
    unknown,

    fn fromString(s: []const u8) Command {
        const command_map = .{
            .{ "setup", .setup },
            .{ "activate", .activate },
            .{ "list", .list },
            .{ "register", .register },
            .{ "deregister", .deregister },
            .{ "cd", .cd },
            .{ "init", .init },
            .{ "rm", .rm },
            .{ "rename", .rename },
            .{ "python", .python },
            .{ "log", .log },
            .{ "run", .run },
            .{ "validate", .validate },
            .{ "alias", .alias },
            .{ "jupyter", .jupyter },
            .{ "help", .help },
            .{ "version", .version },
            .{ "-v", .@"-v" },
            .{ "-V", .@"-V" },
            .{ "--version", .@"--version" },
            .{ "--help", .@"--help" },
        };

        // Linear search through the command_map
        inline for (command_map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) {
                return entry[1];
            }
        }
        return Command.unknown;
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
    stdoutWrite(options.version);
}

fn printUsage() void {
    const usage = comptime 
        \\Usage: zenv <command> [name|id] [options]
        \\
        \\Manages Python virtual environments based on zenv.json configuration.
        \\
        \\Commands:
        \\  init [name] [desc]         Initializes a new 'zenv.json' in the current directory.
        \\                             Creates a 'test' environment if 'name' is not provided.
        \\                             Use to start defining your environments[z].
        \\
        \\  setup <name>               Creates and configures the virtual environment for '<name>'.
        \\                             Builds the environment in '<base_dir>/<name>' as per 'zenv.json'.
        \\                             This is the primary command to build an environment.
        \\
        \\  activate <name|id|.>       Outputs the activation script path for an environment.
        \\                             To use: source $(zenv activate <name|id|.>)
        \\
        \\  run <name|id|.> <command>  Executes a <command> within the specified isolated environment.
        \\                             Does NOT require manual activation of the environment.
        \\
        \\  cd <name|id|.>             Outputs the project directory path for an environment.
        \\                             To use: cd $(zenv cd <name|id|.>)
        \\
        \\  list                       Lists registered environments accessible on this machine.
        \\
        \\  list --all                 Lists all registered environments.
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
        // \\  rm <name|id>               De-registers the environment AND permanently deletes its
        // \\                             virtual environment directory from the filesystem.
        // \\
        \\  validate [config]          Validates the configuration file. If no arguent provided it
        \\                             will validate the 'zenv.json' file in the current directory.
        \\                             Reports errors with line numbers and field names if found.
        \\
        \\  log <name|id|.>            Displays the setup log file for the specified environment.
        \\
        \\  alias <subcommand>         Manages environment aliases for easier access:
        \\    create <alias> <env>     Creates an alias for an environment.
        \\    remove <alias>           Removes an existing alias.
        \\    list                     Lists all defined aliases.
        \\    show <alias>             Shows what environment an alias points to.
        \\
        \\  jupyter <subcommand>       Manages Jupyter kernels for environments:
        \\    create <env_name>        Creates a Jupyter kernel for the specified environment.
        \\    remove <env_name>        Removes the Jupyter kernel for the specified environment.
        \\    list                     Lists all zenv-managed Jupyter kernels.
        \\    check                    Checks if Jupyter is installed and available.
        \\
        \\  python <subcommand>        (Experimantal feature) Manages Python installations:
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
        \\  --force                    Forces reinstallation of all dependencies.
        \\                             Useful if dependencies from loaded modules cause conflicts.
        \\
        \\  --no-cache                 Disables the package cache when installing dependencies.
        \\                             Ensures fresh package downloads for each installation.
        \\
        \\  --jupyter                  Creates a Jupyter kernel for the environment after setup.
        \\                             Equivalent to running 'zenv jupyter create <name>' after setup.
        \\
        \\[z] Configuration (zenv.json):
        \\  The 'zenv.json' file is a JSON formatted file that defines your environments.
        \\  Each top-level key is an environment name. "base_dir": "path/to/venvs" is a special
        \\  top-level key specifying the storage location for virtual environments.
        \\  Paths can be absolute (e.g., /path/to/venvs) or relative to the 'zenv.json' location.
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
        \\  3. zenv-pinned Python (set via 'zenv python use <version>').
        \\  4. System Python.
        \\  Use 'zenv setup <name> --python' to use only the pinned version.
        \\
        \\[.] Dot Notation:
        \\  Use '.' as the environment identifier to automatically select an environment
        \\  from the current directory. This works when you're in a directory containing
        \\  a zenv.json file and have registered environments for that directory.
        \\
    ;
    stdoutWrite(usage);
}

pub fn main(app: std.process.Init) anyerror!void {
    // Establish the process-wide I/O context for the whole program (Zig 0.16).
    runtime.io = app.io;
    runtime.environ_map = app.environ_map;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Collect args into an owned slice from the std bootstrap. The argv strings
    // are static (owned by the OS), so we only copy the pointers; the arena owns
    // the slice itself.
    var args_builder = std.array_list.Managed([]const u8).init(allocator);
    var arg_it = app.minimal.args.iterate();
    while (arg_it.next()) |a| try args_builder.append(a);
    const args = try args_builder.toOwnedSlice();

    // Command parsing logic - Use args directly for command parsing
    const command: Command = if (args.len < 2) .help else Command.fromString(args[1]);

    // Handle simple commands directly
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
        // Let other commands proceed to config parsing
        .setup,
        .activate,
        .list,
        .register,
        .deregister,
        .cd,
        .rm,
        .rename,
        .python,
        .log,
        .run,
        .validate,
        .alias,
        .jupyter,
        .unknown,
        => {},
    }

    const config_path = "zenv.json";

    const handleError = struct {
        pub fn func(alloc: Allocator, err: anyerror) void {
            // Standard error handler
            if (@errorReturnTrace()) |trace| {
                output.printError(alloc, "{s}", .{@errorName(err)}) catch {};

                // Handle specific errors
                switch (err) {
                    error.ConfigFileNotFound => {
                        output.printError(alloc,
                            \\Configuration file '{s}' not found
                        , .{config_path}) catch {};
                    },
                    error.FileNotFound => {
                        output.printError(alloc,
                            \\zenv could not find a file required to complete this command
                        , .{}) catch {};
                    },
                    error.ClusterNotFound => {
                        output.printError(alloc,
                            \\Target machine mismatch or environment not suitable for current machine
                        , .{}) catch {};
                    },
                    error.EnvironmentNotFound => {
                        output.printError(alloc,
                            \\Environment name not found in configuration or argument missing
                        , .{}) catch {};
                    },
                    error.JsonParseError => {
                        output.printError(alloc,
                            \\Invalid JSON format in '{s}'. Check syntax
                        , .{config_path}) catch {};
                    },
                    error.InvalidFormat => {
                        output.printError(alloc,
                            \\Invalid JSON format in '{s}'. Check syntax for details above
                        , .{config_path}) catch {};
                    },
                    error.ConfigInvalid => {
                        output.printError(alloc,
                            \\Invalid configuration structure in '{s}'. Check keys/types/required fields
                        , .{config_path}) catch {};
                    },
                    error.MissingHostname => {
                        output.printError(alloc,
                            \\HOSTNAME is not set or inaccessible which is required for validation
                        , .{}) catch {};
                    },
                    error.PathResolutionFailed => {
                        output.printError(alloc,
                            \\Failed to resolve a required file path (e.g., requirements file)
                            \\
                        , .{}) catch {};
                    },
                    error.TargetMachineMismatch => {
                        output.printError(alloc,
                            \\Current machine does not match the target specified for this environment
                        , .{}) catch {};
                    },
                    error.AmbiguousIdentifier => {
                        output.printError(alloc,
                            \\The provided ID prefix matches multiple environments. Use more characters
                        , .{}) catch {};
                    },
                    error.RegistryError => {
                        output.printError(alloc,
                            \\Failed to access the environment registry. Check permissions for ZENV_DIR
                        , .{}) catch {};
                    },
                    error.ArgsError => {
                        output.printError(alloc,
                            \\Invalid command-line arguments provided. Check usage with 'zenv help'
                        , .{}) catch {};
                    },
                    error.EnvironmentNotRegistered => {
                        output.printError(alloc,
                            \\The specified environment is not registered. Use 'zenv register <name>'
                        , .{}) catch {};
                    },
                    error.MissingPythonExecutable => {
                        output.printError(alloc,
                            \\A required Python executable was not found or is not configured
                        , .{}) catch {};
                        output.printError(alloc,
                            \\Use 'zenv python install <version>' or configure 'fallback_python' in zenv.json
                        , .{}) catch {};
                    },
                    error.InvalidRegistryFormat => {
                        output.printError(alloc,
                            \\The registry file (ZENV_DIR/registry.json) is corrupted or has an invalid format
                        , .{}) catch {};
                    },
                    error.ConfigFileReadError => {
                        output.printError(alloc,
                            \\Error reading the configuration file '{s}'. Check permissions and file integrity
                        , .{config_path}) catch {};
                    },
                    error.HostnameParseError => {
                        output.printError(alloc,
                            \\Failed to parse the system hostname
                        , .{}) catch {};
                    },
                    error.IoError => {
                        output.printError(alloc,
                            \\An I/O error occurred. Check file system permissions and disk space
                        , .{}) catch {};
                    },
                    error.OutOfMemory => {
                        output.printError(alloc,
                            \\The application ran out of memory. Try freeing up system resources
                        , .{}) catch {};
                    },
                    error.PathTraversalAttempt => {
                        output.printError(alloc,
                            \\A path traversal attempt was detected and blocked for security reasons
                        , .{}) catch {};
                    },
                    error.EnvironmentVariableNotFound => {
                        output.printError(alloc,
                            \\A required environment variable was not found. Please ensure it is set
                        , .{}) catch {};
                    },
                    error.InvalidWtf8 => {
                        output.printError(alloc,
                            \\An environment variable contained invalid UTF-8 (WTF-8) characters
                        , .{}) catch {};
                    },
                    error.ProcessError => {
                        // For process errors, already handled by the process itself
                        process.exit(1); // Exit immediately to prevent stack trace
                    },
                    error.ModuleLoadError => {
                        // Module load errors are already handled by module loader
                        process.exit(1); // Exit immediately to prevent stack trace
                    },
                    error.EnvironmentAlreadyExists => {
                        output.printError(alloc,
                            \\An environment with that name already exists
                        , .{}) catch {};
                    },
                    error.InvalidEnvironmentName => {
                        output.printError(alloc,
                            \\Invalid environment name. Use only alphanumeric characters, hyphens, underscores, and dots
                        , .{}) catch {};
                    },
                    error.PathAlreadyExists => {
                        output.printError(alloc,
                            \\The target path already exists
                        , .{}) catch {};
                    },
                    error.InvalidPath => {
                        output.printError(alloc,
                            \\Invalid file or directory path
                        , .{}) catch {};
                    },
                    else => {
                        output.printError(alloc, "An unexpected error occurred: {s}", .{@errorName(err)}) catch {};
                        _ = trace; // error return trace is dumped by the std bootstrap on error
                    },
                }
            } else {
                // However, if it is, it means an error occurred without a return trace.
                output.printError(alloc, "Error: {s} (no trace available)", .{@errorName(err)}) catch {};
            }
            process.exit(1);
        }
    };

    // Load the environment registry first, as we'll need it for all commands
    var registry = configurations.EnvironmentRegistry.load(allocator) catch |err| {
        output.printError(allocator, "Failed to load environment registry: {s}", .{@errorName(err)}) catch {};
        handleError.func(allocator, error.RegistryError);
        return;
    };
    defer registry.deinit();

    // Parse configuration if we're in a project directory with zenv.json
    // We'll only need this for setup and registering new environments
    var config: ?configurations.ZenvConfig = null;
    defer if (config != null) config.?.deinit();

    // For setup command, check if we need to init first
    if (command == .setup) {
        // Check for --init flag
        const flags = flags_module.CommandFlags.fromArgs(args);
        const init_flag = flags.init_mode;

        if (init_flag) {
            // Check if config file already exists
            const config_exists = blk: {
                runtime.access(config_path) catch |err| {
                    if (err != error.FileNotFound) {
                        output.printError(allocator, "Accessing current directory: {s}", .{@errorName(err)}) catch {};
                        handleError.func(allocator, err);
                        break :blk false;
                    }
                    // File doesn't exist
                    break :blk false;
                };
                break :blk true;
            };

            if (!config_exists) {
                // Create init args
                var init_args = std.array_list.Managed([]const u8).init(allocator);
                defer init_args.deinit();

                try init_args.append("zenv"); // Args[0] is the program name
                try init_args.append("init");
                try init_args.append(args[2]); // Environment name

                // Add description if provided
                if (args.len > 3) {
                    try init_args.append(args[3]);
                }

                // Run init to create config
                output.print(allocator, "--init flag detected. Creating config file first...", .{}) catch {};
                commands.handleInitCommand(allocator, init_args.items);
                output.print(allocator, "Proceeding with setup...", .{}) catch {};
            }
        }

        // Now load the config with validation
        config = validation.validateAndParse(allocator, config_path) catch |err| {
            handleError.func(allocator, err);
            return; // Exit after handling error
        };
    } else if (command == .register) {
        config = validation.validateAndParse(allocator, config_path) catch |err| {
            handleError.func(allocator, err);
            return; // Exit after handling error
        };
    }

    // Dispatch to command handlers
    // Dispatch the command; any error it returns is mapped to a user-facing
    // message (and exits) by the single error handler.
    const config_ptr: ?*const configurations.ZenvConfig = if (config) |*c| c else null;
    dispatch(command, allocator, config_ptr, &registry, args, config_path) catch |err| handleError.func(allocator, err);
}

/// Routes a parsed command to its handler. Handlers return errors rather than
/// reporting them; `main` maps the error to a message in one place.
fn dispatch(
    command: Command,
    allocator: Allocator,
    config: ?*const configurations.ZenvConfig,
    registry: *configurations.EnvironmentRegistry,
    args: []const []const u8,
    config_path: []const u8,
) !void {
    switch (command) {
        .setup => try commands.handleSetupCommand(allocator, config.?, registry, args),
        .activate => try commands.handleActivateCommand(allocator, registry, args),
        .list => try commands.handleListCommand(allocator, registry, args),
        .register => try commands.handleRegisterCommand(allocator, config.?, registry, args),
        .deregister => try commands.handleDeregisterCommand(allocator, registry, args),
        .rm => try commands.handleRmCommand(allocator, registry, args),
        .rename => try commands.handleRenameCommand(allocator, registry, args),
        .cd => try commands.handleCdCommand(allocator, registry, args),
        .python => try commands.handlePythonCommand(allocator, args),
        .log => try commands.handleLogCommand(allocator, registry, args),
        .run => try commands.handleRunCommand(allocator, registry, args),
        .validate => try commands.handleValidateCommand(allocator, config_path, args),
        .alias => try commands.handleAliasCommand(allocator, registry, args),
        .jupyter => try commands.handleJupyterCommand(allocator, args),

        // These were handled before dispatch, unreachable here
        .help, .@"--help", .version, .@"-v", .@"-V", .@"--version", .init => unreachable,

        .unknown => {
            output.printError(allocator, "Unknown command '{s}'", .{args[1]}) catch {};
            output.print(allocator, "run 'zenv help' to see the usage", .{}) catch {};
            std.process.exit(1);
        },
    }
}
