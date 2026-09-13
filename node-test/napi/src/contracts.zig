const std = @import("std");
const napi = @import("napi");
var counter = @import("counting").CountingAllocator.init(napi.safePageAllocator());
var alternate_counter = @import("counting").CountingAllocator.init(napi.safePageAllocator());
var failing_allocator = std.testing.FailingAllocator.init(counter.allocator(), .{});
pub const napi_allocator = counter.allocator();
pub const readFile = @import("example_async").read_file_async;
pub const readSummary = @import("example_async").read_file_summary_async;
pub const readParallel = @import("example_async").parallel_read_files_async;
pub const memorySummary = @import("memory_async").memory_async_summary;
pub const memoryCustom = @import("memory_async").memory_async_custom_deinit;

pub fn activeBytes() isize {
    return counter.stats().active_bytes;
}
pub fn useAlternateAllocator(enabled: bool) void {
    if (enabled) napi.setOperationAllocator(alternate_counter.allocator()) else napi.resetOperationAllocator();
}
pub fn alternateBytes() isize {
    return alternate_counter.stats().active_bytes;
}
pub fn setAllocationFailure(index: usize) void {
    failing_allocator = std.testing.FailingAllocator.init(counter.allocator(), .{ .fail_index = index });
    napi.setOperationAllocator(failing_allocator.allocator());
}
/// An opaque foreign-addon payload need not point to a readable allocation.
pub fn foreignObject(env: napi.Env) !napi.Object {
    const object = try napi.Object.Create(env);
    const api = napi.napi_sys.napi_sys;
    const status = api.napi_wrap(env.raw, object.raw, @ptrFromInt(1), null, null, null);
    if (status != api.napi_ok) return error.WrapFailed;
    return object;
}
pub fn unwrapForeign(object: napi.Object) !void {
    _ = try object.unwrap(u64);
}
pub fn foreignExternal(env: napi.Env) !napi.NapiValue {
    const api = napi.napi_sys.napi_sys;
    var raw: api.napi_value = null;
    const status = api.napi_create_external(env.raw, @ptrFromInt(8), null, null, &raw);
    if (status != api.napi_ok) return error.ExternalFailed;
    return napi.NapiValue.from_raw(env.raw, raw);
}
pub fn acceptExternal(external: napi.External(u64)) u64 {
    return external.value().*;
}
pub fn genericNumber(value: napi.NapiValue) !i32 {
    return value.As(i32);
}
pub fn borrowedPromise(value: napi.PromiseValue) napi.PromiseValue {
    return value;
}
pub fn emptyBufferIsDetached(env: napi.Env) !bool {
    const buffer = try napi.ArrayBuffer.New(env, 0);
    return buffer.isDetached();
}
pub fn typedAfterCallback(view: napi.Uint8Array, callback: napi.Function(struct {}, void)) !u8 {
    try callback.Call(.{});
    const bytes = try view.tryAsSlice();
    return if (bytes.len == 0) 0 else bytes[0];
}
pub fn dataAfterCallback(view: napi.DataView, callback: napi.Function(struct {}, void)) !u8 {
    try callback.Call(.{});
    return view.getUint8(0);
}
pub fn nested(input: struct { text: []const u8, count: i32 }) void {
    _ = input;
}
pub fn nestedArray(input: []struct { text: []const u8, count: i32 }) void {
    _ = input;
}
pub fn enumInput(input: enum {
    A,
    B,
    pub const napi_string_enum = true;
}) void {
    _ = input;
}
pub fn fixed(input: [2]i32) i32 {
    return input[0] + input[1];
}
pub fn fixedString(input: [2]u8) bool {
    return std.mem.eql(u8, &input, "ok");
}
pub fn callVoid(callback: napi.Function(struct {}, void)) !void {
    try callback.Call(.{});
}
pub fn unsigned(input: u64) u64 {
    return input;
}
pub fn maxUnsigned() u64 {
    return std.math.maxInt(u64);
}
pub fn smallSigned(input: i8) i8 {
    return input;
}
pub fn string(input: []const u8) []const u8 {
    return input;
}

