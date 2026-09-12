const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Env = @import("../env.zig").Env;
const Napi = @import("../util/napi.zig").Napi;
const helper = @import("../util/helper.zig");
const ArrayList = std.ArrayList;
const NapiError = @import("../wrapper/error.zig");
const GlobalAllocator = @import("../util/allocator.zig");
const typedarray = @import("../wrapper/typedarray.zig");
const ArrayBuffer = @import("../wrapper/arraybuffer.zig").ArrayBuffer;
const options = @import("../options.zig");

pub const Array = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    len: u32,
    type: napi.napi_valuetype,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Array {
        var len: u32 = 0;
        const status = napi.napi_get_array_length(env, raw, &len);
        if (status != napi.napi_ok) {
            // The handle is still usable for element access; the length is only a
            // cached hint, so report it as zero instead of failing construction.
            len = 0;
        }
        return Array{ .env = env, .raw = raw, .len = len, .type = napi.napi_object };
    }

    pub fn length(self: Array) u32 {
        return self.len;
    }

    pub fn Get(self: Array, index: u32, comptime T: type) !T {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_get_element(self.env, self.raw, index, &raw);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return Napi.from_napi_value_auto(self.env, raw, T);
    }

    fn arrayLength(env: napi.napi_env, raw: napi.napi_value) !u32 {
        var len: u32 = 0;
        const status = napi.napi_get_array_length(env, raw, &len);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
        return len;
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        const infos = @typeInfo(T);
        var is_typedarray = false;
        const typedarray_status = napi.napi_is_typedarray(env, raw, &is_typedarray);
        if (typedarray_status != napi.napi_ok) {
            return NapiError.failStatus(typedarray_status);
        }

        if (is_typedarray and comptime supports_typedarray_target(T)) {
            return from_typedarray_value(env, raw, T);
        }

        switch (infos) {
            .array => {
                const array_len = comptime infos.array.len;
                const actual_len = try arrayLength(env, raw);
                if (actual_len != array_len) {
                    return NapiError.failRangeError(
                        "Expected an array of length {d} for {s}, got {d}",
                        .{ array_len, helper.shortTypeName(T), actual_len },
                    );
                }

                var result: T = undefined;
                var initialized: usize = 0;
                errdefer cleanupPrefix(infos.array.child, &result, initialized);

                for (0..array_len) |i| {
                    var element: napi.napi_value = undefined;
                    const status = napi.napi_get_element(env, raw, @intCast(i), &element);
                    if (status != napi.napi_ok) {
                        return NapiError.failStatus(status);
                    }
                    result[i] = try Napi.from_napi_value_auto(env, element, infos.array.child);
                    initialized = i + 1;
                }

                return result;
            },
            .pointer => {
                if (comptime helper.isSlice(T)) {
                    const len = try arrayLength(env, raw);

                    const allocator = GlobalAllocator.globalAllocator();
                    const buf = try allocator.alloc(infos.pointer.child, len);
                    var initialized: usize = 0;
                    errdefer {
                        for (buf[0..initialized]) |item| {
                            Napi.deinit_napi_value_with_allocator(infos.pointer.child, item, allocator);
                        }
                        allocator.free(buf);
                    }

                    for (0..len) |i| {
                        var element: napi.napi_value = undefined;
                        const status = napi.napi_get_element(env, raw, @intCast(i), &element);
                        if (status != napi.napi_ok) {
                            return NapiError.failStatus(status);
                        }
                        buf[i] = try Napi.from_napi_value_auto(env, element, infos.pointer.child);
                        initialized = i + 1;
                    }
                    return buf;
                }
                @compileError("Only support slice type, Unsupported type: " ++ @typeName(T));
            },
            .@"struct" => {
                if (comptime helper.isTuple(T)) {
                    const field_count = infos.@"struct".fields.len;
                    const actual_len = try arrayLength(env, raw);
                    if (actual_len != field_count) {
                        return NapiError.failRangeError(
                            "Expected an array of length {d} for tuple {s}, got {d}",
                            .{ field_count, helper.shortTypeName(T), actual_len },
                        );
                    }

                    var result: T = undefined;
                    var initialized: usize = 0;
                    errdefer {
                        inline for (infos.@"struct".fields, 0..) |field, i| {
                            if (i < initialized) {
                                Napi.deinit_napi_value_with_allocator(field.type, @field(result, field.name), GlobalAllocator.globalAllocator());
                            }
                        }
                    }

                    inline for (infos.@"struct".fields, 0..) |field, i| {
                        var element: napi.napi_value = undefined;
                        const status = napi.napi_get_element(env, raw, @intCast(i), &element);
                        if (status != napi.napi_ok) {
                            return NapiError.failStatus(status);
                        }
                        @field(result, field.name) = try Napi.from_napi_value_auto(env, element, field.type);
                        initialized = i + 1;
                    }
                    return result;
                }
                if (comptime helper.isArrayList(T)) {
                    // Get Array List's items type
                    const child = comptime helper.getArrayListElementType(T);

                    const allocator = GlobalAllocator.globalAllocator();

                    var result: T = T.empty;
                    var initialized: usize = 0;
                    errdefer {
                        for (result.items[0..initialized]) |item| {
                            Napi.deinit_napi_value_with_allocator(child, item, allocator);
                        }
                        result.deinit(allocator);
                    }

                    const len = try arrayLength(env, raw);
                    try result.ensureTotalCapacity(allocator, len);
                    for (0..len) |i| {
                        var element: napi.napi_value = undefined;
                        const status = napi.napi_get_element(env, raw, @intCast(i), &element);
                        if (status != napi.napi_ok) {
                            return NapiError.failStatus(status);
                        }
                        const converted = try Napi.from_napi_value_auto(env, element, child);
                        try result.append(allocator, converted);
                        initialized += 1;
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

    /// Release the elements that were converted before the current element failed.
    fn cleanupPrefix(comptime Child: type, result: anytype, initialized: usize) void {
        const allocator = GlobalAllocator.globalAllocator();
        for (result[0..initialized]) |item| {
            Napi.deinit_napi_value_with_allocator(Child, item, allocator);
        }
    }

    /// Checked element conversion for typed array sources. Out of range and
    /// non finite values report an error instead of aborting the process.
    fn numericCast(comptime Dst: type, value: anytype) !Dst {
        const dst_info = @typeInfo(Dst);
        const src_info = @typeInfo(@TypeOf(value));

        return switch (dst_info) {
            .int => switch (src_info) {
                .int => std.math.cast(Dst, value) orelse NapiError.failRangeError(
                    "TypedArray element {d} is out of range for {s}",
                    .{ value, helper.shortTypeName(Dst) },
                ),
                .float => blk: {
                    const float_value: f64 = @floatCast(value);
                    if (!std.math.isFinite(float_value)) {
                        return NapiError.failRangeError(
                            "TypedArray element {d} cannot be converted to {s}",
                            .{ float_value, helper.shortTypeName(Dst) },
                        );
                    }
                    const truncated = @trunc(float_value);
                    // 2^63 is exactly representable as f64; compare exclusively so
                    // that the conversion to i64 below can never overflow.
                    if (truncated < -9223372036854775808.0 or truncated >= 9223372036854775808.0) {
                        return NapiError.failRangeError(
                            "TypedArray element {d} is out of range for {s}",
                            .{ float_value, helper.shortTypeName(Dst) },
                        );
                    }
                    const wide: i64 = @intFromFloat(truncated);
                    break :blk std.math.cast(Dst, wide) orelse NapiError.failRangeError(
                        "TypedArray element {d} is out of range for {s}",
                        .{ float_value, helper.shortTypeName(Dst) },
                    );
                },
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

    fn fillFromTypedArray(comptime Dst: type, out: []Dst, raw_type: napi.napi_typedarray_type, data: ?*anyopaque, len: usize) !void {
        switch (raw_type) {
            napi.napi_int8_array => {
                const source: []const i8 = if (len == 0 or data == null) &[_]i8{} else @as([*]const i8, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
            },
            napi.napi_uint8_array, napi.napi_uint8_clamped_array => {
                const source: []const u8 = if (len == 0 or data == null) &[_]u8{} else @as([*]const u8, @ptrCast(data))[0..len];
                for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
            },
            napi.napi_int16_array => {
                const source: []const i16 = if (len == 0 or data == null) &[_]i16{} else @as([*]const i16, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
            },
            napi.napi_uint16_array => {
                const source: []const u16 = if (len == 0 or data == null) &[_]u16{} else @as([*]const u16, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
            },
            napi.napi_int32_array => {
                const source: []const i32 = if (len == 0 or data == null) &[_]i32{} else @as([*]const i32, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
            },
            napi.napi_uint32_array => {
                const source: []const u32 = if (len == 0 or data == null) &[_]u32{} else @as([*]const u32, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
            },
            napi.napi_float32_array => {
                const source: []const f32 = if (len == 0 or data == null) &[_]f32{} else @as([*]const f32, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
            },
            napi.napi_float64_array => {
                const source: []const f64 = if (len == 0 or data == null) &[_]f64{} else @as([*]const f64, @ptrCast(@alignCast(data)))[0..len];
                for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
            },
            else => {
                if (options.selectedNapiVersion().isAtLeast(.v6) and raw_type == napi.napi_bigint64_array) {
                    const source: []const i64 = if (len == 0 or data == null) &[_]i64{} else @as([*]const i64, @ptrCast(@alignCast(data)))[0..len];
                    for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
                } else if (options.selectedNapiVersion().isAtLeast(.v6) and raw_type == napi.napi_biguint64_array) {
                    const source: []const u64 = if (len == 0 or data == null) &[_]u64{} else @as([*]const u64, @ptrCast(@alignCast(data)))[0..len];
                    for (out, source) |*dst, src| dst.* = try numericCast(Dst, src);
                } else {
                    unreachable;
                }
            },
        }
    }

    fn from_typedarray_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        var raw_type: napi.napi_typedarray_type = undefined;
        var len: usize = 0;
        var data: ?*anyopaque = null;
        var arraybuffer: napi.napi_value = undefined;
        var byte_offset: usize = 0;

        const info_status = napi.napi_get_typedarray_info(env, raw, &raw_type, &len, &data, &arraybuffer, &byte_offset);
        if (info_status != napi.napi_ok) {
            return NapiError.failStatus(info_status);
        }

        const arraybuffer_value = ArrayBuffer.from_raw(env, arraybuffer);
        const element_len = typedarray.normalizeElementLength(len, raw_type, arraybuffer_value.length(), byte_offset);

        const infos = @typeInfo(T);

        switch (infos) {
            .array => |arr| {
                if (!comptime typedarray.isSupportedElementType(arr.child)) {
                    @compileError("TypedArray only supports numeric array targets, got: " ++ @typeName(T));
                }

                if (element_len != arr.len) {
                    return NapiError.failRangeError(
                        "Expected a typed array of length {d} for {s}, got {d}",
                        .{ arr.len, helper.shortTypeName(T), element_len },
                    );
                }

                var result: T = std.mem.zeroes(T);
                try fillFromTypedArray(arr.child, result[0..], raw_type, data, element_len);
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
                const buf = try allocator.alloc(ptr.child, element_len);
                errdefer allocator.free(buf);
                try fillFromTypedArray(ptr.child, buf, raw_type, data, element_len);
                return buf;
            },
            .@"struct" => {
                if (comptime helper.isArrayList(T)) {
                    const child = comptime helper.getArrayListElementType(T);
                    if (!comptime typedarray.isSupportedElementType(child)) {
                        @compileError("TypedArray only supports numeric ArrayList targets, got: " ++ @typeName(T));
                    }

                    const allocator = GlobalAllocator.globalAllocator();
                    const items = try allocator.alloc(child, element_len);
                    defer allocator.free(items);
                    try fillFromTypedArray(child, items, raw_type, data, element_len);

                    var result: T = T.empty;
                    errdefer result.deinit(allocator);
                    try result.ensureTotalCapacity(allocator, element_len);
                    for (items) |item| {
                        try result.append(allocator, item);
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
            len = @intCast(array.items.len);
        }

        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_array(env.raw, &raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        if (infos == .array or comptime helper.isSlice(array_type)) {
            for (array, 0..) |item, i| {
                const napi_value = try Napi.to_napi_value_auto(env.raw, item, null);
                try setElement(env.raw, raw, @intCast(i), napi_value);
            }
        } else if (comptime helper.isTuple(array_type)) {
            inline for (infos.@"struct".fields, 0..) |item, i| {
                const value = @field(array, item.name);
                const napi_value = try Napi.to_napi_value_auto(env.raw, value, null);
                try setElement(env.raw, raw, @intCast(i), napi_value);
            }
        } else if (comptime helper.isArrayList(array_type)) {
            for (array.items, 0..) |item, i| {
                const napi_value = try Napi.to_napi_value_auto(env.raw, item, null);
                try setElement(env.raw, raw, @intCast(i), napi_value);
            }
        }

        return Array{
            .env = env.raw,
            .raw = raw,
            .len = len,
            .type = napi.napi_object,
        };
    }

    fn setElement(env: napi.napi_env, raw: napi.napi_value, index: u32, value: napi.napi_value) !void {
        const status = napi.napi_set_element(env, raw, index, value);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }
    }

    pub fn Create(env: Env) !Array {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_array(env.raw, &raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        return Array{
            .env = env.raw,
            .raw = raw,
            .len = 0,
            .type = napi.napi_object,
        };
    }

    pub fn CreateWithLength(env: Env, len: u32) !Array {
        var raw: napi.napi_value = undefined;
        const status = napi.napi_create_array_with_length(env.raw, @intCast(len), &raw);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }

        return Array{
            .env = env.raw,
            .raw = raw,
            .len = len,
            .type = napi.napi_object,
        };
    }

    pub fn createWithLength(env: Env, len: u32) !Array {
        return Array.CreateWithLength(env, len);
    }

    pub fn Set(self: *Array, index: u32, value: anytype) !void {
        const napi_value = try Napi.to_napi_value_auto(self.env, value, null);
        try setElement(self.env, self.raw, index, napi_value);
        self.len = @max(self.len, index + 1);
    }

    pub fn HasElement(self: Array, index: u32) !bool {
        var result: bool = false;
        const status = napi.napi_has_element(self.env, self.raw, index, &result);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return result;
    }

    pub fn hasElement(self: Array, index: u32) !bool {
        return self.HasElement(index);
    }

    pub fn DeleteElement(self: Array, index: u32) !bool {
        var result: bool = false;
        const status = napi.napi_delete_element(self.env, self.raw, index, &result);
        if (status != napi.napi_ok) {
            return NapiError.Error.fromStatus(NapiError.Status.New(status));
        }
        return result;
    }

    pub fn deleteElement(self: Array, index: u32) !bool {
        return self.DeleteElement(index);
    }

    pub fn Push(self: *Array, value: anytype) !void {
        try self.Set(self.len, value);
    }
};
