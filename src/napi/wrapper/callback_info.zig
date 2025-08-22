const std = @import("std");
const napi = @import("../../sys/api.zig");
const value = @import("../value.zig");
const NapiEnv = @import("../env.zig").Env;

pub const CallbackInfo = struct {
    raw: napi.napi_callback_info,
    env: napi.napi_env,
    args: []const value.NapiValue,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_callback_info) CallbackInfo {
        var init_argc: usize = 0;
        const status = napi.napi_get_cb_info(env, raw, &init_argc, null, null, null);
        if (status != napi.napi_ok) {
            @panic("Failed to get callback info");
        }

        const allocator = std.heap.page_allocator;
        const args_raw = allocator.alloc(napi.napi_value, init_argc) catch @panic("OOM");
        defer allocator.free(args_raw);

        const status2 = napi.napi_get_cb_info(env, raw, &init_argc, args_raw.ptr, null, null);
        if (status2 != napi.napi_ok) {
            @panic("Failed to get callback info");
        }

        const result = allocator.alloc(value.NapiValue, init_argc) catch @panic("OOM");

        for (0..init_argc) |i| {
            result[i] = value.NapiValue.from_raw(env, args_raw[i]);
        }

        return CallbackInfo{
            .raw = raw,
            .env = env,
            .args = result,
        };
    }

    pub fn Env(self: CallbackInfo) NapiEnv {
        return NapiEnv.from_raw(self.env);
    }

    pub fn Get(self: CallbackInfo, index: usize) value.NapiValue {
        return self.args[index];
    }
};
