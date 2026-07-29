//! `os.argsParser.simple` end-to-end through the interpreter: real JS
//! scripts exercising the whole engine, not just the Zig glue in
//! isolation -- same discipline as `crypto_test.zig`.
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
        try zrun.installArgsParser(&self.interp);
        return self;
    }

    fn deinit(self: *Ctx) void {
        self.interp.deinit();
        self.allocating.deinit();
        testing.allocator.destroy(self);
    }
};

test "os.argsParser.simple tokenizes a flag, an option, a positional, and an unknown option" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const tokens = os.argsParser.simple(
        \\  ['-v', '-o', 'out.txt', 'file.txt', '--bogus'],
        \\  [
        \\    { short: 'v', long: 'verbose' },
        \\    { short: 'o', long: 'output', kind: 'value' },
        \\  ]
        \\);
        \\console.log(tokens.length);
        \\console.log(tokens[0].type, tokens[0].short, tokens[0].long, tokens[0].value);
        \\console.log(tokens[1].type, tokens[1].short, tokens[1].long, tokens[1].value);
        \\console.log(tokens[2].type, tokens[2].short, tokens[2].long, tokens[2].value);
        \\console.log(tokens[3].type, tokens[3].short, tokens[3].long, tokens[3].value);
    );
    try testing.expectEqualStrings(
        \\4
        \\flag v verbose undefined
        \\option o output out.txt
        \\positional undefined undefined file.txt
        \\unknownOption undefined bogus undefined
        \\
    , ctx.allocating.written());
}

test "os.argsParser.simple reports missing_value and unexpected_value" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const specs = [
        \\  { short: 'v', long: 'verbose' },
        \\  { short: 'o', long: 'output', kind: 'value' },
        \\];
        \\const missing = os.argsParser.simple(['-o'], specs);
        \\const unexpected = os.argsParser.simple(['--verbose=x'], specs);
        \\console.log(missing[0].type, unexpected[0].type);
    );
    try testing.expectEqualStrings("missingValue unexpectedValue\n", ctx.allocating.written());
}

test "os.argsParser.simple keeps going past an unknown option (getopt-style continue-on-error)" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const tokens = os.argsParser.simple(['--nope', '-v'], [{ short: 'v', long: 'verbose' }]);
        \\console.log(tokens.length, tokens[0].type, tokens[1].type);
    );
    try testing.expectEqualStrings("2 unknownOption flag\n", ctx.allocating.written());
}

test "os.argsParser.simple with an empty specs array treats everything as positional" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const tokens = os.argsParser.simple(['a', 'b'], []);
        \\console.log(tokens.length, tokens[0].type, tokens[1].type);
    );
    try testing.expectEqualStrings("2 positional positional\n", ctx.allocating.written());
}

test "os.argsParser.simple rejects a non-array argv as a catchable TypeError" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\try {
        \\  os.argsParser.simple('not an array', []);
        \\  console.log('no error');
        \\} catch (e) {
        \\  console.log(e.name);
        \\}
    );
    try testing.expectEqualStrings("TypeError\n", ctx.allocating.written());
}

test "os.argsParser.simple rejects a spec with neither short nor long" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\try {
        \\  os.argsParser.simple(['-x'], [{ kind: 'flag' }]);
        \\  console.log('no error');
        \\} catch (e) {
        \\  console.log(e.name);
        \\}
    );
    try testing.expectEqualStrings("TypeError\n", ctx.allocating.written());
}
