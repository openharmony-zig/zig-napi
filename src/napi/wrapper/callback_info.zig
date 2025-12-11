const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const value = @import("../value.zig");
const NapiEnv = @import("../env.zig").Env;
const GlobalAllocator = @import("../util/allocator.zig");

pub const CallbackInfo = struct {
    raw: napi.napi_callback_info,
    env: napi.napi_env,
    args: []const value.NapiValue,
    args_raw: []napi.napi_value,
    args_count: usize,
    this: napi.napi_value,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_callback_info) CallbackInfo {
        var init_argc: usize = 0;
        const status = napi.napi_get_cb_info(env, raw, &init_argc, null, null, null);
        if (status != napi.napi_ok) {
            @panic("Failed to get callback info");
        }

        const allocator = GlobalAllocator.globalAllocator();
        const args_raw = allocator.alloc(napi.napi_value, init_argc) catch @panic("OOM");

        var this: napi.napi_value = undefined;

        const status2 = napi.napi_get_cb_info(env, raw, &init_argc, args_raw.ptr, &this, null);
        if (status2 != napi.napi_ok) {
            allocator.free(args_raw);
            @panic("Failed to get callback info");
        }

        const result = allocator.alloc(value.NapiValue, init_argc) catch {
            allocator.free(args_raw);
            @panic("OOM");
        };

        for (0..init_argc) |i| {
            result[i] = value.NapiValue.from_raw(env, args_raw[i]);
        }

        return CallbackInfo{
            .raw = raw,
            .env = env,
            .args = result,
            .this = this,
            .args_raw = args_raw,
            .args_count = init_argc,
        };
    }

    /// Free the allocated memory for args and args_raw
    pub fn deinit(self: *const CallbackInfo) void {
        const allocator = GlobalAllocator.globalAllocator();
        allocator.free(self.args_raw);
        allocator.free(self.args);
    }

    pub fn Env(self: CallbackInfo) NapiEnv {
        return NapiEnv.from_raw(self.env);
    }

    pub fn Get(self: CallbackInfo, index: usize) value.NapiValue {
        return self.args[index];
    }

    pub fn This(self: CallbackInfo) napi.napi_value {
        return self.this;
    }
};
