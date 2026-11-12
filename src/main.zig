const std = @import("std");
const builtin = @import("builtin");
const process = std.process;
const Io = std.Io;

const options = @import("options");
const commands = @import("commands.zig");
const envbuild = @import("envbuild.zig");
const Command = commands.Command;
const Registry = @import("Registry.zig");
const output = @import("output.zig");
const runtime = @import("runtime.zig");
const errors = @import("errors.zig");
const help = @import("help.zig");

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
    if (help.requested(command, args)) return help.printCommand(ctx.io, command);
    switch (command) {
        .help, .@"-h", .@"--help" => {
            if (args.len < 3) return help.printOverview(ctx.io);
            const topic = std.meta.stringToEnum(Command, args[2]) orelse {
                output.printError(ctx.io, "Unknown command '{s}'", .{args[2]});
                return error.ArgsError;
            };
            help.printCommand(ctx.io, topic);
        },
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
        .remove => try withRegistry(ctx, args, commands.handleRemove),
        .alias => try withRegistry(ctx, args, commands.handleAlias),
        .jupyter => try withRegistry(ctx, args, commands.handleJupyter),
        // Internal: run by zenv itself inside an env's container.
        .__build => try envbuild.runInside(ctx, if (args.len > 2) args[2] else return error.ArgsError),
        .__exec => try commands.handleExecInside(ctx, args),
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
