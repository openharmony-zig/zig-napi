const napi = @import("napi");
const std = @import("std");

fn fibonacci(n: f64) f64 {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

pub const FibProgress = struct {
    current: f64,
    total: f64,
};

pub const CountProgress = struct {
    current: u32,
    total: u32,
};

pub const AsyncMathInput = struct {
    left: f64,
    right: f64,
    scale: f64,
};

pub const AsyncMathResult = struct {
    sum: f64,
    product: f64,
    scaled_sum: f64,
};

pub const FileReadSummary = struct {
    path: []u8,
    bytes: usize,
    text: []u8,
};

pub const ParallelReadInput = struct {
    first_path: []u8,
    second_path: []u8,
    preview_bytes: usize,
};

pub const ParallelReadSummary = struct {
    first_bytes: usize,
    second_bytes: usize,
    total_bytes: usize,
    preview: []u8,
};

fn fibonacci_execute(data: f64) f64 {
    return fibonacci(data);
}

fn fibonacci_execute_with_progress(ctx: napi.AsyncContext(FibProgress), data: f64) !f64 {
    try ctx.emit(.{ .current = 0, .total = data });
    const result = fibonacci(data);
    try ctx.emit(.{ .current = data, .total = data });
    return result;
}

fn read_file_execute(ctx: napi.AsyncContext(void), path: []u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(1024 * 1024));
}

fn read_file_summary_execute(ctx: napi.AsyncContext(void), path: []u8) !FileReadSummary {
    const text = try read_file_execute(ctx, path);
    return .{
        .path = path,
        .bytes = text.len,
        .text = text,
    };
}

fn async_math_execute(input: AsyncMathInput) AsyncMathResult {
    const sum = input.left + input.right;
    return .{
        .sum = sum,
        .product = input.left * input.right,
        .scaled_sum = sum * input.scale,
    };
}

fn async_void_execute(_: void) void {}

fn async_fail_execute(message: []u8) !void {
    return napi.Error.fromReason(message);
}

const ReadSlot = struct {
    text: []u8 = &.{},
    err: ?anyerror = null,
};

fn read_file_slot(ctx: napi.AsyncContext(void), path: []u8, slot: *ReadSlot) std.Io.Cancelable!void {
    slot.text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(1024 * 1024)) catch |err| {
        slot.err = err;
        return;
    };
}

fn append_preview(output: []u8, offset: *usize, text: []const u8, limit: usize) void {
    const len = @min(text.len, limit);
    @memcpy(output[offset.* .. offset.* + len], text[0..len]);
    offset.* += len;
}

fn parallel_read_execute(ctx: napi.AsyncContext(void), input: ParallelReadInput) !ParallelReadSummary {
    var first: ReadSlot = .{};
    var second: ReadSlot = .{};

    try ctx.group.concurrent(ctx.io, read_file_slot, .{ ctx, input.first_path, &first });
    try ctx.group.concurrent(ctx.io, read_file_slot, .{ ctx, input.second_path, &second });
    try ctx.awaitGroup();

    if (first.err) |err| return err;
    if (second.err) |err| return err;

    const first_preview_len = @min(first.text.len, input.preview_bytes);
    const second_preview_len = @min(second.text.len, input.preview_bytes);
    const separator = "\n---\n";
    const preview_len = first_preview_len + separator.len + second_preview_len;
    const preview = try ctx.allocator.alloc(u8, preview_len);
    var offset: usize = 0;
    append_preview(preview, &offset, first.text, input.preview_bytes);
    @memcpy(preview[offset .. offset + separator.len], separator);
    offset += separator.len;
    append_preview(preview, &offset, second.text, input.preview_bytes);

    return .{
        .first_bytes = first.text.len,
        .second_bytes = second.text.len,
        .total_bytes = first.text.len + second.text.len,
        .preview = preview,
    };
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
        if (current % 1024 == 0) {
            try ctx.checkCancelled();
        }
    }
    try ctx.checkCancelled();
    return total;
}

pub fn fib_async(n: f64) napi.Async(f64, .thread) {
    return napi.Async(f64, .thread).from(n, fibonacci_execute);
}

pub fn fib_async_progress(n: f64) napi.AsyncWithEvents(f64, FibProgress, .single) {
    return napi.AsyncWithEvents(f64, FibProgress, .single).from(n, fibonacci_execute_with_progress);
}

pub fn read_file_async(path: []u8) napi.Async([]u8, .thread) {
    return napi.Async([]u8, .thread).from(path, read_file_execute);
}

pub fn read_file_summary_async(path: []u8) napi.Async(FileReadSummary, .thread) {
    return napi.Async(FileReadSummary, .thread).from(path, read_file_summary_execute);
}

pub fn parallel_read_files_async(input: ParallelReadInput) napi.Async(ParallelReadSummary, .thread) {
    return napi.Async(ParallelReadSummary, .thread).from(input, parallel_read_execute);
}

pub fn async_math_single(input: AsyncMathInput) napi.Async(AsyncMathResult, .single) {
    return napi.Async(AsyncMathResult, .single).from(input, async_math_execute);
}

pub fn async_void_thread() napi.Async(void, .thread) {
    return napi.Async(void, .thread).from({}, async_void_execute);
}

pub fn async_fail_thread(message: []u8) napi.Async(void, .thread) {
    return napi.Async(void, .thread).from(message, async_fail_execute);
}

pub fn count_async_progress_thread(total: u32) napi.AsyncWithEvents(u32, CountProgress, .thread) {
    return napi.AsyncWithEvents(u32, CountProgress, .thread).from(total, count_with_progress_execute);
}

pub fn event_mode_progress_async(total: u32) napi.AsyncWithEvents(u32, CountProgress, .event) {
    return napi.AsyncWithEvents(u32, CountProgress, .event).from(total, count_with_progress_execute);
}

pub fn abortable_count_async(total: u32, signal: napi.AbortSignal) napi.Async(u32, .thread) {
    _ = signal;
    return napi.Async(u32, .thread).from(total, abortable_count_execute);
}
