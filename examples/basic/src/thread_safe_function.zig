const std = @import("std");
const napi = @import("napi");

const Args = struct { i32, i32 };
const Return = i32;

pub fn call_thread_safe_function(tsfn: napi.ThreadSafeFunction(Args, Return)) !Return {
    return try tsfn.Call(.{ 1, 2 }, .Blocking);
}
