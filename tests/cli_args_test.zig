//! `zrun.cli_args.parse` -- z-run's own flat CLI (`-h`/`-v`/`-e`/`-p`/
//! `--`/positional), now built on z-args' `Simple` tier instead of a
//! hand-rolled `std.mem.eql` chain (see `~/.plans/z-run-compile-a2.md`'s
//! Fase 5). Pure parsing, no I/O -- no tmp-dir fixtures needed, unlike
//! `payload_test.zig`/`compile_cmd_test.zig`.
const std = @import("std");
const testing = std.testing;
const zrun = @import("zrun");
const cli_args = zrun.cli_args;

const Arena = struct {
    state: std.heap.ArenaAllocator,

    fn init() Arena {
        return .{ .state = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *Arena) void {
        self.state.deinit();
    }

    fn parse(self: *Arena, args: []const [:0]const u8) !?cli_args.Args {
        return cli_args.parse(self.state.allocator(), args);
    }
};

test "no args starts a repl" {
    var a = Arena.init();
    defer a.deinit();
    const args = (try a.parse(&.{})).?;
    try testing.expectEqual(.repl, args.mode);
    try testing.expectEqual(null, args.script_path);
    try testing.expectEqual(null, args.eval_code);
    try testing.expectEqual(0, args.script_args.len);
}

test "-h and --help both select help mode" {
    var a = Arena.init();
    defer a.deinit();
    try testing.expectEqual(.help, (try a.parse(&.{"-h"})).?.mode);
    try testing.expectEqual(.help, (try a.parse(&.{"--help"})).?.mode);
}

test "-v and --version both select version mode" {
    var a = Arena.init();
    defer a.deinit();
    try testing.expectEqual(.version, (try a.parse(&.{"-v"})).?.mode);
    try testing.expectEqual(.version, (try a.parse(&.{"--version"})).?.mode);
}

test "-h wins even after a positional -- flags are recognized anywhere in argv" {
    // Matches the pre-migration hand-rolled loop: every token is checked
    // against the known flags regardless of position, not just "flags
    // before positionals".
    var a = Arena.init();
    defer a.deinit();
    const args = (try a.parse(&.{ "script.js", "-h" })).?;
    try testing.expectEqual(.help, args.mode);
}

test "-e/--eval sets eval mode and the code" {
    var a = Arena.init();
    defer a.deinit();
    const x = (try a.parse(&.{ "-e", "1+1" })).?;
    try testing.expectEqual(.eval, x.mode);
    try testing.expectEqualStrings("1+1", x.eval_code.?);

    const y = (try a.parse(&.{ "--eval", "1+1" })).?;
    try testing.expectEqual(.eval, y.mode);
    try testing.expectEqualStrings("1+1", y.eval_code.?);
}

test "--eval=<code> (attached long form) also works -- new, was a usage error before" {
    // Documented, deliberate expansion: the hand-rolled parser this
    // replaces only accepted `-e code`/`--eval code` (separate token);
    // `Simple`'s `--long=value` support now also accepts the attached
    // form. No previously-valid invocation stops working.
    var a = Arena.init();
    defer a.deinit();
    const x = (try a.parse(&.{"--eval=1+1"})).?;
    try testing.expectEqual(.eval, x.mode);
    try testing.expectEqualStrings("1+1", x.eval_code.?);
}

test "-e with no following token is a usage error (missing value)" {
    var a = Arena.init();
    defer a.deinit();
    try testing.expectEqual(null, try a.parse(&.{"-e"}));
}

test "-p sets print_result independently of mode" {
    var a = Arena.init();
    defer a.deinit();
    const x = (try a.parse(&.{ "-e", "1+1", "-p" })).?;
    try testing.expectEqual(.eval, x.mode);
    try testing.expect(x.print_result);

    const y = (try a.parse(&.{"-p"})).?;
    try testing.expectEqual(.repl, y.mode);
    try testing.expect(y.print_result);
}

test "first positional becomes script_path, rest become script_args" {
    var a = Arena.init();
    defer a.deinit();
    const args = (try a.parse(&.{ "a.js", "b", "c" })).?;
    try testing.expectEqual(.run_file, args.mode);
    try testing.expectEqualStrings("a.js", args.script_path.?);
    try testing.expectEqual(2, args.script_args.len);
    try testing.expectEqualStrings("b", args.script_args[0]);
    try testing.expectEqualStrings("c", args.script_args[1]);
}

test "once eval_code is set, every positional goes to script_args (none becomes script_path)" {
    var a = Arena.init();
    defer a.deinit();
    const args = (try a.parse(&.{ "-e", "code", "arg1", "arg2" })).?;
    try testing.expectEqual(.eval, args.mode);
    try testing.expectEqual(null, args.script_path);
    try testing.expectEqual(2, args.script_args.len);
    try testing.expectEqualStrings("arg1", args.script_args[0]);
    try testing.expectEqualStrings("arg2", args.script_args[1]);
}

test "a positional seen before -e still ends up in script_path, but eval mode wins anyway" {
    // Parity check against the original algorithm: mode selection prefers
    // eval_code over script_path regardless of which was set first.
    var a = Arena.init();
    defer a.deinit();
    const args = (try a.parse(&.{ "foo.js", "-e", "code" })).?;
    try testing.expectEqual(.eval, args.mode);
    try testing.expectEqualStrings("foo.js", args.script_path.?);
    try testing.expectEqualStrings("code", args.eval_code.?);
}

test "-- treats every following token as positional, even ones that look like flags" {
    var a = Arena.init();
    defer a.deinit();
    const args = (try a.parse(&.{ "--", "-h", "-e" })).?;
    try testing.expectEqual(.run_file, args.mode);
    try testing.expectEqualStrings("-h", args.script_path.?);
    try testing.expectEqual(1, args.script_args.len);
    try testing.expectEqualStrings("-e", args.script_args[0]);
}

test "a bare '-' is a positional, not an unknown flag" {
    var a = Arena.init();
    defer a.deinit();
    const args = (try a.parse(&.{"-"})).?;
    try testing.expectEqual(.run_file, args.mode);
    try testing.expectEqualStrings("-", args.script_path.?);
}

test "an unrecognized flag is a usage error" {
    var a = Arena.init();
    defer a.deinit();
    try testing.expectEqual(null, try a.parse(&.{"--not-a-real-flag"}));
    try testing.expectEqual(null, try a.parse(&.{"-x"}));
}

test "--print=<value> is a usage error -- print takes no value" {
    var a = Arena.init();
    defer a.deinit();
    try testing.expectEqual(null, try a.parse(&.{"--print=x"}));
}

test "short-option bundling: -e absorbs the rest of its own bundle as the value (documented expansion)" {
    // `-e` is a value-kind option, so in a bundle it greedily consumes
    // whatever's left in the token -- getopt_long-standard behavior,
    // ground-truthed in z-args' own Simple.Parser tests. The pre-
    // migration hand-rolled parser had no bundling at all, so `-ep`
    // used to be "unknown flag"; now it's `-e` with value "p".
    var a = Arena.init();
    defer a.deinit();
    const args = (try a.parse(&.{"-ep"})).?;
    try testing.expectEqual(.eval, args.mode);
    try testing.expectEqualStrings("p", args.eval_code.?);
}
