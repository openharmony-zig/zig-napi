const std = @import("std");
const napi = @import("napi-sys").napi_sys;
const napi_env = @import("../env.zig");
const String = @import("../value/string.zig").String;
const Promise = @import("../value/promise.zig").Promise;
const NapiError = @import("./error.zig");
const GlobalAllocator = @import("../util/allocator.zig");
const ownership = @import("../util/async_ownership.zig");
const helper = @import("../util/helper.zig");

const WorkerStatus = enum {
    Pending,
    Resolved,
    Rejected,
    Cancelled,
};

/// How a worker treats the `data` field of its init struct.
///
/// See `Worker` for the contract and `WorkerBorrowed` for the explicit entry
/// point of the borrowed mode.
pub const DataTransfer = enum {
    /// Default. `data` is deep-copied into memory the worker owns before the
    /// work item is created, so the worker never reads memory that a JavaScript
    /// call scope has already released. The copy is released exactly once, after
    /// the result has been converted and after `OnComplete` has returned.
    ///
    /// Supported shapes are the ones the conversion layer can deep-copy: native
    /// values, slices, optionals, arrays, structs/unions of those and `Owned`
    /// wrappers. JavaScript handles, error payloads (their text is borrowed, so
    /// a copy would still alias the call scope) and non-slice pointers are
    /// rejected at compile time - name someone else's resource with
    /// `DataTransfer.borrowed` instead.
    capture,
    /// `data` is stored as it is and is never released by the worker.
    ///
    /// The caller keeps ownership and has to keep the value alive until
    /// `OnComplete` has returned - and, for a value whose lifetime is managed by
    /// an acquisition (a `*ThreadSafeFunction` acquired with `acquire`, a
    /// reference counted resource), until its own release runs. Releasing it in
    /// `OnComplete` is the manual transfer mode.
    borrowed,
};

/// Compile time transfer mode of an init struct type.
///
/// * `napi.Worker` uses the `pub const data_transfer: napi.WorkerDataTransfer`
///   declaration of the init struct, defaulting to `capture`.
/// * `napi.WorkerBorrowed` forces `borrowed` and rejects a conflicting
///   declaration instead of silently ignoring it.
fn transferMode(comptime T: type, comptime forced: ?DataTransfer) DataTransfer {
    if (comptime @hasField(T, "data_transfer")) {
        @compileError("Worker `data_transfer` must be a declaration, not a field: declare " ++
            "`pub const data_transfer: napi.WorkerDataTransfer = .borrowed;` on " ++ @typeName(T) ++
            " - the transfer mode has to be known at compile time.");
    }

    const declared: ?DataTransfer = if (comptime @hasDecl(T, "data_transfer"))
        @field(T, "data_transfer")
    else
        null;

    if (forced) |mode| {
        if (declared) |declared_mode| {
            if (declared_mode != mode) {
                @compileError(@typeName(T) ++ " declares `data_transfer = ." ++ @tagName(declared_mode) ++
                    "`, which conflicts with the worker entry point used (." ++ @tagName(mode) ++ ")");
            }
        }
        return mode;
    }

    return declared orelse .capture;
}

