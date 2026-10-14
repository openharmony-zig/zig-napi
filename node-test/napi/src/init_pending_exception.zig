const napi = @import("napi");

fn initialize(env: napi.Env, _: napi.Object) !?napi.Object {
    const api = napi.napi_sys.napi_sys;
    if (api.napi_throw_error(env.raw, "OriginalInitError", "original init exception") != api.napi_ok) return error.ThrowFailed;
    return error.InitFailed;
}

comptime {
    napi.NODE_API_MODULE_WITH_INIT("init_pending_exception", @This(), initialize);
}
