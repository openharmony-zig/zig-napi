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
const helper = @import("../util/helper.zig");
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
///
/// An error payload is stored as an `ErrorSnapshot`: the error that was handed
/// to `Err` borrows its message and code from the caller (often a stack buffer
/// that is reused right after the call), so the text is copied into memory owned
/// by the queue item before the call is queued.
fn CallData(comptime Args: type) type {
    return struct {
        allocator: std.mem.Allocator,
        args: ?*Args,
        err: ?*ownership.ErrorSnapshot,
    };
}

/// Build the JavaScript error object delivered in the error-first slot.
///
/// Unlike `NapiError.Error.to_napi_error`, every N-API status is checked instead
/// of asserted: a queued call has no caller to report a failed allocation to,
/// and an uninitialized handle must never reach the engine. `null` means the
/// error could not be built, and the caller must not dispatch the failure call
/// at all rather than report it as a success.
fn createErrorValue(inner_env: napi.napi_env, err: NapiError.Error) ?napi.napi_value {
    const text = switch (err) {
        inline else => |inner| .{
            .code = inner.custom_status orelse if (inner.status) |status| status.ToString() else "Error",
            .message = inner.message,
        },
    };

    var code_value: napi.napi_value = undefined;
    if (napi.napi_create_string_utf8(inner_env, text.code.ptr, text.code.len, &code_value) != napi.napi_ok) return null;

    var message_value: napi.napi_value = undefined;
    if (napi.napi_create_string_utf8(inner_env, text.message.ptr, text.message.len, &message_value) != napi.napi_ok) return null;

    var result: napi.napi_value = undefined;
    const status = switch (err) {
        .JsError => napi.napi_create_error(inner_env, code_value, message_value, &result),
        .JsTypeError => napi.napi_create_type_error(inner_env, code_value, message_value, &result),
        .JsRangeError => napi.napi_create_range_error(inner_env, code_value, message_value, &result),
    };
    if (status != napi.napi_ok) return null;
    return result;
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

                    const undefined_value = (Undefined.create(Env.from_raw(inner_env)) catch return).raw;

                    // The error-first variant delivers a failure as a
                    // single-argument call. The remaining argument slots are
                    // *omitted* instead of being passed as native null handles:
                    // a native null is not JavaScript `undefined` and reaching
                    // the engine with one crashes the process (audit H03).
                    if (self.thread_safe_function_call_variant) {
                        if (call_data.err) |snapshot| {
                            // A failure that cannot be turned into an error
                            // object is not delivered as a successful call
                            // instead: the payload is released and the callback
                            // simply never runs for this item.
                            var argv = [1]napi.napi_value{createErrorValue(inner_env, snapshot.value()) orelse return};
                            var ret: napi.napi_value = null;
                            _ = napi.napi_call_function(inner_env, undefined_value, js_callback, argv.len, &argv, &ret);
                            return;
                        }
                    }

                    const args_len = if (@typeInfo(Args) == .@"struct" and @typeInfo(Args).@"struct".is_tuple) @typeInfo(Args).@"struct".fields.len else 1;
                    const call_variant = if (self.thread_safe_function_call_variant) 1 else 0;

                    const argv = allocator.alloc(napi.napi_value, args_len + call_variant) catch return;
                    defer allocator.free(argv);
                    // Filled with JavaScript `undefined` up front, so a slot that
                    // no payload reaches can never be a native null.
                    @memset(argv, undefined_value);

                    if (call_variant == 1) {
                        argv[0] = (Null.create(Env.from_raw(inner_env)) catch return).raw;
                    }

                    var conversion_error: ?NapiError.Error = null;
                    if (call_data.args) |actual_args| {
                        if (@typeInfo(Args) == .@"struct" and @typeInfo(Args).@"struct".is_tuple) {
                            inline for (@typeInfo(Args).@"struct".fields, 0..) |field, i| {
                                argv[i + call_variant] = Napi.to_napi_value(inner_env, @field(actual_args.*, field.name), null) catch |err| blk: {
                                    conversion_error = NapiError.mapAnyError(err);
                                    break :blk undefined_value;
                                };
                            }
                        } else {
                            argv[call_variant] = Napi.to_napi_value(inner_env, actual_args.*, null) catch |err| blk: {
                                conversion_error = NapiError.mapAnyError(err);
                                break :blk undefined_value;
                            };
                        }
                    }

                    if (conversion_error) |err| {
                        // Never pass an invalid handle to JavaScript: report the
                        // conversion failure through the error slot when the
                        // callee accepts one, otherwise as undefined values. An
                        // error slot that cannot hold the error object must not
                        // be delivered as a success.
                        if (call_variant == 1) {
                            argv[0] = createErrorValue(inner_env, err) orelse return;
                        }
                    }

                    var ret: napi.napi_value = null;
                    _ = napi.napi_call_function(inner_env, undefined_value, js_callback, args_len + call_variant, argv.ptr, &ret);
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

            // Promoting a JavaScript function to a TSFN creates an active
            // thread-safe function. While an argument conversion is running the
            // promotion belongs to that conversion: if a later argument fails,
            // the TSFN is aborted so it cannot keep the environment (and the
            // JavaScript function it captured) alive after a call that never
            // reached its body. Once the body runs, the TSFN belongs to the body
            // and is never rolled back - it is usually handed to another thread,
            // which is why the conversion only aborts on failure.
            helper.trackCustom(@ptrCast(self), releaseUncommitted) catch |err| {
                self.abort() catch {};
                return err;
            };

            return self;
        }

        /// Rollback action for a TSFN that a failing conversion created.
        ///
        /// The conversion is still running, so the wrapper was never handed to
        /// user code and no other thread can have released it: aborting here is
        /// the only release the TSFN ever gets.
        fn releaseUncommitted(context: ?*anyopaque) void {
            const raw_context = context orelse return;
            const self: *Self = @ptrCast(@alignCast(raw_context));
            self.abort() catch {};
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
            if (data.err) |snapshot| {
                // The snapshot owns a copy of the error text; releasing it here
                // covers delivery, queue-full, closing and the null-environment
                // drain alike.
                snapshot.deinit();
                allocator.destroy(snapshot);
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

        /// Allocator that releases the payload of a queued call.
        ///
        /// A handle whose creation failed never recorded an allocator (there was
        /// no construction to record it), so it falls back to the operation
        /// allocator of the calling thread - the same allocator the default
        /// conversion path uses for its own copies.
        fn payloadAllocator(self: *const Self) std.mem.Allocator {
            return if (self.failed) GlobalAllocator.globalAllocator() else self.allocator;
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

        /// Queue a successful call.
        ///
        /// Ownership of `args` moves into the queued item on every path -
        /// including a full queue, a closed TSFN or an allocation failure - and
        /// is released after the JavaScript callback ran (or when the queue is
        /// drained during environment shutdown). `error.OutOfMemory` therefore
        /// means "not queued", never "the caller still owns the payload".
        pub fn Ok(self: *const Self, args: Args, mode: ThreadSafeFunctionMode) !void {
            if (self.failed or self.tsfn_raw == null) {
                // The call was never queued, but `Ok` took ownership of the
                // payload: release it here so the caller's job ends with this
                // call on the failure path too.
                ownership.deinitValue(Args, args, self.payloadAllocator());
                return self.notCreatedError();
            }

            const args_data = self.allocator.create(Args) catch |err| {
                ownership.deinitValue(Args, args, self.allocator);
                return err;
            };
            args_data.* = args;

            const data = self.allocator.create(CallData(Args)) catch |err| {
                ownership.deinitValue(Args, args_data.*, self.allocator);
                self.allocator.destroy(args_data);
                return err;
            };
            data.* = CallData(Args){ .allocator = self.allocator, .args = args_data, .err = null };

            try self.callThreadSafeFunction(data, mode);
        }

        /// Queue a failed call. The error is released after the JavaScript
        /// callback ran, and the text of the error is copied first: the caller's
        /// message and code are borrowed slices that may be overwritten (or go
        /// out of scope) long before the JavaScript thread dispatches the call.
        ///
        /// With `ThreadSafeFunctionCalleeHandled = false` there is no error slot
        /// to deliver the failure to; the callback runs with the queued argument
        /// slots left as JavaScript `undefined` (the error is not reported to
        /// JavaScript at all).
        pub fn Err(self: *const Self, err: NapiError.Error, mode: ThreadSafeFunctionMode) !void {
            if (self.failed or self.tsfn_raw == null) return self.notCreatedError();

            const snapshot = self.allocator.create(ownership.ErrorSnapshot) catch |alloc_err| {
                // Without a slot for the snapshot the borrowed text cannot be
                // copied, so the failure must not be queued at all.
                return alloc_err;
            };
            // `capture` never retains borrowed text: an allocation failure
            // inside it degrades to a bounded static error instead.
            snapshot.* = ownership.ErrorSnapshot.capture(self.allocator, err);

            const data = self.allocator.create(CallData(Args)) catch |alloc_err| {
                snapshot.deinit();
                self.allocator.destroy(snapshot);
                return alloc_err;
            };
            data.* = CallData(Args){ .allocator = self.allocator, .args = null, .err = snapshot };

            try self.callThreadSafeFunction(data, mode);
        }
    };
}

test "ThreadSafeFunction release modes map to napi values" {
    try std.testing.expect(ThreadSafeFunctionReleaseMode.Release.to_raw() == napi.napi_tsfn_release);
    try std.testing.expect(ThreadSafeFunctionReleaseMode.Abort.to_raw() == napi.napi_tsfn_abort);
}
