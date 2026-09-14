const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const arraybuffer_mod = @import("./arraybuffer.zig");
const ArrayBuffer = arraybuffer_mod.ArrayBuffer;
const NapiError = @import("./error.zig");
const options = @import("../options.zig");

pub fn isSupportedElementType(comptime T: type) bool {
    return switch (T) {
        i8, u8, i16, u16, i32, u32, f32, f64 => true,
        i64, u64 => options.selectedNapiVersion().isAtLeast(.v6),
        else => false,
    };
}

pub fn defaultTypeFor(comptime T: type) napi.napi_typedarray_type {
    return switch (T) {
        i8 => napi.napi_int8_array,
        u8 => napi.napi_uint8_array,
        i16 => napi.napi_int16_array,
        u16 => napi.napi_uint16_array,
        i32 => napi.napi_int32_array,
        u32 => napi.napi_uint32_array,
        f32 => napi.napi_float32_array,
        f64 => napi.napi_float64_array,
        i64 => blk: {
            comptime options.requireNapiVersion(.v6);
            break :blk napi.napi_bigint64_array;
        },
        u64 => blk: {
            comptime options.requireNapiVersion(.v6);
            break :blk napi.napi_biguint64_array;
        },
        else => @compileError("Unsupported TypedArray element type: " ++ @typeName(T)),
    };
}

pub fn elementByteSize(raw_type: napi.napi_typedarray_type) usize {
    return switch (raw_type) {
        napi.napi_int8_array, napi.napi_uint8_array, napi.napi_uint8_clamped_array => 1,
        napi.napi_int16_array, napi.napi_uint16_array => 2,
        napi.napi_int32_array, napi.napi_uint32_array, napi.napi_float32_array => 4,
        napi.napi_float64_array => 8,
        else => if (options.selectedNapiVersion().isAtLeast(.v6) and (raw_type == napi.napi_bigint64_array or raw_type == napi.napi_biguint64_array)) 8 else 0,
    };
}

pub fn normalizeElementLength(raw_len: usize, raw_type: napi.napi_typedarray_type, arraybuffer_byte_length: usize, byte_offset: usize) usize {
    return tryNormalizeElementLength(raw_len, raw_type, arraybuffer_byte_length, byte_offset) catch 0;
}

/// Fallible variant of `normalizeElementLength`; the multiplication and the
/// offset addition are checked so that a hostile length cannot wrap around and
/// turn into a valid looking view.
pub fn tryNormalizeElementLength(raw_len: usize, raw_type: napi.napi_typedarray_type, arraybuffer_byte_length: usize, byte_offset: usize) !usize {
    const element_size = elementByteSize(raw_type);
    if (element_size == 0) return error.InvalidTypedArrayType;
    if (byte_offset > arraybuffer_byte_length) return error.InvalidTypedArrayView;

    const remaining_byte_len = arraybuffer_byte_length - byte_offset;
    const byte_len = std.math.mul(usize, raw_len, element_size) catch return error.InvalidTypedArrayView;

    if (byte_len <= remaining_byte_len) {
        return raw_len;
    }

    // Some runtimes report the length in bytes instead of elements.
    if (raw_len <= remaining_byte_len and raw_len % element_size == 0) {
        return raw_len / element_size;
    }

    return error.InvalidTypedArrayView;
}

fn validateElementType(comptime T: type) void {
    if (!comptime isSupportedElementType(T)) {
        @compileError("Unsupported TypedArray element type: " ++ @typeName(T));
    }
}

pub fn TypedArray(comptime T: type) type {
    return TypedArrayWithRawType(T, defaultTypeFor(T));
}

fn validateRawTypeForElementType(comptime T: type, comptime raw_type: napi.napi_typedarray_type) void {
    if (raw_type == defaultTypeFor(T)) {
        return;
    }
    if (T == u8 and raw_type == napi.napi_uint8_clamped_array) {
        return;
    }
    @compileError("Unsupported TypedArray raw type for element type: " ++ @typeName(T));
}

