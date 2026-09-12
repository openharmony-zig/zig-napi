const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const NapiError = @import("../wrapper/error.zig");

pub const Bool = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Bool {
        return Bool{ .env = env, .raw = raw, .type = napi.napi_boolean };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        if (comptime T != bool) {
            @compileError("Bool can only convert to bool, got: " ++ @typeName(T));
        }
        var result: bool = false;
        const status = napi.napi_get_value_bool(env, raw, &result);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return result;
    }

    pub fn New(env: Env, value: bool) Bool {
        return create(env, value) catch @panic("napi: failed to create boolean value");
    }

    /// Failing constructor used by the conversion layer.
    pub fn create(env: Env, value: bool) !Bool {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_get_boolean(env.raw, value, &raw);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return Bool.from_raw(env.raw, raw);
    }
};
