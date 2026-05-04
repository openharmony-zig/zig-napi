const std = @import("std");
const napi = @import("napi");

pub fn hello(env: napi.Env, name: []u8) napi.String {
    const allocator = std.heap.page_allocator;

    const message = std.fmt.allocPrint(allocator, "Hello, {s}!", .{name}) catch @panic("OOM");
    defer allocator.free(message);

    return napi.String.New(env, message);
}

pub const text = "Hello World";
