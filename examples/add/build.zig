const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_napi = b.dependency("zig-napi", .{});

    const napi = zig_napi.module("napi");

    var arm64, var arm, var x64 = try napi_build.nativeAddonBuild(b, .{
        .name = "hello",
        .root_source_file = b.path("./src/hello.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = arm64.root_module.addImport("napi", napi);
    _ = arm.root_module.addImport("napi", napi);
    _ = x64.root_module.addImport("napi", napi);
}
