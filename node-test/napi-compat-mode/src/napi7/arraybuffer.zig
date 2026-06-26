const napi = @import("napi");

pub fn detachArrayBuffer(buffer: napi.ArrayBuffer) !void {
    var mutable = buffer;
    try mutable.detach();
}

pub fn detachArrayBufferLength(buffer: napi.ArrayBuffer) !usize {
    var mutable = buffer;
    try mutable.detach();
    return mutable.length();
}

pub fn isDetachedArrayBuffer(buffer: napi.ArrayBuffer) !bool {
    return try buffer.isDetached();
}
