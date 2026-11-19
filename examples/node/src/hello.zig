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
    return @backingInt(napi.selectedNapiVersion());
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

pub const SymbolBox = napi.Class(struct {
    value: i32,
    pub const napi_config = .{
        .value = napi.ExportOptions{ .symbol = .{ .registry = "zig-napi.value" } },
        .getTag = napi.ExportOptions{ .symbol = .{ .well_known = .toStringTag }, .kind = .getter },
        .getValue = napi.ExportOptions{ .symbol = .{ .registry = "pair" }, .kind = .getter },
        .setValue = napi.ExportOptions{ .symbol = .{ .registry = "pair" }, .kind = .setter },
    };
    pub fn init(value: i32) @This() {
        return .{ .value = value };
    }
    pub fn getTag(_: *@This()) []const u8 {
        return "SymbolBox";
    }
    pub fn getValue(self: *@This()) i32 {
        return self.value;
    }
    pub fn setValue(self: *@This(), value: i32) void {
        self.value = value;
    }
});
