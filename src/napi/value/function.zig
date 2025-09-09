const std = @import("std");
const napi = @import("../../sys/api.zig");
const Env = @import("../env.zig").Env;
const CallbackInfo = @import("../wrapper/callback_info.zig").CallbackInfo;
const Napi = @import("../util/napi.zig").Napi;

pub const Function = struct {
    env: napi.napi_env,
    raw: napi.napi_value,
    type: napi.napi_valuetype,

    inner_fn: ?*const fn (inner_env: napi.napi_env, info: napi.napi_callback_info) callconv(.C) napi.napi_value,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) Function {
        return Function{ .env = env, .raw = raw, .type = napi.napi_function, .inner_fn = null };
    }

    pub fn New(env: Env, comptime name: []const u8, value: anytype) Function {
        const value_type = @TypeOf(value);
        const infos = @typeInfo(value_type);
        const params = infos.@"fn".params;
        const return_type = infos.@"fn".return_type;

        if (infos != .@"fn") {
            @compileError("Function.New only support function type, Unsupported type: " ++ @typeName(value_type));
        }

        const FnImpl = struct {
            fn inner_fn(inner_env: napi.napi_env, info: napi.napi_callback_info) callconv(.C) napi.napi_value {
                const callback_info = CallbackInfo.from_raw(inner_env, info);
                if (params.len == 0) {
                    if (return_type == null or return_type.? == void) {
                        value();
                        return Napi.to_napi_value(inner_env, undefined);
                    } else {
                        const ret = value();
                        return Napi.to_napi_value(inner_env, ret) orelse @panic("Failed to convert result to napi_value");
                    }
                } else if (params.len == 1 and params[0].type.? == CallbackInfo) {
                    if (return_type == null or return_type.? == void) {
                        value(callback_info);
                        return Napi.to_napi_value(inner_env, undefined);
                    } else {
                        const result = value(callback_info);
                        return Napi.to_napi_value(inner_env, result) orelse @panic("Failed to convert result to napi_value");
                    }
                } else {
                    @compileError("unsupported function signature");
                }
            }
        };

        var result: napi.napi_value = undefined;
        _ = napi.napi_create_function(env.raw, @ptrCast(name.ptr), 0, FnImpl.inner_fn, null, &result);
        var func = Function.from_raw(env.raw, result);
        func.inner_fn = FnImpl.inner_fn;
        return func;
    }
};
