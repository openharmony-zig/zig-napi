const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

pub fn getNapiVersion(env: napi.Env) u32 {
    var result: u32 = 0;
    _ = c.napi_get_version(env.raw, &result);
    return result;
}
