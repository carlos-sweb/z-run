//! The `os` global -- z-run's host bindings, QuickJS-libc-style: the
//! engine (z-interpreter) knows nothing about files; this module installs
//! a plain `os` object (like `console`/`Math`) whose natives do
//! synchronous file I/O through the host's `std.Io` instance. Async fs /
//! timers / the event loop arrive with Etapa C and will live here too.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const Interpreter = zinterpreter.Interpreter;

/// Shared ctx for every `os.*` native. Arena-allocated by `install`, so
/// its address is stable for the interpreter's lifetime.
pub const RunCtx = struct {
    interp: *Interpreter,
    io: std.Io,
};

/// Refuse to slurp files past this size rather than OOM (matches the
/// spirit of quickjs-libc's bounded loads). 256 MiB.
const max_file_bytes: std.Io.Limit = .limited(256 * 1024 * 1024);

/// Installs the `os` global: `readFile`/`writeFile` (synchronous),
/// `args` (script arguments as an array of strings), `exit(code)`.
/// Call before the first `run()`.
pub fn install(interp: *Interpreter, io: std.Io, args: []const []const u8) !void {
    const arena = interp.arena_state.allocator();

    const ctx = try arena.create(RunCtx);
    ctx.* = .{ .interp = interp, .io = io };

    var os_obj = try JSValue.newObject(arena);
    try os_obj.object.value.set("readFile", try native(arena, ctx, "readFile", osReadFile));
    try os_obj.object.value.set("writeFile", try native(arena, ctx, "writeFile", osWriteFile));
    try os_obj.object.value.set("exit", try native(arena, ctx, "exit", osExit));

    var args_arr = try JSValue.newArray(arena);
    for (args) |a| {
        _ = try args_arr.array.value.push(try JSValue.newString(arena, a));
    }
    try os_obj.object.value.set("args", args_arr);

    try interp.defineGlobal("os", os_obj);
}

const NativeFn = *const fn (ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue;

fn native(arena: Allocator, ctx: *RunCtx, name: []const u8, call_fn: NativeFn) !JSValue {
    return JSValue.newFunction(arena, .{ .ctx = ctx, .name = name, .call = call_fn });
}

fn runCtx(ctx: *anyopaque) *RunCtx {
    return @ptrCast(@alignCast(ctx));
}

fn arg(args: []const JSValue, i: usize) JSValue {
    return if (i < args.len) args[i] else JSValue.UNDEFINED;
}

/// The one string-argument rule every fs native shares: a non-string
/// path/content is a catchable TypeError, not a coercion (narrow and
/// explicit beats silently stringifying an object into a filename).
fn requireString(rc: *RunCtx, v: JSValue, what: []const u8) anyerror![]const u8 {
    if (v != .string) return rc.interp.throwError(.type_error, "{s} must be a string", .{what});
    return v.string.value.data;
}

fn osReadFile(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const rc = runCtx(ctx);
    const path = try requireString(rc, arg(args, 0), "path");
    const bytes = std.Io.Dir.cwd().readFileAlloc(rc.io, path, allocator, max_file_bytes) catch |err| {
        // Node-flavored message ("ENOENT: no such file or directory,
        // open 'x'") built from the Zig error name -- catchable in JS.
        return rc.interp.throwError(.generic, "{s}: cannot read file, open '{s}'", .{ @errorName(err), path });
    };
    defer allocator.free(bytes);
    return JSValue.newString(allocator, bytes);
}

fn osWriteFile(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const rc = runCtx(ctx);
    const path = try requireString(rc, arg(args, 0), "path");
    const contents = try requireString(rc, arg(args, 1), "contents");
    std.Io.Dir.cwd().writeFile(rc.io, .{ .sub_path = path, .data = contents }) catch |err| {
        return rc.interp.throwError(.generic, "{s}: cannot write file, open '{s}'", .{ @errorName(err), path });
    };
    return JSValue.UNDEFINED;
}

fn osExit(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = ctx;
    const code: u8 = switch (arg(args, 0)) {
        .number => |n| if (n >= 0 and n <= 255) @intFromFloat(n) else 1,
        .@"undefined" => 0,
        else => 1,
    };
    std.process.exit(code);
}
