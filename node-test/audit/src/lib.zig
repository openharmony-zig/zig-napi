const std = @import("std");
const napi = @import("napi");
var counter = @import("audit_counting").CountingAllocator.init(std.heap.page_allocator);
pub const napi_allocator = counter.allocator();

pub fn activeBytes() isize {
    return counter.stats().active_bytes;
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
};
pub const Class = napi.Class(State);
pub const NoInit = napi.ClassWithoutInit(State);
const TextState = struct { text: []const u8, count: i32 };
pub const TextClass = napi.Class(TextState);

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

comptime {
    napi.NODE_API_MODULE("audit", @This());
}
