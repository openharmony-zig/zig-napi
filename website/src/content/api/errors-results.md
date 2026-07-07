---
title: Errors
---

# Errors

Error wrappers convert Zig failures into JavaScript exceptions or explicit result values.

## `Error`

```zig
napi.Error
```

`Error` is a union of JavaScript error kinds:

```zig
pub const Error = union(enum) {
    JsError: napi.JsError,
    JsTypeError: napi.JsTypeError,
    JsRangeError: napi.JsRangeError,
};
```

Create errors with:

| Constructor                         | Use                                                             |
| ----------------------------------- | --------------------------------------------------------------- |
| `withReason(reason)`                | Generic JavaScript `Error`.                                     |
| `withStatus(status)`                | Error from `napi.Status` or custom status string.               |
| `withCodeAndMessage(code, message)` | Error with explicit code and message.                           |
| `fromAnyError(err)`                 | Map a Zig error into `napi.Error`.                              |
| `withTypeError(reason)`             | JavaScript `TypeError`.                                         |
| `withRangeError(reason)`            | JavaScript `RangeError`.                                        |
| `fromReason(reason)`                | Store a pending error and return `error.GenericFailure`.        |
| `fromStatus(status)`                | Store a pending status error and return `error.GenericFailure`. |
| `typeError(message)`                | Store a pending `TypeError`.                                    |
| `rangeError(message)`               | Store a pending `RangeError`.                                   |

Use `throwInto(env)` when manual code needs to throw into a JavaScript environment.

## `JsError`, `JsTypeError`, `JsRangeError`

```zig
napi.JsError
napi.JsTypeError
napi.JsRangeError
```

These typed wrappers map directly to JavaScript `Error`, `TypeError`, and `RangeError`.

| Method                 | Use                                       |
| ---------------------- | ----------------------------------------- |
| `fromMessage(message)` | Create with a message and generic status. |
| `fromStatus(status)`   | Create from status.                       |
| `to_napi_error(env)`   | Create a JavaScript error value.          |
| `throwInto(env)`       | Throw into the environment.               |

## Error Mapping

The conversion layer uses pending error state internally for low-level conversion failures. If a wrapper stores a specific `napi.Error`, the exported function wrapper throws that error. Otherwise it maps `Cancelled` to `AbortError`, `Closing` to a closing status, and other Zig errors to an error whose code and message are based on `@errorName(err)`.

## `Result(T)`

```zig
napi.Result(comptime T: type)
```

Return a value-or-error union from exported functions:

```zig
pub fn maybeRead(ok: bool) napi.Result([]const u8) {
    if (!ok) return napi.Result([]const u8).Err(napi.Error.withReason("not ready"));
    return napi.Result([]const u8).Ok("ready");
}
```

Use `Result(T)` when the public API should model a handled result without throwing through Zig error unions.

| Method                | Use                        |
| --------------------- | -------------------------- |
| `Result(T).Ok(value)` | Return a payload.          |
| `Result(T).Err(err)`  | Return a JavaScript error. |

`Result(void).Ok({})` converts to JavaScript `undefined`.

## Zig Error Unions

Exported functions may return `!T`. On success, `T` is converted normally. On failure, the wrapper maps the Zig error to `napi.Error` and throws it into JavaScript.

When you need a specific JavaScript error type, return `napi.Error.typeError(...)`, `napi.Error.rangeError(...)`, or `napi.Error.fromReason(...)` from the Zig error path.

## `Status`

```zig
napi.Status
```

`Status` wraps `napi_status`.

| Method                      | Use                       |
| --------------------------- | ------------------------- |
| `from_raw(raw)`             | Convert raw N-API status. |
| `New(status)`               | Convenience constructor.  |
| `isOk()`                    | Check for `Ok`.           |
| `code()`                    | Numeric status code.      |
| `toString()` / `ToString()` | Stable status text.       |

## Status Values

`Status` includes:

```zig
.Ok
.InvalidArg
.ObjectExpected
.StringExpected
.NameExpected
.FunctionExpected
.NumberExpected
.BooleanExpected
.ArrayExpected
.GenericFailure
.PendingException
.Cancelled
.EscapeCalledTwice
.HandleScopeMismatch
.CallbackScopeMismatch
.QueueFull
.Closing
.BigintExpected
.DateExpected
.ArrayBufferExpected
.DetachableArraybufferExpected
.WouldDeadlock
.NoExternalBuffersAllowed
.CannotRunJs
.RuntimeSpecific24
.Unknown
```

On OpenHarmony, some runtime-specific status names map to Ark runtime text in
`ToString()`.
