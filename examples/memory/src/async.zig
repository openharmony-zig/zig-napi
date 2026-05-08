const std = @import("std");
const napi = @import("napi");

var custom_async_input_deinits = std.atomic.Value(usize).init(0);
var custom_async_result_deinits = std.atomic.Value(usize).init(0);

const AsyncInput = struct {
    label: []u8,
    values: []f32,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.values);
    }
};

const AsyncSummary = struct {
    label: []u8,
    count: usize,
    total: f64,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

const CustomDeinitInput = struct {
    owned_label: []u8,
    borrowed_marker: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = custom_async_input_deinits.fetchAdd(1, .monotonic);
        allocator.free(self.owned_label);
    }
};

const CustomDeinitSummary = struct {
    borrowed_input_marker: []const u8,
    borrowed_result_marker: []const u8,
    owned_label: []u8,
    label_len: usize,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = custom_async_result_deinits.fetchAdd(1, .monotonic);
        allocator.free(self.owned_label);
    }
};

const CountProgress = struct {
    current: u32,
    total: u32,
};

const FnArgs = struct { i32, i32 };
const FnReturn = i32;

fn async_summary_execute(ctx: napi.AsyncContext(void), input: AsyncInput) !AsyncSummary {
    var total: f64 = 0;
    for (input.values) |value| {
        total += value;
    }
    const label = try ctx.allocator.dupe(u8, input.label);
    return .{ .label = label, .count = input.values.len, .total = total };
}

fn custom_deinit_execute(ctx: napi.AsyncContext(void), input: CustomDeinitInput) !CustomDeinitSummary {
    const owned_label = try std.fmt.allocPrint(ctx.allocator, "{s}:owned", .{input.owned_label});
    return .{
        .borrowed_input_marker = input.borrowed_marker,
        .borrowed_result_marker = "result-borrowed-marker",
        .owned_label = owned_label,
        .label_len = input.owned_label.len,
    };
}

fn async_void_execute(_: []u8) void {}

fn async_fail_execute(message: []u8) !void {
    return napi.Error.fromReason(message);
}

fn count_with_progress_execute(ctx: napi.AsyncContext(CountProgress), total: u32) !u32 {
    var current: u32 = 0;
    while (current <= total) : (current += 1) {
        try ctx.emit(.{ .current = current, .total = total });
    }
    return total;
}

fn abortable_count_execute(ctx: napi.AsyncContext(void), total: u32) !u32 {
    var current: u32 = 0;
    while (current < total) : (current += 1) {
        if (current % 256 == 0) {
            try ctx.checkCancelled();
        }
    }
    try ctx.checkCancelled();
    return total;
}

fn abortable_slow_count_execute(ctx: napi.AsyncContext(void), total: u32) !u32 {
    var current: u32 = 0;
    while (current < total) : (current += 1) {
        if (current % 16 == 0) {
            for (0..10000) |_| {
                std.atomic.spinLoopHint();
            }
            try ctx.checkCancelled();
        }
    }
    try ctx.checkCancelled();
    return total;
}

pub fn memory_async_summary(input: AsyncInput) napi.Async(AsyncSummary, .thread) {
    return napi.Async(AsyncSummary, .thread).from(input, async_summary_execute);
}

pub fn memory_async_summary_single(input: AsyncInput) napi.Async(AsyncSummary, .single) {
    return napi.Async(AsyncSummary, .single).from(input, async_summary_execute);
}

pub fn memory_async_custom_deinit(label: []u8) napi.Async(CustomDeinitSummary, .thread) {
    return napi.Async(CustomDeinitSummary, .thread).from(CustomDeinitInput{
        .owned_label = label,
        .borrowed_marker = "input-borrowed-marker",
    }, custom_deinit_execute);
}

pub fn memory_async_custom_deinit_single(label: []u8) napi.Async(CustomDeinitSummary, .single) {
    return napi.Async(CustomDeinitSummary, .single).from(CustomDeinitInput{
        .owned_label = label,
        .borrowed_marker = "input-borrowed-marker",
    }, custom_deinit_execute);
}

pub fn memory_async_custom_deinit_reset() void {
    custom_async_input_deinits.store(0, .monotonic);
    custom_async_result_deinits.store(0, .monotonic);
}

pub fn memory_async_custom_input_deinit_count() usize {
    return custom_async_input_deinits.load(.monotonic);
}

pub fn memory_async_custom_result_deinit_count() usize {
    return custom_async_result_deinits.load(.monotonic);
}

pub fn memory_async_void(label: []u8) napi.Async(void, .thread) {
    return napi.Async(void, .thread).from(label, async_void_execute);
}

pub fn memory_async_fail(message: []u8) napi.Async(void, .thread) {
    return napi.Async(void, .thread).from(message, async_fail_execute);
}

pub fn memory_async_progress(total: u32) napi.AsyncWithEvents(u32, CountProgress, .thread) {
    return napi.AsyncWithEvents(u32, CountProgress, .thread).from(total, count_with_progress_execute);
}

pub fn memory_event_mode_progress(total: u32) napi.AsyncWithEvents(u32, CountProgress, .event) {
    return napi.AsyncWithEvents(u32, CountProgress, .event).from(total, count_with_progress_execute);
}

pub fn memory_abortable_count(total: u32, signal: napi.AbortSignal) napi.Async(u32, .thread) {
    _ = signal;
    return napi.Async(u32, .thread).from(total, abortable_count_execute);
}

pub fn memory_abortable_slow_count(total: u32, signal: napi.AbortSignal) napi.Async(u32, .thread) {
    _ = signal;
    return napi.Async(u32, .thread).from(total, abortable_slow_count_execute);
}

fn worker_execute(value: u32) u32 {
    return value + 1;
}

pub fn memory_worker(env: napi.Env, value: u32) napi.Promise {
    const worker = napi.Worker(env, .{ .data = value, .Execute = worker_execute });
    return worker.AsyncQueue();
}

fn execute_thread_safe_function(tsfn: *napi.ThreadSafeFunction(FnArgs, FnReturn, true, 0)) void {
    defer tsfn.release(.Release) catch {};
    tsfn.Ok(.{ 1, 2 }, .NonBlocking) catch {};
}

fn execute_thread_safe_function_with_error(tsfn: *napi.ThreadSafeFunction(FnArgs, FnReturn, true, 0)) void {
    defer tsfn.release(.Release) catch {};
    tsfn.Err(napi.Error.withReason("memory tsfn error"), .NonBlocking) catch {};
}

pub fn memory_thread_safe_function(tsfn: *napi.ThreadSafeFunction(FnArgs, FnReturn, true, 0)) !void {
    try tsfn.acquire();
    const worker = try std.Thread.spawn(.{}, execute_thread_safe_function, .{tsfn});
    worker.detach();

    try tsfn.acquire();
    const worker_with_error = try std.Thread.spawn(.{}, execute_thread_safe_function_with_error, .{tsfn});
    worker_with_error.detach();

    try tsfn.release(.Release);
}
