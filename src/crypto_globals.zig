//! The `os.crypto` namespace -- z-run's binding onto `z-uuid`/`z-crypto`.
//! Unlike `YAML`/`TOML` (their own top-level globals), `crypto` is a
//! PROPERTY of the already-installed `os` object, so this module doesn't
//! call `defineGlobal` itself: it looks the live `os` object back up via
//! `interp.global_env.get("os")` and attaches `crypto` onto it. Call
//! `install` after `os_globals.install` has already run.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const zuuid = @import("zuuid");
const zcrypto = @import("zcrypto");
const JSValue = zvalue.JSValue;
const Interpreter = zinterpreter.Interpreter;
const RunCtx = @import("os_globals.zig").RunCtx;

pub fn install(interp: *Interpreter, io: std.Io) !void {
    const arena = interp.arena_state.allocator();

    const ctx = try arena.create(RunCtx);
    ctx.* = .{ .interp = interp, .io = io };

    const os_val = interp.global_env.get("os") orelse return error.OsGlobalMissing;

    var uuid_obj = try JSValue.newObject(arena);
    try uuid_obj.object.value.set("v4", try native(arena, ctx, "v4", uuidV4));
    try uuid_obj.object.value.set("v7", try native(arena, ctx, "v7", uuidV7));

    var random_obj = try JSValue.newObject(arena);
    try random_obj.object.value.set("bytes", try native(arena, ctx, "bytes", randomBytes));
    try random_obj.object.value.set("int", try native(arena, ctx, "int", randomIntFn));
    try random_obj.object.value.set("string", try native(arena, ctx, "string", randomStringFn));

    var hash_obj = try JSValue.newObject(arena);
    try hash_obj.object.value.set("sha256", try native(arena, ctx, "sha256", makeHashFn(.sha256)));
    try hash_obj.object.value.set("sha512", try native(arena, ctx, "sha512", makeHashFn(.sha512)));
    try hash_obj.object.value.set("blake3", try native(arena, ctx, "blake3", makeHashFn(.blake3)));

    var hmac_obj = try JSValue.newObject(arena);
    try hmac_obj.object.value.set("sha256", try native(arena, ctx, "sha256", hmacSha256Fn));
    try hmac_obj.object.value.set("sha512", try native(arena, ctx, "sha512", hmacSha512Fn));

    var aead_obj = try JSValue.newObject(arena);
    try aead_obj.object.value.set("encrypt", try native(arena, ctx, "encrypt", aeadEncrypt));
    try aead_obj.object.value.set("decrypt", try native(arena, ctx, "decrypt", aeadDecrypt));

    var password_obj = try JSValue.newObject(arena);
    try password_obj.object.value.set("hash", try native(arena, ctx, "hash", passwordHash));
    try password_obj.object.value.set("verify", try native(arena, ctx, "verify", passwordVerify));

    var crypto_obj = try JSValue.newObject(arena);
    try crypto_obj.object.value.set("uuid", uuid_obj);
    try crypto_obj.object.value.set("random", random_obj);
    try crypto_obj.object.value.set("hash", hash_obj);
    try crypto_obj.object.value.set("hmac", hmac_obj);
    try crypto_obj.object.value.set("aead", aead_obj);
    try crypto_obj.object.value.set("password", password_obj);

    try os_val.object.value.set("crypto", crypto_obj);
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

/// Accepts a JS string (UTF-8 bytes) or any TypedArray view (raw bytes)
/// -- the same "bytes-like" input real crypto APIs accept.
fn coerceBytes(rc: *RunCtx, v: JSValue, what: []const u8) anyerror![]const u8 {
    return switch (v) {
        .string => |box| box.value.data,
        .typed_array => |box| blk: {
            const ta = box.value;
            const buf_bytes = ta.owner.array_buffer.value.bytes;
            const byte_len = ta.len * ta.kind.elemSize();
            break :blk buf_bytes[ta.byte_offset..][0..byte_len];
        },
        else => rc.interp.throwError(.type_error, "{s} must be a string or TypedArray", .{what}),
    };
}

fn requireInteger(rc: *RunCtx, v: JSValue, what: []const u8) anyerror!i64 {
    if (v != .number) return rc.interp.throwError(.type_error, "{s} must be a number", .{what});
    const n = v.number;
    if (!std.math.isFinite(n) or n != @trunc(n)) {
        return rc.interp.throwError(.type_error, "{s} must be an integer", .{what});
    }
    return @intFromFloat(n);
}

/// Copies `bytes` into a fresh `ArrayBuffer` and wraps it as a `Uint8Array`.
fn bytesToUint8Array(rc: *RunCtx, bytes: []const u8) !JSValue {
    const buf_val = try rc.interp.gcNewArrayBuffer(bytes.len);
    @memcpy(buf_val.array_buffer.value.bytes, bytes);
    return rc.interp.gcNewTypedArray(buf_val.retain(), 0, bytes.len, .u8);
}

fn uuidV4(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    const rc = runCtx(ctx);
    const source: std.Random.IoSource = .{ .io = rc.io };
    const id = zuuid.Uuid.v4(source.interface());
    var buf: [36]u8 = undefined;
    return rc.interp.gcNewString(id.toString(&buf));
}

fn uuidV7(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    const rc = runCtx(ctx);
    const source: std.Random.IoSource = .{ .io = rc.io };
    const id = zuuid.Uuid.v7(source.interface(), rc.io);
    var buf: [36]u8 = undefined;
    return rc.interp.gcNewString(id.toString(&buf));
}

fn randomBytes(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const rc = runCtx(ctx);
    const n_i64 = try requireInteger(rc, arg(args, 0), "length");
    if (n_i64 < 0) return rc.interp.throwError(.range_error, "length must be >= 0", .{});
    const n: usize = @intCast(n_i64);

    const buf_val = try rc.interp.gcNewArrayBuffer(n);
    const source: std.Random.IoSource = .{ .io = rc.io };
    source.interface().bytes(buf_val.array_buffer.value.bytes);
    return rc.interp.gcNewTypedArray(buf_val.retain(), 0, n, .u8);
}

fn randomIntFn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const rc = runCtx(ctx);
    const min = try requireInteger(rc, arg(args, 0), "min");
    const max = try requireInteger(rc, arg(args, 1), "max");
    if (min > max) return rc.interp.throwError(.range_error, "min must be <= max", .{});

    const source: std.Random.IoSource = .{ .io = rc.io };
    const n = source.interface().intRangeAtMost(i64, min, max);
    return JSValue.fromNumber(@floatFromInt(n));
}

