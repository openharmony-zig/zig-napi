const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;

pub const Undefined = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Undefined {
        return Undefined{ .env = env, .raw = raw, .type = napi.napi_undefined };
    }

    pub fn New(env: Env) Undefined {
        var raw: napi.napi_value = undefined;
        _ = napi.napi_get_undefined(env.raw, &raw);
        return Undefined.from_raw(env.raw, raw);
    }
};
