const napi = @import("napi");

pub fn getBufferLength(buffer: napi.Buffer) usize {
    return buffer.length();
}

pub fn bufferToString(buffer: napi.Buffer) ![]u8 {
    const allocator = napi.globalAllocator();
    const out = try allocator.alloc(u8, buffer.length());
    @memcpy(out, buffer.asConstSlice());
    return out;
}

pub fn copyBuffer(env: napi.Env, buffer: napi.Buffer) !napi.Buffer {
    return try napi.Buffer.copy(env, buffer.asConstSlice());
}

pub fn createBorrowedBufferWithNoopFinalize(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, &[_]u8{ 1, 2, 3 });
}

pub fn createBorrowedBufferWithFinalize(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, &[_]u8{ 1, 2, 3 });
}

pub fn createEmptyBuffer(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, &[_]u8{});
}

pub fn mutateBuffer(buffer: napi.Buffer) void {
    if (buffer.length() > 1) {
        buffer.asSlice()[1] = 42;
    }
}
