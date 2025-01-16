const std = @import("std");

pub const zigAddonBuild = @import("src/zig-addon-build.zig");

pub fn build(b: *std.Build) !void {
    _ = b.addModule("zigAddonBuild", .{
        .root_source_file = b.path("src/zig-addon-build.zig"),
    });
}
