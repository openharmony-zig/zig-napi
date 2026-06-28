---
title: Functions
---

# Functions

Function wrappers represent JavaScript callables with Zig types.

## `Function`

```zig
napi.Function(comptime Args: type, comptime Return: type)
```

Use `Function` when Zig needs to call a JavaScript function or expose a Zig function manually.

```zig
const Callback = napi.Function(.{ i32, i32 }, i32);

pub fn call(callback: Callback) !i32 {
    return callback.Call(.{ 1, 2 });
}
```

| Method | Use |
| --- | --- |
| `from_raw(env, raw)` | Wrap an existing JavaScript function. |
| `New(env, name, value)` | Create a JavaScript function from a Zig function. |
| `Call(args)` | Call the JavaScript function and convert the result. |
| `CreateRef()` | Create `Reference(Function(Args, Return))`. |

`Args` may be a tuple type for multiple arguments, a non-tuple type for one argument, or an empty struct for no arguments.

## Function Exports

When a `pub fn` is exported through `NODE_API_MODULE`, the wrapper:

1. Injects `napi.Env` when it is the first parameter.
2. Converts JavaScript arguments into Zig parameter types.
3. Calls the Zig function.
4. Converts the return value into JavaScript.
5. Maps Zig errors and `napi.Result(T).Err` into JavaScript exceptions.

If the returned payload is an async descriptor, the function returns a Promise and schedules the async operation.

## `FunctionRef`

```zig
napi.FunctionRef(comptime Args: type, comptime Return: type)
```

`FunctionRef` is a convenience alias for `Reference(Function(Args, Return))`.

Use it when the native side needs to hold a JavaScript function beyond the current call.

## `CallbackInfo`

```zig
napi.CallbackInfo
```

`CallbackInfo` is the low-level callback context. It reads callback arguments with an inline buffer for up to eight arguments and heap storage for larger calls.

| Method | Use |
| --- | --- |
| `from_raw(env, info)` | Read callback information. |
| `deinit()` | Free heap-backed argument storage. |
| `Env()` | Return `napi.Env`. |
| `Get(index)` | Return argument as `NapiValue`. |
| `Len()` | Argument count. |
| `ArgsRaw()` | Raw `napi_value` slice. |
| `ArgRaw(index)` | One raw argument. |
| `This()` | Raw `this` value. |

Most exported functions should use typed Zig parameters instead. `CallbackInfo` is useful for variadic or dynamic APIs.

## `ThreadSafeFunction`

```zig
napi.ThreadSafeFunction(
    comptime Args: type,
    comptime Return: type,
    comptime ThreadSafeFunctionCalleeHandled: anytype,
    comptime MaxQueueSize: anytype,
)
```

Use `ThreadSafeFunction` to call a JavaScript function from native threads. It requires Node-API v4 or newer.

`ThreadSafeFunctionCalleeHandled = true` makes the JavaScript callback receive an error-first argument: `(err, ...args) => void`.

| Method | Use |
| --- | --- |
| `from_raw(env, raw)` | Create a TSFN from a JavaScript function. |
| `acquire()` | Increment active thread usage. |
| `release(mode)` | Release usage or abort release. |
| `abort()` | Stop future calls. |
| `ref()` / `unref()` | Control event-loop lifetime. |
| `Ok(args, mode)` | Send a successful call. |
| `Err(error, mode)` | Send an error call. |
| `deinit()` | Destroy the wrapper allocation. |

## TSFN Modes

```zig
napi.ThreadSafeFunctionMode.NonBlocking
napi.ThreadSafeFunctionMode.Blocking
napi.ThreadSafeFunctionReleaseMode.Release
napi.ThreadSafeFunctionReleaseMode.Abort
```

`NonBlocking` may fail with `QueueFull` when the queue is full. `Blocking` waits for room. Release mode controls whether the TSFN drains normally or aborts queued work.
