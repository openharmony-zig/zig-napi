const std = @import("std");
const napi = @import("../../sys/api.zig");
const Value = @import("../value.zig").Value;
const Env = @import("../env.zig").Env;

pub const String = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) String {
        return String{ .env = env, .raw = raw, .type = napi.napi_string };
    }

    pub fn New(env: Env, value: []const u8) String {
        var raw: napi.napi_value = undefined;
        _ = napi.napi_create_string_utf8(env.raw, value.ptr, value.len, &raw);
        return String.from_raw(env.raw, raw);
    }

    pub fn ToValue(self: String) Value {
        return Value{ .String = self };
    }

    pub fn UTF8Value(self: String) []u8 {
        var len: usize = 0;
        _ = napi.napi_get_value_string_utf8(self.env, self.raw, null, 0, &len);

        const allocator = std.heap.page_allocator;
        const buf = allocator.alloc(u8, len + 1) catch @panic("OOM");

        _ = napi.napi_get_value_string_utf8(self.env, self.raw, buf.ptr, len + 1, null);
        return buf;
    }
};
