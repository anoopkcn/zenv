const std = @import("std");
const process = std.process;
const Allocator = std.mem.Allocator;

const options = @import("options");
const commands = @import("commands.zig");
const configurations = @import("utils/config.zig");
const output = @import("utils/output.zig");

pub const Command = enum {
    setup,
    activate,
    list,
    register,
    deregister,
    cd,
    init,
    python,
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
            .{ "python", .python },
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

fn printVersion() !void {
    std.io.getStdOut().writer().print("{s}", .{options.version}) catch |err| {
        output.printError("Printing version: {s}", .{@errorName(err)}) catch {};
    };
}

fn printUsage() void {
    const usage = comptime 
        \\Usage: zenv <command> [environment_name|id] [options]
        \\
        \\Manages environments based on zenv.json configuration.
        \\
        \\Commands:
        \\  init                      Create a new zenv.json template file in the current directory.
        \\
        \\  setup <name>              Set up the specified environment based on zenv.json file.
        \\                            Creates a virtual environment in <base_dir>/<name>/.
        \\                            <base_dir> and <name> can be defined in the zenv.json file.
        \\
        \\  activate <name|id>        Output the path to the activation script.
        \\                            You can use the environment name or its ID (full or partial).
        \\                            To activate the environment, use:
        \\                            source $(zenv activate <name|id>)
        \\
        \\  cd <name|id>              Output the project directory path.
        \\                            You can use the environment name or its ID (full or partial).
        \\                            To change to the project directory, use:
        \\                            cd $(zenv cd <name|id>)
        \\
        \\  list                      List environments registered for the current machine.
        \\
        \\  list --all                List all registered environments.
        \\
        \\  register <name>           Register an environment in the global registry.
        \\                            Registers the current directory as the project directory.
        \\
        \\  deregister <name|id>      Remove an environment from the global registry.
        \\                            It does not remove the environment itself.
        \\
        \\  python <subcommand>       Python management commands:
        \\                            install <version>  :  Install a specified Python version.
        \\                            use <version>      :  pinn a python version.
        \\                            list               :  List all installed Python versions.
        \\
        \\  version, -v, --version    Print the zenv version.
        \\
        \\  help, --help              Show this help message.
        \\
        \\Options for setup:
        \\  --no-host                 Bypass hostname validation, this is equivalant to
        \\                            setting "target_machines": ["*"] in the zenv.json
        \\
        \\  --upgrade                 Attempt to upgrade the Python interpreter in an existing virtual
        \\                            environment. If the environment doesn't exist or is corrupted,
        \\                            it will be created fresh.
        \\
        \\  --python                  Use only the pinned Python set with 'use' subcommand.
        \\                            This ignores the default python priority list.
        \\                            Will error if no pinned Python is configured.
        \\
        \\  --dev                     Install the current directory as an editable package.
        \\                            Equivalent to running 'pip install --editable .'
        \\                            Requires a valid setup.py or pyproject.toml in the directory.
        \\
        \\  --force-deps              It tries to install all dependencies even if they are already
        \\                            provided by loaded modules.
        \\
        \\Configuration (zenv.json):
        \\  The 'zenv.json' file defines your environments. Environment names occupy top level
        \\  "base_dir": "path/to/venvs", is exceptional top level key-value which specifies the
        \\  base directory for for storing environments. The value can be a relative path,
        \\  relative to zenv.json OR an absolute path(if path starts with a /).
        \\
        \\Registry (ZENV_DIR/registry.json):
        \\  The global registry allows you to manage environments from any directory.
        \\  Setting up an environment will register that environment OR
        \\  register it with 'zenv register <name>'. Once registred one can activate
        \\  using 'source $(zenv activate <name|id>)' from any directory.
        \\
        \\Python Priority list
        \\  1. Module-provided Python (if HPC modules are loaded)
        \\  2. Explicitly configured 'fallback_python' from zenv.json (if not null)
        \\  3. zenv-managed pinned Python
        \\  4. System python3
        \\  5. System python
        \\  This prority list can be ignored with 'zenv setup <name> --python' which will use,
        \\  pinned python to manage the environement
        \\
    ;
    std.io.getStdOut().writer().print("{s}", .{usage}) catch {};
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Get args with ownership - we'll use these directly and cast as needed
    const args = try process.argsAlloc(allocator);
    // Defer freeing is moved lower to ensure args remain valid throughout execution

    // Command parsing logic - Use args directly for command parsing
    const command: Command = if (args.len < 2) .help else Command.fromString(args[1]);

    // Handle simple commands directly
    switch (command) {
        .help, .@"--help" => {
            printUsage();
            process.exit(0);
        },
        .version, .@"-v", .@"-V", .@"--version" => {
            try printVersion();
            process.exit(0);
        },
        .init => {
            // Handle init command directly to avoid loading config
            commands.handleInitCommand(allocator);
            process.exit(0);
        },
        // Let other commands proceed to config parsing
        .setup, .activate, .list, .register, .deregister, .cd, .python, .unknown => {},
    }

    const config_path = "zenv.json"; // Keep config path definition for backward compatibility

    const handleError = struct {
        pub fn func(err: anyerror) void {

            // Standard error handler
            if (@errorReturnTrace()) |trace| {
                output.printError("{s}", .{@errorName(err)}) catch {};

                // Handle specific errors
                switch (err) {
                    error.ConfigFileNotFound => {
                        output.printError(
                            \\Configuration file '{s}' not found
                        , .{config_path}) catch {};
                    },
                    error.FileNotFound => {
                        output.printError(
                            \\zenv could not find a file required to complete this command
                        , .{}) catch {};
                    },
                    error.ClusterNotFound => {
                        output.printError(
                            \\Target machine mismatch or environment not suitable for current machine
                        , .{}) catch {};
                    },
                    error.EnvironmentNotFound => {
                        output.printError(
                            \\Environment name not found in configuration or argument missing
                        , .{}) catch {};
                    },
                    error.JsonParseError => {
                        output.printError(
                            \\Invalid JSON format in '{s}'. Check syntax
                        , .{config_path}) catch {};
                    },
                    error.ConfigInvalid => {
                        output.printError(
                            \\Invalid configuration structure in '{s}'. Check keys/types/required fields
                        , .{config_path}) catch {};
                    },
                    error.MissingHostname => {
                        output.printError(
                            \\HOSTNAME is not set or inaccessible which is required for validation
                        , .{}) catch {};
                    },
                    error.PathResolutionFailed => {
                        output.printError(
                            \\Failed to resolve a required file path (e.g., requirements file)
                            \\
                        , .{}) catch {};
                    },
                    error.TargetMachineMismatch => {
                        output.printError(
                            \\Current machine does not match the target specified for this environment
                        , .{}) catch {};
                    },
                    error.AmbiguousIdentifier => {
                        output.printError(
                            \\The provided ID prefix matches multiple environments. Use more characters
                        , .{}) catch {};
                    },
                    error.RegistryError => {
                        output.printError(
                            \\Failed to access the environment registry. Check permissions for ZENV_DIR
                        , .{}) catch {};
                    },
                    error.ProcessError => {
                        // For process errors, don't show additional output
                        process.exit(1); // Exit immediately to prevent stack trace
                    },
                    error.ModuleLoadError => {
                        // Module load errors are handled specially with no stack trace
                        process.exit(1); // Exit immediately to prevent stack trace
                    },
                    else => {
                        output.printError("Unexpected error", .{}) catch {};
                        std.debug.dumpStackTrace(trace.*);
                    },
                }
            } else {
                output.printError("{s} (no trace available)", .{@errorName(err)}) catch {};
            }
            process.exit(1);
        }
    }.func;

    // Load the environment registry first, as we'll need it for all commands
    var registry = configurations.EnvironmentRegistry.load(allocator) catch |err| {
        output.printError("Failed to load environment registry: {s}", .{@errorName(err)}) catch {};
        handleError(error.RegistryError);
        return;
    };
    defer registry.deinit();

    // Parse configuration if we're in a project directory with zenv.json
    // We'll only need this for setup and registering new environments
    var config: ?configurations.ZenvConfig = null;
    defer if (config != null) config.?.deinit();

    // Only try to load the config file for setup and register commands
    if (command == .setup or command == .register) {
        config = configurations.parse(allocator, config_path) catch |err| {
            handleError(err);
            return; // Exit after handling error
        };
    }

    defer process.argsFree(allocator, args); // Defer freeing the original args

    // Dispatch to command handlers
    switch (command) {
        .setup => try commands.handleSetupCommand(allocator, &config.?, &registry, args, handleError),
        .activate => commands.handleActivateCommand(&registry, args, handleError),
        .list => commands.handleListCommand(allocator, &registry, args),
        .register => commands.handleRegisterCommand(allocator, &config.?, &registry, args, handleError),
        .deregister => commands.handleDeregisterCommand(&registry, args, handleError),
        .cd => commands.handleCdCommand(&registry, args, handleError),
        .python => try commands.handlePythonCommand(allocator, args, handleError),

        // These were handled above, unreachable here
        .help, .@"--help", .version, .@"-v", .@"-V", .@"--version", .init => unreachable,

        .unknown => {
            output.printError("Unknown command '{s}'", .{args[1]}) catch {};
            output.print("run 'zenv help' to see the usage", .{}) catch {};
            // printUsage();
            process.exit(1);
        },
    }
}
