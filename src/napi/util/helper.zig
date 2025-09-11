pub const StringMode = enum {
    Utf8,
    Utf16,
    Unknown,
};

pub fn stringLike(comptime T: type) StringMode {
    const info = @typeInfo(T);

    switch (info) {
        .pointer => |ptr| {
            switch (ptr.child) {
                u8 => return StringMode.Utf8,
                u16 => return StringMode.Utf16,
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
