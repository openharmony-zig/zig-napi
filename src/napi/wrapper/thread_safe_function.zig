const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Napi = @import("../util/napi.zig").Napi;
const Undefined = @import("../value/undefined.zig").Undefined;
const Null = @import("../value/null.zig").Null;
const Env = @import("../env.zig").Env;
const NapiError = @import("./error.zig");
const String = @import("../value/string.zig").String;
const GlobalAllocator = @import("../util/allocator.zig");

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

pub const ThreadSafeFunctionReleaseMode = enum {
    Release,
    Abort,

    const Self = @This();

    pub fn to_raw(self: Self) napi.napi_threadsafe_function_release_mode {
        return switch (self) {
            .Release => napi.napi_tsfn_release,
            .Abort => napi.napi_tsfn_abort,
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
        closed: bool,
        aborted: bool,
        comptime thread_safe_function_call_variant: bool = ThreadSafeFunctionCalleeHandled,
        comptime max_queue_size: usize = MaxQueueSize,

        const Self = @This();

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) *Self {
            const ThreadSafe = struct {
                fn finalize(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                    const self: *Self = @ptrCast(@alignCast(data));
                    self.closed = true;
                    self.deinit();
                }

                fn cb(inner_env: napi.napi_env, js_callback: napi.napi_value, context: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
                    const self: *Self = @ptrCast(@alignCast(context));
                    const args: *CallData(Args) = @ptrCast(@alignCast(data));
                    const allocator = self.allocator;

                    const args_len = if (@typeInfo(Args) == .@"struct" and @typeInfo(Args).@"struct".is_tuple) @typeInfo(Args).@"struct".fields.len else 1;
                    const call_variant = if (self.thread_safe_function_call_variant) 1 else 0;

                    const argv = allocator.alloc(napi.napi_value, args_len + call_variant) catch @panic("OOM");
                    defer allocator.free(argv);
                    @memset(argv, null);

                    const undefined_value = Undefined.New(Env.from_raw(inner_env));

                    if (self.thread_safe_function_call_variant) {
                        if (args.err) |param| {
                            argv[0] = param.to_napi_error(Env.from_raw(inner_env));
                            var ret: napi.napi_value = undefined;
                            _ = napi.napi_call_function(inner_env, undefined_value.raw, js_callback, args_len + call_variant, argv.ptr, &ret);
                            allocator.destroy(param);
                            allocator.destroy(args);
                            return;
                        } else {
                            argv[0] = Null.New(Env.from_raw(inner_env)).raw;
                        }
                    }

                    if (args.args) |actual_args| {
                        if (@typeInfo(Args) == .@"struct" and @typeInfo(Args).@"struct".is_tuple) {
                            inline for (@typeInfo(Args).@"struct".fields, 0..) |field, i| {
                                argv[i + call_variant] = Napi.to_napi_value(inner_env, @field(actual_args.*, field.name), null) catch null;
                            }
                        } else {
                            argv[call_variant] = Napi.to_napi_value(inner_env, actual_args.*, null) catch null;
                        }
                        allocator.destroy(actual_args);
                    }

                    var ret: napi.napi_value = undefined;
                    _ = napi.napi_call_function(inner_env, undefined_value.raw, js_callback, args_len + call_variant, argv.ptr, &ret);
                    allocator.destroy(args);
                }
            };

            const allocator = GlobalAllocator.globalAllocator();
            var self = allocator.create(Self) catch @panic("OOM");

            self.* = Self{
                .env = env,
                .raw = raw,
                .allocator = allocator,
                .args = undefined,
                .return_type = undefined,
                .tsfn_raw = null,
                .closed = false,
                .aborted = false,
            };

            var tsfn_raw: napi.napi_threadsafe_function = null;
            const resource = String.New(Env.from_raw(env), "ThreadSafeFunction");
            const create_status = napi.napi_create_threadsafe_function(
                env,
                raw,
                null,
                resource.raw,
                self.max_queue_size,
                1,
                @ptrCast(self),
                ThreadSafe.finalize,
                @ptrCast(self),
                ThreadSafe.cb,
                &tsfn_raw,
            );
            if (create_status != napi.napi_ok) {
                allocator.destroy(self);
                @panic("Failed to create ThreadSafeFunction");
            }

            self.tsfn_raw = tsfn_raw;

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        fn freeCallData(self: *const Self, data: *CallData(Args)) void {
            if (data.args) |actual_args| {
                self.allocator.destroy(actual_args);
            }
            if (data.err) |actual_err| {
                self.allocator.destroy(actual_err);
            }
            self.allocator.destroy(data);
        }

        fn callThreadSafeFunction(self: *const Self, data: *CallData(Args), mode: ThreadSafeFunctionMode) !void {
            const status = napi.napi_call_threadsafe_function(self.tsfn_raw, @ptrCast(data), mode.to_raw());
            if (status != napi.napi_ok) {
                self.freeCallData(data);
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        pub fn acquire(self: *const Self) !void {
            const status = napi.napi_acquire_threadsafe_function(self.tsfn_raw);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        pub fn release(self: *const Self, mode: ThreadSafeFunctionReleaseMode) !void {
            const status = napi.napi_release_threadsafe_function(self.tsfn_raw, mode.to_raw());
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        pub fn abort(self: *Self) !void {
            if (self.aborted) return;
            try self.release(.Abort);
            self.aborted = true;
        }

        pub fn ref(self: *const Self) !void {
            const status = napi.napi_ref_threadsafe_function(self.env, self.tsfn_raw);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        pub fn unref(self: *const Self) !void {
            const status = napi.napi_unref_threadsafe_function(self.env, self.tsfn_raw);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        pub fn Ok(self: *const Self, args: Args, mode: ThreadSafeFunctionMode) !void {
            const args_data = self.allocator.create(Args) catch @panic("OOM");
            args_data.* = args;

            const data = self.allocator.create(CallData(Args)) catch @panic("OOM");
            data.* = CallData(Args){ .args = args_data, .err = null };

            try self.callThreadSafeFunction(data, mode);
        }

        pub fn Err(self: *const Self, err: NapiError.Error, mode: ThreadSafeFunctionMode) !void {
            const actual_err = self.allocator.create(NapiError.Error) catch @panic("OOM");
            actual_err.* = err;

            const data = self.allocator.create(CallData(Args)) catch @panic("OOM");
            data.* = CallData(Args){ .args = null, .err = actual_err };

            try self.callThreadSafeFunction(data, mode);
        }
    };
}

test "ThreadSafeFunction release modes map to napi values" {
    try std.testing.expect(ThreadSafeFunctionReleaseMode.Release.to_raw() == napi.napi_tsfn_release);
    try std.testing.expect(ThreadSafeFunctionReleaseMode.Abort.to_raw() == napi.napi_tsfn_abort);
}
