const std = @import("std");
const napi = @import("napi");
const finalizer_state = @import("finalizer_state.zig");

var external_buffer_finalizers = std.atomic.Value(usize).init(0);
var external_arraybuffer_finalizers = std.atomic.Value(usize).init(0);
var external_typedarray_finalizers = std.atomic.Value(usize).init(0);
var external_dataview_finalizers = std.atomic.Value(usize).init(0);

fn onExternalBufferFinalized() void {
    _ = external_buffer_finalizers.fetchAdd(1, .monotonic);
    finalizer_state.onExternalFinalized();
}

fn onExternalArrayBufferFinalized() void {
    _ = external_arraybuffer_finalizers.fetchAdd(1, .monotonic);
    finalizer_state.onExternalFinalized();
}

fn onExternalTypedArrayFinalized() void {
    _ = external_typedarray_finalizers.fetchAdd(1, .monotonic);
    finalizer_state.onExternalFinalized();
}

fn onExternalDataViewFinalized() void {
    _ = external_dataview_finalizers.fetchAdd(1, .monotonic);
    finalizer_state.onExternalFinalized();
}

pub fn reset_external_finalizer_counts() void {
    external_buffer_finalizers.store(0, .monotonic);
    external_arraybuffer_finalizers.store(0, .monotonic);
    external_typedarray_finalizers.store(0, .monotonic);
    external_dataview_finalizers.store(0, .monotonic);
}

pub fn external_finalizer_count() usize {
    return external_buffer_finalizers.load(.monotonic) +
        external_arraybuffer_finalizers.load(.monotonic) +
        external_typedarray_finalizers.load(.monotonic) +
        external_dataview_finalizers.load(.monotonic);
}

pub fn create_buffer_copy(env: napi.Env, len: u32) !napi.Buffer {
    var bytes = [_]u8{0} ** 256;
    const actual_len = @min(@as(usize, len), bytes.len);
    for (bytes[0..actual_len], 0..) |*byte, i| {
        byte.* = @intCast(i % 251);
    }
    return try napi.Buffer.copy(env, bytes[0..actual_len]);
}

pub fn create_buffer_new(env: napi.Env, len: u32) !napi.Buffer {
    var buffer = try napi.Buffer.New(env, @intCast(len));
    @memset(buffer.asSlice(), 0x5a);
    return buffer;
}

pub fn create_external_buffer(env: napi.Env, len: u32) !napi.Buffer {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| {
        byte.* = @intCast(i % 251);
    }
    return try napi.Buffer.fromWithFinalizer(env, bytes, onExternalBufferFinalized);
}

pub fn buffer_length(value: napi.Buffer) usize {
    return value.length();
}

pub fn buffer_first_byte(value: napi.Buffer) u8 {
    return if (value.length() == 0) 0 else value.asConstSlice()[0];
}

pub fn create_arraybuffer_copy(env: napi.Env, len: u32) !napi.ArrayBuffer {
    var bytes = [_]u8{0} ** 256;
    const actual_len = @min(@as(usize, len), bytes.len);
    for (bytes[0..actual_len], 0..) |*byte, i| {
        byte.* = @intCast((i + 3) % 251);
    }
    return try napi.ArrayBuffer.copy(env, bytes[0..actual_len]);
}

pub fn create_arraybuffer_new(env: napi.Env, len: u32) !napi.ArrayBuffer {
    var arraybuffer = try napi.ArrayBuffer.New(env, @intCast(len));
    @memset(arraybuffer.asSlice(), 0x6b);
    return arraybuffer;
}

pub fn create_external_arraybuffer(env: napi.Env, len: u32) !napi.ArrayBuffer {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| {
        byte.* = @intCast((i + 3) % 251);
    }
    return try napi.ArrayBuffer.fromWithFinalizer(env, bytes, onExternalArrayBufferFinalized);
}

pub fn arraybuffer_length(value: napi.ArrayBuffer) usize {
    return value.length();
}

pub fn arraybuffer_first_byte(value: napi.ArrayBuffer) u8 {
    return if (value.length() == 0) 0 else value.asConstSlice()[0];
}

pub fn create_uint8_typedarray_copy(env: napi.Env) !napi.Uint8Array {
    const bytes = [_]u8{ 1, 2, 3, 4 };
    return try napi.Uint8Array.copy(env, &bytes);
}

pub fn create_int16_typedarray_copy(env: napi.Env) !napi.Int16Array {
    const values = [_]i16{ -1, 2, 3 };
    return try napi.Int16Array.copy(env, &values);
}

pub fn create_uint16_typedarray_copy(env: napi.Env) !napi.Uint16Array {
    const values = [_]u16{ 4, 5, 6 };
    return try napi.Uint16Array.copy(env, &values);
}

pub fn create_int32_typedarray_copy(env: napi.Env) !napi.Int32Array {
    const values = [_]i32{ -7, 8, 9 };
    return try napi.Int32Array.copy(env, &values);
}

pub fn create_uint32_typedarray_copy(env: napi.Env) !napi.Uint32Array {
    const values = [_]u32{ 10, 11, 12 };
    return try napi.Uint32Array.copy(env, &values);
}

