const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Napi = @import("../util/napi.zig").Napi;
const helper = @import("../util/helper.zig");
const ArrayList = std.ArrayList;
const NapiError = @import("../wrapper/error.zig");
const GlobalAllocator = @import("../util/allocator.zig");
const typedarray = @import("../wrapper/typedarray.zig");

pub const Array = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    len: u32,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Array {
        // TODO: check if the value is an array
        var len: u32 = 0;
        _ = napi.napi_get_array_length(env, raw, &len);
        return Array{ .env = env, .raw = raw, .len = len, .type = napi.napi_object };
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const infos = @typeInfo(T);
        var is_typedarray = false;
        _ = napi.napi_is_typedarray(env, raw, &is_typedarray);

        if (is_typedarray and comptime supports_typedarray_target(T)) {
            return from_typedarray_value(env, raw, T);
        }

        switch (infos) {
            .array => {
                const array_len = infos.array.len;

                for (0..array_len) |i| {
                    var element: napi.napi_value = undefined;
                    _ = napi.napi_get_element(env, raw, @intCast(i), &element);
                    T[i] = Napi.from_napi_value(env, element, infos.array.child);
                }

                return T;
            },
            .pointer => {
                if (comptime helper.isSlice(T)) {
                    // TODO: check if the value is an array
                    var len: u32 = undefined;
                    _ = napi.napi_get_array_length(env, raw, &len);

                    const allocator = GlobalAllocator.globalAllocator();
                    const buf = allocator.alloc(infos.pointer.child, len) catch @panic("OOM");

                    for (0..len) |i| {
                        var element: napi.napi_value = undefined;
                        _ = napi.napi_get_element(env, raw, @intCast(i), &element);
                        buf[i] = Napi.from_napi_value(env, element, infos.pointer.child);
                    }
                    return buf;
                }
                @compileError("Only support slice type, Unsupported type: " ++ @typeName(T));
            },
            .@"struct" => {
                if (comptime helper.isTuple(T)) {
                    var result: T = undefined;

                    inline for (infos.@"struct".fields, 0..) |field, i| {
                        var element: napi.napi_value = undefined;
                        _ = napi.napi_get_element(env, raw, @intCast(i), &element);
                        @field(result, field.name) = Napi.from_napi_value(env, element, field.type);
                    }
                    return result;
                }
                if (comptime helper.isArrayList(T)) {
                    // Get Array List's items type
                    const child = comptime helper.getArrayListElementType(T);

                    const allocator = GlobalAllocator.globalAllocator();

                    var result: T = ArrayList(child).empty;
                    var len: u32 = undefined;
                    _ = napi.napi_get_array_length(env, raw, &len);
                    result.ensureTotalCapacity(allocator, len) catch @panic("OOM");
                    for (0..len) |i| {
                        var element: napi.napi_value = undefined;
                        _ = napi.napi_get_element(env, raw, @intCast(i), &element);
                        result.append(allocator, Napi.from_napi_value(env, element, child)) catch @panic("OOM");
                    }
                    return result;
                }
                @compileError("Only support array, slice, and tuple type, Unsupported type: " ++ @typeName(T));
            },
            else => {
                @compileError("Only support array, slice, and tuple type, Unsupported type: " ++ @typeName(infos));
            },
        }
    }

    fn numericCast(comptime Dst: type, value: anytype) Dst {
        const dst_info = @typeInfo(Dst);
        const src_info = @typeInfo(@TypeOf(value));

        return switch (dst_info) {
            .int => switch (src_info) {
                .int => @intCast(value),
                .float => @intFromFloat(value),
                else => @compileError("Unsupported typed array destination type: " ++ @typeName(Dst)),
            },
            .float => switch (src_info) {
                .int => @floatFromInt(value),
                .float => @floatCast(value),
                else => @compileError("Unsupported typed array destination type: " ++ @typeName(Dst)),
            },
            else => @compileError("Unsupported typed array destination type: " ++ @typeName(Dst)),
        };
    }

    fn supports_typedarray_target(comptime T: type) bool {
        const infos = @typeInfo(T);
        switch (infos) {
            .array => |arr| return typedarray.isSupportedElementType(arr.child),
            .pointer => |ptr| return helper.isSlice(T) and typedarray.isSupportedElementType(ptr.child),
            .@"struct" => {
                if (helper.isArrayList(T)) {
                    return typedarray.isSupportedElementType(helper.getArrayListElementType(T));
                }
                return false;
            },
            else => return false,
        }
    }

    fn fillFromTypedArray(comptime Dst: type, out: []Dst, raw_type: napi.napi_typedarray_type, data: ?*anyopaque, len: usize) void {
        switch (raw_type) {
            napi.napi_int8_array => {
                const source: []const i8 = if (len == 0 or data == null) &[_]i8{} else @as([*]const i8, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            napi.napi_uint8_array, napi.napi_uint8_clamped_array => {
                const source: []const u8 = if (len == 0 or data == null) &[_]u8{} else @as([*]const u8, @ptrCast(data))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            napi.napi_int16_array => {
                const source: []const i16 = if (len == 0 or data == null) &[_]i16{} else @as([*]const i16, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            napi.napi_uint16_array => {
                const source: []const u16 = if (len == 0 or data == null) &[_]u16{} else @as([*]const u16, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            napi.napi_int32_array => {
                const source: []const i32 = if (len == 0 or data == null) &[_]i32{} else @as([*]const i32, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            napi.napi_uint32_array => {
                const source: []const u32 = if (len == 0 or data == null) &[_]u32{} else @as([*]const u32, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            napi.napi_float32_array => {
                const source: []const f32 = if (len == 0 or data == null) &[_]f32{} else @as([*]const f32, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            napi.napi_float64_array => {
                const source: []const f64 = if (len == 0 or data == null) &[_]f64{} else @as([*]const f64, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            napi.napi_bigint64_array => {
                const source: []const i64 = if (len == 0 or data == null) &[_]i64{} else @as([*]const i64, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            napi.napi_biguint64_array => {
                const source: []const u64 = if (len == 0 or data == null) &[_]u64{} else @as([*]const u64, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = numericCast(Dst, src);
            },
            else => unreachable,
        }
    }

    fn from_typedarray_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        var raw_type: napi.napi_typedarray_type = undefined;
        var len: usize = 0;
        var data: ?*anyopaque = null;
        var arraybuffer: napi.napi_value = undefined;
        var byte_offset: usize = 0;

        _ = napi.napi_get_typedarray_info(env, raw, &raw_type, &len, &data, &arraybuffer, &byte_offset);

        const infos = @typeInfo(T);

        switch (infos) {
            .array => |arr| {
                if (!comptime typedarray.isSupportedElementType(arr.child)) {
                    @compileError("TypedArray only supports numeric array targets, got: " ++ @typeName(T));
                }

                var result: T = std.mem.zeroes(T);
                const copy_len = @min(len, arr.len);
                fillFromTypedArray(arr.child, result[0..copy_len], raw_type, data, copy_len);
                return result;
            },
            .pointer => |ptr| {
                if (!comptime helper.isSlice(T)) {
                    @compileError("TypedArray only supports slice targets, got: " ++ @typeName(T));
                }
                if (!comptime typedarray.isSupportedElementType(ptr.child)) {
                    @compileError("TypedArray only supports numeric slice targets, got: " ++ @typeName(T));
                }

                const allocator = GlobalAllocator.globalAllocator();
                const buf = allocator.alloc(ptr.child, len) catch @panic("OOM");
                fillFromTypedArray(ptr.child, buf, raw_type, data, len);
                return buf;
            },
            .@"struct" => {
                if (comptime helper.isArrayList(T)) {
                    const child = comptime helper.getArrayListElementType(T);
                    if (!comptime typedarray.isSupportedElementType(child)) {
                        @compileError("TypedArray only supports numeric ArrayList targets, got: " ++ @typeName(T));
                    }

                    const allocator = GlobalAllocator.globalAllocator();
                    var result: T = ArrayList(child).empty;
                    result.ensureTotalCapacity(allocator, len) catch @panic("OOM");
                    const items = allocator.alloc(child, len) catch @panic("OOM");
                    defer allocator.free(items);
                    fillFromTypedArray(child, items, raw_type, data, len);
                    for (items) |item| {
                        result.append(allocator, item) catch @panic("OOM");
                    }
                    return result;
                }
                @compileError("TypedArray only supports array, slice, and ArrayList targets, got: " ++ @typeName(T));
            },
            else => @compileError("TypedArray only supports array, slice, and ArrayList targets, got: " ++ @typeName(T)),
        }
    }

    pub fn New(env: Env, array: anytype) !Array {
        const array_type = @TypeOf(array);
        const infos = @typeInfo(array_type);

        if (infos != .array and (comptime !helper.isSlice(array_type)) and (comptime !helper.isTuple(array_type)) and (comptime !helper.isArrayList(array_type))) {
            @compileError("Array.New only support array,ArrayList,slice or tuple type, Unsupported type: " ++ @typeName(array_type));
        }
        var len: u32 = undefined;
        if (infos == .array) {
            len = infos.array.len;
        } else if (comptime helper.isSlice(array_type)) {
            len = @intCast(array.len);
        } else if (comptime helper.isTuple(array_type)) {
            len = infos.@"struct".fields.len;
        } else if (comptime helper.isArrayList(array_type)) {
            len = @intCast(array.capacity);
        }

        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_array(env.raw, &raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        if (infos == .array or comptime helper.isSlice(array_type)) {
            for (array, 0..) |item, i| {
                const napi_value = try Napi.to_napi_value(env.raw, item, null);
                _ = napi.napi_set_element(env.raw, raw, @intCast(i), napi_value);
            }
        } else if (comptime helper.isTuple(array_type)) {
            inline for (infos.@"struct".fields, 0..) |item, i| {
                const value = @field(array, item.name);
                const napi_value = try Napi.to_napi_value(env.raw, value, null);
                _ = napi.napi_set_element(env.raw, raw, @intCast(i), napi_value);
            }
        } else if (comptime helper.isArrayList(array_type)) {
            for (array.items, 0..) |item, i| {
                const napi_value = try Napi.to_napi_value(env.raw, item, null);
                _ = napi.napi_set_element(env.raw, raw, @intCast(i), napi_value);
            }
        }

        return Array{
            .env = env.raw,
            .raw = raw,
            .len = len,
            .type = napi.napi_object,
        };
    }
};
