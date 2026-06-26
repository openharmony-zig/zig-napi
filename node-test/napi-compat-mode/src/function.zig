const napi = @import("napi");

pub fn testCallFunction(callback: napi.Function(struct { []const u8, []const u8 }, napi.Undefined)) !void {
    _ = try callback.Call(.{ "hello", "world" });
}

pub fn testCallFunctionWithRefArguments(callback: napi.Function(struct { []const u8, []const u8 }, napi.Undefined)) !void {
    _ = try callback.Call(.{ "hello", "world" });
}

pub fn testCallFunctionError(callback: napi.Function(struct {}, napi.Undefined), error_callback: napi.Function([]const u8, napi.Undefined)) void {
    const env = napi.Env.from_raw(callback.env);
    _ = callback.Call(.{}) catch {
        if (env.isExceptionPending()) {
            _ = env.getAndClearLastException() catch {};
        }
        _ = error_callback.Call("Testing") catch return;
        return;
    };
}

fn argumentsLength(_: i32) []const u8 {
    return "arguments length: 1";
}

pub fn testCreateFunctionFromClosure(env: napi.Env) !napi.Function(i32, []const u8) {
    return try napi.Function(i32, []const u8).New(env, "argumentsLength", argumentsLength);
}
