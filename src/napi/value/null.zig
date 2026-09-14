const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const NapiError = @import("../wrapper/error.zig");

pub const Null = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Null {
        return Null{ .env = env, .raw = raw, .type = napi.napi_null };
    }

    /// Failing constructor: reports the N-API status instead of leaving `raw` unset.
    pub fn create(env: Env) !Null {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_get_null(env.raw, &raw);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return Null.from_raw(env.raw, raw);
    }

    /// Legacy infallible constructor. Panics when the runtime reports an error
    /// instead of returning a value with an uninitialized handle.
    pub fn New(env: Env) Null {
        return create(env) catch @panic("napi: failed to create null value");
    }
};
