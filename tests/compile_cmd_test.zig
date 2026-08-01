//! `zrun.compile_cmd` (the `z-run compile` subcommand's own flag parsing
//! + wiring into `payload.zig`) exercised end-to-end against real
//! tmp-dir fixtures, using `runWithExePath` so the "running executable"
//! is a controlled fixture instead of the test binary itself -- same
//! discipline as `payload_test.zig`.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zrun = @import("zrun");
const compile_cmd = zrun.compile_cmd;
const payload = zrun.payload;

fn absPath(allocator: std.mem.Allocator, tmp_dir: Io.Dir, io: Io, name: []const u8) ![:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = buf[0..try tmp_dir.realPath(io, &buf)];
    return std.fs.path.joinZ(allocator, &.{ dir_path, name });
}

const Writers = struct {
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    fn init() Writers {
        return .{
            .stdout = std.Io.Writer.Allocating.init(testing.allocator),
            .stderr = std.Io.Writer.Allocating.init(testing.allocator),
        };
    }

    fn deinit(self: *Writers) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }
};

test "compiles a script into a standalone payload binary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "z-run-fixture", .data = "FAKE-Z-RUN-BYTES" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.js", .data = "console.log('hi')" });
    const exe_path = try absPath(testing.allocator, tmp.dir, io, "z-run-fixture");
    defer testing.allocator.free(exe_path);
    const script_path = try absPath(testing.allocator, tmp.dir, io, "hello.js");
    defer testing.allocator.free(script_path);
    const output_path = try absPath(testing.allocator, tmp.dir, io, "hello");
    defer testing.allocator.free(output_path);

    var w = Writers.init();
    defer w.deinit();
    const args = [_][:0]const u8{ script_path, "-o", output_path };
    const code = try compile_cmd.runWithExePath(testing.allocator, io, &w.stdout.writer, &w.stderr.writer, exe_path, &args);

    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("", w.stderr.written());

    const read_back = try payload.tryReadPayloadFromFile(io, testing.allocator, output_path);
    defer if (read_back) |s| testing.allocator.free(s);
    try testing.expect(read_back != null);
    try testing.expectEqualStrings("console.log('hi')", read_back.?);
}

test "missing required -o/--output fails with usage on stderr, not a crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "z-run-fixture", .data = "X" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data = "1" });
    const exe_path = try absPath(testing.allocator, tmp.dir, io, "z-run-fixture");
    defer testing.allocator.free(exe_path);
    const script_path = try absPath(testing.allocator, tmp.dir, io, "a.js");
    defer testing.allocator.free(script_path);

    var w = Writers.init();
    defer w.deinit();
    const args = [_][:0]const u8{script_path};
    const code = try compile_cmd.runWithExePath(testing.allocator, io, &w.stdout.writer, &w.stderr.writer, exe_path, &args);

    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, w.stderr.written(), "Usage: z-run compile") != null);
}

test "an unknown flag fails cleanly instead of silently doing nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "z-run-fixture", .data = "X" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data = "1" });
    const exe_path = try absPath(testing.allocator, tmp.dir, io, "z-run-fixture");
    defer testing.allocator.free(exe_path);
    const script_path = try absPath(testing.allocator, tmp.dir, io, "a.js");
    defer testing.allocator.free(script_path);

    var w = Writers.init();
    defer w.deinit();
    const args = [_][:0]const u8{ script_path, "-o", "out", "--bogus" };
    const code = try compile_cmd.runWithExePath(testing.allocator, io, &w.stdout.writer, &w.stderr.writer, exe_path, &args);

    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, w.stderr.written(), "UnknownOption") != null);
}

test "without --force an existing output is left untouched; --force overwrites it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "z-run-fixture", .data = "X" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data = "1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "out", .data = "pre-existing, not a real binary" });
    const exe_path = try absPath(testing.allocator, tmp.dir, io, "z-run-fixture");
    defer testing.allocator.free(exe_path);
    const script_path = try absPath(testing.allocator, tmp.dir, io, "a.js");
    defer testing.allocator.free(script_path);
    const output_path = try absPath(testing.allocator, tmp.dir, io, "out");
    defer testing.allocator.free(output_path);

    {
        var w = Writers.init();
        defer w.deinit();
        const args = [_][:0]const u8{ script_path, "-o", output_path };
        const code = try compile_cmd.runWithExePath(testing.allocator, io, &w.stdout.writer, &w.stderr.writer, exe_path, &args);
        try testing.expectEqual(@as(u8, 1), code);
        try testing.expect(std.mem.indexOf(u8, w.stderr.written(), "already exists") != null);
    }

    const untouched = try tmp.dir.readFileAlloc(io, "out", testing.allocator, .limited(4096));
    defer testing.allocator.free(untouched);
    try testing.expectEqualStrings("pre-existing, not a real binary", untouched);

    {
        var w = Writers.init();
        defer w.deinit();
        const args = [_][:0]const u8{ script_path, "-o", output_path, "-f" };
        const code = try compile_cmd.runWithExePath(testing.allocator, io, &w.stdout.writer, &w.stderr.writer, exe_path, &args);
        try testing.expectEqual(@as(u8, 0), code);
    }

    const read_back = try payload.tryReadPayloadFromFile(io, testing.allocator, output_path);
    defer if (read_back) |s| testing.allocator.free(s);
    try testing.expect(read_back != null);
    try testing.expectEqualStrings("1", read_back.?);
}
