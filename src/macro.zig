const napi_mod = @import("./napi.zig");

/// 更简洁的宏风格函数
pub fn NAPI(comptime func: anytype) void {
    comptime {
        napi_mod.napi(func);
    }
}

pub fn add(left: f64, right: f64) f64 {
    return left + right;
}
