//! `os.crypto.*` end-to-end through the interpreter: real JS scripts
//! exercising the whole engine, not just the Zig glue in isolation.
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const zrun = @import("zrun");

const Ctx = struct {
    interp: zinterpreter.Interpreter,
    allocating: std.Io.Writer.Allocating,

    fn init() !*Ctx {
        const self = try testing.allocator.create(Ctx);
        self.allocating = std.Io.Writer.Allocating.init(testing.allocator);
        self.interp = try zinterpreter.Interpreter.init(testing.allocator, &self.allocating.writer);
        try zrun.install(&self.interp, testing.io, &.{});
        try zrun.installCrypto(&self.interp, testing.io);
        return self;
    }

    fn deinit(self: *Ctx) void {
        self.interp.deinit();
        self.allocating.deinit();
        testing.allocator.destroy(self);
    }
};

test "os.crypto.uuid.v4() has the right shape and version nibble" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const id = os.crypto.uuid.v4();
        \\console.log(id.length, id[14], id[8], id[13], id[18], id[23]);
    );
    try testing.expectEqualStrings("36 4 - - - -\n", ctx.allocating.written());
}

test "os.crypto.uuid.v7() has the right shape and version nibble" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const id = os.crypto.uuid.v7();
        \\console.log(id.length, id[14], id[8], id[13], id[18], id[23]);
    );
    try testing.expectEqualStrings("36 7 - - - -\n", ctx.allocating.written());
}

test "os.crypto.random.bytes(n) returns a Uint8Array of length n" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const a = os.crypto.random.bytes(16);
        \\const b = os.crypto.random.bytes(16);
        \\console.log(a.length, b.length, a[0] !== b[0] || a[15] !== b[15]);
    );
    try testing.expectEqualStrings("16 16 true\n", ctx.allocating.written());
}

test "os.crypto.random.int(min, max) never leaves the range" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\let allInRange = true;
        \\for (let i = 0; i < 200; i++) {
        \\  const n = os.crypto.random.int(-10, 10);
        \\  if (n < -10 || n > 10) allInRange = false;
        \\}
        \\console.log(allInRange);
    );
    try testing.expectEqualStrings("true\n", ctx.allocating.written());
}

test "os.crypto.random.string(len) returns a string of that length" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run("console.log(os.crypto.random.string(24).length);");
    try testing.expectEqualStrings("24\n", ctx.allocating.written());
}

test "os.crypto.hash.sha256 matches the known-answer vector through real JS" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\function toHex(arr) {
        \\  let s = '';
        \\  for (let i = 0; i < arr.length; i++) {
        \\    const h = arr[i].toString(16);
        \\    s += h.length === 1 ? '0' + h : h;
        \\  }
        \\  return s;
        \\}
        \\console.log(toHex(os.crypto.hash.sha256('abc')));
    );
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n", ctx.allocating.written());
}

test "os.crypto.hmac.sha256 differs for different keys" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const a = os.crypto.hmac.sha256('key-one', 'same data');
        \\const b = os.crypto.hmac.sha256('key-two', 'same data');
        \\console.log(a.length, a[0] !== b[0] || a[31] !== b[31]);
    );
    try testing.expectEqualStrings("32 true\n", ctx.allocating.written());
}

test "os.crypto.aead round-trips through real JS" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\function bytesToString(arr) {
        \\  let s = '';
        \\  for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
        \\  return s;
        \\}
        \\const key = os.crypto.random.bytes(32);
        \\const blob = os.crypto.aead.encrypt(key, 'top secret', 'ctx');
        \\const plain = os.crypto.aead.decrypt(key, blob, 'ctx');
        \\console.log(bytesToString(plain) === 'top secret');
    );
    try testing.expectEqualStrings("true\n", ctx.allocating.written());
}

