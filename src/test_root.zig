//! Test aggregator: referencing each module here pulls its inline `test`
//! blocks into the `zig build test` binary.

test {
    _ = @import("utils/validation.zig");
    _ = @import("utils/parse_deps.zig");
    _ = @import("utils/template.zig");
    _ = @import("utils/config.zig");
    _ = @import("utils/template_activate.zig");
    _ = @import("utils/environment.zig");
    _ = @import("utils/jupyter.zig");
    _ = @import("utils/auxiliary.zig");
    _ = @import("commands.zig");
}
