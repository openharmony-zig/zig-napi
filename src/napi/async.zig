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

/// Largest number of events that may be queued but not delivered yet.
///
/// Past this point a producer waits for the JavaScript side to catch up instead
/// of growing the queue without bound. The wait is native (a condition variable),
/// so it never depends on JavaScript running and can never deadlock the
/// environment's thread. Completions are posted outside this budget, so the
/// final settlement is never dropped or delayed by a full event queue.
pub const max_inflight_events = 256;

/// Gate of one thread-safe function handle, packed into a single word so that
/// producers and the finalizer agree on one total order:
///
/// * `active`  - pushes that were admitted and have not returned yet,
/// * `closing` - no new push may be admitted,
/// * `owned`   - the handle's fate belongs to the engine (the finalizer ran, or
///               a push returned `napi_closing`, which already consumed this
///               thread's reference): it must never be released by us again.
///
/// Node calls the user finalizer *before* it drains the queue with a null
/// environment and deletes the handle, so the finalizer closes the gate and
/// waits for the admitted pushes to return; a producer that was admitted before
/// that can therefore finish its (non-blocking) push safely.
/// The word is 32 bits wide because 32-bit targets (the WASI build) have no
/// 64-bit atomics.
const dispatcher_active_mask: u32 = 0xffff;
const dispatcher_closing_bit: u32 = 1 << 16;
const dispatcher_owned_bit: u32 = 1 << 17;

/// Highest number of events any operation held in flight at once. Diagnostic for
/// the bounded-queue regression test; monotonic until it is reset.
var inflight_events_high_water: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// See `inflight_events_high_water`.
pub fn eventQueueHighWaterMark() usize {
    return inflight_events_high_water.load(.acquire);
}

/// Reset the high water mark so a test can measure one operation.
pub fn resetEventQueueHighWaterMark() void {
    inflight_events_high_water.store(0, .release);
}

/// Record a new in-flight observation (diagnostics only, monotonic).
fn noteInflightHighWater(count: usize) void {
    var observed = inflight_events_high_water.load(.monotonic);
    while (observed < count) {
        observed = inflight_events_high_water.cmpxchgWeak(observed, count, .release, .monotonic) orelse break;
    }
}

/// A unit of deferred cleanup that is allowed to block.
///
/// The node is owned by the work item itself (intrusive, preallocated), so
/// queueing never allocates and can never fail halfway.
pub const ReapNode = struct {
    next: ?*ReapNode = null,
    context: ?*anyopaque = null,
    run: ?*const fn (?*anyopaque) void = null,
};

/// Shared, bounded reaper for cleanup that must not run on (or block) the
/// environment's thread.
///
/// Bounded in *threads*: at most `max_workers` helper threads exist per module,
/// created on demand. The queue is an intrusive list of caller-owned nodes, so
/// it has no capacity limit, and work is never dropped: if no helper can be
/// started the node stays queued until one can.
pub const ReapService = struct {
    lock: std.atomic.Mutex = .unlocked,
    head: ?*ReapNode = null,
    tail: ?*ReapNode = null,
    /// Nodes currently queued.
    pending: usize = 0,
    workers: usize = 0,
    max_workers: usize = 4,

    const Self = @This();

    /// Queue `node` and make sure a helper is running.
    pub fn submit(self: *Self, node: *ReapNode, run: *const fn (?*anyopaque) void, context: ?*anyopaque) void {
        node.context = context;
        node.run = run;

        spinLock(&self.lock);
        node.next = null;
        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
        self.pending += 1;
        // One worker per outstanding item, capped: a worker can block for a long
        // time, so a single one would serialize unrelated cleanups.
        const need_worker = self.workers < self.max_workers and (self.workers == 0 or self.pending > self.workers);
        if (need_worker) self.workers += 1;
        self.lock.unlock();

        if (!need_worker) return;
        const thread = std.Thread.spawn(.{}, reaperMain, .{self}) catch {
            // No helper available: the node stays queued (never dropped), and
            // the next submit starts a worker that picks it up.
            spinLock(&self.lock);
            self.workers -= 1;
            self.lock.unlock();
            return;
        };
        thread.detach();
    }

    fn pop(self: *Self) ?*ReapNode {
        spinLock(&self.lock);
        defer self.lock.unlock();
        const node = self.head orelse return null;
        self.head = node.next;
        if (self.head == null) self.tail = null;
        node.next = null;
        self.pending -= 1;
        return node;
    }

    fn peekHasWork(self: *Self) bool {
        spinLock(&self.lock);
        defer self.lock.unlock();
        return self.head != null;
    }

    fn claimWorker(self: *Self) bool {
        spinLock(&self.lock);
        defer self.lock.unlock();
        if (self.workers >= self.max_workers) return false;
        self.workers += 1;
        return true;
    }

    fn releaseWorker(self: *Self) void {
        spinLock(&self.lock);
        defer self.lock.unlock();
        self.workers -= 1;
    }
};

