// re-export napi
pub const napi = @cImport({
    @cInclude("napi/native_api.h");
});

pub const napi_value = napi.napi_value;
pub const napi_env = napi.napi_env;
pub const napi_callback_info = napi.napi_callback_info;
pub const napi_valuetype = napi.napi_valuetype;
pub const napi_get_cb_info = napi.napi_get_cb_info;
pub const napi_typeof = napi.napi_typeof;
pub const napi_get_value_double = napi.napi_get_value_double;
pub const napi_create_double = napi.napi_create_double;
pub const napi_create_object = napi.napi_create_object;
