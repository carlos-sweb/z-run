//! z-run's module loader: resolves RELATIVE specifiers (`./x.js`,
//! `../y.js`) against the referrer's directory (pure string work via
//! std.fs.path -- no Io involved in resolution) and reads sources
//! through the host's std.Io. Bare specifiers ('lodash') are not
//! resolved -- there is no node_modules algorithm here (documented).
const std = @import("std");
const Allocator = std.mem.Allocator;
const zinterpreter = @import("zinterpreter");

pub const LoaderCtx = struct {
    io: std.Io,
};

const max_module_bytes: std.Io.Limit = .limited(64 * 1024 * 1024);

pub fn loader(ctx: *LoaderCtx) zinterpreter.ModuleLoader {
    return .{ .ctx = ctx, .load = load };
}

fn load(ctx: *anyopaque, arena: Allocator, specifier: []const u8, referrer: ?[]const u8) anyerror!?zinterpreter.LoadedModule {
    const lc: *LoaderCtx = @ptrCast(@alignCast(ctx));

    const resolved = blk: {
        if (std.fs.path.isAbsolute(specifier)) {
            break :blk try arena.dupe(u8, specifier);
        }
        const is_relative = std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
        // Bare specifiers only make sense for the entry (a plain
        // `z-run foo.js` from the cwd); imports must be relative.
        if (!is_relative and referrer != null) return null;
        const base = if (referrer) |r| std.fs.path.dirname(r) orelse "." else ".";
        break :blk try std.fs.path.resolve(arena, &.{ base, specifier });
    };

    const source = std.Io.Dir.cwd().readFileAlloc(lc.io, resolved, arena, max_module_bytes) catch return null;
    return .{ .path = resolved, .source = source };
}
