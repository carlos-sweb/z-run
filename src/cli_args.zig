//! z-run's own flat CLI (`-h`/`-v`/`-e`/`-p`/`--`/positional), parsed with
//! z-args' `Simple` tier instead of a hand-rolled `std.mem.eql` chain --
//! see `~/.plans/z-run-compile-a2.md`'s Fase 5 for why `Simple` (a
//! getopt_long-style pull tokenizer, no allocation, no permutation) and
//! not `Builder`/`Declarative`: z-run already owns a hand-written
//! `usage_text` in `main.zig` that must keep its exact wording, and
//! `Simple`'s token-by-token model is what actually matches the current
//! "flags recognized anywhere in argv, not just before positionals"
//! behavior -- ground-truthed by reading `simple.zig` itself, not
//! assumed.
//!
//! Deliberate behavior EXPANSION versus the hand-rolled parser it
//! replaces (documented, not accidental): `Simple` supports short-option
//! bundling and `--long=value`, so `-ep code` (bundle: `-e` with value
//! `"p"`... only if nothing follows; more usefully `-p` bundled with
//! other flag-only shorts) and `--eval=1+1` now parse instead of hitting
//! "unknown flag" the way they did before. No previously-valid
//! invocation stops working -- this only accepts strictly more syntax.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zargs = @import("zargs");
const Simple = zargs.Simple;

pub const Args = struct {
    mode: enum { run_file, eval, repl, help, version },
    eval_code: ?[]const u8 = null,
    print_result: bool = false,
    script_path: ?[]const u8 = null,
    script_args: [][]const u8,
};

const specs = [_]Simple.OptionSpec{
    .{ .short = 'h', .long = "help", .kind = .flag },
    .{ .short = 'v', .long = "version", .kind = .flag },
    .{ .short = 'e', .long = "eval", .kind = .value },
    .{ .short = 'p', .long = "print", .kind = .flag },
};

/// `args` is argv WITHOUT the program name (`argv[0]` already skipped by
/// the caller, matching `compile_cmd.run`'s convention). Returns `null`
/// on any usage error (unknown flag, `-e`/`--eval` with no value) --
/// same "abort the whole parse on the first bad token" policy the
/// previous hand-rolled loop had, not `Simple`'s own default of
/// report-one-and-keep-going.
pub fn parse(arena: Allocator, args: []const [:0]const u8) !?Args {
    var parser = Simple.Parser.init(args, &specs);

    var eval_code: ?[]const u8 = null;
    var print_result = false;
    var script_path: ?[]const u8 = null;
    var script_args: std.ArrayList([]const u8) = .empty;

    while (true) {
        const tok = parser.next();
        switch (tok) {
            .end => break,
            .flag => |f| {
                if (f.short == 'h') return .{ .mode = .help, .script_args = &.{} };
                if (f.short == 'v') return .{ .mode = .version, .script_args = &.{} };
                if (f.short == 'p') print_result = true;
            },
            .option => |o| {
                if (o.short == 'e') eval_code = o.value;
            },
            .positional => |p| {
                if (eval_code == null and script_path == null) {
                    script_path = p;
                } else {
                    try script_args.append(arena, p);
                }
            },
            .unknown_option, .missing_value, .unexpected_value => return null,
        }
    }

    const mode: @FieldType(Args, "mode") = if (eval_code != null)
        .eval
    else if (script_path != null)
        .run_file
    else
        .repl;

    return .{
        .mode = mode,
        .eval_code = eval_code,
        .print_result = print_result,
        .script_path = script_path,
        .script_args = script_args.items,
    };
}
