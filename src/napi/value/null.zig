const napi = @import("../../sys/api.zig");
const Env = @import("../env.zig").Env;

pub const Null = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Null {
        return Null{ .env = env, .raw = raw, .type = napi.napi_null };
    }

    pub fn New(env: Env) Null {
        var raw: napi.napi_value = undefined;
        _ = napi.napi_get_null(env.raw, &raw);
        return Null.from_raw(env.raw, raw);
    }
};
