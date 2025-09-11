const napi = @import("napi");
const std = @import("std");

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

fn add(callback_info: napi.CallbackInfo) f64 {
    const a = callback_info.Get(0).As(f64);
    const b = callback_info.Get(1).As(f64);
    const result = a + b;
    return result;
}

fn hello(callback_info: napi.CallbackInfo) []u8 {
    const value = callback_info.Get(0);
    const name = value.As([]u8);

    const allocator = std.heap.page_allocator;

    const message = std.fmt.allocPrint(allocator, "Hello, {s}!", .{name}) catch @panic("OOM");
    defer allocator.free(message);

    return message;
}

fn fib(callback_info: napi.CallbackInfo) void {
    const env = callback_info.Env();
    const n = callback_info.Get(0).As(f64);

    const worker = napi.Worker(env, .{ .data = n, .Execute = fibonacci_execute, .OnComplete = fibonacci_on_complete });
    worker.Queue();
}

fn fib_async(callback_info: napi.CallbackInfo) napi.Promise {
    const env = callback_info.Env();
    const n = callback_info.Get(0).As(f64);

    const worker = napi.Worker(env, .{ .data = n, .Execute = fibonacci_execute, .OnComplete = fibonacci_on_complete });
    const promise = worker.AsyncQueue();
    return promise;
}

fn get_and_return_array(callback_info: napi.CallbackInfo) []f32 {
    const array = callback_info.Get(0).As([]f32);

    const pg = std.heap.page_allocator;
    const message = std.fmt.allocPrint(pg, "Array length: {d}", .{array.len}) catch @panic("OOM");
    const message2 = std.fmt.allocPrint(pg, "Array content: {any}", .{array}) catch @panic("OOM");
    defer pg.free(message);
    defer pg.free(message2);

    return array;
}

const array_type = struct { f32, bool, []u8 };

fn get_named_array(callback_info: napi.CallbackInfo) array_type {
    const array: array_type = callback_info.Get(0).As(array_type);
    const pg = std.heap.page_allocator;
    const message = std.fmt.allocPrint(pg, "content: {any}", .{array}) catch @panic("OOM");
    defer pg.free(message);

    return array;
}

fn init(env: napi.Env, exports: napi.Object) napi.Object {
    exports.Set("add", add);
    exports.Set("hello", hello);

    const hello_string = napi.String.New(env, "Hello");
    exports.Set("text", hello_string);
    exports.Set("fib", fib);
    exports.Set("fib_async", fib_async);
    exports.Set("get_and_return_array", get_and_return_array);
    exports.Set("get_named_array", get_named_array);

    return exports;
}

comptime {
    napi.NODE_API_MODULE("hello", init);
}
