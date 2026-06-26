const std = @import("std");
const napi = @import("napi");
const c = napi.napi_sys.napi_sys;

pub const DEFAULT_COST: i32 = 12;

pub const Kind = enum(u8) {
    Dog = 0,
    Cat = 1,
    Duck = 2,
};

pub const CustomNumEnum = enum(i32) {
    One = 1,
    Eight = 8,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const ExternalPoint = struct {
    x: i32,
    y: i32,
};

pub const NativeWrapPayload = struct {
    value: u32,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        _ = self;
        _ = native_wrap_deinits.fetchAdd(1, .monotonic);
    }
};

pub const OtherNativeWrapPayload = struct {
    value: u32,
};

const NumberOrString = union(enum) {
    number: i32,
    string: []const u8,
};

const ExternalEither = union(enum) {
    number: napi.External(u32),
    point: napi.External(ExternalPoint),
};

var detached_external_deinits = std.atomic.Value(usize).init(0);
var native_wrap_deinits = std.atomic.Value(usize).init(0);

const DetachedExternalPayload = struct {
    value: u32,

    pub fn deinit(self: *DetachedExternalPayload) void {
        _ = self;
        _ = detached_external_deinits.fetchAdd(1, .monotonic);
    }
};

fn allocator() std.mem.Allocator {
    return napi.globalAllocator();
}

fn concatRustString(input: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator(), "{s} + Rust 🦀 string!", .{input});
}

fn plus100(input: i32) i32 {
    return input + 100;
}

fn optionalReturn(input: bool) ?i32 {
    return if (input) 42 else null;
}

fn resolveArray(count: u32) ![]i32 {
    const out = try allocator().alloc(i32, count);
    for (out, 0..) |*item, i| {
        item.* = @intCast(i);
    }
    return out;
}

fn add200(input: i32) i32 {
    return input + 200;
}

fn copyAs(comptime Dst: type, input: anytype) ![]Dst {
    const out = try allocator().alloc(Dst, input.len);
    for (input, 0..) |value, i| {
        out[i] = switch (@typeInfo(Dst)) {
            .int => @intCast(value),
            .float => @floatCast(value),
            else => @compileError("Unsupported copy destination type: " ++ @typeName(Dst)),
        };
    }
    return out;
}

pub fn getNapiVersion(env: napi.Env) u32 {
    return env.getNapiVersion();
}

pub fn add(left: i32, right: i32) i32 {
    return left + right;
}

pub fn fibonacci(input: u32) u32 {
    if (input <= 1) return input;
    var previous: u32 = 0;
    var current: u32 = 1;
    for (2..input + 1) |_| {
        const next = previous + current;
        previous = current;
        current = next;
    }
    return current;
}

pub fn contains(input: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, input, needle) != null;
}

pub fn concatStr(input: []const u8) ![]u8 {
    return try concatRustString(input);
}

pub fn concatLatin1(input: []const u8) ![]u8 {
    return try concatRustString(input);
}

pub fn concatUtf16(input: []const u8) ![]u8 {
    return try concatRustString(input);
}

pub fn roundtripStr(input: []const u8) []const u8 {
    return input;
}

pub fn getNums() [6]i32 {
    return .{ 1, 1, 2, 3, 5, 8 };
}

pub fn getWords() [2][]const u8 {
    return .{ "foo", "bar" };
}

pub fn getTuple(input: struct { i32, []const u8, i32 }) i32 {
    _ = @field(input, "1");
    return @field(input, "0") + @field(input, "2");
}

pub fn getNumArr() [2]i32 {
    return .{ 1, 2 };
}

pub fn getNestedNumArr() [2][1][1]i32 {
    return .{ .{.{1}}, .{.{1}} };
}

pub fn sumNums(values: []i32) i32 {
    var total: i32 = 0;
    for (values) |value| total += value;
    return total;
}

pub fn translatePoint(point: Point, dx: i32, dy: i32) Point {
    return .{
        .x = point.x + dx,
        .y = point.y + dy,
    };
}

pub fn getMapping(env: napi.Env) !napi.Object {
    const object = try napi.Object.Create(env);
    try object.Set("a", @as(i32, 101));
    try object.Set("b", @as(i32, 102));
    try object.Set("\x00c", @as(i32, 103));
    return object;
}

pub fn sumMapping(object: napi.Object) i32 {
    return object.Get("a", i32) + object.Get("b", i32) + object.Get("\x00c", i32);
}

