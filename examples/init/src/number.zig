const napi = @import("napi");

pub fn test_i32(left: i32, right: i32) i32 {
    return left + right;
}

pub fn test_f32(left: f32, right: f32) f32 {
    return left + right;
}

pub fn test_u32(left: u32, right: u32) u32 {
    return left + right;
}
