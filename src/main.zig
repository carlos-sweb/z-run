//! z-run: minimal script runtime for the z-* engine.
//! `z-run <script.js> [args...]` -- reads the script, runs it with the
//! `os` global installed (synchronous fs, script args), console on real
//! stdout. Also supports `-e/--eval <code>` (optionally `-p/--print`),
//! a REPL (no script/`-e` given), `-v/--version`, `-h/--help`,
//! `compile <script.js> -o <output>` (bake a standalone binary, see
//! `compile_cmd.zig`). Exit codes: 0 ok, 1 uncaught exception / parse
//! error / usage.
const std = @import("std");
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const zrun = @import("zrun");
const repl = @import("repl.zig");

const max_script_bytes: std.Io.Limit = .limited(64 * 1024 * 1024);

const usage_text =
    \\usage: z-run [options] [script.js] [args...]
    \\       z-run compile <script.js> -o <output> [-f]
    \\
    \\options:
    \\  -e, --eval <code>   evaluate <code> instead of a script file
    \\  -p, --print         with -e, print the result of the evaluation
    \\  -v, --version       print the version and exit
    \\  -h, --help          print this help and exit
    \\  --                  treat every following argument as positional
    \\
    \\with no script and no -e, starts a REPL.
    \\
    \\`compile` bakes a script into a standalone executable -- see
    \\`z-run compile -h` for its own options.
    \\
;

const Args = struct {
    mode: enum { run_file, eval, repl, help, version },
    eval_code: ?[]const u8 = null,
    print_result: bool = false,
    script_path: ?[]const u8 = null,
    script_args: [][]const u8,
};