pub fn indexmapPassthrough(object: napi.Object) napi.Object {
    return object;
}

pub fn createNativeWrap(env: napi.Env, value: u32) !napi.Object {
    var object = try napi.Object.Create(env);
    try object.Set("kind", "native-wrap");
    try object.wrapWithSizeHint(NativeWrapPayload{ .value = value }, 64);
    return object;
}

pub fn getNativeWrapValue(object: napi.Object) !u32 {
    const payload = try object.unwrap(NativeWrapPayload);
    return payload.value;
}

pub fn mutateNativeWrapValue(object: napi.Object, value: u32) !void {
    const payload = try object.unwrap(NativeWrapPayload);
    payload.value = value;
}

pub fn dropNativeWrap(object: napi.Object) !void {
    try object.dropWrapped(NativeWrapPayload);
}

pub fn dropNativeWrapWrongType(object: napi.Object) !void {
    try object.dropWrapped(OtherNativeWrapPayload);
}

pub fn getNativeWrapWrongType(object: napi.Object) !u32 {
    const payload = try object.unwrap(OtherNativeWrapPayload);
    return payload.value;
}

pub fn getNativeWrapFromEnv(env: napi.Env, object: napi.Object) !u32 {
    const payload = try env.unwrap(object, NativeWrapPayload);
    return payload.value;
}

pub fn nativeWrapMatches(object: napi.Object) bool {
    return object.matchesWrapped(NativeWrapPayload);
}

pub fn resetNativeWrapDeinitCount() void {
    native_wrap_deinits.store(0, .monotonic);
}

pub fn nativeWrapDeinitCount() usize {
    return native_wrap_deinits.load(.monotonic);
}

pub fn enumToI32(value: CustomNumEnum) i32 {
    return @intFromEnum(value);
}

pub fn call0(callback: napi.Function(struct {}, i32)) !i32 {
    return try callback.Call(.{});
}

pub fn call1(callback: napi.Function(i32, i32), value: i32) !i32 {
    return try callback.Call(value);
}

pub fn call2(callback: napi.Function(struct { i32, i32 }, i32), left: i32, right: i32) !i32 {
    return try callback.Call(.{ left, right });
}

pub fn callFunction(callback: napi.Function(struct {}, i32)) !i32 {
    return try callback.Call(.{});
}

pub fn callFunctionWithArg(callback: napi.Function(struct { i32, i32 }, i32), left: i32, right: i32) !i32 {
    return try callback.Call(.{ left, right });
}

pub fn createFunction(env: napi.Env) !napi.Function(i32, i32) {
    return try napi.Function(i32, i32).New(env, "add200", add200);
}

pub fn createObj() Point {
    return .{ .x = 1, .y = 2 };
}

pub fn listObjKeys(_: napi.Env, object: napi.Object) !napi.Array {
    return try object.propertyNames();
}

pub fn getGlobal(env: napi.Env) !napi.Object {
    return try env.getGlobal();
}

pub fn getUndefined(env: napi.Env) napi.Undefined {
    return env.getUndefined();
}

pub fn getNull(env: napi.Env) napi.Null {
    return env.getNull();
}

pub fn returnUndefined(env: napi.Env) napi.Undefined {
    return env.getUndefined();
}

pub fn returnNull(env: napi.Env) napi.Null {
    return env.getNull();
}

pub fn createSymbol(env: napi.Env, description: []const u8) !napi.NapiValue {
    return try env.createSymbol(description);
}

pub fn setSymbolInObj(env: napi.Env, object: napi.Object) !napi.Object {
    const symbol = try env.createSymbol("native");
    try object.SetProperty(symbol, "symbol-value");
    return object;
}

pub fn throwError() !void {
    return napi.Error.fromReason("native error");
}

pub fn throwTypeError() !void {
    return napi.Error.typeError("type error from native");
}

pub fn throwRangeError() !void {
    return napi.Error.rangeError("range error from native");
}

pub fn resultOk() napi.Result(i32) {
    return napi.Result(i32).Ok(42);
}

pub fn resultErr() napi.Result(i32) {
    return napi.Result(i32).Err(napi.Error.withReason("result error"));
}

pub fn resultVoidOk() napi.Result(void) {
    return napi.Result(void).Ok({});
}

