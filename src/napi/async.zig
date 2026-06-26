const std = @import("std");
const builtin = @import("builtin");
const napi = @import("napi-sys").napi_sys;
const Env = @import("./env.zig").Env;
const Promise = @import("./value/promise.zig").Promise;
const String = @import("./value/string.zig").String;
const Undefined = @import("./value/undefined.zig").Undefined;
const Napi = @import("./util/napi.zig").Napi;
const NapiError = @import("./wrapper/error.zig");
const GlobalAllocator = @import("./util/allocator.zig");
const AbortSignalModule = @import("./abort_signal.zig");
const AbortSignal = @import("./abort_signal.zig").AbortSignal;
const AbortRegistration = @import("./abort_signal.zig").AbortRegistration;
const options = @import("./options.zig");

var threaded_runtime_mutex: std.atomic.Mutex = .unlocked;
var threaded_runtime_initialized = false;
var threaded_runtime_active_operations: usize = 0;
var threaded_runtime_cleanup_registered = false;
var threaded_runtime_cleanup_requested = false;
var threaded_runtime: std.Io.Threaded = undefined;

const use_wasm_emnapi_async_work = builtin.cpu.arch == .wasm32 and builtin.os.tag == .wasi;

pub const RuntimeModel = enum {
    single,
    thread,
    event,

    // Backward-compatible spellings kept while examples and downstream users migrate.
    serial,
    threaded,
    evented,
};

const EffectiveRuntime = enum {
    single,
    thread,
};

pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancelToken) void {
        self.cancelled.store(true, .seq_cst);
    }

    pub fn isCancelled(self: *const CancelToken) bool {
        return self.cancelled.load(.seq_cst);
    }

    pub fn check(self: *const CancelToken) !void {
        if (self.isCancelled()) return error.Cancelled;
    }
};

pub fn resolveRequestedRuntime(runtime: RuntimeModel) RuntimeModel {
    return switch (runtime) {
        .serial => .single,
        .threaded => .thread,
        .evented => .event,
        else => runtime,
    };
}

fn effectiveRuntime(runtime: RuntimeModel) EffectiveRuntime {
    return switch (resolveRequestedRuntime(runtime)) {
        .single => .single,
        .thread => .thread,
        .event => if (std.Io.Evented == void) .thread else .single,
        .serial, .threaded, .evented => unreachable,
    };
}

fn singleIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn deinitThreadedRuntimeLocked() void {
    if (!threaded_runtime_initialized) {
        threaded_runtime_cleanup_requested = false;
        return;
    }

    threaded_runtime.deinit();
    threaded_runtime_initialized = false;
    threaded_runtime_cleanup_requested = false;
    threaded_runtime = undefined;
}

fn threadedRuntimeCleanupHook(_: ?*anyopaque) callconv(.c) void {
    while (!threaded_runtime_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer threaded_runtime_mutex.unlock();

    threaded_runtime_cleanup_registered = false;
    threaded_runtime_cleanup_requested = true;
    if (threaded_runtime_active_operations == 0) {
        deinitThreadedRuntimeLocked();
    }
}

fn ensureThreadedRuntimeCleanupHookLocked(env_raw: napi.napi_env) !void {
    if (threaded_runtime_cleanup_registered) return;

    const status = napi.napi_add_env_cleanup_hook(env_raw, threadedRuntimeCleanupHook, null);
    if (status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(status));
    }
    threaded_runtime_cleanup_registered = true;
}

