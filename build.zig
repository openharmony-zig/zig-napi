const std = @import("std");

pub const napi_build = @import("src/build/napi-build.zig");

pub fn build(b: *std.Build) !void {
    const napi_sys = b.addModule("napi_sys", .{
        .root_source_file = b.path("src/sys/api.zig"),
    });

    const napi = b.addModule("napi", .{
        .root_source_file = b.path("src/napi.zig"),
    });
    const build_options = b.addModule("build_options", .{
        .root_source_file = b.path("src/build/options.zig"),
    });

    napi.addImport("napi-sys", napi_sys);
    napi.addImport("build_options", build_options);
    napi_sys.addImport("build_options", build_options);

    napi.addIncludePath(b.path("src/sys/ohos"));
    napi_sys.addIncludePath(b.path("src/sys/ohos"));

    // Importing a Zig module does not instantiate its generic entrypoints.
    // Keep an explicit host-addon check and a runnable test target for maintainers.
    const check = b.step("check", "Compile the host Node addons and public API regression fixtures");
    const compile_check = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--summary", "failures" });
    compile_check.setCwd(b.path("node-test"));
    check.dependOn(&compile_check.step);

    const test_step = b.step("test", "Run Zig unit tests and the host Node regression suite");
    const node_tests = b.addSystemCommand(&.{ "npm", "run", "test:run" });
    node_tests.setCwd(b.path("node-test"));
    node_tests.step.dependOn(&compile_check.step);
    test_step.dependOn(&node_tests.step);

    const test_options = b.addOptions();
    test_options.addOption(bool, "node_addon", true);
    test_options.addOption(bool, "napi_tsgen", false);
    test_options.addOption(i32, "napi_version", 8);
    test_options.addOption(bool, "napi_experimental", false);
    const unit_options = test_options.createModule();
    const unit_sys = b.createModule(.{ .root_source_file = b.path("src/sys/api.zig") });
    unit_sys.addImport("build_options", unit_options);
    const unit_root = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = b.graph.host,
    });
    unit_root.addImport("napi-sys", unit_sys);
    unit_root.addImport("build_options", unit_options);
    const unit_tests = b.addTest(.{ .root_module = unit_root });
    const run_units = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_units.step);
    b.step("test-unit", "Run the Zig unit tests").dependOn(&run_units.step);
}
