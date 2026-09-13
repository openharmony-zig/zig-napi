//! Regression harness for the class wrapper and the binary wrappers.
//!
//! Audit items covered here:
//!   F05 per environment class constructor references
//!   F06 static methods, factories and ClassWithoutInit construction
//!   F07 constructor rollback and setter replacement ownership
//!   F12 detached / invalidated backing stores for TypedArray, DataView,
//!       ArrayBuffer and Buffer.
//!
//! The addon is built with a counting allocator so that the leak assertions in
//! `node-test/napi/__tests__/classes-audit.spec.js` measure real allocations.
const std = @import("std");
const napi = @import("napi");
const counting = @import("counting");

// The backing is the *safe* page allocator: emnapi runs worker threads next to
// the JavaScript thread in one WebAssembly instance, and the raw page allocator
// keeps its free lists in one unsynchronized global that both of them share.
var counter = counting.CountingAllocator.init(napi.safePageAllocator());

pub const napi_allocator = counter.allocator();

/// Native allocations that are still alive. The tests compare deltas around a
/// loop so that unrelated allocations do not affect the assertion.
pub fn activeBytes() isize {
    return counter.stats().active_bytes;
}

pub fn activeAllocations() isize {
    return counter.stats().active_allocations;
}

// ---------------------------------------------------------------------------
// F07: default field construction, setter replacement and rollback
// ---------------------------------------------------------------------------

const TextState = struct {
    text: []const u8,
    count: i32,
};

pub const TextClass = napi.Class(TextState);

// ---------------------------------------------------------------------------
// F06: init, static methods, value receivers, factories and static values
// ---------------------------------------------------------------------------

var widget_init_calls = std.atomic.Value(usize).init(0);

pub fn widgetInitCalls() usize {
    return widget_init_calls.load(.monotonic);
}

pub fn resetWidgetInitCalls() void {
    widget_init_calls.store(0, .monotonic);
}

const Widget = struct {
    value: i32,

    pub const KIND: []const u8 = "widget";

    /// Running `init` twice (for example from a factory that reuses the
    /// constructor path) is observable through this counter and through the
    /// value offset.
    pub fn init(value: i32) Widget {
        _ = widget_init_calls.fetchAdd(1, .monotonic);
        return .{ .value = value };
    }

    pub fn make(value: i32) Widget {
        return .{ .value = value };
    }

    /// Static method: its `this` is the constructor, it must not unwrap it.
    pub fn twice(value: i32) i32 {
        return value * 2;
    }

    pub fn bump(self: *Widget, delta: i32) i32 {
        self.value += delta;
        return self.value;
    }

    /// Value receiver; the documentation promises this form works.
    pub fn read(self: Widget) i32 {
        return self.value;
    }
};

pub const WidgetClass = napi.Class(Widget);

const Labeled = struct {
    label: []const u8,
    value: i32,

    pub fn init(label: []const u8, value: i32) Labeled {
        return .{ .label = label, .value = value };
    }

    pub fn make(label: []const u8, value: i32) Labeled {
        return .{ .label = label, .value = value };
    }

    pub fn describe(self: *Labeled) []const u8 {
        return self.label;
    }
};

pub const LabeledClass = napi.Class(Labeled);

const NoInitState = struct {
    value: i32,

    pub fn make(value: i32) NoInitState {
        return .{ .value = value };
    }

    pub fn add(self: *NoInitState, delta: i32) i32 {
        self.value += delta;
        return self.value;
    }
};

pub const NoInitClass = napi.ClassWithoutInit(NoInitState);

// ---------------------------------------------------------------------------
// Finalization and the init/factory input contract
// ---------------------------------------------------------------------------

var finalized_count = std.atomic.Value(usize).init(0);

pub fn finalizedCount() usize {
    return finalized_count.load(.monotonic);
}

pub fn resetFinalizedCount() void {
    finalized_count.store(0, .monotonic);
}

