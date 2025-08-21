const napi = @import("../../sys/api.zig").napi;
const Env = @import("../env.zig").Env;
const Value = @import("../value.zig").Value;

pub const Number = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Number {
        return Number{
            .env = env,
            .raw = raw,
            .type = napi.napi_number,
        };
    }

    pub fn New(env: Env, value: anytype) Number {
        const value_type = @TypeOf(value);
        switch (value_type) {
            f64 => {
                var result: napi.napi_value = undefined;
                _ = napi.napi_create_double(env.raw, @floatCast(value), &result);
                return Number.from_raw(env.raw, result);
            },
            else => {
                @compileError("Unsupported type: " ++ @typeName(value_type));
            },
        }
    }

    pub fn ToValue(self: Number) Value {
        return Value{ .Number = self };
    }

    pub fn FloatValue(self: Number) f64 {
        var result: f64 = undefined;
        _ = napi.napi_get_value_double(self.env, self.raw, &result);
        return result;
    }
};
