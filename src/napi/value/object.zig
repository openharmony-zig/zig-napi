const napi = @import("../../sys/api.zig").napi;
const Function = @import("../wrapper/Function.zig").Function;
const Env = @import("../env.zig").Env;
const CallbackInfo = @import("../wrapper/callback_info.zig").CallbackInfo;
const Number = @import("./number.zig").Number;
const std = @import("std");
const Value = @import("../value.zig").Value;

pub const Object = struct {
    env: napi.napi_env,
    raw: napi.napi_value,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Object {
        return Object{
            .env = env,
            .raw = raw,
        };
    }

    pub fn Set(self: Object, comptime key: []const u8, value: anytype) void {
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);

        switch (value_type) {
            Object => {
                napi.napi_set_property(self.raw, key, value.raw);
            },
            else => {
                switch (infos) {
                    .@"fn" => {
                        const params = infos.@"fn".params;
                        const return_type = infos.@"fn".return_type;

                        const FnImpl = struct {
                            fn inner_fn(env: napi.napi_env, info: napi.napi_callback_info) callconv(.C) napi.napi_value {
                                const callback_info = CallbackInfo.from_raw(env, info);
                                if (params.len == 0) {
                                    if (return_type == null or return_type.? == void) {
                                        value();
                                    } else if (return_type.? == Value) {
                                        const ret = value();
                                        switch (ret) {
                                            Value.Number => {
                                                return ret.Number.raw;
                                            },
                                            Value.Object => {
                                                return ret.Object.raw;
                                            },
                                        }
                                    } else {
                                        @compileError("unsupported function return type: " ++ @typeName(return_type.?));
                                    }
                                } else if (params.len == 1 and params[0].type.? == CallbackInfo) {
                                    if (return_type == null or return_type.? == void) {
                                        value(callback_info);
                                    } else if (return_type.? == Value) {
                                        const result = value(callback_info);
                                        switch (result) {
                                            Value.Number => {
                                                return result.Number.raw;
                                            },
                                            Value.Object => {
                                                return result.Object.raw;
                                            },
                                        }
                                    } else {
                                        @compileError("unsupported function return type: " ++ @typeName(return_type.?));
                                    }
                                } else {
                                    @compileError("unsupported function signature");
                                }
                            }
                        };
                        const desc = [_]napi.napi_property_descriptor{
                            .{
                                .utf8name = @ptrCast(key.ptr),
                                .method = FnImpl.inner_fn,
                                .getter = null,
                                .setter = null,
                                .value = null,
                                .attributes = napi.napi_default,
                                .data = null,
                            },
                        };
                        const status = napi.napi_define_properties(self.env, self.raw, 1, &desc);
                        if (status != napi.napi_ok) {
                            @panic("Failed to define properties");
                        }
                    },
                    else => {},
                }
            },
        }
    }
};
