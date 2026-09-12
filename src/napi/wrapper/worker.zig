const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const napi_env = @import("../env.zig");
const String = @import("../value/string.zig").String;
const Promise = @import("../value/promise.zig").Promise;
const NapiError = @import("./error.zig");
const GlobalAllocator = @import("../util/allocator.zig");
const ownership = @import("../util/async_ownership.zig");

const WorkerStatus = enum {
    Pending,
    Resolved,
    Rejected,
    Cancelled,
};

pub fn WorkerContext(comptime T: type) type {
    const has_data = comptime @hasField(T, "data");
    const has_execute = comptime @hasField(T, "Execute");
    const has_on_complete = comptime @hasField(T, "OnComplete");

    if (!has_data) {
        @compileError("Worker must init with data field");
    }
    if (!has_execute) {
        @compileError("Worker must init with Execute field");
    }
    if (@typeInfo(T) != .@"struct") {
        @compileError("Worker init data must be a struct");
    }

    const DataType = @TypeOf(@as(T, undefined).data);
    const ExecuteFn = @TypeOf(@as(T, undefined).Execute);
    const ExecuteInfo = @typeInfo(ExecuteFn);
    if (ExecuteInfo != .@"fn") {
        @compileError("Execute must be a function");
    }

    const ExecuteReturn = ExecuteInfo.@"fn".return_type.?;
    const ExecuteReturnPayload = switch (@typeInfo(ExecuteReturn)) {
        .error_union => |eu| eu.payload,
        else => ExecuteReturn,
    };
    const ExecutePayload = if (comptime NapiError.isResult(ExecuteReturnPayload))
        NapiError.resultPayload(ExecuteReturnPayload)
    else
        ExecuteReturnPayload;

    comptime validateExecuteSignature(DataType, ExecuteFn);

    if (has_on_complete) {
        const OnComplete = @TypeOf(@as(T, undefined).OnComplete);
        if (@typeInfo(OnComplete) != .@"fn") {
            @compileError("OnComplete must be a function");
        }
        comptime validateOnCompleteSignature(DataType, OnComplete);
    }

    return struct {
        data: T,
        env: napi.napi_env,
        raw: napi.napi_async_work,
        allocator: std.mem.Allocator,
        /// The runner's payload. It is borrowed unless the runner returns an
        /// explicit `napi.Owned(...)` value, in which case the worker disposes
        /// it after the promise has been settled.
        result: ExecutePayload = if (ExecutePayload == void) {} else undefined,
        result_ready: bool = false,
        err: ?NapiError.Error = null,
        status: WorkerStatus = .Pending,
        promise: ?Promise = null,
        freed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        const Self = @This();

        /// Create a worker. Creation failures are stored on the instance and
        /// reported by `tryQueue`/`AsyncQueue` instead of aborting the process.
        pub fn New(env: napi_env.Env, init_data: anytype) *Self {
            const allocator = GlobalAllocator.globalAllocator();
            const self = allocator.create(Self) catch @panic("OOM");

            self.* = .{
                .data = init_data,
                .env = env.raw,
                .raw = null,
                .allocator = allocator,
            };

            const async_resource_name = String.New(env, "AsyncWorkerCallback");

            var result: napi.napi_async_work = null;
            const status = napi.napi_create_async_work(
                env.raw,
                null,
                async_resource_name.raw,
                execute,
                complete,
                @ptrCast(self),
                &result,
            );
            if (status != napi.napi_ok) {
                self.status = .Rejected;
                self.err = NapiError.Error.withStatus(NapiError.Status.New(status));
                return self;
            }

            self.raw = result;
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.freed.swap(true, .acq_rel)) return;
            if (self.raw != null) {
                _ = napi.napi_delete_async_work(self.env, self.raw);
                self.raw = null;
            }
            self.promise = null;
            self.allocator.destroy(self);
        }

        /// Legacy fire-and-forget queue entry point.
        ///
        /// Failures are recorded on the worker (`status`/`err`) and reject a
        /// pending `AsyncQueue` promise; use `tryQueue` to observe them.
        pub fn Queue(self: *Self) void {
            self.tryQueue() catch {};
        }

        pub fn tryQueue(self: *Self) !void {
            if (self.raw == null) {
                const err = self.err orelse NapiError.Error.withCodeAndMessage("ERR_NAPI_WORKER_NOT_CREATED", "Worker was not created");
                self.rejectPending(err);
                return toAnyError(err);
            }
            const status = napi.napi_queue_async_work(self.env, self.raw);
            if (status != napi.napi_ok) {
                const err = NapiError.Error.withStatus(NapiError.Status.New(status));
                self.rejectPending(err);
                return toAnyError(err);
            }
        }

        /// Queue the work and return the promise that settles when it is done.
        ///
        /// Every failure path (creation, queueing, cancellation, conversion)
        /// settles or rejects the returned promise; it can never stay pending.
        pub fn AsyncQueue(self: *Self) !Promise {
            if (self.promise != null) {
                return NapiError.Error.fromStatus(@as([]const u8, "This worker already has a pending promise"));
            }

            const promise = try Promise.New(napi_env.Env.from_raw(self.env));
            self.promise = promise;

            self.tryQueue() catch |err| {
                // tryQueue already rejected the promise; drop our reference to
                // it so `deinit` cannot settle it twice.
                self.promise = null;
                return err;
            };
            return promise;
        }

        pub fn Cancel(self: *Self) void {
            if (self.raw == null) return;
            _ = napi.napi_cancel_async_work(self.env, self.raw);
        }

        fn rejectPending(self: *Self, err: NapiError.Error) void {
            if (self.promise) |promise| {
                var mutable = promise;
                mutable.Reject(err) catch {};
                self.promise = null;
            }
            self.status = .Rejected;
            self.err = err;
        }

        fn execute(inner_env: napi.napi_env, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            NapiError.clearLastError();
            self.run(inner_env) catch |err| {
                self.status = .Rejected;
                self.err = NapiError.mapAnyError(err);
                return;
            };
            self.status = .Resolved;
        }

        fn complete(inner_env: napi.napi_env, status: napi.napi_status, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            defer self.deinit();

            if (status == napi.napi_cancelled) {
                self.status = .Cancelled;
            }

            const env = napi_env.Env.from_raw(inner_env);
            switch (self.status) {
                .Rejected => {
                    const err = self.err orelse NapiError.Error.withCodeAndMessage("ERR_NAPI_WORKER_FAILED", "Worker failed");
                    self.settleReject(env, err);
                },
                .Cancelled => {
                    // A cancelled worker must not leave its promise pending.
                    self.settleAbort(env);
                },
                .Resolved => {
                    self.settleResolve(env);
                },
                else => {},
            }

            if (comptime has_on_complete) {
                callOnComplete(self.data, env);
            }
        }

        fn settleReject(self: *Self, env: napi_env.Env, err: NapiError.Error) void {
            if (self.promise) |promise| {
                var mutable = promise;
                mutable.Reject(err) catch {
                    if (NapiError.last_error) |last_err| {
                        last_err.throwInto(env);
                    }
                };
            } else {
                err.throwInto(env);
            }
        }

        fn settleAbort(self: *Self, env: napi_env.Env) void {
            if (self.promise) |promise| {
                var mutable = promise;
                mutable.RejectAbortError() catch {
                    if (NapiError.last_error) |last_err| {
                        last_err.throwInto(env);
                    }
                };
            }
        }

        fn settleResolve(self: *Self, env: napi_env.Env) void {
            _ = env;
            if (self.promise) |promise| {
                var mutable = promise;
                if (ExecutePayload == void) {
                    mutable.Resolve({}) catch {};
                } else if (self.result_ready) {
                    mutable.Resolve(self.result) catch |err| {
                        // Result conversion failed: reject instead of leaving
                        // the promise pending.
                        var rejectable = promise;
                        rejectable.Reject(NapiError.mapAnyError(err)) catch {};
                    };
                    // Plain payloads are borrowed; only explicit `Owned`
                    // values are disposed here.
                    ownership.disposeOwnedParts(ExecutePayload, self.result, self.allocator);
                } else {
                    var rejectable = promise;
                    rejectable.Reject(NapiError.Error.withCodeAndMessage("ERR_NAPI_WORKER_NO_RESULT", "Worker did not produce a result")) catch {};
                }
            }
        }

        fn run(self: *Self, inner_env: napi.napi_env) !void {
            const execute_fn = self.data.Execute;
            const Runner = struct {
                fn storeResult(this: *Self, result: anytype) !void {
                    if (comptime NapiError.isResult(@TypeOf(result))) {
                        switch (result) {
                            .ok => |payload| {
                                if (ExecutePayload != void) {
                                    this.result = payload;
                                    this.result_ready = true;
                                }
                            },
                            .err => |err| {
                                NapiError.last_error = err;
                                return error.GenericFailure;
                            },
                        }
                        return;
                    }

                    if (ExecutePayload != void) {
                        this.result = result;
                        this.result_ready = true;
                    }
                }
            };

            if (@typeInfo(ExecuteReturn) == .error_union) {
                const result = if (ExecuteInfo.@"fn".params.len == 1)
                    try execute_fn(self.data.data)
                else
                    try execute_fn(napi_env.Env.from_raw(inner_env), self.data.data);
                try Runner.storeResult(self, result);
            } else {
                const result = if (ExecuteInfo.@"fn".params.len == 1)
                    execute_fn(self.data.data)
                else
                    execute_fn(napi_env.Env.from_raw(inner_env), self.data.data);
                try Runner.storeResult(self, result);
            }
        }
    };
}

