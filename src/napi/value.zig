const napi = @import("napi").napi_sys;

pub const Object = @import("./value/object.zig").Object;
pub const Number = @import("./value/number.zig").Number;
pub const String = @import("./value/string.zig").String;
pub const Function = @import("./value/function.zig").Function;
pub const BigInt = @import("./value/bigint.zig").BigInt;
pub const Null = @import("./value/null.zig").Null;
pub const Undefined = @import("./value/undefined.zig").Undefined;

pub const NapiValue = struct {
    env: napi.napi_env,
    raw: napi.napi_value,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) NapiValue {
        return NapiValue{
            .env = env,
            .raw = raw,
        };
    }

    pub fn As(self: NapiValue, comptime T: type) T {
        return T.from_raw(self.env, self.raw);
    }
};

pub const Value = union(enum) {
    Object: Object,
    Number: Number,
    String: String,
    Function: Function,
    BigInt: BigInt,
    Null: Null,
    Undefined: Undefined,

    pub fn to_napi_value(self: Value) napi.napi_value {
        switch (self) {
            .Object => {
                return self.Object.raw;
            },
            .Number => {
                return self.Number.raw;
            },
            .BigInt => {
                return self.BigInt.raw;
            },
            .Null => {
                return self.Null.raw;
            },
            .Undefined => {
                return self.Undefined.raw;
            },
            .String => {
                return self.String.raw;
            },
            .Function => {
                return self.Function.raw;
            },
        }
    }
};
