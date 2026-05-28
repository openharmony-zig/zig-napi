const napi = @import("napi");

pub fn detachArrayBuffer(buffer: napi.ArrayBuffer) !void {
    try buffer.detach();
}

pub fn isDetachedArrayBuffer(buffer: napi.ArrayBuffer) !bool {
    return try buffer.isDetached();
}
