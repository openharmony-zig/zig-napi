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
}
