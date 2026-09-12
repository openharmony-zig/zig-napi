//! Regression exports for the async/abort/TSFN/runtime audit findings
//! (F04 async ownership, F08, F09, F10, F11, F14).
//!
//! The addon uses a counting allocator so the JavaScript spec can assert that
//! captured inputs, results and queued payloads are released exactly once.
const std = @import("std");
const napi = @import("napi");

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    alloc_calls: std.atomic.Value(usize) = .init(0),
    free_calls: std.atomic.Value(usize) = .init(0),
    active_bytes: std.atomic.Value(isize) = .init(0),

    const Self = @This();

    fn init(backing: std.mem.Allocator) Self {
        return .{ .backing = backing };
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.alloc_calls.fetchAdd(1, .monotonic);
        _ = self.active_bytes.fetchAdd(@intCast(len), .monotonic);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        _ = self.active_bytes.fetchAdd(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)), .monotonic);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        _ = self.active_bytes.fetchAdd(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)), .monotonic);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self.free_calls.fetchAdd(1, .monotonic);
        _ = self.active_bytes.fetchSub(@intCast(memory.len), .monotonic);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

var counter = CountingAllocator.init(std.heap.page_allocator);
pub const napi_allocator = counter.allocator();

pub fn activeBytes() isize {
    return counter.active_bytes.load(.monotonic);
}

pub fn allocationCount() usize {
    return counter.alloc_calls.load(.monotonic);
}

pub fn freeCount() usize {
    return counter.free_calls.load(.monotonic);
}

// ---------------------------------------------------------------------------
// F04: async ownership
// ---------------------------------------------------------------------------

fn literalResult(_: i32) []const u8 {
    return "literal";
}

/// A borrowed literal result must be handed to JavaScript and never freed.
pub fn asyncLiteral() napi.Async([]const u8, .single) {
    return napi.Async([]const u8, .single).from(@as(i32, 0), literalResult);
}

fn allocatedResult(_: i32) ![]u8 {
    return try std.fmt.allocPrint(counter.allocator(), "allocated", .{});
}

/// A freshly allocated (borrowed) result is not disposed by the runtime; the
/// runner keeps ownership unless it wraps the value in `Owned`.
pub fn asyncAllocatedBorrowed() napi.Async([]u8, .single) {
    return napi.Async([]u8, .single).from(@as(i32, 0), allocatedResult);
}

fn runResult(input: i32) napi.Result(i32) {
    return if (input == 0) .{ .err = napi.Error.withReason("expected rejection") } else .{ .ok = input };
}

/// `napi.Result` errors must reject the promise with that error.
pub fn asyncResult(input: i32) napi.Async(napi.Result(i32), .single) {
    return napi.Async(napi.Result(i32), .single).from(input, runResult);
}

fn takenReference(_: i32) napi.ObjectRef {
    return .{ .raw_ref = null, .taken = true };
}

/// Result conversion failure must reject instead of leaving the promise
/// pending (audit F09: the old code destroyed the operation and never settled).
pub fn asyncBadConversion() napi.Async(napi.ObjectRef, .single) {
    return napi.Async(napi.ObjectRef, .single).from(@as(i32, 0), takenReference);
}

fn slowEcho(input: u32) u32 {
    var spin: u32 = 0;
    while (spin < 2_000_000) : (spin += 1) {
        std.atomic.spinLoopHint();
    }
    return input + 1;
}

/// Captured input must be cloned: the task reads its own copy in the worker
/// thread while the caller's argument is released by the export wrapper.
pub fn asyncThreadValue(input: u32) napi.Async(u32, .thread) {
    return napi.Async(u32, .thread).from(input, slowEcho);
}

fn unusedInput(_: i32) i32 {
    return 1;
}

/// `text` is captured by the conversion layer but not by the task.
pub fn asyncUnusedInput(text: []const u8, input: i32) napi.Async(i32, .single) {
    _ = text;
    return napi.Async(i32, .single).from(input, unusedInput);
}

fn echoBytes(input: []const u8) []const u8 {
    return input;
}

/// The captured slice points at memory owned by the caller's argument scope;
/// the task must run against its own copy.
pub fn asyncEchoBytes(text: []const u8) napi.Async([]const u8, .thread) {
    return napi.Async([]const u8, .thread).from(text, echoBytes);
}

var descriptor_reused: u32 = 0;

/// Scheduling the same descriptor twice must fail cleanly instead of reusing
/// captured state (audit: "descriptors must not be reused after consumption").
pub fn asyncDoubleSchedule(env: napi.Env, input: i32) !napi.Promise {
    var descriptor = napi.Async(i32, .single).from(input, unusedInput);
    const promise = try descriptor.schedule(env);
    descriptor_reused = 0;
    if (descriptor.schedule(env)) |_| {} else |_| {
        descriptor_reused = 1;
    }
    return promise;
}

pub fn asyncDescriptorReused() u32 {
    return descriptor_reused;
}

// ---------------------------------------------------------------------------
// F11: promise settlement
// ---------------------------------------------------------------------------

var settle_successes: u32 = 0;

pub fn settleSuccessCount() u32 {
    return settle_successes;
}

/// Two copies of the same created promise: exactly one settlement may win.
pub fn sharedPromiseSettlement(env: napi.Env) !napi.Promise {
    settle_successes = 0;
    const promise = try napi.Promise.New(env);
    var first = promise;
    var second = promise;
    if (first.Resolve(@as(i32, 11))) |_| {
        settle_successes += 1;
    } else |_| {}
    if (second.Resolve(@as(i32, 22))) |_| {
        settle_successes += 1;
    } else |_| {}
    return promise;
}

