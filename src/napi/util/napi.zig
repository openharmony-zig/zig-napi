const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const NapiValue = @import("../value.zig");
const helper = @import("./helper.zig");
const Env = @import("../env.zig").Env;
const NapiError = @import("../wrapper/error.zig");
const Function = @import("../value/function.zig").Function;
const ThreadSafeFunction = @import("../wrapper/thread_safe_function.zig").ThreadSafeFunction;
const class = @import("../wrapper/class.zig");
const Buffer = @import("../wrapper/buffer.zig").Buffer;
const ArrayBuffer = @import("../wrapper/arraybuffer.zig").ArrayBuffer;
const DataView = @import("../wrapper/dataview.zig").DataView;
const AbortSignal = @import("../abort_signal.zig").AbortSignal;
const GlobalAllocator = @import("./allocator.zig");
const options = @import("../options.zig");

fn napiTypeOf(env: napi.napi_env, raw: napi.napi_value) !napi.napi_valuetype {
    var value_type: napi.napi_valuetype = undefined;
    const status = napi.napi_typeof(env, raw, &value_type);
    if (status != napi.napi_ok) {
        return NapiError.failStatus(status);
    }
    return value_type;
}

fn isArrayValue(env: napi.napi_env, raw: napi.napi_value) !bool {
    var result = false;
    const status = napi.napi_is_array(env, raw, &result);
    if (status != napi.napi_ok) {
        return NapiError.failStatus(status);
    }
    return result;
}

fn isBufferValue(env: napi.napi_env, raw: napi.napi_value) !bool {
    var result = false;
    const status = napi.napi_is_buffer(env, raw, &result);
    if (status != napi.napi_ok) {
        return NapiError.failStatus(status);
    }
    return result;
}

fn isArrayBufferValue(env: napi.napi_env, raw: napi.napi_value) !bool {
    var result = false;
    const status = napi.napi_is_arraybuffer(env, raw, &result);
    if (status != napi.napi_ok) {
        return NapiError.failStatus(status);
    }
    return result;
}

fn isTypedArrayValue(env: napi.napi_env, raw: napi.napi_value) !bool {
    var result = false;
    const status = napi.napi_is_typedarray(env, raw, &result);
    if (status != napi.napi_ok) {
        return NapiError.failStatus(status);
    }
    return result;
}

fn typedArrayValueMatchesType(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !bool {
    if (!try isTypedArrayValue(env, raw)) return false;
    if (!@hasDecl(T, "raw_typedarray_type")) return true;

    var actual_type: napi.napi_typedarray_type = undefined;
    var len: usize = 0;
    var data: ?*anyopaque = null;
    var arraybuffer: napi.napi_value = undefined;
    var byte_offset: usize = 0;
    const status = napi.napi_get_typedarray_info(
        env,
        raw,
        &actual_type,
        &len,
        &data,
        &arraybuffer,
        &byte_offset,
    );
    if (status != napi.napi_ok) {
        return NapiError.failStatus(status);
    }
    return actual_type == @field(T, "raw_typedarray_type");
}

fn isDataViewValue(env: napi.napi_env, raw: napi.napi_value) !bool {
    var result = false;
    const status = napi.napi_is_dataview(env, raw, &result);
    if (status != napi.napi_ok) {
        return NapiError.failStatus(status);
    }
    return result;
}

fn isPromiseValue(env: napi.napi_env, raw: napi.napi_value) !bool {
    var result = false;
    const status = napi.napi_is_promise(env, raw, &result);
    if (status != napi.napi_ok) {
        return NapiError.failStatus(status);
    }
    return result;
}

fn isPlainObjectValue(env: napi.napi_env, raw: napi.napi_value) !bool {
    if (try napiTypeOf(env, raw) != napi.napi_object) return false;
    if (try isArrayValue(env, raw)) return false;
    if (try isBufferValue(env, raw)) return false;
    if (try isArrayBufferValue(env, raw)) return false;
    if (try isTypedArrayValue(env, raw)) return false;
    if (try isDataViewValue(env, raw)) return false;
    if (try isPromiseValue(env, raw)) return false;
    return true;
}

fn isStringEnum(comptime T: type) bool {
    return @hasDecl(T, "napi_string_enum") and @TypeOf(@field(T, "napi_string_enum")) == bool and @field(T, "napi_string_enum");
}

/// Widest integer type used to validate enum tags before narrowing them.
fn enumWideTag(comptime T: type) type {
    const tag = @typeInfo(T).@"enum".tag_type;
    if (@typeInfo(tag).int.bits > 64) {
        @compileError("Enum tags wider than 64 bits are not supported: " ++ @typeName(T));
    }
    return std.meta.Int(@typeInfo(tag).int.signedness, 64);
}

fn enumFromString(env: napi.napi_env, raw: napi.napi_value, comptime T: type, allocator: std.mem.Allocator) !T {
    const enum_info = @typeInfo(T).@"enum";
    // The string copy is a temporary: it must be released regardless of whether
    // one of the enum members matches.
    const value = try NapiValue.String.from_napi_value_with_allocator(env, raw, []u8, allocator);
    defer allocator.free(value);

    inline for (enum_info.fields) |field| {
        if (std.mem.eql(u8, value, field.name)) {
            return @field(T, field.name);
        }
    }

    return NapiError.failTypeError("Invalid enum value, expected one of the string enum members of {s}", .{@typeName(T)});
}

fn enumFromNumber(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
    const enum_info = @typeInfo(T).@"enum";
    const Wide = comptime enumWideTag(T);
    // Validate with a type wide enough to hold every possible input first; only
    // after the member check may the value be narrowed to the enum tag type.
    const value = try Napi.numericFromNapiValue(env, raw, Wide);

    inline for (enum_info.fields) |field| {
        if (value == @as(Wide, @intCast(field.value))) {
            return @field(T, field.name);
        }
    }

    return NapiError.failTypeError("Invalid enum value {d}, expected one of the members of {s}", .{ value, @typeName(T) });
}

fn enumTypeToObject(env: napi.napi_env, comptime E: type) !napi.napi_value {
    var raw: napi.napi_value = undefined;
    const status = napi.napi_create_object(env, &raw);
    if (status != napi.napi_ok) {
        return NapiError.failStatus(status);
    }

    const object = NapiValue.Object.from_raw(env, raw);
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (comptime isStringEnum(E)) {
            try object.Set(field.name, field.name);
        } else {
            const Tag = @typeInfo(E).@"enum".tag_type;
            try object.Set(field.name, @as(Tag, @intCast(field.value)));
        }
    }
    return raw;
}

/// Construct a JavaScript backed wrapper for a converted value.
///
/// Wrappers that declare `tryFromRaw` (TypedArray, DataView, ArrayBuffer,
/// Buffer) validate the backing store there and fail on values that `from_raw`
/// would turn into an empty, unusable wrapper - for example a detached
/// ArrayBuffer. Wrappers that do not declare it yet keep using `from_raw`.
fn wrapperFromNapiValue(comptime T: type, env: napi.napi_env, raw: napi.napi_value) !T {
    if (comptime @hasDecl(T, "tryFromRaw")) {
        return try T.tryFromRaw(env, raw);
    }
    return T.from_raw(env, raw);
}

