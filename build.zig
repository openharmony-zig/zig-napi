const std = @import("std");

pub const napi_build = @import("src/build/napi-build.zig");

pub fn build(b: *std.Build) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const napi = b.addModule("napi", .{
        .root_source_file = b.path("src/napi.zig"),
    });

    const napi_private = b.createModule(.{
        .root_source_file = b.path("src/napi.zig"),
    });

    const rootPath = try napi_build.resolveNdkPath();
    const includePath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "include" });
    const libPath = try std.fs.path.join(allocator, &[_][]const u8{ rootPath, "sysroot", "usr", "lib" });
    const platformPath = try std.fs.path.join(allocator, &[_][]const u8{ includePath, "aarch64-linux-ohos" });
    const platformLibPath = try std.fs.path.join(allocator, &[_][]const u8{ libPath, "aarch64-linux-ohos" });

    napi.addIncludePath(.{ .cwd_relative = includePath });
    napi.addLibraryPath(.{ .cwd_relative = libPath });
    napi.addIncludePath(.{ .cwd_relative = platformPath });
    napi.addLibraryPath(.{ .cwd_relative = platformLibPath });

    napi_private.addIncludePath(.{ .cwd_relative = includePath });
    napi_private.addLibraryPath(.{ .cwd_relative = libPath });
    napi_private.addIncludePath(.{ .cwd_relative = platformPath });
    napi_private.addLibraryPath(.{ .cwd_relative = platformLibPath });
}
