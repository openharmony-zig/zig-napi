const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_napi = b.dependency("zig-napi", .{});
    const napi = zig_napi.module("napi");

    const addon = try napi_build.nodeAddonBuild(b, .{
        .name = "__ADDON_NAME__",
        .napi_module = napi,
        .node_api = .{
            .version = .v8,
            .experimental = false,
        },
        .root_module_options = .{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        },
    });
    _ = addon;

    const dts = try napi_build.generateTypeDefinition(b, .{
        .root_source_file = b.path("src/lib.zig"),
        .output = b.path("index.d.ts"),
        .napi_module = napi,
        .node_api = .{
            .version = .v8,
            .experimental = false,
        },
    });
    b.getInstallStep().dependOn(&dts.step);
}
