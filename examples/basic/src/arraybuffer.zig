const napi = @import("napi");

pub fn create_arraybuffer(env: napi.Env) !napi.ArrayBuffer {
    return napi.ArrayBuffer.New(env, 1024);
}

pub fn create_empty_arraybuffer_new(env: napi.Env) !napi.ArrayBuffer {
    return napi.ArrayBuffer.New(env, 0);
}

pub fn create_empty_arraybuffer_copy(env: napi.Env) !napi.ArrayBuffer {
    return napi.ArrayBuffer.copy(env, &[_]u8{});
}

pub fn create_empty_external_arraybuffer(env: napi.Env) !napi.ArrayBuffer {
    const allocator = napi.globalAllocator();
    const bytes = try allocator.alloc(u8, 0);
    errdefer allocator.free(bytes);
    return napi.ArrayBuffer.from(env, bytes);
}

pub fn get_arraybuffer(buf: napi.ArrayBuffer) !usize {
    return buf.length();
}

pub fn get_arraybuffer_as_string(buf: napi.ArrayBuffer) ![]u8 {
    return buf.asSlice();
}
