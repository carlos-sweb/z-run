//! The `TOML` global -- a z-run host binding (like `os`/`YAML`), NOT part
//! of z-interpreter's core: TOML isn't ECMA-262, so it doesn't belong in
//! the engine. Backed by z-toml, a pure-Zig subset parser/stringifier
//! over JSValue (see its README for the exact scope: tables, arrays of
//! tables, dotted keys, inline tables, single-line strings, int/float/
//! bool -- no multi-line strings, no native date-time typing).
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const ztoml = if (build_options.enable_toml) @import("ztoml") else void;
const JSValue = zvalue.JSValue;
const Interpreter = zinterpreter.Interpreter;

/// Installs the `TOML` global: `TOML.parse(str)` / `TOML.stringify(value)`.
/// Call before the first `run()` (same contract as `os_globals.install`).
/// A no-op when `-Dtoml=false`.
pub fn install(interpreter: *Interpreter) !void {
    if (comptime !build_options.enable_toml) return;

    const arena = interpreter.arena_state.allocator();

    var toml_obj = try JSValue.newObject(arena);
    try toml_obj.object.value.set("parse", try native(arena, interpreter, "parse", tomlParse));
    try toml_obj.object.value.set("stringify", try native(arena, interpreter, "stringify", tomlStringify));

    try interpreter.defineGlobal("TOML", toml_obj);
}

const NativeFn = *const fn (ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue;

fn native(arena: Allocator, interpreter: *Interpreter, name: []const u8, call_fn: NativeFn) !JSValue {
    return JSValue.newFunction(arena, .{ .ctx = interpreter, .name = name, .call = call_fn });
}

fn interp(ctx: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(ctx));
}

fn arg(args: []const JSValue, i: usize) JSValue {
    return if (i < args.len) args[i] else JSValue.UNDEFINED;
}

/// `TOML.parse(text)`: any parse failure becomes a catchable SyntaxError
/// naming the underlying reason (the same shape JSON.parse's/YAML.parse's
/// error mapping uses).
fn tomlParse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const text = arg(args, 0);
    if (text != .string) return self.throwError(.syntax_error, "TOML.parse requires a string", .{});
    const value = ztoml.parse(allocator, text.string.value.data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.throwError(.syntax_error, "Unexpected token in TOML: {t}", .{err}),
    };
    // ztoml.parse builds the tree via z-value's raw constructors, bypassing
    // gcNew*/gcTrack at every level -- see Interpreter.gcAdoptTree's doc
    // comment (same gap JSON.parse/YAML.parse had).
    try self.gcAdoptTree(value);
    return value;
}

/// `TOML.stringify(value)`: table-and-sections TOML output.
fn tomlStringify(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const out = ztoml.stringify(allocator, arg(args, 0)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.throwError(.type_error, "Cannot stringify value to TOML: {t}", .{err}),
    };
    defer allocator.free(out);
    return self.gcNewString(out);
}
