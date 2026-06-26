const napi = @import("napi");

const NumberOrString = union(enum) {
    number: i32,
    string: []const u8,
};

pub fn eitherNumberString(env: napi.Env, value: NumberOrString) !napi.NapiValue {
    switch (value) {
        .number => |number| {
            return napi.NapiValue.from_raw(env.raw, napi.Number.New(env, number + 100).raw);
        },
        .string => |string| {
            const prefix = "Either::B(";
            const suffix = ")";
            const allocator = napi.globalAllocator();
            const out = try allocator.alloc(u8, prefix.len + string.len + suffix.len);
            defer allocator.free(out);

            @memcpy(out[0..prefix.len], prefix);
            @memcpy(out[prefix.len .. prefix.len + string.len], string);
            @memcpy(out[prefix.len + string.len ..], suffix);

            return napi.NapiValue.from_raw(env.raw, napi.String.New(env, out).raw);
        },
    }
}

pub fn dynamicArgumentLength(value: i32) i32 {
    return value + 100;
}
