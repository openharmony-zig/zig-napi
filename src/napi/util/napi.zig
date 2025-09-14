const napi = @import("napi-sys");
const NapiValue = @import("../value.zig");
const helper = @import("./helper.zig");
const Env = @import("../env.zig").Env;

pub const Napi = struct {
    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value, comptime T: type) T {
        const infos = @typeInfo(T);
        switch (T) {
            NapiValue.BigInt, NapiValue.Number, NapiValue.String, NapiValue.Function, NapiValue.Object, NapiValue.Promise, NapiValue.Array => {
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
                                return NapiValue.Null.New(Env.from_raw(env)).raw;
                            },
                            .undefined => {
                                return NapiValue.Undefined.New(Env.from_raw(env)).raw;
                            },
                            .float, .int => {
                                return NapiValue.Number.from_napi_value(env, raw, T);
                            },
                            .array, .pointer => {
                                return NapiValue.Array.from_napi_value(env, raw, T);
                            },
                            .@"struct" => {
                                if (comptime helper.isTuple(T)) {
                                    return NapiValue.Array.from_napi_value(env, raw, T);
                                }
                                if (comptime helper.isGenericType(T, "ArrayList")) {
                                    return NapiValue.Array.from_napi_value(env, raw, T);
                                }
                                return NapiValue.Object.from_napi_value(env, raw, T);
                            },
                            .bool => {
                                return NapiValue.Bool.from_napi_value(env, raw, T);
                            },
                            .optional => {
                                const optional_info = @typeInfo(T).optional;
                                const child_info = @typeInfo(optional_info.child);
                                switch (child_info) {
                                    .null => {
                                        return NapiValue.Null.New(Env.from_raw(env)).raw;
                                    },
                                    .undefined, .void => {
                                        return NapiValue.Undefined.New(Env.from_raw(env)).raw;
                                    },
                                    else => {
                                        return Napi.from_napi_value(env, raw, optional_info.child);
                                    },
                                }
                            },
                            else => {
                                const hasFromRaw = @hasField(T, "from_raw");
                                if (!hasFromRaw) {
                                    @compileError("Type " ++ @typeName(T) ++ " does not have a from_raw method");
                                }
                            },
                        }
                    },
                }
            },
        }
    }

    pub fn to_napi_value(env: napi.napi_env, value: anytype) napi.napi_value {
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);

        switch (value_type) {
            NapiValue.BigInt, NapiValue.Bool, NapiValue.Number, NapiValue.String, NapiValue.Function, NapiValue.Object, NapiValue.Promise, NapiValue.Array => {
                return value.raw;
            },
            // If value is already a napi_value, return it directly
            napi.napi_value => {
                return value;
            },
            else => {
                switch (infos) {
                    .@"fn" => {
                        return NapiValue.Function.New(Env.from_raw(env), value).raw;
                    },
                    .null => {
                        return NapiValue.Null.New(Env.from_raw(env)).raw;
                    },
                    .undefined, .void => {
                        return NapiValue.Undefined.New(Env.from_raw(env)).raw;
                    },
                    .float, .int => {
                        switch (value_type) {
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
                                return NapiValue.Array.New(Env.from_raw(env), value).raw;
                            },
                        }
                    },
                    .@"struct" => {
                        if (comptime helper.isTuple(value_type)) {
                            return NapiValue.Array.New(Env.from_raw(env), value).raw;
                        }
                        if (comptime helper.isGenericType(value_type, "ArrayList")) {
                            return NapiValue.Array.New(Env.from_raw(env), value).raw;
                        }
                        return NapiValue.Object.New(Env.from_raw(env), value).raw;
                    },
                    .bool => {
                        return NapiValue.Bool.New(Env.from_raw(env), value).raw;
                    },
                    .optional => {
                        if (value == null) {
                            return NapiValue.Undefined.New(Env.from_raw(env)).raw;
                        }
                        return Napi.to_napi_value(env, value);
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

                                // TODO: Implement this
                                @compileError("Unsupported type: " ++ @typeName(value_type));
                            },
                        }
                    },
                }
            },
        }
    }
};
