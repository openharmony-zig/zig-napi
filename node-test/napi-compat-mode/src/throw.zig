const napi = @import("napi");

pub fn testThrow() !void {
    return napi.Error.fromReason("native error");
}

pub fn testThrowWithReason(reason: []const u8) !void {
    return napi.Error.fromReason(reason);
}

pub fn testThrowWithPanic() !void {
    return napi.Error.fromReason("panic from native");
}