/// Types that accept any JavaScript value and therefore skip the type gate.
fn acceptsAnyValue(comptime T: type) bool {
    return T == NapiValue.NapiValue or T == napi.napi_value;
}

fn valueMatchesType(env: napi.napi_env, raw: napi.napi_value, comptime T: type) anyerror!bool {
    if (comptime acceptsAnyValue(T)) return true;

    if (comptime helper.isDts(T)) {
        return valueMatchesType(env, raw, T.wrapped_type);
    }

    if (comptime helper.isOwned(T)) {
        return valueMatchesType(env, raw, helper.ownedPayload(T));
    }

    switch (T) {
        NapiValue.Number => return (try napiTypeOf(env, raw)) == napi.napi_number,
        NapiValue.String => return (try napiTypeOf(env, raw)) == napi.napi_string,
        NapiValue.BigInt => {
            comptime options.requireNapiVersion(.v6);
            return (try napiTypeOf(env, raw)) == napi.napi_bigint;
        },
        NapiValue.Bool => return (try napiTypeOf(env, raw)) == napi.napi_boolean,
        NapiValue.Object => return isPlainObjectValue(env, raw),
        NapiValue.Promise, NapiValue.PromiseValue => return isPromiseValue(env, raw),
        NapiValue.Array => return (try isArrayValue(env, raw)) or (try isTypedArrayValue(env, raw)),
        NapiValue.Undefined => return (try napiTypeOf(env, raw)) == napi.napi_undefined,
        NapiValue.Null => return (try napiTypeOf(env, raw)) == napi.napi_null,
        Buffer => return isBufferValue(env, raw),
        ArrayBuffer => return isArrayBufferValue(env, raw),
        DataView => return isDataViewValue(env, raw),
        else => {},
    }

    const string_mode = comptime helper.stringLike(T);
    const infos = @typeInfo(T);
    if (string_mode != .Unknown) {
        // Fixed byte arrays also accept arrays and typed arrays of the same
        // element type, because they convert numerically.
        if (comptime infos == .array) {
            if (try isArrayValue(env, raw)) return true;
            if (try isTypedArrayValue(env, raw)) return true;
        }
        return (try napiTypeOf(env, raw)) == napi.napi_string;
    }

    return switch (infos) {
        .float, .int, .comptime_int, .comptime_float => (try napiTypeOf(env, raw)) == napi.napi_number,
        .bool => (try napiTypeOf(env, raw)) == napi.napi_boolean,
        .array => (try isArrayValue(env, raw)) or (try isTypedArrayValue(env, raw)),
        .pointer => |ptr| blk: {
            if (ptr.size == .one and helper.isThreadSafeFunction(ptr.child)) {
                break :blk (try napiTypeOf(env, raw)) == napi.napi_function;
            }
            break :blk helper.isSlice(T) and ((try isArrayValue(env, raw)) or (try isTypedArrayValue(env, raw)));
        },
        .optional => |optional| blk: {
            const value_type = try napiTypeOf(env, raw);
            if (value_type == napi.napi_null or value_type == napi.napi_undefined) {
                break :blk true;
            }
            break :blk try valueMatchesType(env, raw, optional.child);
        },
        .@"struct" => blk: {
            if (comptime helper.isAbortSignal(T)) break :blk (try napiTypeOf(env, raw)) == napi.napi_object;
            if (comptime helper.isNapiFunction(T)) break :blk (try napiTypeOf(env, raw)) == napi.napi_function;
            if (comptime helper.isThreadSafeFunction(T)) break :blk (try napiTypeOf(env, raw)) == napi.napi_function;
            if (comptime helper.isTypedArray(T)) break :blk try typedArrayValueMatchesType(env, raw, T);
            if (comptime helper.isDataView(T)) break :blk try isDataViewValue(env, raw);
            if (comptime helper.isReference(T)) break :blk true;
            if (comptime helper.isExternal(T)) break :blk T.matches_napi_value(env, raw);
            if (comptime helper.isTuple(T)) break :blk try isArrayValue(env, raw);
            if (comptime helper.isArrayList(T)) break :blk (try isArrayValue(env, raw)) or (try isTypedArrayValue(env, raw));
            break :blk try isPlainObjectValue(env, raw);
        },
        .@"union" => infos.@"union".tag_type != null,
        .@"enum" => if (comptime isStringEnum(T))
            (try napiTypeOf(env, raw)) == napi.napi_string
        else
            (try napiTypeOf(env, raw)) == napi.napi_number,
        else => false,
    };
}

