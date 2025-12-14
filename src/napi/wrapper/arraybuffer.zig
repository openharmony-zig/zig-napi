const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const NapiError = @import("error.zig");
const GlobalAllocator = @import("../util/allocator.zig");

pub const ArrayBuffer = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    data: [*]u8,
    len: usize,

    /// Create an ArrayBuffer from a raw napi_value
    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) ArrayBuffer {
        var data: ?*anyopaque = null;
        var len: usize = 0;
        _ = napi.napi_get_arraybuffer_info(env, raw, &data, &len);
        if (len == 0) {
            return ArrayBuffer{
                .env = env,
                .raw = raw,
                .data = &[_]u8{},
                .len = 0,
            };
        }
        return ArrayBuffer{
            .env = env,
            .raw = raw,
            .data = @ptrCast(data),
            .len = len,
        };
    }

    /// Convert from napi_value to the specified type ([]u8 or [N]u8)
    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const infos = @typeInfo(T);

        switch (infos) {
            // Handle fixed-size array: [N]u8
            .array => |arr| {
                if (arr.child != u8) {
                    @compileError("ArrayBuffer only supports u8 arrays, got: " ++ @typeName(arr.child));
                }

                var data: ?*anyopaque = null;
                var len: usize = 0;
                _ = napi.napi_get_arraybuffer_info(env, raw, &data, &len);

                var result: T = undefined;
                const copy_len = @min(len, arr.len);
                const src: [*]const u8 = @ptrCast(data);
                @memcpy(result[0..copy_len], src[0..copy_len]);

                // Zero-fill remaining bytes if buffer is smaller than array
                if (copy_len < arr.len) {
                    @memset(result[copy_len..], 0);
                }

                return result;
            },
            // Handle slice: []u8 or []const u8
            .pointer => |ptr| {
                if (ptr.size != .slice) {
                    @compileError("ArrayBuffer only supports slices, got pointer type: " ++ @typeName(T));
                }
                if (ptr.child != u8) {
                    @compileError("ArrayBuffer only supports u8 slices, got: " ++ @typeName(ptr.child));
                }

                var data: ?*anyopaque = null;
                var len: usize = 0;
                _ = napi.napi_get_arraybuffer_info(env, raw, &data, &len);

                const allocator = GlobalAllocator.globalAllocator();
                const buf = allocator.alloc(u8, len) catch @panic("OOM");
                const src: [*]const u8 = @ptrCast(data);
                @memcpy(buf, src[0..len]);

                return buf;
            },
            else => {
                @compileError("ArrayBuffer.from_napi_value only supports []u8 or [N]u8, got: " ++ @typeName(T));
            },
        }
    }

    /// Create a new ArrayBuffer from data using external buffer (zero-copy, transfers ownership)
    /// Similar to napi-rs `ArrayBuffer::from(Vec<u8>)` which uses napi_create_external_arraybuffer
    ///
    /// The data ownership is transferred to JavaScript. When the JS ArrayBuffer is garbage collected,
    /// the finalize callback will free the memory using the global allocator.
    ///
    /// Example:
    /// ```zig
    /// const allocator = GlobalAllocator.globalAllocator();
    /// const owned_data = try allocator.alloc(u8, 1024);
    /// // ... fill data ...
    /// const buf = try ArrayBuffer.from(env, owned_data);  // ownership transferred
    /// // Don't free owned_data, it's now managed by JS
    /// ```
    pub fn from(env: Env, data: []u8) !ArrayBuffer {
        var result: napi.napi_value = undefined;

        // Store the slice info for the finalizer
        const hint = ArrayBufferHint.create(data) catch {
            return NapiError.Error.fromStatus(NapiError.Status.GenericFailure);
        };

        const status = napi.napi_create_external_arraybuffer(
            env.raw,
            @ptrCast(data.ptr),
            data.len,
            externalArrayBufferFinalizer,
            hint,
            &result,
        );

        if (status != napi.napi_ok) {
            // Clean up hint if buffer creation failed
            hint.destroy();
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        return ArrayBuffer{
            .env = env.raw,
            .raw = result,
            .data = data.ptr,
            .len = data.len,
        };
    }

    /// Create a new ArrayBuffer by copying data (no ownership transfer)
    /// Similar to napi-rs `ArrayBuffer::copy_from`
    ///
    /// Use this when you want to keep ownership of the original data,
    /// or when the data is on the stack/temporary.
    ///
    /// Example:
    /// ```zig
    /// const stack_data = [_]u8{ 1, 2, 3, 4 };
    /// const buf = try ArrayBuffer.copy(env, &stack_data);
    /// ```
    pub fn copy(env: Env, data: []const u8) !ArrayBuffer {
        var result: napi.napi_value = undefined;
        var result_data: ?*anyopaque = null;

        const status = napi.napi_create_arraybuffer(
            env.raw,
            data.len,
            &result_data,
            &result,
        );

        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        // Copy the data into the newly created ArrayBuffer
        const dest: [*]u8 = @ptrCast(result_data);
        @memcpy(dest[0..data.len], data);

        return ArrayBuffer{
            .env = env.raw,
            .raw = result,
            .data = dest,
            .len = data.len,
        };
    }

    /// Create a new uninitialized ArrayBuffer with the specified length
    /// Similar to napi-rs `env.create_arraybuffer(length)`
    ///
    /// Example:
    /// ```zig
    /// var buf = try ArrayBuffer.New(env, 1024);
    /// @memset(buf.asSlice(), 0);  // initialize
    /// ```
    pub fn New(env: Env, len: usize) !ArrayBuffer {
        var result: napi.napi_value = undefined;
        var data: ?*anyopaque = null;

        const status = napi.napi_create_arraybuffer(env.raw, len, &data, &result);

        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        return ArrayBuffer{
            .env = env.raw,
            .raw = result,
            .data = @ptrCast(data),
            .len = len,
        };
    }

    /// Get the ArrayBuffer data as a mutable slice
    pub fn asSlice(self: ArrayBuffer) []u8 {
        return self.data[0..self.len];
    }

    /// Get the ArrayBuffer data as a const slice
    pub fn asConstSlice(self: ArrayBuffer) []const u8 {
        return self.data[0..self.len];
    }

    /// Get the length of the ArrayBuffer
    pub fn length(self: ArrayBuffer) usize {
        return self.len;
    }
};

/// Helper struct to store ArrayBuffer info for the finalizer
const ArrayBufferHint = struct {
    ptr: [*]u8,
    len: usize,

    fn create(data: []u8) !*ArrayBufferHint {
        const allocator = GlobalAllocator.globalAllocator();
        const hint = try allocator.create(ArrayBufferHint);
        hint.* = .{
            .ptr = data.ptr,
            .len = data.len,
        };
        return hint;
    }

    fn destroy(self: *ArrayBufferHint) void {
        const allocator = GlobalAllocator.globalAllocator();
        // Free the original buffer data
        allocator.free(self.ptr[0..self.len]);
        // Free the hint struct itself
        allocator.destroy(self);
    }
};

/// Callback invoked when the external ArrayBuffer is garbage collected
fn externalArrayBufferFinalizer(
    _: napi.napi_env,
    _: ?*anyopaque,
    hint: ?*anyopaque,
) callconv(.C) void {
    if (hint) |h| {
        const arraybuffer_hint: *ArrayBufferHint = @ptrCast(@alignCast(h));
        arraybuffer_hint.destroy();
    }
}
