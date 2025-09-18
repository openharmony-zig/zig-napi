const napi = @import("napi");

pub fn call_function(cb: napi.Function) !i32 {
    return try cb.Call(.{ 1, 2 }, i32);
}