pub const Napi = struct {
    /// One argument-conversion transaction (see `helper.ConversionFrame`).
    ///
    /// Conversion code that *creates* a JavaScript resource - a strong
    /// reference, a thread-safe function, a wrapped instance - must hand it to
    /// the active frame with `trackResource`, so a later conversion failure
    /// releases it instead of leaking it. `Function`'s exported callbacks
    /// already install a frame around their argument conversion; any other
    /// entry point that converts arguments (for example a class constructor)
    /// installs its own with `start` / `commit` / `end`.
    pub const ConversionFrame = helper.ConversionFrame;
    pub const TrackedResource = helper.TrackedResource;
    pub const trackConversionResource = helper.trackResource;
    pub const trackConversionReference = helper.trackReference;
    pub const trackConversionCustom = helper.trackCustom;

    /// Legacy alias-name based ownership tracker. Kept for the pre-existing
    /// `deinit_napi_value`/`deinit_napi_value_with_state` entry points; new code
    /// should use `Owned` values and `deinit_napi_value_with_allocator`.
    pub const DeinitState = struct {
        const Entry = struct {
            addr: usize,
            byte_len: usize,
        };

        entries: [128]Entry = undefined,
        len: usize = 0,

        fn shouldFree(self: *DeinitState, addr: usize, byte_len: usize) bool {
            for (self.entries[0..self.len]) |entry| {
                if (entry.addr == addr and entry.byte_len == byte_len) {
                    return false;
                }
            }
            if (self.len < self.entries.len) {
                self.entries[self.len] = .{ .addr = addr, .byte_len = byte_len };
                self.len += 1;
            }
            return true;
        }
    };

    pub fn canFastFrom(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .bool => true,
            .float => |float| float.bits <= 64,
            .int => |int| int.bits <= 64,
            else => false,
        };
    }

    pub fn canFastTo(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .bool => true,
            .float => |float| float.bits <= 64,
            .int => |int| int.bits <= 64,
            else => false,
        };
    }

    /// Strict numeric conversion shared by the fast and generic paths so both
    /// behave identically in every build mode.
    ///
    /// Rules:
    /// * the JavaScript value must be a number,
    /// * integer targets reject NaN, infinities, non integral numbers and
    ///   out of range values instead of truncating or wrapping,
    /// * float targets reject finite values that do not fit the target type,
    ///   NaN and infinities are preserved for `f64`.
    pub fn numericFromNapiValue(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        const info = @typeInfo(T);
        if (try napiTypeOf(env, raw) != napi.napi_number) {
            return NapiError.failTypeError("Expected a number for {s}", .{helper.shortTypeName(T)});
        }

        var number: f64 = 0;
        const status = napi.napi_get_value_double(env, raw, &number);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }

        switch (info) {
            .float => {
                if (comptime info.float.bits < 64) {
                    if (std.math.isFinite(number) and @abs(number) > @as(f64, std.math.floatMax(T))) {
                        return NapiError.failRangeError(
                            "Value {d} is out of range for {s}",
                            .{ number, helper.shortTypeName(T) },
                        );
                    }
                }
                return @floatCast(number);
            },
            .int => |int| {
                if (int.bits > 64) {
                    @compileError("Use napi.BigInt for integers wider than 64 bits: " ++ @typeName(T));
                }
                if (!std.math.isFinite(number)) {
                    return NapiError.failTypeError("Expected a finite integer for {s}", .{helper.shortTypeName(T)});
                }
                if (@trunc(number) != number) {
                    return NapiError.failTypeError("Expected an integer for {s}, got {d}", .{ helper.shortTypeName(T), number });
                }

                if (int.signedness == .signed) {
                    // Wide bound. For 64 bit targets the bound is 2^63, which is
                    // exactly representable, and is compared exclusively so the
                    // value can never wrap. Narrower targets compare inclusively
                    // against their exact limit and rely on the final
                    // `std.math.cast` for the rounding edge cases.
                    const min_value: f64 = if (int.bits >= 64)
                        -9223372036854775808.0
                    else
                        @floatFromInt(std.math.minInt(T));
                    const max_value: f64 = if (int.bits >= 64)
                        9223372036854775808.0
                    else
                        @floatFromInt(std.math.maxInt(T));
                    const out_of_range = if (int.bits >= 64)
                        number < min_value or number >= max_value
                    else
                        number < min_value or number > max_value;
                    if (out_of_range) {
                        return NapiError.failRangeError(
                            "Value {d} is out of range for {s}",
                            .{ number, helper.shortTypeName(T) },
                        );
                    }

                    if (int.bits <= 32) {
                        var wide: i32 = 0;
                        const read_status = napi.napi_get_value_int32(env, raw, &wide);
                        if (read_status != napi.napi_ok) {
                            return NapiError.failStatus(read_status);
                        }
                        return std.math.cast(T, wide) orelse
                            NapiError.failRangeError("Value {d} is out of range for {s}", .{ number, helper.shortTypeName(T) });
                    }

                    var wide: i64 = 0;
                    const read_status = napi.napi_get_value_int64(env, raw, &wide);
                    if (read_status != napi.napi_ok) {
                        return NapiError.failStatus(read_status);
                    }
                    return std.math.cast(T, wide) orelse
                        NapiError.failRangeError("Value {d} is out of range for {s}", .{ number, helper.shortTypeName(T) });
                }

                const float_max: f64 = if (int.bits >= 64)
                    18446744073709551616.0
                else
                    @floatFromInt(std.math.maxInt(T));
                const out_of_range = if (int.bits >= 64)
                    number < 0 or number >= float_max
                else
                    number < 0 or number > float_max;
                if (out_of_range) {
                    return NapiError.failRangeError(
                        "Value {d} is out of range for {s}",
                        .{ number, helper.shortTypeName(T) },
                    );
                }

                if (int.bits <= 32) {
                    var wide: u32 = 0;
                    const read_status = napi.napi_get_value_uint32(env, raw, &wide);
                    if (read_status != napi.napi_ok) {
                        return NapiError.failStatus(read_status);
                    }
                    return std.math.cast(T, wide) orelse
                        NapiError.failRangeError("Value {d} is out of range for {s}", .{ number, helper.shortTypeName(T) });
                }

                // N-API has no `napi_get_value_uint64`; the signed 64 bit getter is
                // exact for the validated range [0, 2^63).
                var wide: i64 = 0;
                const read_status = napi.napi_get_value_int64(env, raw, &wide);
                if (read_status != napi.napi_ok) {
                    return NapiError.failStatus(read_status);
                }
                if (wide < 0) {
                    return NapiError.failRangeError("Value {d} is out of range for {s}", .{ number, helper.shortTypeName(T) });
                }
                return std.math.cast(T, wide) orelse
                    NapiError.failRangeError("Value {d} is out of range for {s}", .{ number, helper.shortTypeName(T) });
            },
            else => @compileError("Unsupported numeric type: " ++ @typeName(T)),
        }
    }

    /// Fast path for types that map directly onto an N-API numeric getter.
    /// Uses the same validation rules as `from_napi_value`.
    pub fn from_napi_value_fast(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .bool => {
                var result: bool = false;
                const status = napi.napi_get_value_bool(env, raw, &result);
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }
                return result;
            },
            .float, .int => return Napi.numericFromNapiValue(env, raw, T),
            else => @compileError("Unsupported fast from_napi_value type: " ++ @typeName(T)),
        }
    }

    pub fn from_napi_value_auto(env: napi.napi_env, raw: napi.napi_value, comptime T: type) !T {
        return Napi.from_napi_value_auto_with_allocator(env, raw, T, GlobalAllocator.globalAllocator());
    }

    /// Convert using an explicit allocator for every native copy this conversion
    /// creates.
    ///
    /// Callers that clean the converted value up later must pass the same
    /// allocator here and to `deinit_napi_value_with_allocator`: a reentrant
    /// JavaScript callback may replace this thread's operation allocator while
    /// the conversion (or the call that owns it) is still running, and the
    /// allocate/free pair must not drift apart.
    pub fn from_napi_value_auto_with_allocator(env: napi.napi_env, raw: napi.napi_value, comptime T: type, allocator: std.mem.Allocator) !T {
        if (comptime Napi.canFastFrom(T)) {
            // The fast path copies nothing.
            return Napi.from_napi_value_fast(env, raw, T);
        }
        return Napi.from_napi_value_with_allocator(env, raw, T, allocator);
    }

    pub fn to_napi_value_fast(env: napi.napi_env, value: anytype) !napi.napi_value {
        const T = @TypeOf(value);
        const value_type = switch (T) {
            comptime_int => comptime helper.comptimeIntMode(value),
            comptime_float => comptime helper.comptimeFloatMode(value),
            else => T,
        };

        switch (@typeInfo(value_type)) {
            .bool => {
                var raw: napi.napi_value = undefined;
                const status = napi.napi_get_boolean(env, value, &raw);
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }
                return raw;
            },
            .float => {
                var raw: napi.napi_value = undefined;
                const status = napi.napi_create_double(env, @floatCast(value), &raw);
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }
                return raw;
            },
            .int => |int| {
                var raw: napi.napi_value = undefined;
                const status = if (int.signedness == .signed) blk: {
                    if (int.bits <= 32) {
                        break :blk napi.napi_create_int32(env, @intCast(value), &raw);
                    }
                    break :blk napi.napi_create_int64(env, @intCast(value), &raw);
                } else blk: {
                    if (int.bits <= 32) {
                        break :blk napi.napi_create_uint32(env, @intCast(value), &raw);
                    }
                    // Unsigned values above 2^31 do not fit `napi_create_int64`
                    // without narrowing. Emit a JavaScript number instead; values
                    // beyond 2^53 need `napi.BigInt` for exact results.
                    break :blk napi.napi_create_double(env, @floatFromInt(value), &raw);
                };
                if (status != napi.napi_ok) {
                    return NapiError.failStatus(status);
                }
                return raw;
            },
            else => @compileError("Unsupported fast to_napi_value type: " ++ @typeName(T)),
        }
    }

    pub fn to_napi_value_auto(env: napi.napi_env, value: anytype, comptime name: ?[]const u8) !napi.napi_value {
        if (comptime canFastToValue(@TypeOf(value))) {
            return Napi.to_napi_value_fast(env, value);
        }
        return try Napi.to_napi_value(env, value, name);
    }

    fn canFastToValue(comptime T: type) bool {
        if (comptime helper.isOwned(T)) return false;
        if (comptime helper.isDts(T)) return false;
        return Napi.canFastTo(T);
    }

    /// Legacy entry point. Frees native shapes using the globally configured
    /// allocator and a fixed size address cache. Prefer `Owned` values together
    /// with `deinit_napi_value_with_allocator`.
    pub fn deinit_napi_value(comptime T: type, value: T) void {
        var state = DeinitState{};
        Napi.deinit_napi_value_with_state(T, value, &state);
    }

    fn deinitWithCustomStructDeinit(comptime T: type, value: T, allocator: std.mem.Allocator) bool {
        if (!@hasDecl(T, "deinit")) return false;

        const deinit_fn = @field(T, "deinit");
        const deinit_info = @typeInfo(@TypeOf(deinit_fn));
        if (deinit_info != .@"fn") {
            @compileError("Struct " ++ @typeName(T) ++ ".deinit must be a function");
        }

        const params = deinit_info.@"fn".params;
        if (params.len == 0 or params.len > 2) {
            @compileError("Struct " ++ @typeName(T) ++ ".deinit must accept (self) or (self, allocator)");
        }

        const self_type = params[0].type orelse {
            @compileError("Struct " ++ @typeName(T) ++ ".deinit self parameter must be typed");
        };
        const self_info = @typeInfo(self_type);
        const valid_self_type = self_type == T or
            (self_info == .pointer and self_info.pointer.size == .one and self_info.pointer.child == T);
        if (!valid_self_type) {
            @compileError("Struct " ++ @typeName(T) ++ ".deinit first parameter must be Self, *Self, or *const Self");
        }

        const return_type = deinit_info.@"fn".return_type orelse void;
        if (return_type != void) {
            @compileError("Struct " ++ @typeName(T) ++ ".deinit must return void");
        }

        var mutable = value;
        if (params.len == 1) {
            mutable.deinit();
            return true;
        }

        const allocator_type = params[1].type orelse {
            @compileError("Struct " ++ @typeName(T) ++ ".deinit allocator parameter must be typed");
        };
        if (allocator_type != std.mem.Allocator) {
            @compileError("Struct " ++ @typeName(T) ++ ".deinit allocator parameter must be std.mem.Allocator");
        }

        mutable.deinit(allocator);
        return true;
    }

    /// Release the first `initialized` fields of a partially converted struct.
    /// Used by `errdefer` to roll back a conversion that failed halfway through
    /// instead of leaking everything that was already allocated.
    pub fn cleanupStructPrefix(comptime T: type, result: *const T, initialized: usize, allocator: std.mem.Allocator) void {
        const infos = @typeInfo(T);
        if (comptime infos != .@"struct") {
            @compileError("cleanupStructPrefix expects a struct or tuple type, got: " ++ @typeName(T));
        }
        inline for (infos.@"struct".fields, 0..) |field, i| {
            if (i < initialized) {
                Napi.deinit_napi_value_with_allocator(field.type, @field(result.*, field.name), allocator);
            }
        }
    }

    /// Legacy entry point kept for callers that share one dedupe state across a
    /// group of related values.
    pub fn deinit_napi_value_with_state(comptime T: type, value: T, state: *DeinitState) void {
        Napi.deinit_napi_value_inner(T, value, GlobalAllocator.globalAllocator(), state);
    }

    /// Release every native allocation owned by `value` using `allocator`.
    ///
    /// * JavaScript handles are left alone: they are owned by the runtime.
    /// * Error payloads borrow their message strings and are never freed.
    /// * `Owned` values release their payload with the allocator recorded at
    ///   construction time, which keeps the allocate/free pair together.
    ///
    /// The caller must guarantee that the structure has exactly one owner.
    pub fn deinit_napi_value_with_allocator(comptime T: type, value: T, allocator: std.mem.Allocator) void {
        Napi.deinit_napi_value_inner(T, value, allocator, null);
    }

    fn deinit_napi_value_inner(comptime T: type, value: T, allocator: std.mem.Allocator, state: ?*DeinitState) void {
        if (comptime helper.isOwned(T)) {
            Napi.deinit_napi_value_inner(helper.ownedPayload(T), value.value, value.allocator, state);
            return;
        }

        const infos = @typeInfo(T);

        if (comptime helper.isJsHandle(T)) {
            return;
        }

        const string_mode = comptime helper.stringLike(T);
        if (string_mode != .Unknown) {
            if (infos == .pointer and infos.pointer.size == .slice) {
                Napi.freeSliceIfNeeded(T, value, allocator, state);
            } else if (infos == .array) {
                for (value) |item| {
                    Napi.deinit_napi_value_inner(@TypeOf(item), item, allocator, state);
                }
            }
            return;
        }

        if (comptime helper.isDts(T)) {
            if (comptime !@hasField(T, "value")) {
                @compileError("Type-only dts wrappers cannot be converted from JavaScript values");
            }
            Napi.deinit_napi_value_inner(T.wrapped_type, value.value, allocator, state);
            return;
        }

        switch (infos) {
            .array => {
                for (value) |item| {
                    Napi.deinit_napi_value_inner(infos.array.child, item, allocator, state);
                }
            },
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    for (value) |item| {
                        Napi.deinit_napi_value_inner(ptr.child, item, allocator, state);
                    }
                    Napi.freeSliceIfNeeded(T, value, allocator, state);
                }
            },
            .optional => |optional| {
                if (value) |payload| {
                    Napi.deinit_napi_value_inner(optional.child, payload, allocator, state);
                }
            },
            .@"struct" => {
                if (comptime helper.isArrayList(T)) {
                    const child = comptime helper.getArrayListElementType(T);
                    for (value.items) |item| {
                        Napi.deinit_napi_value_inner(child, item, allocator, state);
                    }
                    var mutable = value;
                    mutable.deinit(allocator);
                    return;
                }

                if (Napi.deinitWithCustomStructDeinit(T, value, allocator)) {
                    return;
                }

                inline for (infos.@"struct".fields) |field| {
                    Napi.deinit_napi_value_inner(field.type, @field(value, field.name), allocator, state);
                }
            },
            .@"union" => |union_info| {
                if (union_info.tag_type == null) return;
                switch (value) {
                    inline else => |payload| Napi.deinit_napi_value_inner(@TypeOf(payload), payload, allocator, state),
                }
            },
            else => {},
        }
    }

    fn freeSliceIfNeeded(comptime T: type, value: T, allocator: std.mem.Allocator, state: ?*DeinitState) void {
        const bytes = std.mem.sliceAsBytes(value);
        if (state) |dedupe| {
            if (!dedupe.shouldFree(@intFromPtr(bytes.ptr), bytes.len)) return;
        }
        allocator.free(value);
    }

    /// Deep-copy a native value shape into freshly allocated memory.
    ///
    /// The copy is independent of the source, which is what background threads
    /// and async tasks need. JavaScript handles cannot be copied: they belong to
    /// a specific `napi_env` and must not silently become shared state.
    pub fn clone_napi_value(comptime T: type, value: T, allocator: std.mem.Allocator) !T {
        if (comptime helper.isOwned(T)) {
            return T.init(try Napi.clone_napi_value(helper.ownedPayload(T), value.value, allocator), allocator);
        }

        // Error payloads only borrow their messages; sharing them is intentional
        // and must be allowed even though they carry no native allocation.
        if (comptime helper.isErrorValue(T)) {
            return value;
        }

        if (comptime helper.isJsHandle(T)) {
            @compileError("JavaScript handles cannot be cloned into native memory: " ++ @typeName(T) ++
                ". Convert the handle to native data (for example a []const u8) before capturing it.");
        }

        const infos = @typeInfo(T);
        const string_mode = comptime helper.stringLike(T);
        if (string_mode != .Unknown) {
            if (infos == .pointer and infos.pointer.size == .slice) {
                return try allocator.dupe(infos.pointer.child, value);
            }
            return value;
        }

        if (comptime helper.isDts(T)) {
            if (comptime !@hasField(T, "value")) {
                @compileError("Type-only dts wrappers cannot be cloned");
            }
            var copy = value;
            copy.value = try Napi.clone_napi_value(T.wrapped_type, value.value, allocator);
            return copy;
        }

        switch (infos) {
            .bool, .int, .float, .@"enum", .comptime_int, .comptime_float => return value,
            .null, .undefined, .void => return value,
            .array => |arr| {
                var copy: T = undefined;
                var initialized: usize = 0;
                errdefer for (copy[0..initialized]) |item| {
                    Napi.deinit_napi_value_with_allocator(arr.child, item, allocator);
                };
                for (value, 0..) |item, i| {
                    copy[i] = try Napi.clone_napi_value(arr.child, item, allocator);
                    initialized = i + 1;
                }
                return copy;
            },
            .pointer => |ptr| {
                if (ptr.size != .slice) {
                    @compileError("Only slices can be cloned, got: " ++ @typeName(T));
                }
                const copy = try allocator.alloc(ptr.child, value.len);
                var initialized: usize = 0;
                errdefer {
                    for (copy[0..initialized]) |item| {
                        Napi.deinit_napi_value_with_allocator(ptr.child, item, allocator);
                    }
                    allocator.free(copy);
                }
                for (value, 0..) |item, i| {
                    copy[i] = try Napi.clone_napi_value(ptr.child, item, allocator);
                    initialized = i + 1;
                }
                return copy;
            },
            .optional => |optional| {
                if (value) |payload| {
                    return try Napi.clone_napi_value(optional.child, payload, allocator);
                }
                return null;
            },
            .@"struct" => {
                if (comptime helper.isArrayList(T)) {
                    const child = comptime helper.getArrayListElementType(T);
                    var copy: T = T.empty;
                    var initialized: usize = 0;
                    errdefer {
                        // Release the clones that were already appended, then the
                        // backing buffer: `deinit` only frees the buffer itself.
                        for (copy.items[0..initialized]) |item| {
                            Napi.deinit_napi_value_with_allocator(child, item, allocator);
                        }
                        copy.deinit(allocator);
                    }
                    try copy.ensureTotalCapacity(allocator, value.items.len);
                    for (value.items) |item| {
                        // A clone that cannot be appended (capacity growth failed)
                        // is released by this iteration's errdefer.
                        const cloned = try Napi.clone_napi_value(child, item, allocator);
                        errdefer Napi.deinit_napi_value_with_allocator(child, cloned, allocator);
                        try copy.append(allocator, cloned);
                        initialized += 1;
                    }
                    return copy;
                }

                var copy = value;
                var initialized: usize = 0;
                errdefer {
                    // Fields cloned before the failing field must not be lost.
                    inline for (infos.@"struct".fields, 0..) |field, i| {
                        if (i < initialized) {
                            Napi.deinit_napi_value_with_allocator(field.type, @field(copy, field.name), allocator);
                        }
                    }
                }
                inline for (infos.@"struct".fields, 0..) |field, i| {
                    @field(copy, field.name) = try Napi.clone_napi_value(field.type, @field(value, field.name), allocator);
                    initialized = i + 1;
                }
                return copy;
            },
            .@"union" => |union_info| {
                if (union_info.tag_type == null) return value;
                return switch (value) {
                    inline else => |payload, tag| @unionInit(T, @tagName(tag), try Napi.clone_napi_value(@TypeOf(payload), payload, allocator)),
                };
            },
            else => @compileError("Unsupported clone type: " ++ @typeName(T)),
        }
    }

    /// True when `T` can contain an explicit `Owned` node somewhere.
    ///
    /// Borrowed values (plain slices, literals, JS handles) return false, which
    /// lets callers skip the cleanup walk entirely: a borrowed slice may alias
    /// memory that is released elsewhere and must never be read during cleanup.
    pub fn containsOwnedValue(comptime T: type) bool {
        if (comptime helper.isOwned(T)) return true;

        switch (@typeInfo(T)) {
            .optional => |optional| return Napi.containsOwnedValue(optional.child),
            .array => |array| return Napi.containsOwnedValue(array.child),
            .pointer => |ptr| return ptr.size == .slice and Napi.containsOwnedValue(ptr.child),
            .@"struct" => |struct_info| {
                if (comptime helper.isJsHandle(T)) return false;
                inline for (struct_info.fields) |field| {
                    if (comptime Napi.containsOwnedValue(field.type)) return true;
                }
                return false;
            },
            .@"union" => |union_info| {
                if (union_info.tag_type == null) return false;
                inline for (union_info.fields) |field| {
                    if (comptime Napi.containsOwnedValue(field.type)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Dispose the explicitly owned parts of an otherwise borrowed value.
    ///
    /// Only `Owned` nodes are released, using the allocator each of them
    /// recorded. Plain slices, literals, input aliases and JS handles are left
    /// untouched, so this is safe on any value: a converted argument (where the
    /// call scope owns the copy) as well as a native return (where the payload
    /// is borrowed unless it says `Owned`).
    ///
    /// `allocator` is kept for callers that already thread an allocator through
    /// the cleanup path; the `Owned` nodes themselves decide what to use.
    pub fn disposeOwnedParts(comptime T: type, value: T, allocator: std.mem.Allocator) void {
        if (comptime !Napi.containsOwnedValue(T)) return;

        if (comptime helper.isOwned(T)) {
            var mutable = value;
            mutable.deinit();
            return;
        }

        switch (@typeInfo(T)) {
            .optional => |optional| {
                if (value) |payload| Napi.disposeOwnedParts(optional.child, payload, allocator);
            },
            .array => |array| {
                for (value) |item| Napi.disposeOwnedParts(array.child, item, allocator);
            },
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    for (value) |item| Napi.disposeOwnedParts(ptr.child, item, allocator);
                }
            },
            .@"struct" => |struct_info| {
                if (comptime helper.isJsHandle(T)) return;
                inline for (struct_info.fields) |field| {
                    Napi.disposeOwnedParts(field.type, @field(value, field.name), allocator);
                }
            },
            .@"union" => |union_info| {
                if (union_info.tag_type == null) return;
                switch (value) {
                    inline else => |payload| Napi.disposeOwnedParts(@TypeOf(payload), payload, allocator),
                }
            },
            else => {},
        }
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) anyerror!T {
        return Napi.from_napi_value_with_allocator(env, raw, T, GlobalAllocator.globalAllocator());
    }

    /// Fallible conversion that allocates every native copy through `allocator`.
    pub fn from_napi_value_with_allocator(env: napi.napi_env, raw: napi.napi_value, comptime T: type, allocator: std.mem.Allocator) anyerror!T {
        const infos = @typeInfo(T);
        if (comptime helper.isDts(T)) {
            if (comptime !@hasField(T, "value")) {
                @compileError("Type-only dts wrappers cannot be converted from JavaScript values");
            }
            return .{ .value = try Napi.from_napi_value_auto_with_allocator(env, raw, T.wrapped_type, allocator) };
        }

        if (comptime helper.isOwned(T)) {
            // An `Owned` parameter receives the freshly allocated conversion
            // result together with the allocator that produced it. The scoped
            // argument cleanup releases it exactly once.
            const converted: helper.ownedPayload(T) = try Napi.from_napi_value_with_allocator(env, raw, helper.ownedPayload(T), allocator);
            return T.init(converted, allocator);
        }

        // Every conversion validates the declared type before reading anything, so
        // a mismatch reports a TypeError instead of reading an unrelated payload.
        // Native wrapped values do their own validation with more precise
        // diagnostics, so they are converted directly below.
        if (comptime !acceptsAnyValue(T) and !helper.isExternal(T) and !helper.isReference(T)) {
            if (!try valueMatchesType(env, raw, T)) {
                // A pending JavaScript exception or a more specific error recorded
                // by the type check (for example for native wrapped values) wins
                // over the generic mismatch message.
                if (NapiError.hasPendingException()) {
                    return error.PendingException;
                }
                if (NapiError.last_error != null) {
                    return error.GenericFailure;
                }
                return NapiError.failTypeError(
                    "Expected {s} but received a value of a different type",
                    .{helper.shortTypeName(T)},
                );
            }
        }

        switch (T) {
            NapiValue.NapiValue, NapiValue.BigInt, NapiValue.Number, NapiValue.String, NapiValue.Object, NapiValue.Promise, NapiValue.PromiseValue, NapiValue.Array, NapiValue.Undefined, NapiValue.Null, Buffer, ArrayBuffer, DataView => {
                return wrapperFromNapiValue(T, env, raw);
            },
            else => {
                const stringMode = comptime helper.stringLike(T);
                switch (stringMode) {
                    .Utf8, .Utf16 => {
                        // Fixed byte arrays keep numeric semantics when they receive
                        // an array or typed array; strings are read as code units.
                        // Slices only ever come from strings.
                        if (comptime infos == .array) {
                            if (try napiTypeOf(env, raw) != napi.napi_string) {
                                return NapiValue.Array.from_napi_value_with_allocator(env, raw, T, allocator);
                            }
                        }
                        return NapiValue.String.from_napi_value_with_allocator(env, raw, T, allocator);
                    },
                    else => {
                        switch (infos) {
                            .@"fn" => {
                                @compileError("Please use Function directly");
                            },
                            .null => {
                                return null;
                            },
                            .undefined => {
                                return undefined;
                            },
                            .float, .int => {
                                return Napi.numericFromNapiValue(env, raw, T);
                            },
                            .array => {
                                return NapiValue.Array.from_napi_value_with_allocator(env, raw, T, allocator);
                            },
                            .pointer => {
                                if (comptime helper.isSinglePointer(T)) {
                                    const child_info = @typeInfo(T).pointer.child;
                                    if (comptime helper.isThreadSafeFunction(child_info)) {
                                        const fn_infos = @typeInfo(child_info);
                                        comptime var args_type = void;
                                        comptime var return_type = void;
                                        comptime var thread_safe_function_call_variant = false;
                                        comptime var max_queue_size = 0;

                                        inline for (fn_infos.@"struct".fields) |field| {
                                            if (comptime std.mem.eql(u8, field.name, "args")) {
                                                args_type = field.type;
                                            }
                                            if (comptime std.mem.eql(u8, field.name, "return_type")) {
                                                return_type = field.type;
                                            }
                                            if (comptime std.mem.eql(u8, field.name, "thread_safe_function_call_variant")) {
                                                const temp_instance = @as(child_info, undefined);
                                                thread_safe_function_call_variant = @field(temp_instance, "thread_safe_function_call_variant");
                                            }
                                            if (comptime std.mem.eql(u8, field.name, "max_queue_size")) {
                                                const temp_instance = @as(child_info, undefined);
                                                max_queue_size = @field(temp_instance, "max_queue_size");
                                            }
                                        }
                                        // A function that cannot be promoted is a
                                        // failed argument, not a handle the native
                                        // body could use: report the recorded
                                        // creation error instead of passing the
                                        // failure handle on.
                                        return ThreadSafeFunction(args_type, return_type, thread_safe_function_call_variant, max_queue_size).tryFrom_raw(env, raw) catch |err| {
                                            if (err != error.OutOfMemory and NapiError.last_error == null) {
                                                NapiError.last_error = NapiError.Error.withCodeAndMessage(
                                                    "ERR_NAPI_TSFN_NOT_CREATED",
                                                    "ThreadSafeFunction could not be created",
                                                );
                                            }
                                            return err;
                                        };
                                    }

                                    @compileError("Unsupported type: " ++ @typeName(T));
                                }
                                return NapiValue.Array.from_napi_value_with_allocator(env, raw, T, allocator);
                            },
                            .@"struct" => {
                                if (comptime helper.isAbortSignal(T)) {
                                    return AbortSignal.from_napi_value(env, raw);
                                }
                                if (comptime helper.isNapiFunction(T)) {
                                    const fn_infos = @typeInfo(T);
                                    comptime var args_type = void;
                                    comptime var return_type = void;
                                    inline for (fn_infos.@"struct".fields) |field| {
                                        if (comptime std.mem.eql(u8, field.name, "args")) {
                                            args_type = field.type;
                                        }
                                        if (comptime std.mem.eql(u8, field.name, "return_type")) {
                                            return_type = field.type;
                                        }
                                    }
                                    return Function(args_type, return_type).from_raw(env, raw);
                                }
                                if (comptime helper.isTypedArray(T)) {
                                    return wrapperFromNapiValue(T, env, raw);
                                }
                                if (comptime helper.isDataView(T)) {
                                    return wrapperFromNapiValue(T, env, raw);
                                }
                                if (comptime helper.isReference(T)) {
                                    return try T.from_napi_value(env, raw);
                                }
                                if (comptime helper.isExternal(T)) {
                                    // The external converter reports precise diagnostics
                                    // through the error state instead of failing itself.
                                    const converted = T.from_napi_value(env, raw);
                                    if (NapiError.last_error != null or NapiError.hasPendingException()) {
                                        if (NapiError.hasPendingException()) {
                                            return error.PendingException;
                                        }
                                        return error.GenericFailure;
                                    }
                                    return converted;
                                }

                                if (comptime helper.isTuple(T)) {
                                    return NapiValue.Array.from_napi_value_with_allocator(env, raw, T, allocator);
                                }
                                if (comptime helper.isArrayList(T)) {
                                    return NapiValue.Array.from_napi_value_with_allocator(env, raw, T, allocator);
                                }
                                return NapiValue.Object.from_napi_value_with_allocator(env, raw, T, allocator);
                            },
                            .bool => {
                                return NapiValue.Bool.from_napi_value(env, raw, T);
                            },
                            .@"enum" => {
                                if (comptime isStringEnum(T)) {
                                    return enumFromString(env, raw, T, allocator);
                                }
                                return enumFromNumber(env, raw, T);
                            },
                            .optional => {
                                const value_type = try napiTypeOf(env, raw);

                                switch (value_type) {
                                    napi.napi_null, napi.napi_undefined => {
                                        return null;
                                    },
                                    else => {
                                        const converted: infos.optional.child = try Napi.from_napi_value_with_allocator(env, raw, infos.optional.child, allocator);
                                        return converted;
                                    },
                                }
                            },
                            .@"union" => {
                                if (infos.@"union".tag_type == null) {
                                    @compileError("Only tagged union(enum) is supported, got: " ++ @typeName(T));
                                }

                                inline for (infos.@"union".fields) |field| {
                                    if (try valueMatchesType(env, raw, field.type)) {
                                        return @unionInit(T, field.name, try Napi.from_napi_value_with_allocator(env, raw, field.type, allocator));
                                    }
                                }

                                return NapiError.failTypeError("Value does not match any supported variant of {s}", .{helper.shortTypeName(T)});
                            },
                            else => {
                                const hasFromRaw = @hasField(T, "from_raw");
                                if (!hasFromRaw) {
                                    @compileError("Type " ++ @typeName(T) ++ " does not have a from_raw method");
                                }
                                return T.from_raw(env, raw);
                            },
                        }
                    },
                }
            },
        }
    }

    pub fn to_napi_value(env: napi.napi_env, value: anytype, comptime name: ?[]const u8) anyerror!napi.napi_value {
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);

        if (comptime helper.isDts(value_type)) {
            if (comptime !@hasField(value_type, "value")) {
                @compileError("Type-only dts wrappers cannot be converted to JavaScript values");
            }
            return try Napi.to_napi_value_auto(env, value.value, name);
        }

        if (comptime helper.isOwned(value_type)) {
            // Borrow the payload: the owner still releases it after the conversion
            // copied the data into a JavaScript value.
            return try Napi.to_napi_value_auto(env, value.value, name);
        }

        if (comptime NapiError.isResult(value_type)) {
            return switch (value) {
                .ok => |payload| try Napi.to_napi_value_auto(env, payload, name),
                .err => |err| {
                    NapiError.last_error = err;
                    return error.GenericFailure;
                },
            };
        }

        switch (value_type) {
            NapiValue.NapiValue, NapiValue.BigInt, NapiValue.Bool, NapiValue.Number, NapiValue.String, NapiValue.Object, NapiValue.Promise, NapiValue.PromiseValue, NapiValue.Array, NapiValue.Undefined, NapiValue.Null, Buffer, ArrayBuffer, DataView => {
                return value.raw;
            },
            // If value is already a napi_value, return it directly
            napi.napi_value => {
                return value;
            },
            else => {
                if (comptime value_type == type and @typeInfo(value) == .@"enum") {
                    return try enumTypeToObject(env, value);
                }
                switch (infos) {
                    .@"fn" => {
                        const fn_name = name orelse @typeName(value_type);
                        const return_type = infos.@"fn".return_type.?;
                        const args_type = comptime helper.collectFunctionArgs(value_type);
                        const fn_value = try Function(args_type, return_type).New(Env.from_raw(env), fn_name, value);
                        return fn_value.raw;
                    },
                    .null => {
                        return (try NapiValue.Null.create(Env.from_raw(env))).raw;
                    },
                    .undefined, .void => {
                        return (try NapiValue.Undefined.create(Env.from_raw(env))).raw;
                    },
                    .float, .int, .comptime_int, .comptime_float => {
                        const merge_type = switch (value_type) {
                            comptime_int => comptime helper.comptimeIntMode(value),
                            comptime_float => comptime helper.comptimeFloatMode(value),
                            else => value_type,
                        };

                        switch (merge_type) {
                            u128, i128 => {
                                return (try NapiValue.BigInt.create(Env.from_raw(env), value)).raw;
                            },
                            else => {
                                return (try NapiValue.Number.create(Env.from_raw(env), value)).raw;
                            },
                        }
                    },
                    .array, .pointer => {
                        const stringMode = comptime helper.stringLike(value_type);

                        switch (stringMode) {
                            .Utf8 => {
                                if (comptime infos == .array) {
                                    return (try NapiValue.String.createUtf8(Env.from_raw(env), &value)).raw;
                                }
                                return (try NapiValue.String.createUtf8(Env.from_raw(env), value)).raw;
                            },
                            .Utf16 => {
                                if (comptime infos == .array) {
                                    return (try NapiValue.String.createUtf16(Env.from_raw(env), &value)).raw;
                                }
                                return (try NapiValue.String.createUtf16(Env.from_raw(env), value)).raw;
                            },
                            else => {
                                const array = try NapiValue.Array.New(Env.from_raw(env), value);
                                return array.raw;
                            },
                        }
                    },
                    .@"struct" => {
                        if (comptime helper.isNapiFunction(value_type)) {
                            return value.raw;
                        }
                        if (comptime helper.isAsyncDescriptor(value_type)) {
                            @compileError("Async descriptors can only be returned from exported functions");
                        }
                        if (comptime helper.isTypedArray(value_type)) {
                            return value.raw;
                        }
                        if (comptime helper.isThreadSafeFunction(value_type)) {
                            @compileError("ThreadSafeFunction is not supported for to_napi_value");
                        }
                        if (comptime helper.isDataView(value_type)) {
                            return value.raw;
                        }
                        if (comptime helper.isReference(value_type)) {
                            return try value.to_napi_value(env);
                        }
                        if (comptime helper.isExternal(value_type)) {
                            return try value.to_napi_value(env);
                        }
                        if (comptime helper.isTuple(value_type)) {
                            const array = try NapiValue.Array.New(Env.from_raw(env), value);
                            return array.raw;
                        }
                        if (comptime helper.isArrayList(value_type)) {
                            const array = try NapiValue.Array.New(Env.from_raw(env), value);
                            return array.raw;
                        }

                        const object = try NapiValue.Object.New(Env.from_raw(env), value);
                        return object.raw;
                    },
                    .bool => {
                        return (try NapiValue.Bool.create(Env.from_raw(env), value)).raw;
                    },
                    .@"enum" => {
                        if (comptime isStringEnum(value_type)) {
                            return (try NapiValue.String.createUtf8(Env.from_raw(env), @tagName(value))).raw;
                        }
                        return (try NapiValue.Number.create(Env.from_raw(env), @intFromEnum(value))).raw;
                    },
                    .optional => {
                        if (value) |v| {
                            if (@typeInfo(@TypeOf(v)) == .null) {
                                return (try NapiValue.Undefined.create(Env.from_raw(env))).raw;
                            }
                            return Napi.to_napi_value(env, v, name);
                        }
                        return (try NapiValue.Undefined.create(Env.from_raw(env))).raw;
                    },
                    .@"union" => {
                        if (infos.@"union".tag_type == null) {
                            @compileError("Only tagged union(enum) is supported, got: " ++ @typeName(value_type));
                        }

                        return switch (value) {
                            inline else => |payload| try Napi.to_napi_value(env, payload, name),
                        };
                    },
                    else => {
                        const stringMode = comptime helper.stringLike(value_type);
                        switch (stringMode) {
                            .Utf8, .Utf16 => {
                                @compileError("Unsupported string type: " ++ @typeName(value_type));
                            },
                            else => {
                                if (comptime class.isClass(value)) {
                                    return try value.to_napi_value(Env.from_raw(env));
                                }
                                // TODO: Implement this
                                @compileError("Unsupported type: " ++ @typeName(value));
                            },
                        }
                    },
                }
            },
        }
    }
};

// ---------------------------------------------------------------------- tests

test "clone_napi_value rolls back partially cloned values on allocator failure" {
    const Source = struct {
        text: []const u8,
        nested: []const []const u8,
    };

    const backing = std.testing.allocator;
    const inner = try backing.alloc([]const u8, 2);
    defer backing.free(inner);
    inner[0] = try backing.dupe(u8, "first");
    inner[1] = try backing.dupe(u8, "second");
    defer for (inner) |item| backing.free(item);

    const source = Source{
        .text = try backing.dupe(u8, "hello"),
        .nested = inner,
    };
    defer backing.free(source.text);

    // Every induced allocation failure must leave nothing behind; the testing
    // allocator fails the test if a clone leaks.
    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const cloned = Napi.clone_napi_value(Source, source, failing.allocator()) catch continue;
        Napi.deinit_napi_value_with_allocator(Source, cloned, failing.allocator());
    }
}

