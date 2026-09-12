const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Value = @import("../value.zig").Value;
const Env = @import("../env.zig").Env;
const helper = @import("../util/helper.zig");
const GlobalAllocator = @import("../util/allocator.zig");
const NapiError = @import("../wrapper/error.zig");

pub const String = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) String {
        return String{ .env = env, .raw = raw, .type = napi.napi_string };
    }

    pub fn utf8Len(self: String) !usize {
        return self.length(napi.napi_get_value_string_utf8);
    }

    pub fn utf16Len(self: String) !usize {
        return self.length(napi.napi_get_value_string_utf16);
    }

    fn length(
        self: String,
        comptime get_value: *const fn (napi.napi_env, napi.napi_value, [*c]u8, usize, ?*usize) callconv(.c) napi.napi_status,
    ) !usize {
        var len: usize = 0;
        const status = get_value(self.env, self.raw, null, 0, &len);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return len;
    }

    pub fn copyUtf8(self: String) ![]u8 {
        return String.from_napi_value(self.env, self.raw, []u8);
    }

    pub fn copyUtf16(self: String) ![]u16 {
        return String.from_napi_value(self.env, self.raw, []u16);
    }

    fn copyNullTerminated(
        comptime T: type,
        comptime get_value: *const fn (napi.napi_env, napi.napi_value, [*c]T, usize, ?*usize) callconv(.c) napi.napi_status,
        env: napi.napi_env,
        raw: napi.napi_value,
        len: usize,
    ) ![]T {
        const allocator = GlobalAllocator.globalAllocator();
        const with_null = try allocator.alloc(T, len + 1);
        errdefer allocator.free(with_null);

        var written: usize = 0;
        const status = get_value(env, raw, with_null.ptr, len + 1, &written);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        if (written != len) {
            return NapiError.failError(
                "String length changed during conversion: expected {d} code units, read {d}",
                .{ len, written },
            );
        }

        if (allocator.resize(with_null, written)) {
            return with_null[0..written];
        }

        const owned = try allocator.alloc(T, written);
        errdefer allocator.free(owned);
        @memcpy(owned, with_null[0..written]);
        allocator.free(with_null);
        return owned;
    }

    /// Convert a JavaScript string into a UTF-8/UTF-16 target.
    ///
    /// Slices copy the whole string; fixed arrays require an exact element count,
    /// which keeps `[N]u8`/`[N]u16` buffers from silently truncating input.
    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        const stringMode = comptime helper.stringLike(T);
        const infos = @typeInfo(T);

        switch (stringMode) {
            .Utf8 => {
                var len: usize = 0;
                const status = napi.napi_get_value_string_utf8(env, raw, null, 0, &len);
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }

                return copyInto(T, u8, napi.napi_get_value_string_utf8, env, raw, len, infos);
            },
            .Utf16 => {
                var len: usize = 0;
                const status = napi.napi_get_value_string_utf16(env, raw, null, 0, &len);
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }

                return copyInto(T, u16, napi.napi_get_value_string_utf16, env, raw, len, infos);
            },
            else => {
                @compileError("Unsupported string type");
            },
        }
    }

    fn copyInto(
        comptime T: type,
        comptime Unit: type,
        comptime get_value: *const fn (napi.napi_env, napi.napi_value, [*c]Unit, usize, ?*usize) callconv(.c) napi.napi_status,
        env: napi.napi_env,
        raw: napi.napi_value,
        len: usize,
        comptime infos: std.builtin.Type,
    ) !T {
        if (comptime infos == .array) {
            const expected = infos.array.len;
            if (len != expected) {
                return NapiError.failRangeError(
                    "Expected a string of {d} code units for {s}, got {d}",
                    .{ expected, helper.shortTypeName(T), len },
                );
            }
            var result: T = undefined;
            const slice = try copyNullTerminated(Unit, get_value, env, raw, len);
            defer GlobalAllocator.globalAllocator().free(slice);
            for (slice, 0..) |unit, i| {
                result[i] = unit;
            }
            return result;
        }

        const buf = try copyNullTerminated(Unit, get_value, env, raw, len);
        return @as(T, buf);
    }

    pub fn New(env: Env, value: []const u8) String {
        return createUtf8(env, value) catch @panic("napi: failed to create string value");
    }

    /// Failing UTF-8 constructor used by the conversion layer.
    pub fn createUtf8(env: Env, value: []const u8) !String {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_string_utf8(env.raw, value.ptr, value.len, &raw);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return String.from_raw(env.raw, raw);
    }

    /// Failing UTF-16 constructor. `napi_create_string_utf8` cannot represent
    /// UTF-16 input, so this is the only correct path for `[]const u16` values.
    pub fn createUtf16(env: Env, value: []const u16) !String {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_string_utf16(env.raw, value.ptr, value.len, &raw);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return String.from_raw(env.raw, raw);
    }
};
