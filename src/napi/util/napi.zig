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

fn napiTypeOf(env: napi.napi_env, raw: napi.napi_value) napi.napi_valuetype {
    var value_type: napi.napi_valuetype = undefined;
    _ = napi.napi_typeof(env, raw, &value_type);
    return value_type;
}

fn isArrayValue(env: napi.napi_env, raw: napi.napi_value) bool {
    var result = false;
    _ = napi.napi_is_array(env, raw, &result);
    return result;
}

fn isBufferValue(env: napi.napi_env, raw: napi.napi_value) bool {
    var result = false;
    _ = napi.napi_is_buffer(env, raw, &result);
    return result;
}

fn isArrayBufferValue(env: napi.napi_env, raw: napi.napi_value) bool {
    var result = false;
    _ = napi.napi_is_arraybuffer(env, raw, &result);
    return result;
}

fn isTypedArrayValue(env: napi.napi_env, raw: napi.napi_value) bool {
    var result = false;
    _ = napi.napi_is_typedarray(env, raw, &result);
    return result;
}

fn typedArrayValueMatchesType(env: napi.napi_env, raw: napi.napi_value, comptime T: type) bool {
    if (!isTypedArrayValue(env, raw)) return false;
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
    return status == napi.napi_ok and actual_type == @field(T, "raw_typedarray_type");
}

fn isDataViewValue(env: napi.napi_env, raw: napi.napi_value) bool {
    var result = false;
    _ = napi.napi_is_dataview(env, raw, &result);
    return result;
}

fn isPromiseValue(env: napi.napi_env, raw: napi.napi_value) bool {
    var result = false;
    _ = napi.napi_is_promise(env, raw, &result);
    return result;
}

fn isPlainObjectValue(env: napi.napi_env, raw: napi.napi_value) bool {
    if (napiTypeOf(env, raw) != napi.napi_object) return false;
    if (isArrayValue(env, raw)) return false;
    if (isBufferValue(env, raw)) return false;
    if (isArrayBufferValue(env, raw)) return false;
    if (isTypedArrayValue(env, raw)) return false;
    if (isDataViewValue(env, raw)) return false;
    if (isPromiseValue(env, raw)) return false;
    return true;
}

fn unionDefaultValue(comptime T: type) T {
    const union_info = @typeInfo(T).@"union";
    if (union_info.fields.len == 0) {
        @compileError("Union must contain at least one field");
    }

    const first = union_info.fields[0];
    return @unionInit(T, first.name, undefined);
}

fn isStringEnum(comptime T: type) bool {
    return @hasDecl(T, "napi_string_enum") and @TypeOf(@field(T, "napi_string_enum")) == bool and @field(T, "napi_string_enum");
}

fn enumFromString(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
    const enum_info = @typeInfo(T).@"enum";
    const value = NapiValue.String.from_napi_value(env, raw, []const u8);

    inline for (enum_info.fields) |field| {
        if (std.mem.eql(u8, value, field.name)) {
            return @field(T, field.name);
        }
    }

    NapiError.last_error = NapiError.Error{ .JsTypeError = NapiError.JsTypeError.fromMessage("Invalid enum value") };
    return @field(T, enum_info.fields[0].name);
}

fn enumFromNumber(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
    const enum_info = @typeInfo(T).@"enum";
    const Tag = enum_info.tag_type;
    const value = NapiValue.Number.from_napi_value(env, raw, Tag);

    inline for (enum_info.fields) |field| {
        if (value == @as(Tag, @intCast(field.value))) {
            return @field(T, field.name);
        }
    }

    NapiError.last_error = NapiError.Error{ .JsTypeError = NapiError.JsTypeError.fromMessage("Invalid enum value") };
    return @field(T, enum_info.fields[0].name);
}

