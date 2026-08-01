//! `z-run compile <script.js> -o <output> [-f]` (A2 -- see
//! `~/.plans/z-run-compile-a2.md`): bakes a script into a standalone,
//! portable executable by copying the running z-run binary and
//! appending the script + a payload footer (`payload.zig`), no Zig
//! toolchain involved. `main.zig` dispatches here when `argv[1]` is the
//! literal token "compile", passing everything after it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zargs = @import("zargs");
const Declarative = zargs.Declarative;
const payload = @import("payload.zig");

/// The subcommand's own flags/positional, parsed by z-args' Declarative
/// tier instead of a hand-rolled `std.mem.eql` chain (the pattern
/// `main.zig`'s own `parseArgs` uses for the rest of the CLI) -- each
/// field arrives already typed, and `Declarative.usageAlloc` generates
/// the usage text straight from this struct's shape.
const CompileCli = struct {
    output: Declarative.Flag([]const u8, .{ .short = 'o', .long = "output", .help = "Output binary path" }),
    force: Declarative.Flag(bool, .{ .short = 'f', .long = "force", .help = "Overwrite the output if it already exists", .default = false }),
    script: Declarative.Positional([]const u8, .{ .help = "Script to bake into the binary" }),
};

const usage_banner = "Usage: z-run compile <script.js> -o <output> [-f|--force]";

/// `args` is argv AFTER the leading "compile" token (already consumed by
/// the caller). Resolves the running executable's own path and delegates
/// to `runWithExePath`. Returns the process exit code.
pub fn run(gpa: Allocator, io: Io, stdout: *std.Io.Writer, stderr: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    const self_exe_path = std.process.executablePathAlloc(io, gpa) catch |err| {
        try stderr.print("z-run compile: cannot determine the running executable's path: {t}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer gpa.free(self_exe_path);
    return runWithExePath(gpa, io, stdout, stderr, self_exe_path, args);
}

/// Core logic against an explicit `self_exe_path` -- split out from
/// `run` so it's testable against a fixture file instead of the real,
/// currently-running executable (which in a test is the test runner
/// itself, never a fixture).
pub fn runWithExePath(
    gpa: Allocator,
    io: Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    self_exe_path: []const u8,
    args: []const [:0]const u8,
) !u8 {
    var diag: Declarative.Diagnostics = .{};
    const cli = Declarative.parseStruct(CompileCli, gpa, args, &diag) catch |err| {
        try stderr.print("z-run compile: {t}", .{err});
        if (diag.field) |f| try stderr.print(" ('{s}')", .{f});
        const usage = try Declarative.usageAlloc(CompileCli, gpa, usage_banner);
        defer gpa.free(usage);
        try stderr.print("\n\n{s}", .{usage});
        try stderr.flush();
        return 1;
    };

    payload.writePayload(io, gpa, self_exe_path, cli.script.value, cli.output.value, cli.force.value) catch |err| {
        switch (err) {
            error.PathAlreadyExists => try stderr.print("z-run compile: '{s}' already exists (use -f/--force to overwrite)\n", .{cli.output.value}),
            // ETXTBSY: `-o` pointed at the very binary currently running
            // (self-collision, see payload.zig's doc comment) -- the
            // kernel itself refuses to truncate a running executable's
            // file, so nothing gets corrupted, but the generic message
            // below would misleadingly blame the script path for a
            // failure that's actually about the output path.
            error.FileBusy => try stderr.print("z-run compile: '{s}' is busy -- can't overwrite the binary that's currently running (compile from a different copy of z-run instead)\n", .{cli.output.value}),
            // Any other failure could be the exe read, the script read,
            // or the output write -- `writePayload` doesn't distinguish,
            // so name both candidate paths rather than guessing which.
            else => try stderr.print("z-run compile: {t} (script: '{s}', output: '{s}')\n", .{ err, cli.script.value, cli.output.value }),
        }
        try stderr.flush();
        return 1;
    };

    try stdout.print("z-run compile: wrote {s}\n", .{cli.output.value});
    try stdout.flush();
    return 0;
}
