const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zinterpreter_dep = b.dependency("zinterpreter", .{ .target = target, .optimize = optimize });
    const zinterpreter_module = zinterpreter_dep.module("zinterpreter");

    const zvalue_dep = b.dependency("zvalue", .{ .target = target, .optimize = optimize });
    const zvalue_module = zvalue_dep.module("zvalue");

    const zyaml_dep = b.dependency("zyaml", .{ .target = target, .optimize = optimize });
    const zyaml_module = zyaml_dep.module("zyaml");

    const zrun_module = b.addModule("zrun", .{
        .root_source_file = b.path("src/zrun.zig"),
    });
    zrun_module.addImport("zinterpreter", zinterpreter_module);
    zrun_module.addImport("zvalue", zvalue_module);
    zrun_module.addImport("zyaml", zyaml_module);

    // The z-run executable.
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("zrun", zrun_module);
    exe_module.addImport("zinterpreter", zinterpreter_module);
    exe_module.addImport("zvalue", zvalue_module);
    const exe = b.addExecutable(.{
        .name = "z-run",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Self-contained binary: `zig build -Dscript=file.js [-Dname=app]` bakes
    // the script into a standalone executable (engine + script), separate
    // from the normal argv-reading z-run. Single-file (run as a script).
    if (b.option([]const u8, "script", "Embed this .js and build a self-contained binary")) |script_path| {
        const bin_name = b.option([]const u8, "name", "Output binary name for -Dscript") orelse "app";
        const embed_module = b.createModule(.{
            .root_source_file = b.path("src/embed_main.zig"),
            .target = target,
            .optimize = optimize,
        });
        embed_module.addImport("zrun", zrun_module);
        embed_module.addImport("zinterpreter", zinterpreter_module);
        embed_module.addImport("zvalue", zvalue_module);
        // @embedFile("embedded_script") in embed_main.zig resolves here.
        // Accept both build-root-relative and absolute -Dscript paths.
        const script_lp: std.Build.LazyPath = if (std.fs.path.isAbsolute(script_path))
            .{ .cwd_relative = script_path }
        else
            b.path(script_path);
        embed_module.addAnonymousImport("embedded_script", .{ .root_source_file = script_lp });
        const app = b.addExecutable(.{ .name = bin_name, .root_module = embed_module });
        b.installArtifact(app);
    }

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/os_test.zig",
        "tests/yaml_test.zig",
    };

    inline for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("zrun", zrun_module);
        unit_tests.root_module.addImport("zinterpreter", zinterpreter_module);
        unit_tests.root_module.addImport("zvalue", zvalue_module);
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    b.default_step = test_step;
}
