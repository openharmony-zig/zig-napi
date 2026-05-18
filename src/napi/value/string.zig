const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Value = @import("../value.zig").Value;
const Env = @import("../env.zig").Env;
const helper = @import("../util/helper.zig");
const GlobalAllocator = @import("../util/allocator.zig");

pub const String = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) String {
        return String{ .env = env, .raw = raw, .type = napi.napi_string };
    }

    pub fn utf8Len(self: String) usize {
        var len: usize = 0;
        _ = napi.napi_get_value_string_utf8(self.env, self.raw, null, 0, &len);
        return len;
    }

    pub fn utf16Len(self: String) usize {
        var len: usize = 0;
        _ = napi.napi_get_value_string_utf16(self.env, self.raw, null, 0, &len);
        return len;
    }

    pub fn copyUtf8(self: String) []u8 {
        return String.from_napi_value(self.env, self.raw, []u8);
    }

    pub fn copyUtf16(self: String) []u16 {
        return String.from_napi_value(self.env, self.raw, []u16);
    }

    fn copyNullTerminated(
        comptime T: type,
        comptime get_value: *const fn (napi.napi_env, napi.napi_value, [*c]T, usize, ?*usize) callconv(.c) napi.napi_status,
        env: napi.napi_env,
        raw: napi.napi_value,
        len: usize,
    ) []T {
        const allocator = GlobalAllocator.globalAllocator();
        if (len == 0) {
            return allocator.alloc(T, 0) catch @panic("OOM");
        }

        const with_null = allocator.alloc(T, len + 1) catch @panic("OOM");
        _ = get_value(env, raw, with_null.ptr, len + 1, null);

        if (allocator.resize(with_null, len)) {
            return with_null[0..len];
        }

        const owned = allocator.alloc(T, len) catch @panic("OOM");
        @memcpy(owned, with_null[0..len]);
        allocator.free(with_null);
        return owned;
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const stringMode = comptime helper.stringLike(T);
        switch (stringMode) {
            .Utf8 => {
                var len: usize = 0;
                _ = napi.napi_get_value_string_utf8(env, raw, null, 0, &len);

                const buf = copyNullTerminated(u8, napi.napi_get_value_string_utf8, env, raw, len);
                return @as(T, buf);
            },
            .Utf16 => {
                var len: usize = 0;
                _ = napi.napi_get_value_string_utf16(env, raw, null, 0, &len);

                const buf = copyNullTerminated(u16, napi.napi_get_value_string_utf16, env, raw, len);
                return @as(T, buf);
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
