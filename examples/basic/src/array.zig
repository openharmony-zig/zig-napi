const std = @import("std");
const napi = @import("napi");
const ArrayList = std.ArrayList;

pub fn get_and_return_array(array: []f32) []f32 {
    const pg = std.heap.page_allocator;
    const message = std.fmt.allocPrint(pg, "Array length: {d}", .{array.len}) catch @panic("OOM");
    const message2 = std.fmt.allocPrint(pg, "Array content: {any}", .{array}) catch @panic("OOM");
    defer pg.free(message);
    defer pg.free(message2);

    return array;
}

const array_type = struct { f32, bool, []u8 };

pub fn get_named_array(array: array_type) array_type {
    const pg = std.heap.page_allocator;
    const message = std.fmt.allocPrint(pg, "content: {any}", .{array}) catch @panic("OOM");
    defer pg.free(message);

    return array;
}

pub fn get_arraylist(array: ArrayList(f32)) ArrayList(f32) {
    const pg = std.heap.page_allocator;
    const message = std.fmt.allocPrint(pg, "Array length: {any}", .{array}) catch @panic("OOM");
    defer pg.free(message);
    return array;
}
