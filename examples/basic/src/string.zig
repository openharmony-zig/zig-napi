const std = @import("std");
const napi = @import("napi");

pub fn hello(env: napi.Env, name: []u8) napi.String {
    const allocator = std.heap.page_allocator;

    const message = std.fmt.allocPrint(allocator, "Hello, {s}!", .{name}) catch @panic("OOM");
    defer allocator.free(message);

    return napi.String.New(env, message);
}

pub fn raw_string_len(value: napi.String) usize {
    return value.utf8Len();
}

pub fn copied_string_len(value: napi.String) usize {
    const bytes = value.copyUtf8();
    defer napi.globalAllocator().free(bytes);
    return bytes.len;
}

pub const text = "Hello World";
pub const custom_text = napi.dts(text, "String");

pub fn custom_string(env: napi.Env, name: []u8) napi.Dts(napi.String, "String") {
    return napi.dts(hello(env, name), "String");
}
