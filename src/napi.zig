const macro = @import("./prelude/module.zig");

// re-export napi
pub const napi = @cImport({
    @cInclude("napi/native_api.h");
});

// re-export macro
pub const NODE_API_MODULE = macro.NODE_API_MODULE;
