//! Conversion layer regression fixture.
//!
//! Every export here covers one of the audit findings for the conversion and
//! ownership layer: status checks, strict numeric ranges, partial conversion
//! rollback, borrowed/owned returns and the fixed array / void callback holes.
//! All native allocations go through a counting allocator so the JavaScript
//! spec can assert that successful *and* failing conversions return to the
//! allocation baseline.
const std = @import("std");
const builtin = @import("builtin");
const napi = @import("napi");
const counting = @import("counting");

/// The WASI runtime has no native threads an addon may spawn, so the two probes
/// that need a *second* thread compile their body out there. Both of their
/// JavaScript tests are native-only for the same reason.
const use_wasm_async_work = builtin.cpu.arch == .wasm32 and builtin.os.tag == .wasi;

// Safe backing: under emnapi every thread of the WebAssembly instance shares
// one unsynchronized page allocator global, so a counting allocator takes its
// pages from the module's safe page allocator.
var counter = counting.CountingAllocator.init(napi.safePageAllocator());
pub const napi_allocator = counter.allocator();

/// Second, independent accounting allocator used by the allocator-provenance
/// tests. It is only ever reached through an explicit override.
var alternate_counter = counting.CountingAllocator.init(napi.safePageAllocator());

fn alternateAllocator() std.mem.Allocator {
    return alternate_counter.allocator();
}

pub fn activeBytes() isize {
    return counter.stats().active_bytes;
}

pub fn activeAltBytes() isize {
    return alternate_counter.stats().active_bytes;
}

pub fn activeAltAllocations() isize {
    return alternate_counter.stats().active_allocations;
}

pub fn activeAllocations() isize {
    return counter.stats().active_allocations;
}

var native_calls: u32 = 0;

pub fn nativeCallCount() u32 {
    return native_calls;
}

pub fn resetNativeCallCount() void {
    native_calls = 0;
}

// ---------------------------------------------------------------- F01: status

const Point = struct {
    x: i32,
    y: i32,
};

/// A plain (non union) argument must be validated too: the audit showed that the
/// type gate was bypassed for ordinary parameters.
pub fn add(a: i32, b: i32) i32 {
    native_calls += 1;
    return a + b;
}

pub fn translatePoint(point: Point, dx: i32, dy: i32) Point {
    native_calls += 1;
    return .{ .x = point.x + dx, .y = point.y + dy };
}

pub fn roundtripStr(value: []const u8) []const u8 {
    native_calls += 1;
    return value;
}

pub fn stringLength(value: []const u8) u32 {
    native_calls += 1;
    return @intCast(value.len);
}

// --------------------------------------------------------------- F02: numbers

pub fn unsignedRoundtrip(value: u64) u64 {
    return value;
}

pub fn maxUnsigned() u64 {
    return std.math.maxInt(u64);
}

pub fn signedRoundtrip(value: i64) i64 {
    return value;
}

pub fn narrowRoundtrip(value: u8) u8 {
    return value;
}

pub fn floatRoundtrip(value: f32) f32 {
    return value;
}

pub fn doubleRoundtrip(value: f64) f64 {
    return value;
}

pub const SmallEnum = enum(u8) {
    A = 1,
    B = 2,
};

pub fn enumRoundtrip(value: SmallEnum) u8 {
    return @intFromEnum(value);
}

pub const StatusEnum = enum {
    Ready,
    Poll,

    pub const napi_string_enum = true;
};

pub fn stringEnumRoundtrip(value: StatusEnum) StatusEnum {
    return value;
}

// ------------------------------------------------------------- F03: rollback

const TextCount = struct {
    text: []const u8,
    count: i32,
};

pub fn nested(input: TextCount) u32 {
    return @intCast(input.text.len + @as(usize, @intCast(input.count)));
}

pub fn nestedArray(input: []TextCount) u32 {
    var total: u32 = 0;
    for (input) |item| {
        total += @intCast(item.text.len + @as(usize, @intCast(item.count)));
    }
    return total;
}

pub fn nestedOptional(input: ?TextCount) u32 {
    if (input) |item| return @intCast(item.text.len + @as(usize, @intCast(item.count)));
    return 0;
}

const NumberOrText = union(enum) {
    number: i32,
    text: []const u8,
};

