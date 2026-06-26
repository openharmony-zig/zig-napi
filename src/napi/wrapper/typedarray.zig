const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const ArrayBuffer = @import("./arraybuffer.zig").ArrayBuffer;
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
    const remaining_byte_len = arraybuffer_byte_length -| byte_offset;
    const element_size = elementByteSize(raw_type);
    if (element_size == 0) return 0;

    if (raw_len * element_size <= remaining_byte_len) {
        return raw_len;
    }

    if (raw_len <= remaining_byte_len and raw_len % element_size == 0) {
        return raw_len / element_size;
    }

    return 0;
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

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
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
                NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(status));
                return invalid(env, raw);
            }
            if (typedarray_type != raw_type) {
                NapiError.last_error = NapiError.Error{
                    .JsTypeError = NapiError.JsTypeError.fromMessage("TypedArray raw type mismatch"),
                };
                return invalid(env, raw);
            }

            const arraybuffer = ArrayBuffer.from_raw(env, arraybuffer_raw);
            const element_len = normalizeElementLength(len, typedarray_type, arraybuffer.length(), byte_offset);

            return Self{
                .env = env,
                .raw = raw,
                .data = if (element_len == 0 or data == null) &[_]T{} else @ptrCast(@alignCast(data)),
                .len = element_len,
                .typedarray_type = typedarray_type,
                .byte_offset = byte_offset,
                .arraybuffer = arraybuffer,
            };
        }

        pub fn fromArrayBuffer(env: Env, arraybuffer: ArrayBuffer, len: usize, byte_offset: usize) !Self {
            if (byte_offset % @sizeOf(T) != 0) {
                return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
            }

            const byte_length = len * @sizeOf(T);
            if (byte_offset + byte_length > arraybuffer.length()) {
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

            return Self{
                .env = env.raw,
                .raw = raw,
                .data = if (len == 0) &[_]T{} else @ptrCast(@alignCast(arraybuffer.data + byte_offset)),
                .len = len,
                .typedarray_type = raw_type,
                .byte_offset = byte_offset,
                .arraybuffer = arraybuffer,
            };
        }

        pub fn New(env: Env, len: usize) !Self {
            const arraybuffer = try ArrayBuffer.New(env, len * @sizeOf(T));
            return Self.fromArrayBuffer(env, arraybuffer, len, 0);
        }

        pub fn copy(env: Env, data: []const T) !Self {
            var result = try Self.New(env, data.len);
            @memcpy(result.asSlice(), data);
            return result;
        }

        pub fn from(env: Env, data: []T) !Self {
            const arraybuffer = try ArrayBuffer.from(env, std.mem.sliceAsBytes(data));
            return Self.fromArrayBuffer(env, arraybuffer, data.len, 0);
        }

        pub fn asSlice(self: Self) []T {
            return self.data[0..self.len];
        }

        pub fn asConstSlice(self: Self) []const T {
            return self.data[0..self.len];
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        pub fn byteLength(self: Self) usize {
            return self.len * @sizeOf(T);
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
