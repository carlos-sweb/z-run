const os_globals = @import("os_globals.zig");
const module_loader = @import("module_loader.zig");

pub const install = os_globals.install;
pub const RunCtx = os_globals.RunCtx;
pub const LoaderCtx = module_loader.LoaderCtx;
pub const loader = module_loader.loader;

test {
    _ = @import("os_globals.zig");
    _ = @import("module_loader.zig");
}
