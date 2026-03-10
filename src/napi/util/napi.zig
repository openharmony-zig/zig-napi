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
            if (comptime helper.isNapiFunction(T)) break :blk napiTypeOf(env, raw) == napi.napi_function;
            if (comptime helper.isTypedArray(T)) break :blk isTypedArrayValue(env, raw);
            if (comptime helper.isDataView(T)) break :blk isDataViewValue(env, raw);
            if (comptime helper.isReference(T)) break :blk true;
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
    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const infos = @typeInfo(T);
        switch (T) {
            NapiValue.BigInt, NapiValue.Number, NapiValue.String, NapiValue.Object, NapiValue.Promise, NapiValue.Array, NapiValue.Undefined, NapiValue.Null, Buffer, ArrayBuffer, DataView => {
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

        switch (value_type) {
            NapiValue.BigInt, NapiValue.Bool, NapiValue.Number, NapiValue.String, NapiValue.Object, NapiValue.Promise, NapiValue.Array, NapiValue.Undefined, NapiValue.Null, Buffer, ArrayBuffer, DataView => {
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
