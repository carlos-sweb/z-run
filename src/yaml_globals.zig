//! The `YAML` global -- a z-run host binding (like `os`), NOT part of
//! z-interpreter's core: YAML isn't ECMA-262, so it doesn't belong in the
//! engine, the same reasoning that keeps `os` here. Backed by z-yaml, a
//! pure-Zig subset parser/stringifier over JSValue (see its README for the
//! exact scope: block/flow mappings+sequences, plain/quoted scalars, core
//! implicit typing -- no anchors/aliases/tags/block-scalars/multi-doc).
const std = @import("std");
const Allocator = std.mem.Allocator;
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const zyaml = @import("zyaml");
const JSValue = zvalue.JSValue;
const Interpreter = zinterpreter.Interpreter;

/// Installs the `YAML` global: `YAML.parse(str)` / `YAML.stringify(value)`.
/// Call before the first `run()` (same contract as `os_globals.install`).
pub fn install(interpreter: *Interpreter) !void {
    const arena = interpreter.arena_state.allocator();

    var yaml_obj = try JSValue.newObject(arena);
    try yaml_obj.object.value.set("parse", try native(arena, interpreter, "parse", yamlParse));
    try yaml_obj.object.value.set("stringify", try native(arena, interpreter, "stringify", yamlStringify));

    try interpreter.defineGlobal("YAML", yaml_obj);
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

/// `YAML.parse(text)`: any parse failure becomes a catchable SyntaxError
/// naming the underlying reason (the same shape JSON.parse's error
/// mapping uses in z-interpreter, applied here since YAML lives outside
/// the engine core).
fn yamlParse(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const text = arg(args, 0);
    if (text != .string) return self.throwError(.syntax_error, "YAML.parse requires a string", .{});
    return zyaml.parse(allocator, text.string.value.data) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => self.throwError(.syntax_error, "Unexpected token in YAML: {t}", .{err}),
    };
}

/// `YAML.stringify(value)`: block-style YAML output.
fn yamlStringify(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const out = zyaml.stringify(allocator, arg(args, 0)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.throwError(.type_error, "Cannot stringify value to YAML: {t}", .{err}),
    };
    defer allocator.free(out);
    return JSValue.newString(allocator, out);
}
