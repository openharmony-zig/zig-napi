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

| Value | Behavior |
| --- | --- |
| `.single` | Run on the single-threaded IO runtime. |
| `.thread` | Run on the shared threaded IO runtime. |
| `.event` | Use evented IO when available, otherwise fall back through the runtime resolver. |
| `.serial` / `.threaded` / `.evented` | Backward-compatible spellings. |

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

## Scheduling

Async descriptors expose:

| Method | Use |
| --- | --- |
| `from(input, run_fn)` | Create a descriptor from input data and a runner function. |
| `schedule(env)` | Schedule without listener or abort signal. |
| `scheduleWithListener(env, listener)` | Schedule with a JavaScript event listener. |
| `scheduleWithSignal(env, signal)` | Schedule with cancellation. |
| `scheduleWithListenerAndSignal(env, listener, signal)` | Schedule with both. |
| `deinit()` | Destroy an unscheduled descriptor. |

Exported functions usually return the descriptor instead of calling `schedule` manually. The function wrapper schedules it and returns the Promise.

## `AsyncContext`

```zig
napi.AsyncContext(comptime Event: type)
```

Context helpers:

| Method | Use |
| --- | --- |
| `emit(event)` | Emit one event. Invalid for `AsyncContext(void)`. |
| `isCancelled()` | Read cancellation state. |
| `checkCancelled()` | Return `error.Cancelled` when cancelled. |
| `awaitGroup()` | Await the IO group. |
| `cancelGroup()` | Cancel the IO group. |

## `CancelToken`

```zig
napi.CancelToken
```

Small cancellation primitive:

| Method | Use |
| --- | --- |
| `cancel()` | Mark cancelled. |
| `isCancelled()` | Read state. |
| `check()` | Return `error.Cancelled` when cancelled. |

## `AbortSignal`

```zig
napi.AbortSignal
```

`AbortSignal` binds JavaScript cancellation to native callbacks.

| Method | Use |
| --- | --- |
| `from_raw(env, raw)` | Wrap an existing signal value. |
| `from_napi_value(env, raw)` | Conversion hook. |
| `isAborted()` | Read the signal's `aborted` property. |
| `bind(context, callback)` | Register a native abort callback. |

`bind` returns `*AbortRegistration`.

## `AbortRegistration`

| Method | Use |
| --- | --- |
| `requestAbort()` | Invoke the registered native callback. |
| `release()` | Remove the registration and delete the signal reference. |

`Promise.RejectAbortError()` and async cancellation use the same `AbortError` shape.

## `Worker`

```zig
napi.Worker(env: napi.Env, data: anytype)
```

`Worker` is a wrapper around `napi_async_work`. The input data must be a struct with `data` and `Execute` fields. It may also include `OnComplete`.

`Execute` accepts `(data)` or `(napi.Env, data)` and may return `T`, `!T`, `napi.Result(T)`, or `!napi.Result(T)`. `OnComplete` accepts `(data)` or `(napi.Env, data)`.

| Method | Use |
| --- | --- |
| `Queue()` | Queue work without returning a Promise. |
| `AsyncQueue()` | Queue work and return a `napi.Promise`. |
| `Cancel()` | Cancel the async work. |
| `deinit()` | Delete work and destroy the wrapper. |

Async wrappers, workers, and `ThreadSafeFunction` require Node-API v4 or newer.
