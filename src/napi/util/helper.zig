const std = @import("std");

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