pub fn resultAfterTry(input: bool) !napi.Result(i32) {
    if (input) return napi.Result(i32).Ok(100);
    return napi.Result(i32).Err(napi.Error.withTypeError("result type error"));
}

pub fn throwZigError() !void {
    return error.ZigNativeFailure;
}

pub fn throwZigErrorValue() !i32 {
    return error.ZigValueFailure;
}

pub fn getBuffer(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, "hello world"[0..]);
}

pub fn getEmptyBuffer(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, &[_]u8{});
}

pub fn getEmptyBufferFromNew(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.New(env, 0);
}

pub fn getEmptyExternalBuffer(env: napi.Env) !napi.Buffer {
    const bytes = try allocator().alloc(u8, 0);
    errdefer allocator().free(bytes);
    return try napi.Buffer.from(env, bytes);
}

pub fn appendBuffer(env: napi.Env, input: napi.Buffer) !napi.Buffer {
    const suffix = " world";
    const input_slice = input.asConstSlice();
    const out = try allocator().alloc(u8, input_slice.len + suffix.len);
    defer allocator().free(out);
    @memcpy(out[0..input_slice.len], input_slice);
    @memcpy(out[input_slice.len..], suffix);
    return try napi.Buffer.copy(env, out);
}

pub fn bufferPassThrough(input: napi.Buffer) napi.Buffer {
    return input;
}

pub fn createArraybuffer(env: napi.Env, len: u32) !napi.ArrayBuffer {
    return try napi.ArrayBuffer.New(env, len);
}

pub fn createEmptyArraybuffer(env: napi.Env) !napi.ArrayBuffer {
    return try napi.ArrayBuffer.New(env, 0);
}

pub fn acceptArraybuffer(input: napi.ArrayBuffer) usize {
    return input.length();
}

pub fn arrayBufferPassThrough(input: napi.ArrayBuffer) napi.ArrayBuffer {
    return input;
}

pub fn getBufferSlice(env: napi.Env, input: napi.Buffer, start: u32, end: u32) !napi.Buffer {
    const slice = input.asConstSlice();
    if (start > end or end > slice.len) {
        return napi.Error.rangeError("buffer slice range is out of bounds");
    }
    return try napi.Buffer.copy(env, slice[start..end]);
}

pub fn createExternalBufferSlice(env: napi.Env) !napi.Buffer {
    const bytes = try allocator().alloc(u8, 8);
    errdefer allocator().free(bytes);
    @memcpy(bytes, "external");
    return try napi.Buffer.from(env, bytes);
}

pub fn createBufferSliceFromCopiedData(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, "copied-data"[0..6]);
}

pub fn getEmptyTypedArray(env: napi.Env) !napi.Uint8Array {
    return try napi.Uint8Array.New(env, 0);
}

pub fn u8ArrayToArray(input: napi.Uint8Array) ![]i32 {
    return try copyAs(i32, input.asConstSlice());
}

pub fn uint8ClampedArrayToArray(input: napi.Uint8ClampedArray) ![]i32 {
    return try copyAs(i32, input.asConstSlice());
}

pub fn i8ArrayToArray(input: napi.Int8Array) ![]i32 {
    return try copyAs(i32, input.asConstSlice());
}

pub fn u16ArrayToArray(input: napi.Uint16Array) ![]i32 {
    return try copyAs(i32, input.asConstSlice());
}

pub fn i16ArrayToArray(input: napi.Int16Array) ![]i32 {
    return try copyAs(i32, input.asConstSlice());
}

pub fn u32ArrayToArray(input: napi.Uint32Array) ![]u32 {
    return try copyAs(u32, input.asConstSlice());
}

pub fn i32ArrayToArray(input: napi.Int32Array) ![]i32 {
    return try copyAs(i32, input.asConstSlice());
}

pub fn f32ArrayToArray(input: napi.Float32Array) ![]f64 {
    return try copyAs(f64, input.asConstSlice());
}

pub fn f64ArrayToArray(input: napi.Float64Array) ![]f64 {
    return try copyAs(f64, input.asConstSlice());
}

pub fn i64ArrayToArray(input: napi.BigInt64Array) ![]i64 {
    return try copyAs(i64, input.asConstSlice());
}

pub fn u64ArrayToArray(input: napi.BigUint64Array) ![]u64 {
    return try copyAs(u64, input.asConstSlice());
}

pub fn acceptSlice(values: []i32) i32 {
    return sumNums(values);
}

