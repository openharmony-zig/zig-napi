const napi = @import("napi");

pub fn create_buffer(env: napi.Env) !napi.Buffer {
    return napi.Buffer.New(env, 1024);
}

pub fn get_buffer(buf: napi.Buffer) ![]u8 {
    return buf.asSlice();
}
