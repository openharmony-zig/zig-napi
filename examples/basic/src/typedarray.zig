const napi = @import("napi");

pub fn create_uint8_typedarray(env: napi.Env) !napi.Uint8Array {
    return napi.Uint8Array.copy(env, &[_]u8{ 1, 2, 3, 4 });
}

pub fn get_uint8_typedarray_length(array: napi.Uint8Array) usize {
    return array.length();
}

pub fn sum_float32_typedarray(array: napi.Float32Array) f32 {
    var sum: f32 = 0;
    for (array.asConstSlice()) |item| {
        sum += item;
    }
    return sum;
}
