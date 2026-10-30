//! Test aggregator: referencing each module here pulls its inline `test`
//! blocks into the `zig build test` binary.

test {
    _ = @import("validation.zig");
    _ = @import("deps.zig");
    _ = @import("shell.zig");
    _ = @import("config.zig");
    _ = @import("Registry.zig");
    _ = @import("activation.zig");
    _ = @import("venv.zig");
    _ = @import("envbuild.zig");
    _ = @import("jupyter.zig");
    _ = @import("host.zig");
    _ = @import("paths.zig");
    _ = @import("cli.zig");
    _ = @import("manifest.zig");
    _ = @import("autosetup.zig");
    _ = @import("envspec.zig");
    _ = @import("output.zig");
    _ = @import("hook.zig");
    _ = @import("python.zig");
    _ = @import("commands.zig");
}
