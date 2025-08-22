const napi = @import("../../sys/api.zig");

pub const Null = struct {
    env: napi.napi_env,
    value: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Null {
        return Null{ .env = env, .value = raw, .type = napi.napi_null };
    }
};
