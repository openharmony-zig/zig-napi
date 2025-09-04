const napi = @import("../../sys/api.zig");
const NapiValue = @import("../value.zig");
const helper = @import("./helper.zig");

pub const Napi = struct {
    pub fn from_napi_value(env: napi.napi_env, raw: napi.napi_value) NapiValue {
        return NapiValue.from_raw(env, raw);
    }

    pub fn to_napi_value(env: napi.napi_env, value: anytype) NapiValue.Value {
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);

        switch (value_type) {
            .NapiValue.NapiValue.BigInt => {
                return NapiValue.Value{ .BigInt = value };
            },
            .NapiValue.NapiValue.Number => {
                return NapiValue.Value{ .Number = value };
            },
            .NapiValue.NapiValue.String => {
                return NapiValue.Value{ .String = value };
            },
            .NapiValue.NapiValue.Function => {
                return NapiValue.Value{ .Function = value };
            },
            .NapiValue.NapiValue.Object => {
                return NapiValue.Value{ .Object = value };
            },
            else => {
                switch (infos) {
                    .@"fn" => {
                        return NapiValue.Value{ .Function = NapiValue.Function.New(env, value) };
                    },
                    .null => {
                        return NapiValue.Value{ .Null = NapiValue.Null.New(env) };
                    },
                    .undefined => {
                        return NapiValue.Value{ .Undefined = NapiValue.Undefined.New(env) };
                    },
                    .float, .int => {
                        switch (value_type) {
                            u128, i128 => {
                                return NapiValue.Value{ .BigInt = NapiValue.BigInt.New(env, value) };
                            },
                            else => {
                                return NapiValue.Value{ .Number = NapiValue.Number.New(env, value) };
                            },
                        }
                    },
                    else => {
                        const isString = helper.isString(value);
                        switch (isString) {
                            .true => {
                                return NapiValue.Value{ .String = NapiValue.String.New(env, value) };
                            },
                            .false => {},
                        }
                    },
                }
            },
        }
    }
};