/// Keeps a borrowed init input in a field and mutates the field in `deinit`.
///
/// The converted input is owned by the wrapper, not by the type, so `deinit`
/// must not free it - and the wrapper must not read the value after `deinit`
/// has run (which clearing the field here detects).
const Tracked = struct {
    payload: []const u8,

    pub fn init(payload: []const u8) Tracked {
        return .{ .payload = payload };
    }

    pub fn make(payload: []const u8) Tracked {
        return .{ .payload = payload };
    }

    pub fn size(self: *Tracked) usize {
        return self.payload.len;
    }

    pub fn deinit(self: *Tracked) void {
        self.payload = &[_]u8{};
        _ = finalized_count.fetchAdd(1, .monotonic);
    }
};

pub const TrackedClass = napi.Class(Tracked);

/// Allocates its own payload in the factory and releases it in `deinit`: the
/// explicit form of resource ownership. A leaked instance shows up as a
/// positive `activeBytes` delta after GC.
const Owned = struct {
    payload: []const u8,

    pub fn make(text: []const u8) !Owned {
        const allocator = napi.globalAllocator();
        const owned = try allocator.dupe(u8, text);
        return .{ .payload = owned };
    }

    pub fn size(self: *Owned) usize {
        return self.payload.len;
    }

    pub fn deinit(self: *Owned) void {
        const allocator = napi.globalAllocator();
        if (self.payload.len > 0) {
            allocator.free(@constCast(self.payload));
        }
        _ = finalized_count.fetchAdd(1, .monotonic);
    }
};

pub const OwnedClass = napi.ClassWithoutInit(Owned);

/// The init input is a struct with a nested allocation; the wrapper has to
/// release the nested slice with the allocator that produced it.
const NestedPayload = struct {
    text: []const u8,
    count: i32,
};

const Nested = struct {
    payload: NestedPayload,

    pub fn init(payload: NestedPayload) Nested {
        return .{ .payload = payload };
    }

    pub fn describe(self: *Nested) []const u8 {
        return self.payload.text;
    }

    pub fn total(self: *Nested) i32 {
        return self.payload.count;
    }
};

pub const NestedClass = napi.Class(Nested);

/// Stores a sub-slice of a converted input. The wrapper owns the whole input
/// and releases it exactly once, so a sub-slice alias must not be freed twice.
const Aliased = struct {
    window: []const u8,

    pub fn init(payload: []const u8) Aliased {
        return .{ .window = if (payload.len > 1) payload[1..] else payload };
    }

    pub fn view(self: *Aliased) []const u8 {
        return self.window;
    }
};

pub const AliasedClass = napi.Class(Aliased);

/// The second argument is never stored: it is still owned by the wrapper and
/// must be released at finalization.
const UnusedArg = struct {
    value: i32,

    pub fn init(value: i32, unused: []const u8) UnusedArg {
        _ = unused;
        return .{ .value = value };
    }

    pub fn read(self: *UnusedArg) i32 {
        return self.value;
    }
};

pub const UnusedArgClass = napi.Class(UnusedArg);

/// The type owns its fields through `deinit`, so an implicit JavaScript
/// replacement of a field that carries native memory is refused instead of
/// orphaning the previous value. Plain data stays assignable.
const DeinitOwned = struct {
    name: []const u8,
    count: i32,

    pub fn init(name: []const u8, count: i32) DeinitOwned {
        return .{ .name = name, .count = count };
    }

    pub fn describe(self: *DeinitOwned) []const u8 {
        return self.name;
    }

    pub fn deinit(self: *DeinitOwned) void {
        self.name = &[_]u8{};
    }
};

pub const DeinitOwnedClass = napi.Class(DeinitOwned);

/// Field construction installs every field through the wrapper, so replacing a
/// field of a type with `deinit` is allowed - the wrapper owns the value it
/// installed.
const FieldBuilt = struct {
    label: []const u8,

    pub fn deinit(self: *FieldBuilt) void {
        self.label = &[_]u8{};
    }
};

pub const FieldBuiltClass = napi.Class(FieldBuilt);

/// A field type that owns itself through `deinit`.
const Payload = struct {
    text: []u8,

    pub fn deinit(self: *Payload) void {
        if (self.text.len > 0) napi.globalAllocator().free(self.text);
        self.text = &[_]u8{};
    }
};

