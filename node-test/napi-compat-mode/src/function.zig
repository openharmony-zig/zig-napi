const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

pub fn testCallFunction(callback: napi.Function(struct { []const u8, []const u8 }, napi.Undefined)) !void {
    _ = try callback.Call(.{ "hello", "world" });
}

pub fn testCallFunctionWithRefArguments(callback: napi.Function(struct { []const u8, []const u8 }, napi.Undefined)) !void {
    _ = try callback.Call(.{ "hello", "world" });
}

pub fn testCallFunctionError(callback: napi.Function(struct {}, napi.Undefined), error_callback: napi.Function([]const u8, napi.Undefined)) void {
    var undefined_value: c.napi_value = undefined;
    _ = c.napi_get_undefined(callback.env, &undefined_value);

    var result: c.napi_value = undefined;
    const call_status = c.napi_call_function(callback.env, undefined_value, callback.raw, 0, null, &result);
    if (call_status != c.napi_ok) {
        var pending = false;
        _ = c.napi_is_exception_pending(callback.env, &pending);
        if (pending) {
            var exception: c.napi_value = undefined;
            _ = c.napi_get_and_clear_last_exception(callback.env, &exception);
        }
        _ = error_callback.Call("Testing") catch return;
    }
}

fn argumentsLength(_: i32) []const u8 {
    return "arguments length: 1";
}

pub fn testCreateFunctionFromClosure(env: napi.Env) !napi.Function(i32, []const u8) {
    return try napi.Function(i32, []const u8).New(env, "argumentsLength", argumentsLength);
}
