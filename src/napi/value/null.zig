const napi = @import("napi").napi_sys;

pub const Null = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Null {
        return Null{ .env = env, .raw = raw, .type = napi.napi_null };
    }
};