fn toAnyError(err: NapiError.Error) anyerror {
    NapiError.last_error = err;
    return error.GenericFailure;
}

fn validateExecuteSignature(comptime DataType: type, comptime ExecuteFn: type) void {
    const info = @typeInfo(ExecuteFn).@"fn";
    if (info.params.len != 1 and info.params.len != 2) {
        @compileError("Worker Execute must accept (data) or (napi.Env, data)");
    }

    if (info.params.len == 1) {
        if (info.params[0].type.? != DataType) {
            @compileError("Worker Execute data type mismatch");
        }
    } else {
        if (info.params[0].type.? != napi_env.Env) {
            @compileError("Worker Execute first parameter must be napi.Env");
        }
        if (info.params[1].type.? != DataType) {
            @compileError("Worker Execute data type mismatch");
        }
    }
}

fn validateOnCompleteSignature(comptime DataType: type, comptime OnCompleteFn: type) void {
    const info = @typeInfo(OnCompleteFn).@"fn";
    if (info.params.len != 1 and info.params.len != 2) {
        @compileError("Worker OnComplete must accept (data) or (napi.Env, data)");
    }

    if (info.params.len == 1) {
        if (info.params[0].type.? != DataType) {
            @compileError("Worker OnComplete data type mismatch");
        }
    } else {
        if (info.params[0].type.? != napi_env.Env) {
            @compileError("Worker OnComplete first parameter must be napi.Env");
        }
        if (info.params[1].type.? != DataType) {
            @compileError("Worker OnComplete data type mismatch");
        }
    }
}

fn callOnComplete(data: anytype, env: napi_env.Env) void {
    const OnCompleteFn = @TypeOf(data.OnComplete);
    const info = @typeInfo(OnCompleteFn).@"fn";
    if (info.params.len == 1) {
        data.OnComplete(data.data);
    } else {
        data.OnComplete(env, data.data);
    }
}

pub fn Worker(env: napi_env.Env, data: anytype) *WorkerContext(@TypeOf(data)) {
    return WorkerContext(@TypeOf(data)).New(env, data);
}
