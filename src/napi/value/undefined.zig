const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const NapiError = @import("../wrapper/error.zig");

pub const Undefined = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Undefined {
        return Undefined{ .env = env, .raw = raw, .type = napi.napi_undefined };
    }

    /// Failing constructor: reports the N-API status instead of leaving `raw` unset.
    pub fn create(env: Env) !Undefined {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_get_undefined(env.raw, &raw);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return Undefined.from_raw(env.raw, raw);
    }

    /// Legacy infallible constructor. Panics when the runtime reports an error
    /// instead of returning a value with an uninitialized handle.
    pub fn New(env: Env) Undefined {
        return create(env) catch @panic("napi: failed to create undefined value");
    }
};
