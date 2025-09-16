const std = @import("std");
const napi = @import("napi");

pub fn hello(name: []u8) []u8 {
    const allocator = std.heap.page_allocator;

    const message = std.fmt.allocPrint(allocator, "Hello, {s}!", .{name}) catch @panic("OOM");
    defer allocator.free(message);

    return message;
}

pub const text = "Hello World";
