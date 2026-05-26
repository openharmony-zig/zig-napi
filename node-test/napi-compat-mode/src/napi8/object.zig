const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

pub fn freezeObject(object: napi.Object) !c.napi_value {
    const status = c.napi_object_freeze(object.env, object.raw);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
    return object.raw;
}

pub fn sealObject(object: napi.Object) !c.napi_value {
    const status = c.napi_object_seal(object.env, object.raw);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
    return object.raw;
}
