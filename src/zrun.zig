const os_globals = @import("os_globals.zig");
const module_loader = @import("module_loader.zig");
const yaml_globals = @import("yaml_globals.zig");

pub const install = os_globals.install;
pub const RunCtx = os_globals.RunCtx;
pub const LoaderCtx = module_loader.LoaderCtx;
pub const loader = module_loader.loader;
/// Installs the `YAML` global (`YAML.parse`/`YAML.stringify`) -- a separate
/// call from `install` since it needs no io/args, only the interpreter.
pub const installYaml = yaml_globals.install;

test {
    _ = @import("os_globals.zig");
    _ = @import("module_loader.zig");
    _ = @import("yaml_globals.zig");
}
