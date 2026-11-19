const napi = @import("napi");

pub fn add(left: i32, right: i32) i32 {
    return left + right;
}

comptime {
    napi.NODE_API_MODULE("__ADDON_NAME__", @This());
}