const State = struct {
    value: i32,
    pub fn make(value: i32) @This() {
        return .{ .value = value };
    }
    pub fn twice(value: i32) i32 {
        return value * 2;
    }
    pub fn read(self: @This()) i32 {
        return self.value;
    }
    pub fn allocatedText(_: *@This()) !napi.Owned([]u8) {
        const allocator = napi.globalAllocator();
        return .init(try allocator.dupe(u8, "class-owned"), allocator);
    }
};
pub const Class = napi.Class(State);
pub const NoInit = napi.ClassWithoutInit(State);
const TextState = struct { text: []const u8, count: i32 };
pub const TextClass = napi.Class(TextState);
const BorrowedState = struct {
    text: []u8,
    pub fn init(text: []u8) @This() {
        return .{ .text = text };
    }
    pub fn make(text: []u8) @This() {
        return .{ .text = text };
    }
    pub fn textLength(_: *@This(), text: []const u8) usize {
        return text.len;
    }
};
pub const BorrowedClass = napi.Class(BorrowedState);

pub fn allocateReturn() !napi.Owned([]u8) {
    const allocator = napi.globalAllocator();
    return napi.Owned([]u8).init(try allocator.dupe(u8, "returned-allocation"), allocator);
}
fn ignore(input: i32) i32 {
    return input;
}
pub fn asyncUnused(text: []const u8, input: i32) napi.Async(i32, .single) {
    _ = text;
    return napi.Async(i32, .single).from(input, ignore);
}
fn literal(_: i32) []const u8 {
    return "literal";
}
pub fn asyncLiteral() napi.Async([]const u8, .single) {
    return napi.Async([]const u8, .single).from(@as(i32, 0), literal);
}
fn returnError(_: i32) napi.Result(i32) {
    return .{ .err = napi.Error.withReason("expected rejection") };
}
pub fn asyncError() napi.Async(napi.Result(i32), .thread) {
    return napi.Async(napi.Result(i32), .thread).from(@as(i32, 0), returnError);
}

pub fn doubleResolve(env: napi.Env) !napi.Promise {
    var p = try napi.Promise.New(env);
    try p.Resolve(@as(i32, 1));
    try p.Resolve(@as(i32, 2));
    return p;
}
pub fn copiedResolve(env: napi.Env) !napi.Promise {
    var p = try napi.Promise.New(env);
    var copy = p;
    try p.Resolve(@as(i32, 1));
    try copy.Resolve(@as(i32, 2));
    return p;
}
pub fn resolveForeign(promise: napi.Promise) !void {
    var p = promise;
    try p.Resolve(@as(i32, 1));
}
pub fn bindSignal(signal: napi.AbortSignal) !void {
    const Impl = struct {
        fn abort(_: ?*anyopaque) void {}
    };
    const registration = try signal.bind(null, Impl.abort);
    registration.release();
}

