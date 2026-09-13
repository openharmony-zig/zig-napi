//! Regression exports for the async/abort/TSFN/runtime audit findings
//! (F04 async ownership, F08, F09, F10, F11, F14).
//!
//! The addon uses a counting allocator so the JavaScript spec can assert that
//! captured inputs, results and queued payloads are released exactly once.
const std = @import("std");
const builtin = @import("builtin");
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

// Safe backing: this addon runs worker threads through emnapi, and the raw
// page allocator keeps one unsynchronized global for every thread of the
// WebAssembly instance.
var counter = CountingAllocator.init(napi.safePageAllocator());
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

var borrowed_result_slot: ?[]u8 = null;

fn allocatedResult(_: i32) ![]u8 {
    const buffer = try std.fmt.allocPrint(counter.allocator(), "allocated", .{});
    borrowed_result_slot = buffer;
    return buffer;
}

/// A freshly allocated (borrowed) result is not disposed by the runtime; the
/// runner keeps ownership unless it wraps the value in `Owned`.
pub fn asyncAllocatedBorrowed() napi.Async([]u8, .single) {
    return napi.Async([]u8, .single).from(@as(i32, 0), allocatedResult);
}

/// Release the buffer `asyncAllocatedBorrowed` handed back: the runtime treats
/// plain results as borrowed, so the owner cleans them up.
pub fn releaseBorrowedResult() void {
    if (borrowed_result_slot) |buffer| {
        counter.allocator().free(buffer);
        borrowed_result_slot = null;
    }
}

fn ownedResult(_: i32) !napi.Owned([]u8) {
    const buffer = try std.fmt.allocPrint(counter.allocator(), "owned", .{});
    return napi.Owned([]u8).init(buffer, counter.allocator());
}

/// An explicit `Owned` result transfers ownership to the runtime, which
/// disposes it after the value has been converted.
pub fn asyncOwnedResult() napi.Async(napi.Owned([]u8), .single) {
    return napi.Async(napi.Owned([]u8), .single).from(@as(i32, 0), ownedResult);
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

fn tinyEcho(input: u32) u32 {
    return input + 1;
}

/// Cheapest possible threaded task, for allocation-baseline measurements over
/// thousands of operations.
pub fn asyncTinyThreadValue(input: u32) napi.Async(u32, .thread) {
    return napi.Async(u32, .thread).from(input, tinyEcho);
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

const SliceEvent = struct {
    text: []const u8,
    index: u32,
};

fn sliceEventRun(ctx: napi.AsyncContext(SliceEvent), total: u32) !u32 {
    var buffer: [32]u8 = undefined;
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        const text = std.fmt.bufPrint(&buffer, "event-{d}", .{index}) catch continue;
        try ctx.emit(.{ .text = text, .index = index });
        // The producer reuses its temporary immediately: a shallow copy in the
        // queue would deliver this overwritten text (or worse, freed memory).
        @memset(&buffer, 'x');
    }
    return total;
}

/// Events carrying a slice must be deep-copied before they are queued.
pub fn asyncSliceEvents(total: u32) napi.AsyncWithEvents(u32, SliceEvent, .thread) {
    return napi.AsyncWithEvents(u32, SliceEvent, .thread).from(total, sliceEventRun);
}

/// Same runner, single runtime: the event is delivered synchronously and the
/// producer may reuse its buffer only after the listener returned.
pub fn asyncSliceEventsSingle(total: u32) napi.AsyncWithEvents(u32, SliceEvent, .single) {
    return napi.AsyncWithEvents(u32, SliceEvent, .single).from(total, sliceEventRun);
}

fn throwingSliceEventRun(ctx: napi.AsyncContext(SliceEvent), total: u32) !u32 {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "throwing-event", .{}) catch "throwing-event";
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        try ctx.emit(.{ .text = text, .index = index });
    }
    return total;
}

