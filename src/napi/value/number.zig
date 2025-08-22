const std = @import("std");
const napi = @import("../../sys/api.zig");
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

        if (@typeInfo(value_type) != std.builtin.Type.Float and @typeInfo(value_type) != std.builtin.Type.Int) {
            @compileError("Only support float and int type, Unsupported type: " ++ @typeName(value_type));
        }

        switch (value_type) {
            f16, f32, f64 => {
                var result: napi.napi_value = undefined;
                _ = napi.napi_create_double(env.raw, @floatCast(value), &result);
                return Number.from_raw(env.raw, result);
            },
            isize,
            i8,
            i16,
            i32,
            => {
                var result: napi.napi_value = undefined;
                _ = napi.napi_create_int32(env.raw, @intCast(value), &result);
                return Number.from_raw(env.raw, result);
            },
            i64 => {
                var result: napi.napi_value = undefined;
                _ = napi.napi_create_int64(env.raw, @intCast(value), &result);
                return Number.from_raw(env.raw, result);
            },
            usize, u8, u16, u32 => {
                var result: napi.napi_value = undefined;
                _ = napi.napi_create_uint32(env.raw, @intCast(value), &result);
                return Number.from_raw(env.raw, result);
            },
            u64 => {
                var result: napi.napi_value = undefined;
                _ = napi.napi_create_uint64(env.raw, @intCast(value), &result);
                return Number.from_raw(env.raw, result);
            },
            else => {
                @compileError("For u128, i128, f128 please use BigInt instead");
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
