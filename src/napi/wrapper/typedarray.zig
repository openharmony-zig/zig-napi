const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const ArrayBuffer = @import("./arraybuffer.zig").ArrayBuffer;
const NapiError = @import("./error.zig");

pub fn isSupportedElementType(comptime T: type) bool {
    return switch (T) {
        i8, u8, i16, u16, i32, u32, f32, f64, i64, u64 => true,
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
        i64 => napi.napi_bigint64_array,
        u64 => napi.napi_biguint64_array,
        else => @compileError("Unsupported TypedArray element type: " ++ @typeName(T)),
    };
}

fn validateElementType(comptime T: type) void {
    if (!comptime isSupportedElementType(T)) {
        @compileError("Unsupported TypedArray element type: " ++ @typeName(T));
    }
}

pub fn TypedArray(comptime T: type) type {
    validateElementType(T);

    return struct {
        pub const is_napi_typedarray = true;
        pub const element_type = T;

        env: napi.napi_env,
        raw: napi.napi_value,
        data: [*]T,
        len: usize,
        typedarray_type: napi.napi_typedarray_type,
        byte_offset: usize,
        arraybuffer: ArrayBuffer,

        const Self = @This();

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Self {
            var typedarray_type: napi.napi_typedarray_type = undefined;
            var len: usize = 0;
            var data: ?*anyopaque = null;
            var arraybuffer_raw: napi.napi_value = undefined;
            var byte_offset: usize = 0;

            _ = napi.napi_get_typedarray_info(
                env,
                raw,
                &typedarray_type,
                &len,
                &data,
                &arraybuffer_raw,
                &byte_offset,
            );

            return Self{
                .env = env,
                .raw = raw,
                .data = if (len == 0 or data == null) &[_]T{} else @ptrCast(@alignCast(data)),
                .len = len,
                .typedarray_type = typedarray_type,
                .byte_offset = byte_offset,
                .arraybuffer = ArrayBuffer.from_raw(env, arraybuffer_raw),
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
                defaultTypeFor(T),
                len,
                arraybuffer.raw,
                byte_offset,
                &raw,
            );

            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }

            return Self.from_raw(env.raw, raw);
        }

        pub fn from_arraybuffer(env: Env, arraybuffer: ArrayBuffer, len: usize, byte_offset: usize) !Self {
            return Self.fromArrayBuffer(env, arraybuffer, len, byte_offset);
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

        pub fn copy_from(env: Env, data: []const T) !Self {
            return Self.copy(env, data);
        }

        pub fn from(env: Env, data: []T) !Self {
            const arraybuffer = try ArrayBuffer.from(env, std.mem.sliceAsBytes(data));
            return Self.fromArrayBuffer(env, arraybuffer, data.len, 0);
        }

        pub fn from_data(env: Env, data: []T) !Self {
            return Self.from(env, data);
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
pub const Int16Array = TypedArray(i16);
pub const Uint16Array = TypedArray(u16);
pub const Int32Array = TypedArray(i32);
pub const Uint32Array = TypedArray(u32);
pub const Float32Array = TypedArray(f32);
pub const Float64Array = TypedArray(f64);
pub const BigInt64Array = TypedArray(i64);
pub const BigUint64Array = TypedArray(u64);
