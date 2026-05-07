const napi = @import("napi");

pub fn allocator_kind() []const u8 {
    return "builtin-page";
}

pub fn manual_allocation_roundtrip(len: u32) bool {
    const allocator = napi.globalAllocator();
    const bytes = allocator.alloc(u8, len) catch return false;
    defer allocator.free(bytes);

    @memset(bytes, 0x2a);
    return bytes.len == len and (len == 0 or bytes[0] == 0x2a);
}

pub fn make_js_owned_buffer(env: napi.Env, len: u32) !napi.Buffer {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);

    for (bytes, 0..) |*byte, index| {
        byte.* = @intCast((index + 3) % 251);
    }
    return try napi.Buffer.from(env, bytes);
}

pub fn make_copied_buffer(env: napi.Env) !napi.Buffer {
    const bytes = [_]u8{ 2, 4, 6, 8 };
    return try napi.Buffer.copy(env, &bytes);
}

pub fn input_sum(input: napi.Buffer) u32 {
    var sum: u32 = 0;
    for (input.asConstSlice()) |byte| {
        sum += byte;
    }
    return sum;
}

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
