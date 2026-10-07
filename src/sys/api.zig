const build_options = @import("build_options");
pub const node_addon = build_options.node_addon;
pub const wasmCrash = @import("wasm_crash.zig");

pub const napi_sys = if (build_options.node_addon)
    @import("node.zig")
else
    @import("ohos");
