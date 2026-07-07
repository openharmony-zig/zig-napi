const std = @import("std");
const napi = @import("napi");

pub fn createBigInt(env: napi.Env) napi.BigInt {
    return napi.BigInt.New(env, @as(i128, 9007199254740993));
}

pub fn makeBigInt(env: napi.Env) napi.BigInt {
    return createBigInt(env);
}

pub fn bigintToI64(value: napi.BigInt) i64 {
    return napi.BigInt.from_napi_value(value.env, value.raw, i64);
}

pub fn bigintAdd(env: napi.Env, left: napi.BigInt, right: napi.BigInt) napi.BigInt {
    const left_value = napi.BigInt.from_napi_value(left.env, left.raw, i64);
    const right_value = napi.BigInt.from_napi_value(right.env, right.raw, i64);
    return napi.BigInt.New(env, @as(i128, left_value + right_value));
}

pub fn mutateI64Array(values: napi.BigInt64Array) !void {
    if (values.length() > 0) {
        values.asSlice()[0] = std.math.maxInt(i64);
    }
    try values.flush();
}
