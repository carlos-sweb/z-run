//! The `YAML` global end-to-end through the interpreter.
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
        try zrun.installYaml(&self.interp);
        return self;
    }

    fn deinit(self: *Ctx) void {
        self.interp.deinit();
        self.allocating.deinit();
        testing.allocator.destroy(self);
    }
};

test "YAML.parse produces a plain JS value tree" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const doc = YAML.parse("name: app\nserver:\n  host: localhost\n  port: 8080\ntags:\n  - web\n  - prod\n");
        \\console.log(doc.name, doc.server.host, doc.server.port, doc.tags.join(","));
    );
    try testing.expectEqualStrings("app localhost 8080 web,prod\n", ctx.allocating.written());
}

test "YAML.stringify round-trips a JS object" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\const out = YAML.stringify({ name: "app", port: 8080, active: true });
        \\console.log(out);
        \\console.log(YAML.parse(out).port);
    );
    try testing.expectEqualStrings("name: app\nport: 8080\nactive: true\n\n8080\n", ctx.allocating.written());
}

test "YAML.parse failure is a catchable SyntaxError" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    _ = try ctx.interp.run(
        \\try { YAML.parse("a: &x 1"); } catch (e) { console.log(e.name); }
    );
    try testing.expectEqualStrings("SyntaxError\n", ctx.allocating.written());
}

test "reading a .yaml config file end-to-end with os.readFile" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var ctx = try Ctx.init();
    defer ctx.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.yaml", .{dir_path});
    defer testing.allocator.free(config_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = config_path, .data = "name: myapp\nport: 3000\n" });

    const script = try std.fmt.allocPrint(testing.allocator,
        \\const cfg = YAML.parse(os.readFile('{s}/config.yaml'));
        \\console.log(cfg.name, cfg.port);
    , .{dir_path});
    defer testing.allocator.free(script);
    _ = try ctx.interp.run(script);
    try testing.expectEqualStrings("myapp 3000\n", ctx.allocating.written());
}