test "clone_napi_value rolls back partially cloned fixed arrays" {
    const Source = [3][]const u8;
    const source = Source{ "one", "two", "three" };
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const cloned = Napi.clone_napi_value(Source, source, failing.allocator()) catch continue;
        Napi.deinit_napi_value_with_allocator(Source, cloned, failing.allocator());
    }
}

test "clone_napi_value rolls back partially cloned ArrayLists" {
    const Item = struct { name: []const u8 };
    const List = std.ArrayList(Item);

    const backing = std.testing.allocator;
    var source = List.empty;
    defer source.deinit(backing);
    {
        const first = try backing.dupe(u8, "first");
        errdefer backing.free(first);
        try source.append(backing, .{ .name = first });
        const second = try backing.dupe(u8, "second");
        errdefer backing.free(second);
        try source.append(backing, .{ .name = second });
    }
    defer for (source.items) |item| backing.free(item.name);

    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const cloned = Napi.clone_napi_value(List, source, failing.allocator()) catch continue;
        Napi.deinit_napi_value_with_allocator(List, cloned, failing.allocator());
    }
}

test "owned parts are disposed without touching borrowed containers" {
    const Payload = struct {
        borrowed: []const u8,
        owned: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    var disposed: usize = 0;

    const Nested = struct {
        value: []const u8,
        allocator: std.mem.Allocator,
        counter: *usize,

        const Self = @This();
        pub const is_napi_owned = true;
        pub const owned_payload_type = []const u8;

        pub fn init(value: []const u8, allocator_: std.mem.Allocator, counter: *usize) Self {
            return .{ .value = value, .allocator = allocator_, .counter = counter };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.value);
            self.counter.* += 1;
        }
    };

    const value = Payload{
        .borrowed = "literal",
        .owned = try allocator.dupe(u8, "owned"),
    };
    const nested = Nested.init(value.owned.?, allocator, &disposed);

    try std.testing.expect(Napi.containsOwnedValue(Nested));
    try std.testing.expect(!Napi.containsOwnedValue(Payload));

    Napi.disposeOwnedParts(Nested, nested, allocator);
    try std.testing.expectEqual(@as(usize, 1), disposed);
}

