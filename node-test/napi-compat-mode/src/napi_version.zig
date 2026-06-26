const napi = @import("napi");

pub fn getNapiVersion(env: napi.Env) u32 {
    return env.getNapiVersion();
}
