const std = @import("std");
const build_options = @import("build_options");

pub const napi_sys = if (build_options.node_addon)
    @import("node.zig")
else
    @cImport({
        @cDefine("NAPI_VERSION", std.fmt.comptimePrint("{d}", .{build_options.napi_version}));
        if (build_options.napi_experimental) {
            @cDefine("NAPI_EXPERIMENTAL", "1");
        }
        @cInclude("native_api.h");
    });
