//! Self-extracting payload format for `z-run compile` (A2 -- see
//! `~/.plans/z-run-compile-a2.md`): appends a JS script plus a 16-byte
//! footer (8-byte magic + little-endian u64 length) to a copy of the
//! z-run executable. At startup `main.zig` checks its own tail for this
//! footer before doing anything else; if present, the binary runs the
//! appended script instead of behaving like normal z-run. Unlike
//! `embed_main.zig` (build-time `@embedFile`, the A1 approach), this
//! needs no Zig toolchain -- it works from an already-built z-run binary.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const magic = "ZRUNPAY1";
pub const footer_len = magic.len + 8; // magic + u64 LE script length

/// Core footer-parsing logic against an explicit, already-known path --
/// split out from `tryReadEmbeddedPayload` so it's testable against a
/// fixture file without needing a real, currently-running executable
/// (`std.process.executablePath` always reports the calling process's
/// own binary, which in a test is the test runner itself, never a
/// fixture). Returns `null` for a file with no matching footer.
pub fn tryReadPayloadFromFile(io: Io, allocator: Allocator, path: []const u8) !?[]u8 {
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const total_len = try file.length(io);
    if (total_len < footer_len) return null;

    var footer: [footer_len]u8 = undefined;
    const footer_read = try file.readPositionalAll(io, &footer, total_len - footer_len);
    if (footer_read != footer_len) return null;
    if (!std.mem.eql(u8, footer[0..magic.len], magic)) return null;

    const script_len = std.mem.readInt(u64, footer[magic.len..][0..8], .little);
    if (script_len > total_len - footer_len) return error.CorruptPayload;

    const script = try allocator.alloc(u8, script_len);
    errdefer allocator.free(script);
    const script_read = try file.readPositionalAll(io, script, total_len - footer_len - script_len);
    if (script_read != script_len) return error.CorruptPayload;
    return script;
}

/// If the currently-running executable has a payload footer appended,
/// returns the embedded script source (caller-owned, free with
/// `allocator.free`). Returns `null` for a normal z-run binary -- this
/// runs on EVERY startup, so it stays cheap (see
/// `tryReadPayloadFromFile`: one open + a 16-byte read; the full script
/// is only read once a matching magic is actually found). Any failure to
/// even locate/open the running executable (unsupported platform,
/// sandboxed procfs, etc.) is treated the same as "no payload" rather
/// than propagated -- a normal z-run invocation must never fail because
/// of this check.
pub fn tryReadEmbeddedPayload(io: Io, allocator: Allocator) !?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = std.process.executablePath(io, &path_buf) catch return null;
    return tryReadPayloadFromFile(io, allocator, path_buf[0..path_len]);
}

/// Copies `self_exe_path`'s bytes, followed by `script_path`'s bytes and
/// a payload footer, into `output_path` (made executable). Both source
/// files are read fully into memory first, before `output_path` is even
/// opened for writing -- required so that `output_path` aliasing
/// `self_exe_path` (compiling on top of the very binary that's running,
/// or re-compiling over a binary previously produced by this same
/// function) can never truncate a read still in progress. `force =
/// false` fails with `error.PathAlreadyExists` if `output_path` already
/// exists, rather than silently overwriting it.
pub fn writePayload(
    io: Io,
    allocator: Allocator,
    self_exe_path: []const u8,
    script_path: []const u8,
    output_path: []const u8,
    force: bool,
) !void {
    const exe_bytes = try Io.Dir.cwd().readFileAlloc(io, self_exe_path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(exe_bytes);
    const script_bytes = try Io.Dir.cwd().readFileAlloc(io, script_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(script_bytes);

    var footer: [footer_len]u8 = undefined;
    @memcpy(footer[0..magic.len], magic);
    std.mem.writeInt(u64, footer[magic.len..][0..8], script_bytes.len, .little);

    var out_file = try Io.Dir.cwd().createFile(io, output_path, .{
        .exclusive = !force,
        .permissions = .executable_file,
    });
    defer out_file.close(io);

    try out_file.writePositionalAll(io, exe_bytes, 0);
    try out_file.writePositionalAll(io, script_bytes, exe_bytes.len);
    try out_file.writePositionalAll(io, &footer, exe_bytes.len + script_bytes.len);
}
