const std = @import("std");
const napi_build = @import("zig-napi").napi_build;

fn addNodeAddon(
    b: *std.Build,
    napi: *std.Build.Module,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const addon = try napi_build.nodeAddonBuild(b, .{
        .name = name,
        .napi_module = napi,
        .node_api = .{
            // Keep the node-version matrix loadable on Node 12 while still
            // covering the N-API v4/v5/v6/v7/v8 gated surfaces.
            .version = .v8,
            .experimental = false,
        },
        .root_module_options = .{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        },
    });
    const npm_root_install = b.addInstallFileWithDir(
        addon.getEmittedBin(),
        .{ .custom = ".." },
        napi_build.nodeAddonFilename(b, name, target),
    );
    b.getInstallStep().dependOn(&npm_root_install.step);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_napi = b.dependency("zig-napi", .{});
    const napi = zig_napi.module("napi");

    try addNodeAddon(
        b,
        napi,
        "compat_mode",
        "napi-compat-mode/src/lib.zig",
        target,
        optimize,
    );

    try addNodeAddon(
        b,
        napi,
        "example",
        "napi/src/lib.zig",
        target,
        optimize,
    );
}