pub fn unionRoundtrip(input: NumberOrText) u32 {
    return switch (input) {
        .number => |value| @intCast(value),
        .text => |value| @intCast(value.len),
    };
}

// ------------------------------------------------------------ F04: ownership

/// Freshly allocated return: `Owned` transfers the allocation to the conversion
/// layer, which releases it right after the JavaScript value has been created.
pub fn allocateReturn() napi.Owned([]u8) {
    const allocator = napi.globalAllocator();
    return .init(allocator.dupe(u8, "returned-allocation") catch @panic("OOM"), allocator);
}

/// Static literal return: plain returns are borrowed and must never be freed.
pub fn literalReturn() []const u8 {
    return "literal";
}

/// Returning an input alias is only safe because the argument cleanup runs after
/// the value has been copied into JavaScript.
pub fn passthroughReturn(value: []const u8) []const u8 {
    return value;
}

/// A sub slice of an argument has a different base pointer than the allocation
/// that owns the memory, so it must never be released on its own.
pub fn subsliceReturn(value: []const u8) []const u8 {
    if (value.len < 2) return value;
    return value[1..];
}

pub fn ownedStructReturn() napi.Owned(TextCount) {
    const allocator = napi.globalAllocator();
    return .init(.{
        .text = allocator.dupe(u8, "owned-struct") catch @panic("OOM"),
        .count = 7,
    }, allocator);
}

pub fn ownedStructText(value: napi.Owned(TextCount)) u32 {
    return @intCast(value.value.text.len);
}

/// Deep-copy the input into an owned value: this is the API async captures use,
/// so the copy must not share memory with the argument copy.
pub fn clonedReturn(input: TextCount) !napi.Owned(TextCount) {
    const allocator = napi.globalAllocator();
    return try napi.Owned(TextCount).clone(input, allocator);
}

pub fn clonedArrayReturn(input: []const []const u8) !napi.Owned([]const []const u8) {
    const allocator = napi.globalAllocator();
    return try napi.Owned([]const []const u8).clone(input, allocator);
}

/// A borrowed return that contains a nested `Owned` field: the container is
/// borrowed, the `Owned` field must still be disposed after the conversion.
const OwnedPair = struct {
    text: napi.Owned([]u8),
    count: i32,
};

// ------------------------------------- callback conversion ownership H03/H07

/// Error-first TSFN with two declared argument slots. The error path must call
/// the JavaScript callback with the error *alone*: a native null handle in the
/// remaining slots is not JavaScript `undefined` and crashes the engine.
const PairArgs = struct { u32, u32 };
const PairTsfn = napi.ThreadSafeFunction(PairArgs, void, true, 0);

/// Error-first TSFN without argument slots.
const NoArgsTsfn = napi.ThreadSafeFunction(std.meta.Tuple(&.{}), void, true, 0);

/// TSFN whose callback does not receive an error slot, with a bounded queue.
const PlainArgs = struct { u32 };
const PlainTsfn = napi.ThreadSafeFunction(PlainArgs, void, false, 0);
const LimitedTsfn = napi.ThreadSafeFunction(PlainArgs, void, false, 1);

/// Queue `count` failures whose message text is borrowed from a stack buffer
/// that is overwritten immediately after queueing. The queued call must own the
/// text it delivers.
pub fn tsfnErrorBorrowedText(tsfn: *NoArgsTsfn, prefix: []const u8, count: u32) !void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{s}-{d}", .{ prefix, index }) catch unreachable;
        try tsfn.Err(napi.Error.withReason(text), .NonBlocking);
        // The caller reuses (and clobbers) its buffer right after queueing.
        @memset(&buffer, 'x');
    }
    try tsfn.release(.Release);
}

/// Queue failures on an error-first TSFN that declares two argument slots.
/// Regression for the crash: the error branch must pass one argument, never a
/// native null in the argument slots.
pub fn tsfnErrorWithArgs(tsfn: *PairTsfn, count: u32) !void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try tsfn.Err(napi.Error.withReason("pair-error"), .NonBlocking);
    }
    try tsfn.release(.Release);
}

