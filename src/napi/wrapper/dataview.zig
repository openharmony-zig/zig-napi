const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const ArrayBuffer = @import("./arraybuffer.zig").ArrayBuffer;
const NapiError = @import("./error.zig");
const Endian = std.builtin.Endian;

pub const DataView = struct {
    pub const is_napi_dataview = true;

    env: napi.napi_env,
    raw: napi.napi_value,
    data: [*]u8,
    byte_length: usize,
    byte_offset: usize,
    arraybuffer: ArrayBuffer,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) DataView {
        var byte_length: usize = 0;
        var data: ?*anyopaque = null;
        var arraybuffer_raw: napi.napi_value = undefined;
        var byte_offset: usize = 0;

        _ = napi.napi_get_dataview_info(
            env,
            raw,
            &byte_length,
            &data,
            &arraybuffer_raw,
            &byte_offset,
        );

        return DataView{
            .env = env,
            .raw = raw,
            .data = if (byte_length == 0 or data == null) &[_]u8{} else @ptrCast(data),
            .byte_length = byte_length,
            .byte_offset = byte_offset,
            .arraybuffer = ArrayBuffer.from_raw(env, arraybuffer_raw),
        };
    }

    pub fn fromArrayBuffer(env: Env, arraybuffer: ArrayBuffer, byte_offset: usize, byte_length: usize) !DataView {
        if (byte_offset + byte_length > arraybuffer.length()) {
            return NapiError.Error.fromStatus(NapiError.Status.InvalidArg);
        }

        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_dataview(
            env.raw,
            byte_length,
            arraybuffer.raw,
            byte_offset,
            &raw,
        );

        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        return DataView.from_raw(env.raw, raw);
    }

    pub fn New(env: Env, byte_length: usize) !DataView {
        const arraybuffer = try ArrayBuffer.New(env, byte_length);
        return DataView.fromArrayBuffer(env, arraybuffer, 0, byte_length);
    }

    pub fn copy(env: Env, data: []const u8) !DataView {
        const arraybuffer = try ArrayBuffer.copy(env, data);
        return DataView.fromArrayBuffer(env, arraybuffer, 0, data.len);
    }

    pub fn from(env: Env, data: []u8) !DataView {
        const arraybuffer = try ArrayBuffer.from(env, data);
        return DataView.fromArrayBuffer(env, arraybuffer, 0, data.len);
    }

    pub fn asSlice(self: DataView) []u8 {
        return self.data[0..self.byte_length];
    }

    pub fn asConstSlice(self: DataView) []const u8 {
        return self.data[0..self.byte_length];
    }

    pub fn byteLength(self: DataView) usize {
        return self.byte_length;
    }

    fn endianOf(little_endian: bool) Endian {
        return if (little_endian) .little else .big;
    }

    fn ensureRange(self: DataView, byte_offset: usize, len: usize) !void {
        if (byte_offset > self.byte_length or len > self.byte_length - byte_offset) {
            return NapiError.Error.rangeError("DataView offset is out of bounds");
        }
    }

    fn bytesAt(self: DataView, byte_offset: usize, len: usize) ![]u8 {
        try self.ensureRange(byte_offset, len);
        return self.asSlice()[byte_offset .. byte_offset + len];
    }

    pub fn readInt(self: DataView, comptime T: type, byte_offset: usize, little_endian: bool) !T {
        const info = @typeInfo(T);
        if (info != .int) {
            @compileError("readInt only supports integer types");
        }

        const bytes = try self.bytesAt(byte_offset, @sizeOf(T));
        const fixed: *const [@sizeOf(T)]u8 = @ptrCast(bytes.ptr);
        return std.mem.readInt(T, fixed, endianOf(little_endian));
    }

    pub fn writeInt(self: DataView, comptime T: type, byte_offset: usize, value: T, little_endian: bool) !void {
        const info = @typeInfo(T);
        if (info != .int) {
            @compileError("writeInt only supports integer types");
        }

        const bytes = try self.bytesAt(byte_offset, @sizeOf(T));
        const fixed: *[@sizeOf(T)]u8 = @ptrCast(bytes.ptr);
        std.mem.writeInt(T, fixed, value, endianOf(little_endian));
    }

    pub fn readFloat(self: DataView, comptime T: type, byte_offset: usize, little_endian: bool) !T {
        const info = @typeInfo(T);
        if (info != .float) {
            @compileError("readFloat only supports floating-point types");
        }

        const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
        const bits = try self.readInt(Bits, byte_offset, little_endian);
        return @bitCast(bits);
    }

    pub fn writeFloat(self: DataView, comptime T: type, byte_offset: usize, value: T, little_endian: bool) !void {
        const info = @typeInfo(T);
        if (info != .float) {
            @compileError("writeFloat only supports floating-point types");
        }

        const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
        try self.writeInt(Bits, byte_offset, @bitCast(value), little_endian);
    }

    pub fn getInt8(self: DataView, byte_offset: usize) !i8 {
        return self.readInt(i8, byte_offset, true);
    }

    pub fn getUint8(self: DataView, byte_offset: usize) !u8 {
        return self.readInt(u8, byte_offset, true);
    }

    pub fn getInt16(self: DataView, byte_offset: usize, little_endian: bool) !i16 {
        return self.readInt(i16, byte_offset, little_endian);
    }

    pub fn getUint16(self: DataView, byte_offset: usize, little_endian: bool) !u16 {
        return self.readInt(u16, byte_offset, little_endian);
    }

    pub fn getInt32(self: DataView, byte_offset: usize, little_endian: bool) !i32 {
        return self.readInt(i32, byte_offset, little_endian);
    }

    pub fn getUint32(self: DataView, byte_offset: usize, little_endian: bool) !u32 {
        return self.readInt(u32, byte_offset, little_endian);
    }

    pub fn getBigInt64(self: DataView, byte_offset: usize, little_endian: bool) !i64 {
        return self.readInt(i64, byte_offset, little_endian);
    }

    pub fn getBigUint64(self: DataView, byte_offset: usize, little_endian: bool) !u64 {
        return self.readInt(u64, byte_offset, little_endian);
    }

    pub fn getFloat32(self: DataView, byte_offset: usize, little_endian: bool) !f32 {
        return self.readFloat(f32, byte_offset, little_endian);
    }

    pub fn getFloat64(self: DataView, byte_offset: usize, little_endian: bool) !f64 {
        return self.readFloat(f64, byte_offset, little_endian);
    }

    pub fn setInt8(self: DataView, byte_offset: usize, value: i8) !void {
        try self.writeInt(i8, byte_offset, value, true);
    }

    pub fn setUint8(self: DataView, byte_offset: usize, value: u8) !void {
        try self.writeInt(u8, byte_offset, value, true);
    }

    pub fn setInt16(self: DataView, byte_offset: usize, value: i16, little_endian: bool) !void {
        try self.writeInt(i16, byte_offset, value, little_endian);
    }

    pub fn setUint16(self: DataView, byte_offset: usize, value: u16, little_endian: bool) !void {
        try self.writeInt(u16, byte_offset, value, little_endian);
    }

    pub fn setInt32(self: DataView, byte_offset: usize, value: i32, little_endian: bool) !void {
        try self.writeInt(i32, byte_offset, value, little_endian);
    }

    pub fn setUint32(self: DataView, byte_offset: usize, value: u32, little_endian: bool) !void {
        try self.writeInt(u32, byte_offset, value, little_endian);
    }

    pub fn setBigInt64(self: DataView, byte_offset: usize, value: i64, little_endian: bool) !void {
        try self.writeInt(i64, byte_offset, value, little_endian);
    }

    pub fn setBigUint64(self: DataView, byte_offset: usize, value: u64, little_endian: bool) !void {
        try self.writeInt(u64, byte_offset, value, little_endian);
    }

    pub fn setFloat32(self: DataView, byte_offset: usize, value: f32, little_endian: bool) !void {
        try self.writeFloat(f32, byte_offset, value, little_endian);
    }

    pub fn setFloat64(self: DataView, byte_offset: usize, value: f64, little_endian: bool) !void {
        try self.writeFloat(f64, byte_offset, value, little_endian);
    }
};
