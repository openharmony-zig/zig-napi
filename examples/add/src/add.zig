const napi = @import("napi");

fn add(callback_info: napi.CallbackInfo) napi.Value {
    const a = callback_info.Get(0).As(napi.Number);
    const b = callback_info.Get(1).As(napi.Number);
    const result = a.FloatValue() + b.FloatValue();
    const result_number = napi.Number.New(callback_info.Env(), result);
    return result_number.ToValue();
}

fn init(_: napi.Env, exports: napi.Object) napi.Object {
    exports.Set("add", add);
    return exports;
}

comptime {
    napi.NODE_API_MODULE("hello", init);
}
