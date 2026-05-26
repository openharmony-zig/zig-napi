const napi = @import("napi");

pub fn throw_error() !void {
    return napi.Error.fromReason("test");
}

pub fn result_ok() napi.Result(i32) {
    return napi.Result(i32).Ok(42);
}

pub fn result_error() napi.Result(i32) {
    return napi.Result(i32).Err(napi.Error.withReason("result error"));
}

pub fn result_void_ok() napi.Result(void) {
    return napi.Result(void).Ok({});
}

pub fn result_after_try(input: bool) !napi.Result(i32) {
    if (input) return napi.Result(i32).Ok(100);
    return napi.Result(i32).Err(napi.Error.withTypeError("result type error"));
}

pub fn throw_zig_error() !void {
    return error.ZigNativeFailure;
}

pub fn throw_zig_error_value() !i32 {
    return error.ZigValueFailure;
}
