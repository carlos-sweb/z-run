const std = @import("std");
const zvalue = @import("zvalue");
const os_globals = @import("os_globals.zig");
const module_loader = @import("module_loader.zig");
const yaml_globals = @import("yaml_globals.zig");
const toml_globals = @import("toml_globals.zig");
const crypto_globals = @import("crypto_globals.zig");

pub const install = os_globals.install;
pub const RunCtx = os_globals.RunCtx;
pub const LoaderCtx = module_loader.LoaderCtx;
pub const loader = module_loader.loader;
/// Installs the `YAML` global (`YAML.parse`/`YAML.stringify`) -- a separate
/// call from `install` since it needs no io/args, only the interpreter.
pub const installYaml = yaml_globals.install;
/// Installs the `TOML` global (`TOML.parse`/`TOML.stringify`) -- same
/// contract as `installYaml`.
pub const installToml = toml_globals.install;
/// Attaches `os.crypto` (`uuid`/`random`/`hash`/`hmac`/`aead`/`password`)
/// onto the ALREADY-installed `os` global -- call after `install`, not
/// standalone (unlike `installYaml`/`installToml`, which add their own
/// top-level globals and don't depend on `os` existing yet).
pub const installCrypto = crypto_globals.install;

/// Keep in sync with build.zig.zon's `.version` by hand -- no build-time
/// plumbing for a single string.
pub const version = "0.1.0";

/// Formats an uncaught top-level exception the same way in every entry
/// point (script file, `-e`, REPL) so error output never drifts between
/// them.
pub fn printUncaught(stderr: *std.Io.Writer, ex: zvalue.JSValue) !void {
    switch (ex) {
        .@"error" => |box| try stderr.print("Uncaught {s}: {s}\n", .{ box.value.kind.name(), box.value.message }),
        .string => |box| try stderr.print("Uncaught '{s}'\n", .{box.value.data}),
        .number => |n| try stderr.print("Uncaught {d}\n", .{n}),
        else => try stderr.print("Uncaught [{s}]\n", .{ex.typeOf()}),
    }
}

test {
    _ = @import("os_globals.zig");
    _ = @import("module_loader.zig");
    _ = @import("yaml_globals.zig");
    _ = @import("toml_globals.zig");
    _ = @import("crypto_globals.zig");
}
