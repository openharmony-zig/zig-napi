---
title: Conversion Model
---

# Conversion Model

Exported functions normally do not call wrapper constructors manually. The module registration layer converts JavaScript arguments into Zig types, calls the Zig function, then converts the return value back into JavaScript.

## Function Parameters

The first parameter may be `napi.Env`. It is injected by the wrapper and is not part of the JavaScript signature.

```zig
pub fn make(env: napi.Env, name: []const u8) napi.Object {
    _ = env;
    _ = name;
}
```

All other parameters are read from JavaScript arguments in order. Missing arguments are passed as `undefined` before conversion.

## Supported Input Shapes

| Zig type                                              | JavaScript input                                              |
| ----------------------------------------------------- | ------------------------------------------------------------- |
| `bool`                                                | boolean                                                       |
| integer and float types                               | number                                                        |
| `napi.BigInt`                                         | bigint                                                        |
| `[]u8`, `[]const u8`, `[N]u8`                         | UTF-8 string input                                            |
| `[]u16`, `[]const u16`, `[N]u16`                      | UTF-16 string input                                           |
| `?T`                                                  | `T`, `null`, or `undefined`                                   |
| struct                                                | object with matching fields                                   |
| tuple struct                                          | array with positional entries                                 |
| array, slice, `std.ArrayList(T)`                      | JavaScript Array, or numeric TypedArray when `T` is supported |
| enum                                                  | numeric enum value                                            |
| enum with `pub const napi_string_enum = true`         | string enum name                                              |
| union(enum)                                           | first matching union field                                    |
| `napi.NapiValue`                                      | raw JavaScript value                                          |
| `napi.Function`, `*napi.Function`, `napi.FunctionRef` | JavaScript function                                           |
| `napi.ThreadSafeFunction` pointer                     | JavaScript function promoted to a TSFN                        |
| `napi.Buffer`                                         | Node Buffer                                                   |
| `napi.ArrayBuffer`                                    | ArrayBuffer                                                   |
| `napi.TypedArray(T)` and aliases                      | matching TypedArray                                           |
| `napi.DataView`                                       | DataView                                                      |
| `napi.External(T)`                                    | zig-napi external value tagged with `T`                       |
| `napi.AbortSignal`                                    | AbortSignal-like object                                       |

Use `napi.Buffer` or `napi.ArrayBuffer` when the JavaScript input should be
treated as binary data instead of a string.

## Conversion Hooks

Most wrapper types expose `from_raw(env, raw)` for manually wrapping an existing
`napi_value`. Types that can be accepted as exported function parameters also
expose `from_napi_value`; that hook is what the generated wrapper calls during
automatic argument conversion.

Regular addon code usually only needs `from_raw` for low-level N-API interop.
Prefer typed function parameters for normal exports so cleanup and error mapping
stay in the generated conversion layer.

`Napi.from_napi_value*`, `NapiValue.As`, `Object.Get`/`GetNamed`/`Has`,
`Array.Get` and string copy/length APIs now return error unions. Migrate manual
callers with `try` or explicit `catch`. Binary wrappers expose `tryFromRaw` and
`tryAsSlice` for checked construction/access; generated inputs use checked paths.

## Supported Return Shapes

The return conversion supports ordinary Zig values and wrapper values.

| Zig return                                   | JavaScript output                                      |
| -------------------------------------------- | ------------------------------------------------------ |
| `void`                                       | `undefined`                                            |
| `napi.Owned(T)`                              | same as `T`; release native ownership after conversion |
| `bool`, numbers, strings                     | primitive JavaScript values                            |
| `i128` / `u128`                              | bigint                                                 |
| `?T`                                         | `T` or `undefined`                                     |
| struct                                       | object                                                 |
| tuple, array, slice, `std.ArrayList(T)`      | array                                                  |
| enum                                         | numeric or string enum value                           |
| union(enum)                                  | payload of the active field                            |
| `napi.Result(T)`                             | payload or thrown JavaScript error                     |
| Zig error union `!T`                         | payload or thrown JavaScript error                     |
| `napi.Async(T, runtime)`                     | `Promise<T>`                                           |
| `napi.AsyncWithEvents(T, Event, runtime)`    | `Promise<T>` plus optional event callback              |
| `napi.Promise`                               | Promise                                                |
| `napi.Function`                              | JavaScript function                                    |
| `napi.Class(T)` / `napi.ClassWithoutInit(T)` | JavaScript class constructor                           |
| `napi.External(T)`                           | branded external object                                |

## Allocation And Cleanup

Conversions that allocate Zig memory use `napi.globalAllocator()`. String, array, slice, object, function, external, and async conversions are cleaned up by the conversion layer when the wrapper owns the temporary value.

For addon-wide allocator control, export `pub const napi_allocator` from the addon root. For narrow tests or scoped operations, use `setOperationAllocator` and `resetOperationAllocator`.

A root allocator is reached from every thread of the addon: a worker executes
`Execute` while the JavaScript thread converts arguments. On WebAssembly
`std.heap.page_allocator` is the break allocator, whose free lists are one
unsynchronized global that emnapi's worker threads share with the JavaScript
thread; a custom allocator (a counting wrapper, for example) must therefore take
its pages from `napi.safePageAllocator()`, which is that allocator behind one
module-global lock (and is `std.heap.page_allocator` itself on native targets).

Converted arguments are call-scoped owned copies. Plain return values are
borrowed and are not freed; return native heap allocations in `napi.Owned(T)`.
Async captures clone native inputs and dispose owned results explicitly. A custom
`deinit` must release the allocations its value actually owns; it must not free
borrowed literals or instance-retained constructor arguments. See [Ownership](./classes-ownership).

## Conversion Transactions

Argument conversion is a transaction. Some conversions do not copy data, they
_create_ JavaScript resources: `napi.Reference(T)`, `napi.ObjectRef` and
`napi.FunctionRef` create a strong reference, and a
`*napi.ThreadSafeFunction(...)` parameter creates an active thread-safe
function. Those resources are recorded while the arguments are converted and
released again when the call is rejected, including a failure inside a nested
struct or array, before the native body runs.

The transaction is committed at the moment the native body is entered. From
then on the converted values belong to the body, so a successful call never
releases a reference the body stored or aborts a TSFN another thread is using.
Releasing them is the body's job: `Unref()`/`Delete()` for a reference, the
final `release()`/`abort()` for a TSFN. See [Ownership](./classes-ownership) and
[Functions](./callback-functions).

Manual conversions (`Napi.from_napi_value*`, `NapiValue.As(T)`) are
transactions too:

- inside an automatic argument conversion they join that conversion, so a
  failure anywhere still releases everything the outer conversion created,
- anywhere else - a standalone conversion, or a manual conversion inside a
  native body whose own transaction is already committed - they run in their own
  transaction. It is committed when the conversion succeeds, which hands the
  created resources to the caller, and it releases them if the conversion fails
  halfway instead of leaking what it had already created.

One consequence of the ordering: a custom `deinit` of a converted value (a
struct that releases its own native memory) runs _after_ the resource rollback,
during the ordinary native cleanup. It must only release native memory it owns -
never a reference or TSFN the conversion created, which the transaction releases
itself and the body owns after the commit.

## TypeScript Output

`generateTypeDefinition` follows the same conversion model. It emits interfaces for object-like structs, tuples for tuple structs, `const enum` for Zig enums, union types for `union(enum)`, `ExternalObject<T>` for `napi.External(T)`, and an `AbortSignal` interface when an API references `napi.AbortSignal`.