fn enumTypeToObject(env: napi.napi_env, comptime E: type) !napi.napi_value {
    var raw: napi.napi_value = undefined;
    const status = napi.napi_create_object(env, &raw);
    if (status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(status));
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

fn valueMatchesType(env: napi.napi_env, raw: napi.napi_value, comptime T: type) bool {
    switch (T) {
        NapiValue.Number => return napiTypeOf(env, raw) == napi.napi_number,
        NapiValue.String => return napiTypeOf(env, raw) == napi.napi_string,
        NapiValue.NapiValue => return true,
        NapiValue.BigInt => {
            comptime options.requireNapiVersion(.v6);
            return napiTypeOf(env, raw) == napi.napi_bigint;
        },
        NapiValue.Bool => return napiTypeOf(env, raw) == napi.napi_boolean,
        NapiValue.Object => return isPlainObjectValue(env, raw),
        NapiValue.Promise => return isPromiseValue(env, raw),
        NapiValue.Array => return isArrayValue(env, raw) or isTypedArrayValue(env, raw),
        NapiValue.Undefined => return napiTypeOf(env, raw) == napi.napi_undefined,
        NapiValue.Null => return napiTypeOf(env, raw) == napi.napi_null,
        Buffer => return isBufferValue(env, raw),
        ArrayBuffer => return isArrayBufferValue(env, raw),
        DataView => return isDataViewValue(env, raw),
        else => {},
    }

    const string_mode = comptime helper.stringLike(T);
    if (string_mode != .Unknown) {
        return napiTypeOf(env, raw) == napi.napi_string;
    }

    const infos = @typeInfo(T);
    return switch (infos) {
        .float, .int, .comptime_int, .comptime_float => napiTypeOf(env, raw) == napi.napi_number,
        .bool => napiTypeOf(env, raw) == napi.napi_boolean,
        .array => isArrayValue(env, raw) or isTypedArrayValue(env, raw),
        .pointer => helper.isSlice(T) and (isArrayValue(env, raw) or isTypedArrayValue(env, raw)),
        .optional => blk: {
            const value_type = napiTypeOf(env, raw);
            if (value_type == napi.napi_null or value_type == napi.napi_undefined) {
                break :blk true;
            }
            break :blk valueMatchesType(env, raw, infos.optional.child);
        },
        .@"struct" => blk: {
            if (comptime helper.isAbortSignal(T)) break :blk napiTypeOf(env, raw) == napi.napi_object;
            if (comptime helper.isNapiFunction(T)) break :blk napiTypeOf(env, raw) == napi.napi_function;
            if (comptime helper.isTypedArray(T)) break :blk typedArrayValueMatchesType(env, raw, T);
            if (comptime helper.isDataView(T)) break :blk isDataViewValue(env, raw);
            if (comptime helper.isReference(T)) break :blk true;
            if (comptime helper.isExternal(T)) break :blk T.matches_napi_value(env, raw);
            if (comptime helper.isTuple(T)) break :blk isArrayValue(env, raw);
            if (comptime helper.isArrayList(T)) break :blk isArrayValue(env, raw) or isTypedArrayValue(env, raw);
            break :blk isPlainObjectValue(env, raw);
        },
        .@"union" => infos.@"union".tag_type != null,
        .@"enum" => if (comptime isStringEnum(T)) napiTypeOf(env, raw) == napi.napi_string else napiTypeOf(env, raw) == napi.napi_number,
        else => false,
    };
}

pub const Napi = struct {
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

    pub fn from_napi_value_fast(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        switch (@typeInfo(T)) {
            .bool => {
                var result: bool = false;
                const status = napi.napi_get_value_bool(env, raw, &result);
                if (status != napi.napi_ok) {
                    NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(status));
                }
                return result;
            },
            .float => {
                var result: f64 = 0;
                const status = napi.napi_get_value_double(env, raw, &result);
                if (status != napi.napi_ok) {
                    NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(status));
                }
                return @floatCast(result);
            },
            .int => |int| {
                if (int.signedness == .signed) {
                    if (int.bits <= 32) {
                        var result: i32 = 0;
                        const status = napi.napi_get_value_int32(env, raw, &result);
                        if (status != napi.napi_ok) {
                            NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(status));
                        }
                        return @intCast(result);
                    }

                    var result: i64 = 0;
                    const status = napi.napi_get_value_int64(env, raw, &result);
                    if (status != napi.napi_ok) {
                        NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(status));
                    }
                    return @intCast(result);
                }

                if (int.bits <= 32) {
                    var result: u32 = 0;
                    const status = napi.napi_get_value_uint32(env, raw, &result);
                    if (status != napi.napi_ok) {
                        NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(status));
                    }
                    return @intCast(result);
                }

                var result: i64 = 0;
                const status = napi.napi_get_value_int64(env, raw, &result);
                if (status != napi.napi_ok) {
                    NapiError.last_error = NapiError.Error.withStatus(NapiError.Status.New(status));
                }
                return @intCast(result);
            },
            else => @compileError("Unsupported fast from_napi_value type: " ++ @typeName(T)),
        }
    }

    pub fn from_napi_value_auto(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        if (comptime Napi.canFastFrom(T)) {
            return Napi.from_napi_value_fast(env, raw, T);
        }
        return Napi.from_napi_value(env, raw, T);
    }

    pub fn to_napi_value_fast(env: napi.napi_env, value: anytype) napi.napi_value {
        const T = @TypeOf(value);
        const value_type = switch (T) {
            comptime_int => comptime helper.comptimeIntMode(value),
            comptime_float => comptime helper.comptimeFloatMode(value),
            else => T,
        };

        switch (@typeInfo(value_type)) {
            .bool => {
                var raw: napi.napi_value = undefined;
                _ = napi.napi_get_boolean(env, value, &raw);
                return raw;
            },
            .float => {
                var raw: napi.napi_value = undefined;
                _ = napi.napi_create_double(env, @floatCast(value), &raw);
                return raw;
            },
            .int => |int| {
                var raw: napi.napi_value = undefined;
                if (int.signedness == .signed) {
                    if (int.bits <= 32) {
                        _ = napi.napi_create_int32(env, @intCast(value), &raw);
                    } else {
                        _ = napi.napi_create_int64(env, @intCast(value), &raw);
                    }
                } else {
                    if (int.bits <= 32) {
                        _ = napi.napi_create_uint32(env, @intCast(value), &raw);
                    } else {
                        _ = napi.napi_create_int64(env, @intCast(value), &raw);
                    }
                }
                return raw;
            },
            else => @compileError("Unsupported fast to_napi_value type: " ++ @typeName(T)),
        }
    }

    pub fn to_napi_value_auto(env: napi.napi_env, value: anytype, comptime name: ?[]const u8) !napi.napi_value {
        if (comptime Napi.canFastTo(@TypeOf(value))) {
            return Napi.to_napi_value_fast(env, value);
        }
        return try Napi.to_napi_value(env, value, name);
    }

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

    pub fn deinit_napi_value_with_state(comptime T: type, value: T, state: *DeinitState) void {
        const allocator = GlobalAllocator.globalAllocator();
        const infos = @typeInfo(T);

        const string_mode = comptime helper.stringLike(T);
        if (string_mode != .Unknown) {
            if (infos == .pointer and infos.pointer.size == .slice) {
                const bytes = std.mem.sliceAsBytes(value);
                if (state.shouldFree(@intFromPtr(bytes.ptr), bytes.len)) {
                    allocator.free(value);
                }
            }
            return;
        }

        switch (infos) {
            .array => {
                for (value) |item| {
                    Napi.deinit_napi_value_with_state(infos.array.child, item, state);
                }
            },
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    for (value) |item| {
                        Napi.deinit_napi_value_with_state(ptr.child, item, state);
                    }
                    const bytes = std.mem.sliceAsBytes(value);
                    if (state.shouldFree(@intFromPtr(bytes.ptr), bytes.len)) {
                        allocator.free(value);
                    }
                }
            },
            .optional => |optional| {
                if (value) |payload| {
                    Napi.deinit_napi_value_with_state(optional.child, payload, state);
                }
            },
            .@"struct" => {
                if (comptime helper.isNapiFunction(T) or
                    helper.isTypedArray(T) or
                    helper.isDataView(T) or
                    helper.isReference(T) or
                    helper.isExternal(T) or
                    helper.isAbortSignal(T) or
                    T == NapiValue.NapiValue or
                    T == NapiValue.BigInt or
                    T == NapiValue.Bool or
                    T == NapiValue.Number or
                    T == NapiValue.String or
                    T == NapiValue.Object or
                    T == NapiValue.Promise or
                    T == NapiValue.Array or
                    T == NapiValue.Undefined or
                    T == NapiValue.Null or
                    T == Buffer or
                    T == ArrayBuffer or
                    T == DataView)
                {
                    return;
                }

                if (comptime helper.isArrayList(T)) {
                    const child = comptime helper.getArrayListElementType(T);
                    for (value.items) |item| {
                        Napi.deinit_napi_value_with_state(child, item, state);
                    }
                    var mutable = value;
                    mutable.deinit(allocator);
                    return;
                }

                if (Napi.deinitWithCustomStructDeinit(T, value, allocator)) {
                    return;
                }

                inline for (infos.@"struct".fields) |field| {
                    Napi.deinit_napi_value_with_state(field.type, @field(value, field.name), state);
                }
            },
            .@"union" => |union_info| {
                if (union_info.tag_type == null) return;
                switch (value) {
                    inline else => |payload| Napi.deinit_napi_value_with_state(@TypeOf(payload), payload, state),
                }
            },
            else => {},
        }
    }

    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const infos = @typeInfo(T);
        switch (T) {
            NapiValue.NapiValue, NapiValue.BigInt, NapiValue.Number, NapiValue.String, NapiValue.Object, NapiValue.Promise, NapiValue.Array, NapiValue.Undefined, NapiValue.Null, Buffer, ArrayBuffer, DataView => {
                return T.from_raw(env, raw);
            },
            else => {
                const stringMode = comptime helper.stringLike(T);
                switch (stringMode) {
                    .Utf8 => {
                        return NapiValue.String.from_napi_value(env, raw, T);
                    },
                    .Utf16 => {
                        return NapiValue.String.from_napi_value(env, raw, T);
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
                                return NapiValue.Number.from_napi_value(env, raw, T);
                            },
                            .array => {
                                return NapiValue.Array.from_napi_value(env, raw, T);
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
                                        return ThreadSafeFunction(args_type, return_type, thread_safe_function_call_variant, max_queue_size).from_raw(env, raw);
                                    }

                                    @compileError("Unsupported type: " ++ @typeName(T));
                                }
                                return NapiValue.Array.from_napi_value(env, raw, T);
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
                                    return T.from_raw(env, raw);
                                }
                                if (comptime helper.isDataView(T)) {
                                    return T.from_raw(env, raw);
                                }
                                if (comptime helper.isReference(T)) {
                                    return T.from_napi_value(env, raw);
                                }
                                if (comptime helper.isExternal(T)) {
                                    return T.from_napi_value(env, raw);
                                }

                                if (comptime helper.isTuple(T)) {
                                    return NapiValue.Array.from_napi_value(env, raw, T);
                                }
                                if (comptime helper.isArrayList(T)) {
                                    return NapiValue.Array.from_napi_value(env, raw, T);
                                }
                                return NapiValue.Object.from_napi_value(env, raw, T);
                            },
                            .bool => {
                                return NapiValue.Bool.from_napi_value(env, raw, T);
                            },
                            .@"enum" => {
                                if (comptime isStringEnum(T)) {
                                    return enumFromString(env, raw, T);
                                }
                                return enumFromNumber(env, raw, T);
                            },
                            .optional => {
                                const value_type = napiTypeOf(env, raw);

                                switch (value_type) {
                                    napi.napi_null, napi.napi_undefined => {
                                        return null;
                                    },
                                    else => {
                                        return Napi.from_napi_value(env, raw, infos.optional.child);
                                    },
                                }
                            },
                            .@"union" => {
                                if (infos.@"union".tag_type == null) {
                                    @compileError("Only tagged union(enum) is supported, got: " ++ @typeName(T));
                                }

                                inline for (infos.@"union".fields) |field| {
                                    if (valueMatchesType(env, raw, field.type)) {
                                        return @unionInit(T, field.name, Napi.from_napi_value(env, raw, field.type));
                                    }
                                }

                                NapiError.last_error = NapiError.Error{ .JsTypeError = NapiError.JsTypeError.fromMessage("Value does not match any supported union variant") };
                                return unionDefaultValue(T);
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

    pub fn to_napi_value(env: napi.napi_env, value: anytype, comptime name: ?[]const u8) !napi.napi_value {
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);

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
            NapiValue.NapiValue, NapiValue.BigInt, NapiValue.Bool, NapiValue.Number, NapiValue.String, NapiValue.Object, NapiValue.Promise, NapiValue.Array, NapiValue.Undefined, NapiValue.Null, Buffer, ArrayBuffer, DataView => {
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
                        return NapiValue.Null.New(Env.from_raw(env)).raw;
                    },
                    .undefined, .void => {
                        return NapiValue.Undefined.New(Env.from_raw(env)).raw;
                    },
                    .float, .int, .comptime_int, .comptime_float => {
                        const merge_type = switch (value_type) {
                            comptime_int => comptime helper.comptimeIntMode(value),
                            comptime_float => comptime helper.comptimeFloatMode(value),
                            else => value_type,
                        };

                        switch (merge_type) {
                            u128, i128 => {
                                return NapiValue.BigInt.New(Env.from_raw(env), value).raw;
                            },
                            else => {
                                return NapiValue.Number.New(Env.from_raw(env), value).raw;
                            },
                        }
                    },
                    .array, .pointer => {
                        const stringMode = comptime helper.stringLike(value_type);

                        switch (stringMode) {
                            .Utf8 => {
                                return NapiValue.String.New(Env.from_raw(env), value).raw;
                            },
                            .Utf16 => {
                                return NapiValue.String.New(Env.from_raw(env), value).raw;
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
                        return NapiValue.Bool.New(Env.from_raw(env), value).raw;
                    },
                    .@"enum" => {
                        if (comptime isStringEnum(value_type)) {
                            return NapiValue.String.New(Env.from_raw(env), @tagName(value)).raw;
                        }
                        return NapiValue.Number.New(Env.from_raw(env), @intFromEnum(value)).raw;
                    },
                    .optional => {
                        if (value) |v| {
                            if (@typeInfo(@TypeOf(v)) == .null) {
                                return NapiValue.Undefined.New(Env.from_raw(env)).raw;
                            }
                            return Napi.to_napi_value(env, v, name);
                        }
                        return NapiValue.Undefined.New(Env.from_raw(env)).raw;
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
                            .Utf8 => {
                                return NapiValue.String.New(Env.from_raw(env), value).raw;
                            },
                            .Utf16 => {
                                return NapiValue.String.New(Env.from_raw(env), value).raw;
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