fn acquireThreadedRuntime(env_raw: napi.napi_env) !std.Io {
    while (!threaded_runtime_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer threaded_runtime_mutex.unlock();

    if (threaded_runtime_cleanup_requested) {
        return NapiError.Error.fromStatus(NapiError.Status.Closing);
    }

    try ensureThreadedRuntimeCleanupHookLocked(env_raw);

    if (!threaded_runtime_initialized) {
        threaded_runtime = std.Io.Threaded.init(GlobalAllocator.globalAllocator(), .{});
        threaded_runtime_initialized = true;
    }

    threaded_runtime_active_operations += 1;
    return threaded_runtime.io();
}

fn activeThreadedIo() std.Io {
    while (!threaded_runtime_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer threaded_runtime_mutex.unlock();

    std.debug.assert(threaded_runtime_initialized);
    std.debug.assert(threaded_runtime_active_operations > 0);
    return threaded_runtime.io();
}

fn releaseThreadedRuntime() void {
    while (!threaded_runtime_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer threaded_runtime_mutex.unlock();

    if (!threaded_runtime_initialized or threaded_runtime_active_operations == 0) {
        return;
    }

    threaded_runtime_active_operations -= 1;
    if (threaded_runtime_active_operations == 0 and threaded_runtime_cleanup_requested) {
        deinitThreadedRuntimeLocked();
    }
}

fn ioForRuntime(effective_runtime: EffectiveRuntime) std.Io {
    return switch (effective_runtime) {
        .single => singleIo(),
        .thread => activeThreadedIo(),
    };
}

pub fn AsyncContext(comptime Event: type) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        group: *std.Io.Group,
        runtime: RuntimeModel,
        effective_runtime: RuntimeModel,
        cancel_token: *const CancelToken,
        emitter_ptr: ?*anyopaque,
        emit_fn: ?*const fn (?*anyopaque, Event) anyerror!void,

        const Self = @This();

        pub fn emit(self: Self, event: Event) !void {
            if (Event == void) {
                @compileError("AsyncContext(void) does not support emit()");
            }
            try self.cancel_token.check();
            const emit_fn = self.emit_fn orelse return error.InvalidArg;
            const emitter_ptr = self.emitter_ptr orelse return error.InvalidArg;
            try emit_fn(emitter_ptr, event);
        }

        pub fn isCancelled(self: Self) bool {
            return self.cancel_token.isCancelled();
        }

        pub fn checkCancelled(self: Self) !void {
            try self.cancel_token.check();
        }

        pub fn awaitGroup(self: Self) !void {
            try self.group.await(self.io);
        }

        pub fn cancelGroup(self: Self) void {
            self.group.cancel(self.io);
        }
    };
}

pub fn mapAnyError(err: anyerror) NapiError.Error {
    return NapiError.mapAnyError(err);
}

fn createOptionalCallbackRef(env: napi.napi_env, raw: ?napi.napi_value) !?napi.napi_ref {
    const value = raw orelse return null;

    var value_type: napi.napi_valuetype = undefined;
    const typeof_status = napi.napi_typeof(env, value, &value_type);
    if (typeof_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(typeof_status));
    }

    switch (value_type) {
        napi.napi_undefined, napi.napi_null => return null,
        napi.napi_function => {},
        else => return error.InvalidArg,
    }

    var ref: napi.napi_ref = null;
    const ref_status = napi.napi_create_reference(env, value, 1, &ref);
    if (ref_status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(ref_status));
    }
    return ref;
}

fn releaseCallbackRef(env: napi.napi_env, ref: *?napi.napi_ref) void {
    if (ref.*) |actual_ref| {
        _ = napi.napi_delete_reference(env, actual_ref);
        ref.* = null;
    }
}

fn validateTaskRunSignature(comptime Input: type, comptime Result: type, comptime Event: type, comptime RunFn: anytype) void {
    const run_type = @TypeOf(RunFn);
    const info = @typeInfo(run_type);
    if (info != .@"fn") {
        @compileError("Async task runner must be a function");
    }

    const params = info.@"fn".params;
    if (params.len != 1 and params.len != 2) {
        @compileError("Async task runner must accept (input) or (AsyncContext(Event), input)");
    }

    if (params.len == 1) {
        if (params[0].type.? != Input) {
            @compileError("Async task runner input type mismatch");
        }
    } else {
        if (params[0].type.? != AsyncContext(Event)) {
            @compileError("Async task runner context type must be napi.AsyncContext(Event)");
        }
        if (params[1].type.? != Input) {
            @compileError("Async task runner input type mismatch");
        }
    }

    const return_type = info.@"fn".return_type.?;
    switch (@typeInfo(return_type)) {
        .error_union => |eu| {
            if (eu.payload != Result) {
                @compileError("Async task runner return type mismatch");
            }
        },
        else => {
            if (return_type != Result) {
                @compileError("Async task runner return type mismatch");
            }
        },
    }
}

