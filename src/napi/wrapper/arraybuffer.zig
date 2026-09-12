const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const NapiError = @import("error.zig");
const GlobalAllocator = @import("../util/allocator.zig");
const options = @import("../options.zig");

/// Returns whether the ArrayBuffer behind `raw` has been detached.
///
/// `napi_is_detached_arraybuffer` exists since N-API v7. Lower versions cannot
/// distinguish a detached buffer from an empty one and always report `false`;
/// callers fall back to comparing refreshed lengths.
pub fn backingIsDetached(env: napi.napi_env, raw: napi.napi_value) !bool {
    if (comptime options.selectedNapiVersion().isAtLeast(.v7)) {
        var detached = false;
        const status = napi.napi_is_detached_arraybuffer(env, raw, &detached);
        if (status == napi.napi_ok) return detached;
        // Not an ArrayBuffer (a SharedArrayBuffer or a non binary object) is
        // not detached; the caller validates the value type separately.
        if (status == napi.napi_invalid_arg) return false;
        if (NapiError.Status.New(status) == .ArrayBufferExpected) return false;
        return NapiError.toError(NapiError.Status.New(status));
    } else {
        return false;
    }
}

/// Errors reported by the fallible binary accessors.
pub const BinaryError = error{
    /// The wrapper was produced from a JavaScript value of another type.
    InvalidBinaryValue,
    /// The backing store has been detached or resized after the view was
    /// created; the cached pointer must not be dereferenced.
    InvalidatedBackingStore,
};

