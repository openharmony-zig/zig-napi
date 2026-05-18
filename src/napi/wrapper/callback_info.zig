const napi = @import("napi-sys").napi_sys;
const value = @import("../value.zig");
const NapiEnv = @import("../env.zig").Env;
const GlobalAllocator = @import("../util/allocator.zig");

pub const CallbackInfo = struct {
    const inline_arg_count = 8;

    raw: napi.napi_callback_info,
    env: napi.napi_env,
    args_count: usize,
    this: napi.napi_value,
    inline_args_raw: [inline_arg_count]napi.napi_value = undefined,
    heap_args_raw: ?[]napi.napi_value = null,

    pub fn from_raw(env: napi.napi_env, raw: napi.napi_callback_info) CallbackInfo {
        var result = CallbackInfo{
            .raw = raw,
            .env = env,
            .args_count = 0,
            .this = undefined,
        };

        var argc: usize = inline_arg_count;
        const status = napi.napi_get_cb_info(env, raw, &argc, result.inline_args_raw[0..].ptr, &result.this, null);
        if (status != napi.napi_ok) {
            @panic("Failed to get callback info");
        }

        result.args_count = argc;
        if (argc <= inline_arg_count) {
            return result;
        }

        const allocator = GlobalAllocator.globalAllocator();
        const heap_args_raw = allocator.alloc(napi.napi_value, argc) catch @panic("OOM");
        var heap_argc = argc;
        const heap_status = napi.napi_get_cb_info(env, raw, &heap_argc, heap_args_raw.ptr, &result.this, null);
        if (heap_status != napi.napi_ok) {
            allocator.free(heap_args_raw);
            @panic("Failed to get callback info");
        }

        result.args_count = heap_argc;
        result.heap_args_raw = heap_args_raw;
        return result;
    }

    /// Free the allocated memory for heap-backed args, if any.
    pub fn deinit(self: *const CallbackInfo) void {
        if (self.heap_args_raw) |args_raw| {
            const allocator = GlobalAllocator.globalAllocator();
            allocator.free(args_raw);
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