/// True when `T` is a native value shape the capture path can deep-copy.
///
/// Mirrors the shapes `Napi.clone_napi_value` handles. JavaScript handles are
/// not capturable - a handle belongs to one `napi_env` and must not become
/// shared state with the worker thread - and neither is a pointer that is not a
/// slice: copying the pointer would not copy the value it names, so the worker
/// would still read the caller's memory.
fn canCapture(comptime T: type) bool {
    if (comptime helper.isOwned(T)) return canCapture(helper.ownedPayload(T));
    // An error payload borrows its message and code text. Copying the payload
    // would copy the pointers, not the text, so a captured error would still
    // read the caller's memory after the call scope released it - the exact
    // failure the capture mode exists to prevent. Rejected, not silently
    // shared: convert the message to an owned string (`allocator.dupe`) or use
    // the borrowed mode and keep the error alive until `OnComplete` returned.
    if (comptime helper.isErrorValue(T)) return false;
    if (comptime helper.isJsHandle(T)) return false;

    const infos = @typeInfo(T);
    if (comptime helper.stringLike(T) != .Unknown) {
        // Slices are copied, fixed arrays are copied by value.
        return true;
    }
    if (comptime helper.isDts(T)) {
        if (comptime !@hasField(T, "value")) return false;
        return canCapture(T.wrapped_type);
    }
    if (comptime helper.isArrayList(T)) return canCapture(helper.getArrayListElementType(T));

    switch (infos) {
        .bool, .int, .float, .comptime_int, .comptime_float, .@"enum", .null, .undefined, .void => return true,
        .optional => |optional| return canCapture(optional.child),
        .array => |array| return canCapture(array.child),
        .pointer => |ptr| return ptr.size == .slice and canCapture(ptr.child),
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (!canCapture(field.type)) return false;
            }
            return true;
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) return false;
            inline for (union_info.fields) |field| {
                if (!canCapture(field.type)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// True when the `data` field of the init struct is a compile time constant.
///
/// An anonymous struct literal infers a comptime field for every comptime known
/// value, so `.{ .data = "literal", ... }` and `.{ .data = @as(u32, 1), ... }`
/// are constants. A constant cannot dangle, so the capture mode neither copies
/// nor releases it.
fn payloadIsStatic(comptime T: type) bool {
    return comptime blk: {
        for (@typeInfo(T).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, "data")) break :blk field.is_comptime;
        }
        break :blk false;
    };
}

/// A worker created by `Worker` with the transfer mode resolved from `T`.
pub fn WorkerContext(comptime T: type) type {
    return WorkerContextWith(T, transferMode(T, null));
}