/// Same for a TSFN without argument slots: the callback must still receive
/// exactly one argument.
pub fn tsfnErrorWithoutArgs(tsfn: *NoArgsTsfn, count: u32) !void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try tsfn.Err(napi.Error.withReason("noargs-error"), .NonBlocking);
    }
    try tsfn.release(.Release);
}

/// `ThreadSafeFunctionCalleeHandled = false` has no error slot: an `Err` call
/// still runs the callback, with the argument slots left as `undefined`.
pub fn tsfnPlainError(tsfn: *PlainTsfn, count: u32) !void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try tsfn.Err(napi.Error.withReason("undeliverable"), .NonBlocking);
    }
    try tsfn.release(.Release);
}

pub fn tsfnPlainSuccess(tsfn: *PlainTsfn, base: u32, count: u32) !void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try tsfn.Ok(.{base + index}, .NonBlocking);
    }
    try tsfn.release(.Release);
}

/// A queued payload whose own conversion to JavaScript fails at delivery time
/// (the reference was already released). The dispatch must report that failure
/// through the error slot instead of passing an invalid handle to the callback.
const BadOutputArgs = struct { reference: napi.ObjectRef };
const BadOutputTsfn = napi.ThreadSafeFunction(BadOutputArgs, void, true, 0);

pub fn tsfnBadOutput(tsfn: *BadOutputTsfn, count: u32) !void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        try tsfn.Ok(.{ .reference = .{ .raw_ref = null, .taken = true } }, .NonBlocking);
    }
    try tsfn.release(.Release);
}

/// Hands the converted TSFN to a native worker thread that keeps queueing after
/// this body returned. The conversion transaction is committed when the body
/// runs, so the TSFN must not be aborted by the call that produced it.
pub fn tsfnQueueFromThread(tsfn: *PairTsfn, count: u32) !void {
    if (comptime use_wasm_async_work) {
        // Nothing is queued: the caller's test is skipped in this runtime.
        _ = .{ tsfn, count };
        return;
    }

    const ThreadBody = struct {
        fn run(inner: *PairTsfn, total: u32) void {
            defer inner.release(.Release) catch {};
            var index: u32 = 0;
            while (index < total) : (index += 1) {
                inner.Ok(.{ index, index + 1 }, .NonBlocking) catch {};
            }
        }
    };

    // Keep the creator reference held by this call: the worker releases its own.
    try tsfn.acquire();
    const worker = try std.Thread.spawn(.{}, ThreadBody.run, .{ tsfn, count });
    worker.detach();
    try tsfn.release(.Release);
}

/// Queues one call too many from a worker thread while the main thread is busy
/// inside this body, so the bounded queue really is full when the second call
/// arrives. A rejected call must release its payload instead of leaking it.
pub fn tsfnQueueOverflow(tsfn: *LimitedTsfn, queued: u32) !u32 {
    if (comptime use_wasm_async_work) {
        // A bounded queue can only be observed as full while the main thread is
        // blocked in this body, which needs a thread the runtime does not give
        // the addon here.
        _ = .{ tsfn, queued };
        return 0;
    }

    const ThreadBody = struct {
        fn run(inner: *LimitedTsfn, total: u32, rejected: *u32) void {
            defer inner.release(.Release) catch {};
            var index: u32 = 0;
            while (index < total) : (index += 1) {
                inner.Ok(.{index}, .NonBlocking) catch {
                    rejected.* += 1;
                };
            }
        }
    };

    try tsfn.acquire();
    var rejected: u32 = 0;
    const worker = try std.Thread.spawn(.{}, ThreadBody.run, .{ tsfn, queued, &rejected });
    worker.join();
    try tsfn.release(.Release);
    return rejected;
}

/// Aborts the TSFN while keeping the wrapper alive, then queues `count` calls:
/// a closing TSFN must reject them and release every payload it was handed.
/// The abort hands the TSFN to the runtime: Node destroys it - running the
/// wrapper's finalizer - on a later loop turn, so there is no second release to
/// make here (and the wrapper must not be used after this body returned).
pub fn tsfnAbortProbe(tsfn: *PlainTsfn, count: u32) !u32 {
    try tsfn.abort();

    var rejected: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        tsfn.Ok(.{index}, .NonBlocking) catch {
            rejected += 1;
        };
    }

    return rejected;
}

