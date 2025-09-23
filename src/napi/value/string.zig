const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Value = @import("../value.zig").Value;
const Env = @import("../env.zig").Env;
const helper = @import("../util/helper.zig");

pub const String = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) String {
        return String{ .env = env, .raw = raw, .type = napi.napi_string };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const stringMode = comptime helper.stringLike(T);
        switch (stringMode) {
            .Utf8 => {
                var len: usize = 0;
                _ = napi.napi_get_value_string_utf8(env, raw, null, 0, &len);

                const allocator = std.heap.page_allocator;
                const buf = allocator.alloc(u8, len + 1) catch @panic("OOM");

                _ = napi.napi_get_value_string_utf8(env, raw, buf.ptr, len + 1, null);
                return @as(T, buf[0..len]);
            },
            .Utf16 => {
                var len: usize = 0;
                _ = napi.napi_get_value_string_utf16(env, raw, null, 0, &len);

                const allocator = std.heap.page_allocator;
                const buf = allocator.alloc(u16, len + 1) catch @panic("OOM");

                _ = napi.napi_get_value_string_utf16(env, raw, buf.ptr, len + 1, null);
                return @as(T, buf[0..len]);
            },
            else => {
                @compileError("Unsupported string type");
            },
        }
    }

    pub fn New(env: Env, value: []const u8) String {
        var raw: napi.napi_value = undefined;
        _ = napi.napi_create_string_utf8(env.raw, value.ptr, value.len, &raw);
        return String.from_raw(env.raw, raw);
    }
};
