const std = @import("std");

const nativeBuild = @import("zig-addon-ohos").zigAddonBuild;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    try nativeBuild.nativeAddonBuild(b, .{
        .name = "add",
        .root_source_file = b.path("./src/add.zig"),
        .target = target,
        .optimize = optimize,
    });
}
