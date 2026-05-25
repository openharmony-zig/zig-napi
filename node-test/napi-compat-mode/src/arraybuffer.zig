const std = @import("std");
const napi = @import("napi");

pub fn getArraybufferLength(buffer: napi.ArrayBuffer) usize {
    return buffer.length();
}

pub fn mutateUint8Array(values: napi.Uint8Array) void {
    if (values.length() > 0) values.asSlice()[0] = 42;
}

pub fn mutateUint16Array(values: napi.Uint16Array) void {
    if (values.length() > 0) values.asSlice()[0] = 65535;
}

pub fn mutateInt16Array(values: napi.Int16Array) void {
    if (values.length() > 0) values.asSlice()[0] = 32767;
}

pub fn mutateFloat32Array(values: napi.Float32Array) void {
    if (values.length() > 0) values.asSlice()[0] = 3.33;
}

pub fn mutateFloat64Array(values: napi.Float64Array) void {
    if (values.length() > 0) values.asSlice()[0] = std.math.pi;
}