pub fn Async(comptime Result: type, comptime runtime: RuntimeModel) type {
    comptime options.requireNapiVersion(.v4);
    return AsyncTaskDescriptor(Result, void, runtime);
}

pub fn AsyncWithEvents(comptime Result: type, comptime Event: type, comptime runtime: RuntimeModel) type {
    comptime options.requireNapiVersion(.v4);
    return AsyncTaskDescriptor(Result, Event, runtime);
}

fn AsyncTaskDescriptor(comptime Result: type, comptime Event: type, comptime runtime: RuntimeModel) type {
    comptime options.requireNapiVersion(.v4);

    return struct {
        pub const is_napi_async_descriptor = true;
        pub const async_result_type = Result;
        pub const async_event_type = Event;
        pub const async_runtime_model = runtime;
        pub const async_has_events = Event != void;

        base: *AsyncTaskDescriptorBase,

        const Self = @This();

        pub fn from(input: anytype, comptime run_fn: anytype) Self {
            const Input = @TypeOf(input);
            validateTaskRunSignature(Input, Result, Event, run_fn);

            const allocator = GlobalAllocator.globalAllocator();
            const Impl = AsyncTaskDescriptorImpl(Input, Result, Event, runtime, run_fn);
            var impl = allocator.create(Impl) catch @panic("OOM");
            impl.* = .{
                .base = .{
                    .allocator = allocator,
                    .schedule_fn = Impl.schedule,
                    .destroy_fn = Impl.destroy,
                },
                .input = input,
            };
            return .{ .base = &impl.base };
        }

        pub fn schedule(self: *Self, env: Env) !Promise {
            return try self.scheduleWithListenerAndSignal(env, null, null);
        }

        pub fn scheduleWithListener(self: *Self, env: Env, listener: ?napi.napi_value) !Promise {
            return try self.scheduleWithListenerAndSignal(env, listener, null);
        }

        pub fn scheduleWithSignal(self: *Self, env: Env, signal: ?AbortSignal) !Promise {
            return try self.scheduleWithListenerAndSignal(env, null, signal);
        }

        pub fn scheduleWithListenerAndSignal(self: *Self, env: Env, listener: ?napi.napi_value, signal: ?AbortSignal) !Promise {
            const base = self.base;
            return try base.schedule_fn(base, env.raw, listener, signal);
        }

        pub fn deinit(self: *Self) void {
            self.base.destroy_fn(self.base);
        }
    };
}

const AsyncTaskDescriptorBase = struct {
    allocator: std.mem.Allocator,
    schedule_fn: *const fn (*AsyncTaskDescriptorBase, napi.napi_env, ?napi.napi_value, ?AbortSignal) anyerror!Promise,
    destroy_fn: *const fn (*AsyncTaskDescriptorBase) void,
};

fn AsyncTaskDescriptorImpl(
    comptime Input: type,
    comptime Result: type,
    comptime Event: type,
    comptime runtime: RuntimeModel,
    comptime run_fn: anytype,
) type {
    return struct {
        base: AsyncTaskDescriptorBase,
        input: Input,
        input_moved: bool = false,

        const Self = @This();

        fn schedule(base: *AsyncTaskDescriptorBase, env_raw: napi.napi_env, listener: ?napi.napi_value, signal: ?AbortSignal) !Promise {
            const self: *Self = @alignCast(@fieldParentPtr("base", base));
            errdefer base.destroy_fn(base);
            const operation = try AsyncTaskOperation(Input, Result, Event, runtime, run_fn).create(Env.from_raw(env_raw), self.input, listener, signal);
            self.input_moved = true;
            const promise = try operation.submit();
            base.destroy_fn(base);
            return promise;
        }

        fn destroy(base: *AsyncTaskDescriptorBase) void {
            const self: *Self = @alignCast(@fieldParentPtr("base", base));
            if (!self.input_moved) {
                Napi.deinit_napi_value(Input, self.input);
            }
            self.base.allocator.destroy(self);
        }
    };
}

