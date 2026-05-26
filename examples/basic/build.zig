const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_napi = b.dependency("zig-napi", .{});

    const napi = zig_napi.module("napi");

    const result = try napi_build.nativeAddonBuild(b, .{
        .name = "hello",
        .napi_module = napi,
        .root_module_options = .{
            .root_source_file = b.path("./src/hello.zig"),
            .target = target,
            .optimize = optimize,
        },
    });

    if (result.arm64) |arm64| {
        if (arm64.rootModuleTarget().abi.isOpenHarmony()) {
            arm64.root_module.linkSystemLibrary("hilog_ndk.z", .{});
        }
    }
    if (result.arm) |arm| {
        if (arm.rootModuleTarget().abi.isOpenHarmony()) {
            arm.root_module.linkSystemLibrary("hilog_ndk.z", .{});
        }
    }
    if (result.x64) |x64| {
        if (x64.rootModuleTarget().abi.isOpenHarmony()) {
            x64.root_module.linkSystemLibrary("hilog_ndk.z", .{});
        }
    }

    const dts = try napi_build.generateTypeDefinition(b, .{
        .root_source_file = b.path("./src/hello.zig"),
        .output = b.path("index.d.ts"),
        .napi_module = napi,
    });
    b.getInstallStep().dependOn(&dts.step);
}
