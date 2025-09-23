const napi = @import("napi-sys").napi_sys;
const Undefined = @import("./value/undefined.zig").Undefined;
const Null = @import("./value/null.zig").Null;

pub const Env = struct {
    raw: napi.napi_env,

    pub fn from_raw(raw: napi.napi_env) Env {
        return Env{
            .raw = raw,
        };
    }

    pub fn getUndefined(self: Env) Undefined {
        var result: napi.napi_value = undefined;
        _ = napi.napi_get_undefined(self.raw, &result);
        return Undefined.from_raw(self.raw, result);
    }

    pub fn getNull(self: Env) Null {
        var result: napi.napi_value = undefined;
        _ = napi.napi_get_null(self.raw, &result);
        return Null.from_raw(self.raw, result);
    }
};