fn randomStringFn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const rc = runCtx(ctx);
    const len_i64 = try requireInteger(rc, arg(args, 0), "length");
    if (len_i64 < 0) return rc.interp.throwError(.range_error, "length must be >= 0", .{});
    const len: usize = @intCast(len_i64);

    const alphabet_arg = arg(args, 1);
    const alphabet: ?[]const u8 = if (alphabet_arg == .undefined)
        null
    else
        try coerceBytes(rc, alphabet_arg, "alphabet");

    const s = try zcrypto.random.randomString(allocator, rc.io, len, alphabet);
    defer allocator.free(s);
    return rc.interp.gcNewString(s);
}

fn makeHashFn(comptime alg: zcrypto.hash.Algorithm) NativeFn {
    return struct {
        fn call(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
            _ = allocator;
            _ = this_value;
            const rc = runCtx(ctx);
            const data = try coerceBytes(rc, arg(args, 0), "data");
            const len = comptime zcrypto.hash.digestLength(alg);
            var digest_buf: [len]u8 = undefined;
            zcrypto.hash.hash(alg, data, &digest_buf);
            return bytesToUint8Array(rc, &digest_buf);
        }
    }.call;
}

fn hmacSha256Fn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const rc = runCtx(ctx);
    const key = try coerceBytes(rc, arg(args, 0), "key");
    const data = try coerceBytes(rc, arg(args, 1), "data");
    const mac = zcrypto.hmac.hmacSha256(key, data);
    return bytesToUint8Array(rc, &mac);
}

fn hmacSha512Fn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const rc = runCtx(ctx);
    const key = try coerceBytes(rc, arg(args, 0), "key");
    const data = try coerceBytes(rc, arg(args, 1), "data");
    const mac = zcrypto.hmac.hmacSha512(key, data);
    return bytesToUint8Array(rc, &mac);
}

fn coerceAeadKey(rc: *RunCtx, v: JSValue) anyerror![zcrypto.aead.key_length]u8 {
    const key_bytes = try coerceBytes(rc, v, "key");
    if (key_bytes.len != zcrypto.aead.key_length) {
        return rc.interp.throwError(.range_error, "key must be {d} bytes, got {d}", .{ zcrypto.aead.key_length, key_bytes.len });
    }
    var key: [zcrypto.aead.key_length]u8 = undefined;
    @memcpy(&key, key_bytes);
    return key;
}

fn coerceOptionalAad(rc: *RunCtx, args: []const JSValue, index: usize) anyerror![]const u8 {
    const aad_arg = arg(args, index);
    return if (aad_arg == .undefined) "" else try coerceBytes(rc, aad_arg, "aad");
}

fn aeadEncrypt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const rc = runCtx(ctx);
    const key = try coerceAeadKey(rc, arg(args, 0));
    const plaintext = try coerceBytes(rc, arg(args, 1), "plaintext");
    const aad = try coerceOptionalAad(rc, args, 2);

    const blob = try zcrypto.aead.encrypt(allocator, rc.io, key, plaintext, aad);
    defer allocator.free(blob);
    return bytesToUint8Array(rc, blob);
}

fn aeadDecrypt(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const rc = runCtx(ctx);
    const key = try coerceAeadKey(rc, arg(args, 0));
    const blob = try coerceBytes(rc, arg(args, 1), "blob");
    const aad = try coerceOptionalAad(rc, args, 2);

    const plaintext = zcrypto.aead.decrypt(allocator, key, blob, aad) catch |err| {
        return rc.interp.throwError(.generic, "AEAD decryption failed: {t}", .{err});
    };
    defer allocator.free(plaintext);
    return bytesToUint8Array(rc, plaintext);
}

fn passwordHash(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const rc = runCtx(ctx);
    const password = try coerceBytes(rc, arg(args, 0), "password");
    const phc = zcrypto.password.hash(allocator, rc.io, password) catch |err| {
        return rc.interp.throwError(.generic, "password hashing failed: {t}", .{err});
    };
    defer allocator.free(phc);
    return rc.interp.gcNewString(phc);
}

fn passwordVerify(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const rc = runCtx(ctx);
    const phc_str = try coerceBytes(rc, arg(args, 0), "hash");
    const password = try coerceBytes(rc, arg(args, 1), "password");
    const ok = zcrypto.password.verify(allocator, rc.io, phc_str, password) catch |err| {
        return rc.interp.throwError(.generic, "password verification failed: {t}", .{err});
    };
    return JSValue.fromBool(ok);
}
