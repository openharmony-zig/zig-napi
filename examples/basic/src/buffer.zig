const napi = @import("napi");

pub fn create_buffer(env: napi.Env) !napi.Buffer {
    return napi.Buffer.New(env, 1024);
}

pub fn create_empty_buffer_new(env: napi.Env) !napi.Buffer {
    return napi.Buffer.New(env, 0);
}

pub fn create_empty_buffer_copy(env: napi.Env) !napi.Buffer {
    return napi.Buffer.copy(env, &[_]u8{});
}

pub fn create_empty_external_buffer(env: napi.Env) !napi.Buffer {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, 0);
    errdefer allocator.free(bytes);
    return napi.Buffer.from(env, bytes);
}

pub fn get_buffer(buf: napi.Buffer) !usize {
    return buf.length();
}

pub fn get_buffer_as_string(buf: napi.Buffer) ![]u8 {
    return buf.asSlice();
}
