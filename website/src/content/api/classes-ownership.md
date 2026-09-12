---
title: Ownership
---

# Ownership

These wrappers are for JavaScript values that carry native lifetime, or for native code that must keep JavaScript values alive.

## Native Return Values

Plain native returns are borrowed. Conversion copies their contents to JavaScript
without freeing literals, input aliases, or sub-slices. Return a freshly allocated
value as `napi.Owned(T)` so the export boundary releases it after conversion,
including when conversion fails:

```zig
pub fn greeting() !napi.Owned([]u8) {
    const allocator = napi.globalAllocator();
    return .init(try allocator.dupe(u8, "hello"), allocator);
}
```

Converted JavaScript arguments belong to the current native call and are released
when it returns. Clone data that must survive that call. `Owned(T)` records its
allocator, but Zig does not enforce move-only types: copying a wrapper does not
create a second owner. Do not release or transfer the same allocation twice.
An owned aggregate must not contain overlapping owning slices.

The same rule applies to class methods: return a borrow of an instance field,
not a new `Owned` wrapper around memory the instance still owns. Constructors
and factories must return a fully initialized `T`; `undefined` fields are not
valid data and are not repaired by the wrapper.

## JavaScript Resources Created By Conversion

Two parameter shapes do not copy data - they *create* a JavaScript resource:

| Parameter                     | Created resource                     | Release with              |
| ----------------------------- | ------------------------------------ | ------------------------- |
| `napi.Reference(T)`, `napi.ObjectRef`, `napi.FunctionRef` | strong reference (`napi_create_reference`) | `Unref(env)` or `Delete(env)` |
| `*napi.ThreadSafeFunction(...)` | active thread-safe function       | `release(mode)` / `abort()` |

Both are tracked by the argument-conversion transaction
([Conversion Model](./conversion-model)). When the call is rejected before the
native body runs - a wrong type in a later argument, a failure inside a nested
struct or array - the resources the conversion already created are released, so
the referenced JavaScript value becomes collectible again and a rejected call
cannot keep the environment (or the process) alive.

When the call reaches its body the resources belong to the body:

```zig
pub fn remember(reference: napi.ObjectRef) void {
    // `reference` is a strong reference this call now owns. Store it, hand it
    // on, or release it with `Unref`/`Delete` when it is no longer needed;
    // dropping the value without releasing it keeps the JavaScript object
    // alive forever.
}
```

`napi.Reference(T)` is a value type that holds the reference *handle*, not the
ownership. Copying one copies the handle: releasing through one copy
(`Unref`/`Delete`) deletes the reference for all of them, and the other copies
only fail safely if they were marked taken themselves. Keep exactly one owner
per created reference and share borrowed values read through `GetValue(env)`
instead of the handle.

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

### Calls, receivers and factories

- A method whose first parameter is `*T` or `T` is an instance method. The
  receiver is validated against the registry of payloads this class created:
  calling it on an object that is not wrapped with this class (or that belongs
  to another class or addon) throws a `TypeError`, and a wrapped pointer of
  another party is never dereferenced. A `self: T` receiver works on a copy of
  the native state, so field writes through the copy are not visible afterwards.
- Every other method is a static method. Its `this` is the class constructor and
  is never unwrapped, so `Class.twice(3)` behaves like a plain function.
- A static method returning `T` or `*T` is a factory. The returned value is moved
  into a real instance of the class (correct prototype, wrapped exactly once)
  and user `init` is _not_ executed again. `*T` moves the pointee; the
  allocation holding it stays owned by the factory.
- Each `napi_env` owns its own constructor reference, so the main thread and
  worker threads can construct instances and call factories concurrently. The
  reference is weak and the definition is released through an environment
  cleanup hook, with a constructor finalizer as the fallback for environments
  older than Node-API v3; a failing hook registration is reported instead of
  leaking.

### Ownership

- Field construction (`Class(T)` without `init`) transfers ownership of the
  converted constructor arguments to the fields; a failure releases the
  arguments that were converted before the failing one.
- Construction through `init` or a factory _borrows_ its converted inputs. The
  wrapper owns them, keeps them alive for the lifetime of the instance and
  releases them exactly once **after** `deinit` has run:
  - storing one of them in a field is supported;
  - freeing one of them (in `deinit` or anywhere else) is a double free;
  - a type that has to own a resource clones it explicitly
    (`Napi.clone_napi_value`, `allocator.dupe`, ...) or stores it in an
    explicitly owned field (`napi.Owned(T)`), whose `deinit` the wrapper calls.
- A setter converts the new value first, and only then installs it. Ownership is
  never inferred from a pointer value:
  - a value the wrapper installed is released when it is replaced;
  - a field type that declares `deinit` (for example `napi.Owned(T)`) owns
    itself, so the previous value is released through its own `deinit`;
  - when `T` declares `deinit` and the field carries native memory the wrapper
    did not install, the assignment is refused with a `TypeError` rather than
    orphaning or double freeing the previous value. Replace such a field through
    a method of `T`, or use an explicitly owned field type;
  - plain data fields and instances where the wrapper installed the value stay
    assignable.
- `deinit` runs exactly once per instance and is the only owner of the fields it
  declares. Nothing is read from the value after `deinit` returned.

### Construction from JavaScript

`ClassWithoutInit(T)` keeps native construction fully under the addon's control:

- `new ClassWithoutInit(...)` throws a `TypeError`; the class can only be built
  through its factory methods, which matches the `private constructor()`
  declaration emitted by the declaration generator.
- Fields are still exposed as instance properties, and static values and static
  methods keep working.

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
| `isTaken()`                        | True once this copy released the handle.           |

`New`/`from_napi_value` create a strong reference on an object, function or
symbol; the underlying `napi_create_reference` rejects primitives, so
referencing a string or number fails instead of producing a handle that can
never be read back. Every read goes through `napi_get_reference_value`, so a
released (or externally collected) reference fails with `Ref value has been
deleted` instead of returning an invalid handle.

The ownership rules of a created reference are described under
[JavaScript Resources Created By Conversion](#javascript-resources-created-by-conversion):
the exporting wrapper releases a reference whose conversion was rejected, and
the native body owns it once it runs.

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

`setOperationAllocator` overrides short-lived conversion and operation allocations
on the current thread. Restore it before leaving your scope. It is mainly intended
for scoped tests; applications should prefer a thread-safe root `napi_allocator`.
Long-lived resources retain the allocator that created them. An allocator and its
backing state must outlive every allocation created through it, including async
tasks and JavaScript finalizers.
