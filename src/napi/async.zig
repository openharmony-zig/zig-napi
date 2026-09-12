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
const ownership = @import("./util/async_ownership.zig");
const options = @import("./options.zig");

/// One environment that uses the shared threaded runtime.
///
/// The runtime itself is process wide, but its lifetime is tied to the set of
/// environments that actually use it: closing one environment only stops new
/// work for that environment, and the runtime is released once the last owner
/// is gone.
///
/// Entries are allocated from the stable default allocator and linked, so there
/// is no fixed environment limit and entry addresses stay valid while the list
/// is manipulated under the runtime mutex.
const RuntimeEnv = struct {
    env: napi.napi_env,
    active_operations: usize = 0,
    closed: bool = false,
    hook_registered: bool = false,
    next: ?*RuntimeEnv = null,
};

var runtime_mutex: std.atomic.Mutex = .unlocked;
// Threaded workers retain a pointer to their runtime. Never move that runtime
// after the first task has started; retirement only moves this owning pointer.
const RuntimeStorage = struct {
    runtime: std.Io.Threaded,
    next: ?*RuntimeStorage = null,
};
/// Live runtime. `null` while a retired runtime is being released or before the
/// first environment acquires one.
var runtime_active: ?*RuntimeStorage = null;
/// Runtime whose last owner is gone; released by the reaper thread (never by a
/// worker of the runtime itself, which would have to join itself).
var runtime_retiring: ?*RuntimeStorage = null;
var runtime_reaper_running = false;
/// Environments that may still start work.
var runtime_env_head: ?*RuntimeEnv = null;
/// Environments whose cleanup hook ran while operations were still in flight.
///
/// They are unlinked from `runtime_env_head` immediately - `napi_env` addresses
/// are recycled, so a new environment would otherwise match a dead entry and
/// fail with `napi_closing` - but they keep the runtime alive until their last
/// operation finishes.
var runtime_env_closing_head: ?*RuntimeEnv = null;

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

