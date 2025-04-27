const std = @import("std");
const options = @import("options");
const process = std.process;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const config_module = @import("config.zig");
const commands = @import("commands.zig");
const Allocator = std.mem.Allocator;


const Command = enum {
    setup,
    activate,
    list,
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
        \\Usage: zenv <command> [environment_name] [--all]
        \\
        \\Manages environments based on zenv.json configuration.
        \\
        \\Commands:
        \\  setup <env_name>       Set up the specified environment for the current machine.
        \\                         Creates a Python virtual environment in sc_venv/<env_name>/.
        \\                         Checks if current machine matches env_name's target_machine.
        \\  activate <env_name>    Print shell commands to activate the specified environment.
        \\                         Shows two options: using the activation script or manual steps.
        \\                         Checks if current machine matches env_name's target_machine.
        \\  list                   List environments configured for the current machine.
        \\  list --all             List all environments defined in the configuration file.
        \\  version, -v, --version Print the zenv version.
        \\  help, --help           Show this help message.
        \\
        \\Environment names (e.g., 'pytorch-gpu-jureca') are defined in zenv.json.
        \\
        \\To activate an environment after setup:
        \\  source /absolute/path/to/sc_venv/<env_name>/activate.sh
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
        // Let other commands proceed to config parsing
        .setup, .activate, .list, .unknown => {},
    }

    const config_path = "zenv.json"; // Keep config path definition

    const handleError = struct {
        pub fn func(err: anyerror) void {
            const stderr = std.io.getStdErr().writer();
            if (@errorReturnTrace()) |trace| {
                 switch (err) {
                     ZenvError.ConfigFileNotFound => {
                         stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                         stderr.print(" -> Configuration file '{s}' not found.\n", .{config_path}) catch {};
                     },
                     ZenvError.ClusterNotFound => {
                         stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                         stderr.print(" -> Target machine mismatch or environment not suitable for current machine.\n", .{}) catch {};
                     },
                     ZenvError.EnvironmentNotFound => {
                         stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                         stderr.print(" -> Environment name not found in configuration or argument missing.\n", .{}) catch {};
                     },
                     ZenvError.JsonParseError => {
                         stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                         stderr.print(" -> Invalid JSON format in '{s}'. Check syntax.\n", .{config_path}) catch {};
                     },
                     ZenvError.ConfigInvalid => {
                         stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                         stderr.print(" -> Invalid configuration structure in '{s}'. Check keys/types/required fields.\n", .{config_path}) catch {};
                     },
                     ZenvError.ProcessError => {
                         stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                         stderr.print(" -> An external command (module/pip/sh) failed. See output above for details.\n", .{}) catch {};
                     },
                     ZenvError.MissingHostname => {
                         stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                         stderr.print(" -> HOSTNAME environment variable not set or inaccessible. Needed for target machine check.\n", .{}) catch {};
                     },
                     ZenvError.PathResolutionFailed => {
                         stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                         stderr.print(" -> Failed to resolve a required file path (e.g., requirements file).\n", .{}) catch {};
                     },
                     else => {
                         stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
                         stderr.print(" -> Unexpected error.\n", .{}) catch {};
                         std.debug.dumpStackTrace(trace.*);
                     }
                 }
            } else {
                 stderr.print("Error: {s} (no trace available)\n", .{@errorName(err)}) catch {};
            }
            process.exit(1);
        }
    }.func;


    // Parse configuration
    var config = config_module.ZenvConfig.parse(allocator, config_path) catch |err| {
        handleError(err);
        return; // Exit after handling error
    };
    defer config.deinit(); // Ensure config memory is cleaned up

    defer process.argsFree(allocator, args_owned); // Defer freeing the original mutable args

    // Dispatch to command handlers (using args_const)
    switch (command) {
        .setup => try commands.handleSetupCommand(allocator, &config, args_const, handleError),
        .activate => commands.handleActivateCommand(allocator, &config, args_const, handleError),
        .list => commands.handleListCommand(allocator, &config, args_const, handleError),

        // These were handled above, unreachable here
        .help, .@"--help", .version, .@"-v", .@"-V", .@"--version" => unreachable,

        .unknown => {
             std.io.getStdErr().writer().print("Error: Unknown command '{s}'\n\n", .{args_const[1]}) catch {};
             printUsage();
             process.exit(1);
        },
    }
}
