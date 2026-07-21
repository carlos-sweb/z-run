//! z-run embedded-script entry point (build-time `@embedFile`): builds a
//! self-contained binary that runs ONE JS script baked in at compile time.
//! Produced by `zig build -Dscript=file.js -Dname=app`. Unlike main.zig it
//! reads no script path from argv -- all of argv[1..] are the script's own
//! args (exposed via the `os` global). Single-file: run as a script (the
//! engine is always-strict); `import`/`export` are not resolved.
const std = @import("std");
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const zrun = @import("zrun");

/// The JS source baked into this binary. `build.zig` maps the anonymous
/// import "embedded_script" to the file given via -Dscript.
const embedded_source = @embedFile("embedded_script");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // No script-path argument here: every argv[1..] is a script arg.
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.skip(); // argv[0]
    var script_args: std.ArrayList([]const u8) = .empty;
    while (args_it.next()) |a| try script_args.append(arena, a);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var interp = try zinterpreter.Interpreter.init(gpa, stdout);
    defer interp.deinit();
    try zrun.install(&interp, io, script_args.items);
    try zrun.installYaml(&interp);

    _ = interp.run(embedded_source) catch |err| {
        try stdout.flush();
        switch (err) {
            error.UncaughtException => {
                const ex = interp.pending_exception.?;
                switch (ex) {
                    .@"error" => |box| try stderr.print("Uncaught {s}: {s}\n", .{ box.value.kind.name(), box.value.message }),
                    .string => |box| try stderr.print("Uncaught '{s}'\n", .{box.value.data}),
                    .number => |n| try stderr.print("Uncaught {d}\n", .{n}),
                    else => try stderr.print("Uncaught [{s}]\n", .{ex.typeOf()}),
                }
            },
            error.NotImplemented => try stderr.writeAll("z-run: NotImplemented: the script uses a feature this engine doesn't support yet\n"),
            else => try stderr.print("SyntaxError: {t}\n", .{err}),
        }
        try stderr.flush();
        return 1;
    };

    try stdout.flush();
    return 0;
}
