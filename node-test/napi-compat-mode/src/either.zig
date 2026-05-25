const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

const NumberOrString = union(enum) {
    number: i32,
    string: []const u8,
};

pub fn eitherNumberString(env: napi.Env, value: NumberOrString) !c.napi_value {
    switch (value) {
        .number => |number| {
            var raw: c.napi_value = undefined;
            const status = c.napi_create_int32(env.raw, number + 100, &raw);
            if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
            return raw;
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

            var raw: c.napi_value = undefined;
            const status = c.napi_create_string_utf8(env.raw, out.ptr, out.len, &raw);
            if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
            return raw;
        },
    }
}

pub fn dynamicArgumentLength(value: i32) i32 {
    return value + 100;
}
