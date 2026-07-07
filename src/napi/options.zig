const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const NapiVersion = enum(i32) {
    v1 = 1,
    v2 = 2,
    v3 = 3,
    v4 = 4,
    v5 = 5,
    v6 = 6,
    v7 = 7,
    v8 = 8,
    v9 = 9,
    v10 = 10,
    experimental = std.math.maxInt(i32),

    pub inline fn isAtLeast(self: NapiVersion, min_version: NapiVersion) bool {
        return @intFromEnum(self) >= @intFromEnum(min_version);
    }
};

pub fn selectedNapiVersion() NapiVersion {
    return @enumFromInt(build_options.napi_version);
}

pub fn experimentalEnabled() bool {
    return build_options.napi_experimental;
}

pub fn isNodeAddon() bool {
    return build_options.node_addon;
}

pub fn isWasmNodeAddon() bool {
    return build_options.node_addon and builtin.cpu.arch == .wasm32 and builtin.os.tag == .wasi;
}

pub fn isOhosAddon() bool {
    return !build_options.node_addon;
}

pub fn requireNapiVersion(comptime required: NapiVersion) void {
    const selected = comptime selectedNapiVersion();
    if (!selected.isAtLeast(required)) {
        const required_name = comptime @tagName(required);
        const selected_name = comptime @tagName(selected);
        @compileError(std.fmt.comptimePrint(
            \\[ Node-API Version Mismatch ]
            \\Expected `{[required_name]s}` (N-API {[required_number]d}) or greater, got `{[selected_name]s}` (N-API {[selected_number]d}).
            \\Set `.node_api.version = .{[required_name]s}` in `nodeAddonBuild` or `nativeAddonBuild`.
            \\
        , .{
            .required_name = required_name,
            .required_number = @intFromEnum(required),
            .selected_name = selected_name,
            .selected_number = @intFromEnum(selected),
        }));
    }
}