fn lockRuntime() void {
    while (!runtime_mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

fn unlockRuntime() void {
    runtime_mutex.unlock();
}

fn runtimeEnvAllocator() std.mem.Allocator {
    // Stable for the process: never the swapping per-thread operation allocator.
    return GlobalAllocator.defaultAllocator();
}

/// Find the entry of a *live* environment. Closed entries live in
/// `runtime_env_closing_head` and are never matched here.
fn findRuntimeEnvLocked(env_raw: napi.napi_env) ?*RuntimeEnv {
    var current = runtime_env_head;
    while (current) |entry| : (current = entry.next) {
        if (entry.env == env_raw) return entry;
    }
    return null;
}

fn addRuntimeEnvLocked(env_raw: napi.napi_env) !*RuntimeEnv {
    const allocator = runtimeEnvAllocator();
    const entry = try allocator.create(RuntimeEnv);
    entry.* = .{ .env = env_raw, .next = runtime_env_head };
    runtime_env_head = entry;
    return entry;
}

fn unlinkRuntimeEnvLocked(entry: *RuntimeEnv) void {
    var link = &runtime_env_head;
    while (link.*) |current| {
        if (current == entry) {
            link.* = current.next;
            return;
        }
        link = &current.next;
    }

    link = &runtime_env_closing_head;
    while (link.*) |current| {
        if (current == entry) {
            link.* = current.next;
            return;
        }
        link = &current.next;
    }
}

/// Move a closing environment out of the acquirable list, keeping its entry (and
/// therefore the runtime) alive for the operations that are still running.
fn closeRuntimeEnvLocked(entry: *RuntimeEnv) void {
    entry.closed = true;
    unlinkRuntimeEnvLocked(entry);
    entry.next = runtime_env_closing_head;
    runtime_env_closing_head = entry;
}

fn destroyRuntimeEnvLocked(entry: *RuntimeEnv) void {
    unlinkRuntimeEnvLocked(entry);
    runtimeEnvAllocator().destroy(entry);
}

fn ensureRuntimeEnvHookLocked(entry: *RuntimeEnv) !void {
    if (entry.hook_registered) return;
    const status = napi.napi_add_env_cleanup_hook(entry.env, runtimeEnvCleanupHook, @ptrCast(entry.env));
    if (status != napi.napi_ok) {
        return NapiError.Error.fromStatus(NapiError.Status.New(status));
    }
    entry.hook_registered = true;
}

/// Retire the active runtime when it has no owners left.
///
/// The release always happens on a dedicated thread: it may be running on one
/// of the runtime's own pool workers (the async controller task), and a worker
/// cannot join itself.
fn maybeRetireRuntimeLocked() void {
    if (runtime_active == null) return;
    // Both lists matter: a closing environment whose operations are still in
    // flight keeps the runtime - and therefore its pool workers - alive.
    if (runtime_env_head != null or runtime_env_closing_head != null) return;

    if (comptime builtin.single_threaded) {
        // Without threads there are no pool workers that could join themselves:
        // release the runtime here.
        const retired = runtime_active.?;
        runtime_active = null;
        unlockRuntime();
        destroyRuntime(retired);
        lockRuntime();
        return;
    }

    const retired = runtime_active.?;
    retired.next = runtime_retiring;
    runtime_retiring = retired;
    runtime_active = null;
    if (runtime_reaper_running) return;

    runtime_reaper_running = true;
    const thread = std.Thread.spawn(.{}, runtimeReaper, .{}) catch {
        // No helper thread available: the runtime stays retired until the next
        // acquire (which is never a pool worker) or process exit.
        runtime_reaper_running = false;
        return;
    };
    thread.detach();
}

/// Releases retired runtimes until none are left, then exits.
fn runtimeReaper() void {
    while (true) {
        lockRuntime();
        const retiring = runtime_retiring;
        if (retiring) |retired| runtime_retiring = retired.next;
        if (retiring == null) {
            runtime_reaper_running = false;
            unlockRuntime();
            return;
        }
        unlockRuntime();

        destroyRuntime(retiring.?);
    }
}

/// Release a retired runtime inline.
///
/// Only called from `acquireThreadedRuntime`, which runs on an environment's
/// JavaScript thread and therefore never on a pool worker of the runtime.
fn retireRuntimeInline() void {
    lockRuntime();
    const retiring = if (!runtime_reaper_running) runtime_retiring else null;
    if (retiring) |retired| runtime_retiring = retired.next;
    unlockRuntime();

    if (retiring) |retired| destroyRuntime(retired);
}

fn destroyRuntime(storage: *RuntimeStorage) void {
    storage.runtime.deinit();
    runtimeEnvAllocator().destroy(storage);
}

/// Called when one environment is torn down. Other environments keep working.
fn runtimeEnvCleanupHook(data: ?*anyopaque) callconv(.c) void {
    const raw = data orelse return;
    const env_raw: napi.napi_env = @ptrCast(@alignCast(raw));

    lockRuntime();
    defer unlockRuntime();

    if (findRuntimeEnvLocked(env_raw)) |entry| {
        // The environment is gone: no new work may start for it. The entry is
        // kept (out of the acquirable list) while its operations drain, so the
        // runtime outlives every producer.
        closeRuntimeEnvLocked(entry);
        if (entry.active_operations == 0) {
            destroyRuntimeEnvLocked(entry);
        }
    }
    maybeRetireRuntimeLocked();
}

/// An environment's right to use the threaded runtime, together with the runtime
/// itself.
///
/// The entry is returned instead of being looked up again on release: `napi_env`
/// addresses are recycled, so an operation that released by address could hit
/// the entry of a *newer* environment that happens to live at the same address.
const RuntimeLease = struct {
    io: std.Io,
    env: *RuntimeEnv,
};

fn acquireThreadedRuntime(env_raw: napi.napi_env) !RuntimeLease {
    retireRuntimeInline();

    lockRuntime();
    defer unlockRuntime();

    var entry = findRuntimeEnvLocked(env_raw);
    if (entry) |existing| {
        if (existing.closed) {
            return NapiError.Error.fromStatus(NapiError.Status.Closing);
        }
    } else {
        const created = try addRuntimeEnvLocked(env_raw);
        // Registration failures roll the entry back: an environment without a
        // cleanup hook would never be marked closed.
        ensureRuntimeEnvHookLocked(created) catch |err| {
            destroyRuntimeEnvLocked(created);
            return err;
        };
        entry = created;
    }

    if (runtime_active == null) {
        const allocator = runtimeEnvAllocator();
        const storage = try allocator.create(RuntimeStorage);
        storage.* = .{ .runtime = std.Io.Threaded.init(allocator, .{}) };
        runtime_active = storage;
    }

    entry.?.active_operations += 1;
    return .{ .io = runtime_active.?.runtime.io(), .env = entry.? };
}

/// The threaded runtime is only retired once its last owner is gone, so an
/// active operation always observes an initialized runtime.
fn activeThreadedIo() std.Io {
    lockRuntime();
    defer unlockRuntime();

    std.debug.assert(runtime_active != null);
    return runtime_active.?.runtime.io();
}

fn releaseThreadedRuntime(entry: *RuntimeEnv) void {
    lockRuntime();
    defer unlockRuntime();

    if (entry.active_operations > 0) {
        entry.active_operations -= 1;
    }
    // Only this environment is removed; other environments keep the runtime.
    if (entry.active_operations == 0 and entry.closed) {
        destroyRuntimeEnvLocked(entry);
    }
    maybeRetireRuntimeLocked();
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
    // `?napi_value` is a nested optional: the generated export wrapper passes
    // the *missing* listener as `Some(null)` (the raw handle of an absent
    // argument), while an explicit `undefined`/`null` argument arrives as a real
    // handle. Both spell "no listener", and neither may reach `napi_typeof`,
    // which rejects a null handle with `napi_invalid_arg`.
    const value = (raw orelse return null) orelse return null;

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

/// Property a captured listener exception is stored under on its holder object.
const listener_value_property = "value";

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

        /// Capture `input` for an async task.
        ///
        /// The input is deep-copied into memory owned by the task, so the
        /// caller keeps ownership of the original argument and can release it
        /// as soon as the exported call returns. A copy failure produces an
        /// error-bearing descriptor that rejects the returned promise instead
        /// of running the task with an invalid placeholder; use `tryFrom` to
        /// observe the failure synchronously.
        pub fn from(input: anytype, comptime run_fn: anytype) Self {
            return tryFrom(input, run_fn) catch |err| {
                const Input = @TypeOf(input);
                validateTaskRunSignature(Input, Result, Event, run_fn);
                return errorDescriptor(Input, run_fn, err);
            };
        }

        pub fn tryFrom(input: anytype, comptime run_fn: anytype) !Self {
            const Input = @TypeOf(input);
            validateTaskRunSignature(Input, Result, Event, run_fn);

            // Read the operation allocator once: the descriptor and the task it
            // will start must allocate and free with the same allocator, even if
            // this thread (or the task thread) replaces it in the meantime.
            const allocator = GlobalAllocator.capture();
            const Impl = AsyncTaskDescriptorImpl(Input, Result, Event, runtime, run_fn);
            const impl = try allocator.create(Impl);
            errdefer allocator.destroy(impl);

            impl.* = .{
                .base = .{
                    .allocator = allocator,
                    .schedule_fn = Impl.schedule,
                    .destroy_fn = Impl.release,
                },
                .allocator = allocator,
            };
            impl.input = try ownership.cloneValue(Input, input, allocator);
            impl.has_input = true;
            return .{ .base = &impl.base };
        }

        fn errorDescriptor(comptime Input: type, comptime run_fn: anytype, err: anyerror) Self {
            const allocator = GlobalAllocator.capture();
            const Impl = AsyncTaskDescriptorImpl(Input, Result, Event, runtime, run_fn);
            const impl = allocator.create(Impl) catch @panic("OOM");
            const mapped = NapiError.last_error orelse NapiError.mapAnyError(err);
            NapiError.clearLastError();
            impl.* = .{
                .base = .{
                    .allocator = allocator,
                    .schedule_fn = Impl.schedule,
                    .destroy_fn = Impl.release,
                },
                .allocator = allocator,
                .clone_error = mapped,
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

        /// Consume the descriptor and start the task.
        ///
        /// A descriptor is single use. Once consumed, the handle is repointed
        /// at a terminal state whose `schedule_fn` reports the error, so a
        /// second `schedule` (or a `deinit` after scheduling) fails cleanly even
        /// though the task already released the original state.
        pub fn scheduleWithListenerAndSignal(self: *Self, env: Env, listener: ?napi.napi_value, signal: ?AbortSignal) !Promise {
            const base = self.base;
            const result = base.schedule_fn(base, env.raw, listener, signal);
            self.base = &consumed_descriptor_base;
            return result;
        }

        /// Release a descriptor that was never scheduled. Safe (no-op) after
        /// the descriptor was consumed.
        pub fn deinit(self: *Self) void {
            self.base.destroy_fn(self.base);
        }
    };
}

/// Terminal state every consumed descriptor handle points at. It owns nothing
/// and can be shared process wide: scheduling through it always fails and
/// releasing it is a no-op.
var consumed_descriptor_base: AsyncTaskDescriptorBase = .{
    .allocator = std.heap.page_allocator,
    .schedule_fn = scheduleConsumedDescriptor,
    .destroy_fn = ignoreDescriptorRelease,
};

fn scheduleConsumedDescriptor(_: *AsyncTaskDescriptorBase, _: napi.napi_env, _: ?napi.napi_value, _: ?AbortSignal) anyerror!Promise {
    NapiError.last_error = NapiError.Error.withCodeAndMessage(
        "ERR_NAPI_ASYNC_DESCRIPTOR_CONSUMED",
        "This async descriptor has already been scheduled",
    );
    return error.GenericFailure;
}

fn ignoreDescriptorRelease(_: *AsyncTaskDescriptorBase) void {}

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
        allocator: std.mem.Allocator,
        input: Input = undefined,
        has_input: bool = false,
        clone_error: ?NapiError.Error = null,
        consumed: bool = false,

        const Self = @This();

        fn schedule(base: *AsyncTaskDescriptorBase, env_raw: napi.napi_env, listener: ?napi.napi_value, signal: ?AbortSignal) anyerror!Promise {
            const self: *Self = @alignCast(@fieldParentPtr("base", base));

            if (self.consumed) {
                NapiError.last_error = NapiError.Error.withCodeAndMessage(
                    "ERR_NAPI_ASYNC_DESCRIPTOR_CONSUMED",
                    "This async descriptor has already been scheduled",
                );
                return error.GenericFailure;
            }
            self.consumed = true;

            if (self.clone_error) |clone_error| {
                var promise = Promise.New(Env.from_raw(env_raw)) catch |err| {
                    Self.release(base);
                    return err;
                };
                promise.Reject(clone_error) catch {};
                Self.release(base);
                return promise;
            }

            // Ownership of the captured input moves into the operation, which
            // releases it itself when creation fails.
            const captured = self.input;
            self.has_input = false;
            const operation = AsyncTaskOperation(Input, Result, Event, runtime, run_fn).create(
                Env.from_raw(env_raw),
                captured,
                listener,
                signal,
                self.allocator,
            ) catch |err| {
                Self.release(base);
                return err;
            };
            operation.descriptor_base = base;
            return operation.submit();
        }

        /// Frees the captured input (when it was not handed to a task) and the
        /// descriptor itself.
        fn release(base: *AsyncTaskDescriptorBase) void {
            const self: *Self = @alignCast(@fieldParentPtr("base", base));
            if (self.has_input) {
                self.has_input = false;
                ownership.deinitValue(Input, self.input, self.allocator);
            }
            self.base.allocator.destroy(self);
        }
    };
}

/// Explicit lifecycle of one async task.
pub const AsyncState = enum(u8) {
    created,
    queued,
    running,
    settling,
    settled,
    closed,
};

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
        descriptor_base: ?*AsyncTaskDescriptorBase = null,
        input: Input = undefined,
        result: Result = if (Result == void) {} else undefined,
        err: ?NapiError.Error = null,
        /// Owns the text of `err` when the error was produced on the task
        /// thread (its message may live in thread local storage).
        err_snapshot: ?ownership.ErrorSnapshot = null,
        listener_ref: ?napi.napi_ref = null,
        /// Original exception thrown by the event listener, kept alive (inside
        /// a referenced holder object, so primitives work on every N-API
        /// version) so the task rejects with it instead of leaking an uncaught
        /// exception.
        listener_error_ref: ?napi.napi_ref = null,
        /// True once delivering an event failed. Kept separate from the
        /// captured value: a failure that could not be rooted must still reject
        /// the task instead of resolving it.
        listener_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Native error used to reject when the thrown value could not be kept.
        listener_failure_error: ?ownership.ErrorSnapshot = null,
        abort_registration: ?*AbortRegistration = null,
        cancel_token: CancelToken = .{},
        future: ?std.Io.Future(void) = null,
        controller_future: ?std.Io.Future(void) = null,
        async_work: napi.napi_async_work = null,
        tsfn_raw: napi.napi_threadsafe_function = null,
        /// Completion record, allocated before the promise reaches JavaScript so
        /// a queueing failure can never be mistaken for a dead environment.
        /// Ownership moves to the dispatcher queue once it is posted.
        completion: ?*DispatchData = null,
        /// True once a thread-safe function owns this operation's finalization.
        tsfn_created: bool = false,
        state_mutex: std.Io.Mutex = .init,
        state_cond: std.Io.Condition = .init,
        state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(AsyncState.created)),
        task_done: bool = false,
        cancel_requested: bool = false,
        cancel_dispatched: bool = false,
        result_ready: bool = false,
        uses_threaded_runtime: bool = false,
        /// Runtime lease held while this operation may run producers. It keeps
        /// the shared runtime (and its pool workers) alive even after the
        /// environment's cleanup hook ran.
        runtime_env: ?*RuntimeEnv = null,
        settled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        js_released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        native_released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        /// Number of native owners of this operation's memory.
        ///
        /// The environment's thread-safe function does *not* protect the
        /// operation: Node finalizes (and frees) it as soon as the environment is
        /// torn down, while `runTask` and the controller may still be using
        /// `self`. Producers therefore hold their own references, and the last
        /// owner - the dispatcher finalizer or the last producer - frees the
        /// memory. `create` starts with one reference for the caller.
        ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
        /// Serializes every use of the thread-safe function handle against the
        /// finalizer that ends its life: Node frees the handle during
        /// environment teardown, so a producer must never call into it
        /// afterwards.
        dispatcher_gate: std.Io.Mutex = .init,
        /// True while `tsfn_raw` may still be called. Guarded by
        /// `dispatcher_gate`.
        dispatcher_live: bool = false,

        const Self = @This();
        const Context = AsyncContext(Event);
        const run_info = @typeInfo(@TypeOf(run_fn)).@"fn";
        const DispatchKind = enum { event, completion };

        /// A queued item owns everything needed to release it, including when
        /// the environment is already gone and the JS callback receives a null
        /// environment.
        const DispatchData = struct {
            kind: DispatchKind,
            allocator: std.mem.Allocator,
            payload: ?*Event = null,
        };

        fn setState(self: *Self, new_state: AsyncState) void {
            self.state.store(@intFromEnum(new_state), .release);
        }

        fn getState(self: *const Self) AsyncState {
            return @enumFromInt(self.state.load(.acquire));
        }

        /// Take a reference: the caller must pair it with `dropOwner`.
        fn retain(self: *Self) void {
            _ = self.ref_count.fetchAdd(1, .monotonic);
        }

        /// Drop a reference. The last owner frees the operation.
        fn dropOwner(self: *Self) void {
            if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
                // Frees the native state (captured input, result, snapshot) and
                // then the operation itself: no producer can be running here,
                // because every producer held a reference of its own.
                self.releaseNative();
                self.allocator.destroy(self);
            }
        }

        /// Reference-taking adapter for `AbortSignal`'s context owner.
        fn retainOperation(ptr: ?*anyopaque) void {
            const raw = ptr orelse return;
            const self: *Self = @ptrCast(@alignCast(raw));
            self.retain();
        }

        /// Reference-dropping adapter for `AbortSignal`'s context owner.
        fn releaseOperation(ptr: ?*anyopaque) void {
            const raw = ptr orelse return;
            const self: *Self = @ptrCast(@alignCast(raw));
            self.dropOwner();
        }

        fn create(env: Env, input: Input, listener: ?napi.napi_value, signal: ?AbortSignal, allocator: std.mem.Allocator) !*Self {
            // Registered before anything can fail: the caller handed the captured
            // input over on entry, so a failure to allocate the operation must
            // still release it.
            errdefer ownership.deinitValue(Input, input, allocator);

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const promise = try Promise.New(env);
            // A task that never starts must not leave the caller's promise
            // pending forever, and a promise the caller never received must not
            // turn into an unhandled rejection either: release its deferred
            // silently (the thrown error is the caller visible failure).
            errdefer {
                var discardable = promise;
                discardable.discard();
            }

            self.* = .{
                .allocator = allocator,
                .env = env.raw,
                .promise = promise,
                .input = input,
            };
            errdefer releaseCallbackRef(env.raw, &self.listener_ref);

            if (Event != void) {
                self.listener_ref = try createOptionalCallbackRef(env.raw, listener);
            }

            if (signal) |abort_signal| {
                // The registration takes its own reference on this operation
                // while the abort callback runs, so a late `abort` event can
                // never call into freed memory.
                self.abort_registration = try abort_signal.bindOwned(
                    .{
                        .context = @ptrCast(self),
                        .retain = retainOperation,
                        .release = releaseOperation,
                    },
                    requestAbortFromSignal,
                );
            }

            return self;
        }

        fn submit(self: *Self) !Promise {
            // The initial reference either stays here (nothing was started) or
            // is handed to the thread-safe function, whose finalizer drops it.
            var handed_to_dispatcher = false;
            errdefer {
                var discardable = self.promise;
                discardable.discard();
                _ = self.destroyJs(self.env);
                if (!handed_to_dispatcher) self.dropOwner();
            }

            const promise = self.promise;
            if (self.abort_registration != null and self.isAbortRequestedFromSignal()) {
                self.cancel_token.cancel();
                self.cancel_requested = true;
                self.dispatchCompletion(self.env);
                self.dropOwner();
                return promise;
            }

            switch (effectiveRuntime(runtime)) {
                .single => {
                    self.setState(.running);
                    self.runSingle();
                },
                .thread => {
                    if (comptime use_wasm_emnapi_async_work) {
                        try self.runWasmAsyncWork();
                        return promise;
                    }

                    const lease = try acquireThreadedRuntime(self.env);
                    self.runtime_env = lease.env;
                    const io = lease.io;
                    self.uses_threaded_runtime = true;
                    // From here on the dispatcher owns the initial reference:
                    // it is dropped by the thread-safe function's finalizer.
                    try self.initThreadDispatcher();
                    handed_to_dispatcher = true;
                    // The completion record is allocated while the promise has
                    // not been handed to JavaScript yet, so the completion path
                    // itself never has to allocate (and can never fail on a live
                    // environment).
                    try self.prepareCompletionRecord();
                    self.setState(.queued);
                    self.retain();
                    self.future = std.Io.concurrent(io, runTaskOwned, .{self}) catch |err| {
                        self.dropOwner();
                        self.err = mapAnyError(err);
                        self.dispatchCompletion(self.env);
                        return promise;
                    };
                    self.retain();
                    self.controller_future = std.Io.concurrent(io, controllerTaskOwned, .{self}) catch |err| {
                        self.dropOwner();
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

        /// `runTask` with its own reference: the task thread owns the operation
        /// for as long as it runs, no matter what the environment does.
        fn runTaskOwned(self: *Self) void {
            defer self.dropOwner();
            self.runTask();
        }

        /// `controllerTask` with its own reference.
        fn controllerTaskOwned(self: *Self) void {
            defer self.dropOwner();
            self.controllerTask();
        }

        fn controllerTask(self: *Self) void {
            const io = self.operationIo();
            const should_cancel = self.waitForTaskDoneOrAbort();
            if (self.future) |*future| {
                if (should_cancel) {
                    // Cancellation is cooperative: `cancel` waits for the task
                    // to return, so nothing touches this operation afterwards.
                    future.cancel(io);
                    self.cancel_dispatched = true;
                } else {
                    future.await(io);
                }
            }
            self.queueCompletion() catch {
                // The completion channel is gone (the environment is shutting
                // down). No JavaScript may run any more: only release native
                // state, never settle a promise against a dead environment.
                self.destroyNativeOnly(true);
            };
        }

        fn runSingle(self: *Self) void {
            const io = singleIo();
            var future = std.Io.async(io, runTask, .{self});
            future.await(io);
            self.dispatchCompletion(self.env);
            // Single runtime: the caller's reference is the last one.
            self.dropOwner();
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
                self.storeTaskError(mapAnyError(err));
                return;
            };
            group.await(io) catch |err| {
                self.storeTaskError(mapAnyError(err));
            };
        }

        /// Record an error produced on the task thread.
        ///
        /// The message may live in this thread's rotating error slots or in the
        /// captured input, so the text is copied into operation-owned memory
        /// before the completion crosses back to the JavaScript thread.
        fn storeTaskError(self: *Self, err: NapiError.Error) void {
            if (self.err_snapshot) |*previous| previous.deinit();
            self.err_snapshot = ownership.ErrorSnapshot.capture(self.allocator, err);
            self.err = null;
        }

        /// Current error, preferring the snapshot taken by the task thread.
        fn currentError(self: *Self) ?NapiError.Error {
            if (self.err_snapshot) |snapshot| return snapshot.value();
            return self.err;
        }

        /// Value used to reject a completion whose conversion failed.
        ///
        /// A conversion can leave a JavaScript exception pending (for example a
        /// getter that threw). That original exception object is the rejection
        /// reason: it is cleared from the environment first, so the caller sees
        /// it as the promise rejection instead of an exception thrown out of the
        /// exported call.
        fn rejectionForConversionFailure(self: *Self, env_raw: napi.napi_env, err: anyerror) Settlement {
            _ = self;
            const env = Env.from_raw(env_raw);
            if (env.isExceptionPending()) {
                if (env.getAndClearLastException()) |pending| {
                    return .{ .value = pending.raw, .reject = true };
                } else |_| {}
            }
            return .{
                .value = NapiError.mapAnyError(err).to_napi_error(env),
                .reject = true,
            };
        }

        fn runWasmAsyncWork(self: *Self) !void {
            try self.initThreadDispatcher();
            try self.prepareCompletionRecord();

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
            self.setState(.queued);

            // The executor runs on another thread and owns a reference, exactly
            // like a threaded producer: the environment may be torn down while
            // it is still running.
            self.retain();
            const queue_status = napi.napi_queue_async_work(self.env, async_work);
            if (queue_status != napi.napi_ok) {
                self.dropOwner();
                _ = napi.napi_delete_async_work(self.env, async_work);
                self.async_work = null;
                return NapiError.Error.fromStatus(NapiError.Status.New(queue_status));
            }
        }

        fn wasmAsyncWorkExecute(_: napi.napi_env, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            self.setState(.running);
            self.runTaskWithIo(singleIo(), .thread);
        }

        fn wasmAsyncWorkComplete(inner_env: napi.napi_env, status: napi.napi_status, data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(data));
            // The executor's reference is dropped on the way out: everything
            // below only touches native state and the dispatcher.
            defer self.dropOwner();

            if (status == napi.napi_cancelled) {
                self.cancel_dispatched = true;
            }
            if (self.async_work != null) {
                _ = napi.napi_delete_async_work(inner_env, self.async_work);
                self.async_work = null;
            }
            // Complete through the same FIFO as progress events. emnapi's work
            // completion callback can otherwise overtake queued listeners and
            // resolve before observing their exceptions (or drop their events).
            self.queueCompletion() catch self.destroyNativeOnly(true);
        }

        fn isAbortRequestedFromSignal(self: *Self) bool {
            if (self.abort_registration) |registration| {
                return registration.isSignalAborted();
            }
            return false;
        }

        fn requestAbortFromSignal(ptr: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.requestAbort();
        }

        fn requestAbort(self: *Self) void {
            // Cancellation must be observable even after the operation was torn
            // down natively, but nothing else may be touched then.
            if (self.native_released.load(.acquire)) {
                self.cancel_token.cancel();
                return;
            }
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
                    // The event crosses a thread boundary and is delivered
                    // later: it must own its data (a slice field would otherwise
                    // alias a buffer the producer may reuse or release).
                    const payload = try self.allocator.create(Event);
                    payload.* = ownership.cloneValue(Event, event, self.allocator) catch |err| {
                        self.allocator.destroy(payload);
                        return err;
                    };
                    errdefer {
                        ownership.deinitValue(Event, payload.*, self.allocator);
                        self.allocator.destroy(payload);
                    }

                    const data = try self.allocator.create(DispatchData);
                    data.* = .{ .kind = .event, .allocator = self.allocator, .payload = payload };
                    errdefer self.allocator.destroy(data);

                    try self.postToDispatcher(data);
                },
            }
        }

        fn dispatchEvent(self: *Self, env_raw: napi.napi_env, event: Event) void {
            if (Event == void or self.listener_ref == null) return;

            var callback: napi.napi_value = null;
            const get_ref_status = napi.napi_get_reference_value(env_raw, self.listener_ref.?, &callback);
            // A missing reference means the environment is going away: there is
            // no listener left to report a failure to.
            if (get_ref_status != napi.napi_ok or callback == null) return;

            const event_value = Napi.to_napi_value(env_raw, event, null) catch |err| {
                self.recordListenerFailure(env_raw, err);
                return;
            };
            const undefined_value = Undefined.New(Env.from_raw(env_raw));
            const argv = [1]napi.napi_value{event_value};
            var ignored: napi.napi_value = null;
            const call_status = napi.napi_call_function(env_raw, undefined_value.raw, callback, argv.len, &argv, &ignored);
            if (call_status != napi.napi_ok) {
                self.recordListenerFailure(env_raw, null);
            }
        }

        /// Record that delivering an event to the listener failed.
        ///
        /// The listener runs inside a thread-safe-function dispatch, where Node
        /// would report a pending exception as uncaught and drop it. The
        /// exception object (whatever its type) is rooted so the task can reject
        /// with exactly the value the listener threw; the pending state is
        /// always cleared so the environment stays usable and the engine has
        /// nothing left to report.
        fn recordListenerFailure(self: *Self, env_raw: napi.napi_env, cause: ?anyerror) void {
            self.listener_failed.store(true, .release);

            const env = Env.from_raw(env_raw);
            var thrown: ?napi.napi_value = null;
            if (env.isExceptionPending()) {
                if (env.getAndClearLastException()) |pending| {
                    thrown = pending.raw;
                } else |_| {}
            }
            // Never leave the dispatch with a pending exception, whatever the
            // rooting below does.
            defer self.clearPendingException(env_raw);

            if (thrown) |value| {
                if (self.rootListenerValue(env_raw, value)) return;
            }

            // No usable value (no pending exception, or rooting failed): keep a
            // native error so the task still rejects instead of resolving.
            const mapped = if (cause) |err|
                NapiError.mapAnyError(err)
            else
                NapiError.Error.withCodeAndMessage(
                    "ERR_NAPI_ASYNC_EVENT_LISTENER_FAILED",
                    "The event listener failed while the event was being delivered",
                );
            if (self.listener_failure_error) |*previous| previous.deinit();
            self.listener_failure_error = ownership.ErrorSnapshot.capture(self.allocator, mapped);
        }

        /// Root an arbitrary JavaScript value so it survives until settlement.
        ///
        /// `napi_create_reference` only accepts objects below N-API 10, and an
        /// event listener may throw any value (`42`, `"boom"`, `null`,
        /// `undefined`). The value is stored on a holder object and the *holder*
        /// is referenced: reading the property back returns exactly the original
        /// value, identity included.
        fn rootListenerValue(self: *Self, env_raw: napi.napi_env, value: napi.napi_value) bool {
            if (value == null) return false;

            var holder: napi.napi_value = null;
            if (napi.napi_create_object(env_raw, &holder) != napi.napi_ok) return false;
            if (holder == null) return false;
            if (napi.napi_set_named_property(env_raw, holder, listener_value_property, value) != napi.napi_ok) return false;

            releaseCallbackRef(env_raw, &self.listener_error_ref);
            var ref: napi.napi_ref = null;
            if (napi.napi_create_reference(env_raw, holder, 1, &ref) != napi.napi_ok) return false;
            self.listener_error_ref = ref;
            return true;
        }

        fn clearPendingException(self: *Self, env_raw: napi.napi_env) void {
            _ = self;
            const env = Env.from_raw(env_raw);
            var attempts: usize = 0;
            while (env.isExceptionPending() and attempts < 4) : (attempts += 1) {
                _ = env.getAndClearLastException() catch return;
            }
        }

        /// Rejection reason for a listener failure, or null when the listener
        /// never failed.
        fn listenerFailureValue(self: *Self, env_raw: napi.napi_env) ?napi.napi_value {
            if (!self.listener_failed.load(.acquire)) return null;

            if (self.listener_error_ref) |ref| {
                var holder: napi.napi_value = null;
                if (napi.napi_get_reference_value(env_raw, ref, &holder) == napi.napi_ok and holder != null) {
                    var value: napi.napi_value = null;
                    if (napi.napi_get_named_property(env_raw, holder, listener_value_property, &value) == napi.napi_ok and value != null) {
                        return value;
                    }
                    // Reading the property of a hostile holder can itself throw.
                    self.clearPendingException(env_raw);
                }
            }
            if (self.listener_failure_error) |snapshot| {
                return snapshot.value().to_napi_error(Env.from_raw(env_raw));
            }
            return NapiError.Error.withCodeAndMessage(
                "ERR_NAPI_ASYNC_EVENT_LISTENER_FAILED",
                "The event listener failed while the event was being delivered",
            ).to_napi_error(Env.from_raw(env_raw));
        }

        fn prepareCompletionRecord(self: *Self) !void {
            if (self.completion != null) return;
            const data = try self.allocator.create(DispatchData);
            data.* = .{ .kind = .completion, .allocator = self.allocator };
            self.completion = data;
        }

        fn queueCompletion(self: *Self) !void {
            // Normally preallocated in `submit`; the fallback keeps older paths
            // (and the wasm dispatcher) working.
            try self.prepareCompletionRecord();
            const data = self.completion.?;

            // The completion shares the dispatcher with the events but never
            // waits for a queue slot: it is the last item the operation posts
            // (producers are done by now) and it must not be lost.
            self.postToDispatcher(data) catch |err| {
                self.completion = null;
                self.allocator.destroy(data);
                return err;
            };
            self.completion = null;
        }

        /// Hand one queue record to the environment's dispatcher.
        ///
        /// The dispatcher gate is what makes this safe against environment
        /// teardown: Node frees the thread-safe function handle while producers
        /// may still be running, and calling it after that is undefined
        /// behavior. Inside the gate the handle is either still usable, or the
        /// finalizer already marked it dead.
        fn postToDispatcher(self: *Self, data: *DispatchData) !void {
            const io = self.operationIo();
            self.dispatcher_gate.lockUncancelable(io);
            if (!self.dispatcher_live or self.tsfn_raw == null) {
                self.dispatcher_gate.unlock(io);
                return error.Closing;
            }
            const status = napi.napi_call_threadsafe_function(self.tsfn_raw, @ptrCast(data), napi.napi_tsfn_nonblocking);
            self.dispatcher_gate.unlock(io);

            if (status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
        }

        const Settlement = struct {
            value: ?napi.napi_value = null,
            reject: bool = false,
        };

        /// Settlement priority, highest first: the listener's own exception (or
        /// the delivery failure that replaced it), the cancellation, the task's
        /// own error, then the task's result. Cleanup failures are handled by
        /// `dispatchCompletion` and can never override any of these.
        fn settlementFor(self: *Self, env_raw: napi.napi_env) Settlement {
            if (self.listenerFailureValue(env_raw)) |value| {
                // The JavaScript listener threw: that original exception object
                // is the reason, not an error we synthesized afterwards.
                return .{ .value = value, .reject = true };
            }
            if (self.cancel_dispatched or self.cancel_requested) {
                const value = AbortSignalModule.abortErrorValue(Env.from_raw(env_raw)) catch {
                    return .{
                        .value = NapiError.Error.withCodeAndMessage("AbortError", "AbortError").to_napi_error(Env.from_raw(env_raw)),
                        .reject = true,
                    };
                };
                return .{ .value = value, .reject = true };
            }
            if (self.currentError()) |err| {
                return .{ .value = err.to_napi_error(Env.from_raw(env_raw)), .reject = true };
            }
            if (comptime Result == void) {
                return .{ .value = Undefined.New(Env.from_raw(env_raw)).raw };
            }
            if (!self.result_ready) {
                return .{
                    .value = NapiError.Error.withCodeAndMessage("ERR_NAPI_ASYNC_NO_RESULT", "Async task did not produce a result").to_napi_error(Env.from_raw(env_raw)),
                    .reject = true,
                };
            }
            if (comptime NapiError.isResult(Result)) {
                switch (self.result) {
                    .ok => |payload| {
                        const value = Napi.to_napi_value(env_raw, payload, null) catch |err| {
                            return self.rejectionForConversionFailure(env_raw, err);
                        };
                        return .{ .value = value };
                    },
                    .err => |err| return .{ .value = err.to_napi_error(Env.from_raw(env_raw)), .reject = true },
                }
            }
            const value = Napi.to_napi_value(env_raw, self.result, null) catch |err| {
                return self.rejectionForConversionFailure(env_raw, err);
            };
            return .{ .value = value };
        }

        /// Settle the promise at most once and release the JavaScript side.
        ///
        /// Runs on the environment's JavaScript thread and never waits for a
        /// producer: a completion is only dispatched after the task stopped, and
        /// the operation's memory is reference counted, so there is nothing to
        /// join here. In particular the main JavaScript thread is never blocked
        /// on a task that may itself be waiting on JavaScript.
        fn dispatchCompletion(self: *Self, env_raw: napi.napi_env) void {
            // Teardown below may release the last reference of the operation;
            // hold one for the duration of the settlement.
            self.retain();
            defer self.dropOwner();

            if (self.settled.swap(true, .acq_rel)) return;
            self.setState(.settling);

            // The settlement reason is computed *before* cleanup: the listener's
            // exception, the cancellation and the task's own error are the
            // original outcome, and a hostile signal that throws from
            // `removeEventListener` must not replace them.
            const promise = self.promise;
            var settlement = self.settlementFor(env_raw);
            if (settlement.value == null) {
                // Never leave the caller's promise pending: a missing
                // settlement value is itself a failure.
                settlement = .{
                    .value = NapiError.Error.withCodeAndMessage("ERR_NAPI_ASYNC_NO_RESULT", "Async task did not produce a result").to_napi_error(Env.from_raw(env_raw)),
                    .reject = true,
                };
            }
            self.setState(.settled);

            // Cleanup may run JavaScript (removing the abort listener). Any
            // exception it leaves pending is isolated here: it is cleared in
            // every case, so the engine never reports it as uncaught, and it
            // only becomes the rejection reason when the task itself had none.
            const cleanup_failure = self.destroyJs(env_raw);
            if (cleanup_failure) |value| {
                if (!settlement.reject) settlement = .{ .value = value, .reject = true };
            }

            if (settlement.value) |value| {
                var settle_target = promise;
                if (settlement.reject) {
                    settle_target.rejectRaw(value) catch {};
                } else {
                    settle_target.resolveRaw(value) catch {};
                }
            }
        }

        fn initThreadDispatcher(self: *Self) !void {
            const resource_name = String.New(Env.from_raw(self.env), "ZigAsyncTask");
            var dispatcher_fn: napi.napi_value = null;
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
                @ptrCast(self),
                dispatcherFinalize,
                @ptrCast(self),
                dispatcherCallJs,
                &tsfn_raw,
            );
            if (create_status != napi.napi_ok) {
                return NapiError.Error.fromStatus(NapiError.Status.New(create_status));
            }
            self.tsfn_raw = tsfn_raw;
            self.tsfn_created = true;
            const io = self.operationIo();
            self.dispatcher_gate.lockUncancelable(io);
            self.dispatcher_live = true;
            self.dispatcher_gate.unlock(io);
        }

        fn dispatcherNoop(inner_env: napi.napi_env, _: napi.napi_callback_info) callconv(.c) napi.napi_value {
            return Undefined.New(Env.from_raw(inner_env)).raw;
        }

        /// The thread-safe function is gone: the queue was drained (with a null
        /// environment when the environment is shutting down) and its handle is
        /// about to be freed by the engine.
        ///
        /// Only the dispatcher's *reference* is dropped here. Producers may
        /// still be running - a finalized thread-safe function is not proof that
        /// they stopped - and they keep the operation alive until they return.
        fn dispatcherFinalize(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const raw = data orelse return;
            const self: *Self = @ptrCast(@alignCast(raw));
            self.closeDispatcher();
            self.js_released.store(true, .release);
            self.dropOwner();
        }

        /// Mark the thread-safe function unusable.
        ///
        /// Serialized with `postToDispatcher` and `releaseDispatcher`, so no
        /// producer can be inside `napi_call_threadsafe_function` when the
        /// handle dies.
        fn closeDispatcher(self: *Self) void {
            const io = self.operationIo();
            self.dispatcher_gate.lockUncancelable(io);
            self.dispatcher_live = false;
            self.dispatcher_gate.unlock(io);
        }

        /// Release the thread-safe function exactly once.
        ///
        /// The gate is dropped *before* the release call: Node may run the
        /// finalizer synchronously from here, and the finalizer takes the same
        /// gate.
        fn releaseDispatcher(self: *Self) void {
            const io = self.operationIo();
            self.dispatcher_gate.lockUncancelable(io);
            const release_now = self.dispatcher_live;
            self.dispatcher_live = false;
            self.dispatcher_gate.unlock(io);

            if (release_now and self.tsfn_raw != null) {
                _ = napi.napi_release_threadsafe_function(self.tsfn_raw, napi.napi_tsfn_release);
            }
        }

        fn dispatcherCallJs(inner_env: napi.napi_env, js_callback: napi.napi_value, context: ?*anyopaque, raw_data: ?*anyopaque) callconv(.c) void {
            const data: *DispatchData = @ptrCast(@alignCast(raw_data orelse return));
            const allocator = data.allocator;
            const kind = data.kind;
            const payload = data.payload;
            allocator.destroy(data);

            // Node drains the queue with a null environment while shutting
            // down: release the queued payload natively and never touch JS.
            const env_alive = inner_env != null and js_callback != null;

            switch (kind) {
                .event => {
                    if (payload) |event_payload| {
                        defer {
                            // Delivery and the null-environment drain both
                            // release the event's own data.
                            ownership.deinitValue(Event, event_payload.*, allocator);
                            allocator.destroy(event_payload);
                        }
                        if (!env_alive) return;
                        const self = operationFromContext(context) orelse return;
                        self.dispatchEvent(inner_env, event_payload.*);
                    }
                },
                .completion => {
                    if (!env_alive) return;
                    const self = operationFromContext(context) orelse return;
                    self.dispatchCompletion(inner_env);
                },
            }
        }

        fn operationFromContext(context: ?*anyopaque) ?*Self {
            const raw = context orelse return null;
            return @ptrCast(@alignCast(raw));
        }

        /// JavaScript-thread teardown: releases every reference owned by the
        /// environment and the dispatcher.
        ///
        /// Native state (the captured input, the result, the completion record)
        /// is deliberately *not* released here: producers may still hold
        /// references and read them. The last owner releases them in
        /// `releaseNative`.
        ///
        /// Returns the exception a cleanup callback left pending (as a value),
        /// or null. The exception is always cleared from the environment, so a
        /// hostile `removeEventListener` can neither break the settlement nor be
        /// reported as an uncaught exception.
        fn destroyJs(self: *Self, env_raw: napi.napi_env) ?napi.napi_value {
            if (self.js_released.swap(true, .acq_rel)) return null;

            releaseCallbackRef(env_raw, &self.listener_ref);
            releaseCallbackRef(env_raw, &self.listener_error_ref);
            if (self.abort_registration) |registration| {
                registration.release();
                self.abort_registration = null;
            }
            if (self.async_work != null) {
                _ = napi.napi_delete_async_work(env_raw, self.async_work);
                self.async_work = null;
            }

            var cleanup_failure: ?napi.napi_value = null;
            const env = Env.from_raw(env_raw);
            if (env.isExceptionPending()) {
                if (env.getAndClearLastException()) |pending| {
                    cleanup_failure = pending.raw;
                } else |_| {}
                self.clearPendingException(env_raw);
            }

            // Release last: the finalizer may free the operation synchronously,
            // and nothing may touch `self` afterwards.
            self.releaseDispatcher();
            return cleanup_failure;
        }

        /// Native-only teardown for paths where JavaScript must not be touched.
        ///
        /// `release_dispatcher` releases the thread-safe function so its queue
        /// is drained (with a null environment) and its finalizer can drop the
        /// dispatcher's reference. It must be false when the finalizer itself is
        /// already running.
        fn destroyNativeOnly(self: *Self, release_dispatcher: bool) void {
            self.js_released.store(true, .release);
            if (release_dispatcher) {
                self.releaseDispatcher();
            } else {
                self.closeDispatcher();
            }
        }

        /// Frees everything the operation owns natively.
        ///
        /// Only called by the last reference holder (`dropOwner`), which is the
        /// only point where no producer can still be reading the input or the
        /// result. Idempotent, callable from any thread, never touches
        /// JavaScript.
        fn releaseNative(self: *Self) void {
            if (self.native_released.swap(true, .acq_rel)) return;

            const allocator = self.allocator;
            const runtime_entry = self.runtime_env;
            self.runtime_env = null;
            self.uses_threaded_runtime = false;
            self.setState(.closed);

            // Dispose owned result state first: a borrowed result may alias the
            // captured input, which is released right after this.
            if (comptime Result != void) {
                if (self.result_ready) {
                    self.result_ready = false;
                    ownership.disposeOwnedParts(Result, self.result, allocator);
                }
            }
            ownership.deinitValue(Input, self.input, allocator);

            // Native-only paths must still detach the abort registration: it
            // points back at this operation and would otherwise call into freed
            // memory when the event fires later. The listener references are
            // reclaimed by the environment.
            self.listener_error_ref = null;
            if (self.abort_registration) |registration| {
                registration.releaseWithoutJs();
                self.abort_registration = null;
            }

            if (self.err_snapshot) |*snapshot| {
                // The completion has been converted to a JavaScript value by now.
                snapshot.deinit();
                self.err_snapshot = null;
            }
            if (self.listener_failure_error) |*snapshot| {
                snapshot.deinit();
                self.listener_failure_error = null;
            }
            if (self.completion) |record| {
                self.completion = null;
                allocator.destroy(record);
            }

            if (self.descriptor_base) |base| {
                self.descriptor_base = null;
                base.destroy_fn(base);
            }

            // Once every producer stopped, the runtime is no longer needed by
            // this operation. Retiring it here (and never earlier) is what keeps
            // the runtime alive for producers that outlive their environment.
            if (runtime_entry) |entry| {
                releaseThreadedRuntime(entry);
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
