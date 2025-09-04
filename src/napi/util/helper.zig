fn isString(comptime T: type) bool {
    const info = @typeInfo(T);

    switch (info) {
        .Pointer => |ptr| {
            return ptr.child == u8;
        },
        .Array => |arr| {
            return arr.child == u8;
        },
        else => return false,
    }
}
