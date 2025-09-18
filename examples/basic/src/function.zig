const napi = @import("napi");

const Args = struct { i32, i32 };

pub fn call_function(cb: napi.Function(Args, i32)) !i32 {
    return try cb.Call(.{ 1, 2 });
}

pub fn basic_function(left: i32, right: i32) i32 {
    return left + right;
}

pub fn create_function(env: napi.Env) !napi.Function(Args, i32) {
    return try napi.Function(Args, i32).New(env, "basic_function", basic_function);
}
