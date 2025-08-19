const std = @import("std");

pub const napi_build = @import("src/build/napi-build.zig");

pub fn build(b: *std.Build) !void {
    const napi = b.addModule("napi", .{
        .root_source_file = b.path("src/napi.zig"),
    });

    const napi_private = b.createModule(.{
        .root_source_file = b.path("src/napi.zig"),
    });

    try napi_build.linkNapi(napi);
    try napi_build.linkNapi(napi_private);
}
