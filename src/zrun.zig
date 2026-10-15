const std = @import("std");
const zvalue = @import("zvalue");
const os_globals = @import("os_globals.zig");
const module_loader = @import("module_loader.zig");
const yaml_globals = @import("yaml_globals.zig");
const toml_globals = @import("toml_globals.zig");
const crypto_globals = @import("crypto_globals.zig");
const args_globals = @import("args_globals.zig");
pub const payload = @import("payload.zig");
pub const compile_cmd = @import("compile_cmd.zig");
pub const cli_args = @import("cli_args.zig");

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
/// Attaches `os.argsParser` (z-args' `Simple` tier only) onto the
/// ALREADY-installed `os` global -- same contract as `installCrypto`.
pub const installArgsParser = args_globals.install;

/// Keep in sync with build.zig.zon's `.version` by hand -- no build-time
/// plumbing for a single string.
pub const version = "0.1.2";

/// Report a pending JS exception when present; otherwise classify the Zig
/// failure without turning resource or engine failures into SyntaxError.
pub fn printFailure(allocator: std.mem.Allocator, stderr: *std.Io.Writer, err: anyerror, pending_exception: ?zvalue.JSValue) !void {
    if (pending_exception) |ex| return printUncaught(allocator, stderr, ex);
    try stderr.print("{s}: {s}\n", .{ failureLabel(err), @errorName(err) });
}

fn failureLabel(err: anyerror) []const u8 {
    switch (err) {
        error.SyntaxError, error.ParseError => return "SyntaxError",
        error.OutOfMemory => return "Out of memory",
        error.IoError => return "I/O error",
        error.StepLimitExceeded => return "Execution step limit exceeded",
        error.UnsupportedFeature, error.NotImplemented => return "Unsupported feature",
        else => {},
    }
    // ParseError includes allocator failures: classify those above first.
    inline for (@typeInfo(@import("zfunctions").ParseError).error_set.error_names.?) |name| {
        if (std.mem.eql(u8, @errorName(err), name)) return "SyntaxError";
    }
    return "Engine error";
}

/// Formats an uncaught top-level exception the same way in every entry
/// point (script file, `-e`, REPL) so error output never drifts between
/// them.
pub fn printUncaught(allocator: std.mem.Allocator, stderr: *std.Io.Writer, ex: zvalue.JSValue) !void {
    switch (ex) {
        .@"error" => |box| try stderr.print("Uncaught {s}: {s}\n", .{ box.value.kind.name(), box.value.message }),
        .string => |box| try stderr.print("Uncaught '{s}'\n", .{box.value.data}),
        .number => |n| try stderr.print("Uncaught {d}\n", .{n}),
        else => {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            const zinterpreter = @import("zinterpreter");
            zinterpreter.inspect.inspect(allocator, &buf, ex) catch {
                try stderr.print("Uncaught [{s}]\n", .{ex.typeOf()});
                return;
            };
            try stderr.print("Uncaught {s}\n", .{buf.items});
        },
    }
}

test {
    _ = @import("os_globals.zig");
    _ = @import("module_loader.zig");
    _ = @import("yaml_globals.zig");
    _ = @import("toml_globals.zig");
    _ = @import("crypto_globals.zig");
    _ = @import("args_globals.zig");
}
