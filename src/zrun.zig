const os_globals = @import("os_globals.zig");

pub const install = os_globals.install;
pub const RunCtx = os_globals.RunCtx;

test {
    _ = @import("os_globals.zig");
}
