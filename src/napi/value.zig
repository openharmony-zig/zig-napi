const napi = @import("../sys/api.zig");

pub const Object = @import("./value/object.zig").Object;
pub const Number = @import("./value/number.zig").Number;
pub const String = @import("./value/string.zig").String;

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
        return T.from_raw(self.env, self.raw);
    }
};

pub const Value = union(enum) {
    Object: Object,
    Number: Number,
    String: String,
};
