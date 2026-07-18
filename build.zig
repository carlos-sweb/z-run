const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zinterpreter_dep = b.dependency("zinterpreter", .{ .target = target, .optimize = optimize });
    const zinterpreter_module = zinterpreter_dep.module("zinterpreter");

    const zvalue_dep = b.dependency("zvalue", .{ .target = target, .optimize = optimize });
    const zvalue_module = zvalue_dep.module("zvalue");

    const zrun_module = b.addModule("zrun", .{
        .root_source_file = b.path("src/zrun.zig"),
    });
    zrun_module.addImport("zinterpreter", zinterpreter_module);
    zrun_module.addImport("zvalue", zvalue_module);

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

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/os_test.zig",
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