pub const ArrayBuffer = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    data: [*]u8,
    len: usize,

    /// Whether this wrapper refers to a usable ArrayBuffer.
    pub fn isValid(self: ArrayBuffer) bool {
        return self.raw != null;
    }

    /// Create an ArrayBuffer from a raw napi_value.
    ///
    /// Kept for source compatibility with the previous infallible API: the
    /// N-API status is checked, a value that is not an ArrayBuffer yields an
    /// invalid wrapper (`isValid() == false`, empty slice) and the failure is
    /// published through the conversion error channel. Prefer `tryFromRaw` when
    /// the failure has to be handled in Zig.
    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) ArrayBuffer {
        return ArrayBuffer.tryFromRaw(env, raw) catch |err| {
            recordBinaryFailure("ArrayBuffer expected", err);
            return invalid(env, null);
        };
    }

    /// Create an ArrayBuffer from a raw napi_value, reporting the N-API status.
    pub fn tryFromRaw(env: napi.napi_env, raw: napi.napi_value) !ArrayBuffer {
        var data: ?*anyopaque = null;
        var len: usize = 0;
        const status = napi.napi_get_arraybuffer_info(env, raw, &data, &len);
        if (status != napi.napi_ok) {
            if (NapiError.Status.New(status) == .InvalidArg) {
                return BinaryError.InvalidBinaryValue;
            }
            return NapiError.toError(NapiError.Status.New(status));
        }
        if (len == 0 or data == null) {
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

    pub fn invalid(env: napi.napi_env, raw: napi.napi_value) ArrayBuffer {
        return ArrayBuffer{
            .env = env,
            .raw = raw,
            .data = &[_]u8{},
            .len = 0,
        };
    }

    /// Convert from napi_value to the specified type ([]u8 or [N]u8).
    ///
    /// Fails when the value is not an ArrayBuffer. A value that cannot be read
    /// is never reported as zero filled data: silently returning zeros made an
    /// invalid input look like a successful conversion.
    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        const infos = @typeInfo(T);

        const buffer = try ArrayBuffer.tryFromRaw(env, raw);
        const source = buffer.data[0..buffer.len];

        switch (infos) {
            // Handle fixed-size array: [N]u8
            .array => |arr| {
                if (arr.child != u8) {
                    @compileError("ArrayBuffer only supports u8 arrays, got: " ++ @typeName(arr.child));
                }

                var result: T = undefined;
                const copy_len = @min(source.len, arr.len);
                @memcpy(result[0..copy_len], source[0..copy_len]);

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

                const allocator = GlobalAllocator.globalAllocator();
                const buf = allocator.alloc(u8, source.len) catch @panic("OOM");
                @memcpy(buf, source);

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
        return try ArrayBuffer.fromWithFinalizer(env, data, null);
    }

    pub fn fromWithFinalizer(env: Env, data: []u8, on_finalize: ?*const fn () void) !ArrayBuffer {
        var result: napi.napi_value = undefined;
        var result_data: ?*anyopaque = null;

        // Store the slice info for the finalizer
        const hint = ArrayBufferHint.create(data, on_finalize) catch {
            return NapiError.Error.fromStatus(NapiError.Status.GenericFailure);
        };

        if (data.len == 0) {
            const create_status = createArrayBuffer(env.raw, 0);
            result = create_status.result;
            result_data = create_status.data;
            hint.destroy();
            if (create_status.raw != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(create_status.raw));
            }
            return ArrayBuffer{
                .env = env.raw,
                .raw = result,
                .data = if (result_data == null) &[_]u8{} else @ptrCast(result_data),
                .len = 0,
            };
        }

        var status = napi.napi_create_external_arraybuffer(
            env.raw,
            @ptrCast(data.ptr),
            data.len,
            externalArrayBufferFinalizer,
            hint,
            &result,
        );

        var hint_destroyed = false;
        if (isNoExternalBuffersAllowed(status)) {
            const create_status = createArrayBuffer(env.raw, data.len);
            result = create_status.result;
            result_data = create_status.data;
            status = create_status.raw;
            if (status == napi.napi_ok) {
                if (result_data == null) {
                    hint.destroy();
                    return NapiError.Error.fromStatus(NapiError.Status.GenericFailure);
                }
                const dest: [*]u8 = @ptrCast(result_data);
                @memcpy(dest[0..data.len], data);
            }
            hint.destroy();
            hint_destroyed = true;
        }

        if (status != napi.napi_ok) {
            // Clean up hint if buffer creation failed
            if (!hint_destroyed) {
                hint.destroy();
            }
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        return ArrayBuffer{
            .env = env.raw,
            .raw = result,
            .data = if (result_data == null) data.ptr else @ptrCast(result_data),
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
        const create_status = createArrayBuffer(env.raw, data.len);
        const status = create_status.raw;

        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        // Copy the data into the newly created ArrayBuffer
        if (data.len > 0) {
            if (create_status.data == null) {
                return NapiError.Error.fromStatus(NapiError.Status.GenericFailure);
            }
            const dest: [*]u8 = @ptrCast(create_status.data);
            @memcpy(dest[0..data.len], data);
        }

        const result_buffer = ArrayBuffer{
            .env = env.raw,
            .raw = create_status.result,
            .data = if (data.len == 0 or create_status.data == null) &[_]u8{} else @ptrCast(create_status.data),
            .len = data.len,
        };
        try result_buffer.flush();
        return result_buffer;
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
        const create_status = createArrayBuffer(env.raw, len);
        const status = create_status.raw;

        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        return ArrayBuffer{
            .env = env.raw,
            .raw = create_status.result,
            .data = if (len == 0 or create_status.data == null) &[_]u8{} else @ptrCast(create_status.data),
            .len = len,
        };
    }

    /// Re-query the backing store and refresh the cached pointer and length.
    ///
    /// JavaScript code that ran after this wrapper was created (a callback, a
    /// getter, a Proxy trap) may have detached or transferred the buffer. The
    /// cached pointer is only valid until the next JavaScript reentry.
    pub fn refresh(self: *ArrayBuffer) !void {
        const refreshed = try ArrayBuffer.tryFromRaw(self.env, self.raw);
        self.data = refreshed.data;
        self.len = refreshed.len;
    }

    /// Get the ArrayBuffer data as a mutable slice, refreshing the backing
    /// store first.
    ///
    /// Returns an error when the backing store was detached or is no longer
    /// readable. The returned slice is only valid until the next JavaScript
    /// reentry.
    pub fn tryAsSlice(self: ArrayBuffer) ![]u8 {
        if (self.raw == null) return BinaryError.InvalidBinaryValue;
        if (try backingIsDetached(self.env, self.raw)) return BinaryError.InvalidatedBackingStore;
        const refreshed = try ArrayBuffer.tryFromRaw(self.env, self.raw);
        return refreshed.data[0..refreshed.len];
    }

    /// Safe variant of `asSlice`.
    pub fn tryAsConstSlice(self: ArrayBuffer) ![]const u8 {
        return try self.tryAsSlice();
    }

    /// Get the ArrayBuffer data as a mutable slice.
    ///
    /// The backing store is re-validated on every call; a detached backing
    /// store yields an empty slice instead of a dangling pointer. Use
    /// `tryAsSlice` to observe the failure.
    pub fn asSlice(self: ArrayBuffer) []u8 {
        return self.tryAsSlice() catch &[_]u8{};
    }

    /// Get the ArrayBuffer data as a const slice. See `asSlice`.
    pub fn asConstSlice(self: ArrayBuffer) []const u8 {
        return self.tryAsSlice() catch &[_]u8{};
    }

    /// Get the length of the ArrayBuffer
    pub fn length(self: ArrayBuffer) usize {
        return self.len;
    }

    /// Sync wasm-side mutations back to the JavaScript ArrayBuffer when running on emnapi.
    pub fn flush(self: ArrayBuffer) !void {
        if (comptime !options.isWasmNodeAddon()) return;
        if (self.len == 0) return;
        var raw = self.raw;
        const status = napi.emnapi_sync_memory(self.env, false, &raw, 0, self.len);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
    }

    /// Detach the ArrayBuffer.
    pub fn detach(self: *ArrayBuffer) !void {
        comptime options.requireNapiVersion(.v7);

        const status = napi.napi_detach_arraybuffer(self.env, self.raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        self.data = &[_]u8{};
        self.len = 0;
    }

    /// Check whether the ArrayBuffer has been detached.
    pub fn isDetached(self: ArrayBuffer) !bool {
        comptime options.requireNapiVersion(.v7);

        return backingIsDetached(self.env, self.raw);
    }
};

/// Reports a failure of the infallible `from_raw` entry points.
///
/// Invalid input maps to a `TypeError`, an invalidated backing store to a
/// `RangeError`. The failure is published through the conversion error channel
/// (`last_error`) rather than thrown here: the export pipeline checks that
/// channel right after converting an argument and refuses the call before the
/// native function runs, so throwing here would raise a second exception while
/// one is already pending.
///
/// The fallible `tryFromRaw` / `tryAsSlice` API is the primary contract and is
/// what the ownership rework of the conversion layer consumes.
pub fn recordBinaryFailure(comptime expected: []const u8, err: anyerror) void {
    const reported = switch (err) {
        BinaryError.InvalidBinaryValue => NapiError.Error.withTypeError(expected),
        BinaryError.InvalidatedBackingStore => NapiError.Error.withRangeError("binary view backing store was detached or resized"),
        // A pending JavaScript exception is the error to report; creating a
        // second one would abort N-API.
        error.PendingException => NapiError.Error.withStatus(NapiError.Status.PendingException),
        else => NapiError.Error.withStatus(NapiError.Status.GenericFailure),
    };

    NapiError.last_error = reported;
    NapiError.last_error_status = switch (err) {
        error.PendingException => .PendingException,
        else => .GenericFailure,
    };
}

const ArrayBufferCreateStatus = struct {
    raw: napi.napi_status,
    result: napi.napi_value,
    data: ?*anyopaque,
};

fn createArrayBuffer(env: napi.napi_env, len: usize) ArrayBufferCreateStatus {
    var result: napi.napi_value = undefined;
    var data: ?*anyopaque = null;
    const status = napi.napi_create_arraybuffer(env, len, &data, &result);
    return .{
        .raw = status,
        .result = result,
        .data = data,
    };
}

fn isNoExternalBuffersAllowed(status: napi.napi_status) bool {
    return NapiError.Status.New(status) == .NoExternalBuffersAllowed;
}

/// Helper struct to store ArrayBuffer info for the finalizer
const ArrayBufferHint = struct {
    allocator: std.mem.Allocator,
    ptr: [*]u8,
    len: usize,
    on_finalize: ?*const fn () void,

    fn create(data: []u8, on_finalize: ?*const fn () void) !*ArrayBufferHint {
        const allocator = GlobalAllocator.globalAllocator();
        const hint = try allocator.create(ArrayBufferHint);
        hint.* = .{
            .allocator = allocator,
            .ptr = data.ptr,
            .len = data.len,
            .on_finalize = on_finalize,
        };
        return hint;
    }

    fn destroy(self: *ArrayBufferHint) void {
        const allocator = self.allocator;
        // Free the original buffer data
        allocator.free(self.ptr[0..self.len]);
        if (self.on_finalize) |on_finalize| {
            on_finalize();
        }
        // Free the hint struct itself
        allocator.destroy(self);
    }
};

/// Callback invoked when the external ArrayBuffer is garbage collected
fn externalArrayBufferFinalizer(
    _: napi.napi_env,
    _: ?*anyopaque,
    hint: ?*anyopaque,
) callconv(.c) void {
    if (hint) |h| {
        const arraybuffer_hint: *ArrayBufferHint = @ptrCast(@alignCast(h));
        arraybuffer_hint.destroy();
    }
}
