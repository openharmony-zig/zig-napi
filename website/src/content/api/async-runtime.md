---
title: Async Runtime
---

# Async Runtime

Async descriptors turn native work into JavaScript promises.

## `AsyncRuntime`

```zig
napi.AsyncRuntime
```

Runtime values:

| Value                                | Behavior                                                                         |
| ------------------------------------ | -------------------------------------------------------------------------------- |
| `.single`                            | Run on the single-threaded IO runtime.                                           |
| `.thread`                            | Run on the shared threaded IO runtime.                                           |
| `.event`                             | Use evented IO when available, otherwise fall back through the runtime resolver. |
| `.serial` / `.threaded` / `.evented` | Backward-compatible spellings.                                                   |

`resolveRequestedRuntime(runtime)` normalizes the backward-compatible spellings.

## `Async`

```zig
napi.Async(comptime Result: type, comptime runtime: napi.AsyncRuntime)
```

Use `Async` for work that produces one final result.

```zig
fn execute(input: u32) !u32 {
    return input + 1;
}

pub fn run(value: u32) napi.Async(u32, .thread) {
    return napi.Async(u32, .thread).from(value, execute);
}
```

The run function must accept either `(input)` or `(napi.AsyncContext(void), input)` and return `Result` or `!Result`.

Captured native inputs are deep-copied; the original converted arguments are still
released when the exporting function returns. JavaScript-backed handles must not
be captured for background use: first convert them to native data. Async results
are borrowed unless explicitly wrapped in `napi.Owned(T)`. Heap-allocated results
must use `Owned`, whereas a literal or an alias of captured input may be returned
as a plain slice. This is a source-level ownership change from older releases.

## `AsyncWithEvents`

```zig
napi.AsyncWithEvents(
    comptime Result: type,
    comptime Event: type,
    comptime runtime: napi.AsyncRuntime,
)
```

Use this when native work emits progress events before resolving.

```zig
const Progress = struct { current: u32, total: u32 };

fn execute(ctx: napi.AsyncContext(Progress), total: u32) !u32 {
    for (0..total) |index| {
        try ctx.emit(.{ .current = @intCast(index), .total = total });
        try ctx.checkCancelled();
    }
    return total;
}
```

When an exported function returns `AsyncWithEvents`, declaration generation adds a trailing optional event listener parameter.

Emitting without that listener (omitted, `undefined` or `null`) does not copy the
event: nothing can observe it, so the producer keeps running at full speed.

## Event delivery

On a threaded runtime the event crosses a thread boundary, so it must own its
data: `emit` deep-copies the event before queueing it. Delivery order is FIFO -
every event emitted before the task returned is delivered before the Promise
settles, and a listener exception therefore always precedes the settlement.

One operation keeps at most 256 undelivered events (`max_inflight_events`).
Beyond that the producer waits for the JavaScript side to drain the queue instead
of growing memory without bound. The wait is native: it is released as the queue
drains, when the task is cancelled, and when the environment shuts down, so it
can never depend on the very thread that is waiting for the task's promise.

Settlement reason priority, highest first:

1. the exception the event listener threw (delivered exactly as thrown, including
   primitives such as `42`, `"boom"`, `null` and `undefined`),
2. the cancellation (`AbortError`),
3. the runner's own error or a failed result conversion,
4. a failure while cleaning up (for example a hostile `removeEventListener` that
   throws),
5. the task's result.

A cleanup failure is always cleared from the environment - it never escapes as an
uncaught Node-API callback exception - and it only becomes the rejection reason
when the task itself had none.

## Scheduling

Async descriptors expose:

| Method                                                 | Use                                                              |
| ------------------------------------------------------ | ---------------------------------------------------------------- |
| `from(input, run_fn)`                                  | Create a descriptor from input data and a runner function.       |
| `tryFrom(input, run_fn)`                               | Fallible creation; propagate allocation/clone errors with `try`. |
| `schedule(env)`                                        | Schedule without listener or abort signal.                       |
| `scheduleWithListener(env, listener)`                  | Schedule with a JavaScript event listener.                       |
| `scheduleWithSignal(env, signal)`                      | Schedule with cancellation.                                      |
| `scheduleWithListenerAndSignal(env, listener, signal)` | Schedule with both.                                              |
| `deinit()`                                             | Destroy an unscheduled descriptor.                               |

Exported functions usually return the descriptor instead of calling `schedule` manually. The function wrapper schedules it and returns the Promise.

A descriptor has one owner. Schedule it once, or call `deinit` if it is never
scheduled. Do not copy it into independently used owners. Prefer `tryFrom` when
allocation failure must be recoverable.

## `AsyncContext`

```zig
napi.AsyncContext(comptime Event: type)
```

Context helpers:

| Method             | Use                                               |
| ------------------ | ------------------------------------------------- |
| `emit(event)`      | Emit one event. Invalid for `AsyncContext(void)`. |
| `isCancelled()`    | Read cancellation state.                          |
| `checkCancelled()` | Return `error.Cancelled` when cancelled.          |
| `awaitGroup()`     | Await the IO group.                               |
| `cancelGroup()`    | Cancel the IO group.                              |

## `CancelToken`

```zig
napi.CancelToken
```

Small cancellation primitive:

