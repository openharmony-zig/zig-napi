const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const helper = @import("../util/helper.zig");

pub const BigInt = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) BigInt {
        return BigInt{ .env = env, .raw = raw, .type = napi.napi_bigint };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const value_type = @TypeOf(T);
        const infos = @typeInfo(value_type);

        switch (infos) {
            .i64 => {
                var result: T = undefined;
                _ = napi.napi_get_value_bigint_int64(env, raw, @ptrCast(&result), false);
                return result;
            },
            .u64 => {
                var result: T = undefined;
                _ = napi.napi_get_value_bigint_uint64(env, raw, @ptrCast(&result), false);
                return result;
            },
            else => {
                @compileError("Unsupported type: " ++ @typeName(value_type));
            },
        }
    }

    pub fn New(env: Env, value: anytype) BigInt {
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);

        const merge_type = switch (value_type) {
            comptime_int => comptime helper.comptimeIntMode(value),
            comptime_float => comptime helper.comptimeFloatMode(value),
            else => value_type,
        };

        switch (infos) {
            .float, .int, .comptime_int, .comptime_float => {
                switch (merge_type) {
                    u128 => {
                        var result: napi.napi_value = undefined;
                        var words: [2]u64 = undefined;
                        words[0] = @truncate(value);
                        words[1] = @truncate(value >> 64);

                        const word_count: usize = if (words[1] != 0) 2 else 1;

                        _ = napi.napi_create_bigint_words(env.raw, 0, word_count, @ptrCast(words.ptr), &result);
                        return BigInt.from_raw(env.raw, result);
                    },
                    i128 => {
                        var result: napi.napi_value = undefined;

                        const is_negative = value < 0;
                        const abs_value: u128 = if (is_negative) @bitCast(-value) else @bitCast(value);

                        var words: [2]u64 = undefined;
                        words[0] = @truncate(abs_value);
                        words[1] = @truncate(abs_value >> 64);

                        const word_count: usize = if (words[1] != 0) 2 else 1;

                        _ = napi.napi_create_bigint_words(env.raw, if (is_negative) @as(c_int, 1) else @as(c_int, 0), word_count, @ptrCast(words.ptr), &result);
                        return BigInt.from_raw(env.raw, result);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};