/// The listener throws: the completion must reject with that original
/// exception instead of leaving it pending on the environment.
pub fn asyncThrowingEvents(total: u32) napi.AsyncWithEvents(u32, SliceEvent, .thread) {
    return napi.AsyncWithEvents(u32, SliceEvent, .thread).from(total, throwingSliceEventRun);
}

fn takenReferenceRun(ctx: napi.AsyncContext(SliceEvent), total: u32) !napi.ObjectRef {
    _ = total;
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "pending-exception-event", .{}) catch "pending-exception-event";
    try ctx.emit(.{ .text = text, .index = 0 });
    // The result conversion fails while the listener's exception is still
    // pending: the promise must reject with that original exception.
    return .{ .raw_ref = null, .taken = true };
}

/// Completion conversion failure with a pending JavaScript exception.
pub fn asyncPendingExceptionCompletion() napi.AsyncWithEvents(napi.ObjectRef, SliceEvent, .thread) {
    return napi.AsyncWithEvents(napi.ObjectRef, SliceEvent, .thread).from(@as(u32, 1), takenReferenceRun);
}

/// Thread local message storage, the same shape as the conversion layer's
/// rotating error slots: each thread sees its own copy, so an error created on
/// the task thread is only readable there.
threadlocal var task_message: [64]u8 = [_]u8{'?'} ** 64;

fn failingRunner(_: i32) !i32 {
    const text = std.fmt.bufPrint(&task_message, "background failure {d}", .{@as(u32, 7)}) catch "background failure";
    return napi.Error.fromReason(text);
}

/// Error text produced on the task thread must survive the trip to JavaScript.
pub fn asyncBackgroundError() napi.Async(i32, .thread) {
    return napi.Async(i32, .thread).from(@as(i32, 0), failingRunner);
}

fn failingWorker(_: u32) !u32 {
    const text = std.fmt.bufPrint(&task_message, "worker failure {d}", .{@as(u32, 3)}) catch "worker failure";
    return napi.Error.fromReason(text);
}

/// Same for the worker bridge.
pub fn workerFailure(env: napi.Env, value: u32) !napi.Promise {
    const worker = napi.Worker(env, .{ .data = value, .Execute = failingWorker });
    return worker.AsyncQueue();
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

var status_after_reject: u32 = 0;

pub fn promiseStatusAfterReject() u32 {
    return status_after_reject;
}

/// The status recorded by the winning settlement must describe the outcome for
/// every copy of the wrapper (a reject must not read as resolved).
pub fn rejectedPromiseStatus(env: napi.Env) !napi.Promise {
    const promise = try napi.Promise.New(env);
    var writer = promise;
    try writer.Reject(napi.Error.withReason("status probe"));
    var alias = promise;
    status_after_reject = @intFromEnum(alias.status());
    return promise;
}

var status_after_resolve: u32 = 0;

pub fn promiseStatusAfterResolve() u32 {
    return status_after_resolve;
}

pub fn resolvedPromiseStatus(env: napi.Env) !napi.Promise {
    const promise = try napi.Promise.New(env);
    var writer = promise;
    try writer.Resolve(@as(i32, 3));
    var alias = promise;
    status_after_resolve = @intFromEnum(alias.status());
    return promise;
}

/// Native size of the settlement state a created promise keeps alive.
pub fn promiseSettlementStateSize() usize {
    return napi.Promise.settlementStateSize();
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

fn longRunner(input: u32) u32 {
    var spin: u32 = 0;
    while (spin < 30_000_000) : (spin += 1) {
        std.atomic.spinLoopHint();
    }
    return input + 1;
}

/// A threaded task that stays in flight long enough for its environment to be
/// torn down underneath it. Its controller thread is a worker of the runtime, so
/// this is the path that must not release the runtime from one of its own
/// workers.
pub fn asyncLongThreadValue(input: u32) napi.Async(u32, .thread) {
    return napi.Async(u32, .thread).from(input, longRunner);
}

/// Two tasks sharing one signal: both must observe the abort.
pub fn asyncMultiSignalTask(total: u32, signal: napi.AbortSignal) napi.Async(u32, .thread) {
    _ = signal;
    return napi.Async(u32, .thread).from(total, abortableRun);
}

// ---------------------------------------------------------------------------
// H01/H05/H08/H10: regression probes for the second audit round
// ---------------------------------------------------------------------------

const SliceTask = napi.AsyncWithEvents(u32, SliceEvent, .thread);
const SliceTaskSingle = napi.AsyncWithEvents(u32, SliceEvent, .single);

/// Largest number of events one operation keeps in flight (H10).
pub fn eventQueueLimit() u32 {
    return @intCast(SliceTask.async_max_inflight_events);
}

/// Highest number of in-flight events observed since the last reset (H10).
pub fn eventQueueHighWater() usize {
    return SliceTask.asyncEventQueueHighWaterMark();
}

/// True when progress events are delivered straight to the listener instead of
/// through the bounded queue, because the producer runs on the host's own
/// thread (threadless WASI build): nothing is ever in flight there, so the
/// high-water observation stays at zero.
pub fn inlineEventDelivery() bool {
    return SliceTask.async_events_inline;
}

pub fn resetEventQueueHighWater() void {
    SliceTask.asyncResetEventQueueHighWaterMark();
}

/// Emits `total` slice events with no listener at all; a listener that is
/// explicitly `undefined` takes the same path.
pub fn asyncSliceEventsNoListener(total: u32) SliceTask {
    return SliceTask.from(total, sliceEventRun);
}

fn throwingEventRun(ctx: napi.AsyncContext(SliceEvent), total: u32) !u32 {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "listener-failure", .{}) catch "listener-failure";
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        try ctx.emit(.{ .text = text, .index = index });
    }
    return total;
}