/// A second settlement attempt must throw, never touch the released deferred.
pub fn doubleResolve(env: napi.Env) !napi.Promise {
    var promise = try napi.Promise.New(env);
    try promise.Resolve(@as(i32, 1));
    try promise.Resolve(@as(i32, 2));
    return promise;
}

/// Rejecting after a successful resolve must throw as well.
pub fn rejectAfterResolve(env: napi.Env) !napi.Promise {
    var promise = try napi.Promise.New(env);
    try promise.Resolve(@as(i32, 1));
    try promise.Reject(napi.Error.withReason("late"));
    return promise;
}

/// A promise received from JavaScript owns no deferred: settling it must be a
/// controlled error instead of a use-after-free.
pub fn resolveForeign(promise: napi.Promise) !void {
    var borrowed = promise;
    try borrowed.Resolve(@as(i32, 1));
}

pub fn borrowedPromiseSettlable(promise: napi.Promise) bool {
    return promise.canSettle();
}

// ---------------------------------------------------------------------------
// F09: worker cancellation
// ---------------------------------------------------------------------------

fn workerBody(value: u32) u32 {
    var spin: u32 = 0;
    while (spin < 200_000) : (spin += 1) {
        std.atomic.spinLoopHint();
    }
    return value + 1;
}

/// Cancelling a worker must settle its promise (resolve or AbortError), never
/// leave it pending.
pub fn workerCancelled(env: napi.Env) !napi.Promise {
    const worker = napi.Worker(env, .{ .data = @as(u32, 1), .Execute = workerBody });
    const promise = try worker.AsyncQueue();
    worker.Cancel();
    return promise;
}

pub fn workerValue(env: napi.Env, value: u32) !napi.Promise {
    const worker = napi.Worker(env, .{ .data = value, .Execute = workerBody });
    return worker.AsyncQueue();
}

// ---------------------------------------------------------------------------
// F08: abort signal
// ---------------------------------------------------------------------------

var abort_callbacks: std.atomic.Value(u32) = .init(0);
/// `napi.AbortRegistration` is not re-exported by the root module yet, so the
/// type is recovered from `bind`'s signature instead of touching the public
/// module surface.
const AbortRegistrationPtr = @typeInfo(@typeInfo(@TypeOf(napi.AbortSignal.bind)).@"fn".return_type.?).error_union.payload;
var held_registration: ?AbortRegistrationPtr = null;
var held_second_registration: ?AbortRegistrationPtr = null;

fn onAbortCallback(_: ?*anyopaque) void {
    _ = abort_callbacks.fetchAdd(1, .monotonic);
}

pub fn abortCallbackCount() u32 {
    return abort_callbacks.load(.monotonic);
}

pub fn resetAbortCallbackCount() void {
    abort_callbacks.store(0, .monotonic);
}

/// Bind a listener and release it immediately (rollback / cleanup path).
pub fn bindAndRelease(signal: napi.AbortSignal) !void {
    const registration = try signal.bind(null, onAbortCallback);
    registration.release();
}

/// Bind and keep the registration so JavaScript can abort afterwards.
pub fn bindAndHold(signal: napi.AbortSignal) !void {
    held_registration = try signal.bind(null, onAbortCallback);
}

pub fn bindSecondAndHold(signal: napi.AbortSignal) !void {
    held_second_registration = try signal.bind(null, onAbortCallback);
}

pub fn releaseHeldSignal() void {
    if (held_registration) |registration| {
        registration.release();
        held_registration = null;
    }
}

pub fn releaseSecondHeldSignal() void {
    if (held_second_registration) |registration| {
        registration.release();
        held_second_registration = null;
    }
}

fn abortableRun(ctx: napi.AsyncContext(void), total: u32) !u32 {
    var current: u32 = 0;
    while (current < total) : (current += 1) {
        if (current % 512 == 0) try ctx.checkCancelled();
    }
    try ctx.checkCancelled();
    return total;
}

/// AbortSignal passed to an async task: the task must observe the abort and
/// reject with AbortError.
pub fn asyncAbortable(total: u32, signal: napi.AbortSignal) napi.Async(u32, .thread) {
    _ = signal;
    return napi.Async(u32, .thread).from(total, abortableRun);
}

/// Two tasks sharing one signal: both must observe the abort.
pub fn asyncMultiSignalTask(total: u32, signal: napi.AbortSignal) napi.Async(u32, .thread) {
    _ = signal;
    return napi.Async(u32, .thread).from(total, abortableRun);
}

// ---------------------------------------------------------------------------
// F10: thread-safe function queue cleanup
// ---------------------------------------------------------------------------

const TsfnArgs = struct { u32 };
const TsfnReturn = u32;
const AuditTsfn = napi.ThreadSafeFunction(TsfnArgs, TsfnReturn, true, 0);

/// Queue calls and then relinquish the creator reference: the dispatcher must
/// drain the queue and release the context in its finalizer.
pub fn queueThreadSafeFunction(tsfn: *AuditTsfn, value: u32, count: u32) !void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try tsfn.Ok(.{value + index}, .NonBlocking);
    }
    try tsfn.release(.Release);
}

/// Queue calls and never release: used to verify that environment teardown
/// drains the queue with a null environment instead of leaking or touching JS.
pub fn queueThreadSafeFunctionAbandon(tsfn: *AuditTsfn, count: u32) !void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try tsfn.Ok(.{index}, .NonBlocking);
    }
}

// ---------------------------------------------------------------------------
// F14: shared runtime environment ownership
// ---------------------------------------------------------------------------

pub fn runtimePing() void {}

comptime {
    napi.NODE_API_MODULE("async_audit", @This());
}
