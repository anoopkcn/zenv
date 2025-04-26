const std = @import("std");
const options = @import("options");
const process = std.process;
const errors = @import("errors.zig");
const ZenvError = errors.ZenvError;
const config_module = @import("config.zig");
const commands = @import("commands.zig");

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
        \\Usage: zenv <command>
        \\
        \\Commands:
        \\  setup [env_name]     Set up a virtual environment. If env_name is omitted,
        \\                       it will try to auto-detect based on hostname.
        \\  activate [env_name]  Print instructions to activate an environment. If env_name
        \\                       is omitted, it will try to auto-detect based on hostname.
        \\  list                 List existing environments that have been set up.
        \\  list --all           List all available environments from the config file.
        \\  version, -v, --version  Print the zenv version.
        \\  help                 Show this help message.
        \\
    ;
    std.io.getStdErr().writer().print("{s}", .{usage}) catch {};
}


pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);

    const command: Command = if (args.len < 2) .help else Command.fromString(args[1]);

    switch (command) {
        .help, .@"--help" => {
            printUsage();
            process.exit(0);
        },
        .version, .@"-v", .@"-V", .@"--version" => {
            printVersion();
            process.exit(0);
        },
        .setup, .activate, .list, .unknown => {},
    }

    const config_path = "zenv.json";

    const handleError = struct {
        pub fn func(err: anyerror) void {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Error: {s}\n", .{@errorName(err)}) catch {};
            switch (@as(ZenvError, @errorCast(err))) {
                ZenvError.ConfigFileNotFound => stderr.print(" -> Configuration file '{s}' not found.\n", .{config_path}) catch {},
                ZenvError.ClusterNotFound => stderr.print(" -> Target cluster doesn't match current hostname or config target mismatch.\n", .{}) catch {},
                ZenvError.EnvironmentNotFound => stderr.print(" -> Environment not found or auto-detection failed. Check name or specify explicitly.\n", .{}) catch {},
                ZenvError.JsonParseError => stderr.print(" -> Invalid JSON format in '{s}'. Check syntax.\n", .{config_path}) catch {},
                ZenvError.ConfigInvalid => stderr.print(" -> Invalid configuration structure in '{s}'. Check keys/types.\n", .{config_path}) catch {},
                ZenvError.ProcessError => stderr.print(" -> An external command failed. See output above for details.\n", .{}) catch {},
                ZenvError.MissingHostname => stderr.print(" -> HOSTNAME environment variable not set or inaccessible. Needed for cluster detection.\n", .{}) catch {},
                ZenvError.PathResolutionFailed => stderr.print(" -> Failed to resolve a required file path.\n", .{}) catch {},
                else => {
                    stderr.print(" -> Unexpected error details: {s}\n", .{@errorName(err)}) catch {};
                },
            }
            process.exit(1);
        }
    }.func;

    var config = config_module.ZenvConfig.parse(allocator, config_path) catch |err| {
         handleError(err);
         return;
    };
    defer config.deinit();

    switch (command) {
        .setup => commands.handleSetupCommand(allocator, &config, args, &handleError),
        .activate => commands.handleActivateCommand(allocator, &config, args, &handleError),
        .list => commands.handleListCommand(allocator, &config, args, &handleError),

        .help, .@"--help", .version, .@"-v", .@"-V", .@"--version" => unreachable,

        .unknown => {
            std.io.getStdErr().writer().print("Error: Unknown command '{s}'\n\n", .{args[1]}) catch {};
            printUsage();
            process.exit(1);
        },
    }
}