| Method          | Use                                      |
| --------------- | ---------------------------------------- |
| `cancel()`      | Mark cancelled.                          |
| `isCancelled()` | Read state.                              |
| `check()`       | Return `error.Cancelled` when cancelled. |

## `AbortSignal`

```zig
napi.AbortSignal
```

`AbortSignal` binds JavaScript cancellation to native callbacks.

| Method                      | Use                                   |
| --------------------------- | ------------------------------------- |
| `from_raw(env, raw)`        | Wrap an existing signal value.        |
| `from_napi_value(env, raw)` | Conversion hook.                      |
| `isAborted()`               | Read the signal's `aborted` property. |
| `bind(context, callback)`   | Register a native abort callback.     |

`bind` returns `*AbortRegistration`. `bindOwned(owner, callback)` additionally
lets the registration take a reference on the callback's context (`ContextOwner`
with `retain`/`release`), so an abort that arrives while the context is being
torn down observes an inactive registration instead of a freed one.

## `AbortRegistration`

| Method               | Use                                                                            |
| -------------------- | ------------------------------------------------------------------------------ |
| `requestAbort()`     | Invoke the registered native callback.                                          |
| `release()`          | Remove the registration and delete the signal reference (JavaScript thread).    |
| `releaseWithoutJs()` | Detach without touching JavaScript, for teardown while the environment is gone. |
| `isActive()`         | True while the registration may still deliver `abort`.                          |

A registration is reference counted between the caller and its listener function,
so it stays valid until both released it, whichever order that happens in.
`releaseWithoutJs` never calls back into the environment.

`Promise.RejectAbortError()` and async cancellation use the same `AbortError` shape.

## `Worker`

```zig
napi.Worker(env: napi.Env, data: anytype)
napi.WorkerBorrowed(env: napi.Env, data: anytype)
napi.tryWorker(env: napi.Env, data: anytype) !*WorkerContext(...)
napi.tryWorkerBorrowed(env: napi.Env, data: anytype) !*WorkerContext(...)
```

`Worker` is a wrapper around `napi_async_work`. The input data must be a struct with `data` and `Execute` fields. It may also include `OnComplete`.

`Execute` accepts `(data)` or `(napi.Env, data)` and may return `T`, `!T`, `napi.Result(T)`, or `!napi.Result(T)`. `OnComplete` accepts `(data)` or `(napi.Env, data)`.

### Data ownership

`Worker` **deep-copies** `data` before the work item is created, so the runner never reads memory the exporting call has already released:

```zig
pub fn checksum(env: napi.Env, input: []const u8) !napi.Promise {
    // `input` is released when this function returns; the worker owns a copy.
    return napi.Worker(env, .{ .data = input, .Execute = hash }).AsyncQueue();
}
```

The copy is released exactly once, after the result has been converted and after `OnComplete` returned. Native values, slices, optionals, arrays, structs/unions of those and `napi.Owned` payloads can be captured; JavaScript handles, error payloads (their message text is borrowed) and non-slice pointers are rejected at compile time.

A value the worker cannot own - a pointer to a capability like an acquired `ThreadSafeFunction`, a static buffer, memory the caller releases in `OnComplete` - uses the borrowed mode instead:

```zig
const worker = napi.WorkerBorrowed(env, .{ .data = tsfn, .Execute = run });
```

The worker stores it as it is and never releases it: the caller keeps it alive until `OnComplete` returned (or until its own acquisition is released). A named options type can also declare the mode, and a conflict with the entry point used is a compile error:

```zig
const Options = struct {
    pub const data_transfer: napi.WorkerDataTransfer = .borrowed;
    data: *Tsfn,
    Execute: *const fn (*Tsfn) void,
};
```

A `data` value that is a compile time constant (`.{ .data = @as(u32, 1), ... }`) is not copied or released: a constant cannot dangle.

`tryWorker`/`tryWorkerBorrowed` report creation failures instead of aborting the process; `Worker`/`WorkerBorrowed` follow a documented OOM panic policy (an allocation failure has no channel through a constructor that returns a pointer).

### Lifecycle

A worker belongs to the JavaScript thread and environment that created it, and the handle is valid from creation until its completion callback ran - or until a reported setup failure released it. `Execute` is the only callback that runs on the worker thread; it must not call JavaScript (the `napi.Env` a two-parameter `Execute` receives is only for explicitly thread-safe N-API entry points such as `napi_call_threadsafe_function`).

| Method         | Use                                                                          |
| -------------- | ---------------------------------------------------------------------------- |
| `Queue()`      | Queue work without returning a Promise. A worker that cannot be queued releases itself (this entry point has no failure channel). |
| `AsyncQueue()` | Queue work and return a `napi.Promise`. Setup failures are thrown instead of publishing a promise that would never settle, and release the worker. |
| `Cancel()`     | Cooperatively cancel a queued work item; the promise settles with an `AbortError` when the runner had not started. |
| `deinit()`     | Release work item, captured data and wrapper. While the work item is running the release is deferred to the completion callback, so `deinit` from `OnComplete` is safe. |

A worker can only be queued once: a second `Queue`/`AsyncQueue` is refused instead of settling one promise twice. The runner's result is released after the conversion on every path (`Queue`, `AsyncQueue`, rejection and cancellation), so native memory returned as `napi.Owned` is never leaked.

Async wrappers, workers, and `ThreadSafeFunction` require Node-API v4 or newer.
