const std = @import("std");
const napi = @import("napi-sys");
const Napi = @import("../util/napi.zig").Napi;
const Undefined = @import("../value/undefined.zig").Undefined;
const Null = @import("../value/null.zig").Null;
const Env = @import("../env.zig").Env;
const NapiError = @import("./error.zig");
const String = @import("../value/string.zig").String;

pub const ThreadSafeFunctionMode = enum {
    NonBlocking,
    Blocking,

    const Self = @This();
    pub fn to_raw(self: Self) napi.napi_threadsafe_function_call_mode {
        return switch (self) {
            .NonBlocking => napi.napi_tsfn_nonblocking,
            .Blocking => napi.napi_tsfn_blocking,
        };
    }
};

pub const ThreadSafeFunctionCallVariant = enum {
    Direct,
    WithCallback,
};

fn CallData(comptime Args: type) type {
    return struct {
        args: ?*Args,
        err: ?*NapiError.Error,
    };
}

pub fn ThreadSafeFunction(comptime Args: type, comptime Return: type, comptime ThreadSafeFunctionCalleeHandled: anytype, comptime MaxQueueSize: anytype) type {
    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        tsfn_raw: napi.napi_threadsafe_function,
        allocator: std.mem.Allocator,
        args: Args,
        return_type: Return,
        comptime thread_safe_function_call_variant: bool = ThreadSafeFunctionCalleeHandled,
        comptime max_queue_size: usize = MaxQueueSize,

        const Self = @This();

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) *Self {
            const ThreadSafe = struct {
                fn finalize(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
                    const self: *Self = @ptrCast(@alignCast(data));
                    self.deinit();
                }

                fn cb(inner_env: napi.napi_env, js_callback: napi.napi_value, context: ?*anyopaque, data: ?*anyopaque) callconv(.C) void {
                    const self: *Self = @ptrCast(@alignCast(context));
                    const args: *CallData(Args) = @ptrCast(@alignCast(data));

                    const args_len = if (@typeInfo(Args) == .@"struct" and @typeInfo(Args).@"struct".is_tuple) @typeInfo(Args).@"struct".fields.len else 1;
                    const call_variant = if (self.thread_safe_function_call_variant) 1 else 0;

                    const argv = self.allocator.alloc(napi.napi_value, args_len + call_variant) catch @panic("OOM");
                    defer self.allocator.free(argv);

                    const undefined_value = Undefined.New(Env.from_raw(inner_env));

                    if (self.thread_safe_function_call_variant) {
                        if (args.err) |param| {
                            argv[0] = param.to_napi_error(Env.from_raw(inner_env));
                            // if err, return immediately
                            var ret: napi.napi_value = undefined;
                            _ = napi.napi_call_function(inner_env, undefined_value.raw, js_callback, args_len + call_variant, argv.ptr, &ret);
                            return;
                        } else {
                            argv[0] = Null.New(Env.from_raw(inner_env)).raw;
                        }
                    }

                    if (args.args) |actual_args| {
                        if (@typeInfo(Args) == .@"struct" and @typeInfo(Args).@"struct".is_tuple) {
                            inline for (@typeInfo(Args).@"struct".fields, 0..) |field, i| {
                                argv[i + call_variant] = try Napi.to_napi_value(inner_env, @field(actual_args.*, field.name), null);
                            }
                        } else {
                            argv[call_variant] = try Napi.to_napi_value(inner_env, actual_args.*, null);
                        }
                    }

                    var ret: napi.napi_value = undefined;
                    _ = napi.napi_call_function(inner_env, undefined_value.raw, js_callback, args_len + call_variant, argv.ptr, &ret);
                }
            };

            const allocator = std.heap.page_allocator;
            var self = allocator.create(Self) catch @panic("OOM");

            self.* = Self{ .env = env, .raw = raw, .allocator = allocator, .args = undefined, .return_type = undefined, .tsfn_raw = undefined };

            var tsfn_raw: napi.napi_threadsafe_function = undefined;
            const resource = String.New(Env.from_raw(env), "ThreadSafeFunction");
            _ = napi.napi_create_threadsafe_function(env, raw, null, resource.raw, 0, 1, @ptrCast(self), null, @ptrCast(self), ThreadSafe.cb, &tsfn_raw);

            self.tsfn_raw = tsfn_raw;

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        pub fn Ok(self: *const Self, args: Args, mode: ThreadSafeFunctionMode) void {
            const args_data = self.allocator.create(Args) catch @panic("OOM");
            args_data.* = args;

            const data = self.allocator.create(CallData(Args)) catch @panic("OOM");
            data.* = CallData(Args){ .args = args_data, .err = null };

            _ = napi.napi_call_threadsafe_function(self.tsfn_raw, @ptrCast(data), mode.to_raw());
        }

        pub fn Err(self: *const Self, err: NapiError.Error, mode: ThreadSafeFunctionMode) void {
            const e = self.allocator.create(NapiError.Error) catch @panic("OOM");
            e.* = err;

            const data = self.allocator.create(CallData(Args)) catch @panic("OOM");
            data.* = CallData(Args){ .args = null, .err = e };

            _ = napi.napi_call_threadsafe_function(self.tsfn_raw, @ptrCast(data), mode.to_raw());
        }
    };
}
