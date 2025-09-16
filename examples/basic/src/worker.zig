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

pub fn fib(env: napi.Env, n: f64) void {
    const worker = napi.Worker(env, .{ .data = n, .Execute = fibonacci_execute, .OnComplete = fibonacci_on_complete });
    worker.Queue();
}

pub fn fib_async(env: napi.Env, n: f64) napi.Promise {
    const worker = napi.Worker(env, .{ .data = n, .Execute = fibonacci_execute, .OnComplete = fibonacci_on_complete });
    const promise = worker.AsyncQueue();
    return promise;
}
