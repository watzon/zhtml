const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("build", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var html5lib_tests = b.addTest("test/tokenizer-html5lib.zig");
    html5lib_tests.setBuildMode(mode);
    html5lib_tests.addPackagePath("zhtml/token", "src/token.zig");
    html5lib_tests.addPackagePath("zhtml/parse_error", "src/parse_error.zig");
    html5lib_tests.addPackagePath("zhtml/tokenizer", "src/tokenizer.zig");
    const html5lib_test_step = b.step("test-html5lib", "Run the tests from html5lib/html5lib-tests");
    html5lib_test_step.dependOn(&html5lib_tests.step);
}

// pub fn build(b: *Builder) void {
//     const mode = b.standardReleaseOptions();
//     const lib = b.addStaticLibrary("zhtml", "src/main.zig");
//     lib.setBuildMode(mode);
//     lib.install();

//     var main_tests = b.addTest("src/main.zig");
//     main_tests.setBuildMode(mode);

//     const test_step = b.step("test", "Run library tests");
//     test_step.dependOn(&main_tests.step);
// }
