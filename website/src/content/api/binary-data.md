---
title: Binary Data
---

# Binary Data

Binary wrappers make ownership and copying explicit at the JavaScript boundary.

## Borrowed views and revalidation

`asSlice()` and `asConstSlice()` hand out a view into the memory the JavaScript
runtime owns, so the view stays valid only until the next JavaScript reentry: a
callback, a getter or a Proxy trap may detach, transfer or resize the backing
store. Every accessor therefore re-queries the runtime instead of trusting the
pointer that was cached when the wrapper was created, and every wrapper offers a
fallible variant:

| Method                               | Behavior                                                                                        |
| ------------------------------------ | ----------------------------------------------------------------------------------------------- |
| `tryAsSlice()` / `tryAsConstSlice()` | Revalidate and return the view; fails with `error.InvalidatedBackingStore` after a detach.      |
| `asSlice()` / `asConstSlice()`       | Same view, but an invalid backing store yields an empty slice instead of a dangling pointer.    |
| `refresh()`                          | Re-query the view and update the cached pointer and length.                                     |
| `isValid()`                          | Whether the wrapper refers to a value of the expected JavaScript type.                          |
| `tryFromRaw(env, raw)`               | Fallible wrapper construction; `from_raw` keeps the infallible signature for compatibility.     |
| `from_napi_value(env, raw, T)`       | Fallible byte/element copy into `[]u8` or `[N]u8`; invalid input fails instead of zero filling. |

The conversion layer of an exported function uses `tryFromRaw`, so a view that
was detached, transferred or resized before the call is rejected while the
arguments are converted: the native function never runs with an unusable view.

Reads through `napi.DataView` (`getUint8`, `readInt`, ...) and the element
accessors revalidate the same way. Buffers and views are never copied
implicitly, and the `copy` constructors are not a native-ownership tool:
`Buffer.copy`, `ArrayBuffer.copy`, `TypedArray(T).copy` and `DataView.copy`
build another *JavaScript-owned* object. They are the right answer when the
JavaScript side has to keep the bytes after the original object goes away or is
detached, and the wrong one for native code that has to own them, because a
copy JavaScript owns can be detached, resized or collected just like the
original.

Native ownership means copying into Zig memory, from a view that was validated
in the same turn it is read. For a capture, the async runtime does that copy.
The block below is added to a root that is already registered; it declares no
`NODE_API_MODULE` of its own.

```zig
const napi = @import("napi");

fn checksum(bytes: []const u8) u32 {
    var sum: u32 = 0;
    for (bytes) |byte| sum +%= byte;
    return sum;
}

/// `tryAsConstSlice()` revalidates the view, and `from` deep-copies the
/// captured slice before this call returns, so the JavaScript buffer may be
/// detached or resized immediately afterwards.
pub fn checksumAsync(input: napi.Uint8Array) !napi.Async(u32, .thread) {
    return napi.Async(u32, .thread).from(try input.tryAsConstSlice(), checksum);
}
```

```js
const sum = await addon.checksumAsync(new Uint8Array([1, 2, 3])); // 6
```

An `allocator.dupe` the body performs itself is native-owned: it belongs to
whoever allocated it, is invisible to JavaScript, and has to be released by
native code - the same function before it returns, or a native owner it was
handed to. It is the right tool for a copy that stays inside the addon, and the
wrong one to hand back at an export boundary.

For a freshly allocated result that leaves the addon, name the owner:

- text returns `napi.Owned([]u8)`. The export layer converts it (a `[]u8` or
  `[]const u8` converts to a JavaScript *string*) and then releases the
  allocation, on the success and the failure path alike.
