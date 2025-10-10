const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const NapiValue = @import("../value.zig");
const helper = @import("./helper.zig");
const Env = @import("../env.zig").Env;
const NapiError = @import("../wrapper/error.zig");
const Function = @import("../value/function.zig").Function;
const ThreadSafeFunction = @import("../wrapper/thread_safe_function.zig").ThreadSafeFunction;
const class = @import("../wrapper/class.zig");

pub const Napi = struct {
    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const infos = @typeInfo(T);
        switch (T) {
            NapiValue.BigInt, NapiValue.Number, NapiValue.String, NapiValue.Object, NapiValue.Promise, NapiValue.Array, NapiValue.Undefined, NapiValue.Null => {
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
                            .optional => {
                                var value_type: napi.napi_valuetype = undefined;

                                _ = napi.napi_typeof(env, raw, &value_type);

                                switch (value_type) {
                                    napi.napi_null, napi.napi_undefined => {
                                        return null;
                                    },
                                    else => {
                                        return Napi.from_napi_value(env, raw, T);
                                    },
                                }
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
            NapiValue.BigInt, NapiValue.Bool, NapiValue.Number, NapiValue.String, NapiValue.Object, NapiValue.Promise, NapiValue.Array, NapiValue.Undefined, NapiValue.Null => {
                return value.raw;
            },
            // If value is already a napi_value, return it directly
            napi.napi_value => {
                return value;
            },
            else => {
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
                        if (comptime helper.isThreadSafeFunction(value_type)) {
                            @compileError("ThreadSafeFunction is not supported for to_napi_value");
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
                    .optional => {
                        if (value) |v| {
                            if (@typeInfo(@TypeOf(v)) == .null) {
                                return NapiValue.Undefined.New(Env.from_raw(env)).raw;
                            }
                            return Napi.to_napi_value(env, v, name);
                        }
                        return NapiValue.Undefined.New(Env.from_raw(env)).raw;
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
