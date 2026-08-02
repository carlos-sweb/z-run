//! z-run's REPL: reads one line at a time from stdin and hands each to
//! `Interpreter.run`, which already reuses its `script_env` across calls
//! -- so bindings persist across lines for free, no interpreter-side
//! support needed. No multi-line continuation (an unterminated statement
//! is just a SyntaxError on that line, documented gap) and no line
//! editing/history (raw `takeDelimiterExclusive`).
const std = @import("std");
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const Interpreter = zinterpreter.Interpreter;
const zrun = @import("zrun");

/// Runs the REPL loop until EOF (Ctrl+D) or `os.exit()`. Returns the
/// process exit code.
pub fn run(interp: *Interpreter, io: std.Io, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    while (true) {
        try stdout.writeAll("> ");
        try stdout.flush();

        // Inclusive, not exclusive: `takeDelimiterExclusive` leaves the
        // delimiter itself in the buffer for the caller to discard, so a
        // loop calling it repeatedly never advances past a line with no
        // trailing content after the newline -- inclusive + trim sidesteps
        // that entirely.
        const raw = stdin.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                try stdout.writeAll("\n");
                try stdout.flush();
                return 0;
            },
            else => return err,
        };
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) continue;

        const result = interp.run(line) catch |err| {
            try stdout.flush();
            switch (err) {
                error.UncaughtException => try zrun.printUncaught(interp.arena_state.allocator(), stderr, interp.pending_exception.?),
                error.NotImplemented => try stderr.writeAll("z-run: NotImplemented: the script uses a feature this engine doesn't support yet\n"),
                else => try stderr.print("SyntaxError: {t}\n", .{err}),
            }
            try stderr.flush();
            continue;
        };

        if (result != .undefined) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(interp.arena_state.allocator());
            try zinterpreter.inspect.inspect(interp.arena_state.allocator(), &buf, result);
            try stdout.writeAll(buf.items);
            try stdout.writeAll("\n");
        }
        try stdout.flush();
    }
}
