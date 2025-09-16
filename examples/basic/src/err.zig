const napi = @import("napi");

pub fn throw_error() !void {
    return napi.Error.fromReason("test");
}
