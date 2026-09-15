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

| Method               | Use                                                                             |
| -------------------- | ------------------------------------------------------------------------------- |
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

| Method         | Use                                                                                                                                                                     |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Queue()`      | Queue work without returning a Promise. A worker that cannot be queued releases itself (this entry point has no failure channel).                                       |
| `AsyncQueue()` | Queue work and return a `napi.Promise`. Setup failures are thrown instead of publishing a promise that would never settle, and release the worker.                      |
| `Cancel()`     | Cooperatively cancel a queued work item; the promise settles with an `AbortError` when the runner had not started.                                                      |
| `deinit()`     | Release work item, captured data and wrapper. While the work item is running the release is deferred to the completion callback, so `deinit` from `OnComplete` is safe. |

A worker can only be queued once: a second `Queue`/`AsyncQueue` is refused instead of settling one promise twice. The runner's result is released after the conversion on every path (`Queue`, `AsyncQueue`, rejection and cancellation), so native memory returned as `napi.Owned` is never leaked.

Async wrappers, workers, and `ThreadSafeFunction` require Node-API v4 or newer.

## Runtime Targets And Scheduling

`Async(R, runtime)` names a runtime, not a thread. What that runtime resolves to
depends on the target the addon was built for:

| Runtime   | Native build                                                                                        | WASI, threaded                                                                                      | WASI, single-threaded                                                                                     |
| --------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `.single` | body runs on the calling thread through the single-threaded IO runtime; the exported call returns after it finished | same                                                                                                | same                                                                                                        |
| `.thread` | body runs on the addon's IO runtime threads; the completion returns through a thread-safe function    | body runs on the emnapi JavaScript worker pool, in parallel, over one shared linear memory           | the same descriptor is executed by the `@emnapi/core` plugin on the JavaScript thread: no worker, no parallelism |
| `.event`  | evented IO when the target provides it, otherwise the threaded runtime                                | same resolution                                                                                      | same resolution                                                                                             |

The single-threaded WASI flavor is the one that changes observable behavior, and
it changes it in one direction: the producer is the host's own thread.

- **Events are delivered inline.** A threaded operation deep-copies each event
  into the bounded queue described under [Event delivery](#event-delivery). When
  the producer runs on the host's thread there is no queue at all: the listener
  is called inside `emit`, before it returns, and `max_inflight_events` never
  applies. Either way the producer may reuse its buffer once `emit` returned.
  The `.single` runtime behaves that way on every target.
- **Nothing the producer does can be interrupted by a timer.** A JavaScript
  timer needs the event loop, and the loop is inside the wasm call.
- **Ownership does not change.** The captured input is cloned for both thread
  runtimes, and results follow the borrowed/`Owned` rules above; see
  [WASM Runtime](./wasm-runtime) for the allocation limits of the module itself.

## Cancellation Checkpoints

Cancellation is cooperative on every runtime: nothing preempts a running body,
and `scheduleWithSignal` (or the `AbortSignal` parameter of an exported
function) only flips the operation's cancel token. The token is read at
checkpoints:

| Checkpoint                    | Behavior when the token is set                                              |
| ----------------------------- | --------------------------------------------------------------------------- |
| `emit(event)`                 | returns `error.Cancelled` before anything is queued or delivered             |
| `checkCancelled()`            | returns `error.Cancelled`                                                    |
| submit, with an aborted signal | the promise rejects with the `AbortError` and the body never runs            |

Where the cancellation comes from matters only for a host-thread producer. When
the body runs on a different thread (native and threaded WASI), the event loop
stays free and a timer, a request handler or a signal can abort at any time;
the producer notices it a few events later, at its next checkpoint. When the
body runs on the host's own thread (the `.single` runtime, and the
single-threaded WASI flavor), no timer can fire while it runs, so cancellation
has to be requested by something that runs during the body - the event listener
is the one that always does, and an `AbortController` aborted inside it is
visible at the very next checkpoint. A task that already finished keeps its
result; a late cancellation does not rewrite a settled promise.

## Teardown And Disposal

Destroying an environment is not "reject whatever is pending". A WebAssembly
instance runs a barrier first, so that work still in flight settles while
JavaScript is still allowed to run:

| Situation                                                    | Outcome                                                                                        |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| a running task the barrier can cancel                         | rejects with the `AbortError`                                                                   |
| a task that finished before its completion callback was published | still resolves with the result it produced, queued behind the progress events it already emitted |
| a task submitted after the barrier                            | rejects with code `Cancelled`; no listener runs and no event is produced                         |
| queued progress events                                        | delivered in the producer's order, before the settlement that follows them                       |

The loader drives that handshake and then waits - in real event-loop turns - for
the queue to drain before it destroys the context, which is why disposal is
awaited rather than fired and forgotten. A queue that is still non-empty when
the bounded wait runs out makes the disposal reject with
`ERR_NAPI_WASI_CLEANUP_PENDING` instead of destroying the context over it. The
loader-level commands and their error codes are in
[WASM Runtime](./wasm-runtime).

Two rules follow for addon code:

- A settled promise does not mean the native side is finished with it. On a
  threaded runtime the worker can return before the host publishes the
  completion, and the ownership of captured inputs, events and results follows
  the completion, not the promise.
- Release resources on the paths that own them. `emit` copies an event that
  crosses a thread, so the producer keeps and may reuse its own buffer; the
  payload handed to a thread-safe function's `Ok`/`Err` is owned by that call on
  every path; an `Owned` result is released after its conversion. What the body
  itself acquires - a thread-safe function it received, an explicit
  `Reference` - is released by the body, and a disposal that never completed
  leaves that work to the retry.

## Worked Example: Progress, Abort, And Disposal

The file below is a complete addon root: it emits one event per chunk, checks
cancellation at each step, and returns a total. It is the shape the repository's
own async acceptance uses (`node-test/napi/src/async_tasks.zig`), and it can be
dropped into a scaffold's `src/lib.zig`.

```zig
const std = @import("std");
const napi = @import("napi");