/// Single-runtime variant of `asyncThrowingEvents`: the event is delivered
/// synchronously on the JavaScript thread.
pub fn asyncThrowingEventsSingle(total: u32) SliceTaskSingle {
    return SliceTaskSingle.from(total, throwingEventRun);
}

/// Emits one event and then throws from the runner: the runner error and a
/// failing listener must not both be able to settle the promise.
fn runnerFailureAfterEvent(ctx: napi.AsyncContext(SliceEvent), total: u32) !u32 {
    _ = total;
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "runner-failure-event", .{}) catch "runner-failure-event";
    try ctx.emit(.{ .text = text, .index = 0 });
    return napi.Error.fromReason("runner failed after emitting");
}

pub fn asyncRunnerFailureAfterEvent() SliceTask {
    return SliceTask.from(@as(u32, 1), runnerFailureAfterEvent);
}

/// Abortable emitters whose listener is expected to be slow on the JavaScript
/// side: cancellation has to release a producer that is waiting for queue
/// capacity (H10).
fn abortableEventRun(ctx: napi.AsyncContext(SliceEvent), total: u32) !u32 {
    var buffer: [32]u8 = undefined;
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        if (index % 64 == 0) try ctx.checkCancelled();
        const text = std.fmt.bufPrint(&buffer, "slow-{d}", .{index}) catch continue;
        try ctx.emit(.{ .text = text, .index = index });
    }
    try ctx.checkCancelled();
    return total;
}

pub fn asyncAbortableSliceEvents(total: u32, signal: napi.AbortSignal) napi.AsyncWithEvents(u32, SliceEvent, .thread) {
    _ = signal;
    return napi.AsyncWithEvents(u32, SliceEvent, .thread).from(total, abortableEventRun);
}

/// Long-running threaded task whose promise stays pending until it finishes or
/// is cancelled; used to keep an environment busy while it is torn down (H01).
pub fn asyncAbandonedThreadValue(input: u32) napi.Async(u32, .thread) {
    return napi.Async(u32, .thread).from(input, longRunner);
}

