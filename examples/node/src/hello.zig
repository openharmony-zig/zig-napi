const napi = @import("napi");

const CountProgress = struct {
    current: u32,
    total: u32,
};

pub fn add(left: i32, right: i32) i32 {
    return left + right;
}

pub fn hello() []const u8 {
    return "hello from node";
}

pub fn requestedNapiVersion() i32 {
    return @intFromEnum(napi.selectedNapiVersion());
}

fn fibonacci(n: u32) u32 {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

fn fibonacciExecute(n: u32) u32 {
    return fibonacci(n);
}

fn countWithProgressExecute(ctx: napi.AsyncContext(CountProgress), total: u32) !u32 {
    try ctx.emit(.{ .current = 0, .total = total });
    try ctx.emit(.{ .current = total, .total = total });
    return total;
}

pub fn fibonacciAsync(n: u32) napi.Async(u32, .thread) {
    return napi.Async(u32, .thread).from(n, fibonacciExecute);
}

pub fn countAsyncProgress(total: u32) napi.AsyncWithEvents(u32, CountProgress, .thread) {
    return napi.AsyncWithEvents(u32, CountProgress, .thread).from(total, countWithProgressExecute);
}

comptime {
    napi.NODE_API_MODULE("hello", @This());
}