/// Promotes the first parameter to a strong reference and then fails on the
/// second one. The reference the conversion created must be deleted again, or
/// the JavaScript object stays alive forever.
pub fn referenceThenRejected(reference: napi.ObjectRef, tail: i32) i32 {
    _ = reference;
    native_calls += 1;
    return tail;
}

/// Same, but the reference is nested inside a struct whose *second* field fails
/// to convert: the struct prefix rollback must not leak the reference.
const ReferenceHolder = struct {
    reference: napi.ObjectRef,
    count: i32,
};

pub fn nestedReferenceThenRejected(holder: ReferenceHolder, tail: i32) i32 {
    _ = holder;
    native_calls += 1;
    return tail;
}

/// And inside an array, where a failure on a later element must release the
/// references created for the earlier ones.
pub fn arrayReferenceThenRejected(references: []const napi.ObjectRef, tail: i32) i32 {
    _ = references;
    native_calls += 1;
    return tail;
}

/// Promotes the first parameter to a TSFN and then fails: the promoted TSFN
/// must be aborted by the conversion, otherwise it keeps the environment (and
/// the process) alive after a call that never reached its body.
pub fn tsfnThenRejected(tsfn: *PairTsfn, tail: i32) i32 {
    _ = tsfn;
    native_calls += 1;
    return tail;
}

// A successful conversion hands the reference to the body. Storing it here is
// what keeps the JavaScript object alive; only `releaseStoredReference` drops
// the strong reference again.
var stored_reference: ?napi.ObjectRef = null;

pub fn storeReference(reference: napi.ObjectRef) void {
    stored_reference = reference;
}

pub fn storedReferenceIsSet() bool {
    return stored_reference != null;
}

pub fn releaseStoredReference(env: napi.Env) bool {
    const held = if (stored_reference) |*value| value else return false;
    held.Unref(env) catch return false;
    stored_reference = null;
    return true;
}

/// A manual conversion inside a native body, where the body never goes through
/// the automatic argument conversion: the struct conversion creates a reference
/// for `reference` and then fails on `count`. The conversion transaction must
/// release the reference it created before the failure, even though the frame of
/// this exported function is already committed.
const ManualHolder = struct {
    reference: napi.ObjectRef,
    count: i32,
};

pub fn manualNestedConversion(value: napi.NapiValue) !i32 {
    const holder = try value.As(ManualHolder);
    return holder.count;
}

/// The same manual conversion, but successful: the reference belongs to the
/// caller of the conversion from here on, exactly like an automatically
/// converted parameter.
pub fn manualStoredReference(value: napi.NapiValue) !void {
    stored_reference = try value.As(napi.ObjectRef);
}