test "wrapper construction prefers tryFromRaw when the wrapper declares it" {
    const WithTry = struct {
        used: bool = false,

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) @This() {
            _ = env;
            _ = raw;
            return .{ .used = false };
        }

        pub fn tryFromRaw(env: napi.napi_env, raw: napi.napi_value) !@This() {
            _ = env;
            _ = raw;
            return .{ .used = true };
        }
    };

    const WithoutTry = struct {
        used: bool = false,

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) @This() {
            _ = env;
            _ = raw;
            return .{ .used = false };
        }
    };

    try std.testing.expect((try wrapperFromNapiValue(WithTry, null, null)).used);
    try std.testing.expect(!(try wrapperFromNapiValue(WithoutTry, null, null)).used);
}

test "owned-part cleanup leaves javascript handles, literals and aliases alone" {
    const Holder = struct {
        object: NapiValue.Object,
        text: []const u8,
        aliases: []const []const u8,
    };

    const alias = "alias";
    const value = Holder{
        .object = NapiValue.Object.from_raw(null, null),
        .text = "literal",
        .aliases = &.{ alias, alias },
    };

    // A borrowed value containing a JS handle has no owned parts, so the walk is
    // skipped entirely: the handle, the literal and the alias are never read or
    // released (freeing any of them would be reported by the testing allocator).
    try std.testing.expect(!Napi.containsOwnedValue(Holder));
    Napi.disposeOwnedParts(Holder, value, std.testing.allocator);
}
