const napi = @import("napi");

pub fn testCreateArray(env: napi.Env) !napi.Array {
    return try napi.Array.Create(env);
}

pub fn testCreateArrayWithLength(env: napi.Env, len: u32) !napi.Array {
    return try napi.Array.CreateWithLength(env, len);
}

pub fn testSetElement(array: napi.Array, index: u32, value: napi.Object) !void {
    var mutable_array = array;
    try mutable_array.Set(index, value);
}

pub fn testHasElement(array: napi.Array, index: u32) !bool {
    return try array.HasElement(index);
}

pub fn testDeleteElement(array: napi.Array, index: u32) !bool {
    return try array.DeleteElement(index);
}
