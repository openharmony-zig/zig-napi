const std = @import("std");

const zigAddonBuild = @import("zig-addon").zigAddonBuild;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_addon = b.dependency("zig-addon", .{});

    const napi = zig_addon.module("napi");

    var arm64, var arm, var x64 = try zigAddonBuild.nativeAddonBuild(b, .{
        .name = "add",
        .root_source_file = b.path("./src/add.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = arm64.root_module.addImport("napi", napi);
    _ = arm.root_module.addImport("napi", napi);
    _ = x64.root_module.addImport("napi", napi);
}
