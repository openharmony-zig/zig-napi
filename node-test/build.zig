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
    try addNodeAddonWith(b, napi, name, source, target, optimize, null);
}

fn addNodeAddonWith(
    b: *std.Build,
    napi: *std.Build.Module,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    extra_imports: ?[]const struct { []const u8, *std.Build.Module },
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
    if (std.mem.eql(u8, name, "audit")) {
        addon.root_module.addImport("audit_counting", b.createModule(.{
            .root_source_file = b.path("../examples/allocator-custom/src/counting_allocator.zig"),
        }));
        const example_async = b.createModule(.{
            .root_source_file = b.path("../examples/basic/src/async.zig"),
        });
        example_async.addImport("napi", addon.root_module.import_table.get("napi").?);
        addon.root_module.addImport("example_async", example_async);
        const memory_async = b.createModule(.{
            .root_source_file = b.path("../examples/memory/src/async.zig"),
        });
        memory_async.addImport("napi", addon.root_module.import_table.get("napi").?);
        addon.root_module.addImport("memory_async", memory_async);
    }
    const npm_root_install = b.addInstallFileWithDir(
        addon.getEmittedBin(),
        .{ .custom = ".." },
        napi_build.nodeAddonFilename(b, name, target),
    );
    b.getInstallStep().dependOn(&npm_root_install.step);

    if (extra_imports) |imports| {
        for (imports) |entry| {
            addon.root_module.addImport(entry[0], entry[1]);
        }
    }
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
    try addNodeAddon(b, napi, "audit", "audit/src/lib.zig", target, optimize);

    // Conversion/ownership regression addon. It uses its own counting allocator
    // so the spec can assert that conversions return to their allocation
    // baseline, including on the failure paths.
    const counting_allocator = b.createModule(.{
        .root_source_file = b.path("../examples/allocator-custom/src/counting_allocator.zig"),
    });
    try addNodeAddonWith(
        b,
        napi,
        "conversion_audit",
        "napi/src/conversion_audit.zig",
        target,
        optimize,
        &.{.{ "counting", counting_allocator }},
    );
    try addNodeAddonWith(
        b,
        napi,
        "classes_audit",
        "napi/src/classes_audit.zig",
        target,
        optimize,
        &.{.{ "counting", counting_allocator }},
    );

    // Dedicated regression addon for the async/abort/TSFN/runtime audit
    // findings. Kept separate from lib.zig so the audit exports can evolve
    // without touching the shared example module.
    try addNodeAddon(
        b,
        napi,
        "async_audit",
        "napi/src/async_audit.zig",
        target,
        optimize,
    );
}
