const std = @import("std");
const napi = @import("napi-sys");
const NapiError = @import("./error.zig");
const String = @import("../value/string.zig").String;

pub const ThreadSafeFunctionMode = enum {
    NonBlocking,
    Blocking,
};

pub fn ThreadSafeFunction(comptime option: anytype) type {
    if (@typeInfo(@TypeOf(option)) != .@"struct") {
        @compileError("ThreadSafeFunction option must be a struct");
    }

    const Args = @TypeOf(@field(option, "args"));
    const Return = @TypeOf(@field(option, "return"));

    const ThreadSafeFunctionCalleeHandled = @TypeOf(@field(option, "thread_safe_function_call_mode"));
    const MaxQueueSize = @TypeOf(@field(option, "max_queue_size"));

    return struct {
        env: napi.napi_env,
        raw: napi.napi_function,
        tsfn_raw: napi.napi_threadsafe_function,
        type: napi.napi_valuetype,
        allocator: std.mem.Allocator,
        args: Args,
        return_type: Return,
        thread_safe_function_call_mode: ThreadSafeFunctionCalleeHandled,
        max_queue_size: MaxQueueSize,

        const Self = @This();

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_function) Self {
            const ThreadSafe = struct {
                fn finalize(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
                    const self: *Self = @ptrCast(@alignCast(data));
                    self.deinit();
                }

                fn cb(_: napi.napi_env, js_callback: napi.napi_value, context: ?*anyopaque, data: ?*anyopaque) callconv(.C) void {
                    _ = js_callback;
                    _ = context;
                    _ = data;
                }
            };

            const allocator = std.heap.page_allocator;
            var self = allocator.create(Self) catch @panic("OOM");

            self.* = Self{ .env = env, .raw = raw, .type = napi.napi_threadsafe_function, .allocator = allocator, .args = undefined, .return_type = undefined };

            var tsfn_raw: napi.napi_threadsafe_function = undefined;
            const resource = String.New(env, "ThreadSafeFunction");
            const status = napi.napi_create_threadsafe_function(env, raw, null, resource.raw, 0, 1, @ptrCast(self), null, @ptrCast(self), ThreadSafe.cb, &tsfn_raw);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }

            self.tsfn_raw = tsfn_raw;

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        pub fn Call(self: *Self, _: Args, mode: ThreadSafeFunctionMode) !Return {
            _ = napi.napi_call_threadsafe_function(self.tsfn_raw, @ptrCast(self), mode);
        }
    };
}
