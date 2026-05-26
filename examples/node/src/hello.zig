const napi = @import("napi");

pub fn add(left: i32, right: i32) i32 {
    return left + right;
}

pub fn hello() []const u8 {
    return "hello from node";
}

pub fn requestedNapiVersion() i32 {
    return @intFromEnum(napi.selectedNapiVersion());
}

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