pub fn create_float64_typedarray_copy(env: napi.Env) !napi.Float64Array {
    const values = [_]f64{ 1.5, 2.25, -0.75 };
    return try napi.Float64Array.copy(env, &values);
}

pub fn create_external_uint8_typedarray(env: napi.Env) !napi.Uint8Array {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, 4);
    errdefer allocator.free(bytes);
    @memcpy(bytes, &[_]u8{ 5, 6, 7, 8 });
    const arraybuffer = try napi.ArrayBuffer.fromWithFinalizer(env, bytes, onExternalTypedArrayFinalized);
    return try napi.Uint8Array.fromArrayBuffer(env, arraybuffer, bytes.len, 0);
}

pub fn typedarray_sum(value: napi.Uint8Array) usize {
    var sum: usize = 0;
    for (value.asConstSlice()) |item| {
        sum += item;
    }
    return sum;
}

pub fn int16_typedarray_sum(value: napi.Int16Array) i64 {
    var sum: i64 = 0;
    for (value.asConstSlice()) |item| {
        sum += @intCast(item);
    }
    return sum;
}

pub fn uint16_typedarray_sum(value: napi.Uint16Array) i64 {
    var sum: i64 = 0;
    for (value.asConstSlice()) |item| {
        sum += @intCast(item);
    }
    return sum;
}

pub fn int32_typedarray_sum(value: napi.Int32Array) i64 {
    var sum: i64 = 0;
    for (value.asConstSlice()) |item| {
        sum += @intCast(item);
    }
    return sum;
}

pub fn uint32_typedarray_sum(value: napi.Uint32Array) i64 {
    var sum: i64 = 0;
    for (value.asConstSlice()) |item| {
        sum += @intCast(item);
    }
    return sum;
}

pub fn float32_typedarray_sum(value: napi.Float32Array) f64 {
    var sum: f64 = 0;
    for (value.asConstSlice()) |item| {
        sum += item;
    }
    return sum;
}

pub fn float64_typedarray_sum(value: napi.Float64Array) f64 {
    var sum: f64 = 0;
    for (value.asConstSlice()) |item| {
        sum += item;
    }
    return sum;
}

pub fn create_dataview_copy(env: napi.Env) !napi.DataView {
    const bytes = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    return try napi.DataView.copy(env, &bytes);
}

pub fn create_dataview_new(env: napi.Env, len: u32) !napi.DataView {
    var view = try napi.DataView.New(env, @intCast(len));
    @memset(view.asSlice(), 0);
    return view;
}

pub fn create_external_dataview(env: napi.Env) !napi.DataView {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, 4);
    errdefer allocator.free(bytes);
    @memcpy(bytes, &[_]u8{ 0x78, 0x56, 0x34, 0x12 });
    const arraybuffer = try napi.ArrayBuffer.fromWithFinalizer(env, bytes, onExternalDataViewFinalized);
    return try napi.DataView.fromArrayBuffer(env, arraybuffer, 0, bytes.len);
}

pub fn dataview_length(value: napi.DataView) usize {
    return value.byteLength();
}

pub fn dataview_uint32_le(value: napi.DataView) !u32 {
    return try value.readInt(u32, 0, true);
}

pub fn dataview_accessors_roundtrip(env: napi.Env) !bool {
    const view = try napi.DataView.New(env, 64);

    try view.setInt8(0, -5);
    try view.setUint8(1, 250);
    try view.setInt16(2, -1234, true);
    try view.setUint16(4, 4321, false);
    try view.setInt32(8, -123456, true);
    try view.setUint32(12, 0x89abcdef, false);
    try view.setBigInt64(16, -123456789, true);
    try view.setBigUint64(24, 123456789, false);
    try view.setFloat32(32, 3.5, true);
    try view.setFloat64(40, 6.25, false);

    if ((try view.getInt8(0)) != -5) return false;
    if ((try view.getUint8(1)) != 250) return false;
    if ((try view.getInt16(2, true)) != -1234) return false;
    if ((try view.getUint16(4, false)) != 4321) return false;
    if ((try view.getInt32(8, true)) != -123456) return false;
    if ((try view.getUint32(12, false)) != 0x89abcdef) return false;
    if ((try view.getBigInt64(16, true)) != -123456789) return false;
    if ((try view.getBigUint64(24, false)) != 123456789) return false;
    if (!std.math.approxEqAbs(f32, try view.getFloat32(32, true), 3.5, 0.001)) return false;
    if (!std.math.approxEqAbs(f64, try view.getFloat64(40, false), 6.25, 0.001)) return false;

    return true;
}

pub fn invalid_typedarray_from_arraybuffer(env: napi.Env) !void {
    const arraybuffer = try napi.ArrayBuffer.New(env, 4);
    _ = try napi.Uint32Array.fromArrayBuffer(env, arraybuffer, 2, 1);
}

pub fn invalid_dataview_from_arraybuffer(env: napi.Env) !void {
    const arraybuffer = try napi.ArrayBuffer.New(env, 4);
    _ = try napi.DataView.fromArrayBuffer(env, arraybuffer, 3, 2);
}
