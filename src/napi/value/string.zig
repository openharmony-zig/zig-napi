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
        return self.length(u8, napi.napi_get_value_string_utf8);
    }

    pub fn utf16Len(self: String) !usize {
        return self.length(u16, napi.napi_get_value_string_utf16);
    }

    pub fn latin1Len(self: String) !usize {
        return self.length(u8, napi.napi_get_value_string_latin1);
    }

    fn length(
        self: String,
        comptime Unit: type,
        comptime get_value: *const fn (napi.napi_env, napi.napi_value, [*c]Unit, usize, ?*usize) callconv(.c) napi.napi_status,
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

    pub fn copyLatin1(self: String) ![]u8 {
        return copyNullTerminated(u8, napi.napi_get_value_string_latin1, self.env, self.raw, try self.latin1Len(), GlobalAllocator.capture());
    }

    pub fn createLatin1(env: Env, value: []const u8) !String {
        if (comptime @import("../options.zig").isWasmNodeAddon()) {
            // emnapi alpha.5's Latin1 encoder stops at NUL even with an
            // explicit length. Its UTF16 path preserves every code unit.
            const allocator = GlobalAllocator.capture();
            const wide = try allocator.alloc(u16, value.len);
            defer allocator.free(wide);
            for (value, wide) |byte, *unit| unit.* = byte;
            return createUtf16(env, wide);
        }
        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_string_latin1(env.raw, value.ptr, value.len, &raw);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
        return from_raw(env.raw, raw);
    }

    fn copyNullTerminated(
        comptime T: type,
        comptime get_value: *const fn (napi.napi_env, napi.napi_value, [*c]T, usize, ?*usize) callconv(.c) napi.napi_status,
        env: napi.napi_env,
        raw: napi.napi_value,
        len: usize,
        allocator: std.mem.Allocator,
    ) ![]T {
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
        return from_napi_value_with_allocator(env, raw, T, GlobalAllocator.globalAllocator());
    }

    /// Convert with an explicit allocator so the allocation and the matching
    /// cleanup cannot diverge when this thread's operation allocator changes
    /// while the conversion is running.
    pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, comptime T: type, allocator: std.mem.Allocator) !T {
        const stringMode = comptime helper.stringLike(T);
        const infos = @typeInfo(T);

        switch (stringMode) {
            .Utf8 => {
                var len: usize = 0;
                const status = napi.napi_get_value_string_utf8(env, raw, null, 0, &len);
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }

                return copyInto(T, u8, napi.napi_get_value_string_utf8, env, raw, len, infos, allocator);
            },
            .Utf16 => {
                var len: usize = 0;
                const status = napi.napi_get_value_string_utf16(env, raw, null, 0, &len);
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }

                return copyInto(T, u16, napi.napi_get_value_string_utf16, env, raw, len, infos, allocator);
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
        allocator: std.mem.Allocator,
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
            const slice = try copyNullTerminated(Unit, get_value, env, raw, len, allocator);
            defer allocator.free(slice);
            for (slice, 0..) |unit, i| {
                result[i] = unit;
            }
            return result;
        }

        const buf = try copyNullTerminated(Unit, get_value, env, raw, len, allocator);
        return @as(T, buf);
    }

    pub const ExternalResult = struct { value: String, copied: bool };

    /// Duplicate input with the captured allocator and transfer that allocation
    /// to the host. A copying host invokes the same finalizer immediately.
    pub fn createExternalLatin1(env: Env, value: []const u8) !ExternalResult {
        if (comptime !@import("../options.zig").isWasmNodeAddon() and @import("../options.zig").selectedNapiVersion().isAtLeast(.v10) and @hasDecl(napi, "node_api_create_external_string_latin1")) return createExternal(u8, env, value, napi.node_api_create_external_string_latin1);
        return .{ .value = try createLatin1(env, value), .copied = true };
    }
    pub fn createExternalUtf16(env: Env, value: []const u16) !ExternalResult {
        if (comptime @import("../options.zig").selectedNapiVersion().isAtLeast(.v10) and @hasDecl(napi, "node_api_create_external_string_utf16")) return createExternal(u16, env, value, napi.node_api_create_external_string_utf16);
        return .{ .value = try createUtf16(env, value), .copied = true };
    }
    fn createExternal(comptime Unit: type, env: Env, value: []const Unit, comptime create: anytype) !ExternalResult {
        const State = struct {
            allocator: std.mem.Allocator,
            bytes: []Unit,
            fn finalize(_: napi.node_api_basic_env, _: ?*anyopaque, hint: ?*anyopaque) callconv(.c) void {
                const state: *@This() = @ptrCast(@alignCast(hint.?));
                const allocator = state.allocator;
                allocator.free(state.bytes);
                allocator.destroy(state);
            }
        };
        const allocator = GlobalAllocator.capture();
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .bytes = try allocator.dupe(Unit, value) };
        errdefer allocator.free(state.bytes);
        var raw: napi.napi_value = null;
        var copied = false;
        const status = create(env.raw, state.bytes.ptr, state.bytes.len, State.finalize, state, &raw, &copied);
        if (status != napi.napi_ok) return NapiError.failStatus(status);
        return .{ .value = from_raw(env.raw, raw), .copied = copied };
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
