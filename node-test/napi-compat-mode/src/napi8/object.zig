const napi = @import("napi");

pub fn freezeObject(object: napi.Object) !napi.Object {
    return try object.freeze();
}

pub fn sealObject(object: napi.Object) !napi.Object {
    return try object.seal();
}
