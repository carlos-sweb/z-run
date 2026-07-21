//! z-run: minimal script runtime for the z-* engine.
//! `z-run <script.js> [args...]` -- reads the script, runs it with the
//! `os` global installed (synchronous fs, script args), console on real
//! stdout. Exit codes: 0 ok, 1 uncaught exception / parse error / usage.
const std = @import("std");
const zinterpreter = @import("zinterpreter");
const zvalue = @import("zvalue");
const zrun = @import("zrun");

const max_script_bytes: std.Io.Limit = .limited(64 * 1024 * 1024);

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.skip(); // argv[0]
    const script_path = args_it.next() orelse {
        try stderr.writeAll("usage: z-run <script.js> [args...]\n");
        try stderr.flush();
        return 1;
    };
    var script_args: std.ArrayList([]const u8) = .empty;
    while (args_it.next()) |a| try script_args.append(arena, a);

    // Existence check up front for a clean CLI error (the loader's
    // not-found becomes a JS-level error otherwise).
    _ = std.Io.Dir.cwd().readFileAlloc(io, script_path, arena, max_script_bytes) catch |err| {
        try stderr.print("z-run: {t}: cannot open '{s}'\n", .{ err, script_path });
        try stderr.flush();
        return 1;
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var interp = try zinterpreter.Interpreter.init(gpa, stdout);
    defer interp.deinit();
    try zrun.install(&interp, io, script_args.items);
    try zrun.installYaml(&interp);

    // Every script runs as a module (the engine is always-strict, so a
    // script with no imports behaves identically) -- import/export just
    // work, resolved relative to each file.
    var loader_ctx = zrun.LoaderCtx{ .io = io };
    interp.setModuleLoader(zrun.loader(&loader_ctx));

    _ = interp.runModule(script_path) catch |err| {
        // console output emitted before the failure must still land, in
        // order, before the error report.
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
