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
