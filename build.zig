const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Feature flags: each disables a host extension's JS-visible surface
    // AND its underlying sibling dependency (never imported, so the linker
    // never sees it) -- not just a runtime no-op. All default true, so a
    // plain `zig build` is unchanged. `crypto-*` sub-flags are additionally
    // gated by the `crypto` master switch (see `enable_crypto_*` below).
    const enable_yaml = b.option(bool, "yaml", "Enable the YAML global (YAML.parse/stringify)") orelse true;
    const enable_toml = b.option(bool, "toml", "Enable the TOML global (TOML.parse/stringify)") orelse true;
    const enable_args = b.option(bool, "args", "Enable the os.argsParser.* namespace (z-args' Simple tier)") orelse true;
    const enable_crypto = b.option(bool, "crypto", "Enable the os.crypto.* namespace (master switch)") orelse true;
    const enable_crypto_uuid = enable_crypto and (b.option(bool, "crypto-uuid", "Enable os.crypto.uuid.*") orelse true);
    const enable_crypto_random = enable_crypto and (b.option(bool, "crypto-random", "Enable os.crypto.random.*") orelse true);
    const enable_crypto_hash = enable_crypto and (b.option(bool, "crypto-hash", "Enable os.crypto.hash.*") orelse true);
    const enable_crypto_hmac = enable_crypto and (b.option(bool, "crypto-hmac", "Enable os.crypto.hmac.*") orelse true);
    const enable_crypto_aead = enable_crypto and (b.option(bool, "crypto-aead", "Enable os.crypto.aead.*") orelse true);
    const enable_crypto_password = enable_crypto and (b.option(bool, "crypto-password", "Enable os.crypto.password.*") orelse true);
    const enable_crypto_base32 = enable_crypto and (b.option(bool, "crypto-base32", "Enable os.crypto.base32.*") orelse true);
    const enable_crypto_totp = enable_crypto and (b.option(bool, "crypto-totp", "Enable os.crypto.totp.*") orelse true);
    const enable_crypto_jws = enable_crypto and (b.option(bool, "crypto-jws", "Enable os.crypto.jws.*") orelse true);

    const feature_options = b.addOptions();
    feature_options.addOption(bool, "enable_yaml", enable_yaml);
    feature_options.addOption(bool, "enable_toml", enable_toml);
    feature_options.addOption(bool, "enable_args", enable_args);
    feature_options.addOption(bool, "enable_crypto", enable_crypto);
    feature_options.addOption(bool, "enable_crypto_uuid", enable_crypto_uuid);
    feature_options.addOption(bool, "enable_crypto_random", enable_crypto_random);
    feature_options.addOption(bool, "enable_crypto_hash", enable_crypto_hash);
    feature_options.addOption(bool, "enable_crypto_hmac", enable_crypto_hmac);
    feature_options.addOption(bool, "enable_crypto_aead", enable_crypto_aead);
    feature_options.addOption(bool, "enable_crypto_password", enable_crypto_password);
    feature_options.addOption(bool, "enable_crypto_base32", enable_crypto_base32);
    feature_options.addOption(bool, "enable_crypto_totp", enable_crypto_totp);
    feature_options.addOption(bool, "enable_crypto_jws", enable_crypto_jws);
    const build_options_module = feature_options.createModule();

    const zinterpreter_dep = b.dependency("zinterpreter", .{ .target = target, .optimize = optimize });
    const zinterpreter_module = zinterpreter_dep.module("zinterpreter");

    const zvalue_dep = b.dependency("zvalue", .{ .target = target, .optimize = optimize });
    const zvalue_module = zvalue_dep.module("zvalue");

    const zrun_module = b.addModule("zrun", .{
        .root_source_file = b.path("src/zrun.zig"),
    });
    zrun_module.addImport("zinterpreter", zinterpreter_module);
    zrun_module.addImport("zvalue", zvalue_module);
    zrun_module.addImport("build_options", build_options_module);

    // zargs is a mandatory import of zrun_module now (unlike the
    // conditionally-fetched siblings below): `compile_cmd.zig` (the
    // `z-run compile` subcommand) always needs its Declarative tier,
    // independent of `-Dargs` -- that flag only gates the JS-visible
    // `os.argsParser.*` surface (see `args_globals.zig`'s own
    // `if (comptime !build_options.enable_args) return;` guard).
    const zargs_dep = b.dependency("zargs", .{ .target = target, .optimize = optimize });
    zrun_module.addImport("zargs", zargs_dep.module("zargs"));

    // Each sibling below is only fetched/built/linked when its flag is on
    // -- an `if (comptime !build_options.enable_x) return;` guard at the
    // top of the corresponding `*_globals.zig install()` means the
    // disabled module's import is never referenced, so it's fine for it
    // to not exist in the import table at all.
    if (enable_yaml) {
        const zyaml_dep = b.dependency("zyaml", .{ .target = target, .optimize = optimize });
        zrun_module.addImport("zyaml", zyaml_dep.module("zyaml"));
    }
    if (enable_toml) {
        const ztoml_dep = b.dependency("ztoml", .{ .target = target, .optimize = optimize });
        zrun_module.addImport("ztoml", ztoml_dep.module("ztoml"));
    }
    if (enable_crypto_uuid) {
        const zuuid_dep = b.dependency("zuuid", .{ .target = target, .optimize = optimize });
        zrun_module.addImport("zuuid", zuuid_dep.module("zuuid"));
    }
    if (enable_crypto) {
        const zcrypto_dep = b.dependency("zcrypto", .{ .target = target, .optimize = optimize });
        zrun_module.addImport("zcrypto", zcrypto_dep.module("zcrypto"));
    }

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
        "tests/toml_test.zig",
        "tests/crypto_test.zig",
        "tests/args_test.zig",
        "tests/payload_test.zig",
        "tests/compile_cmd_test.zig",
        "tests/cli_args_test.zig",
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
