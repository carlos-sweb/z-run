//! The `os.argsParser` namespace -- z-run's binding onto z-args' `Simple`
//! tier only (POSIX/GNU `getopt_long`-style tokenizer). Like `crypto`,
//! this is a PROPERTY of the already-installed `os` object, not its own
//! top-level global. Call `install` after `os_globals.install`.
//!
//! `Builder`/`Declarative`/`Commands` (z-args' other three tiers) are
//! deliberately NOT bound here: `Declarative.parseStruct` needs a Zig
//! type known at compile time, which a JS script can never supply (a
//! `JSValue` only exists at runtime -- not a missing feature, a hard
//! Zig-language boundary). `Commands`' `action` needs a native `*const
//! fn`, not a JS callback. `Builder` COULD be bound, but its natural
//! shape is a stateful object (`addFlag`/`addOption` across several
//! calls, then `parse`) -- z-run has no "native object with persistent
//! Zig state" pattern yet, and adding one is out of scope for this pass.
//! `Simple.Parser` has no such problem: it's a plain data struct over
//! borrowed slices (no allocations, nothing to leak), so draining it
//! into a JS array of tokens in one native call captures its whole
//! contract with zero redesign.
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const zargs = if (build_options.enable_args) @import("zargs") else void;
const JSValue = zvalue.JSValue;
const Interpreter = zinterpreter.Interpreter;

/// A no-op when `-Dargs=false`.
pub fn install(interp: *Interpreter) !void {
    if (comptime !build_options.enable_args) return;

    const arena = interp.arena_state.allocator();
    const os_val = interp.global_env.get("os") orelse return error.OsGlobalMissing;

    var args_parser_obj = try JSValue.newObject(arena);
    try args_parser_obj.object.value.set("simple", try native(arena, interp, "simple", argsSimple));
    try os_val.object.value.set("argsParser", args_parser_obj);
}

const NativeFn = *const fn (ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue;

fn native(arena: Allocator, interp: *Interpreter, name: []const u8, call_fn: NativeFn) !JSValue {
    return JSValue.newFunction(arena, .{ .ctx = interp, .name = name, .call = call_fn });
}

fn interpFromCtx(ctx: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(ctx));
}

fn arg(args: []const JSValue, i: usize) JSValue {
    return if (i < args.len) args[i] else JSValue.UNDEFINED;
}

/// `os.argsParser.simple(argv, specs)` -- drains a z-args `Simple.Parser`
/// over `argv` into a JS array of tagged token objects. Each token has a
/// `type` (`"flag"`/`"option"`/`"positional"`/`"unknownOption"`/
/// `"missingValue"`/`"unexpectedValue"`) plus whichever of `short`/
/// `long`/`value` that variant actually carries -- an absent field is
/// left unset, so it reads as `undefined` in JS rather than `null`.
fn argsSimple(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const interp = interpFromCtx(ctx);

    const argv_val = arg(args, 0);
    if (argv_val != .array) return interp.throwError(.type_error, "argv must be an array of strings", .{});
    const specs_val = arg(args, 1);
    if (specs_val != .array) return interp.throwError(.type_error, "specs must be an array", .{});

    const argv = try coerceArgv(interp, allocator, argv_val);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }
    const specs = try coerceSpecs(interp, allocator, specs_val);
    defer allocator.free(specs);

    var parser = zargs.Simple.Parser.init(argv, specs);
    var tokens = try interp.gcNewArray();
    while (true) {
        const tok = parser.next();
        if (tok == .end) break;
        _ = try tokens.array.value.push(try tokenToJSValue(interp, tok));
    }
    return tokens;
}

fn coerceArgv(interp: *Interpreter, allocator: Allocator, argv_val: JSValue) anyerror![]const [:0]const u8 {
    const items = argv_val.array.value.toSlice();
    const out = try allocator.alloc([:0]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |a| allocator.free(a);
        allocator.free(out);
    }
    for (items, 0..) |item, i| {
        if (item != .string) return interp.throwError(.type_error, "argv must contain only strings", .{});
        out[i] = try allocator.dupeZ(u8, item.string.value.data);
        filled = i + 1;
    }
    return out;
}

