const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const helper = @import("../util/helper.zig");
const Napi = @import("../util/napi.zig").Napi;
const NapiError = @import("../wrapper/error.zig");

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

    /// Strict numeric conversion. See `Napi.numericFromNapiValue` for the rules;
    /// the fast path uses exactly the same validation.
    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .float, .int => return Napi.numericFromNapiValue(env, raw, T),
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        }
    }

    pub fn New(env: Env, value: anytype) Number {
        return create(env, value) catch @panic("napi: failed to create number value");
    }

    /// Failing constructor used by the conversion layer.
    pub fn create(env: Env, value: anytype) !Number {
        const value_type = @TypeOf(value);

        if (@typeInfo(value_type) != .float and @typeInfo(value_type) != .int and @typeInfo(value_type) != .comptime_int and @typeInfo(value_type) != .comptime_float) {
            @compileError("Only support float, int, comptime_int and comptime_float type, Unsupported type: " ++ @typeName(value_type));
        }

        const merge_type = switch (value_type) {
            comptime_int => comptime helper.comptimeIntMode(value),
            comptime_float => comptime helper.comptimeFloatMode(value),
            else => value_type,
        };

        var result: napi.napi_value = undefined;
        const status = switch (merge_type) {
            f16, f32, f64 => napi.napi_create_double(env.raw, @floatCast(value), &result),
            i8,
            i16,
            i32,
            => napi.napi_create_int32(env.raw, @intCast(value), &result),
            i64, isize => napi.napi_create_int64(env.raw, @intCast(value), &result),
            u8, u16, u32 => napi.napi_create_uint32(env.raw, @intCast(value), &result),
            // 64 bit unsigned values do not fit `napi_create_int64`; JavaScript
            // numbers are exact up to 2^53, use `napi.BigInt` beyond that.
            u64, usize => napi.napi_create_double(env.raw, @floatFromInt(value), &result),
            else => {
                @compileError("For u128, i128, f128 please use BigInt instead");
            },
        };
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return Number.from_raw(env.raw, result);
    }
};
