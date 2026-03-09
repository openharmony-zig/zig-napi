const napi = @import("napi");

const Args = struct { i32, i32 };

pub fn call_function_with_reference(env: napi.Env, cb: napi.Function(Args, i32)) !i32 {
    var reference = try cb.CreateRef();
    defer reference.Unref(env) catch @panic("Failed to unref reference");

    const function = try reference.GetValue(env);
    return try function.Call(.{ 1, 2 });
}