fn coerceSpecs(interp: *Interpreter, allocator: Allocator, specs_val: JSValue) anyerror![]const zargs.Simple.OptionSpec {
    const items = specs_val.array.value.toSlice();
    const out = try allocator.alloc(zargs.Simple.OptionSpec, items.len);
    errdefer allocator.free(out);

    for (items, 0..) |item, i| {
        if (item != .object) return interp.throwError(.type_error, "each spec must be an object", .{});
        const obj = item.object.value;
        var spec: zargs.Simple.OptionSpec = .{};

        const short_val = obj.get("short") orelse JSValue.UNDEFINED;
        if (short_val == .string) {
            if (short_val.string.value.data.len != 1) return interp.throwError(.range_error, "spec.short must be a single character", .{});
            spec.short = short_val.string.value.data[0];
        } else if (short_val != .undefined) {
            return interp.throwError(.type_error, "spec.short must be a one-character string", .{});
        }

        const long_val = obj.get("long") orelse JSValue.UNDEFINED;
        if (long_val == .string) {
            spec.long = long_val.string.value.data;
        } else if (long_val != .undefined) {
            return interp.throwError(.type_error, "spec.long must be a string", .{});
        }

        if (spec.short == null and spec.long == null) {
            return interp.throwError(.type_error, "spec needs at least one of short/long", .{});
        }

        const kind_val = obj.get("kind") orelse JSValue.UNDEFINED;
        if (kind_val == .string) {
            if (std.mem.eql(u8, kind_val.string.value.data, "value")) {
                spec.kind = .value;
            } else if (std.mem.eql(u8, kind_val.string.value.data, "flag")) {
                spec.kind = .flag;
            } else {
                return interp.throwError(.range_error, "spec.kind must be \"flag\" or \"value\"", .{});
            }
        } else if (kind_val != .undefined) {
            return interp.throwError(.type_error, "spec.kind must be a string", .{});
        }

        out[i] = spec;
    }
    return out;
}

fn tokenToJSValue(interp: *Interpreter, tok: zargs.Simple.Token) anyerror!JSValue {
    var obj = try interp.gcNewObject();
    switch (tok) {
        .flag => |f| {
            try obj.object.value.set("type", try interp.gcNewString("flag"));
            try setOptChar(interp, obj, "short", f.short);
            try setOptStr(interp, obj, "long", f.long);
        },
        .option => |o| {
            try obj.object.value.set("type", try interp.gcNewString("option"));
            try setOptChar(interp, obj, "short", o.short);
            try setOptStr(interp, obj, "long", o.long);
            try obj.object.value.set("value", try interp.gcNewString(o.value));
        },
        .positional => |p| {
            try obj.object.value.set("type", try interp.gcNewString("positional"));
            try obj.object.value.set("value", try interp.gcNewString(p));
        },
        .unknown_option => |u| {
            try obj.object.value.set("type", try interp.gcNewString("unknownOption"));
            try setOptChar(interp, obj, "short", u.short);
            try setOptStr(interp, obj, "long", u.long);
        },
        .missing_value => |m| {
            try obj.object.value.set("type", try interp.gcNewString("missingValue"));
            try setOptChar(interp, obj, "short", m.short);
            try setOptStr(interp, obj, "long", m.long);
        },
        .unexpected_value => |uv| {
            try obj.object.value.set("type", try interp.gcNewString("unexpectedValue"));
            try setOptChar(interp, obj, "short", uv.short);
            try setOptStr(interp, obj, "long", uv.long);
            try obj.object.value.set("value", try interp.gcNewString(uv.value));
        },
        .end => unreachable,
    }
    return obj;
}

fn setOptChar(interp: *Interpreter, obj: JSValue, key: []const u8, v: ?u8) !void {
    if (v) |c| try obj.object.value.set(key, try interp.gcNewString(&[_]u8{c}));
}

fn setOptStr(interp: *Interpreter, obj: JSValue, key: []const u8, v: ?[]const u8) !void {
    if (v) |s| try obj.object.value.set(key, try interp.gcNewString(s));
}
