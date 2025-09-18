const napi = @import("napi-sys");
const Napi = @import("./util/napi.zig").Napi;

pub const Object = @import("./value/object.zig").Object;
pub const Number = @import("./value/number.zig").Number;
pub const String = @import("./value/string.zig").String;
pub const BigInt = @import("./value/bigint.zig").BigInt;
pub const Null = @import("./value/null.zig").Null;
pub const Undefined = @import("./value/undefined.zig").Undefined;
pub const Promise = @import("./value/promise.zig").Promise;
pub const Bool = @import("./value/bool.zig").Bool;
pub const Array = @import("./value/array.zig").Array;

pub const NapiValue = struct {
    env: napi.napi_env,
    raw: napi.napi_value,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) NapiValue {
        return NapiValue{
            .env = env,
            .raw = raw,
        };
    }

    pub fn As(self: NapiValue, comptime T: type) T {
        return Napi.from_napi_value(self.env, self.raw, T);
    }
};
