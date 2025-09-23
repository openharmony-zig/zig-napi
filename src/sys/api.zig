const sys = @cImport({
    @cInclude("native_api.h");
});

pub const napi_sys = sys;