// Integration fixtures: kept separate from the per-feature fixtures so these
// checks exercise the public APIs the way a downstream addon would.
var worker_completions: std.atomic.Value(u32) = .init(0);
fn workerOwnedResult(_: u32) !napi.Owned([]u8) {
    const allocator = counter.allocator();
    return .init(try allocator.dupe(u8, "worker-owned-result"), allocator);
}
fn workerOwnedCompleted(_: u32) void {
    _ = worker_completions.fetchAdd(1, .monotonic);
}
pub fn workerOwnedCompletions() u32 {
    return worker_completions.load(.monotonic);
}
pub fn workerOwnedQueue(env: napi.Env) void {
    napi.Worker(env, .{
        .data = @as(u32, 0),
        .Execute = workerOwnedResult,
        .OnComplete = workerOwnedCompleted,
    }).Queue();
}
fn delayedWorkerRead(input: []const u8) u32 {
    for (0..2_000_000) |_| std.atomic.spinLoopHint();
    return if (input.len == 0) 0 else input[0];
}
pub fn workerCapturedInput(env: napi.Env, input: []const u8) !napi.Promise {
    return napi.Worker(env, .{ .data = input, .Execute = delayedWorkerRead }).AsyncQueue();
}
const ErrorTsfn = napi.ThreadSafeFunction(struct { u32 }, void, true, 0);
const EmptyErrorTsfn = napi.ThreadSafeFunction(std.meta.Tuple(&.{}), void, true, 0);
var tsfn_error_message: [12]u8 = "original msg".*;
pub fn tsfnError(tsfn: *ErrorTsfn) !void {
    @memcpy(&tsfn_error_message, "original msg");
    try tsfn.Err(napi.Error.withReason(&tsfn_error_message), .NonBlocking);
    @memset(&tsfn_error_message, 'x');
    try tsfn.release(.Release);
}
pub fn tsfnEmptyError(tsfn: *EmptyErrorTsfn) !void {
    @memcpy(&tsfn_error_message, "original msg");
    try tsfn.Err(napi.Error.withReason(&tsfn_error_message), .NonBlocking);
    @memset(&tsfn_error_message, 'x');
    try tsfn.release(.Release);
}
pub fn referenceThenInvalid(env: napi.Env, reference: napi.ObjectRef, number: i32) !void {
    _ = number;
    var owned = reference;
    try owned.Delete(env);
}
pub fn referenceNested(env: napi.Env, input: struct { reference: napi.ObjectRef, number: i32 }) !void {
    var owned = input.reference;
    try owned.Delete(env);
}
var saved_reference: ?napi.ObjectRef = null;
var saved_env: napi.napi_sys.napi_sys.napi_env = null;
pub fn saveReference(env: napi.Env, reference: napi.ObjectRef) !void {
    if (saved_reference) |old| {
        var mutable = old;
        try mutable.Delete(env);
    }
    saved_reference = reference;
    saved_env = env.raw;
}
pub fn takeSavedReference(env: napi.Env) !napi.Object {
    var reference = saved_reference orelse return error.NoSavedReference;
    const value = try reference.GetValue(env);
    try reference.Delete(env);
    saved_reference = null;
    return value;
}

pub fn manualReferenceConversion(env: napi.Env, value: napi.NapiValue) !void {
    const converted = try value.As(struct { reference: napi.ObjectRef, number: i32 });
    var reference = converted.reference;
    try reference.Delete(env);
}

const TransientSummaryState = struct {
    pub const arg_ownership: napi.ArgOwnership = .transient;
    length: usize,
    pub fn init(text: []const u8) @This() {
        return .{ .length = text.len };
    }
    pub fn make(text: []const u8) @This() {
        return .{ .length = text.len };
    }
};
pub const TransientSummary = napi.Class(TransientSummaryState);
const RetainedSummaryState = struct {
    length: usize,
    pub fn init(text: []const u8) @This() {
        return .{ .length = text.len };
    }
    pub fn make(text: []const u8) @This() {
        return .{ .length = text.len };
    }
};
pub const RetainedSummary = napi.Class(RetainedSummaryState);

const ReferenceCallState = struct {
    number: i32,
    pub fn init(reference: napi.ObjectRef, number: i32, context: napi.Object) !@This() {
        var owned = reference;
        try owned.Delete(napi.Env.from_raw(context.env));
        return .{ .number = number };
    }
    pub fn make(reference: napi.ObjectRef, number: i32, context: napi.Object) !@This() {
        return init(reference, number, context);
    }
    pub fn makeSaved() !@This() {
        const env = napi.Env.from_raw(saved_env);
        var previous = saved_reference orelse return error.NoSavedReference;
        const replacement = try napi.ObjectRef.New(env, try previous.GetValue(env));
        try previous.Delete(env);
        saved_reference = replacement;
        return .{ .number = 1 };
    }
    pub fn consume(_: *@This(), reference: napi.ObjectRef, number: i32, context: napi.Object) !void {
        _ = try init(reference, number, context);
    }
};
pub const ReferenceCalls = napi.Class(ReferenceCallState);
pub const ReferenceFields = napi.Class(struct { reference: napi.ObjectRef, number: i32 });

/// Fail after the worker has captured its input, exactly when AsyncQueue
/// allocates the Promise capability. The worker must unwind its own owner.
pub fn workerPromiseAllocationFailure(env: napi.Env, input: []const u8) !napi.Promise {
    const worker = try napi.tryWorker(env, .{ .data = input, .Execute = delayedWorkerRead });
    setAllocationFailure(0);
    defer napi.resetOperationAllocator();
    return worker.AsyncQueue();
}

comptime {
    napi.NODE_API_MODULE("contracts", @This());
}