/// Explicit owner contract: the field type declares `deinit`, so replacing the
/// field releases the previous value through that `deinit` even when the
/// wrapper did not install it.
const ExplicitOwner = struct {
    payload: Payload,

    pub fn init() ExplicitOwner {
        return .{ .payload = .{ .text = &[_]u8{} } };
    }

    pub fn size(self: *ExplicitOwner) usize {
        return self.payload.text.len;
    }

    pub fn deinit(self: *ExplicitOwner) void {
        self.payload.deinit();
    }
};

pub const ExplicitOwnerClass = napi.Class(ExplicitOwner);

// ---------------------------------------------------------------------------
// Provenance: a foreign `napi_wrap` payload must never be dereferenced
// ---------------------------------------------------------------------------

/// Wraps an opaque foreign payload (pointer 1, which is not a readable
/// allocation) into an object of this addon.
pub fn foreignObject(env: napi.Env) !napi.Object {
    const object = try napi.Object.Create(env);
    const api = napi.napi_sys.napi_sys;
    if (api.napi_wrap(env.raw, object.raw, @ptrFromInt(1), null, null, null) != api.napi_ok) {
        return error.WrapFailed;
    }
    return object;
}

/// Reads a wrapper payload and returns its first byte, proving that the native
/// body only runs when the wrapper is valid.
pub fn firstByte(view: napi.Uint8Array) !u32 {
    _ = typed_array_calls.fetchAdd(1, .monotonic);
    const slice = try view.tryAsSlice();
    return if (slice.len == 0) 0 else slice[0];
}

var typed_array_calls = std.atomic.Value(usize).init(0);

pub fn typedArrayCalls() usize {
    return typed_array_calls.load(.monotonic);
}

pub fn resetTypedArrayCalls() void {
    typed_array_calls.store(0, .monotonic);
}

// ---------------------------------------------------------------------------
// F12: binary wrappers must re-validate after JavaScript reentry
// ---------------------------------------------------------------------------

pub fn firstByteAfterCallback(view: napi.Uint8Array, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    const slice = try view.tryAsSlice();
    return if (slice.len == 0) 0 else slice[0];
}

/// Reads through the unchecked accessor: after a detach this must not return
/// the stale first byte any more.
pub fn firstByteUncheckedAfterCallback(view: napi.Uint8Array, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    const slice = view.asSlice();
    return if (slice.len == 0) 0 else slice[0];
}

pub fn dataViewByteAfterCallback(view: napi.DataView, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    return try view.getUint8(0);
}

pub fn bufferFirstByteAfterCallback(buffer: napi.Buffer, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    const slice = try buffer.tryAsSlice();
    return if (slice.len == 0) 0 else slice[0];
}

pub fn arrayBufferFirstByteAfterCallback(buffer: napi.ArrayBuffer, callback: napi.Function(struct {}, i32)) !u32 {
    _ = try callback.Call(.{});
    const slice = try buffer.tryAsSlice();
    return if (slice.len == 0) 0 else slice[0];
}

pub fn typedArraySum(input: napi.Uint32Array) !u32 {
    var sum: u32 = 0;
    for (try input.tryAsSlice()) |value| {
        sum +%= value;
    }
    return sum;
}

/// Creating a view whose byte range overflows `usize` must fail instead of
/// wrapping into a valid looking view.
pub fn typedArrayOverflow(env: napi.Env, buffer: napi.ArrayBuffer) !void {
    _ = try napi.Uint8Array.fromArrayBuffer(env, buffer, std.math.maxInt(usize), 0);
}

pub fn dataViewOverflow(env: napi.Env, buffer: napi.ArrayBuffer) !void {
    _ = try napi.DataView.fromArrayBuffer(env, buffer, std.math.maxInt(usize), 16);
}

// ---------------------------------------------------------------------------
// H02: worker data - captured by default, borrowed explicitly
// ---------------------------------------------------------------------------

fn fnvChecksum(input: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (input) |byte| {
        hash = (hash ^ byte) *% 16777619;
    }
    return hash;
}

/// The converting call scope releases its copy of the argument when the
/// exported function returns. `Worker` captures the payload by default, so the
/// runner reads a private copy instead of a freed 64 KiB argument.
pub fn workerCapturedChecksum(env: napi.Env, input: []const u8) !napi.Promise {
    return napi.Worker(env, .{ .data = input, .Execute = fnvChecksum }).AsyncQueue();
}