fn parseArgs(arena: std.mem.Allocator, init: std.process.Init) !?Args {
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.skip(); // argv[0]

    var eval_code: ?[]const u8 = null;
    var print_result = false;
    var script_path: ?[]const u8 = null;
    var positional_only = false;
    var script_args: std.ArrayList([]const u8) = .empty;

    while (args_it.next()) |a| {
        if (!positional_only and std.mem.eql(u8, a, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help"))) {
            return .{ .mode = .help, .script_args = &.{} };
        }
        if (!positional_only and (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--version"))) {
            return .{ .mode = .version, .script_args = &.{} };
        }
        if (!positional_only and (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--eval"))) {
            eval_code = args_it.next() orelse {
                return null; // missing argument to -e
            };
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--print"))) {
            print_result = true;
            continue;
        }
        if (!positional_only and a.len > 1 and a[0] == '-') {
            return null; // unknown flag
        }
        if (eval_code == null and script_path == null) {
            script_path = a;
        } else {
            try script_args.append(arena, a);
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

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    // Self-extracting payload check (`z-run compile`, A2 -- see
    // payload.zig): if THIS binary has a script appended, run it instead
    // of behaving like normal z-run, with every argv[1..] becoming the
    // script's own args -- same contract as embed_main.zig's build-time
    // equivalent (A1). Runs on every startup, so it must stay cheap; see
    // `tryReadEmbeddedPayload`'s doc comment.
    if (try zrun.payload.tryReadEmbeddedPayload(io, gpa)) |source| {
        defer gpa.free(source);
        var payload_args_it = std.process.Args.Iterator.init(init.minimal.args);
        _ = payload_args_it.skip(); // argv[0]
        var script_args: std.ArrayList([]const u8) = .empty;
        while (payload_args_it.next()) |a| try script_args.append(arena, a);

        var interp = try zinterpreter.Interpreter.init(gpa, stdout);
        interp.console_error_writer = stderr;
        defer interp.deinit();
        try zrun.install(&interp, io, script_args.items);
        try zrun.installYaml(&interp);
        try zrun.installToml(&interp);
        try zrun.installCrypto(&interp, io);
        try zrun.installArgsParser(&interp);

        _ = interp.run(source) catch |err| {
            try stdout.flush();
            switch (err) {
                error.UncaughtException => try zrun.printUncaught(stderr, interp.pending_exception.?),
                error.NotImplemented => try stderr.writeAll("z-run: NotImplemented: the script uses a feature this engine doesn't support yet\n"),
                else => try stderr.print("SyntaxError: {t}\n", .{err}),
            }
            try stderr.flush();
            return 1;
        };

        try stdout.flush();
        try stderr.flush();
        return 0;
    }

    // `z-run compile <script.js> -o <output> [-f]`: reserved first-token
    // subcommand, dispatched before the normal flat `parseArgs` below.
    // A script literally named `compile` needs `z-run ./compile` or
    // `z-run -- compile` (documented narrowing, see
    // `~/.plans/z-run-compile-a2.md`).
    {
        var peek_it = std.process.Args.Iterator.init(init.minimal.args);
        _ = peek_it.skip(); // argv[0]
        if (peek_it.next()) |first| {
            if (std.mem.eql(u8, first, "compile")) {
                var rest: std.ArrayList([:0]const u8) = .empty;
                while (peek_it.next()) |a| try rest.append(arena, a);
                return zrun.compile_cmd.run(gpa, io, stdout, stderr, rest.items);
            }
        }
    }

    const args = try parseArgs(arena, init) orelse {
        try stderr.writeAll(usage_text);
        try stderr.flush();
        return 1;
    };

    switch (args.mode) {
        .help => {
            try stdout.writeAll(usage_text);
            try stdout.flush();
            return 0;
        },
        .version => {
            try stdout.print("z-run {s}\n", .{zrun.version});
            try stdout.flush();
            return 0;
        },
        .run_file => {
            const script_path = args.script_path.?;
            // Existence check up front for a clean CLI error (the loader's
            // not-found becomes a JS-level error otherwise).
            _ = std.Io.Dir.cwd().readFileAlloc(io, script_path, arena, max_script_bytes) catch |err| {
                try stderr.print("z-run: {t}: cannot open '{s}'\n", .{ err, script_path });
                try stderr.flush();
                return 1;
            };

            var interp = try zinterpreter.Interpreter.init(gpa, stdout);
            interp.console_error_writer = stderr;
            defer interp.deinit();
            try zrun.install(&interp, io, args.script_args);
            try zrun.installYaml(&interp);
            try zrun.installToml(&interp);
            try zrun.installCrypto(&interp, io);
            try zrun.installArgsParser(&interp);

            // Every script runs as a module (the engine is always-strict, so
            // a script with no imports behaves identically) -- import/export
            // just work, resolved relative to each file.
            var loader_ctx = zrun.LoaderCtx{ .io = io };
            interp.setModuleLoader(zrun.loader(&loader_ctx));

            _ = interp.runModule(script_path) catch |err| {
                // console output emitted before the failure must still land,
                // in order, before the error report.
                try stdout.flush();
                switch (err) {
                    error.UncaughtException => try zrun.printUncaught(stderr, interp.pending_exception.?),
                    error.NotImplemented => try stderr.writeAll("z-run: NotImplemented: the script uses a feature this engine doesn't support yet\n"),
                    else => try stderr.print("SyntaxError: {t}\n", .{err}),
                }
                try stderr.flush();
                return 1;
            };

            try stdout.flush();
            try stderr.flush();
            return 0;
        },
        .eval => {
            var interp = try zinterpreter.Interpreter.init(gpa, stdout);
            interp.console_error_writer = stderr;
            defer interp.deinit();
            try zrun.install(&interp, io, args.script_args);
            try zrun.installYaml(&interp);
            try zrun.installToml(&interp);
            try zrun.installCrypto(&interp, io);
            try zrun.installArgsParser(&interp);

            const result = interp.run(args.eval_code.?) catch |err| {
                try stdout.flush();
                switch (err) {
                    error.UncaughtException => try zrun.printUncaught(stderr, interp.pending_exception.?),
                    error.NotImplemented => try stderr.writeAll("z-run: NotImplemented: the script uses a feature this engine doesn't support yet\n"),
                    else => try stderr.print("SyntaxError: {t}\n", .{err}),
                }
                try stderr.flush();
                return 1;
            };

            if (args.print_result and result != .undefined) {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(interp.arena_state.allocator());
                try zinterpreter.inspect.inspect(interp.arena_state.allocator(), &buf, result);
                try stdout.writeAll(buf.items);
                try stdout.writeAll("\n");
            }

            try stdout.flush();
            try stderr.flush();
            return 0;
        },
        .repl => {
            var interp = try zinterpreter.Interpreter.init(gpa, stdout);
            interp.console_error_writer = stderr;
            defer interp.deinit();
            try zrun.install(&interp, io, args.script_args);
            try zrun.installYaml(&interp);
            try zrun.installToml(&interp);
            try zrun.installCrypto(&interp, io);
            try zrun.installArgsParser(&interp);

            return try repl.run(&interp, io, stdout, stderr);
        },
    }
}
