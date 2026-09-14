const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const helper = @import("../util/helper.zig");
const NapiError = @import("../wrapper/error.zig");
const options = @import("../options.zig");

pub const BigInt = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) BigInt {
        comptime options.requireNapiVersion(.v6);
        return BigInt{ .env = env, .raw = raw, .type = napi.napi_bigint };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        comptime options.requireNapiVersion(.v6);
        switch (T) {
            i64 => {
                var result: i64 = 0;
                var lossless = false;
                const status = napi.napi_get_value_bigint_int64(env, raw, &result, &lossless);
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }
                if (!lossless) {
                    return NapiError.failRangeError("BigInt value does not fit into i64", .{});
                }
                return result;
            },
            u64 => {
                var result: u64 = 0;
                var lossless = false;
                const status = napi.napi_get_value_bigint_uint64(env, raw, &result, &lossless);
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }
                if (!lossless) {
                    return NapiError.failRangeError("BigInt value does not fit into u64", .{});
                }
                return result;
            },
            else => {
                @compileError("Unsupported type: " ++ @typeName(T));
            },
        }
    }

    pub fn New(env: Env, value: anytype) BigInt {
        return create(env, value) catch @panic("napi: failed to create bigint value");
    }

    /// Failing constructor used by the conversion layer.
    pub fn create(env: Env, value: anytype) !BigInt {
        comptime options.requireNapiVersion(.v6);
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);

        const merge_type = switch (value_type) {
            comptime_int => comptime helper.comptimeIntMode(value),
            comptime_float => comptime helper.comptimeFloatMode(value),
            else => value_type,
        };

        var result: napi.napi_value = undefined;
        switch (infos) {
            .float, .comptime_float => {
                @compileError("BigInt cannot be created from a float, got: " ++ @typeName(value_type));
            },
            .int, .comptime_int => {
                const merge_info = @typeInfo(merge_type);
                if (merge_info.int.bits <= 64) {
                    const status = if (merge_info.int.signedness == .signed)
                        napi.napi_create_bigint_int64(env.raw, @intCast(value), &result)
                    else
                        napi.napi_create_bigint_uint64(env.raw, @intCast(value), &result);
                    if (status != napi.napi_ok) {
                        return NapiError.failStatus(status);
                    }
                    return BigInt.from_raw(env.raw, result);
                }
                switch (merge_type) {
                    u128 => {
                        var words: [2]u64 = undefined;
                        words[0] = @truncate(value);
                        words[1] = @truncate(value >> 64);

                        const word_count: usize = if (words[1] != 0) 2 else 1;

                        const status = napi.napi_create_bigint_words(env.raw, 0, word_count, @ptrCast(&words), &result);
                        if (status != napi.napi_ok) {
                            return NapiError.failStatus(status);
                        }
                        return BigInt.from_raw(env.raw, result);
                    },
                    i128 => {
                        const is_negative = value < 0;
                        const abs_value: u128 = if (is_negative) @bitCast(-value) else @bitCast(value);

                        var words: [2]u64 = undefined;
                        words[0] = @truncate(abs_value);
                        words[1] = @truncate(abs_value >> 64);

                        const word_count: usize = if (words[1] != 0) 2 else 1;

                        const status = napi.napi_create_bigint_words(env.raw, if (is_negative) @as(c_int, 1) else @as(c_int, 0), word_count, @ptrCast(&words), &result);
                        if (status != napi.napi_ok) {
                            return NapiError.failStatus(status);
                        }
                        return BigInt.from_raw(env.raw, result);
                    },
                    else => {
                        @compileError("BigInt only supports integers up to 128 bits, got: " ++ @typeName(value_type));
                    },
                }
            },
            else => {
                @compileError("BigInt only supports integers up to 128 bits, got: " ++ @typeName(value_type));
            },
        }
    }
};