/// Same through the fallible creation entry point.
pub fn workerTryCapturedChecksum(env: napi.Env, input: []const u8) !napi.Promise {
    const worker = try napi.tryWorker(env, .{ .data = input, .Execute = fnvChecksum });
    return worker.AsyncQueue();
}

const CapturedPayload = struct {
    text: []const u8,
    marker: u32,
};

fn payloadChecksum(payload: CapturedPayload) u32 {
    return fnvChecksum(payload.text) ^ payload.marker;
}

/// Struct payload with a nested slice: the capture is recursive.
pub fn workerCapturedStruct(env: napi.Env, text: []const u8) !napi.Promise {
    return napi.Worker(env, .{
        .data = CapturedPayload{ .text = text, .marker = 7 },
        .Execute = payloadChecksum,
    }).AsyncQueue();
}

fn slowLength(input: []const u8) u32 {
    var spin: u32 = 0;
    while (spin < 100_000) : (spin += 1) std.atomic.spinLoopHint();
    return @intCast(input.len);
}

/// Allocates, fills, verifies and releases several blocks per round on the
/// *worker* thread while the JavaScript thread keeps allocating on its own.
///
/// Under emnapi both threads share one WebAssembly instance, and therefore one
/// page allocator: with an unsynchronized free list the two threads hand out
/// the same block to each other, which the pattern check reports - the audit's
/// "memory access out of bounds" trap inside `Allocator.destroy` was the same
/// corruption one step later.
fn concurrentAllocationRounds(rounds: u32) u32 {
    const allocator = napi.globalAllocator();
    var mismatches: u32 = 0;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        var buffers: [4][]u8 = undefined;
        var count: usize = 0;
        for (&buffers, 0..) |*buffer, index| {
            buffer.* = allocator.alloc(u8, 1024 + index * 37) catch break;
            @memset(buffer.*, @intCast(0x40 + index));
            count += 1;
        }
        // Verify only after every block of the round exists: an overlapping
        // allocation is visible here as a block another thread overwrote.
        for (buffers[0..count], 0..) |buffer, index| {
            for (buffer) |byte| {
                if (byte != @as(u8, @intCast(0x40 + index))) {
                    mismatches +%= 1;
                    break;
                }
            }
        }
        for (buffers[0..count]) |buffer| allocator.free(buffer);
    }
    return mismatches;
}

/// Exercise the shared page allocator from a worker thread. The returned count
/// must be zero: any other value means two threads were handed the same live
/// block.
pub fn workerConcurrentAllocations(env: napi.Env, rounds: u32) !napi.Promise {
    return napi.Worker(env, .{ .data = rounds, .Execute = concurrentAllocationRounds }).AsyncQueue();
}

/// Manual transfer: the payload stays owned by the caller, which releases it in
/// `OnComplete` - the first point at which the runner is guaranteed to be done
/// with it.
fn releaseBorrowedPayload(_: napi.Env, data: []const u8) void {
    const allocator = napi.globalAllocator();
    if (data.len != 0) allocator.free(@constCast(data));
}

pub fn workerBorrowedManual(env: napi.Env, size: u32) !napi.Promise {
    const allocator = napi.globalAllocator();
    const buffer = try allocator.alloc(u8, size);
    @memset(buffer, 'm');
    return napi.WorkerBorrowed(env, .{
        .data = @as([]const u8, buffer),
        .Execute = slowLength,
        .OnComplete = releaseBorrowedPayload,
    }).AsyncQueue();
}

// ---------------------------------------------------------------------------
// H06: the runner's owned result is released on every path
// ---------------------------------------------------------------------------

var worker_owned_runs = std.atomic.Value(usize).init(0);

pub fn workerOwnedRuns() usize {
    return worker_owned_runs.load(.monotonic);
}

fn countWorkerRun(_: napi.Env, _: []const u8) void {
    _ = worker_owned_runs.fetchAdd(1, .monotonic);
}

/// Native memory allocated by the runner: it has to be disposed after the
/// conversion, including on the `Queue` path where no promise ever sees it.
fn ownedWorkerResult(_: []const u8) !napi.Owned([]u8) {
    const allocator = napi.globalAllocator();
    return napi.Owned([]u8).init(try allocator.dupe(u8, "worker-owned-result"), allocator);
}