pub fn acceptUint8ClampedSlice(values: []i32) i32 {
    return sumNums(values);
}

pub fn convertU32Array(env: napi.Env, input: napi.Uint32Array) !napi.Uint32Array {
    return try napi.Uint32Array.copy(env, input.asConstSlice());
}

pub fn createExternalTypedArray(env: napi.Env) !napi.Uint32Array {
    return try napi.Uint32Array.copy(env, &[_]u32{ 1, 2, 3 });
}

pub fn mutateTypedArray(input: napi.Uint8Array) void {
    for (input.asSlice()) |*value| {
        value.* +%= 1;
    }
}

pub fn mutateArraybuffer(input: napi.ArrayBuffer) void {
    for (input.asSlice()) |*value| {
        value.* +%= 1;
    }
}

pub fn createUint8ClampedArrayFromData(env: napi.Env) !napi.Uint8ClampedArray {
    return try napi.Uint8ClampedArray.copy(env, &[_]u8{ 1, 2, 255 });
}

pub fn arrayBufferFromData(env: napi.Env) !napi.ArrayBuffer {
    return try napi.ArrayBuffer.copy(env, &[_]u8{ 1, 2, 3, 4 });
}

pub fn arrayBufferFromEmptyData(env: napi.Env) !napi.ArrayBuffer {
    return try napi.ArrayBuffer.copy(env, &[_]u8{});
}

pub fn arrayBufferFromExternal(env: napi.Env) !napi.ArrayBuffer {
    const bytes = try allocator().alloc(u8, 4);
    errdefer allocator().free(bytes);
    @memcpy(bytes, &[_]u8{ 5, 6, 7, 8 });
    return try napi.ArrayBuffer.from(env, bytes);
}

pub fn arrayBufferFromEmptyExternal(env: napi.Env) !napi.ArrayBuffer {
    const bytes = try allocator().alloc(u8, 0);
    errdefer allocator().free(bytes);
    return try napi.ArrayBuffer.from(env, bytes);
}

pub fn uint8ArrayFromData(env: napi.Env) !napi.Uint8Array {
    return try napi.Uint8Array.copy(env, &[_]u8{ 1, 2, 3, 4 });
}

pub fn uint8ArrayFromExternal(env: napi.Env) !napi.Uint8Array {
    return try napi.Uint8Array.copy(env, &[_]u8{ 5, 6, 7, 8 });
}

pub fn createDataView(env: napi.Env) !napi.DataView {
    return try napi.DataView.copy(env, &[_]u8{ 0x34, 0x12, 0, 0 });
}

pub fn readDataView(input: napi.DataView) !i32 {
    return try input.getUint16(0, true);
}

pub fn mutateDataView(input: napi.DataView) !void {
    try input.setUint16(0, 0x1234, true);
}

pub fn asyncPlus100(value: i32) napi.Async(i32, .single) {
    return napi.Async(i32, .single).from(value, plus100);
}

pub fn asyncTaskOptionalReturn(value: bool) napi.Async(?i32, .single) {
    return napi.Async(?i32, .single).from(value, optionalReturn);
}

pub fn asyncResolveArray(count: u32) napi.Async([]i32, .single) {
    return napi.Async([]i32, .single).from(count, resolveArray);
}

pub fn createBigInt(env: napi.Env) napi.BigInt {
    return napi.BigInt.New(env, @as(i128, -3689348814741910323300));
}

pub fn createBigIntI64(env: napi.Env) napi.BigInt {
    return napi.BigInt.New(env, @as(i128, 100));
}

pub fn bigintAdd(env: napi.Env, left: napi.BigInt, right: napi.BigInt) napi.BigInt {
    const left_value = napi.BigInt.from_napi_value(left.env, left.raw, i64);
    const right_value = napi.BigInt.from_napi_value(right.env, right.raw, i64);
    return napi.BigInt.New(env, @as(i128, left_value + right_value));
}

pub fn bigintGetU64AsString(value: napi.BigInt) ![]u8 {
    const raw = napi.BigInt.from_napi_value(value.env, value.raw, u64);
    return try std.fmt.allocPrint(allocator(), "{d}", .{raw});
}

pub fn bigintFromI64(env: napi.Env) napi.BigInt {
    return napi.BigInt.New(env, @as(i128, 100));
}

