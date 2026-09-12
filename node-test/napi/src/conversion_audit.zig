//! Conversion layer regression fixture.
//!
//! Every export here covers one of the audit findings for the conversion and
//! ownership layer: status checks, strict numeric ranges, partial conversion
//! rollback, borrowed/owned returns and the fixed array / void callback holes.
//! All native allocations go through a counting allocator so the JavaScript
//! spec can assert that successful *and* failing conversions return to the
//! allocation baseline.
const std = @import("std");
const napi = @import("napi");
const counting = @import("counting");

var counter = counting.CountingAllocator.init(std.heap.page_allocator);
pub const napi_allocator = counter.allocator();

/// Second, independent accounting allocator used by the allocator-provenance
/// tests. It is only ever reached through an explicit override.
var alternate_counter = counting.CountingAllocator.init(std.heap.page_allocator);

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
