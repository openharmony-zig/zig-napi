const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const napi = b.dependency("zig-napi", .{}).module("napi");
    const source = b.path("src/lib.zig");

    _ = try napi_build.nativeAddonBuild(b, .{
        .name = "__ADDON_NAME__",
        .napi_module = napi,
        .root_module_options = .{
            .root_source_file = source,
            .target = target,
            .optimize = optimize,
        },
    });
    const declarations = try napi_build.generateTypeDefinition(b, .{
        .root_source_file = source,
        .napi_module = napi,
        .output = b.path("package/types/Index.d.ts"),
    });
    b.getInstallStep().dependOn(&declarations.step);
}