test "os.crypto.aead.decrypt with the wrong key is a catchable error" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const key = os.crypto.random.bytes(32);
        \\const otherKey = os.crypto.random.bytes(32);
        \\const blob = os.crypto.aead.encrypt(key, 'secret');
        \\try {
        \\  os.crypto.aead.decrypt(otherKey, blob);
        \\  console.log('no error');
        \\} catch (e) {
        \\  console.log(e.name, e.message.includes('AEAD'));
        \\}
    );
    try testing.expectEqualStrings("Error true\n", ctx.allocating.written());
}

test "os.crypto.aead.encrypt with a wrong-length key is a catchable RangeError" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\try {
        \\  os.crypto.aead.encrypt('too-short-key', 'data');
        \\  console.log('no error');
        \\} catch (e) {
        \\  console.log(e.name, e.message.includes('32'));
        \\}
    );
    try testing.expectEqualStrings("RangeError true\n", ctx.allocating.written());
}

test "os.crypto.base32 round-trips through real JS" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const encoded = os.crypto.base32.encode('foobar');
        \\const decoded = os.crypto.base32.decode(encoded);
        \\function bytesToString(arr) {
        \\  let s = '';
        \\  for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
        \\  return s;
        \\}
        \\console.log(encoded, bytesToString(decoded) === 'foobar');
    );
    try testing.expectEqualStrings("MZXW6YTBOI====== true\n", ctx.allocating.written());
}

test "os.crypto.totp matches the RFC 4226 known-answer vector through real JS" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\console.log(os.crypto.totp.hotp('12345678901234567890', 0, 6));
    );
    try testing.expectEqualStrings("755224\n", ctx.allocating.written());
}

test "os.crypto.totp.totp matches the RFC 6238 known-answer vector through real JS" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\console.log(os.crypto.totp.totp('12345678901234567890', 59, 30, 8));
    );
    try testing.expectEqualStrings("94287082\n", ctx.allocating.written());
}

test "os.crypto.totp.verifyTotp accepts the right code and a window, rejects a wrong one" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const secret = '12345678901234567890';
        \\const exact = os.crypto.totp.verifyTotp(secret, '94287082', 59, 30, 8, 0);
        \\const wrong = os.crypto.totp.verifyTotp(secret, '00000000', 59, 30, 8, 0);
        \\const drifted = os.crypto.totp.verifyTotp(secret, '94287082', 59 + 30, 30, 8, 1);
        \\console.log(exact, wrong, drifted);
    );
    try testing.expectEqualStrings("true false true\n", ctx.allocating.written());
}

test "os.crypto.totp.hotp rejects out-of-range digits as a catchable RangeError" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\try {
        \\  os.crypto.totp.hotp('12345678901234567890', 0, 10);
        \\  console.log('no error');
        \\} catch (e) {
        \\  console.log(e.name, e.message.includes('digits'));
        \\}
    );
    try testing.expectEqualStrings("RangeError true\n", ctx.allocating.written());
}

test "os.crypto.jws round-trips through real JS" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const header = '{"alg":"HS256"}';
        \\const payload = '{"sub":"1"}';
        \\const token = os.crypto.jws.sign(header, payload, 'jwt-key');
        \\const verified = os.crypto.jws.verify(token, 'jwt-key');
        \\console.log(verified.header === header, verified.payload === payload);
    );
    try testing.expectEqualStrings("true true\n", ctx.allocating.written());
}

test "os.crypto.jws.verify with the wrong key is a catchable error" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const token = os.crypto.jws.sign('{}', '{}', 'right-key');
        \\try {
        \\  os.crypto.jws.verify(token, 'wrong-key');
        \\  console.log('no error');
        \\} catch (e) {
        \\  console.log(e.name, e.message.includes('JWS'));
        \\}
    );
    try testing.expectEqualStrings("Error true\n", ctx.allocating.written());
}

test "os.crypto.password hash/verify round-trips through real JS" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const phc = os.crypto.password.hash('hunter2');
        \\const ok = os.crypto.password.verify(phc, 'hunter2');
        \\const bad = os.crypto.password.verify(phc, 'wrong');
        \\console.log(phc.indexOf('$argon2id$') === 0, ok, bad);
    );
    try testing.expectEqualStrings("true true false\n", ctx.allocating.written());
}