fn TypedArrayWithRawType(comptime T: type, comptime raw_type: napi.napi_typedarray_type) type {
    validateElementType(T);
    validateRawTypeForElementType(T, raw_type);

    return struct {
        pub const is_napi_typedarray = true;
        pub const element_type = T;
        pub const raw_typedarray_type = raw_type;

        env: napi.napi_env,
        raw: napi.napi_value,
        data: [*]T,
        len: usize,
        typedarray_type: napi.napi_typedarray_type,
        byte_offset: usize,
        arraybuffer: ArrayBuffer,

        const Self = @This();

        fn invalid(env: napi.napi_env, raw: napi.napi_value) Self {
            return Self{
                .env = env,
                .raw = raw,
                .data = &[_]T{},
                .len = 0,
                .typedarray_type = raw_type,
                .byte_offset = 0,
                .arraybuffer = .{
                    .env = env,
                    .raw = raw,
                    .data = &[_]u8{},
                    .len = 0,
                },
            };
        }

        /// Whether this wrapper refers to a usable TypedArray.
        pub fn isValid(self: Self) bool {
            return self.raw != null;
        }

        /// Create a wrapper from a raw napi_value.
        ///
        /// Kept for source compatibility with the previous infallible API: the
        /// N-API status and the raw TypedArray type are validated, and a value
        /// that is not a matching TypedArray throws a JavaScript `TypeError`
        /// and yields an invalid wrapper. Prefer `tryFromRaw` when the failure
        /// has to be handled in Zig.
        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            return Self.tryFromRaw(env, raw) catch |err| {
                arraybuffer_mod.recordBinaryFailure("matching TypedArray expected", err);
                return invalid(env, null);
            };
        }

        /// Create a wrapper from a raw napi_value, validating the N-API status,
        /// the element type and the view length.
        pub fn tryFromRaw(env: napi.napi_env, raw: napi.napi_value) !Self {
            var typedarray_type: napi.napi_typedarray_type = undefined;
            var len: usize = 0;
            var data: ?*anyopaque = null;
            var arraybuffer_raw: napi.napi_value = undefined;
            var byte_offset: usize = 0;

            const status = napi.napi_get_typedarray_info(
                env,
                raw,
                &typedarray_type,
                &len,
                &data,
                &arraybuffer_raw,
                &byte_offset,
            );
            if (status != napi.napi_ok) {
                // A value that is not a TypedArray at all is a type error; any
                // other status is reported as it came in.
                if (NapiError.Status.New(status) == .InvalidArg) {
                    return arraybuffer_mod.BinaryError.InvalidBinaryValue;
                }
                return NapiError.toError(NapiError.Status.New(status));
            }
            if (typedarray_type != raw_type) {
                return arraybuffer_mod.BinaryError.InvalidBinaryValue;
            }

            const backing = ArrayBuffer.tryFromRaw(env, arraybuffer_raw) catch {
                return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
            };
            if (try arraybuffer_mod.backingIsDetached(env, arraybuffer_raw)) {
                return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
            }

            const element_len = tryNormalizeElementLength(len, typedarray_type, backing.length(), byte_offset) catch {
                return arraybuffer_mod.BinaryError.InvalidBinaryValue;
            };

            // A reported length without a backing pointer is the shape of a
            // detached view; it must never turn into a slice.
            if (element_len > 0 and data == null) {
                return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
            }

            return Self{
                .env = env,
                .raw = raw,
                .data = if (element_len == 0 or data == null) &[_]T{} else @ptrCast(@alignCast(data)),
                .len = element_len,
                .typedarray_type = typedarray_type,
                .byte_offset = byte_offset,
                .arraybuffer = backing,
            };
        }

        pub fn fromArrayBuffer(env: Env, arraybuffer: ArrayBuffer, len: usize, byte_offset: usize) !Self {
            const element_size = @sizeOf(T);
            if (byte_offset % element_size != 0) {
                return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
            }

            // Checked so that a huge `len` cannot wrap around and look like a
            // view inside the buffer.
            const byte_length = std.math.mul(usize, len, element_size) catch {
                return NapiError.Error.rangeError("TypedArray length overflows the byte range");
            };
            const end = std.math.add(usize, byte_offset, byte_length) catch {
                return NapiError.Error.rangeError("TypedArray offset overflows the byte range");
            };
            if (end > arraybuffer.length()) {
                return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
            }

            var raw: napi.napi_value = undefined;
            const status = napi.napi_create_typedarray(
                env.raw,
                raw_type,
                len,
                arraybuffer.raw,
                byte_offset,
                &raw,
            );

            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }

            // Re-read the view from the runtime instead of deriving the pointer
            // from the ArrayBuffer wrapper: the created view is the authority
            // for its own pointer, length and offset.
            return Self.tryFromRaw(env.raw, raw);
        }

        pub fn New(env: Env, len: usize) !Self {
            const byte_length = std.math.mul(usize, len, @sizeOf(T)) catch {
                return NapiError.Error.rangeError("TypedArray length overflows the byte range");
            };
            const arraybuffer = try ArrayBuffer.New(env, byte_length);
            return Self.fromArrayBuffer(env, arraybuffer, len, 0);
        }

        pub fn copy(env: Env, data: []const T) !Self {
            var result = try Self.New(env, data.len);
            @memcpy(try result.tryAsSlice(), data);
            try result.flush();
            return result;
        }

        pub fn from(env: Env, data: []T) !Self {
            const arraybuffer = try ArrayBuffer.from(env, std.mem.sliceAsBytes(data));
            return Self.fromArrayBuffer(env, arraybuffer, data.len, 0);
        }

        /// Re-query the view and refresh the cached pointer, length and offset.
        ///
        /// JavaScript code that ran after this wrapper was created (a callback,
        /// a getter, a Proxy trap) may have detached or transferred the backing
        /// ArrayBuffer. The cached pointer is only valid until the next
        /// JavaScript reentry.
        pub fn refresh(self: *Self) !void {
            const refreshed = try Self.tryFromRaw(self.env, self.raw);
            self.data = refreshed.data;
            self.len = refreshed.len;
            self.typedarray_type = refreshed.typedarray_type;
            self.byte_offset = refreshed.byte_offset;
            self.arraybuffer = refreshed.arraybuffer;
        }

        /// Borrowed native view of the TypedArray contents, re-validated
        /// against the backing store on every call.
        ///
        /// Fails when the wrapper is invalid, when the element type no longer
        /// matches, or when the backing store was detached, transferred or
        /// resized since the wrapper was created. The returned slice stays
        /// valid only until the next JavaScript reentry.
        pub fn tryAsSlice(self: Self) ![]T {
            if (self.raw == null) return arraybuffer_mod.BinaryError.InvalidBinaryValue;
            const refreshed = try Self.tryFromRaw(self.env, self.raw);
            if (refreshed.len != self.len) return arraybuffer_mod.BinaryError.InvalidatedBackingStore;
            return refreshed.data[0..refreshed.len];
        }

        /// Safe variant of `asConstSlice`.
        pub fn tryAsConstSlice(self: Self) ![]const T {
            return try self.tryAsSlice();
        }

        /// Borrowed native view of the TypedArray contents.
        ///
        /// The view is re-validated on every call; when the backing store is no
        /// longer valid the result is an empty slice rather than a dangling
        /// pointer. Use `tryAsSlice` to observe the failure.
        pub fn asSlice(self: Self) []T {
            return self.tryAsSlice() catch &[_]T{};
        }

        /// Const variant of `asSlice`. See `asSlice` for the empty-slice rule.
        pub fn asConstSlice(self: Self) []const T {
            return self.tryAsSlice() catch &[_]T{};
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        /// Byte length of the view with checked arithmetic.
        pub fn tryByteLength(self: Self) !usize {
            return std.math.mul(usize, self.len, @sizeOf(T)) catch arraybuffer_mod.BinaryError.InvalidBinaryValue;
        }

        pub fn byteLength(self: Self) usize {
            return self.tryByteLength() catch 0;
        }

        /// Sync wasm-side mutations back to the JavaScript TypedArray when running on emnapi.
        pub fn flush(self: Self) !void {
            try self.flushRange(0, self.byteLength());
        }

        /// Sync wasm-side mutations for a byte range relative to this TypedArray view.
        pub fn flushRange(self: Self, byte_offset: usize, byte_length: usize) !void {
            if (comptime !options.isWasmNodeAddon()) return;
            const view_byte_length = try self.tryByteLength();
            if (byte_offset > view_byte_length or byte_length > view_byte_length - byte_offset) {
                return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
            }
            if (byte_length == 0) return;
            var raw = self.raw;
            const status = napi.emnapi_sync_memory(self.env, false, &raw, byte_offset, byte_length);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }
    };
}

pub const Int8Array = TypedArray(i8);
pub const Uint8Array = TypedArray(u8);
pub const Uint8ClampedArray = TypedArrayWithRawType(u8, napi.napi_uint8_clamped_array);
pub const Int16Array = TypedArray(i16);
pub const Uint16Array = TypedArray(u16);
pub const Int32Array = TypedArray(i32);
pub const Uint32Array = TypedArray(u32);
pub const Float32Array = TypedArray(f32);
pub const Float64Array = TypedArray(f64);
pub const BigInt64Array = if (options.selectedNapiVersion().isAtLeast(.v6)) TypedArray(i64) else UnavailableTypedArray(i64, .v6);
pub const BigUint64Array = if (options.selectedNapiVersion().isAtLeast(.v6)) TypedArray(u64) else UnavailableTypedArray(u64, .v6);

fn UnavailableTypedArray(comptime T: type, comptime required: options.NapiVersion) type {
    return struct {
        pub const is_napi_typedarray = true;
        pub const element_type = T;

        fn unavailable() void {
            options.requireNapiVersion(required);
        }

        pub fn from_raw(_: napi.napi_env, _: napi.napi_value) @This() {
            comptime unavailable();
        }
    };
}
