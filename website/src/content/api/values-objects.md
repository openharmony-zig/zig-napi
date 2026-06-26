---
title: Objects And Arrays
---

# Objects And Arrays

`Env`, `Object`, `Array`, and `Promise` cover most manual JavaScript value work.

## `Env`

```zig
napi.Env
```

`Env` wraps `napi_env`. It is injected automatically when an exported function uses `napi.Env` as its first parameter.

| Method | Use |
| --- | --- |
| `from_raw(raw)` | Wrap an existing `napi_env`. |
| `getUndefined()` / `getNull()` | Get singleton JavaScript values. |
| `getNapiVersion()` | Read the host runtime Node-API version. |
| `getGlobal()` | Get the global object. |
| `createSymbol(description)` | Create a JavaScript symbol. |
| `createDate(value)` | Create a JavaScript Date. Requires Node-API v5. |
| `isExceptionPending()` | Check whether an exception is pending. |
| `getAndClearLastException()` | Consume the pending exception as `NapiValue`. |
| `wrap` / `wrapWithSizeHint` | Attach native payload to an object. |
| `unwrap` / `unwrapConst` | Read native payload from an object. |
| `dropWrapped` | Remove and destroy a wrapped payload. |
| `matchesWrapped` | Check whether an object carries a payload of type `T`. |

## `Object`

```zig
napi.Object
```

Common operations:

| Method | Use |
| --- | --- |
| `Object.Create(env)` | Create an empty JavaScript object. |
| `Object.New(env, value)` | Convert a Zig object-like value. |
| `Set(key, value)` | Set a named string property. |
| `SetProperty(key, value)` | Set a property with a dynamic key. |
| `setProperty(key, value)` | Lowercase alias for `SetProperty`. |
| `Get(key, T)` | Read a property and convert it to `T`. |
| `GetNamed(key, T)` | Read a comptime-known named property. |
| `Has(key)` | Check for a named property. |
| `propertyNames()` | Return property names as `napi.Array`. |
| `isDate()` / `dateValue()` | Inspect Date values. Requires Node-API v5. |
| `freeze()` / `seal()` | Apply JavaScript object immutability operations. Requires Node-API v8. |
| `CreateRef()` | Create `Reference(Object)`. |
| `Wrap` / `Unwrap` / `DropWrapped` | Convenience native wrap operations. |

Automatic object conversion maps object-like Zig structs to JavaScript objects. Optional struct fields become optional TypeScript properties during declaration generation.

## `Array`

```zig
napi.Array
```

Arrays support length, indexed reads, indexed writes, push, element existence checks, and element deletion.

```zig
var array = try napi.Array.CreateWithLength(env, 0);
try array.Push("first");
try array.Push(42);
```

| Method | Use |
| --- | --- |
| `Array.New(env, value)` | Create an array from a Zig array, slice, tuple, or `std.ArrayList(T)`. |
| `Array.Create(env)` | Create an empty array. |
| `Array.CreateWithLength(env, len)` | Create an array with length. |
| `createWithLength(env, len)` | Lowercase alias for `CreateWithLength`. |
| `length()` | Return cached length. |
| `Get(index, T)` | Read and convert one element. |
| `Set(index, value)` | Write one element. |
| `HasElement(index)` / `hasElement(index)` | Check whether an index exists. |
| `DeleteElement(index)` / `deleteElement(index)` | Delete one element. |
| `Push(value)` | Append one element. |

When reading JavaScript values into Zig arrays, slices, or `std.ArrayList(T)`, numeric TypedArray inputs are accepted for supported numeric element types.

## `Promise`

```zig
napi.Promise
```

`Promise.New(env)` creates a deferred promise wrapper.

| Method | Use |
| --- | --- |
| `Resolve(value)` | Resolve with any value supported by return conversion. |
| `Reject(error)` | Reject with `napi.Error`. |
| `RejectAbortError()` | Reject with an `AbortError` JavaScript error. |

For most async exports, prefer `napi.Async` or `napi.AsyncWithEvents`; they produce promises and handle scheduling.
