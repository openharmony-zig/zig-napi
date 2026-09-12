const napi = @import("napi-sys").napi_sys;
const value = @import("../value.zig");
const NapiEnv = @import("../env.zig").Env;
const GlobalAllocator = @import("../util/allocator.zig");
const std = @import("std");
const NapiError = @import("error.zig");

pub const CallbackInfo = struct {
    const inline_arg_count = 8;

    raw: napi.napi_callback_info,
    env: napi.napi_env,
    args_count: usize,
    this: napi.napi_value,
    inline_args_raw: [inline_arg_count]napi.napi_value = undefined,
    heap_args_raw: ?[]napi.napi_value = null,
    allocator: std.mem.Allocator,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_callback_info) CallbackInfo {
        return tryFromRaw(env, raw) catch @panic("Failed to get callback info");
    }

    pub fn tryFromRaw(env: napi.napi_env, raw: napi.napi_callback_info) !CallbackInfo {
        var result = CallbackInfo{
            .raw = raw,
            .env = env,
            .args_count = 0,
            .this = undefined,
            .allocator = GlobalAllocator.capture(),
        };

        var argc: usize = inline_arg_count;
        const status = napi.napi_get_cb_info(env, raw, &argc, result.inline_args_raw[0..].ptr, &result.this, null);
        if (status != napi.napi_ok) {
            return NapiError.failStatus(status);
        }

        result.args_count = argc;
        if (argc <= inline_arg_count) {
            return result;
        }

        const allocator = result.allocator;
        const heap_args_raw = try allocator.alloc(napi.napi_value, argc);
        var heap_argc = argc;
        const heap_status = napi.napi_get_cb_info(env, raw, &heap_argc, heap_args_raw.ptr, &result.this, null);
        if (heap_status != napi.napi_ok) {
            allocator.free(heap_args_raw);
            return NapiError.failStatus(heap_status);
        }

        result.args_count = heap_argc;
        result.heap_args_raw = heap_args_raw;
        return result;
    }

    /// Free the allocated memory for heap-backed args, if any.
    pub fn deinit(self: *const CallbackInfo) void {
        if (self.heap_args_raw) |args_raw| {
            self.allocator.free(args_raw);
        }
    }

    pub fn Env(self: CallbackInfo) NapiEnv {
        return NapiEnv.from_raw(self.env);
    }

    pub fn Get(self: CallbackInfo, index: usize) value.NapiValue {
        return value.NapiValue.from_raw(self.env, self.ArgRaw(index));
    }

    pub fn Len(self: CallbackInfo) usize {
        return self.args_count;
    }

    pub fn ArgsRaw(self: CallbackInfo) []const napi.napi_value {
        if (self.heap_args_raw) |args_raw| {
            return args_raw[0..self.args_count];
        }
        return self.inline_args_raw[0..self.args_count];
    }

    pub fn ArgRaw(self: CallbackInfo, index: usize) napi.napi_value {
        return self.ArgsRaw()[index];
    }

    pub fn This(self: CallbackInfo) napi.napi_value {
        return self.this;
    }
};
