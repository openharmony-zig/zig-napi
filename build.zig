const std = @import("std");

pub const napi_build = @import("src/build/napi-build.zig");

pub fn build(b: *std.Build) !void {
    const napi_sys = b.addModule("napi_sys", .{
        .root_source_file = b.path("src/sys/api.zig"),
    });

    const napi = b.addModule("napi", .{
        .root_source_file = b.path("src/napi.zig"),
    });

    napi.addImport("napi-sys", napi_sys);

    napi.addIncludePath(b.path("src/sys/header"));
    napi_sys.addIncludePath(b.path("src/sys/header"));
}
