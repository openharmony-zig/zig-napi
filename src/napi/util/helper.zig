const std = @import("std");
const math = std.math;

pub const StringMode = enum {
    Utf8,
    Utf16,
    Unknown,
};

pub fn stringLike(comptime T: type) StringMode {
    const info = @typeInfo(T);

    switch (info) {
        .pointer => |ptr| {
            const child_info = @typeInfo(ptr.child);
            switch (child_info) {
                .array => |arr| {
                    switch (arr.child) {
                        u8 => return StringMode.Utf8,
                        u16 => return StringMode.Utf16,
                        else => return StringMode.Unknown,
                    }
                },
                .int => |int| {
                    switch (int.bits) {
                        8 => return StringMode.Utf8,
                        16 => return StringMode.Utf16,
                        else => return StringMode.Unknown,
                    }
                },
                else => return StringMode.Unknown,
            }
        },
        .array => |arr| {
            switch (arr.child) {
                u8 => return StringMode.Utf8,
                u16 => return StringMode.Utf16,
                else => return StringMode.Unknown,
            }
        },
        else => return StringMode.Unknown,
    }
}

pub fn isTuple(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .@"struct" and info.@"struct".is_tuple;
}

pub fn isSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .slice;
}

pub fn isGenericType(comptime T: type, comptime name: []const u8) bool {
    const info = @typeName(T);
    return std.mem.indexOf(u8, info, name) != null;
}

pub fn getArrayListElementType(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("Expected struct type for ArrayList");
    }

    for (info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "items")) {
            const items_type_info = @typeInfo(field.type);
            if (items_type_info == .pointer and items_type_info.pointer.size == .slice) {
                return items_type_info.pointer.child;
            }
        }
    }

    @compileError("Could not extract element type from ArrayList: " ++ @typeName(T));
}

pub fn comptimeFloatMode(comptime value: comptime_float) type {
    const f32_min = math.floatMin(f32);
    const f32_max = math.floatMax(f32);
    const f64_min = math.floatMin(f64);
    const f64_max = math.floatMax(f64);

    // Check if it can be converted to f32 without loss
    if (value >= f32_min and value <= f32_max) {
        const as_f32: f32 = value;
        const back_to_comptime: f64 = as_f32; // 通过 f64 来比较
        if (@abs(back_to_comptime - @as(f64, value)) < 1e-6) {
            return f32;
        }
    }

    // Check if it can be converted to f64 without loss
    if (value >= f64_min and value <= f64_max) {
        const as_f64: f64 = value;
        const back_to_comptime: f128 = as_f64;
        if (@abs(back_to_comptime - @as(f128, value)) < 1e-15) {
            return f64;
        }
    }

    // Otherwise, it needs f128
    return f128;
}

pub fn comptimeIntMode(comptime value: comptime_int) type {
    // Check if it can be converted to i32 without loss
    if (value >= math.minInt(i32) and value <= math.maxInt(i32)) {
        return i32;
    }

    // Check if it can be converted to i64 without loss
    if (value >= math.minInt(i64) and value <= math.maxInt(i64)) {
        return i64;
    }

    return i128;
}