- bytes return a `Buffer` built with `Buffer.copy` (a copy of caller-owned data)
  or `Buffer.from` (ownership transferred to JavaScript where the runtime allows
  external buffers; see the fallback note under [`Buffer`](#buffer)), so the
  JavaScript side receives an object it can hold and collect.

Returning a plain `[]u8` from an exported function transfers nothing: it
converts to a string and the allocation is never freed. There is no JavaScript
handle to release it through, so the export leaks.

The rule behind all of these: a view is valid only until the next JavaScript
reentry, so the pointer must not be stored in a struct that outlives the call,
in a global, or in a background capture. Copy it while the call is still
running; `napi.Owned(T)` and the async runtime's own input cloning
([Async Runtime](./async-runtime)) are the supported ways to carry bytes across
that boundary.

## `Buffer`

```zig
napi.Buffer
```

Use `Buffer` for Node-compatible binary data.

| Constructor                                        | Behavior                                                          |
| -------------------------------------------------- | ----------------------------------------------------------------- |
| `Buffer.New(env, len)`                             | Allocate a new mutable buffer.                                    |
| `Buffer.copy(env, data)`                           | Copy bytes into a new buffer.                                     |
| `Buffer.from(env, data)`                           | Wrap mutable data and transfer ownership to JavaScript.           |
| `Buffer.fromWithFinalizer(env, data, on_finalize)` | Wrap mutable data and run a callback when JavaScript releases it. |
| `Buffer.from_raw(env, raw)`                        | Wrap an existing `napi_value`.                                    |

Read the memory with:

| Method           | Use                     |
| ---------------- | ----------------------- |
| `asSlice()`      | Mutable `[]u8`.         |
| `asConstSlice()` | Immutable `[]const u8`. |
| `length()`       | Byte length.            |

On the zero-copy path the data is released when the Buffer is collected, by the
same allocator that created it (`napi.globalAllocator()`, so hand `from` memory
from that allocator).

When external buffers are not allowed by the runtime, `from` and
`fromWithFinalizer` fall back to a copied buffer, and that fallback *consumes*
the argument the same way the zero-copy path would: the pending external-buffer
record is destroyed, which frees the caller's `data` and invokes `on_finalize`
synchronously, inside the call. The returned `Buffer` owns a copy, so it stays
valid, but the caller must not free or reuse its buffer afterwards, and a
finalizer written to run at collection time has already run. The error paths
below the fallback consume the data the same way; only a failure to allocate the
record itself returns before any ownership changes hands.

## `ArrayBuffer`

```zig
napi.ArrayBuffer
```

`ArrayBuffer` mirrors the buffer API for JavaScript `ArrayBuffer` values.

| Constructor                                             | Behavior                                                |
| ------------------------------------------------------- | ------------------------------------------------------- |
| `ArrayBuffer.New(env, len)`                             | Allocate a new ArrayBuffer.                             |
| `ArrayBuffer.copy(env, data)`                           | Copy bytes into a new ArrayBuffer.                      |
| `ArrayBuffer.from(env, data)`                           | Wrap mutable data and transfer ownership to JavaScript. |
| `ArrayBuffer.fromWithFinalizer(env, data, on_finalize)` | Wrap mutable data and run a callback when released.     |
| `ArrayBuffer.from_raw(env, raw)`                        | Wrap an existing `napi_value`.                          |

| Method                         | Use                                                       |
| ------------------------------ | --------------------------------------------------------- |
| `asSlice()` / `asConstSlice()` | Access bytes.                                             |
| `length()`                     | Byte length.                                              |
| `detach()`                     | Detach the ArrayBuffer. Requires Node-API v7.             |
| `isDetached()`                 | Check whether it is detached. Requires Node-API v7.       |
| `tryAsSlice()`                 | Fails with `error.InvalidatedBackingStore` when detached. |

## `TypedArray`

```zig
napi.TypedArray(T)
```

Typed arrays can be created from new memory, copied memory, external memory, or a view into an existing `ArrayBuffer`.

| Constructor                                                         | Behavior                                                   |
| ------------------------------------------------------------------- | ---------------------------------------------------------- |
| `TypedArray(T).New(env, len)`                                       | Allocate an ArrayBuffer and create the view.               |
| `TypedArray(T).copy(env, data)`                                     | Copy numeric data into a new view.                         |
| `TypedArray(T).from(env, data)`                                     | Wrap mutable numeric data through an external ArrayBuffer. |
| `TypedArray(T).fromArrayBuffer(env, arraybuffer, len, byte_offset)` | Create a view over an existing ArrayBuffer.                |
| `TypedArray(T).from_raw(env, raw)`                                  | Wrap an existing TypedArray.                               |

| Method                             | Use                                            |
| ---------------------------------- | ---------------------------------------------- |
| `asSlice()` / `asConstSlice()`     | Access typed elements.                         |
| `tryAsSlice()`                     | Fail instead of returning an invalidated view. |
| `length()`                         | Element length.                                |
| `tryByteLength()` / `byteLength()` | Byte length, with checked arithmetic.          |

Aliases are exported for common element types:

| Alias                              | Element                    |
| ---------------------------------- | -------------------------- |
| `Int8Array`                        | `i8`                       |
| `Uint8Array`                       | `u8`                       |
| `Uint8ClampedArray`                | `u8` with clamped raw type |
| `Int16Array` / `Uint16Array`       | `i16` / `u16`              |
| `Int32Array` / `Uint32Array`       | `i32` / `u32`              |
| `Float32Array` / `Float64Array`    | `f32` / `f64`              |
| `BigInt64Array` / `BigUint64Array` | `i64` / `u64`              |

BigInt typed arrays require Node-API v6 or newer.

## `DataView`

```zig
napi.DataView
```

`DataView` supports byte-level access and explicit endianness.

| Constructor                                                            | Behavior                                            |
| ---------------------------------------------------------------------- | --------------------------------------------------- |
| `DataView.New(env, byte_length)`                                       | Allocate a new ArrayBuffer and view.                |
| `DataView.copy(env, data)`                                             | Copy bytes into a new view.                         |
| `DataView.from(env, data)`                                             | Wrap mutable bytes through an external ArrayBuffer. |
| `DataView.fromArrayBuffer(env, arraybuffer, byte_offset, byte_length)` | Create a view over an existing ArrayBuffer.         |
| `DataView.from_raw(env, raw)`                                          | Wrap an existing DataView.                          |

| Method                                                                                | Use                                            |
| ------------------------------------------------------------------------------------- | ---------------------------------------------- |
| `asSlice()` / `asConstSlice()`                                                        | Access bytes.                                  |
| `tryAsSlice()`                                                                        | Fail instead of returning an invalidated view. |
| `byteLength()`                                                                        | View byte length.                              |
| `readInt(T, offset, little_endian)` / `writeInt(T, offset, value, little_endian)`     | Generic integer access.                        |
| `readFloat(T, offset, little_endian)` / `writeFloat(T, offset, value, little_endian)` | Generic floating-point access.                 |
| `getInt8` / `getUint8`                                                                | 8-bit reads.                                   |
| `getInt16` / `getUint16` / `getInt32` / `getUint32`                                   | Endian-aware integer reads.                    |
| `getBigInt64` / `getBigUint64`                                                        | 64-bit integer reads.                          |
| `getFloat32` / `getFloat64`                                                           | Endian-aware float reads.                      |
| `setInt8` / `setUint8`                                                                | 8-bit writes.                                  |
| `setInt16` / `setUint16` / `setInt32` / `setUint32`                                   | Endian-aware integer writes.                   |
| `setBigInt64` / `setBigUint64`                                                        | 64-bit integer writes.                         |
| `setFloat32` / `setFloat64`                                                           | Endian-aware float writes.                     |
