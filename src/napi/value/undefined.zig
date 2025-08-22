const napi = @import("napi").napi_sys;

pub const Undefined = struct {
    env: napi.napi_env,
    value: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Undefined {
        return Undefined{ .env = env, .value = raw, .type = napi.napi_undefined };
    }
};
