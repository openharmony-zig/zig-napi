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

const NumberOrString = union(enum) {
    number: i32,
    string: []const u8,
};

fn allocator() std.mem.Allocator {
    return napi.globalAllocator();
}

fn check(status: c.napi_status) !void {
    if (status != c.napi_ok) {
        return napi.Error.fromStatus(napi.Status.New(status));
    }
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
    var result: u32 = 0;
    _ = c.napi_get_version(env.raw, &result);
    return result;
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

pub fn getMapping(env: napi.Env) !c.napi_value {
    const object = try napi.Object.Create(env);
    try object.Set("a", @as(i32, 101));
    try object.Set("b", @as(i32, 102));
    try object.Set("\x00c", @as(i32, 103));
    return object.raw;
}

pub fn sumMapping(object: napi.Object) i32 {
    return object.Get("a", i32) + object.Get("b", i32) + object.Get("\x00c", i32);
}

pub fn indexmapPassthrough(object: napi.Object) c.napi_value {
    return object.raw;
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

pub fn listObjKeys(env: napi.Env, object: napi.Object) !c.napi_value {
    var raw: c.napi_value = undefined;
    try check(c.napi_get_property_names(env.raw, object.raw, &raw));
    return raw;
}

pub fn getGlobal(env: napi.Env) !c.napi_value {
    var raw: c.napi_value = undefined;
    try check(c.napi_get_global(env.raw, &raw));
    return raw;
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

pub fn createSymbol(env: napi.Env, description: []const u8) !c.napi_value {
    const desc = napi.String.New(env, description);
    var symbol: c.napi_value = undefined;
    try check(c.napi_create_symbol(env.raw, desc.raw, &symbol));
    return symbol;
}

pub fn setSymbolInObj(env: napi.Env, object: napi.Object) !c.napi_value {
    const desc = napi.String.New(env, "native");
    var symbol: c.napi_value = undefined;
    try check(c.napi_create_symbol(env.raw, desc.raw, &symbol));
    const value = napi.String.New(env, "symbol-value");
    try check(c.napi_set_property(env.raw, object.raw, symbol, value.raw));
    return object.raw;
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

pub fn getBuffer(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, "hello world"[0..]);
}

pub fn getEmptyBuffer(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, &[_]u8{});
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

pub fn bufferPassThrough(input: napi.Buffer) c.napi_value {
    return input.raw;
}

pub fn createArraybuffer(env: napi.Env, len: u32) !napi.ArrayBuffer {
    return try napi.ArrayBuffer.New(env, len);
}

pub fn acceptArraybuffer(input: napi.ArrayBuffer) usize {
    return input.length();
}

pub fn arrayBufferPassThrough(input: napi.ArrayBuffer) c.napi_value {
    return input.raw;
}

pub fn getBufferSlice(env: napi.Env, input: napi.Buffer, start: u32, end: u32) !napi.Buffer {
    const slice = input.asConstSlice();
    if (start > end or end > slice.len) {
        return napi.Error.rangeError("buffer slice range is out of bounds");
    }
    return try napi.Buffer.copy(env, slice[start..end]);
}

pub fn createExternalBufferSlice(env: napi.Env) !napi.Buffer {
    return try napi.Buffer.copy(env, "external-buffer"[0..8]);
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

pub fn createUint8ClampedArrayFromData(env: napi.Env) !c.napi_value {
    var arraybuffer = try napi.ArrayBuffer.New(env, 3);
    @memcpy(arraybuffer.asSlice(), &[_]u8{ 1, 2, 255 });

    var raw: c.napi_value = undefined;
    try check(c.napi_create_typedarray(env.raw, c.napi_uint8_clamped_array, 3, arraybuffer.raw, 0, &raw));
    return raw;
}

pub fn arrayBufferFromData(env: napi.Env) !napi.ArrayBuffer {
    return try napi.ArrayBuffer.copy(env, &[_]u8{ 1, 2, 3, 4 });
}

pub fn arrayBufferFromExternal(env: napi.Env) !napi.ArrayBuffer {
    return try napi.ArrayBuffer.copy(env, &[_]u8{ 5, 6, 7, 8 });
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

pub fn eitherStringOrNumber(env: napi.Env, value: NumberOrString) !c.napi_value {
    switch (value) {
        .number => |number| {
            var raw: c.napi_value = undefined;
            try check(c.napi_create_int32(env.raw, number + 100, &raw));
            return raw;
        },
        .string => |string| {
            var raw: c.napi_value = undefined;
            try check(c.napi_create_string_utf8(env.raw, string.ptr, string.len, &raw));
            return raw;
        },
    }
}

pub fn returnEither(value: bool) NumberOrString {
    return if (value) .{ .string = "napi" } else .{ .number = 42 };
}

pub fn eitherFromOption(value: ?[]const u8) NumberOrString {
    return if (value) |payload| .{ .string = payload } else .{ .number = 0 };
}
