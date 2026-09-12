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

pub fn activeBytes() isize {
    return counter.stats().active_bytes;
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
