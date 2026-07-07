---
title: Ownership
---

# Ownership

These wrappers are for JavaScript values that carry native lifetime, or for native code that must keep JavaScript values alive.

## `Class`

```zig
napi.Class(comptime T: type)
```

Exports a Zig struct type as a JavaScript class with constructor initialization and wrapped native instances.

`Class(T)` supports:

| Zig declaration                      | JavaScript class member                       |
| ------------------------------------ | --------------------------------------------- |
| struct fields                        | instance properties with getter and setter    |
| `pub fn init(...) T` or `!T`         | constructor body                              |
| no `init`                            | constructor parameters are the struct fields  |
| `pub fn method(self: *T, ...)`       | instance method                               |
| `pub fn method(self: T, ...)`        | instance method with value receiver           |
| `pub fn staticMethod(...)`           | static method                                 |
| static factory returning `T` or `*T` | static factory returning a class instance     |
| `pub const value = ...`              | static readonly value                         |
| `pub fn deinit(self: *T)`            | called when the wrapped instance is finalized |

```zig
const Counter = struct {
    value: i32,

    pub fn init(value: i32) Counter {
        return .{ .value = value };
    }

    pub fn inc(self: *Counter) i32 {
        self.value += 1;
        return self.value;
    }
};

pub const CounterClass = napi.Class(Counter);
```

## `ClassWithoutInit`

```zig
napi.ClassWithoutInit(comptime T: type)
```

Exports a class wrapper when construction should be controlled by native factory functions instead of the JavaScript constructor path.

Declaration generation emits a private constructor for this form. Static factory methods that return `T` or `*T` are the public construction path.

## `Reference` And `Ref`

```zig
napi.Reference(comptime T: type)
napi.Ref(comptime T: type)
```

References keep JavaScript values alive across calls. `Ref` is an alias for `Reference`.

| Method                             | Use                                                |
| ---------------------------------- | -------------------------------------------------- |
| `New(env, value)`                  | Create a reference.                                |
| `from_napi_value(env, raw)`        | Convert a JavaScript value into a reference.       |
| `to_napi_value(env)`               | Get the referenced value as raw `napi_value`.      |
| `get_value(env)` / `GetValue(env)` | Get the referenced wrapper value.                  |
| `Ref(env)`                         | Increase the reference count and return the count. |
| `Unref(env)`                       | Unref and delete the reference.                    |
| `Delete(env)`                      | Alias for `Unref`.                                 |

## `FunctionRef` And `ObjectRef`

```zig
napi.FunctionRef(Args, Return)
napi.ObjectRef
```

`FunctionRef` is `Reference(Function(Args, Return))`. `ObjectRef` is `Reference(Object)`.

Use these when native code needs to keep a callback or object after the current N-API callback returns.

## `External`

```zig
napi.External(comptime T: type)
```

Wraps a native payload in a JavaScript external value. The wrapper tags the external with the Zig type name, so `External(A)` does not match `External(B)`.

| Method                                             | Use                                                           |
| -------------------------------------------------- | ------------------------------------------------------------- |
| `New(payload)` / `new(payload)`                    | Create a detached external wrapper.                           |
| `NewWithSizeHint(payload, size_hint)`              | Create with memory pressure accounting.                       |
| `newWithSizeHint(payload, size_hint)`              | Lowercase alias.                                              |
| `from_raw(env, raw)` / `from_napi_value(env, raw)` | Read and validate an external value.                          |
| `matches_napi_value(env, raw)`                     | Check whether a raw value is a zig-napi external of type `T`. |
| `to_napi_value(env)`                               | Materialize the JavaScript external.                          |
| `value()` / `asConstPtr()`                         | Immutable payload pointer.                                    |
| `valueMut()` / `asPtr()`                           | Mutable payload pointer.                                      |
| `sizeHint()`                                       | Declared size hint.                                           |
| `adjustedSize()`                                   | Last adjusted external memory value.                          |
| `deinit()` / `Deinit()`                            | Destroy a detached external before it is materialized.        |

If `T` has a `deinit` method, the conversion layer calls it when the external payload is destroyed.

## `NativeWrap`

```zig
napi.NativeWrap.wrap
napi.NativeWrap.unwrap
napi.NativeWrap.unwrapConst
napi.NativeWrap.dropWrapped
napi.NativeWrap.matches
```

`NativeWrap` attaches native payloads to JavaScript objects and retrieves them later.

Use the higher-level conveniences when possible:

```zig
try object.wrap(.{ .state = 1 });
const state = try object.unwrap(State);
```

The wrapper stores a type tag, optional `size_hint`, and a finalizer. `dropWrapped` removes the N-API wrap, adjusts external memory when needed, and destroys the stored payload.

## Allocator Hooks

```zig
napi.globalAllocator()
napi.setOperationAllocator(allocator)
napi.resetOperationAllocator()
```

Addon roots may declare `pub const napi_allocator: std.mem.Allocator = ...;` for a root allocator. This declaration is reserved and is not exported as a JavaScript property.

`setOperationAllocator` overrides only short-lived conversion and operation allocations. It is mainly intended for scoped tests. Applications should prefer a root `napi_allocator`.
