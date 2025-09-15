const napi = @import("napi");
const std = @import("std");
const ArrayList = std.ArrayList;

fn fibonacci(n: f64) f64 {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

fn fibonacci_execute(_: napi.Env, data: f64) void {
    const result = fibonacci(data);

    const allocator = std.heap.page_allocator;
    const message = std.fmt.allocPrint(allocator, "Fibonacci result: {d}", .{result}) catch @panic("OOM");
    defer allocator.free(message);
}

fn fibonacci_on_complete(_: napi.Env, _: napi.Status, data: f64) void {
    const allocator = std.heap.page_allocator;
    const message = std.fmt.allocPrint(allocator, "Fibonacci result: {d}", .{data}) catch @panic("OOM");
    defer allocator.free(message);
}

fn add(left: f64, right: f64) f64 {
    const result = left + right;
    return result;
}

fn hello(name: []u8) []u8 {
    const allocator = std.heap.page_allocator;

    const message = std.fmt.allocPrint(allocator, "Hello, {s}!", .{name}) catch @panic("OOM");
    defer allocator.free(message);

    return message;
}

fn fib(env: napi.Env, n: f64) void {
    const worker = napi.Worker(env, .{ .data = n, .Execute = fibonacci_execute, .OnComplete = fibonacci_on_complete });
    worker.Queue();
}

fn fib_async(env: napi.Env, n: f64) napi.Promise {
    const worker = napi.Worker(env, .{ .data = n, .Execute = fibonacci_execute, .OnComplete = fibonacci_on_complete });
    const promise = worker.AsyncQueue();
    return promise;
}

fn get_and_return_array(array: []f32) []f32 {
    const pg = std.heap.page_allocator;
    const message = std.fmt.allocPrint(pg, "Array length: {d}", .{array.len}) catch @panic("OOM");
    const message2 = std.fmt.allocPrint(pg, "Array content: {any}", .{array}) catch @panic("OOM");
    defer pg.free(message);
    defer pg.free(message2);

    return array;
}

const array_type = struct { f32, bool, []u8 };

fn get_named_array(array: array_type) array_type {
    const pg = std.heap.page_allocator;
    const message = std.fmt.allocPrint(pg, "content: {any}", .{array}) catch @panic("OOM");
    defer pg.free(message);

    return array;
}

fn get_arraylist(array: ArrayList(f32)) ArrayList(f32) {
    const pg = std.heap.page_allocator;
    const message = std.fmt.allocPrint(pg, "Array length: {any}", .{array}) catch @panic("OOM");
    defer pg.free(message);
    return array;
}

fn throw_error() !void {
    return napi.Error.fromReason("test");
}

fn init(env: napi.Env, exports: napi.Object) !napi.Object {
    try exports.Set("add", add);
    try exports.Set("hello", hello);

    const hello_string = napi.String.New(env, "Hello");
    try exports.Set("text", hello_string);
    try exports.Set("fib", fib);
    try exports.Set("fib_async", fib_async);
    try exports.Set("get_and_return_array", get_and_return_array);
    try exports.Set("get_named_array", get_named_array);
    try exports.Set("get_arraylist", get_arraylist);
    try exports.Set("throw_error", throw_error);

    return exports;
}

comptime {
    napi.NODE_API_MODULE("hello", init);
}
