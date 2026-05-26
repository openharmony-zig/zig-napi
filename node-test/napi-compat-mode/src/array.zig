const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

pub fn testCreateArray(env: napi.Env) !napi.Array {
    return try napi.Array.Create(env);
}

pub fn testCreateArrayWithLength(env: napi.Env, len: u32) !c.napi_value {
    var raw: c.napi_value = undefined;
    const status = c.napi_create_array_with_length(env.raw, len, &raw);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
    return raw;
}

pub fn testSetElement(array: napi.Array, index: u32, value: napi.Object) !void {
    const status = c.napi_set_element(array.env, array.raw, index, value.raw);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
}

pub fn testHasElement(array: napi.Array, index: u32) !bool {
    var result = false;
    const status = c.napi_has_element(array.env, array.raw, index, &result);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
    return result;
}

pub fn testDeleteElement(array: napi.Array, index: u32) !bool {
    var result = false;
    const status = c.napi_delete_element(array.env, array.raw, index, &result);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
    return result;
}
