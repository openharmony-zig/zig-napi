const std = @import("std");

pub const napi_build = @import("src/build/napi-build.zig");

pub fn build(b: *std.Build) !void {
    const allocator = b.allocator;

    const napi = b.addModule("napi", .{
        .root_source_file = b.path("src/napi.zig"),
    });

    const rootPath = try napi_build.resolveNdkPath(b);
    const includePath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "include" });
    const platformPath = try std.fs.path.join(allocator, &[_][]const u8{ includePath, "aarch64-linux-ohos" });

    // TODO: we should't depends on platform path
    napi.addIncludePath(.{ .cwd_relative = includePath });
    napi.addIncludePath(.{ .cwd_relative = platformPath });
}
