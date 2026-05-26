const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

pub fn detachArrayBuffer(buffer: napi.ArrayBuffer) !void {
    const status = c.napi_detach_arraybuffer(buffer.env, buffer.raw);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
}

pub fn isDetachedArrayBuffer(buffer: napi.ArrayBuffer) !bool {
    var result = false;
    const status = c.napi_is_detached_arraybuffer(buffer.env, buffer.raw, &result);
    if (status != c.napi_ok) return napi.Error.fromStatus(napi.Status.New(status));
    return result;
}