/// A worker with an explicitly chosen transfer mode.
pub fn WorkerContextWith(comptime T: type, comptime transfer: DataTransfer) type {
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

    // The payload is passed to `Execute` by value, so it needs a concrete type.
    const payload_is_static = comptime payloadIsStatic(T);
    if (comptime @typeInfo(DataType) == .comptime_int or @typeInfo(DataType) == .comptime_float) {
        @compileError("Worker data must have a concrete type: write `.data = @as(u32, 0)` (or declare a " ++
            "named options struct type) instead of a bare number literal, because the payload is passed " ++
            "to Execute by value.");
    }

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
        /// explicit `napi.Owned(...)` value; owned parts are released by the
        /// final cleanup, after the result conversion and after `OnComplete`.
        result: ExecutePayload = if (ExecutePayload == void) {} else undefined,
        result_ready: bool = false,
        result_disposed: bool = false,
        err: ?NapiError.Error = null,
        /// Owns the text of `err` when the error was produced by the runner
        /// (its message may live in the runner thread's error slots).
        err_snapshot: ?ownership.ErrorSnapshot = null,
        status: WorkerStatus = .Pending,
        promise: ?Promise = null,
        /// The work item was handed to the runtime; its completion callback is
        /// still owed to this worker.
        queued: bool = false,
        /// The completion callback is running (`OnComplete` included). A
        /// `deinit` from inside it may not free the worker under its own feet.
        in_completion: bool = false,
        /// The completion callback already ran: the work item can never be
        /// queued again.
        completed: bool = false,
        /// `data.data` is a private copy made by the capture mode.
        payload_captured: bool = false,
        freed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        const Self = @This();

        /// Create a worker, reporting every failure to the caller.
        ///
        /// Failure leaks nothing: the capture, the work item and the shell are
        /// released before the error is returned.
        pub fn tryNew(env: napi_env.Env, init_data: anytype) !*Self {
            const self = try create(env, init_data);
            errdefer self.destroyNow();
            try self.createWork(env);
            return self;
        }

        /// Create a worker without a failure channel.
        ///
        /// Documented OOM policy: allocating the worker (or its captured data)
        /// cannot be reported through a constructor that must return a pointer,
        /// so it aborts the process. Use `tryNew` when the caller can report a
        /// failure to JavaScript. A failure of `napi_create_async_work` is *not*
        /// fatal: it is recorded and reported by `tryQueue`/`AsyncQueue`.
        pub fn New(env: napi_env.Env, init_data: anytype) *Self {
            const self = create(env, init_data) catch {
                @panic("zig-napi: out of memory while creating a Worker (use tryNew to handle it)");
            };
            self.createWork(env) catch |err| {
                self.status = .Rejected;
                self.err = NapiError.mapAnyError(err);
            };
            return self;
        }

        /// Request the release of this worker.
        ///
        /// * not queued: the worker, its captured data and its work item are
        ///   released immediately;
        /// * queued or running: the release is deferred to the completion
        ///   callback, which still settles the promise and runs `OnComplete`.
        ///   Cancelling the work is `Cancel`, not `deinit`.
        ///
        /// A worker is a self-owning handle: this may only be called while the
        /// worker is alive, that is on the JavaScript thread that created it,
        /// before the completion callback ran and after a setup failure already
        /// released it. Releasing an already released worker is undefined
        /// behaviour, exactly like using any other freed pointer; `deinit` from
        /// `OnComplete` is what the deferred path above is for, and it is safe
        /// because the completion callback is still its owner.
        pub fn deinit(self: *Self) void {
            if (self.queued or self.in_completion) return;
            self.destroyNow();
        }

        /// Fire-and-forget queue entry point.
        ///
        /// `Queue` hands the worker over: it releases itself when the completion
        /// callback has run, and it releases itself immediately when the work
        /// cannot be queued - this entry point has no way to report that failure.
        /// A caller that has to know whether the work was accepted uses
        /// `tryQueue` or `AsyncQueue`, which report the failure *and* release
        /// the worker.
        pub fn Queue(self: *Self) void {
            self.tryQueue() catch {};
        }

        /// Hand the work item to the runtime.
        ///
        /// A worker can only be queued once. Failures are reported to the
        /// caller *and* release the worker exactly once (queue failure means its
        /// completion callback will never run): the captured data, the work item
        /// and the shell are gone when the error arrives, so nothing has to be
        /// cleaned up and any promise is released without a settlement. The
        /// returned error is therefore also the end of the worker's lifetime -
        /// the pointer must not be used again.
        pub fn tryQueue(self: *Self) !void {
            if (self.queued or self.completed) {
                // A second queue would either be refused by N-API or run the
                // completion callback twice, settling one promise twice.
                return toAnyError(NapiError.Error.withCodeAndMessage(
                    "ERR_NAPI_WORKER_ALREADY_QUEUED",
                    "This worker has already been queued",
                ));
            }

            if (self.raw == null) {
                const err = self.err orelse NapiError.Error.withCodeAndMessage(
                    "ERR_NAPI_WORKER_NOT_CREATED",
                    "Worker was not created",
                );
                self.releaseAfterQueueFailure();
                return toAnyError(err);
            }

            const status = napi.napi_queue_async_work(self.env, self.raw);
            if (status != napi.napi_ok) {
                const err = NapiError.Error.withStatus(NapiError.Status.New(status));
                self.releaseAfterQueueFailure();
                return toAnyError(err);
            }

            self.queued = true;
        }

        /// Queue the work and return the promise that settles when it is done.
        ///
        /// The promise is returned only after the work item was accepted by the
        /// runtime, so a rejected or pending-forever promise is never published
        /// to JavaScript: setup failures are thrown synchronously instead, and
        /// the unpublished promise is released without an unhandled rejection.
        /// Every failure path releases the worker, so the pointer must not be
        /// used after an error was returned.
        pub fn AsyncQueue(self: *Self) !Promise {
            if (self.promise != null or self.queued or self.completed) {
                return NapiError.Error.fromStatus(@as([]const u8, "This worker already has a pending promise"));
            }

            // The promise is created first: it is the only failure that happens
            // before the work item is handed over, and it may not leave the
            // worker and its captured data behind either.
            const promise = Promise.New(napi_env.Env.from_raw(self.env)) catch |err| {
                self.releaseAfterQueueFailure();
                return err;
            };
            self.promise = promise;

            // A failure releases the worker (and the promise above, which was
            // never handed to JavaScript) before the error is returned.
            try self.tryQueue();
            return promise;
        }

        /// Ask the runtime to cancel a queued work item.
        ///
        /// Cancellation is cooperative: once the runner started executing, the
        /// cancel request is ignored and the promise settles with the result.
        /// A cancelled work item settles its promise with an `AbortError`
        /// instead of leaving it pending.
        ///
        /// Like every other life-cycle call this belongs to the JavaScript
        /// thread that created the worker, and it is only meaningful while the
        /// work item is queued.
        pub fn Cancel(self: *Self) void {
            if (self.raw == null or !self.queued) return;
            _ = napi.napi_cancel_async_work(self.env, self.raw);
        }

        /// Roll back a worker whose work item never reached the runtime.
        ///
        /// There is no completion callback for a work item that was not queued
        /// and `napi_delete_async_work` may not be called for a work item the
        /// runtime still owns, so this path releases everything here: the
        /// unpublished promise is settled silently (never as an unhandled
        /// rejection), then the captured data, the work item and the shell are
        /// gone. The error value the caller receives is a copy taken before the
        /// worker (and the recorded error) is released.
        fn releaseAfterQueueFailure(self: *Self) void {
            self.settleUnpublishedPromise();
            self.status = .Rejected;
            self.destroyNow();
        }

        /// Release everything this worker owns, exactly once.
        ///
        /// Order matters: the result may alias the captured data, so the result
        /// is released first, and the captured data last - after the result
        /// conversion and after `OnComplete` have finished with it.
        fn destroyNow(self: *Self) void {
            // Guards the repeated release of a live worker (a second `deinit`
            // before it was queued, a failure path that already rolled back).
            // The freed memory itself is not handed back by any entry point:
            // the caller owns the lifetime rules described on `deinit`.
            if (self.freed.swap(true, .acq_rel)) return;

            self.releaseResult();
            self.releasePayload();

            if (self.raw != null) {
                _ = napi.napi_delete_async_work(self.env, self.raw);
                self.raw = null;
            }
            if (self.err_snapshot) |*snapshot| {
                snapshot.deinit();
                self.err_snapshot = null;
            }
            // A promise that reached this point was settled by the completion
            // callback or is the unpublished promise of a failed setup, which
            // `releaseAfterQueueFailure` settles before the release. A settled
            // promise is never touched again (see `takePromise`).
            self.promise = null;
            self.allocator.destroy(self);
        }

        /// Dispose the explicitly owned parts of the runner's result.
        ///
        /// Plain payloads are borrowed and left untouched; `Owned` payloads (at
        /// the top level or nested) are released here. This runs after the
        /// promise conversion copied the value into JavaScript and after
        /// `OnComplete` returned, and only once, so the payload cannot be freed
        /// while it is still in use and cannot be freed twice.
        fn releaseResult(self: *Self) void {
            if (comptime ExecutePayload == void) return;
            if (!self.result_ready or self.result_disposed) return;
            self.result_disposed = true;
            ownership.disposeOwnedParts(ExecutePayload, self.result, self.allocator);
        }

        /// Release the captured copy of `data.data`, exactly once.
        ///
        /// Only the capture mode owns a copy; a borrowed value belongs to the
        /// caller and is never released here.
        fn releasePayload(self: *Self) void {
            if (!self.payload_captured) return;
            self.payload_captured = false;
            ownership.deinitValue(DataType, self.data.data, self.allocator);
        }

        /// Settle a promise that was created but never published.
        ///
        /// The only promise a worker can be released with is one whose setup
        /// failed before it was handed to JavaScript; it is settled silently so
        /// that releasing the deferred can never turn into an unhandled
        /// rejection. A promise that was already settled is not touched here:
        /// its settlement state may have been released together with the
        /// deferred.
        fn settleUnpublishedPromise(self: *Self) void {
            const promise = self.takePromise() orelse return;
            var mutable = promise;
            mutable.discard();
        }

        fn create(env: napi_env.Env, init_data: anytype) !*Self {
            if (comptime transfer == .capture) {
                // A compile time payload is a constant: nothing can dangle and
                // nothing has to be released, so it needs no capture - and the
                // field it lives in cannot be assigned at runtime either.
                if (comptime !payload_is_static) {
                    if (comptime !canCapture(DataType)) {
                        const reason = if (comptime helper.isErrorValue(DataType))
                            "it is an error payload, whose message and code text are borrowed and cannot be" ++
                                " copied by the capture mode"
                        else
                            "it contains a JavaScript handle, a non-slice pointer or an unsupported type";
                        @compileError("Worker data of type " ++ @typeName(DataType) ++ " cannot be captured: " ++
                            reason ++ ". Use napi.WorkerBorrowed (or declare" ++
                            " `pub const data_transfer: napi.WorkerDataTransfer = .borrowed;` on the init struct)" ++
                            " and keep the value alive until OnComplete returns - an owned copy of the message" ++
                            " (`allocator.dupe`) is the alternative for text that has to outlive the call scope.");
                    }
                }
            }

            const allocator = GlobalAllocator.capture();
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .data = init_data,
                .env = env.raw,
                .raw = null,
                .allocator = allocator,
            };
            // From here on the shell owns a private copy.
            errdefer self.releasePayload();

            if (comptime transfer == .capture and !payload_is_static) {
                self.data.data = try ownership.cloneValue(DataType, init_data.data, allocator);
                self.payload_captured = true;
            }

            return self;
        }

        fn createWork(self: *Self, env: napi_env.Env) !void {
            const async_resource_name = try String.createUtf8(env, "AsyncWorkerCallback");

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
                return NapiError.failStatus(status);
            }

            self.raw = result;
        }

        fn execute(inner_env: napi.napi_env, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data orelse return));

            NapiError.clearLastError();
            self.run(inner_env) catch |err| {
                self.status = .Rejected;
                // The message may point into this thread's error slots: copy it
                // before the completion callback reports it to JavaScript.
                self.storeTaskError(NapiError.mapAnyError(err));
                return;
            };
            self.status = .Resolved;
        }

        fn storeTaskError(self: *Self, err: NapiError.Error) void {
            if (self.err_snapshot) |*previous| previous.deinit();
            self.err_snapshot = ownership.ErrorSnapshot.capture(self.allocator, err);
            self.err = null;
        }

        fn currentError(self: *Self) ?NapiError.Error {
            if (self.err_snapshot) |snapshot| return snapshot.value();
            return self.err;
        }

        fn complete(inner_env: napi.napi_env, status: napi.napi_status, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data orelse return));

            // The runtime is done with the work item: a `deinit` from here on -
            // `OnComplete` included - may not free the worker before this
            // function returned, so the release happens in the deferred cleanup
            // below.
            self.queued = false;
            self.completed = true;
            self.in_completion = true;
            defer {
                self.in_completion = false;
                self.destroyNow();
            }

            if (status == napi.napi_cancelled) {
                self.status = .Cancelled;
            }

            const env = napi_env.Env.from_raw(inner_env);
            switch (self.status) {
                .Rejected => {
                    const err = self.currentError() orelse NapiError.Error.withCodeAndMessage("ERR_NAPI_WORKER_FAILED", "Worker failed");
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
            if (self.takePromise()) |promise| {
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

        /// Take the promise a completion is about to settle.
        ///
        /// The worker drops its copy before settling: a settlement releases the
        /// deferred, and the settlement state may become unreachable right after
        /// that (the WASI runtime releases it as soon as the deferred is gone),
        /// so nothing may read the promise again once it was settled.
        fn takePromise(self: *Self) ?Promise {
            const promise = self.promise orelse return null;
            self.promise = null;
            return promise;
        }

        fn settleAbort(self: *Self, env: napi_env.Env) void {
            // The copy is dropped after the attempt: settling releases the
            // deferred, and on runtimes that free the settlement state as soon
            // as the deferred is gone (the WASI runtime does) a second read of
            // it would be a read of released memory.
            const promise = self.takePromise() orelse return;
            var mutable = promise;
            mutable.RejectAbortError() catch {
                if (NapiError.last_error) |last_err| {
                    last_err.throwInto(env);
                }
            };
        }

        fn settleResolve(self: *Self, env: napi_env.Env) void {
            _ = env;
            if (self.takePromise()) |promise| {
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
                } else {
                    var rejectable = promise;
                    rejectable.Reject(NapiError.Error.withCodeAndMessage("ERR_NAPI_WORKER_NO_RESULT", "Worker did not produce a result")) catch {};
                }
            }

            // The result itself is released by the final cleanup: the payload is
            // freed exactly once, for `Queue` and `AsyncQueue`, on the success,
            // rejection and cancellation paths, and never before `OnComplete`
            // has run.
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

/// Run `Execute` on a worker thread and settle a promise with its result.
///
/// The `data` field is deep-copied by default (`DataTransfer.capture`), so the
/// runner may read it after the exporting JavaScript call returned. Two things
/// are never allowed on the worker thread:
///
/// * calling JavaScript (the `napi.Env` a two parameter `Execute` receives is
///   only for APIs that are explicitly thread safe, such as
///   `napi.napi_call_threadsafe_function`; every other N-API entry point may
///   only be used on the thread that owns the environment),
/// * touching `data` after `OnComplete` returned - the captured copy is
///   released exactly then.
///
/// Lifetime and threading contract of the returned handle: a worker belongs to
/// the JavaScript thread and environment that created it. `Queue`, `tryQueue`,
/// `AsyncQueue`, `Cancel` and `deinit` are called on that thread, while the
/// worker is alive - from creation until its completion callback ran, or until a
/// reported setup failure released it. The completion callback and `OnComplete`
/// also run on that thread; only `Execute` runs on the worker thread.
pub fn Worker(env: napi_env.Env, data: anytype) *WorkerContext(@TypeOf(data)) {
    return WorkerContext(@TypeOf(data)).New(env, data);
}

/// `Worker` with the data borrowed instead of captured.
///
/// The worker stores `data.data` as it is and never releases it: the caller is
/// responsible for keeping it alive until `OnComplete` returned (or, when the
/// value is a capability that was acquired, until that acquisition is released).
///
/// The mode is forced, but not silently: a `data_transfer` declaration that says
/// `capture` is a conflict and fails the build instead of being ignored.
pub fn WorkerBorrowed(env: napi_env.Env, data: anytype) *WorkerContextWith(@TypeOf(data), transferMode(@TypeOf(data), .borrowed)) {
    return WorkerContextWith(@TypeOf(data), transferMode(@TypeOf(data), .borrowed)).New(env, data);
}

/// Fallible form of `Worker`: creation failures are returned instead of
/// aborting the process.
pub fn tryWorker(env: napi_env.Env, data: anytype) !*WorkerContext(@TypeOf(data)) {
    return WorkerContext(@TypeOf(data)).tryNew(env, data);
}

/// Fallible form of `WorkerBorrowed`.
pub fn tryWorkerBorrowed(env: napi_env.Env, data: anytype) !*WorkerContextWith(@TypeOf(data), transferMode(@TypeOf(data), .borrowed)) {
    return WorkerContextWith(@TypeOf(data), transferMode(@TypeOf(data), .borrowed)).tryNew(env, data);
}

// The capture predicate is what keeps the default mode from reading memory the
// caller released, and the transfer mode is resolved once per init struct type.
// Both are compile time decisions, so their invariants are checked at compile
// time and hold for every target the module is built for.
comptime {
    const Rust = struct { text: []const u8 };
    const Payload = @import("../ownership.zig").Owned([]u8);

    if (!canCapture(u32)) @compileError("worker capture must accept numbers");
    if (!canCapture([]const u8)) @compileError("worker capture must deep-copy slices");
    if (!canCapture([]const []const u8)) @compileError("worker capture must deep-copy slice elements");
    if (!canCapture(?[]u8)) @compileError("worker capture must accept optionals");
    if (!canCapture(struct { text: []const u8, count: i32 })) @compileError("worker capture must deep-copy structs");
    if (!canCapture(Payload)) @compileError("worker capture must deep-copy owned values");

    // A non-slice pointer names someone else's allocation: copying the pointer
    // would leave the worker reading the caller's memory.
    if (canCapture(*Rust)) @compileError("worker capture must reject non-slice pointers");
    if (canCapture(struct { text: *Rust })) @compileError("worker capture must reject structs holding pointers");
    // A JavaScript handle belongs to one environment.
    if (canCapture(String)) @compileError("worker capture must reject JavaScript handles");
    // An error payload borrows its text: capturing it would share the caller's
    // buffer instead of copying it.
    if (canCapture(NapiError.Error)) @compileError("worker capture must reject borrowed error text");

    const CaptureOptions = struct {
        data: []const u8,
        Execute: *const fn ([]const u8) void,
    };
    const BorrowedOptions = struct {
        pub const data_transfer: DataTransfer = .borrowed;
        data: []const u8,
        Execute: *const fn ([]const u8) void,
    };

    if (transferMode(CaptureOptions, null) != .capture) @compileError("capture is the default transfer mode");
    if (transferMode(CaptureOptions, .borrowed) != .borrowed) @compileError("the entry point may force the borrowed mode");
    if (transferMode(BorrowedOptions, null) != .borrowed) @compileError("the declaration must be honored");
    if (transferMode(BorrowedOptions, .borrowed) != .borrowed) @compileError("matching modes must not conflict");
}
