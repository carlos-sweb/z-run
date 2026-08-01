//! `zrun.payload` (the `z-run compile` A2 footer format) exercised
//! end-to-end against real tmp-dir fixtures -- same discipline as
//! `args_test.zig`: test through the public `zrun` module, not internals.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zrun = @import("zrun");
const payload = zrun.payload;

/// `payload.zig`'s functions all go through `Io.Dir.cwd()` with whatever
/// path string they're given (matching `main.zig`'s existing
/// convention), never a directory *handle* -- so these tests need
/// absolute path *strings* into the tmp dir, not `tmp.dir` itself.
/// `Dir.realPath` resolves the tmp dir's own absolute path;
/// `std.fs.path.join` builds each file's path from there (working
/// whether or not that file exists yet, unlike a sub_path-resolving
/// realpath call).
fn absPath(allocator: std.mem.Allocator, tmp_dir: Io.Dir, io: Io, name: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = buf[0..try tmp_dir.realPath(io, &buf)];
    return std.fs.path.join(allocator, &.{ dir_path, name });
}

test "round-trip: write a payload to a temp file, then read it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    // Stand in for "the running executable": any real file works, the
    // format doesn't care that it's not actually a valid ELF/PE here.
    try tmp.dir.writeFile(io, .{ .sub_path = "fake_exe", .data = "FAKE-EXE-BYTES" });
    try tmp.dir.writeFile(io, .{ .sub_path = "script.js", .data = "console.log('hi')" });

    const exe_path = try absPath(testing.allocator, tmp.dir, io, "fake_exe");
    defer testing.allocator.free(exe_path);
    const script_path = try absPath(testing.allocator, tmp.dir, io, "script.js");
    defer testing.allocator.free(script_path);
    const output_path = try absPath(testing.allocator, tmp.dir, io, "out_bin");
    defer testing.allocator.free(output_path);

    try payload.writePayload(io, testing.allocator, exe_path, script_path, output_path, false);

    // Byte layout: exe bytes, then script bytes, then the 16-byte footer.
    const written = try tmp.dir.readFileAlloc(io, "out_bin", testing.allocator, .limited(4096));
    defer testing.allocator.free(written);
    try testing.expect(std.mem.startsWith(u8, written, "FAKE-EXE-BYTES"));
    try testing.expectEqualStrings(
        "console.log('hi')",
        written["FAKE-EXE-BYTES".len .. written.len - payload.footer_len],
    );

    const read_back = try payload.tryReadPayloadFromFile(io, testing.allocator, output_path);
    defer if (read_back) |s| testing.allocator.free(s);
    try testing.expect(read_back != null);
    try testing.expectEqualStrings("console.log('hi')", read_back.?);
}

test "writePayload without force fails on an existing output, with force overwrites it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "fake_exe", .data = "EXE1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data = "1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "out", .data = "pre-existing" });

    const exe_path = try absPath(testing.allocator, tmp.dir, io, "fake_exe");
    defer testing.allocator.free(exe_path);
    const script_path = try absPath(testing.allocator, tmp.dir, io, "a.js");
    defer testing.allocator.free(script_path);
    const output_path = try absPath(testing.allocator, tmp.dir, io, "out");
    defer testing.allocator.free(output_path);

    try testing.expectError(
        error.PathAlreadyExists,
        payload.writePayload(io, testing.allocator, exe_path, script_path, output_path, false),
    );

    try payload.writePayload(io, testing.allocator, exe_path, script_path, output_path, true);
    const written = try tmp.dir.readFileAlloc(io, "out", testing.allocator, .limited(4096));
    defer testing.allocator.free(written);
    try testing.expect(std.mem.startsWith(u8, written, "EXE1"));
}

test "tryReadPayloadFromFile returns null for a file with no footer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "plain", .data = "just some bytes, no footer here" });
    const plain_path = try absPath(testing.allocator, tmp.dir, io, "plain");
    defer testing.allocator.free(plain_path);

    const result = try payload.tryReadPayloadFromFile(io, testing.allocator, plain_path);
    try testing.expect(result == null);
}

test "tryReadPayloadFromFile returns null for a too-short file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "tiny", .data = "hi" });
    const tiny_path = try absPath(testing.allocator, tmp.dir, io, "tiny");
    defer testing.allocator.free(tiny_path);

    const result = try payload.tryReadPayloadFromFile(io, testing.allocator, tiny_path);
    try testing.expect(result == null);
}

test "an old footer buried in the middle of a file is inert -- only the tail matters" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    // Simulate recompiling on top of an already-compiled A2 binary: an
    // old, real footer ends up buried in the middle of the new file.
    try tmp.dir.writeFile(io, .{ .sub_path = "fake_exe", .data = "EXE-BYTES" });
    try tmp.dir.writeFile(io, .{ .sub_path = "first.js", .data = "1" });
    const exe_path = try absPath(testing.allocator, tmp.dir, io, "fake_exe");
    defer testing.allocator.free(exe_path);
    const script_path = try absPath(testing.allocator, tmp.dir, io, "first.js");
    defer testing.allocator.free(script_path);
    const compiled_path = try absPath(testing.allocator, tmp.dir, io, "compiled_once");
    defer testing.allocator.free(compiled_path);
    try payload.writePayload(io, testing.allocator, exe_path, script_path, compiled_path, false);

    // Now compile AGAIN, using the already-compiled binary as the "exe"
    // to copy -- its old footer ends up buried mid-file in the result.
    try tmp.dir.writeFile(io, .{ .sub_path = "second.js", .data = "22" });
    const script_path2 = try absPath(testing.allocator, tmp.dir, io, "second.js");
    defer testing.allocator.free(script_path2);
    const twice_path = try absPath(testing.allocator, tmp.dir, io, "compiled_twice");
    defer testing.allocator.free(twice_path);
    try payload.writePayload(io, testing.allocator, compiled_path, script_path2, twice_path, false);

    const read_back = try payload.tryReadPayloadFromFile(io, testing.allocator, twice_path);
    defer if (read_back) |s| testing.allocator.free(s);
    try testing.expect(read_back != null);
    try testing.expectEqualStrings("22", read_back.?); // "22", not the old "1"
}

test "self-collision: compiling with -o pointing at the exe path being read still works" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "z-run-copy", .data = "SOME-EXE-BYTES" });
    try tmp.dir.writeFile(io, .{ .sub_path = "s.js", .data = "print(1)" });
    const exe_path = try absPath(testing.allocator, tmp.dir, io, "z-run-copy");
    defer testing.allocator.free(exe_path);
    const script_path = try absPath(testing.allocator, tmp.dir, io, "s.js");
    defer testing.allocator.free(script_path);

    // -o is the SAME path as the exe being copied -- writePayload reads
    // both source files fully into memory before ever opening the
    // output for writing, so this must not corrupt anything.
    try payload.writePayload(io, testing.allocator, exe_path, script_path, exe_path, true);

    const read_back = try payload.tryReadPayloadFromFile(io, testing.allocator, exe_path);
    defer if (read_back) |s| testing.allocator.free(s);
    try testing.expect(read_back != null);
    try testing.expectEqualStrings("print(1)", read_back.?);
}
