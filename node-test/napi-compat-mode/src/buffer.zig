const napi = @import("napi");

fn noopFinalize() void {}

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
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, 3);
    errdefer allocator.free(bytes);
    @memcpy(bytes, &[_]u8{ 1, 2, 3 });
    return try napi.Buffer.fromWithFinalizer(env, bytes, null);
}

pub fn createBorrowedBufferWithFinalize(env: napi.Env) !napi.Buffer {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, 3);
    errdefer allocator.free(bytes);
    @memcpy(bytes, &[_]u8{ 1, 2, 3 });
    return try napi.Buffer.fromWithFinalizer(env, bytes, noopFinalize);
}

pub fn createEmptyBuffer(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, &[_]u8{});
}

pub fn createEmptyBufferFromNew(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.New(env, 0);
}

pub fn createEmptyExternalBuffer(env: napi.Env) !napi.Buffer {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, 0);
    errdefer allocator.free(bytes);
    return try napi.Buffer.from(env, bytes);
}

pub fn mutateBuffer(buffer: napi.Buffer) void {
    if (buffer.length() > 1) {
        buffer.asSlice()[1] = 42;
    }
}