pub fn workerOwnedQueue(env: napi.Env, input: []const u8) void {
    napi.Worker(env, .{
        .data = input,
        .Execute = ownedWorkerResult,
        .OnComplete = countWorkerRun,
    }).Queue();
}

pub fn workerOwnedAsync(env: napi.Env, input: []const u8) !napi.Promise {
    return napi.Worker(env, .{ .data = input, .Execute = ownedWorkerResult }).AsyncQueue();
}

/// A large owned result: its release is measurable without a garbage
/// collection, which the (GC driven) promise settlement state is not.
fn ownedLargeResult(size: u32) !napi.Owned([]u8) {
    const allocator = napi.globalAllocator();
    const buffer = try allocator.alloc(u8, size);
    @memset(buffer, 'o');
    return napi.Owned([]u8).init(buffer, allocator);
}

pub fn workerOwnedLargeAsync(env: napi.Env, size: u32) !napi.Promise {
    return napi.Worker(env, .{ .data = size, .Execute = ownedLargeResult }).AsyncQueue();
}

// ---------------------------------------------------------------------------
// Worker lifecycle: repeated queueing, release while running, cancellation
// ---------------------------------------------------------------------------

/// A second queue of a running work item has to be refused (N-API cannot queue
/// one work item twice), and `deinit` while the work is in flight may not free
/// the worker under its own completion callback.
pub fn workerQueueWhileRunning(env: napi.Env, input: []const u8) !napi.Promise {
    const worker = napi.Worker(env, .{ .data = input, .Execute = slowLength });
    const promise = try worker.AsyncQueue();
    worker.Queue();
    worker.Queue();
    worker.deinit();
    worker.deinit();
    return promise;
}

/// A second `AsyncQueue` would settle a second promise with the same runner.
pub fn workerAsyncQueueTwice(env: napi.Env, input: []const u8) !napi.Promise {
    const worker = napi.Worker(env, .{ .data = input, .Execute = slowLength });
    const promise = try worker.AsyncQueue();
    if (worker.AsyncQueue()) |_| {} else |_| {}
    return promise;
}

/// Cancelling a queued worker settles its promise and still releases the
/// captured payload exactly once.
pub fn workerCancelCaptured(env: napi.Env, input: []const u8) !napi.Promise {
    const worker = napi.Worker(env, .{ .data = input, .Execute = slowLength });
    const promise = try worker.AsyncQueue();
    worker.Cancel();
    return promise;
}

var on_complete_copy: [32]u8 = [_]u8{0} ** 32;
var on_complete_len: usize = 0;
var remembered_worker: ?*anyopaque = null;
var remembered_release: ?*const fn (*anyopaque) void = null;

fn releaseHook(comptime WorkerPtr: type) *const fn (*anyopaque) void {
    return struct {
        fn call(raw: *anyopaque) void {
            const worker: WorkerPtr = @ptrCast(@alignCast(raw));
            worker.deinit();
        }
    }.call;
}

/// Releases the worker from inside its own completion callback - the worker is
/// still alive there, and the completion callback is its owner - and reads the
/// captured payload afterwards: the release has to be deferred to the end of the
/// completion, so the payload is still intact here.
fn deinitAndReadOnComplete(_: napi.Env, input: []const u8) void {
    on_complete_len = @min(input.len, on_complete_copy.len);
    @memcpy(on_complete_copy[0..on_complete_len], input[0..on_complete_len]);

    if (remembered_release) |release| {
        if (remembered_worker) |raw| release(raw);
    }
    remembered_worker = null;
    remembered_release = null;
}

pub fn workerDeinitInOnComplete(env: napi.Env, input: []const u8) !napi.Promise {
    const worker = napi.Worker(env, .{
        .data = input,
        .Execute = slowLength,
        .OnComplete = deinitAndReadOnComplete,
    });
    remembered_worker = @ptrCast(worker);
    remembered_release = releaseHook(@TypeOf(worker));
    return worker.AsyncQueue();
}

/// What `OnComplete` read from the captured payload.
pub fn workerOnCompletePayload() []const u8 {
    return on_complete_copy[0..on_complete_len];
}