const Chunk = struct {
    text: []const u8,
    index: u32,
};

fn processChunks(ctx: napi.AsyncContext(Chunk), total: u32) !u32 {
    var buffer: [32]u8 = undefined;
    var index: u32 = 0;
    while (index < total) : (index += 1) {
        // `emit` checks the cancel token before it queues anything.
        const label = std.fmt.bufPrint(&buffer, "chunk-{d}", .{index}) catch continue;
        try ctx.emit(.{ .text = label, .index = index });
        // A queued event was deep-copied, and an inline listener has already
        // returned, so this buffer can be reused right here on every runtime.
        @memset(&buffer, 'x');
    }
    return total;
}

/// `signal` is an ordinary parameter: the generated wrapper converts it and
/// binds it to the operation's cancel token, so the body does not read it.
pub fn processChunksWithProgress(total: u32, signal: napi.AbortSignal) napi.AsyncWithEvents(u32, Chunk, .thread) {
    _ = signal;
    return napi.AsyncWithEvents(u32, Chunk, .thread).from(total, processChunks);
}

comptime {
    napi.NODE_API_MODULE("my_addon", @This());
}
```

Declaration generation appends the listener after every declared parameter, so
the JavaScript signature is:

```ts
export declare function processChunksWithProgress(
  total: number,
  signal: AbortSignal,
  onEvent?: (event: { text: string; index: number }) => void,
): Promise<number>
```

The listener is optional and last; `undefined`, `null` and an omitted argument
all mean "no listener", and a non-callable value is rejected. Using it, with the
disposal a WASI binding needs:

```js
// Native build: require("./my_addon.darwin-arm64.node") (or the scaffold's
// index.js, which picks the platform binary itself). WASI build: require the
// generated loader ("./my_addon.wasip1.cjs", or ".wasi.cjs" for the threaded
// flavor), which publishes the disposal hook used below.
const addon = require("./my_addon.wasip1.cjs");

async function main() {
  try {
    const controller = new AbortController();
    const seen = [];

    const outcome = await addon
      .processChunksWithProgress(1024, controller.signal, (event) => {
        seen.push(event.index);
        if (event.index === 7) {
          // The listener always runs on the host's JavaScript thread. On the
          // threadless WebAssembly flavor the producer is that same thread, so
          // this abort is visible at its next checkpoint.
          controller.abort();
        }
      })
      .then(
        (total) => ({ total }),
        (error) => ({ error }),
      );

    if (outcome.error) {
      // Aborted mid-run: the runner stopped early, and the events it did emit
      // were delivered in order before this rejection.
      console.error(outcome.error.code, seen.length); // AbortError, fewer than 1024
    } else {
      console.log(outcome.total, seen.length); // 1024, 1024
    }
  } finally {
    // The WASI loaders publish this hook; a native `.node` binding has none.
    // Await it: disposal drains the settlements the barrier queued.
    const dispose = addon[Symbol.for("napi.rs.wasi.dispose")];
    if (dispose) await dispose();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```

Two details the example depends on, both documented above: the rejection is the
`AbortError` the operation's own cancellation produces (not a fresh error), and
every event the runner emitted before it noticed the abort has already been
delivered when the promise settles.
