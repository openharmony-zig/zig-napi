const napi = @import("napi");

fn initialize(_: napi.Env, _: napi.Object) !?napi.Object {
    return error.InitFailed;
}

comptime {
    napi.NODE_API_MODULE_WITH_INIT("init_failure", @This(), initialize);
}
