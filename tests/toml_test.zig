//! The `TOML` global end-to-end through the interpreter.
const std = @import("std");
const testing = std.testing;
const zinterpreter = @import("zinterpreter");
const zrun = @import("zrun");

const Ctx = struct {
    interp: zinterpreter.Interpreter,
    allocating: std.Io.Writer.Allocating,

    fn init() !*Ctx {
        const self = try testing.allocator.create(Ctx);
        self.allocating = std.Io.Writer.Allocating.init(testing.allocator);
        self.interp = try zinterpreter.Interpreter.init(testing.allocator, &self.allocating.writer);
        try zrun.install(&self.interp, testing.io, &.{});
        try zrun.installToml(&self.interp);
        return self;
    }

    fn deinit(self: *Ctx) void {
        self.interp.deinit();
        self.allocating.deinit();
        testing.allocator.destroy(self);
    }
};

test "TOML.parse produces a plain JS value tree, including tables and arrays of tables" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const doc = TOML.parse("name = \"app\"\n[server]\nhost = \"localhost\"\nport = 8080\n\n[[bin]]\nname = \"cli\"\n");
        \\console.log(doc.name, doc.server.host, doc.server.port, doc.bin[0].name);
    );
    try testing.expectEqualStrings("app localhost 8080 cli\n", ctx.allocating.written());
}

test "TOML.stringify round-trips a JS object" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const out = TOML.stringify({ name: "app", port: 8080, active: true });
        \\console.log(out);
        \\console.log(TOML.parse(out).port);
    );
    try testing.expectEqualStrings("name = \"app\"\nport = 8080\nactive = true\n\n8080\n", ctx.allocating.written());
}

test "TOML.parse failure is a catchable SyntaxError" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\try { TOML.parse("= 1"); } catch (e) { console.log(e.name); }
    );
    try testing.expectEqualStrings("SyntaxError\n", ctx.allocating.written());
}

test "reading a .toml config file end-to-end with os.readFile" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var ctx = try Ctx.init();
    defer ctx.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.toml", .{dir_path});
    defer testing.allocator.free(config_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = config_path, .data = "name = \"myapp\"\nport = 3000\n" });

    const script = try std.fmt.allocPrint(testing.allocator,
        \\const cfg = TOML.parse(os.readFile('{s}/config.toml'));
        \\console.log(cfg.name, cfg.port);
    , .{dir_path});
    defer testing.allocator.free(script);
    _ = try ctx.interp.run(script);
    try testing.expectEqualStrings("myapp 3000\n", ctx.allocating.written());
}
