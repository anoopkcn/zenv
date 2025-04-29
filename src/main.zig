const std = @import("std");
// Standard library components
const process = std.process;
const Allocator = std.mem.Allocator;

// Project specific imports
const options = @import("options");
const config_module = @import("utils/config.zig");
const commands = @import("commands.zig");

const Command = enum {
    setup,
    activate,
    list,
    register,
    deregister,
    cd,
    init,
    help,
    version,
    @"-v",
    @"-V",
    @"--version",
    @"--help",
    unknown,

    fn fromString(s: []const u8) Command {
        return std.meta.stringToEnum(Command, s) orelse Command.unknown;
    }
};

fn printVersion() void {
    std.io.getStdOut().writer().print("zenv version {s}\n", .{options.version}) catch |err| {
        std.log.err("Error printing version: {s}", .{@errorName(err)});
    };
}

fn printUsage() void {
    const usage = comptime
        \\Usage: zenv <command> [environment_name|id] [options]
        \\
        \\Manages environments based on zenv.json configuration.
        \\
        \\Configuration (zenv.json):
        \\  The zenv.json file defines your environments. It can optionally include:
        \\  "base_dir": "path/to/venvs"  (Optional, top-level string. Specifies the base directory
        \\                                for creating virtual environments. Can be relative to
        \\                                zenv.json location or an absolute path.
        \\                                Defaults to "zenv" if omitted.)
        \\
        \\Commands:
        \\  init                   Create a new zenv.json template file in the current directory.
        \\
        \\  setup <env_name>       Set up the specified environment for the current machine.
        \\                         Creates a Python virtual environment in <base_dir>/<env_name>/.
        \\                         Checks if current machine matches env_name's target_machine.
        \\
        \\  activate <env_name|id> Output the path to the activation script.
        \\                         You can use the environment name or its ID (full or partial).
        \\                         To activate the environment, use:
        \\                         source $(zenv activate <env_name|id>)
        \\
        \\  cd <env_name|id>       Output the project directory path.
        \\                         You can use the environment name or its ID (full or partial).
        \\                         To change to the project directory, use:
        \\                         cd $(zenv cd <env_name|id>)
        \\
        \\  list                   List environments registered for the current machine.
        \\  list --all             List all registered environments.
        \\
        \\  register <env_name>    Register an environment in the global registry.
        \\                         Registers the current directory as the project directory.
        \\  deregister <env_name>  Remove an environment from the global registry.
        \\
        \\  version, -v, --version Print the zenv version.
        \\
        \\  help, --help           Show this help message.
        \\
        \\Options:
        \\  --force-deps           When used with setup command, it tries to install all specified dependencies
        \\                         even if they are already provided by loaded modules.
        \\
        \\  --no-host              Bypass hostname validation and allow setup/register of an environment
        \\                         regardless of the target_machine specified in the configuration.
        \\                         Useful for portable environments or development machines.
        \\
        \\Registry:
        \\  The global registry (~/.zenv/registry.json) allows you to manage environments from any directory.
        \\  Setting up an environment will register that environment OR register it with 'zenv register <env_name>'.
        \\  Once registred one can activate it from anywhere with 'source $(zenv activate <env_name|id>)'.
        \\  Also the project directory can be 'cd' into from anywhere using 'source $(zenv cd <env_name|id>)'
        \\
    ;
    std.io.getStdErr().writer().print("{s}", .{usage}) catch {};
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Allocate args properly now for command handlers that might need ownership
    const args_owned = try process.argsAlloc(allocator);
    // Defer freeing args_owned *after* potential early exits and config parsing
    // defer process.argsFree(allocator, args_owned); // Moved lower

    // Convert [][]u8 to [][]const u8
    const args_const = try allocator.alloc([]const u8, args_owned.len);
    for (args_owned, 0..) |arg, i| {
        args_const[i] = arg; // Implicit cast from []u8 to []const u8 happens here
    }
    // No need to free args_const separately, it uses the arena allocator

    // Command parsing logic - Use args_const for reading, args_owned for potential modification/freeing later
    const command: Command = if (args_const.len < 2) .help else Command.fromString(args_const[1]);

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
            commands.handleInitCommand(allocator);
            process.exit(0);
        },
        // Let other commands proceed to config parsing
        .setup, .activate, .list, .register, .deregister, .cd, .unknown => {},
    }

    const config_path = "zenv.json"; // Keep config path definition for backward compatibility

    const handleError = struct {
        pub fn func(err: anyerror) void {
            const stderr = std.io.getStdErr().writer();

            // Standard error handler
            if (@errorReturnTrace()) |trace| {
                switch (err) {
                    error.ConfigFileNotFound => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> Configuration file '{s}' not found.\n", .{config_path}) catch {};
                    },
                    error.FileNotFound => {
                       stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                    },
                    error.ClusterNotFound => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> Target machine mismatch or environment not suitable for current machine.\n", .{}) catch {};
                    },
                    error.EnvironmentNotFound => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> Environment name not found in configuration or argument missing.\n", .{}) catch {};
                    },
                    error.JsonParseError => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> Invalid JSON format in '{s}'. Check syntax.\n", .{config_path}) catch {};
                    },
                    error.ConfigInvalid => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> Invalid configuration structure in '{s}'. Check keys/types/required fields.\n", .{config_path}) catch {};
                    },
                    error.ProcessError => {
                        // For process errors, don't show any additional output
                        // as the actual error output should have already been displayed
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        process.exit(1); // Exit immediately to prevent stack trace
                    },
                    error.ModuleLoadError => {
                        // Module load errors are handled specially with no stack trace
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        process.exit(1); // Exit immediately to prevent stack trace
                    },
                    error.MissingHostname => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> HOSTNAME environment variable not set or inaccessible. Needed for target machine check.\n", .{}) catch {};
                    },
                    error.PathResolutionFailed => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> Failed to resolve a required file path (e.g., requirements file).\n", .{}) catch {};
                    },
                    error.TargetMachineMismatch => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> Current machine does not match the target_machine specified for this environment.\n", .{}) catch {};
                    },
                    error.AmbiguousIdentifier => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> The provided ID prefix matches multiple environments. Please use more characters.\n", .{}) catch {};
                    },
                    error.RegistryError => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> Failed to access the environment registry. Check permissions for ~/.zenv directory.\n", .{}) catch {};
                    },
                    else => {
                        stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                        stderr.print(" -> Unexpected error.\n", .{}) catch {};
                        std.debug.dumpStackTrace(trace.*);
                    },
                }
            } else {
                stderr.print("Error: {s} (no trace available)\n", .{@errorName(err)}) catch {};
            }
            process.exit(1);
        }
    }.func;

    // Load the environment registry first, as we'll need it for all commands
    var registry = config_module.EnvironmentRegistry.load(allocator) catch |err| {
        std.log.err("Failed to load environment registry: {s}", .{@errorName(err)});
        handleError(error.RegistryError);
        return;
    };
    defer registry.deinit();

    // Parse configuration if we're in a project directory with zenv.json
    // We'll only need this for setup and registering new environments
    var config: ?config_module.ZenvConfig = null;
    defer if (config != null) config.?.deinit();

    // Only try to load the config file for setup and register commands
    if (command == .setup or command == .register) {
        config = config_module.ZenvConfig.parse(allocator, config_path) catch |err| {
            handleError(err);
            return; // Exit after handling error
        };
    }

    defer process.argsFree(allocator, args_owned); // Defer freeing the original mutable args

    // Dispatch to command handlers
    switch (command) {
        .setup => try commands.handleSetupCommand(allocator, &config.?, &registry, args_const, handleError),
        .activate => commands.handleActivateCommand(&registry, args_const, handleError),
        .list => commands.handleListCommand(allocator, &registry, args_const),
        .register => commands.handleRegisterCommand(allocator, &registry, args_const, handleError), // Removed config param
        .deregister => commands.handleDeregisterCommand(&registry, args_const, handleError),
        .cd => commands.handleCdCommand(&registry, args_const, handleError),

        // These were handled above, unreachable here
        .help, .@"--help", .version, .@"-v", .@"-V", .@"--version", .init => unreachable,

        .unknown => {
            std.io.getStdErr().writer().print("Error: Unknown command '{s}'\n\n", .{args_const[1]}) catch {};
            printUsage();
            process.exit(1);
        },
    }
}
