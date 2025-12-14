const napi = @import("napi");

pub fn create_arraybuffer(env: napi.Env) !napi.ArrayBuffer {
    return napi.ArrayBuffer.New(env, 1024);
}

pub fn get_arraybuffer(buf: napi.ArrayBuffer) !usize {
    return buf.length();
}

pub fn get_arraybuffer_as_string(buf: napi.ArrayBuffer) ![]u8 {
    return buf.asSlice();
}
