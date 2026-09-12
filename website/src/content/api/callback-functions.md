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

| Method                  | Use                                                  |
| ----------------------- | ---------------------------------------------------- |
| `from_raw(env, raw)`    | Wrap an existing JavaScript function.                |
| `New(env, name, value)` | Create a JavaScript function from a Zig function.    |
| `Call(args)`            | Call the JavaScript function and convert the result. |
| `CreateRef()`           | Create `Reference(Function(Args, Return))`.          |

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

| Method                | Use                                |
| --------------------- | ---------------------------------- |
| `from_raw(env, info)` | Read callback information.         |
| `deinit()`            | Free heap-backed argument storage. |
| `Env()`               | Return `napi.Env`.                 |
| `Get(index)`          | Return argument as `NapiValue`.    |
| `Len()`               | Argument count.                    |
| `ArgsRaw()`           | Raw `napi_value` slice.            |
| `ArgRaw(index)`       | One raw argument.                  |
| `This()`              | Raw `this` value.                  |

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

The error-first convention is strict: a successful call passes `null` in the
error slot followed by the queued arguments, and a failed call passes the error
**alone**. The error call has a single argument, so a callback written as
`(err, value) => void` sees `value === undefined` for a failure; the remaining
argument slots are omitted rather than filled with placeholder values.

Without `ThreadSafeFunctionCalleeHandled` there is no error slot. `Err()` still
runs the callback, with the argument slots passed as `undefined`; the error
itself cannot be delivered to JavaScript.

```js
const callback = (err, first, second) => {
  if (err) {
    // The failure call passed exactly one argument.
    return;
  }
  // A success passes the queued arguments after `null`.
};
```

| Method               | Use                                       |
| -------------------- | ----------------------------------------- |
| `from_raw(env, raw)` | Create a TSFN from a JavaScript function. |
| `acquire()`          | Increment active thread usage.            |
| `release(mode)`      | Release usage or abort release.           |
| `abort()`            | Stop future calls.                        |
| `ref()` / `unref()`  | Control event-loop lifetime.              |
| `Ok(args, mode)`     | Send a successful call.                   |
| `Err(error, mode)`   | Send an error call.                       |
| `deinit()`           | Destroy the wrapper allocation.           |

### Queueing and payload ownership

`Ok(args, mode)` and `Err(error, mode)` take ownership of their payload on every
path, including a full queue, a closing TSFN and a failed allocation: a returned
error means "not queued", never "you still own the payload". Both report
allocation failure as a Zig error instead of aborting the process.

`Err` copies the message and code of the error it is given. The text of a
`napi.Error` is borrowed, so the caller's buffer may be reused as soon as the
call returns; what JavaScript finally sees is the copy. The copy is released
when the call is delivered, when it is rejected, and when the queue is drained
during environment shutdown. If the copy itself cannot be allocated, the
delivered error degrades to a fixed native error instead of falling back to the
borrowed bytes. If the error object cannot be built at all, the failure call is
not dispatched (the payload is still released) - a failure is never delivered as
a successful call.

Queued calls keep working while the callback throws: the pending JavaScript
exception is left to the runtime, and later calls are still dispatched. Whether
that exception reaches `uncaughtException` depends on Node's
`--force-node-api-uncaught-exceptions-policy` option, not on this wrapper.

### TSFN parameters and conversion rollback

A `*napi.ThreadSafeFunction(...)` parameter promotes the JavaScript function it
received. The promotion is part of the argument conversion, so a call that is
rejected before the native body runs - for example because a later argument has
the wrong type - releases it again. Once the body runs, the TSFN belongs to the
body: it is usually handed to another thread, and nothing aborts it when the
exported function returns. The body remains responsible for the final
`release()`/`abort()`.

## TSFN Modes

```zig
napi.ThreadSafeFunctionMode.NonBlocking
napi.ThreadSafeFunctionMode.Blocking
napi.ThreadSafeFunctionReleaseMode.Release
napi.ThreadSafeFunctionReleaseMode.Abort
```

`NonBlocking` may fail with `QueueFull` when the queue is full. `Blocking` waits for room. Release mode controls whether the TSFN drains normally or aborts queued work.
