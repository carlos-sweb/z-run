//! The `os` global end-to-end through the interpreter: real files on a
//! temp dir, real JS scripts using the whole engine.
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const zrun = @import("zrun");

const Ctx = struct {
    interp: zinterpreter.Interpreter,
    allocating: std.Io.Writer.Allocating,

    fn init(args: []const []const u8) !*Ctx {
        const self = try testing.allocator.create(Ctx);
        self.allocating = std.Io.Writer.Allocating.init(testing.allocator);
        self.interp = try zinterpreter.Interpreter.init(testing.allocator, &self.allocating.writer);
        try zrun.install(&self.interp, testing.io, args);
        return self;
    }

    fn deinit(self: *Ctx) void {
        self.interp.deinit();
        self.allocating.deinit();
        testing.allocator.destroy(self);
    }
};

test "write -> read round-trip through real files, with the whole engine available" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var ctx = try Ctx.init(&.{});
    defer ctx.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const script = try std.fmt.allocPrint(testing.allocator,
        \\const path = '{s}/datos.json';
        \\const registros = [ {{ nombre: 'ana', edad: 30 }}, {{ nombre: 'luis', edad: 25 }} ];
        \\os.writeFile(path, JSON.stringify(registros));
        \\const [primero, ...resto] = JSON.parse(os.readFile(path));
        \\console.log(primero.nombre, resto.length);
    , .{dir_path});
    defer testing.allocator.free(script);

    _ = try ctx.interp.run(script);
    try testing.expectEqualStrings("ana 1\n", ctx.allocating.written());
}

test "os.args arrives as an array of strings" {
    var ctx = try Ctx.init(&.{ "uno", "dos" });
    defer ctx.deinit();
    _ = try ctx.interp.run("console.log(os.args.length, os.args[0], os.args[1]);");
    try testing.expectEqualStrings("2 uno dos\n", ctx.allocating.written());
}

test "readFile failure is a catchable JS Error naming the path" {
    var ctx = try Ctx.init(&.{});
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\try { os.readFile('/definitivamente/no/existe.txt'); }
        \\catch (e) { console.log(e.name, e.message.includes('/definitivamente/no/existe.txt')); }
    );
    try testing.expectEqualStrings("Error true\n", ctx.allocating.written());
}

test "non-string path is a catchable TypeError" {
    var ctx = try Ctx.init(&.{});
    defer ctx.deinit();
    _ = try ctx.interp.run("try { os.readFile(42); } catch (e) { console.log(e.name, e.message); }");
    try testing.expectEqualStrings("TypeError path must be a string\n", ctx.allocating.written());
}