// ---------------------------------------------------------------------------
// Setup failures: nothing is published and nothing is leaked
// ---------------------------------------------------------------------------

/// Allocation failure injector. Every allocation fails; frees are delegated to
/// the counting allocator so that whatever was allocated earlier stays visible
/// in `activeBytes`.
const FailingAllocator = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        return null;
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

/// Creation through the fallible entry point reports the failure instead of
/// aborting the process.
pub fn workerCreationFailure(env: napi.Env, input: []const u8) bool {
    var failing = FailingAllocator{ .backing = counter.allocator() };
    var scope = napi.ScopedAllocatorOverride.enter(failing.allocator());
    defer scope.exit();

    const worker = napi.tryWorker(env, .{ .data = input, .Execute = fnvChecksum }) catch {
        return true;
    };
    worker.deinit();
    return false;
}

/// The promise cannot be created, so nothing is published: the worker releases
/// itself (data, work item and shell) instead of handing out a promise that
/// would never settle. The returned pointer is dead after the error, so the
/// fixture must not touch it again.
pub fn workerPromiseCreationFailure(env: napi.Env, input: []const u8) bool {
    const worker = napi.Worker(env, .{ .data = input, .Execute = slowLength });

    var failing = FailingAllocator{ .backing = counter.allocator() };
    var scope = napi.ScopedAllocatorOverride.enter(failing.allocator());
    defer scope.exit();

    if (worker.AsyncQueue()) |_| {} else |_| {
        return true;
    }
    // Not reached with a failing allocator; keep the worker releasable if the
    // injection ever stops working.
    worker.deinit();
    return false;
}

// ---------------------------------------------------------------------------
// H11: explicit argument ownership for constructors and factories
// ---------------------------------------------------------------------------

/// The constructor copies a scalar out of its argument, so the class declares
/// the transient policy: converted arguments are released as soon as `init` or
/// the factory returned instead of staying alive until the instance is
/// collected.
const Summary = struct {
    length: usize,

    pub const arg_ownership: napi.ArgOwnership = .transient;

    pub fn init(text: []const u8) Summary {
        return .{ .length = text.len };
    }

    pub fn make(text: []const u8) Summary {
        return .{ .length = text.len };
    }

    pub fn lengthOf(self: *Summary) usize {
        return self.length;
    }
};

pub const SummaryClass = napi.Class(Summary);

/// Transient arguments together with an explicitly owned field: the field type
/// releases itself, so the wrapper must not retain the converted argument as
/// well.
const OwnedText = struct {
    text: napi.Owned([]u8),

    pub const arg_ownership: napi.ArgOwnership = .transient;

    pub fn init(text: []const u8) !OwnedText {
        const allocator = napi.globalAllocator();
        const copy = try allocator.dupe(u8, text);
        return .{ .text = napi.Owned([]u8).init(copy, allocator) };
    }

    pub fn describe(self: *OwnedText) []const u8 {
        return self.text.value;
    }

    pub fn deinit(self: *OwnedText) void {
        self.text.deinit();
        _ = finalized_count.fetchAdd(1, .monotonic);
    }
};

pub const OwnedTextClass = napi.Class(OwnedText);

/// A transient class whose *second* argument fails to convert: the large first
/// argument that was converted before the failure has to be released.
const PartialSummary = struct {
    length: usize,

    pub const arg_ownership: napi.ArgOwnership = .transient;

    pub fn init(text: []const u8, count: i32) PartialSummary {
        _ = count;
        return .{ .length = text.len };
    }

    pub fn lengthOf(self: *PartialSummary) usize {
        return self.length;
    }
};

pub const PartialSummaryClass = napi.Class(PartialSummary);

/// A transient factory that can fail.
const RefusingFactory = struct {
    length: usize,

    pub const arg_ownership: napi.ArgOwnership = .transient;

    pub fn make(text: []const u8, refuse: bool) !RefusingFactory {
        if (refuse) return error.Refused;
        return .{ .length = text.len };
    }

    pub fn lengthOf(self: *RefusingFactory) usize {
        return self.length;
    }
};

pub const RefusingFactoryClass = napi.ClassWithoutInit(RefusingFactory);

comptime {
    napi.NODE_API_MODULE("classes_audit", @This());
}
