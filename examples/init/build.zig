const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_napi = b.dependency("zig-napi", .{});

    const napi = zig_napi.module("napi");

    const result = try napi_build.nativeAddonBuild(b, .{
        .name = "hello",
        .root_module_options = .{
            .root_source_file = b.path("./src/hello.zig"),
            .target = target,
            .optimize = optimize,
        },
    });

    if (result.arm64) |arm64| {
        arm64.root_module.addImport("napi", napi);
    }
    if (result.arm) |arm| {
        arm.root_module.addImport("napi", napi);
    }
    if (result.x64) |x64| {
        x64.root_module.addImport("napi", napi);
    }
}
