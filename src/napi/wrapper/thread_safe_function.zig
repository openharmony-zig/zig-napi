const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const Napi = @import("../util/napi.zig").Napi;
const Undefined = @import("../value/undefined.zig").Undefined;
const Null = @import("../value/null.zig").Null;
const Env = @import("../env.zig").Env;
const NapiError = @import("./error.zig");
const String = @import("../value/string.zig").String;
const GlobalAllocator = @import("../util/allocator.zig");
const ownership = @import("../util/async_ownership.zig");
const options = @import("../options.zig");

const ThreadSafeFunctionCallModeRaw = if (options.selectedNapiVersion().isAtLeast(.v4))
    napi.napi_threadsafe_function_call_mode
else
    c_int;

const ThreadSafeFunctionReleaseModeRaw = if (options.selectedNapiVersion().isAtLeast(.v4))
    napi.napi_threadsafe_function_release_mode
else
    c_int;

pub const ThreadSafeFunctionMode = enum {
    NonBlocking,
    Blocking,

    const Self = @This();

    pub fn to_raw(self: Self) ThreadSafeFunctionCallModeRaw {
        comptime options.requireNapiVersion(.v4);
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

    pub fn to_raw(self: Self) ThreadSafeFunctionReleaseModeRaw {
        comptime options.requireNapiVersion(.v4);
        return switch (self) {
            .Abort => napi.napi_tsfn_abort,
            .Release => napi.napi_tsfn_release,
        };
    }
};

pub const ThreadSafeFunctionCallVariant = enum {
    Direct,
    WithCallback,
};

/// One queued call.
///
/// The item owns its payload and records the allocator that must release it, so
/// it can be released even when the JavaScript environment is already gone and
/// the dispatcher runs with a null environment.
fn CallData(comptime Args: type) type {
    return struct {
        allocator: std.mem.Allocator,
        args: ?*Args,
        err: ?*NapiError.Error,
    };
}

pub fn ThreadSafeFunction(comptime Args: type, comptime Return: type, comptime ThreadSafeFunctionCalleeHandled: anytype, comptime MaxQueueSize: anytype) type {
    comptime options.requireNapiVersion(.v4);

    return struct {
        env: napi.napi_env,
        raw: napi.napi_value,
        tsfn_raw: napi.napi_threadsafe_function,
        allocator: std.mem.Allocator,
        args: Args,
        return_type: Return,
        closed: bool,
        aborted: bool,
        failed: bool = false,
        freed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        comptime thread_safe_function_call_variant: bool = ThreadSafeFunctionCalleeHandled,
        comptime max_queue_size: usize = MaxQueueSize,

        const Self = @This();

        /// Fallback handle returned when the underlying thread-safe function
        /// could not be created. All operations report the stored error instead
        /// of aborting the process, and the handle is never freed.
        var failed_handle: Self = .{
            .env = null,
            .raw = null,
            .tsfn_raw = null,
            .allocator = undefined,
            .args = undefined,
            .return_type = undefined,
            .closed = true,
            .aborted = true,
            .failed = true,
        };

        pub fn from_raw(env: napi.napi_env, raw: napi.napi_value) *Self {
            return tryFrom_raw(env, raw) catch {
                // Keep the failure visible to the conversion layer: callers
                // check `NapiError.last_error` and report it to JavaScript.
                if (NapiError.last_error == null) {
                    NapiError.last_error = NapiError.Error.withCodeAndMessage(
                        "ERR_NAPI_TSFN_NOT_CREATED",
                        "ThreadSafeFunction could not be created",
                    );
                }
                return &failed_handle;
            };
        }

        /// Fallible construction. Prefer this over `from_raw` when the caller
        /// can propagate the creation error.
        pub fn tryFrom_raw(env: napi.napi_env, raw: napi.napi_value) !*Self {
            const ThreadSafe = struct {
                fn finalize(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                    const raw_data = data orelse return;
                    const self: *Self = @ptrCast(@alignCast(raw_data));
                    self.closed = true;
                    self.deinit();
                }

                fn cb(inner_env: napi.napi_env, js_callback: napi.napi_value, context: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
                    const raw_data = data orelse return;
                    const call_data: *CallData(Args) = @ptrCast(@alignCast(raw_data));
                    const allocator = call_data.allocator;
                    // Every path below releases the queued payload, including
                    // the null-environment shutdown drain.
                    defer freeCallData(allocator, call_data);

                    if (inner_env == null or js_callback == null) return;

                    const raw_context = context orelse return;
                    const self: *Self = @ptrCast(@alignCast(raw_context));

                    const args_len = if (@typeInfo(Args) == .@"struct" and @typeInfo(Args).@"struct".is_tuple) @typeInfo(Args).@"struct".fields.len else 1;
                    const call_variant = if (self.thread_safe_function_call_variant) 1 else 0;

                    const argv = allocator.alloc(napi.napi_value, args_len + call_variant) catch return;
                    defer allocator.free(argv);
                    @memset(argv, null);

                    const undefined_value = Undefined.New(Env.from_raw(inner_env));

                    if (self.thread_safe_function_call_variant) {
                        if (call_data.err) |param| {
                            argv[0] = param.to_napi_error(Env.from_raw(inner_env));
                            var ret: napi.napi_value = null;
                            _ = napi.napi_call_function(inner_env, undefined_value.raw, js_callback, args_len + call_variant, argv.ptr, &ret);
                            return;
                        }
                        argv[0] = Null.New(Env.from_raw(inner_env)).raw;
                    }

                    var conversion_error: ?NapiError.Error = null;
                    if (call_data.args) |actual_args| {
                        if (@typeInfo(Args) == .@"struct" and @typeInfo(Args).@"struct".is_tuple) {
                            inline for (@typeInfo(Args).@"struct".fields, 0..) |field, i| {
                                argv[i + call_variant] = Napi.to_napi_value(inner_env, @field(actual_args.*, field.name), null) catch |err| blk: {
                                    conversion_error = NapiError.mapAnyError(err);
                                    break :blk undefined_value.raw;
                                };
                            }
                        } else {
                            argv[call_variant] = Napi.to_napi_value(inner_env, actual_args.*, null) catch |err| blk: {
                                conversion_error = NapiError.mapAnyError(err);
                                break :blk undefined_value.raw;
                            };
                        }
                    }

                    if (conversion_error) |err| {
                        // Never pass an invalid handle to JavaScript: report the
                        // conversion failure through the error slot when the
                        // callee accepts one, otherwise as undefined values.
                        if (self.thread_safe_function_call_variant) {
                            argv[0] = err.to_napi_error(Env.from_raw(inner_env));
                        }
                    }
                    for (argv) |*slot| {
                        if (slot.* == null) slot.* = undefined_value.raw;
                    }

                    var ret: napi.napi_value = null;
                    _ = napi.napi_call_function(inner_env, undefined_value.raw, js_callback, args_len + call_variant, argv.ptr, &ret);
                }
            };

            const allocator = GlobalAllocator.globalAllocator();
            const self = try allocator.create(Self);

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
                return NapiError.Error.fromStatus(NapiError.Status.New(create_status));
            }

            self.tsfn_raw = tsfn_raw;

            return self;
        }

        pub fn deinit(self: *Self) void {
            // The failure handle is a process-wide singleton.
            if (self.failed) return;
            if (self.freed.swap(true, .acq_rel)) return;
            self.allocator.destroy(self);
        }

        fn freeCallData(allocator: std.mem.Allocator, data: *CallData(Args)) void {
            if (data.args) |actual_args| {
                // `Ok` transfers ownership of the arguments to the queued call.
                ownership.deinitValue(Args, actual_args.*, allocator);
                allocator.destroy(actual_args);
            }
            if (data.err) |actual_err| {
                allocator.destroy(actual_err);
            }
            allocator.destroy(data);
        }

        fn callThreadSafeFunction(self: *const Self, data: *CallData(Args), mode: ThreadSafeFunctionMode) !void {
            if (self.failed or self.tsfn_raw == null) {
                freeCallData(data.allocator, data);
                return self.notCreatedError();
            }
            const status = napi.napi_call_threadsafe_function(self.tsfn_raw, @ptrCast(data), mode.to_raw());
            if (status != napi.napi_ok) {
                // The item never entered the queue: release it here.
                freeCallData(data.allocator, data);
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        fn notCreatedError(self: *const Self) anyerror {
            if (self.failed) {
                NapiError.last_error = NapiError.Error.withCodeAndMessage(
                    "ERR_NAPI_TSFN_NOT_CREATED",
                    "ThreadSafeFunction could not be created",
                );
            }
            return error.Closing;
        }

        pub fn acquire(self: *const Self) !void {
            if (self.failed or self.tsfn_raw == null) return self.notCreatedError();
            const status = napi.napi_acquire_threadsafe_function(self.tsfn_raw);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        pub fn release(self: *const Self, mode: ThreadSafeFunctionReleaseMode) !void {
            if (self.failed or self.tsfn_raw == null) return self.notCreatedError();
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
            if (self.failed or self.tsfn_raw == null) return self.notCreatedError();
            const status = napi.napi_ref_threadsafe_function(self.env, self.tsfn_raw);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        pub fn unref(self: *const Self) !void {
            if (self.failed or self.tsfn_raw == null) return self.notCreatedError();
            const status = napi.napi_unref_threadsafe_function(self.env, self.tsfn_raw);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed;
        }

        /// Queue a successful call. Ownership of `args` moves into the queued
        /// item and is released after the JavaScript callback ran (or when the
        /// queue is drained during environment shutdown).
        pub fn Ok(self: *const Self, args: Args, mode: ThreadSafeFunctionMode) !void {
            const args_data = self.allocator.create(Args) catch @panic("OOM");
            args_data.* = args;

            const data = self.allocator.create(CallData(Args)) catch {
                ownership.deinitValue(Args, args_data.*, self.allocator);
                self.allocator.destroy(args_data);
                @panic("OOM");
            };
            data.* = CallData(Args){ .allocator = self.allocator, .args = args_data, .err = null };

            try self.callThreadSafeFunction(data, mode);
        }

        /// Queue a failed call. The error is released after the JavaScript
        /// callback ran.
        pub fn Err(self: *const Self, err: NapiError.Error, mode: ThreadSafeFunctionMode) !void {
            const actual_err = self.allocator.create(NapiError.Error) catch @panic("OOM");
            actual_err.* = err;

            const data = self.allocator.create(CallData(Args)) catch {
                self.allocator.destroy(actual_err);
                @panic("OOM");
            };
            data.* = CallData(Args){ .allocator = self.allocator, .args = null, .err = actual_err };

            try self.callThreadSafeFunction(data, mode);
        }
    };
}

test "ThreadSafeFunction release modes map to napi values" {
    try std.testing.expect(ThreadSafeFunctionReleaseMode.Release.to_raw() == napi.napi_tsfn_release);
    try std.testing.expect(ThreadSafeFunctionReleaseMode.Abort.to_raw() == napi.napi_tsfn_abort);
}