pub fn bigintFromI128(env: napi.Env) napi.BigInt {
    return napi.BigInt.New(env, @as(i128, -100));
}

pub fn eitherStringOrNumber(env: napi.Env, value: NumberOrString) !napi.NapiValue {
    switch (value) {
        .number => |number| {
            return napi.NapiValue.from_raw(env.raw, napi.Number.New(env, number + 100).raw);
        },
        .string => |string| {
            return napi.NapiValue.from_raw(env.raw, napi.String.New(env, string).raw);
        },
    }
}

pub fn returnEither(value: bool) NumberOrString {
    return if (value) .{ .string = "napi" } else .{ .number = 42 };
}

pub fn eitherFromOption(value: ?[]const u8) NumberOrString {
    return if (value) |payload| .{ .string = payload } else .{ .number = 0 };
}

pub fn createExternal(value: u32) !napi.External(u32) {
    return try napi.External(u32).New(value);
}

pub fn createExternalWithSizeHint(value: u32) !napi.External(u32) {
    return try napi.External(u32).NewWithSizeHint(value, 128);
}

pub fn createExternalPair(value: u32) ![2]napi.External(u32) {
    const external = try napi.External(u32).New(value);
    return .{ external, external };
}

const ForeignExternalHint = struct {
    allocator: std.mem.Allocator,
    ptr: [*]u64,
    len: usize,

    fn destroy(self: *ForeignExternalHint) void {
        const allocator_value = self.allocator;
        allocator_value.free(self.ptr[0..self.len]);
        allocator_value.destroy(self);
    }
};

fn foreignExternalFinalizer(
    _: c.napi_env,
    _: ?*anyopaque,
    hint: ?*anyopaque,
) callconv(.c) void {
    if (hint) |raw_hint| {
        const external_hint: *ForeignExternalHint = @ptrCast(@alignCast(raw_hint));
        external_hint.destroy();
    }
}

pub fn createMisalignedExternal(env: napi.Env) !c.napi_value {
    const allocator_value = allocator();
    const storage = try allocator_value.alloc(u64, 2);
    errdefer allocator_value.free(storage);

    const hint = try allocator_value.create(ForeignExternalHint);
    errdefer allocator_value.destroy(hint);
    hint.* = .{
        .allocator = allocator_value,
        .ptr = storage.ptr,
        .len = storage.len,
    };

    const byte_ptr: [*]u8 = @ptrCast(storage.ptr);
    var raw: c.napi_value = undefined;
    // Intentionally bypass zig-napi to create a foreign misaligned external for negative tests.
    const status = c.napi_create_external(
        env.raw,
        @ptrCast(byte_ptr + 1),
        foreignExternalFinalizer,
        hint,
        &raw,
    );
    if (status != c.napi_ok) {
        return napi.Error.fromStatus(napi.Status.New(status));
    }
    return raw;
}

pub fn getExternal(external: napi.External(u32)) u32 {
    return external.value().*;
}

pub fn getExternalSizeHint(external: napi.External(u32)) usize {
    return external.sizeHint();
}

pub fn mutateExternal(external: napi.External(u32), value: u32) void {
    external.valueMut().* = value;
}

pub fn createExternalPoint(x: i32, y: i32) !napi.External(ExternalPoint) {
    return try napi.External(ExternalPoint).New(.{ .x = x, .y = y });
}

pub fn getExternalPoint(external: napi.External(ExternalPoint)) ExternalPoint {
    return external.value().*;
}

pub fn mutateExternalPoint(external: napi.External(ExternalPoint), x: i32, y: i32) void {
    external.valueMut().* = .{ .x = x, .y = y };
}

pub fn externalEitherKind(value: ExternalEither) u32 {
    return switch (value) {
        .number => 1,
        .point => 2,
    };
}

pub fn externalEitherValue(value: ExternalEither) i32 {
    return switch (value) {
        .number => |external| @intCast(external.value().*),
        .point => |external| external.value().x + external.value().y,
    };
}

pub fn resetDetachedExternalDeinitCount() void {
    detached_external_deinits.store(0, .monotonic);
}

pub fn detachedExternalDeinitCount() usize {
    return detached_external_deinits.load(.monotonic);
}

pub fn deinitDetachedExternal() !usize {
    resetDetachedExternalDeinitCount();
    var external = try napi.External(DetachedExternalPayload).New(.{ .value = 1 });
    external.deinit();
    return detachedExternalDeinitCount();
}
