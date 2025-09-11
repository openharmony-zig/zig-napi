const napi = @import("../../sys/api.zig");
const Env = @import("../env.zig").Env;

pub const Bool = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Bool {
        return Bool{ .env = env, .raw = raw, .type = napi.napi_boolean };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        var result: T = undefined;
        _ = napi.napi_get_value_bool(env, raw, &result);
        return result;
    }

    pub fn New(env: Env, value: bool) Bool {
        var raw: napi.napi_value = undefined;
        _ = napi.napi_get_boolean(env.raw, value, &raw);
        return Bool.from_raw(env.raw, raw);
    }
};
