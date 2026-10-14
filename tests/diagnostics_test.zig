const std = @import("std");
const zrun = @import("zrun");
const zvalue = @import("zvalue");

fn expectDiagnostic(err: anyerror, pending: ?zvalue.JSValue, expected: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try zrun.printFailure(std.testing.allocator, &out.writer, err, pending);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "explicit syntax failures retain their category" {
    try expectDiagnostic(error.SyntaxError, null, "SyntaxError: SyntaxError\n");
    try expectDiagnostic(error.ParseError, null, "SyntaxError: ParseError\n");
}

test "parser failures use SyntaxError" {
    try expectDiagnostic(error.UnexpectedToken, null, "SyntaxError: UnexpectedToken\n");
    try expectDiagnostic(error.RestParameterMustBeLast, null, "SyntaxError: RestParameterMustBeLast\n");
}

test "out of memory is not a syntax failure even though ParseError includes it" {
    try expectDiagnostic(error.OutOfMemory, null, "Out of memory: OutOfMemory\n");
}

test "I/O failures use their own category" {
    try expectDiagnostic(error.IoError, null, "I/O error: IoError\n");
}

test "execution step limits use their own category" {
    try expectDiagnostic(error.StepLimitExceeded, null, "Execution step limit exceeded: StepLimitExceeded\n");
}

test "unsupported features use their own category" {
    try expectDiagnostic(error.UnsupportedFeature, null, "Unsupported feature: UnsupportedFeature\n");
    try expectDiagnostic(error.NotImplemented, null, "Unsupported feature: NotImplemented\n");
}

test "unclassified engine failures retain the actual Zig error name" {
    try expectDiagnostic(error.BacktrackStackExhausted, null, "Engine error: BacktrackStackExhausted\n");
    try expectDiagnostic(error.UncaughtException, null, "Engine error: UncaughtException\n");
}

test "a pending JS Error supplies its actual kind and message" {
    const ex = try zvalue.JSValue.newError(std.testing.allocator, .type_error, "not callable");
    defer ex.deinit();
    try expectDiagnostic(error.UncaughtException, ex, "Uncaught TypeError: not callable\n");
}

test "arbitrary pending thrown values take precedence over the Zig error" {
    const ex = try zvalue.JSValue.newString(std.testing.allocator, "x");
    defer ex.deinit();
    try expectDiagnostic(error.IoError, ex, "Uncaught 'x'\n");
    try expectDiagnostic(error.UncaughtException, zvalue.JSValue.fromNumber(123), "Uncaught 123\n");
}