/// Spin lock over `std.atomic.Mutex`.
///
/// The critical sections it protects are a few pointer updates, never an
/// allocation and never a call into N-API, so spinning (with a yield) is
/// preferable to a blocking mutex: it also works on single threaded targets,
/// where a contended blocking lock is unavailable.
fn spinLock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}

var reap_service: ReapService = .{};

/// Helper thread: runs deferred cleanup until the queue is empty, then exits.
///
/// The work may block for as long as the user task behind it runs; the node and
/// the reference it carries stay valid until it returns.
fn reaperMain(service: *ReapService) void {
    while (true) {
        const node = service.pop() orelse {
            service.releaseWorker();
            // Work that arrived while this worker was finishing is handled by
            // its own submit (which starts another worker when none is left);
            // if none is, this worker takes it over.
            if (!service.peekHasWork()) return;
            if (!service.claimWorker()) return;
            continue;
        };
        if (node.run) |run| run(node.context);
    }
}

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
        /// Largest number of events one operation keeps in flight (see
        /// `max_inflight_events`), exposed so regressions can assert the bound.
        pub const async_max_inflight_events = max_inflight_events;
        /// Highest number of in-flight events observed, process wide.
        pub fn asyncEventQueueHighWaterMark() usize {
            return eventQueueHighWaterMark();
        }
        /// Reset the observation above so a test can measure one operation.
        pub fn asyncResetEventQueueHighWaterMark() void {
            resetEventQueueHighWaterMark();
        }

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
        /// Exactly one consumer may await `controller_future`: the JavaScript
        /// thread while the environment is alive, or the shared reaper when it
        /// is not.
        controller_future_claimed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Preallocated work item handed to the shared reaper, so the teardown
        /// path never allocates a node or spawns a private thread.
        reap_node: ReapNode = .{},
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
        /// Lifecycle of the thread-safe function handle; see the module level
        /// constants for the protocol.
        dispatcher_word: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        /// Orders the queue accounting against the condition variable below.
        /// Never held while waiting for JavaScript, and never taken on a single
        /// threaded target (where a contended lock is unavailable).
        event_queue_mutex: std.Io.Mutex = .init,
        /// Producers waiting for a queue slot are woken here whenever one is
        /// released, the queue is closed, or the task is cancelled.
        event_queue_cond: std.Io.Condition = .init,
        /// Events posted to the dispatcher but not delivered yet.
        ///
        /// Atomic because a single threaded target (the WASI build) has no
        /// blocking primitive to wait on: it spins on this counter instead. On
        /// threaded targets the mutex above orders every access.
        inflight_events: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        /// Set once the dispatcher can no longer deliver.
        queue_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Recycled queue records.
        ///
        /// Guarded by a small spin lock, not a lock-free stack: several consumer
        /// threads recycle records concurrently, and a pointer-only CAS stack
        /// would be exposed to ABA. The lock is only ever held for a couple of
        /// pointer updates - never across an N-API call or an allocation.
        free_records: ?*DispatchData = null,
        records_lock: std.atomic.Mutex = .unlocked,
        /// True when a JavaScript listener was supplied. Producers read it to
        /// skip cloning and queueing events nobody would observe.
        has_event_listener: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        const Self = @This();
        const Context = AsyncContext(Event);
        const run_info = @typeInfo(@TypeOf(run_fn)).@"fn";
        const DispatchKind = enum { event, completion };

        /// A queued item owns everything needed to release it, including when
        /// the environment is already gone and the JS callback receives a null
        /// environment.
        ///
        /// The event payload is stored inline: one queue item is one allocation
        /// (and, in steady state, no allocation at all - the operation recycles
        /// its records through `free_records`).
        const DispatchData = struct {
            kind: DispatchKind,
            allocator: std.mem.Allocator,
            /// Owned event payload. Unused (and never read) for completions.
            payload: Event = if (Event == void) {} else undefined,
            /// Link of the operation's record pool; only valid while the record
            /// sits in `free_records`.
            next_free: ?*DispatchData = null,
        };

        /// See `max_inflight_events`.
        const queue_limit = max_inflight_events;

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

        /// Reaper callback: consume the controller's future and release the
        /// reference the finalizer took on the reaper's behalf.
        fn reapControllerFutureNode(raw: ?*anyopaque) void {
            const ptr = raw orelse return;
            const self: *Self = @ptrCast(@alignCast(ptr));
            defer self.dropOwner();
            if (self.controller_future) |*controller_future| {
                // Blocks until the controller returns, which is bounded by the
                // task the controller is waiting for - not by the environment.
                _ = controller_future.await(self.operationIo());
                self.controller_future = null;
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
                // Producers on other threads check this before cloning and
                // queueing an event nobody would ever observe.
                self.has_event_listener.store(self.listener_ref != null, .release);
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
            errdefer {
                var discardable = self.promise;
                discardable.discard();
                // A created thread-safe function already owns the initial
                // reference and its finalizer drops it (whether or not the
                // setup finished). Without one, this call still owns it.
                const dispatcher_owns_initial = self.tsfn_created;
                _ = self.destroyJs(self.env);
                if (!dispatcher_owns_initial) self.dropOwner();
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
                        // Every failure inside is covered by the errdefer above,
                        // which uses `tsfn_created` to decide who owns the
                        // initial reference - the setup can fail after the
                        // dispatcher was created.
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
                        // Nothing will observe the abort from here on: mark the
                        // task cancelled, refuse further events and wake a
                        // producer that is waiting for queue capacity *before*
                        // joining the task. Otherwise the join below would wait
                        // for a producer that is waiting for this thread to
                        // drain a queue it can no longer drain.
                        self.cancel_token.cancel();
                        self.cancel_requested = true;
                        self.closeEventQueue();
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
            // Cancellation must unblock producers waiting for queue capacity.
            self.wakeEventProducers();
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
                    // Without a listener nobody can observe the event: skip the
                    // deep copy and the queue entirely and keep producing. An
                    // explicit `undefined` listener lands here too.
                    if (!self.has_event_listener.load(.acquire)) return;

                    // Reserve capacity first: a full queue must throttle the
                    // producer, not grow memory without bound.
                    try self.reserveEventSlot();

                    const data = self.acquireRecord() orelse {
                        self.releaseEventSlot();
                        return error.OutOfMemory;
                    };
                    data.kind = .event;
                    data.allocator = self.allocator;
                    // The event crosses a thread boundary and is delivered
                    // later: it must own its data (a slice field would otherwise
                    // alias a buffer the producer may reuse or release).
                    data.payload = ownership.cloneValue(Event, event, self.allocator) catch |err| {
                        self.recycleRecord(data);
                        self.releaseEventSlot();
                        return err;
                    };

                    self.postToDispatcher(data) catch |err| {
                        ownership.deinitValue(Event, data.payload, self.allocator);
                        self.recycleRecord(data);
                        self.releaseEventSlot();
                        return err;
                    };
                },
            }
        }

        fn lockRecords(self: *Self) void {
            spinLock(&self.records_lock);
        }

        fn unlockRecords(self: *Self) void {
            self.records_lock.unlock();
        }

        /// Take a queue record from the operation's pool, allocating only when
        /// the pool is empty.
        fn acquireRecord(self: *Self) ?*DispatchData {
            self.lockRecords();
            if (self.free_records) |record| {
                self.free_records = record.next_free;
                self.unlockRecords();
                return record;
            }
            self.unlockRecords();

            // Allocation happens outside the lock: it can be slow and must never
            // serialize the JavaScript thread against a producer.
            const record = self.allocator.create(DispatchData) catch return null;
            record.* = .{ .kind = .completion, .allocator = self.allocator };
            return record;
        }

        /// Give a record back to the pool. Its payload must already be released.
        fn recycleRecord(self: *Self, data: *DispatchData) void {
            self.lockRecords();
            data.next_free = self.free_records;
            self.free_records = data;
            self.unlockRecords();
        }

        /// Claim one of the bounded event slots, waiting for the JavaScript side
        /// to drain the queue when it is full.
        ///
        /// The wait is purely native - it never requires the environment's
        /// thread to run - and ends as soon as the queue drains, the task is
        /// cancelled, or the dispatcher is gone. `napi_tsfn_blocking` is
        /// deliberately not used here: it can block forever when the environment
        /// is already shutting down.
        fn reserveEventSlot(self: *Self) !void {
            if (comptime builtin.single_threaded) {
                // A single threaded target has no blocking primitive to wait on
                // (the WASI executor shares atomics with the JavaScript thread,
                // which drains the queue): poll the counter instead.
                while (true) {
                    if (self.queue_closed.load(.acquire)) return error.Closing;
                    if (self.cancel_token.isCancelled()) return error.Cancelled;
                    const current = self.inflight_events.load(.acquire);
                    if (current < queue_limit) {
                        if (self.inflight_events.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) == null) {
                            noteInflightHighWater(current + 1);
                            return;
                        }
                        continue;
                    }
                    std.Thread.yield() catch {};
                }
            }

            const io = self.operationIo();
            // The classic condition-variable pattern: the predicate is
            // inspected and changed under the mutex, and the releaser takes the
            // same mutex before signalling, so no wake-up can be lost.
            self.event_queue_mutex.lockUncancelable(io);
            defer self.event_queue_mutex.unlock(io);

            while (true) {
                if (self.queue_closed.load(.acquire)) return error.Closing;
                if (self.cancel_token.isCancelled()) return error.Cancelled;
                const current = self.inflight_events.load(.monotonic);
                if (current < queue_limit) {
                    self.inflight_events.store(current + 1, .release);
                    noteInflightHighWater(current + 1);
                    return;
                }
                // Backpressure: wait until a queued event is delivered.
                self.event_queue_cond.waitUncancelable(io, &self.event_queue_mutex);
            }
        }

        /// Release an event slot once its record was delivered (or dropped).
        ///
        /// On threaded targets the counter is updated under the same mutex the
        /// waiter holds while it inspects it, so a decrement can never be lost
        /// (which would leave the queue permanently full) and a wake-up can
        /// never be lost (which would leave a producer asleep past a free slot).
        /// A single threaded target has no blocking mutex: it uses one atomic
        /// read-modify-write instead.
        fn releaseEventSlot(self: *Self) void {
            if (comptime builtin.single_threaded) {
                while (true) {
                    const current = self.inflight_events.load(.acquire);
                    if (current == 0) return;
                    if (self.inflight_events.cmpxchgWeak(current, current - 1, .acq_rel, .acquire) == null) return;
                }
            }

            const io = self.operationIo();
            self.event_queue_mutex.lockUncancelable(io);
            const current = self.inflight_events.load(.monotonic);
            if (current > 0) self.inflight_events.store(current - 1, .release);
            self.event_queue_mutex.unlock(io);
            self.event_queue_cond.signal(io);
        }

        /// Wake every producer waiting for a queue slot.
        ///
        /// The mutex round-trip orders this with a producer that already decided
        /// to wait: it is held for a few instructions and never across a wait,
        /// so it can neither block the JavaScript thread nor deadlock against a
        /// producer that is waiting for it to drain the queue.
        fn wakeEventProducers(self: *Self) void {
            if (comptime builtin.single_threaded) return;
            const io = self.operationIo();
            self.event_queue_mutex.lockUncancelable(io);
            self.event_queue_mutex.unlock(io);
            self.event_queue_cond.broadcast(io);
        }

        /// Refuse further events and wake every waiting producer.
        fn closeEventQueue(self: *Self) void {
            self.queue_closed.store(true, .release);
            self.wakeEventProducers();
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
            // Allocated before the promise is handed to JavaScript, so the
            // completion itself never has to allocate.
            const data = self.acquireRecord() orelse return error.OutOfMemory;
            data.kind = .completion;
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
                self.recycleRecord(data);
                return err;
            };
            self.completion = null;
        }

        /// Admit one push: returns false once the gate is closed.
        ///
        /// The admitted push keeps a count in the same word the finalizer and
        /// the releaser observe, so there is a single total order over "may
        /// push" and "the handle is going away".
        fn admitDispatcherPush(self: *Self) bool {
            while (true) {
                const word = self.dispatcher_word.load(.acquire);
                if ((word & dispatcher_closing_bit) != 0) return false;
                // A saturated counter refuses instead of corrupting the word.
                if ((word & dispatcher_active_mask) == dispatcher_active_mask) return false;
                if (self.dispatcher_word.cmpxchgWeak(word, word + 1, .acq_rel, .acquire) == null) return true;
            }
        }

        fn leaveDispatcherPush(self: *Self) void {
            _ = self.dispatcher_word.fetchSub(1, .acq_rel);
        }

        /// Close the gate and wait for every admitted push to return.
        ///
        /// The pushes are non-blocking N-API calls that only queue an item, so
        /// this is bounded; waiting is what lets Node delete the handle (right
        /// after the finalizer returns) without pulling it from under a push.
        fn closeDispatcherAndWait(self: *Self) void {
            _ = self.dispatcher_word.fetchOr(dispatcher_closing_bit, .acq_rel);
            while ((self.dispatcher_word.load(.acquire) & dispatcher_active_mask) != 0) {
                std.Thread.yield() catch {};
            }
        }

        /// Close the gate without waiting, for callers that must not block (a
        /// failed push on a producer thread, native-only teardown).
        fn closeDispatcher(self: *Self) void {
            _ = self.dispatcher_word.fetchOr(dispatcher_closing_bit, .acq_rel);
            self.closeEventQueue();
        }

        /// Claim the one release of the handle. False when the engine already
        /// owns it (finalizer ran, or a push returned `napi_closing`).
        fn claimDispatcherRelease(self: *Self) bool {
            const previous = self.dispatcher_word.fetchOr(dispatcher_owned_bit, .acq_rel);
            return (previous & dispatcher_owned_bit) == 0;
        }

        /// Hand one queue record to the environment's dispatcher.
        ///
        /// The record must already own a reference to this operation: Node runs
        /// the user finalizer *before* it drains the queue with a null
        /// environment, so a queued item can outlive the last producer and the
        /// dispatcher's own reference.
        fn postToDispatcher(self: *Self, data: *DispatchData) !void {
            if (!self.admitDispatcherPush()) return error.Closing;

            self.retain();
            const status = napi.napi_call_threadsafe_function(self.tsfn_raw, @ptrCast(data), napi.napi_tsfn_nonblocking);
            self.leaveDispatcherPush();

            if (status != napi.napi_ok) {
                if (status == napi.napi_closing) {
                    // The engine already consumed this thread's reference: the
                    // handle must never be released or called again.
                    _ = self.dispatcher_word.fetchOr(dispatcher_closing_bit | dispatcher_owned_bit, .acq_rel);
                    self.closeEventQueue();
                } else {
                    // An incidental enqueue failure (for example a full engine
                    // queue): stop pushing, but leave the still-live handle for
                    // the JavaScript thread to release.
                    self.closeDispatcher();
                }
                self.dropOwner();
                return NapiError.Error.fromStatus(NapiError.Status.New(status));
            }
            return;
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

            // Release the producer futures. `await`/`cancel` are what free the
            // future's own allocation, and the controller always releases the
            // task's future in both of its branches; the controller's own future
            // is consumed here. The wait is bounded and never depends on
            // JavaScript: a completion item can only be processed after the
            // controller posted it, which is after it left
            // `waitForTaskDoneOrAbort`, so there is nothing left to wait for.
            // The claim keeps the reaper (teardown path) out of the same future.
            if (!self.controller_future_claimed.swap(true, .acq_rel)) {
                if (self.controller_future) |*controller_future| {
                    _ = controller_future.await(self.operationIo());
                    self.controller_future = null;
                }
            }
            self.future = null;

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
            // From here on the dispatcher owns the caller's reference: the
            // finalizer drops it, whether the rest of the setup succeeds or not.
            self.tsfn_created = true;
            self.dispatcher_word.store(0, .release);
        }

        fn dispatcherNoop(inner_env: napi.napi_env, _: napi.napi_callback_info) callconv(.c) napi.napi_value {
            return Undefined.New(Env.from_raw(inner_env)).raw;
        }

        /// The thread-safe function finalizer.
        ///
        /// Node runs this *before* it drains the queue with a null environment
        /// and deletes the handle, so the dispatcher is retired here first: no
        /// producer may push afterwards, and no producer can be inside a push
        /// while the engine walks the queue.
        ///
        /// Only the dispatcher's *reference* is dropped here. Producers may
        /// still be running - a finalized thread-safe function is not proof that
        /// they stopped - and they keep the operation alive until they return.
        /// The queued items own references of their own.
        fn dispatcherFinalize(_: napi.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const raw = data orelse return;
            const self: *Self = @ptrCast(@alignCast(raw));
            // The engine deletes the handle as soon as this returns: no push
            // may still be running, and the handle must never be released by us.
            self.closeDispatcherAndWait();
            _ = self.claimDispatcherRelease();
            self.closeEventQueue();
            self.js_released.store(true, .release);
            self.enqueueControllerReap();
            self.dropOwner();
        }

        /// Hand the controller's future to the shared reaper when the
        /// environment went away before the completion could be dispatched.
        ///
        /// `std.Io.concurrent` gives every task its own allocation, freed by
        /// exactly one `await`/`cancel`. The controller cannot await its own
        /// future (it would wait for itself) and the environment's thread must
        /// not wait for an abandoned user task, so a shared reaper thread
        /// consumes it instead. The work item is this operation's own
        /// preallocated node, so queueing never allocates and the operation
        /// reference it carries keeps the runtime alive until the future is
        /// really consumed.
        fn enqueueControllerReap(self: *Self) void {
            if (comptime builtin.single_threaded) return;
            if (self.controller_future == null) return;
            if (self.controller_future_claimed.swap(true, .acq_rel)) return;

            self.retain();
            reap_service.submit(&self.reap_node, reapControllerFutureNode, self);
        }

        /// Release the thread-safe function, once, from the JavaScript thread.
        ///
        /// It must not run anywhere else: the handle is created, released and
        /// finalized by the environment's thread, and a producer thread doing it
        /// could race the finalizer (which would free the handle underneath it).
        /// The release waits for in-flight pushes to return first.
        fn releaseDispatcher(self: *Self) void {
            // Stop new pushes and wake producers waiting on the queue first.
            self.closeDispatcher();
            // A push that already returned `napi_closing`, or a finalizer that
            // already ran, owns the handle's fate now: releasing it again would
            // touch an engine-owned (possibly freed) handle.
            if (!self.claimDispatcherRelease()) return;

            // Only then wait out the pushes that were admitted before the gate
            // closed; they are non-blocking calls and cannot wait for us.
            while ((self.dispatcher_word.load(.acquire) & dispatcher_active_mask) != 0) {
                std.Thread.yield() catch {};
            }
            if (self.tsfn_raw != null) {
                // May run the finalizer (and free this operation) before it
                // returns; nothing may touch `self` afterwards.
                _ = napi.napi_release_threadsafe_function(self.tsfn_raw, napi.napi_tsfn_release);
            }
        }

        fn dispatcherCallJs(inner_env: napi.napi_env, js_callback: napi.napi_value, context: ?*anyopaque, raw_data: ?*anyopaque) callconv(.c) void {
            const data: *DispatchData = @ptrCast(@alignCast(raw_data orelse return));
            const allocator = data.allocator;

            // The record's own reference keeps this operation alive even when
            // the environment's finalizer already ran (Node finalizes first and
            // only then drains the queue with a null environment).
            const self = operationFromContext(context) orelse {
                if (data.kind == .event) ownership.deinitValue(Event, data.payload, allocator);
                allocator.destroy(data);
                return;
            };
            // Everything below must finish before the reference is dropped:
            // releasing it may free the operation.
            defer {
                if (data.kind == .event) self.releaseEventSlot();
                self.recycleRecord(data);
                self.dropOwner();
            }

            // Node drains the queue with a null environment while shutting
            // down: release the queued payload natively and never touch JS.
            const env_alive = inner_env != null and js_callback != null;

            switch (data.kind) {
                .event => {
                    defer ownership.deinitValue(Event, data.payload, allocator);
                    if (!env_alive) return;
                    self.dispatchEvent(inner_env, data.payload);
                },
                .completion => {
                    if (!env_alive) return;
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
        /// `retire_dispatcher` retires the dispatcher so producers stop pushing
        /// and blocked producers wake up. The thread-safe function handle itself
        /// is *not* released here: only the environment's thread may do that,
        /// and the environment is exactly what these paths cannot trust. The
        /// engine finalizes (and deletes) the handle on its own when the
        /// environment goes away.
        fn destroyNativeOnly(self: *Self, retire_dispatcher: bool) void {
            self.js_released.store(true, .release);
            if (retire_dispatcher) self.closeDispatcher();
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
            // Records are only pooled while the operation lives; hand them back
            // to the allocator that created them (and stop any producer that is
            // still waiting for a slot).
            self.queue_closed.store(true, .release);
            self.lockRecords();
            var pooled = self.free_records;
            self.free_records = null;
            self.unlockRecords();
            while (pooled) |record| {
                const next = record.next_free;
                allocator.destroy(record);
                pooled = next;
            }
            self.wakeEventProducers();

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
