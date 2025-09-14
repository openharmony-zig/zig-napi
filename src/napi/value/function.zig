const std = @import("std");
const napi = @import("napi-sys");
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

        if (infos != .@"fn") {
            @compileError("Function.New only support function type, Unsupported type: " ++ @typeName(value_type));
        }

        const FnImpl = struct {
            fn inner_fn(inner_env: napi.napi_env, info: napi.napi_callback_info) callconv(.C) napi.napi_value {
                var init_argc: usize = params.len;

                const allocator = std.heap.page_allocator;
                const args_raw = allocator.alloc(napi.napi_value, init_argc) catch @panic("OOM");
                defer allocator.free(args_raw);

                _ = napi.napi_get_cb_info(inner_env, info, &init_argc, args_raw.ptr, null, null);

                const has_env = comptime params[0].type.? == Env;
                const env_index = if (has_env) 1 else 0;

                var napi_params: std.meta.ArgsTuple(value_type) = undefined;
                if (comptime has_env) {
                    napi_params[0] = Env.from_raw(inner_env);
                }

                inline for (params[env_index..], env_index..) |param_index, i| {
                    napi_params[i] = Napi.from_napi_value(inner_env, args_raw[i - env_index], param_index.type.?);
                }

                const ret = @call(.auto, value, napi_params);
                return Napi.to_napi_value(inner_env, ret);
            }
        };

        var result: napi.napi_value = undefined;
        _ = napi.napi_create_function(env.raw, @ptrCast(name.ptr), 0, FnImpl.inner_fn, null, &result);
        var func = Function.from_raw(env.raw, result);
        func.inner_fn = FnImpl.inner_fn;
        return func;
    }
};
