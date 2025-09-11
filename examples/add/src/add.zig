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

    std.debug.print("{s}\n", .{message});
}

fn fibonacci_on_complete(_: napi.Env, _: napi.Status, data: f64) void {
    const allocator = std.heap.page_allocator;
    const message = std.fmt.allocPrint(allocator, "Fibonacci result: {d}", .{data}) catch @panic("OOM");
    defer allocator.free(message);

    std.debug.print("{s}\n", .{message});
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

fn init(env: napi.Env, exports: napi.Object) napi.Object {
    exports.Set("add", add);
    exports.Set("hello", hello);

    const hello_string = napi.String.New(env, "Hello");
    exports.Set("text", hello_string);
    exports.Set("fib", fib);
    exports.Set("fib_async", fib_async);

    return exports;
}

comptime {
    napi.NODE_API_MODULE("hello", init);
}