/// Long-running abortable task: the environment is torn down while both the
/// task and its controller are still running (H01).
pub fn asyncAbandonedAbortable(total: u32, signal: napi.AbortSignal) napi.Async(u32, .thread) {
    _ = signal;
    return napi.Async(u32, .thread).from(total, abortableRun);
}

var completed_operations: std.atomic.Value(u32) = .init(0);

/// Counts threaded operations that ran to completion natively, so the spec can
/// tell "the producer really finished" from "the process survived".
pub fn completedThreadedOperations() u32 {
    return completed_operations.load(.monotonic);
}

fn countedLongRunner(input: u32) u32 {
    const value = longRunner(input);
    _ = completed_operations.fetchAdd(1, .monotonic);
    return value;
}

pub fn asyncCountedThreadValue(input: u32) napi.Async(u32, .thread) {
    return napi.Async(u32, .thread).from(input, countedLongRunner);
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

// ---------------------------------------------------------------------------
// Zig-side page allocator probes
//
// The addon's own allocations go through `napi.safePageAllocator()`, which on
// WebAssembly is a *different* `std.heap.BrkAllocator` instance than the C
// `malloc` facade in `src/sys/emnapi_alloc.zig`. These exports drive that
// instance directly so the JavaScript tests can check the class-limit guard and
// the failure semantics of `resize`/`remap` (the old block must stay valid).
//
// They are WebAssembly probes: the guard they exercise only exists there, and
// the pointers are returned as `u32`. On other targets they report 0.
// ---------------------------------------------------------------------------

const page_probe_pattern: u8 = 0xa5;

fn pageProbeAvailable() bool {
    return builtin.target.cpu.arch.isWasm();
}

/// Allocates `size` bytes from the Zig-side page allocator and writes a pattern
/// into its first and last byte. Returns 0 when the allocator refuses — which
/// is what a request past the class limit must do instead of trapping.
pub fn zigPageAlloc(size: usize) u32 {
    if (!pageProbeAvailable()) return 0;
    const memory = napi.safePageAllocator().alloc(u8, size) catch return 0;
    memory[0] = page_probe_pattern;
    memory[memory.len - 1] = page_probe_pattern;
    return @intCast(@intFromPtr(memory.ptr));
}

/// Whether the block still carries the pattern `zigPageAlloc` wrote.
pub fn zigPagePattern(ptr: u32, size: usize) bool {
    if (!pageProbeAvailable()) return false;
    const memory: [*]u8 = @ptrFromInt(ptr);
    return memory[0] == page_probe_pattern and memory[size - 1] == page_probe_pattern;
}

/// `Allocator.resize` to `new_size`. False means "not resizable in place", which
/// is also the answer for a size the allocator cannot serve.
pub fn zigPageResize(ptr: u32, old_size: usize, new_size: usize) bool {
    if (!pageProbeAvailable()) return false;
    const old: []u8 = @as([*]u8, @ptrFromInt(ptr))[0..old_size];
    return napi.safePageAllocator().resize(old, new_size);
}

/// `Allocator.remap` to `new_size`. Returns 0 when the allocator refuses, in
/// which case the caller still owns the old block untouched.
pub fn zigPageRemap(ptr: u32, old_size: usize, new_size: usize) u32 {
    if (!pageProbeAvailable()) return 0;
    const old: []u8 = @as([*]u8, @ptrFromInt(ptr))[0..old_size];
    const moved = napi.safePageAllocator().remap(old, new_size) orelse return 0;
    return @intCast(@intFromPtr(moved.ptr));
}

/// Releases a block that `zigPageAlloc` or `zigPageRemap` returned.
pub fn zigPageFree(ptr: u32, size: usize) void {
    if (!pageProbeAvailable()) return;
    const memory: []u8 = @as([*]u8, @ptrFromInt(ptr))[0..size];
    napi.safePageAllocator().free(memory);
}

comptime {
    napi.NODE_API_MODULE("async_audit", @This());
}