fn AsyncTaskOperation(
    comptime Input: type,
    comptime Result: type,
    comptime Event: type,
    comptime runtime: RuntimeModel,
    comptime run_fn: anytype,
) type {
    return struct {
        allocator: std.mem.Allocator,
        env: napi.napi_env,
        promise: Promise,
        input: Input,
        result: Result = if (Result == void) {} else undefined,
        err: ?NapiError.Error = null,
        listener_ref: ?napi.napi_ref = null,
        abort_registration: ?*AbortRegistration = null,
        cancel_token: CancelToken = .{},
        future: ?std.Io.Future(void) = null,
        controller_future: ?std.Io.Future(void) = null,
        async_work: napi.napi_async_work = null,
        tsfn_raw: napi.napi_threadsafe_function = null,
        state_mutex: std.Io.Mutex = .init,
        state_cond: std.Io.Condition = .init,
        task_done: bool = false,
        cancel_requested: bool = false,
        cancel_dispatched: bool = false,
        closed: bool = false,
        result_ready: bool = false,
        uses_threaded_runtime: bool = false,

        const Self = @This();
        const Context = AsyncContext(Event);
        const run_info = @typeInfo(@TypeOf(run_fn)).@"fn";
        const DispatchKind = enum { event, completion };
        const DispatchData = struct {
            kind: DispatchKind,
            payload: ?*Event = null,
        };

        fn create(env: Env, input: Input, listener: ?napi.napi_value, signal: ?AbortSignal) !*Self {
            const allocator = GlobalAllocator.globalAllocator();
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .env = env.raw,
                .promise = Promise.New(env),
                .input = input,
                .listener_ref = if (Event == void) null else try createOptionalCallbackRef(env.raw, listener),
            };
            errdefer releaseCallbackRef(env.raw, &self.listener_ref);

            if (signal) |abort_signal| {
                self.abort_registration = try abort_signal.bind(@ptrCast(self), requestAbortFromSignal);
            }

            return self;
        }

        fn submit(self: *Self) !Promise {
            errdefer self.destroy(self.env);

            const promise = self.promise;
            if (self.abort_registration != null and self.isAbortRequestedFromSignal()) {
                self.cancel_token.cancel();
                self.cancel_requested = true;
                self.promise.RejectAbortError() catch {};
                self.destroy(self.env);
                return promise;
            }

            switch (effectiveRuntime(runtime)) {
                .single => self.runSingle(),
                .thread => {
                    if (comptime use_wasm_emnapi_async_work) {
                        try self.runWasmAsyncWork();
                        return promise;
                    }

                    const io = try acquireThreadedRuntime(self.env);
                    self.uses_threaded_runtime = true;
                    try self.initThreadDispatcher();
                    self.future = std.Io.concurrent(io, runTask, .{self}) catch |err| {
                        self.err = mapAnyError(err);
                        self.dispatchCompletion(self.env);
                        return promise;
                    };
                    self.controller_future = std.Io.concurrent(io, controllerTask, .{self}) catch |err| {
                        if (self.future) |*future| {
                            future.cancel(io);
                            self.future = null;
                        }
                        self.err = mapAnyError(err);
                        self.dispatchCompletion(self.env);
                        return promise;
                    };
                },
            }
            return promise;
        }

        fn controllerTask(self: *Self) void {
            const io = self.operationIo();
            const should_cancel = self.waitForTaskDoneOrAbort();
            if (self.future) |*future| {
                if (should_cancel) {
                    future.cancel(io);
                    self.cancel_dispatched = true;
                } else {
                    future.await(io);
                }
            }
            self.queueCompletion() catch {};
        }

        fn runSingle(self: *Self) void {
            const io = singleIo();
            var future = std.Io.async(io, runTask, .{self});
            future.await(io);
            self.dispatchCompletion(self.env);
        }

        fn runTask(self: *Self) void {
            defer self.markTaskDone();

            const task_runtime = effectiveRuntime(runtime);
            self.runTaskWithIo(ioForRuntime(task_runtime), switch (task_runtime) {
                .single => .single,
                .thread => .thread,
            });
        }

        fn runTaskWithIo(self: *Self, io: std.Io, effective_runtime: RuntimeModel) void {
            var group: std.Io.Group = .init;
            defer group.cancel(io);

            const context = Context{
                .allocator = self.allocator,
                .io = io,
                .group = &group,
                .runtime = runtime,
                .effective_runtime = effective_runtime,
                .cancel_token = &self.cancel_token,
                .emitter_ptr = if (Event == void) null else @ptrCast(self),
                .emit_fn = if (Event == void) null else emitFromContext,
            };

            NapiError.clearLastError();
            self.execute(context) catch |err| {
                self.err = mapAnyError(err);
                return;
            };
            group.await(io) catch |err| {
                self.err = mapAnyError(err);
            };
        }

        fn runWasmAsyncWork(self: *Self) !void {
            try self.initThreadDispatcher();

            const resource_name = String.New(Env.from_raw(self.env), "ZigAsyncTask");
            var async_work: napi.napi_async_work = null;
            const create_status = napi.napi_create_async_work(
                self.env,
                null,
                resource_name.raw,
                wasmAsyncWorkExecute,
                wasmAsyncWorkComplete,
                @ptrCast(self),
                &async_work,
            );
            if (create_status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(create_status));
            }
            self.async_work = async_work;

            const queue_status = napi.napi_queue_async_work(self.env, async_work);
            if (queue_status != napi.napi_ok) {
                _ = napi.napi_delete_async_work(self.env, async_work);
                self.async_work = null;
                return NapiError.Error.fromStatus(NapiError.Status.New(queue_status));
            }
        }

        fn wasmAsyncWorkExecute(_: napi.napi_env, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            self.runTaskWithIo(singleIo(), .thread);
        }

        fn wasmAsyncWorkComplete(inner_env: napi.napi_env, status: napi.napi_status, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            if (status == napi.napi_cancelled) {
                self.cancel_dispatched = true;
            }
            if (self.async_work != null) {
                _ = napi.napi_delete_async_work(inner_env, self.async_work);
                self.async_work = null;
            }
            self.queueCompletion() catch {
                self.dispatchCompletion(inner_env);
            };
        }

        fn isAbortRequestedFromSignal(self: *Self) bool {
            if (self.abort_registration) |registration| {
                var signal_value: napi.napi_value = undefined;
                const ref_status = napi.napi_get_reference_value(self.env, registration.signal_ref, &signal_value);
                if (ref_status != napi.napi_ok or signal_value == null) return false;
                return AbortSignal.from_raw(self.env, signal_value).isAborted() catch false;
            }
            return false;
        }

        fn requestAbortFromSignal(ptr: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.requestAbort();
        }

        fn requestAbort(self: *Self) void {
            const io = self.operationIo();
            self.cancel_token.cancel();
            self.state_mutex.lockUncancelable(io);
            defer self.state_mutex.unlock(io);
            if (self.task_done) return;
            self.cancel_requested = true;
            if (comptime use_wasm_emnapi_async_work) {
                if (self.async_work != null) {
                    _ = napi.napi_cancel_async_work(self.env, self.async_work);
                }
            }
            self.state_cond.signal(io);
        }

        fn markTaskDone(self: *Self) void {
            const io = self.operationIo();
            self.state_mutex.lockUncancelable(io);
            defer self.state_mutex.unlock(io);
            self.task_done = true;
            self.state_cond.signal(io);
        }

        fn waitForTaskDoneOrAbort(self: *Self) bool {
            const io = self.operationIo();
            self.state_mutex.lockUncancelable(io);
            defer self.state_mutex.unlock(io);

            while (!self.task_done and !self.cancel_requested) {
                self.state_cond.waitUncancelable(io, &self.state_mutex);
            }
            return self.cancel_requested and !self.task_done;
        }

        fn operationIo(self: *const Self) std.Io {
            return if (self.uses_threaded_runtime) activeThreadedIo() else singleIo();
        }

        fn execute(self: *Self, context: Context) !void {
            if (run_info.params.len == 1) {
                if (@typeInfo(run_info.return_type.?) == .error_union) {
                    if (Result == void) {
                        try run_fn(self.input);
                    } else {
                        self.result = try run_fn(self.input);
                        self.result_ready = true;
                    }
                } else {
                    if (Result == void) {
                        _ = run_fn(self.input);
                    } else {
                        self.result = run_fn(self.input);
                        self.result_ready = true;
                    }
                }
            } else {
                if (@typeInfo(run_info.return_type.?) == .error_union) {
                    if (Result == void) {
                        try run_fn(context, self.input);
                    } else {
                        self.result = try run_fn(context, self.input);
                        self.result_ready = true;
                    }
                } else {
                    if (Result == void) {
                        _ = run_fn(context, self.input);
                    } else {
                        self.result = run_fn(context, self.input);
                        self.result_ready = true;
                    }
                }
            }
        }

        fn emitFromContext(ptr: ?*anyopaque, event: Event) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.cancel_token.check();

            switch (effectiveRuntime(runtime)) {
                .single => self.dispatchEvent(self.env, event),
                .thread => {
                    const payload = try self.allocator.create(Event);
                    payload.* = event;
                    errdefer self.allocator.destroy(payload);

                    const data = try self.allocator.create(DispatchData);
                    data.* = .{ .kind = .event, .payload = payload };
                    errdefer self.allocator.destroy(data);

                    const status = napi.napi_call_threadsafe_function(self.tsfn_raw, @ptrCast(data), napi.napi_tsfn_nonblocking);
                    if (status != napi.napi_ok) {
                        return NapiError.Error.fromStatus(NapiError.Status.New(status));
                    }
                },
            }
        }

        fn dispatchEvent(self: *Self, env_raw: napi.napi_env, event: Event) void {
            if (Event == void or self.listener_ref == null) return;

            var callback: napi.napi_value = undefined;
            const get_ref_status = napi.napi_get_reference_value(env_raw, self.listener_ref.?, &callback);
            if (get_ref_status != napi.napi_ok) return;

            const event_value = Napi.to_napi_value(env_raw, event, null) catch return;
            const undefined_value = Undefined.New(Env.from_raw(env_raw));
            const argv = [1]napi.napi_value{event_value};
            var ignored: napi.napi_value = undefined;
            _ = napi.napi_call_function(env_raw, undefined_value.raw, callback, argv.len, &argv, &ignored);
        }

        fn queueCompletion(self: *Self) !void {
            const data = try self.allocator.create(DispatchData);
            data.* = .{ .kind = .completion };
            errdefer self.allocator.destroy(data);

            const status = napi.napi_call_threadsafe_function(self.tsfn_raw, @ptrCast(data), napi.napi_tsfn_nonblocking);
            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        fn dispatchCompletion(self: *Self, env_raw: napi.napi_env) void {
            if (self.controller_future) |*controller_future| {
                controller_future.await(self.operationIo());
                self.controller_future = null;
                self.future = null;
            } else if (self.future) |*future| {
                future.await(self.operationIo());
                self.future = null;
            }

            const promise = self.promise;
            var settled_value: ?napi.napi_value = null;
            var should_reject = false;

            if (self.cancel_dispatched or self.cancel_requested) {
                settled_value = AbortSignalModule.abortErrorValue(Env.from_raw(env_raw));
                should_reject = true;
            } else if (self.err) |err| {
                settled_value = err.to_napi_error(Env.from_raw(env_raw));
                should_reject = true;
            } else if (Result == void) {
                settled_value = Undefined.New(Env.from_raw(env_raw)).raw;
            } else {
                settled_value = Napi.to_napi_value(env_raw, self.result, null) catch null;
            }

            self.destroy(env_raw);

            if (settled_value) |value| {
                const status = if (should_reject)
                    napi.napi_reject_deferred(env_raw, promise.deferred, value)
                else
                    napi.napi_resolve_deferred(env_raw, promise.deferred, value);
                _ = status;
            }
        }

        fn initThreadDispatcher(self: *Self) !void {
            const resource_name = String.New(Env.from_raw(self.env), "ZigAsyncTask");
            var dispatcher_fn: napi.napi_value = undefined;
            const create_fn_status = napi.napi_create_function(
                self.env,
                "zigAsyncTask",
                "zigAsyncTask".len,
                dispatcherNoop,
                null,
                &dispatcher_fn,
            );
            if (create_fn_status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(create_fn_status));
            }

            var tsfn_raw: napi.napi_threadsafe_function = null;
            const create_status = napi.napi_create_threadsafe_function(
                self.env,
                dispatcher_fn,
                null,
                resource_name.raw,
                0,
                1,
                null,
                dispatcherFinalize,
                @ptrCast(self),
                dispatcherCallJs,
                &tsfn_raw,
            );
            if (create_status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(create_status));
            }
            self.tsfn_raw = tsfn_raw;
        }

        fn dispatcherNoop(inner_env: napi.napi_env, _: napi.napi_callback_info) callconv(.c) napi.napi_value {
            return Undefined.New(Env.from_raw(inner_env)).raw;
        }

        fn dispatcherFinalize(_: napi.napi_env, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

        fn dispatcherCallJs(inner_env: napi.napi_env, _: napi.napi_value, context: ?*anyopaque, raw_data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const data: *DispatchData = @ptrCast(@alignCast(raw_data));
            const allocator = self.allocator;

            switch (data.kind) {
                .event => {
                    defer allocator.destroy(data);
                    if (Event != void and data.payload != null) {
                        const payload = data.payload.?;
                        defer allocator.destroy(payload);
                        self.dispatchEvent(inner_env, payload.*);
                    }
                },
                .completion => {
                    allocator.destroy(data);
                    self.dispatchCompletion(inner_env);
                    return;
                },
            }
        }

        fn destroy(self: *Self, env_raw: napi.napi_env) void {
            if (self.closed) return;
            self.closed = true;
            const should_release_threaded_runtime = self.uses_threaded_runtime;
            self.uses_threaded_runtime = false;

            releaseCallbackRef(env_raw, &self.listener_ref);
            if (self.abort_registration) |registration| {
                registration.release();
                self.abort_registration = null;
            }
            if (self.tsfn_raw != null) {
                _ = napi.napi_release_threadsafe_function(self.tsfn_raw, napi.napi_tsfn_release);
                self.tsfn_raw = null;
            }
            if (self.async_work != null) {
                _ = napi.napi_delete_async_work(env_raw, self.async_work);
                self.async_work = null;
            }
            var deinit_state = Napi.DeinitState{};
            Napi.deinit_napi_value_with_state(Input, self.input, &deinit_state);
            if (comptime Result != void) {
                if (self.result_ready) {
                    Napi.deinit_napi_value_with_state(Result, self.result, &deinit_state);
                }
            }
            self.allocator.destroy(self);
            if (should_release_threaded_runtime) {
                releaseThreadedRuntime();
            }
        }
    };
}

test "Async descriptor exposes runtime metadata" {
    const Task = Async(u32, .thread);
    try std.testing.expect(Task.is_napi_async_descriptor);
    try std.testing.expect(Task.async_result_type == u32);
    try std.testing.expect(Task.async_event_type == void);
    try std.testing.expect(Task.async_runtime_model == .thread);
}

test "AsyncWithEvents descriptor marks callback support" {
    const Event = struct { current: u32 };
    const Task = AsyncWithEvents(u32, Event, .single);
    try std.testing.expect(Task.async_has_events);
    try std.testing.expect(Task.async_event_type == Event);
}