/// A converted struct whose custom `deinit` releases its own native buffer while
/// the same conversion created a strong reference. On a rejected call the
/// transaction releases the reference and the native cleanup then runs the
/// custom `deinit`; neither may touch what the other owns.
const NativeHolder = struct {
    text: []u8,
    reference: napi.ObjectRef,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub fn nativeHolderThenRejected(holder: NativeHolder, tail: i32) i32 {
    _ = holder;
    native_calls += 1;
    return tail;
}

pub fn ownedPairReturn() OwnedPair {
    const allocator = napi.globalAllocator();
    return .{
        .text = .init(allocator.dupe(u8, "pair") catch @panic("OOM"), allocator),
        .count = 3,
    };
}

/// Same shape, but the second field cannot be converted to a JavaScript value
/// (`napi.Object.from_raw(env, null)` has no handle). The nested `Owned` field
/// must be released even though the output conversion fails.
const OwnedWithFailingOutput = struct {
    text: napi.Owned([]u8),
    handle: napi.Object,
};

pub fn ownedWithFailingOutput(env: napi.Env) OwnedWithFailingOutput {
    const allocator = napi.globalAllocator();
    return .{
        .text = .init(allocator.dupe(u8, "failing-output") catch @panic("OOM"), allocator),
        .handle = napi.Object.from_raw(env.raw, null),
    };
}

/// Nested `Owned` nodes inside a fixed array and an optional.
pub fn ownedFixedArrayReturn() [2]napi.Owned([]u8) {
    const allocator = napi.globalAllocator();
    return .{
        .init(allocator.dupe(u8, "first") catch @panic("OOM"), allocator),
        .init(allocator.dupe(u8, "second") catch @panic("OOM"), allocator),
    };
}

pub fn ownedOptionalReturn(present: bool) ?napi.Owned([]u8) {
    if (!present) return null;
    const allocator = napi.globalAllocator();
    return .init(allocator.dupe(u8, "optional") catch @panic("OOM"), allocator);
}

// --------------------------------------------------- F14: allocator provenance

/// Allocate through the alternate allocator and hand the result to the
/// conversion layer as `Owned`: the value must be released by the allocator that
/// produced it, not by whatever allocator is current at cleanup time.
pub fn allocateWithAlternateAllocator() napi.Owned([]u8) {
    var scope = napi.ScopedAllocatorOverride.enter(alternateAllocator());
    defer scope.exit();

    const allocator = napi.captureOperationAllocator();
    return .init(allocator.dupe(u8, "alternate") catch @panic("OOM"), allocator);
}

/// Reentrant probe: the arguments are converted with the allocator that was
/// current when the call started, then the callback switches this thread's
/// operation allocator, and finally the argument copies are released again.
pub fn allocatorProbe(input: TextCount, callback: napi.Function(struct {}, void)) !u32 {
    try callback.Call(.{});
    return @intCast(input.text.len + @as(usize, @intCast(input.count)));
}

/// Wrap a payload whose native memory (and the wrap header) was allocated by the
/// alternate allocator. Releasing the wrap must use the recorded allocator.
pub fn alternateAllocatorWrapProbe(env: napi.Env) !napi.Object {
    var scope = napi.ScopedAllocatorOverride.enter(alternateAllocator());
    defer scope.exit();

    const allocator = napi.captureOperationAllocator();
    var object = try napi.Object.Create(env);
    try object.wrap(TextCount{
        .text = allocator.dupe(u8, "wrapped") catch @panic("OOM"),
        .count = 1,
    });
    return object;
}

/// Runs the same destroy path a GC finalizer would run, without waiting for GC.
pub fn releaseWrapProbe(object: napi.Object) !void {
    try object.dropWrapped(TextCount);
}

pub fn useAlternateOperationAllocator() void {
    napi.setOperationAllocator(alternateAllocator());
}

pub fn useDefaultOperationAllocator() void {
    napi.resetOperationAllocator();
}

pub fn currentOperationAllocatorIsDefault() bool {
    const current = napi.globalAllocator();
    const expected = counter.allocator();
    return current.vtable == expected.vtable and current.ptr == expected.ptr;
}

// ---------------------------------------------------- binary inputs (F12/F13)

/// True once the binary wrappers validate their input through `tryFromRaw`.
/// The detach regression test below only runs when that API exists.
pub fn supportsBinaryTryFromRaw() bool {
    return @hasDecl(napi.Uint8Array, "tryFromRaw") and
        @hasDecl(napi.Buffer, "tryFromRaw") and
        @hasDecl(napi.ArrayBuffer, "tryFromRaw") and
        @hasDecl(napi.DataView, "tryFromRaw");
}

/// Reads through the wrapper. If a detached backing store were accepted by the
/// conversion, this body would read freed memory.
pub fn firstByte(view: napi.Uint8Array) u8 {
    native_calls += 1;
    const slice = view.asConstSlice();
    if (slice.len == 0) return 0;
    return slice[0];
}

// --------------------------------------------------------------- F13: generics

pub fn fixedInts(input: [2]i32) i32 {
    return input[0] + input[1];
}

pub fn fixedBytes(input: [2]u8) u32 {
    return @as(u32, input[0]) * 10 + input[1];
}

pub fn fixedUtf16(input: [2]u16) u32 {
    return @as(u32, input[0]) + input[1];
}

pub fn callVoid(callback: napi.Function(struct {}, void)) !void {
    try callback.Call(.{});
}

pub fn callNumber(callback: napi.Function(struct {}, i32)) !i32 {
    return try callback.Call(.{});
}

pub fn concatUtf16(env: napi.Env, input: []const u16) !napi.String {
    return try napi.String.createUtf16(env, input);
}

comptime {
    napi.NODE_API_MODULE("conversion_audit", @This());
}
